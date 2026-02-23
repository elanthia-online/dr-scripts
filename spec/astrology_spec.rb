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

# Define stub modules only if not already defined
module DRC
  class << self
    def bput(*_args); end
    def left_hand; end
    def right_hand; end
    def message(_msg); end
    def wait_for_script_to_complete(*_args); end
    def fix_standing; end
  end
end unless defined?(DRC)

module DRCI
  class << self
    def in_hands?(_item); end
  end
end unless defined?(DRCI)

module DRCMM
  class << self
    def observe(_thing); end
    def predict(_thing); end
    def study_sky; end
    def align(_skill); end
    def roll_bones(_storage); end
    def use_div_tool(_tool); end
    def get_telescope?(_name, _storage); end
    def store_telescope?(_name, _storage); end
    def center_telescope(_target); end
    def peer_telescope; end
  end
end unless defined?(DRCMM)

module DRCA
  class << self
    def cast_spell(_data, _settings); end
    def check_discern(_data, _settings); end
    def cast_spells(_spells, _settings); end
    def perc_mana; end
  end
end unless defined?(DRCA)

module DRCT
  class << self
    def walk_to(_room_id); end
  end
end unless defined?(DRCT)

module Lich
  module Messaging
    class << self
      def msg(*_args); end
    end
  end

  module Util
    class << self
      def issue_command(*_args); end
    end
  end
end unless defined?(Lich::Messaging)

# Define Lich::Util separately in case Lich::Messaging was already defined
module Lich
  module Util
    class << self
      def issue_command(*_args); end
    end
  end
end unless defined?(Lich::Util)

# Add methods to Harness classes that astrology.lic needs
Harness::EquipmentManager.class_eval do
  def empty_hands; end
end

# DRSkill needs getxp for training routines
# Use singleton methods to avoid class variable issues in Ruby 4.0
Harness::DRSkill.define_singleton_method(:_xp_store) { @_xp_store ||= {} }
Harness::DRSkill.define_singleton_method(:_set_xp) { |skillname, val| _xp_store[skillname] = val }
Harness::DRSkill.define_singleton_method(:_reset_xp) { @_xp_store = {} }
Harness::DRSkill.define_singleton_method(:getxp) { |skillname| _xp_store[skillname] || 0 }

class Room
  class << self
    def current
      OpenStruct.new(id: 1)
    end
  end
end unless defined?(Room)

class UserVars
  class << self
    def astrology_debug
      false
    end

    def astral_plane_exp_timer
      nil
    end

    def astral_plane_exp_timer=(_val); end
  end
end unless defined?(UserVars)

def sitting?
  false
end

def stunned?
  false
end

def pause(*_args); end

load_lic_class('astrology.lic', 'Astrology')

