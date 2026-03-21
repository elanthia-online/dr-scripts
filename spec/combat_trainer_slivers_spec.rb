# frozen_string_literal: true

require 'ostruct'

# Load test harness which provides mock game objects
load File.join(File.dirname(__FILE__), '..', 'test', 'test_harness.rb')
include Harness

# Extract and eval a class from a .lic file without executing top-level code
def load_lic_class(filename, class_name)
  return if Object.const_defined?(class_name)

  filepath = File.join(File.dirname(__FILE__), '..', filename)
  lines = File.readlines(filepath)

  start_idx = lines.index { |l| l =~ /^class\s+#{class_name}\b/ }
  raise "Could not find 'class #{class_name}' in #{filename}" unless start_idx

  end_idx = nil
  (start_idx + 1...lines.size).each do |i|
    if lines[i] =~ /^end\s*$/
      end_idx = i
      break
    end
  end
  raise "Could not find matching end for 'class #{class_name}' in #{filename}" unless end_idx

  class_source = lines[start_idx..end_idx].join
  eval(class_source, TOPLEVEL_BINDING, filepath, start_idx + 1)
end

# Stub modules needed by SpellProcess
module DRC
  class << self
    def bput(*_args)
      'Roundtime'
    end

    def message(*_args); end
  end
end

module DRCA
  class << self
    def cast_spell(*_args); end
  end
end

# UserVars stub with moons support
class UserVars
  @@data = {}

  def self.moons
    @@data['moons'] || { 'visible' => [] }
  end

  def self._set_moons(val)
    @@data['moons'] = val
  end

  def self._reset
    @@data = {}
  end
end

# Extend harness DRSpells with slivers and known_spells
class DRSpells
  @@_slivers = false
  @@_known_spells = {}

  def self.slivers
    @@_slivers
  end

  def self._set_slivers(val)
    @@_slivers = val
  end

  def self.known_spells
    @@_known_spells
  end

  def self._set_known_spells(val)
    @@_known_spells = val
  end
end

$debug_mode_ct = false

load_lic_class('combat-trainer.lic', 'SpellProcess')

RSpec.configure do |config|
  config.before(:each) do
    reset_data
    UserVars._reset
    DRSpells._set_slivers(false)
    DRSpells._set_known_spells({})
  end
end

# ===========================================================================
# SpellProcess#check_slivers -- sliver detection and creation for Moon Mages
# ===========================================================================
RSpec.describe SpellProcess do
  # Build a SpellProcess without calling initialize
  def build_spell_process(**overrides)
    instance = SpellProcess.allocate
    defaults = {
      tk_spell: { 'abbrev' => 'tkt' },
      tk_ammo: nil,
      settings: OpenStruct.new
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  def build_game_state(**attrs)
    defaults = { casting: false }
    double('GameState', defaults.merge(attrs))
  end

  def setup_moon_mage_with_moonblade
    DRStats.guild = 'Moon Mage'
    DRSpells._set_known_spells({ 'Moonblade' => true })
    UserVars._set_moons({ 'visible' => ['Katamba'] })
    # Stub get_data to return spell data with Moonblade
    $test_data = OpenStruct.new(
      spells: OpenStruct.new(
        spell_data: { 'Moonblade' => { 'mana' => 5, 'prep_time' => 5 } }
      )
    )
  end

  describe '#check_slivers' do
    context 'guard clauses' do
      it 'returns early if character does not know Moonblade' do
        DRStats.guild = 'Moon Mage'
        DRSpells._set_known_spells({})

        instance = build_spell_process
        game_state = build_game_state

        expect(DRCA).not_to receive(:cast_spell)
        instance.send(:check_slivers, game_state)
      end

      it 'returns early if character is not a Moon Mage' do
        DRStats.guild = 'Warrior Mage'
        DRSpells._set_known_spells({ 'Moonblade' => true })

        instance = build_spell_process
        game_state = build_game_state

        expect(DRCA).not_to receive(:cast_spell)
        instance.send(:check_slivers, game_state)
      end

      it 'returns early if no TK spell is configured' do
        DRStats.guild = 'Moon Mage'
        DRSpells._set_known_spells({ 'Moonblade' => true })

        instance = build_spell_process(tk_spell: nil)
        game_state = build_game_state

        expect(DRCA).not_to receive(:cast_spell)
        instance.send(:check_slivers, game_state)
      end

      it 'returns early if already casting' do
        DRStats.guild = 'Moon Mage'
        DRSpells._set_known_spells({ 'Moonblade' => true })

        instance = build_spell_process
        game_state = build_game_state(casting: true)

        expect(DRCA).not_to receive(:cast_spell)
        instance.send(:check_slivers, game_state)
      end

      it 'returns early if slivers already exist' do
        DRStats.guild = 'Moon Mage'
        DRSpells._set_known_spells({ 'Moonblade' => true })
        DRSpells._set_slivers(true)

        instance = build_spell_process
        game_state = build_game_state

        expect(DRCA).not_to receive(:cast_spell)
        instance.send(:check_slivers, game_state)
      end

      it 'returns early if no moons are visible' do
        DRStats.guild = 'Moon Mage'
        DRSpells._set_known_spells({ 'Moonblade' => true })
        UserVars._set_moons({ 'visible' => [] })

        instance = build_spell_process
        game_state = build_game_state

        expect(DRCA).not_to receive(:cast_spell)
        instance.send(:check_slivers, game_state)
      end
    end

    context 'when slivers need to be created' do
      before(:each) do
        setup_moon_mage_with_moonblade
        allow(DRCA).to receive(:cast_spell)
      end

      it 'casts moonblade and breaks it on success' do
        allow(DRC).to receive(:bput)
          .with('break moonblade', 'The slivers drift about', 'dissipate without any benefit', 'Break what?')
          .and_return('The slivers drift about')

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell).once
        expect(DRC).to have_received(:bput).with('break moonblade', anything, anything, anything).once
      end

      it 'retries up to 3 times on failure' do
        allow(DRC).to receive(:bput)
          .with('break moonblade', 'The slivers drift about', 'dissipate without any benefit', 'Break what?')
          .and_return('dissipate without any benefit', 'dissipate without any benefit', 'dissipate without any benefit')

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell).exactly(3).times
        expect(DRC).to have_received(:bput).with('break moonblade', anything, anything, anything).exactly(3).times
      end

      it 'stops retrying after first success' do
        allow(DRC).to receive(:bput)
          .with('break moonblade', 'The slivers drift about', 'dissipate without any benefit', 'Break what?')
          .and_return('dissipate without any benefit', 'The slivers drift about')

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell).exactly(2).times
      end

      it 'logs failure message when all retries are exhausted' do
        allow(DRC).to receive(:bput)
          .with('break moonblade', 'The slivers drift about', 'dissipate without any benefit', 'Break what?')
          .and_return('dissipate without any benefit')

        instance = build_spell_process
        game_state = build_game_state

        expect(DRC).to receive(:message).with(/Failed to create slivers.*3 attempts/)
        instance.send(:check_slivers, game_state)
      end

      it 'does not log failure message on success' do
        allow(DRC).to receive(:bput)
          .with('break moonblade', 'The slivers drift about', 'dissipate without any benefit', 'Break what?')
          .and_return('The slivers drift about')

        instance = build_spell_process
        game_state = build_game_state

        expect(DRC).not_to receive(:message).with(/Failed to create slivers/)
        instance.send(:check_slivers, game_state)
      end
    end

    context 'prep time based on Lunar Magic rank' do
      before(:each) do
        setup_moon_mage_with_moonblade
        allow(DRC).to receive(:bput)
          .with('break moonblade', anything, anything, anything)
          .and_return('The slivers drift about')
      end

      it 'uses prep_time 1 for Lunar Magic >= 400' do
        DRSkill._set_rank('Lunar Magic', 450)
        allow(DRCA).to receive(:cast_spell)

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell) do |spell_data, _settings|
          expect(spell_data['prep_time']).to eq(1)
        end
      end

      it 'uses prep_time 2 for Lunar Magic 300-399' do
        DRSkill._set_rank('Lunar Magic', 350)
        allow(DRCA).to receive(:cast_spell)

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell) do |spell_data, _settings|
          expect(spell_data['prep_time']).to eq(2)
        end
      end

      it 'uses prep_time 3 for Lunar Magic 200-299' do
        DRSkill._set_rank('Lunar Magic', 250)
        allow(DRCA).to receive(:cast_spell)

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell) do |spell_data, _settings|
          expect(spell_data['prep_time']).to eq(3)
        end
      end

      it 'does not override prep_time for Lunar Magic < 200' do
        DRSkill._set_rank('Lunar Magic', 150)
        allow(DRCA).to receive(:cast_spell)

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell) do |spell_data, _settings|
          # prep_time should remain at the spell data default (5)
          expect(spell_data['prep_time']).to eq(5)
        end
      end
    end
  end
end