RSpec.describe Astrology do
  let(:messages) { [] }
  let(:constellations_data) do
    OpenStruct.new(
      constellations: [
        { 'name' => 'Katamba', 'circle' => 1, 'constellation' => false, 'telescope' => false,
          'pools' => { 'magic' => true, 'survival' => true } },
        { 'name' => 'Xibar', 'circle' => 1, 'constellation' => false, 'telescope' => false,
          'pools' => { 'lore' => true } },
        { 'name' => 'Yavash', 'circle' => 5, 'constellation' => false, 'telescope' => false,
          'pools' => { 'offensive combat' => true } },
        { 'name' => 'Heart', 'circle' => 30, 'constellation' => true, 'telescope' => true,
          'pools' => { 'magic' => true, 'lore' => true, 'survival' => true } }
      ],
      observe_finished_messages: [
        "You've learned all that you can",
        'You believe you have learned'
      ],
      observe_success_messages: [
        'You learned something useful',
        'While the sighting'
      ],
      observe_injured_messages: [
        'The pain is too much',
        'Your vision is too fuzzy'
      ]
    )
  end
  let(:spell_data) do
    {
      'Read the Ripples' => { 'expire' => 'The ripples of Fate settle' }
    }
  end
  let(:default_settings) do
    OpenStruct.new(
      waggle_sets: {},
      astrology_training: %w[observe weather events],
      astrology_force_visions: false,
      divination_tool: nil,
      divination_bones_storage: nil,
      have_telescope: false,
      telescope_storage: {},
      telescope_name: 'telescope',
      astral_plane_training: {},
      astrology_use_full_pools: false,
      astrology_pool_target: 7,
      astrology_prediction_skills: {
        'magic'    => 'Arcana',
        'lore'     => 'Scholarship',
        'offense'  => 'Tactics',
        'defense'  => 'Evasion',
        'survival' => 'Outdoorsmanship'
      }
    )
  end

  before(:each) do
    reset_data

    # Setup test data
    DRStats.guild = 'Moon Mage'
    DRStats.circle = 50

    $test_settings = default_settings
    $test_data = {
      constellations: constellations_data,
      spells: OpenStruct.new(spell_data: spell_data)
    }

    # Setup module stubs
    allow(Lich::Messaging).to receive(:msg) { |_, msg| messages << msg }
    allow(Lich::Util).to receive(:issue_command).and_return([])
    allow(DRC).to receive(:bput).and_return('Roundtime')
    allow(DRC).to receive(:wait_for_script_to_complete)
    allow(DRC).to receive(:fix_standing)
    allow(DRCI).to receive(:in_hands?).and_return(false)
    allow(DRCMM).to receive(:observe).and_return('You learned something useful')
    allow(DRCMM).to receive(:predict)
    allow(DRCMM).to receive(:study_sky).and_return('Roundtime')
    allow(DRCMM).to receive(:align)
    allow(DRCMM).to receive(:roll_bones)
    allow(DRCMM).to receive(:use_div_tool)
    allow(DRCMM).to receive(:get_telescope?).and_return(true)
    allow(DRCMM).to receive(:store_telescope?).and_return(true)
    allow(DRCMM).to receive(:center_telescope)
    allow(DRCMM).to receive(:peer_telescope).and_return(['You learned something useful', 'Roundtime: 5 sec.'])
    allow(DRCA).to receive(:cast_spell)
    allow(DRCA).to receive(:check_discern)
    allow(DRCA).to receive(:cast_spells)
    allow(DRCA).to receive(:perc_mana)
    allow(DRCT).to receive(:walk_to)
  end

  describe 'constants' do
    describe 'POOL_PATTERNS' do
      it 'is frozen' do
        expect(described_class::POOL_PATTERNS).to be_frozen
      end

      it 'maps understanding levels 0-10' do
        values = described_class::POOL_PATTERNS.values
        expect(values).to include(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
      end

      it 'matches feeble understanding to level 1' do
        pattern = described_class::POOL_PATTERNS.find { |k, _| k.source.include?('feeble') }&.last
        expect(pattern).to eq(1)
      end

      it 'matches complete understanding to level 10' do
        pattern = described_class::POOL_PATTERNS.find { |k, _| k.source.include?('complete') }&.last
        expect(pattern).to eq(10)
      end
    end

    describe 'OBSERVE_SUCCESS_PATTERNS' do
      it 'is frozen' do
        expect(described_class::OBSERVE_SUCCESS_PATTERNS).to be_frozen
      end

      it 'includes partial success pattern' do
        expect(described_class::OBSERVE_SUCCESS_PATTERNS).to include('While the sighting')
      end

      it 'includes full success pattern' do
        expect(described_class::OBSERVE_SUCCESS_PATTERNS).to include('You learned something useful')
      end

      it 'includes solar conjunction pattern' do
        expect(described_class::OBSERVE_SUCCESS_PATTERNS).to include('too close to the sun')
      end

      it 'includes observation cooldown pattern' do
        expect(described_class::OBSERVE_SUCCESS_PATTERNS).to include('You have not pondered')
      end

      it 'includes cooldown followup pattern' do
        expect(described_class::OBSERVE_SUCCESS_PATTERNS).to include('You are unable to make use')
      end
    end

    describe 'PERCEIVE_TARGETS' do
      it 'is frozen' do
        expect(described_class::PERCEIVE_TARGETS).to be_frozen
      end

      it 'includes empty string for basic perceive' do
        expect(described_class::PERCEIVE_TARGETS).to include('')
      end

      it 'includes mana target' do
        expect(described_class::PERCEIVE_TARGETS).to include('mana')
      end

      it 'includes moons target' do
        expect(described_class::PERCEIVE_TARGETS).to include('moons')
      end
    end

    describe 'PREDICT_STATE_START' do
      it 'is frozen' do
        expect(described_class::PREDICT_STATE_START).to be_frozen
      end

      it 'matches celestial influences' do
        expect('You have a feeble understanding of the celestial influences over').to match(described_class::PREDICT_STATE_START)
      end
    end

    describe 'PREDICT_STATE_END' do
      it 'is frozen' do
        expect(described_class::PREDICT_STATE_END).to be_frozen
      end

      it 'matches Roundtime case-insensitively' do
        expect('Roundtime: 3 sec.').to match(described_class::PREDICT_STATE_END)
        expect('roundtime: 3 sec.').to match(described_class::PREDICT_STATE_END)
      end
    end
  end

  describe '#initialize' do
    context 'when not a Moon Mage' do
      before do
        DRStats.guild = 'Warrior'
      end

      it 'displays exit message and terminates' do
        expect do
          described_class.allocate.tap { |a| a.send(:initialize) }
        end.to raise_error(SystemExit)
        expect(messages).to include('Astrology: This script is only for Moon Mages. Exiting.')
      end
    end

    context 'when circle is zero' do
      before do
        DRStats.circle = 0
        # Set high XP to exit training loop immediately
        Harness::DRSkill._set_xp('Astrology', 35)
        allow(Lich::Util).to receive(:issue_command).and_return([])
      end

      it 'calls info command to refresh circle' do
        expect(DRC).to receive(:bput).with('info', 'Circle:')
        described_class.allocate.tap { |a| a.send(:initialize) }
      end
    end
  end

  describe '#check_pools' do
    let(:astrology) { described_class.allocate }
    let(:pool_output) do
      [
        'You have a potent understanding of the celestial influences over magic.',
        'You have a modest understanding of the celestial influences over lore.',
        'You have no understanding of the celestial influences over survival.',
        'Roundtime: 3 sec.'
      ]
    end

    before do
      allow(Lich::Util).to receive(:issue_command).and_return(pool_output)
    end

    it 'uses issue_command with correct patterns' do
      expect(Lich::Util).to receive(:issue_command).with(
        'predict state all',
        described_class::PREDICT_STATE_START,
        described_class::PREDICT_STATE_END,
        timeout: 10,
        usexml: false,
        silent: true,
        quiet: true
      )
      astrology.check_pools
    end

    it 'parses potent understanding as level 7' do
      pools = astrology.check_pools
      expect(pools['magic']).to eq(7)
    end

    it 'parses modest understanding as level 4' do
      pools = astrology.check_pools
      expect(pools['lore']).to eq(4)
    end

    it 'parses no understanding as level 0' do
      pools = astrology.check_pools
      expect(pools['survival']).to eq(0)
    end

    context 'when issue_command times out' do
      before do
        allow(Lich::Util).to receive(:issue_command).and_return(nil)
      end

      it 'returns default pool values' do
        pools = astrology.check_pools
        expect(pools.values).to all(eq(0))
      end

      it 'logs failure message' do
        astrology.check_pools
        expect(messages).to include('Astrology: Failed to capture predict state output. Using default pool values.')
      end
    end
  end

  describe '#check_attunement' do
    let(:astrology) { described_class.allocate }

    context 'when Attunement XP is low' do
      before do
        DRSkill._set_rank('Attunement', 0)
        allow(DRSkill).to receive(:getxp).with('Attunement').and_return(10)
      end

      it 'perceives all targets' do
        described_class::PERCEIVE_TARGETS.each do |target|
          expect(DRC).to receive(:bput).with("perceive #{target}", 'roundtime')
        end
        astrology.check_attunement
      end
    end

    context 'when Attunement XP is above threshold' do
      before do
        allow(DRSkill).to receive(:getxp).with('Attunement').and_return(31)
      end

      it 'does not perceive' do
        expect(DRC).not_to receive(:bput).with(/perceive/, anything)
        astrology.check_attunement
      end
    end
  end

  describe '#check_weather' do
    let(:astrology) { described_class.allocate }

    it 'calls predict weather' do
      expect(DRCMM).to receive(:predict).with('weather')
      astrology.check_weather
    end
  end

  describe '#rtr_active?' do
    let(:astrology) { described_class.allocate }

    context 'when Read the Ripples is active' do
      before do
        DRSpells._set_active_spells({ 'Read the Ripples' => true })
      end

      it 'returns true' do
        expect(astrology.rtr_active?).to be true
      end
    end

    context 'when Read the Ripples is not active' do
      before do
        DRSpells._set_active_spells({})
      end

      it 'returns false' do
        expect(astrology.rtr_active?).to be false
      end
    end
  end

  describe '#check_observation_finished?' do
    let(:astrology) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@finished_messages, constellations_data.observe_finished_messages)
      end
    end

    context 'with array result' do
      it 'returns true when array contains finished message' do
        result = ['Some text', "You've learned all that you can", 'Roundtime: 5 sec.']
        expect(astrology.check_observation_finished?(result)).to be true
      end

      it 'returns false when array has no finished message' do
        result = ['Some text', 'Roundtime: 5 sec.']
        expect(astrology.check_observation_finished?(result)).to be false
      end
    end

    context 'with string result' do
      it 'returns true for finished message' do
        expect(astrology.check_observation_finished?("You've learned all that you can")).to be true
      end

      it 'returns false for non-finished message' do
        expect(astrology.check_observation_finished?('You learned something useful')).to be false
      end
    end

    context 'with nil result' do
      it 'returns false' do
        expect(astrology.check_observation_finished?(nil)).to be false
      end
    end
  end

  describe '#check_observation_success?' do
    let(:astrology) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@success_messages, constellations_data.observe_success_messages)
      end
    end

    context 'with array result' do
      it 'returns true when array contains success message' do
        result = ['Some text', 'You learned something useful', 'Roundtime: 5 sec.']
        expect(astrology.check_observation_success?(result)).to be true
      end

      it 'returns false when array has no success message' do
        result = ['Some text', 'Roundtime: 5 sec.']
        expect(astrology.check_observation_success?(result)).to be false
      end
    end

    context 'with string result' do
      it 'returns true for success message' do
        expect(astrology.check_observation_success?('You learned something useful')).to be true
      end

      it 'returns false for non-success message' do
        expect(astrology.check_observation_success?('Random text')).to be false
      end
    end

    context 'with nil result' do
      it 'returns false' do
        expect(astrology.check_observation_success?(nil)).to be false
      end
    end
  end

  describe '#check_telescope_result' do
    let(:astrology) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@injured_messages, constellations_data.observe_injured_messages)
      end
    end

    context 'with array result containing injury' do
      it 'returns injuries=true' do
        result = ['The pain is too much', 'Roundtime: 5 sec.']
        injuries, closed = astrology.check_telescope_result(result)
        expect(injuries).to be true
        expect(closed).to be false
      end
    end

    context 'with array result containing closed telescope' do
      it 'returns closed=true' do
        result = ["You'll need to open it", 'Roundtime: 5 sec.']
        injuries, closed = astrology.check_telescope_result(result)
        expect(injuries).to be false
        expect(closed).to be true
      end
    end

    context 'with string result containing injury' do
      it 'returns injuries=true' do
        injuries, closed = astrology.check_telescope_result('The pain is too much')
        expect(injuries).to be true
        expect(closed).to be false
      end
    end

    context 'with string result containing open it' do
      it 'returns closed=true' do
        injuries, closed = astrology.check_telescope_result('open it')
        expect(injuries).to be false
        expect(closed).to be true
      end
    end

    context 'with normal result' do
      it 'returns both false' do
        result = ['You learned something useful', 'Roundtime: 5 sec.']
        injuries, closed = astrology.check_telescope_result(result)
        expect(injuries).to be false
        expect(closed).to be false
      end
    end
  end

  describe '#empty_hands' do
    let(:mock_equipment_manager) { instance_double('EquipmentManager', empty_hands: nil) }
    let(:astrology) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@telescope_name, 'telescope')
        a.instance_variable_set(:@telescope_storage, { 'container' => 'backpack' })
        a.instance_variable_set(:@equipment_manager, mock_equipment_manager)
      end
    end

    context 'when telescope is in hands' do
      before do
        allow(DRCI).to receive(:in_hands?).with('telescope').and_return(true)
      end

      it 'stores the telescope' do
        expect(DRCMM).to receive(:store_telescope?).with('telescope', { 'container' => 'backpack' })
        astrology.empty_hands
      end
    end

    context 'when telescope is not in hands' do
      before do
        allow(DRCI).to receive(:in_hands?).with('telescope').and_return(false)
      end

      it 'does not store telescope' do
        expect(DRCMM).not_to receive(:store_telescope?)
        astrology.empty_hands
      end
    end
  end

  describe '#align_routine' do
    let(:astrology) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@divination_bones_storage, nil)
        a.instance_variable_set(:@divination_tool, nil)
        a.instance_variable_set(:@force_visions, false)
      end
    end

    context 'with future events skill' do
      it 'predicts event instead of aligning' do
        expect(DRCMM).to receive(:predict).with('event')
        expect(DRCMM).not_to receive(:align)
        astrology.align_routine('future events')
      end
    end

    context 'with regular skill' do
      it 'aligns to skill' do
        expect(DRCMM).to receive(:align).with('Arcana')
        astrology.align_routine('Arcana')
      end
    end

    context 'with bones storage configured' do
      before do
        astrology.instance_variable_set(:@divination_bones_storage, { 'container' => 'backpack' })
      end

      it 'rolls bones' do
        expect(DRCMM).to receive(:roll_bones).with({ 'container' => 'backpack' })
        astrology.align_routine('Arcana')
      end
    end

    context 'with divination tool configured' do
      before do
        astrology.instance_variable_set(:@divination_tool, { 'name' => 'mirror' })
      end

      it 'uses divination tool' do
        expect(DRCMM).to receive(:use_div_tool).with({ 'name' => 'mirror' })
        astrology.align_routine('Arcana')
      end
    end

    context 'with force_visions enabled' do
      before do
        astrology.instance_variable_set(:@force_visions, true)
        astrology.instance_variable_set(:@divination_bones_storage, { 'container' => 'backpack' })
      end

      it 'predicts future instead of using bones' do
        expect(DRCMM).not_to receive(:roll_bones)
        expect(DRCMM).to receive(:predict).with('future')
        astrology.align_routine('Arcana')
      end
    end
  end

  describe '#predict_all' do
    let(:astrology) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@prediction_pool_target, 7)
        a.instance_variable_set(:@astrology_prediction_skills_magic, 'Arcana')
        a.instance_variable_set(:@astrology_prediction_skills_lore, 'Scholarship')
        a.instance_variable_set(:@astrology_prediction_skills_offense, 'Tactics')
        a.instance_variable_set(:@astrology_prediction_skills_defense, 'Evasion')
        a.instance_variable_set(:@astrology_prediction_skills_survival, 'Outdoorsmanship')
        a.instance_variable_set(:@divination_bones_storage, nil)
        a.instance_variable_set(:@divination_tool, nil)
        a.instance_variable_set(:@force_visions, false)
      end
    end

    let(:pools) do
      {
        'magic'            => 8,
        'lore'             => 5,
        'survival'         => 7,
        'offensive combat' => 3,
        'defensive combat' => 9,
        'future events'    => 10
      }
    end

    before do
      allow(DRSkill).to receive(:getxp).with('Astrology').and_return(10)
    end

    it 'aligns for pools at or above target' do
      expect(astrology).to receive(:align_routine).with('Arcana') # magic = 8 >= 7
      expect(astrology).to receive(:align_routine).with('Outdoorsmanship') # survival = 7 >= 7
      expect(astrology).to receive(:align_routine).with('Evasion') # defense = 9 >= 7
      expect(astrology).to receive(:align_routine).with('future events') # future = 10 >= 7
      astrology.predict_all(pools)
    end

    it 'skips pools below target' do
      expect(astrology).not_to receive(:align_routine).with('Scholarship') # lore = 5 < 7
      expect(astrology).not_to receive(:align_routine).with('Tactics')     # offense = 3 < 7
      astrology.predict_all(pools)
    end

    context 'when astrology XP exceeds threshold' do
      before do
        allow(DRSkill).to receive(:getxp).with('Astrology').and_return(31)
      end

      it 'stops predicting early' do
        expect(astrology).not_to receive(:align_routine)
        astrology.predict_all(pools)
      end
    end
  end

  describe '#observe_routine' do
    let(:astrology) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@have_telescope, false)
        a.instance_variable_set(:@telescope_name, 'telescope')
        a.instance_variable_set(:@telescope_storage, {})
        a.instance_variable_set(:@injured_messages, constellations_data.observe_injured_messages)
      end
    end

    context 'without telescope' do
      it 'observes body with DRCMM' do
        expect(DRCMM).to receive(:observe).with('Katamba').and_return('You learned something useful')
        result = astrology.observe_routine('Katamba')
        expect(result).to be true
      end

      it 'returns false for unsuccessful observation' do
        allow(DRCMM).to receive(:observe).with('Katamba').and_return('Your search for')
        result = astrology.observe_routine('Katamba')
        expect(result).to be false
      end
    end

    context 'with telescope' do
      before do
        astrology.instance_variable_set(:@have_telescope, true)
      end

      it 'centers and peers through telescope' do
        expect(DRCMM).to receive(:center_telescope).with('Heart')
        expect(DRCMM).to receive(:peer_telescope).and_return(['You learned something useful', 'Roundtime: 5 sec.'])
        astrology.observe_routine('Heart')
      end
    end
  end

  describe '#do_buffs' do
    let(:astrology) { described_class.allocate }
    let(:settings_with_buffs) do
      OpenStruct.new(
        waggle_sets: {
          'astrology' => {
            'Aura Sight'       => { 'name' => 'Aura Sight', 'use_auto_mana' => true },
            'Read the Ripples' => { 'name' => 'Read the Ripples', 'use_auto_mana' => true }
          }
        }
      )
    end

    let(:mock_equipment_manager) { instance_double('EquipmentManager', empty_hands: nil) }

    before do
      astrology.instance_variable_set(:@equipment_manager, mock_equipment_manager)
    end

    context 'when settings is nil' do
      it 'returns early' do
        expect(DRCA).not_to receive(:cast_spells)
        astrology.do_buffs(nil)
      end
    end

    context 'when waggle_sets has no astrology key' do
      it 'returns early' do
        settings = OpenStruct.new(waggle_sets: {})
        expect(DRCA).not_to receive(:cast_spells)
        astrology.do_buffs(settings)
      end
    end

    context 'with astrology buffs configured' do
      before do
        DRSpells._set_active_spells({})
      end

      it 'separates Read the Ripples from other buffs' do
        astrology.do_buffs(settings_with_buffs)
        expect(astrology.instance_variable_get(:@rtr_data)).to eq({ 'name' => 'Read the Ripples', 'use_auto_mana' => true })
      end

      it 'casts non-RtR buffs' do
        expect(DRCA).to receive(:cast_spells).with(
          hash_including('Aura Sight'),
          settings_with_buffs
        )
        astrology.do_buffs(settings_with_buffs)
      end
    end

    context 'when all buffs are already active' do
      before do
        DRSpells._set_active_spells({ 'Aura Sight' => true })
      end

      it 'does not cast spells' do
        expect(DRCA).not_to receive(:cast_spells)
        astrology.do_buffs(settings_with_buffs)
      end
    end
  end

  describe '#visible_bodies' do
    let(:astrology) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@constellations, constellations_data.constellations)
      end
    end

    context 'when indoors' do
      before do
        allow(DRCMM).to receive(:observe).with('heavens').and_return("That's a bit hard to do while inside")
      end

      it 'returns nil and logs message' do
        expect(astrology.visible_bodies).to be_nil
        expect(messages).to include('Astrology: Must be outdoors to observe sky. Exiting.')
      end
    end
  end

  describe '#train_astrology' do
    let(:mock_equipment_manager) { instance_double('EquipmentManager', empty_hands: nil) }
    let(:astrology) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@constellations, constellations_data.constellations)
        a.instance_variable_set(:@finished_messages, constellations_data.observe_finished_messages)
        a.instance_variable_set(:@success_messages, constellations_data.observe_success_messages)
        a.instance_variable_set(:@injured_messages, constellations_data.observe_injured_messages)
        a.instance_variable_set(:@have_telescope, false)
        a.instance_variable_set(:@telescope_name, 'telescope')
        a.instance_variable_set(:@telescope_storage, {})
        a.instance_variable_set(:@prediction_pool_target, 7)
        a.instance_variable_set(:@equipment_manager, mock_equipment_manager)
        a.instance_variable_set(:@astrology_prediction_skills_magic, 'Arcana')
        a.instance_variable_set(:@astrology_prediction_skills_lore, 'Scholarship')
        a.instance_variable_set(:@astrology_prediction_skills_offense, 'Tactics')
        a.instance_variable_set(:@astrology_prediction_skills_defense, 'Evasion')
        a.instance_variable_set(:@astrology_prediction_skills_survival, 'Outdoorsmanship')
        a.instance_variable_set(:@divination_bones_storage, nil)
        a.instance_variable_set(:@divination_tool, nil)
        a.instance_variable_set(:@force_visions, false)
        a.instance_variable_set(:@astral_place_source, nil)
        a.instance_variable_set(:@astral_plane_destination, nil)
      end
    end

    context 'when settings is nil' do
      it 'exits with message' do
        astrology.train_astrology(nil)
        expect(messages).to include('Astrology: No settings provided. Exiting training loop.')
      end
    end

    context 'when astrology_training is not an array' do
      it 'exits with message' do
        settings = OpenStruct.new(astrology_training: 'observe')
        astrology.train_astrology(settings)
        expect(messages).to include('Astrology: astrology_training is not an array. Exiting training loop.')
      end
    end

    context 'when astrology_training is empty' do
      it 'exits with message' do
        settings = OpenStruct.new(astrology_training: [])
        astrology.train_astrology(settings)
        expect(messages).to include('Astrology: astrology_training is empty. Exiting training loop.')
      end
    end

    context 'when XP reaches threshold' do
      before do
        allow(DRSkill).to receive(:getxp).with('Astrology').and_return(33)
        allow(Lich::Util).to receive(:issue_command).and_return([])
      end

      it 'exits with completion message' do
        settings = OpenStruct.new(astrology_training: ['weather'])
        astrology.train_astrology(settings)
        expect(messages).to include('Astrology: Reached target Astrology XP. Training complete.')
      end
    end

    context 'with unknown training task' do
      before do
        # Start with low XP so it enters the loop, then return high XP to exit
        allow(DRSkill).to receive(:getxp).with('Astrology').and_return(10, 33)
        allow(Lich::Util).to receive(:issue_command).and_return([])
      end

      it 'logs warning and continues' do
        settings = OpenStruct.new(astrology_training: ['unknown_task'])
        astrology.train_astrology(settings)
        expect(messages).to include("Astrology: Unknown training task 'unknown_task'. Skipping.")
      end
    end
  end
end
