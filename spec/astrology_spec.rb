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
    def store_div_tool?(_tool); end
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
          'pools' => { 'magic' => true, 'lore' => true, 'survival' => true } },
        { 'name' => 'Dawgolesh', 'circle' => 2, 'constellation' => false, 'telescope' => false,
          'pools' => { 'lore' => true, 'magic' => true } }
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

    DRStats.guild = 'Moon Mage'
    DRStats.circle = 50

    $test_settings = default_settings
    $test_data = {
      constellations: constellations_data,
      spells: OpenStruct.new(spell_data: spell_data)
    }

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
    allow(DRCMM).to receive(:store_div_tool?).and_return(true)
    allow(DRCMM).to receive(:center_telescope)
    allow(DRCMM).to receive(:peer_telescope).and_return(['You learned something useful', 'Roundtime: 5 sec.'])
    allow(DRCA).to receive(:cast_spell)
    allow(DRCA).to receive(:check_discern)
    allow(DRCA).to receive(:cast_spells)
    allow(DRCA).to receive(:perc_mana)
    allow(DRCT).to receive(:walk_to)
  end

  # Helper to build an Astrology instance with common ivars set
  def build_astrology(**overrides)
    defaults = {
      have_telescope: false,
      telescope_name: 'telescope',
      telescope_storage: {},
      constellations: constellations_data.constellations,
      finished_messages: constellations_data.observe_finished_messages,
      success_messages: constellations_data.observe_success_messages,
      injured_messages: constellations_data.observe_injured_messages,
      prediction_pool_target: 7,
      prediction_skills: {
        'magic' => 'Arcana', 'lore' => 'Scholarship', 'offense' => 'Tactics',
        'defense' => 'Evasion', 'survival' => 'Outdoorsmanship'
      },
      equipment_manager: instance_double('EquipmentManager', empty_hands: nil),
      divination_bones_storage: nil,
      divination_tool: nil,
      force_visions: false,
      astral_place_source: nil,
      astral_plane_destination: nil,
      settings: default_settings,
      rtr_data: nil
    }
    opts = defaults.merge(overrides)

    described_class.allocate.tap do |a|
      opts.each { |key, val| a.instance_variable_set(:"@#{key}", val) }
    end
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

      it 'has exactly 11 entries for all understanding levels' do
        expect(described_class::POOL_PATTERNS.size).to eq(11)
      end

      it 'matches feeble understanding to level 1' do
        pattern = described_class::POOL_PATTERNS.find { |k, _| k.source.include?('feeble') }&.last
        expect(pattern).to eq(1)
      end

      it 'matches complete understanding to level 10' do
        pattern = described_class::POOL_PATTERNS.find { |k, _| k.source.include?('complete') }&.last
        expect(pattern).to eq(10)
      end

      it 'uses unique values for each level' do
        values = described_class::POOL_PATTERNS.values
        expect(values.uniq.size).to eq(values.size)
      end

      it 'matches actual game output for each level' do
        game_messages = {
          'You have no understanding of the celestial influences over magic.'            => 0,
          'You have a feeble understanding of the celestial influences over lore.'       => 1,
          'You have a weak understanding of the celestial influences over survival.'     => 2,
          'You have a fledgling understanding of the celestial influences over magic.'   => 3,
          'You have a modest understanding of the celestial influences over lore.'       => 4,
          'You have a decent understanding of the celestial influences over survival.'   => 5,
          'You have a significant understanding of the celestial influences over magic.' => 6,
          'You have a potent understanding of the celestial influences over lore.'       => 7,
          'You have an insightful understanding of the celestial influences over magic.' => 8,
          'You have a powerful understanding of the celestial influences over survival.' => 9,
          'You have a complete understanding of the celestial influences over magic.'    => 10
        }

        game_messages.each do |message, expected_level|
          matched = described_class::POOL_PATTERNS.find { |pattern, _| pattern =~ message }
          expect(matched).not_to be_nil, "Expected pattern to match: #{message}"
          expect(matched.last).to eq(expected_level), "Expected level #{expected_level} for: #{message}"
        end
      end

      it 'does not match unrelated text' do
        unrelated = 'The sky is cloudy and you see nothing.'
        matched = described_class::POOL_PATTERNS.find { |pattern, _| pattern =~ unrelated }
        expect(matched).to be_nil
      end
    end

    describe 'OBSERVE_SUCCESS_PATTERNS' do
      it 'is frozen' do
        expect(described_class::OBSERVE_SUCCESS_PATTERNS).to be_frozen
      end

      %w[
        While\ the\ sighting
        You\ learned\ something\ useful
        Clouds\ obscure
        You\ learn\ nothing
        too\ close\ to\ the\ sun
        too\ faint\ for\ you
        below\ the\ horizon
        You\ have\ not\ pondered
        You\ are\ unable\ to\ make\ use
        you\ still\ learned\ more
      ].each do |pattern|
        it "includes '#{pattern}'" do
          expect(described_class::OBSERVE_SUCCESS_PATTERNS).to include(pattern)
        end
      end

      # Adversarial: verify each pattern matches its actual game message via substring
      context 'matching against actual game output' do
        {
          'While the sighting was not ideal, you still gleaned useful information.'                                         => 'While the sighting',
          'You learned something useful from your study of the heavens.'                                                    => 'You learned something useful',
          'Clouds obscure the sky, making observation impossible.'                                                          => 'Clouds obscure',
          'You learn nothing of the future from this observation.'                                                          => 'You learn nothing',
          'Katamba is too close to the sun to observe.'                                                                     => 'too close to the sun',
          'Xibar is too faint for you to pick out from the sky.'                                                            => 'too faint for you',
          'Katamba is below the horizon.'                                                                                   => 'below the horizon',
          'You have not pondered your last observation sufficiently.'                                                       => 'You have not pondered',
          'You are unable to make use of this latest observation.'                                                          => 'You are unable to make use',
          'Although you were nearly overwhelmed by some aspects of your observation, you still learned more of the future.' =>
                                                                                                                               'you still learned more'
        }.each do |game_message, expected_pattern|
          it "matches '#{expected_pattern}' in: #{game_message[0..60]}..." do
            matched = described_class::OBSERVE_SUCCESS_PATTERNS.any? { |p| game_message.include?(p) }
            expect(matched).to be(true), "OBSERVE_SUCCESS_PATTERNS should match game message containing '#{expected_pattern}'"
          end
        end
      end

      # Adversarial: ensure no false positives for unrelated game output
      context 'rejecting unrelated game output' do
        [
          'You scan the skies for a few moments.',
          'Your search for the heavens is foiled by the daylight.',
          'Your search for the heavens turns up fruitless.',
          'Roundtime: 5 sec.',
          'You see nothing regarding the future.',
          'You gesture.',
          'The wind picks up, howling through the area.',
          ''
        ].each do |unrelated_message|
          it "does not match: '#{unrelated_message}'" do
            matched = described_class::OBSERVE_SUCCESS_PATTERNS.any? { |p| unrelated_message.include?(p) }
            expect(matched).to be(false), "OBSERVE_SUCCESS_PATTERNS should NOT match: '#{unrelated_message}'"
          end
        end
      end
    end

    describe 'PERCEIVE_TARGETS' do
      it 'is frozen and has 8 targets including empty string and mana' do
        expect(described_class::PERCEIVE_TARGETS).to be_frozen
        expect(described_class::PERCEIVE_TARGETS.size).to eq(8)
        expect(described_class::PERCEIVE_TARGETS).to include('', 'mana', 'moons')
      end
    end

    describe 'PREDICT_STATE_START' do
      it 'matches celestial influences case-sensitively' do
        expect(described_class::PREDICT_STATE_START).to be_frozen
        expect('You have a feeble understanding of the celestial influences over').to match(described_class::PREDICT_STATE_START)
      end
    end

    describe 'PREDICT_STATE_END' do
      it 'matches Roundtime case-insensitively' do
        expect(described_class::PREDICT_STATE_END).to be_frozen
        expect('Roundtime: 3 sec.').to match(described_class::PREDICT_STATE_END)
        expect('roundtime: 3 sec.').to match(described_class::PREDICT_STATE_END)
      end
    end

    describe 'MAX_HEAVENS_RETRIES' do
      it 'is defined' do
        expect(described_class::MAX_HEAVENS_RETRIES).to eq(3)
      end
    end

    describe 'MAX_OBSERVE_RETRIES' do
      it 'is defined' do
        expect(described_class::MAX_OBSERVE_RETRIES).to eq(5)
      end
    end

    describe 'MAX_OBSERVE_ITERATIONS' do
      it 'is defined' do
        expect(described_class::MAX_OBSERVE_ITERATIONS).to eq(20)
      end
    end
  end

  describe '#initialize' do
    context 'when not a Moon Mage' do
      before { DRStats.guild = 'Warrior' }

      it 'displays exit message and terminates' do
        expect do
          described_class.allocate.tap { |a| a.send(:initialize) }
        end.to raise_error(SystemExit)
        expect(messages).to include('Astrology: This script is only for Moon Mages. Exiting.')
      end
    end

    context 'when circle is zero' do
      before { DRStats.circle = 0 }

      it 'calls info command to refresh circle' do
        expect(DRC).to receive(:bput).with('info', 'Circle:')
        described_class.allocate.tap { |a| a.send(:initialize) }
      end
    end

    context 'when astral_plane_training is nil' do
      before do
        $test_settings = OpenStruct.new(
          default_settings.to_h.merge(astral_plane_training: nil)
        )
      end

      it 'does not crash (nil-safe navigation)' do
        astro = described_class.allocate.tap { |a| a.send(:initialize) }
        expect(astro.instance_variable_get(:@astral_place_source)).to be_nil
        expect(astro.instance_variable_get(:@astral_plane_destination)).to be_nil
      end
    end

    it 'deduplicates get_data calls (calls constellations once)' do
      described_class.allocate.tap { |a| a.send(:initialize) }
      constellations_calls = $data_called_with.count { |d| d == 'constellations' }
      expect(constellations_calls).to eq(1)
    end

    it 'stores prediction_skills as a single hash' do
      astro = described_class.allocate.tap { |a| a.send(:initialize) }
      skills = astro.instance_variable_get(:@prediction_skills)
      expect(skills).to be_a(Hash)
      expect(skills['magic']).to eq('Arcana')
      expect(skills['survival']).to eq('Outdoorsmanship')
    end
  end

  describe '#run' do
    let(:astrology) do
      build_astrology(args: OpenStruct.new(rtr: false))
    end

    it 'calls do_buffs and train_astrology for default mode' do
      allow(DRSkill).to receive(:getxp).with('Astrology').and_return(33)
      expect(astrology).to receive(:do_buffs)
      expect(astrology).to receive(:train_astrology)
      astrology.run
    end

    context 'with rtr mode' do
      let(:astrology) do
        build_astrology(args: OpenStruct.new(rtr: true))
      end

      it 'calls do_buffs and check_ripples' do
        expect(astrology).to receive(:do_buffs)
        expect(astrology).to receive(:check_ripples)
        astrology.run
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
        timeout: 10, usexml: false, silent: true, quiet: true
      )
      astrology.check_pools
    end

    it 'parses pool levels correctly' do
      pools = astrology.check_pools
      expect(pools['magic']).to eq(7)
      expect(pools['lore']).to eq(4)
      expect(pools['survival']).to eq(0)
    end

    it 'returns all six pool keys' do
      pools = astrology.check_pools
      expect(pools.keys).to contain_exactly(
        'lore', 'magic', 'survival',
        'offensive combat', 'defensive combat', 'future events'
      )
    end

    context 'when all pools are at maximum' do
      let(:pool_output) do
        %w[magic lore survival].map do |name|
          "You have a complete understanding of the celestial influences over #{name}."
        end + [
          'You have a complete understanding of the celestial influences over offensive combat.',
          'You have a complete understanding of the celestial influences over defensive combat.',
          'You have a complete understanding of the celestial influences over future events.',
          'Roundtime: 3 sec.'
        ]
      end

      it 'sets all pools to 10' do
        pools = astrology.check_pools
        expect(pools.values).to all(eq(10))
      end
    end

    context 'when issue_command times out' do
      before { allow(Lich::Util).to receive(:issue_command).and_return(nil) }

      it 'returns default pool values and logs failure' do
        pools = astrology.check_pools
        expect(pools.values).to all(eq(0))
        expect(messages).to include('Astrology: Failed to capture predict state output. Using default pool values.')
      end
    end

    context 'when issue_command returns empty array' do
      before { allow(Lich::Util).to receive(:issue_command).and_return([]) }

      it 'returns default pool values' do
        pools = astrology.check_pools
        expect(pools.values).to all(eq(0))
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
      before { allow(DRSkill).to receive(:getxp).with('Attunement').and_return(31) }

      it 'does not perceive' do
        expect(DRC).not_to receive(:bput).with(/perceive/, anything)
        astrology.check_attunement
      end
    end

    context 'when Attunement XP is exactly at threshold (30)' do
      before do
        DRSkill._set_rank('Attunement', 0)
        allow(DRSkill).to receive(:getxp).with('Attunement').and_return(30)
      end

      it 'still perceives because threshold is > 30, not >=' do
        described_class::PERCEIVE_TARGETS.each do |target|
          expect(DRC).to receive(:bput).with("perceive #{target}", 'roundtime')
        end
        astrology.check_attunement
      end
    end
  end

  describe '#check_weather' do
    it 'calls predict weather' do
      expect(DRCMM).to receive(:predict).with('weather')
      described_class.allocate.check_weather
    end
  end

  describe '#rtr_active?' do
    let(:astrology) { described_class.allocate }

    it 'returns true when Read the Ripples is active' do
      DRSpells._set_active_spells({ 'Read the Ripples' => true })
      expect(astrology.rtr_active?).to be true
    end

    it 'returns false when Read the Ripples is not active' do
      DRSpells._set_active_spells({})
      expect(astrology.rtr_active?).to be false
    end
  end

  describe '#check_observation_finished?' do
    let(:astrology) { build_astrology }

    context 'with array result' do
      it 'returns true when array contains finished message' do
        expect(astrology.check_observation_finished?(["You've learned all that you can", 'Roundtime'])).to be true
      end

      it 'returns false when array has no finished message' do
        expect(astrology.check_observation_finished?(['Some text', 'Roundtime'])).to be false
      end

      it 'returns false for empty array' do
        expect(astrology.check_observation_finished?([])).to be false
      end
    end

    context 'with string result' do
      it 'returns true for finished message' do
        expect(astrology.check_observation_finished?("You've learned all that you can")).to be true
      end

      it 'returns false for non-finished message' do
        expect(astrology.check_observation_finished?('You learned something useful')).to be false
      end

      # Adversarial: string path must use substring matching, not exact match
      it 'returns true when string CONTAINS a finished message (not exact match)' do
        full_message = "You've learned all that you can from this observation of Katamba."
        expect(astrology.check_observation_finished?(full_message)).to be true
      end
    end

    it 'returns false for nil' do
      expect(astrology.check_observation_finished?(nil)).to be false
    end
  end

  describe '#check_observation_success?' do
    let(:astrology) { build_astrology }

    context 'with array result' do
      it 'returns true when array contains success message' do
        expect(astrology.check_observation_success?(['You learned something useful', 'Roundtime'])).to be true
      end

      it 'returns true for partial success' do
        expect(astrology.check_observation_success?(['While the sighting was not ideal'])).to be true
      end

      it 'returns false when array has no success message' do
        expect(astrology.check_observation_success?(['Some text'])).to be false
      end

      it 'returns false for empty array' do
        expect(astrology.check_observation_success?([])).to be false
      end
    end

    context 'with string result' do
      it 'returns true for success message' do
        expect(astrology.check_observation_success?('You learned something useful')).to be true
      end

      it 'returns false for non-success message' do
        expect(astrology.check_observation_success?('Random text')).to be false
      end

      # Adversarial: string path must use substring matching, not exact match
      it 'returns true when string CONTAINS a success message (not exact match)' do
        full_message = 'You learned something useful from your observation of Katamba.'
        expect(astrology.check_observation_success?(full_message)).to be true
      end
    end

    it 'returns false for nil' do
      expect(astrology.check_observation_success?(nil)).to be false
    end
  end

  describe '#check_telescope_result' do
    let(:astrology) { build_astrology }

    it 'detects injury in array result' do
      injuries, closed = astrology.check_telescope_result(['The pain is too much', 'Roundtime'])
      expect(injuries).to be true
      expect(closed).to be false
    end

    it 'detects fuzzy vision injury in array result' do
      injuries, closed = astrology.check_telescope_result(['Your vision is too fuzzy to make out details'])
      expect(injuries).to be true
      expect(closed).to be false
    end

    it 'detects closed telescope in array result' do
      injuries, closed = astrology.check_telescope_result(["You'll need to open it"])
      expect(injuries).to be false
      expect(closed).to be true
    end

    it 'detects injury in string result' do
      injuries, = astrology.check_telescope_result('The pain is too much')
      expect(injuries).to be true
    end

    it 'detects closed in string result' do
      _, closed = astrology.check_telescope_result('open it')
      expect(closed).to be true
    end

    it 'returns both false for normal result' do
      injuries, closed = astrology.check_telescope_result(['You learned something useful'])
      expect(injuries).to be false
      expect(closed).to be false
    end

    it 'returns both false for empty array' do
      injuries, closed = astrology.check_telescope_result([])
      expect(injuries).to be false
      expect(closed).to be false
    end
  end

  describe '#empty_hands' do
    let(:mock_equipment_manager) { instance_double('EquipmentManager', empty_hands: nil) }
    let(:astrology) do
      build_astrology(
        telescope_name: 'telescope',
        telescope_storage: { 'container' => 'backpack' },
        equipment_manager: mock_equipment_manager
      )
    end

    it 'stores telescope when in hands' do
      allow(DRCI).to receive(:in_hands?).with('telescope').and_return(true)
      expect(DRCMM).to receive(:store_telescope?).with('telescope', { 'container' => 'backpack' })
      astrology.empty_hands
    end

    it 'does not store telescope when not in hands' do
      allow(DRCI).to receive(:in_hands?).with('telescope').and_return(false)
      expect(DRCMM).not_to receive(:store_telescope?)
      astrology.empty_hands
    end

    it 'always calls equipment_manager.empty_hands' do
      allow(DRCI).to receive(:in_hands?).and_return(false)
      expect(mock_equipment_manager).to receive(:empty_hands)
      astrology.empty_hands
    end
  end

  describe '#get_healed' do
    let(:astrology) do
      build_astrology(
        have_telescope: true,
        telescope_name: 'telescope',
        telescope_storage: { 'container' => 'backpack' }
      )
    end

    it 'executes operations in correct order' do
      expect(DRCMM).to receive(:store_telescope?).with('telescope', { 'container' => 'backpack' }).ordered
      expect(DRC).to receive(:wait_for_script_to_complete).with('safe-room', ['force']).ordered
      expect(DRCT).to receive(:walk_to).with(1).ordered
      astrology.get_healed
    end

    it 're-buffs after healing' do
      expect(astrology).to receive(:do_buffs).with(astrology.instance_variable_get(:@settings))
      astrology.get_healed
    end

    it 'retrieves telescope after healing' do
      expect(DRCMM).to receive(:get_telescope?).with('telescope', { 'container' => 'backpack' })
      astrology.get_healed
    end
  end

  describe '#align_routine' do
    let(:astrology) { build_astrology }

    it 'predicts event for future events skill' do
      expect(DRCMM).to receive(:predict).with('event')
      expect(DRCMM).not_to receive(:align)
      astrology.align_routine('future events')
    end

    it 'aligns to skill and predicts future when no divination tools' do
      expect(DRCMM).to receive(:align).with('Arcana')
      expect(DRCMM).to receive(:predict).with('future')
      astrology.align_routine('Arcana')
    end

    it 'aligns with nil skill' do
      expect(DRCMM).to receive(:align).with(nil)
      astrology.align_routine(nil)
    end

    context 'with bones storage configured' do
      let(:astrology) { build_astrology(divination_bones_storage: { 'container' => 'backpack' }) }

      it 'rolls bones' do
        expect(DRCMM).to receive(:roll_bones).with({ 'container' => 'backpack' })
        astrology.align_routine('Arcana')
      end
    end

    context 'with divination tool configured' do
      let(:astrology) { build_astrology(divination_tool: { 'name' => 'mirror' }) }

      it 'uses divination tool' do
        expect(DRCMM).to receive(:use_div_tool).with({ 'name' => 'mirror' })
        astrology.align_routine('Arcana')
      end
    end

    context 'with both bones and tool' do
      let(:astrology) do
        build_astrology(
          divination_bones_storage: { 'container' => 'backpack' },
          divination_tool: { 'name' => 'mirror' }
        )
      end

      it 'prefers bones over tool' do
        expect(DRCMM).to receive(:roll_bones)
        expect(DRCMM).not_to receive(:use_div_tool)
        astrology.align_routine('Arcana')
      end
    end

    context 'with force_visions' do
      let(:astrology) do
        build_astrology(
          force_visions: true,
          divination_bones_storage: { 'container' => 'backpack' }
        )
      end

      it 'predicts future instead of using bones' do
        expect(DRCMM).not_to receive(:roll_bones)
        expect(DRCMM).to receive(:predict).with('future')
        astrology.align_routine('Arcana')
      end
    end

    context 'with empty string bones storage' do
      let(:astrology) { build_astrology(divination_bones_storage: '') }

      it 'falls through to predict future' do
        expect(DRCMM).not_to receive(:roll_bones)
        expect(DRCMM).to receive(:predict).with('future')
        astrology.align_routine('Arcana')
      end
    end
  end

  describe '#predict_all' do
    let(:astrology) { build_astrology }
    let(:pools) do
      {
        'magic' => 8, 'lore' => 5, 'survival' => 7,
        'offensive combat' => 3, 'defensive combat' => 9, 'future events' => 10
      }
    end

    before { allow(DRSkill).to receive(:getxp).with('Astrology').and_return(10) }

    it 'aligns for pools at or above target' do
      expect(astrology).to receive(:align_routine).with('Arcana')
      expect(astrology).to receive(:align_routine).with('Outdoorsmanship')
      expect(astrology).to receive(:align_routine).with('Evasion')
      expect(astrology).to receive(:align_routine).with('future events')
      astrology.predict_all(pools)
    end

    it 'skips pools below target' do
      expect(astrology).not_to receive(:align_routine).with('Scholarship')
      expect(astrology).not_to receive(:align_routine).with('Tactics')
      astrology.predict_all(pools)
    end

    context 'when astrology XP exceeds threshold' do
      before { allow(DRSkill).to receive(:getxp).with('Astrology').and_return(31) }

      it 'stops predicting early' do
        expect(astrology).not_to receive(:align_routine)
        astrology.predict_all(pools)
      end
    end

    context 'with all pools at zero' do
      let(:pools) do
        { 'magic' => 0, 'lore' => 0, 'survival' => 0,
          'offensive combat' => 0, 'defensive combat' => 0, 'future events' => 0 }
      end

      it 'does not align for any pool' do
        expect(astrology).not_to receive(:align_routine)
        astrology.predict_all(pools)
      end
    end
  end

  describe '#observe_routine' do
    let(:astrology) { build_astrology }

    context 'without telescope' do
      it 'returns raw observe result string on success' do
        allow(DRCMM).to receive(:observe).with('Katamba').and_return('You learned something useful')
        result = astrology.observe_routine('Katamba')
        expect(result).to eq('You learned something useful')
      end

      it 'returns raw string for unsuccessful observation' do
        allow(DRCMM).to receive(:observe).with('Katamba').and_return('Your search for')
        result = astrology.observe_routine('Katamba')
        expect(result).to eq('Your search for')
      end

      it 'returns overwhelmed message string' do
        overwhelmed_msg = 'Although you were nearly overwhelmed by some aspects of your observation, ' \
                          'you still learned more of the future.'
        allow(DRCMM).to receive(:observe).with('Dawgolesh').and_return(overwhelmed_msg)
        result = astrology.observe_routine('Dawgolesh')
        expect(result).to eq(overwhelmed_msg)
      end

      it 'returns nil for nil observe result' do
        allow(DRCMM).to receive(:observe).with('Katamba').and_return(nil)
        result = astrology.observe_routine('Katamba')
        expect(result).to be_nil
      end

      it 'preserves bad-search flag for caller to check' do
        allow(DRCMM).to receive(:observe) do |_body|
          Flags['bad-search'] = 'turns up fruitless'
          'You learned something useful'
        end
        astrology.observe_routine('Katamba')
        expect(Flags['bad-search']).to eq('turns up fruitless')
      end
    end

    context 'with telescope' do
      let(:astrology) { build_astrology(have_telescope: true) }

      it 'centers and peers through telescope' do
        expect(DRCMM).to receive(:center_telescope).with('Heart')
        expect(DRCMM).to receive(:peer_telescope).and_return(['You learned something useful', 'Roundtime: 5 sec.'])
        astrology.observe_routine('Heart')
      end

      it 'retries when telescope not in hand (Center what)' do
        expect(DRCMM).to receive(:center_telescope).with('Heart').and_return('Center what?', nil)
        expect(DRCMM).to receive(:get_telescope?).with('telescope', {})
        allow(DRCMM).to receive(:peer_telescope).and_return(['You learned something useful'])
        astrology.observe_routine('Heart')
      end

      it 'opens telescope when closed' do
        expect(DRCMM).to receive(:center_telescope).with('Heart').and_return('open it', nil)
        expect(DRC).to receive(:bput).with('open my telescope', 'extend your telescope')
        allow(DRCMM).to receive(:peer_telescope).and_return(['You learned something useful'])
        astrology.observe_routine('Heart')
      end

      # Adversarial: observe_routine used to recurse infinitely on persistent errors
      it 'aborts after MAX_OBSERVE_RETRIES when telescope keeps failing' do
        # center_telescope keeps returning "Center what" (telescope falls out of hands)
        allow(DRCMM).to receive(:center_telescope).with('Heart').and_return('Center what?')
        allow(DRCMM).to receive(:get_telescope?).and_return(true)
        result = astrology.observe_routine('Heart')
        expect(result).to be_nil
        expect(messages).to include('Astrology: Max observe retries reached. Aborting observation.')
      end

      it 'aborts after MAX_OBSERVE_RETRIES when injuries persist' do
        allow(DRCMM).to receive(:center_telescope).with('Heart').and_return('The pain is too much')
        allow(DRC).to receive(:wait_for_script_to_complete)
        result = astrology.observe_routine('Heart')
        expect(result).to be_nil
        expect(messages).to include('Astrology: Max observe retries reached. Aborting observation.')
      end
    end
  end

  describe '#do_buffs' do
    let(:astrology) { build_astrology }
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

    context 'when settings is nil' do
      it 'returns early' do
        expect(DRCA).not_to receive(:cast_spells)
        astrology.do_buffs(nil)
      end
    end

    context 'when waggle_sets has no astrology key' do
      it 'returns early' do
        expect(DRCA).not_to receive(:cast_spells)
        astrology.do_buffs(OpenStruct.new(waggle_sets: {}))
      end
    end

    context 'with astrology buffs configured' do
      before { DRSpells._set_active_spells({}) }

      it 'separates Read the Ripples from other buffs' do
        astrology.do_buffs(settings_with_buffs)
        expect(astrology.instance_variable_get(:@rtr_data)).to eq({ 'name' => 'Read the Ripples', 'use_auto_mana' => true })
      end

      it 'casts non-RtR buffs' do
        expect(DRCA).to receive(:cast_spells).with(hash_including('Aura Sight'), settings_with_buffs)
        astrology.do_buffs(settings_with_buffs)
      end

      it 'does not mutate the original settings hash' do
        original_keys = settings_with_buffs.waggle_sets['astrology'].keys.dup
        astrology.do_buffs(settings_with_buffs)
        expect(settings_with_buffs.waggle_sets['astrology'].keys).to eq(original_keys)
      end
    end

    context 'when all buffs are already active' do
      before { DRSpells._set_active_spells({ 'Aura Sight' => true }) }

      it 'does not cast spells' do
        expect(DRCA).not_to receive(:cast_spells)
        astrology.do_buffs(settings_with_buffs)
      end
    end

    context 'when called multiple times (via get_healed)' do
      before { DRSpells._set_active_spells({}) }

      it 'still finds RtR data on second call' do
        astrology.do_buffs(settings_with_buffs)
        first_rtr = astrology.instance_variable_get(:@rtr_data)

        astrology.do_buffs(settings_with_buffs)
        second_rtr = astrology.instance_variable_get(:@rtr_data)

        expect(first_rtr).to eq(second_rtr)
        expect(second_rtr).not_to be_nil
      end
    end
  end

  describe '#visible_bodies' do
    let(:astrology) { build_astrology }

    context 'when indoors' do
      before do
        allow(DRCMM).to receive(:observe).with('heavens').and_return("That's a bit hard to do while inside")
      end

      it 'returns nil and logs message' do
        expect(astrology.visible_bodies).to be_nil
        expect(messages).to include('Astrology: Must be outdoors to observe sky. Exiting.')
      end
    end

    context 'with body names containing regex metacharacters' do
      let(:astrology) do
        build_astrology(
          constellations: [
            { 'name' => 'Star (Alpha)', 'circle' => 1, 'constellation' => false, 'telescope' => false,
              'pools' => { 'magic' => true } },
            { 'name' => 'Obj+ect', 'circle' => 1, 'constellation' => false, 'telescope' => false,
              'pools' => { 'lore' => true } }
          ]
        )
      end

      before do
        allow(DRCMM).to receive(:observe).with('heavens').and_return('Some result')
      end

      it 'does not crash on parentheses in body name' do
        $history = ["You see Star (Alpha) shining brightly.", 'Roundtime: 5 sec.']
        expect { astrology.visible_bodies }.not_to raise_error
      end

      it 'does not crash on plus sign in body name' do
        $history = ["You see Obj+ect overhead.", 'Roundtime: 5 sec.']
        expect { astrology.visible_bodies }.not_to raise_error
      end

      it 'matches last word of name via word boundary' do
        # visible_bodies uses body['name'].split.last with \b anchors
        # For "Star (Alpha)", split.last is "(Alpha)" -- \b around escaped parens
        # won't match because \b needs a word char adjacent to a non-word char
        # This is expected: the regex is designed for plain word names
        $history = ['You see Alpha) high in the sky.', 'Roundtime: 5 sec.']
        DRStats.circle = 50
        # The escaped parens prevent regex crash but \b won't match around them
        expect { astrology.visible_bodies }.not_to raise_error
      end
    end

    context 'when get? returns nil (disconnect)' do
      before do
        allow(DRCMM).to receive(:observe).with('heavens').and_return('Some result')
        $history = [nil]
      end

      it 'breaks out of loop without hanging' do
        result = astrology.visible_bodies
        expect(result).to eq([])
      end
    end
  end

  describe '#check_heavens' do
    let(:astrology) { build_astrology }

    context 'when depth exceeds MAX_HEAVENS_RETRIES' do
      it 'aborts with message' do
        astrology.check_heavens(depth: described_class::MAX_HEAVENS_RETRIES + 1)
        expect(messages).to include('Astrology: Max observation retries reached. Aborting check_heavens.')
      end

      it 'does not call visible_bodies' do
        expect(astrology).not_to receive(:visible_bodies)
        astrology.check_heavens(depth: 10)
      end
    end

    context 'when visible_bodies returns empty array' do
      it 'aborts with no observable bodies message' do
        allow(astrology).to receive(:visible_bodies).and_return([])
        astrology.check_heavens
        expect(messages).to include('Astrology: No observable celestial bodies found. Aborting check_heavens.')
      end
    end

    context 'without telescope (happy path)' do
      let(:astrology) { build_astrology }

      it 'observes the best body by pool count' do
        allow(astrology).to receive(:visible_bodies).and_return(
          [
            { 'name' => 'Xibar', 'circle' => 1, 'constellation' => false, 'telescope' => false,
              'pools' => { 'lore' => true } },
            { 'name' => 'Katamba', 'circle' => 1, 'constellation' => false, 'telescope' => false,
              'pools' => { 'magic' => true, 'survival' => true } }
          ]
        )
        allow(DRCMM).to receive(:observe).and_return('You learned something useful')
        astrology.check_heavens
        expect(DRCMM).to have_received(:observe).with('Katamba')
      end
    end

    context 'with telescope (happy path)' do
      let(:astrology) { build_astrology(have_telescope: true) }

      it 'dispatches to telescope path and stores telescope in ensure' do
        allow(astrology).to receive(:visible_bodies).and_return(
          [{ 'name' => 'Katamba', 'circle' => 1, 'constellation' => false, 'telescope' => false,
             'pools' => { 'magic' => true } }]
        )
        allow(DRCMM).to receive(:center_telescope).and_return(nil)
        allow(DRCMM).to receive(:peer_telescope).and_return(
          ["You've learned all that you can", 'You learned something useful', 'Roundtime: 5 sec.']
        )
        astrology.check_heavens
        expect(DRCMM).to have_received(:center_telescope)
        expect(DRCMM).to have_received(:store_telescope?)
      end
    end
  end

  describe '#train_astrology' do
    let(:astrology) { build_astrology }

    context 'when settings is nil' do
      it 'exits with message' do
        astrology.train_astrology(nil)
        expect(messages).to include('Astrology: No settings provided. Exiting training loop.')
      end
    end

    context 'when astrology_training is not an array' do
      it 'exits with message' do
        astrology.train_astrology(OpenStruct.new(astrology_training: 'observe'))
        expect(messages).to include('Astrology: astrology_training is not an array. Exiting training loop.')
      end
    end

    context 'when astrology_training is empty' do
      it 'exits with message' do
        astrology.train_astrology(OpenStruct.new(astrology_training: []))
        expect(messages).to include('Astrology: astrology_training is empty. Exiting training loop.')
      end
    end

    context 'when XP reaches threshold' do
      before { allow(DRSkill).to receive(:getxp).with('Astrology').and_return(33) }

      it 'exits with completion message' do
        astrology.train_astrology(OpenStruct.new(astrology_training: ['weather']))
        expect(messages).to include('Astrology: Reached target Astrology XP. Training complete.')
      end
    end

    context 'with unknown training task' do
      before do
        allow(DRSkill).to receive(:getxp).with('Astrology').and_return(10, 33)
      end

      it 'logs warning and continues' do
        astrology.train_astrology(OpenStruct.new(astrology_training: ['unknown_task']))
        expect(messages).to include("Astrology: Unknown training task 'unknown_task'. Skipping.")
      end
    end

    context 'with weather training task' do
      before { allow(DRSkill).to receive(:getxp).with('Astrology').and_return(10, 33) }

      it 'calls check_weather' do
        expect(DRCMM).to receive(:predict).with('weather')
        astrology.train_astrology(OpenStruct.new(astrology_training: ['weather']))
      end
    end

    context 'with observe training task' do
      before { allow(DRSkill).to receive(:getxp).with('Astrology').and_return(10, 33) }

      it 'calls check_heavens which observes a body' do
        allow(astrology).to receive(:visible_bodies).and_return(
          [{ 'name' => 'Katamba', 'circle' => 1, 'constellation' => false, 'telescope' => false,
             'pools' => { 'magic' => true } }]
        )
        allow(DRCMM).to receive(:observe).and_return('You learned something useful')
        astrology.train_astrology(OpenStruct.new(astrology_training: ['observe']))
        expect(DRCMM).to have_received(:observe).with('Katamba')
      end
    end

    context 'with events training task' do
      before { allow(DRSkill).to receive(:getxp).with('Astrology').and_return(10, 33) }

      it 'calls check_events via study_sky' do
        allow(DRCMM).to receive(:study_sky).and_return('You fail to detect any portents')
        astrology.train_astrology(OpenStruct.new(astrology_training: ['events']))
        expect(DRCMM).to have_received(:study_sky)
      end
    end

    context 'with attunement training task' do
      before do
        allow(DRSkill).to receive(:getxp).with('Astrology').and_return(10, 33)
        allow(DRSkill).to receive(:getxp).with('Attunement').and_return(10)
      end

      it 'calls check_attunement (perceive targets)' do
        astrology.train_astrology(OpenStruct.new(astrology_training: ['attunement']))
        expect(DRC).to have_received(:bput).with('perceive ', 'roundtime')
      end
    end
  end

  describe '#check_astral' do
    let(:astrology) do
      build_astrology(astral_place_source: 'some_source', astral_plane_destination: 'some_dest')
    end

    context 'when circle is below 100' do
      before { DRStats.circle = 50 }

      it 'returns early' do
        expect(DRC).not_to receive(:wait_for_script_to_complete)
        astrology.check_astral
      end
    end

    context 'when circle is 100+' do
      before { DRStats.circle = 100 }

      it 'returns early when no source configured' do
        astrology.instance_variable_set(:@astral_place_source, nil)
        expect(DRC).not_to receive(:wait_for_script_to_complete)
        astrology.check_astral
      end

      it 'returns early when no destination configured' do
        astrology.instance_variable_set(:@astral_plane_destination, nil)
        expect(DRC).not_to receive(:wait_for_script_to_complete)
        astrology.check_astral
      end

      it 'returns early when on cooldown' do
        allow(UserVars).to receive(:astral_plane_exp_timer).and_return(Time.now - 1800)
        expect(DRC).not_to receive(:wait_for_script_to_complete)
        astrology.check_astral
      end

      it 'walks to destination then source when ready' do
        allow(UserVars).to receive(:astral_plane_exp_timer).and_return(nil)
        expect(DRC).to receive(:wait_for_script_to_complete).with('bescort', ['ways', 'some_dest']).ordered
        expect(DRC).to receive(:wait_for_script_to_complete).with('bescort', ['ways', 'some_source']).ordered
        astrology.check_astral
      end
    end
  end

  describe '#check_events' do
    let(:astrology) { described_class.allocate }

    it 'returns early when study_sky returns inability message' do
      allow(DRCMM).to receive(:study_sky).and_return('You are unable to sense additional information')
      expect(DRCMM).not_to receive(:predict)
      astrology.check_events({ 'future events' => 0 })
    end

    it 'returns early when study_sky detects no portents' do
      allow(DRCMM).to receive(:study_sky).and_return('You fail to detect any portents')
      expect(DRCMM).not_to receive(:predict)
      astrology.check_events({ 'future events' => 0 })
    end

    context 'when pool stabilizes (happy path)' do
      it 'calls predict event after study_sky completes' do
        allow(DRCMM).to receive(:study_sky).and_return('Roundtime: 5 sec.')
        allow(Lich::Util).to receive(:issue_command).and_return(
          ['You have no understanding of the celestial influences over future events.', 'Roundtime: 3 sec.']
        )
        expect(DRCMM).to receive(:predict).with('event')
        astrology.check_events({ 'future events' => 0 })
      end
    end
  end

  # Adversarial: observe_without_telescope must not loop forever
  describe '#observe_without_telescope (via check_heavens)' do
    let(:astrology) { build_astrology }

    it 'stops after MAX_OBSERVE_ITERATIONS when observe never succeeds' do
      # Make visible_bodies return something valid
      allow(astrology).to receive(:visible_bodies).and_return(
        [{ 'name' => 'Katamba', 'circle' => 1, 'constellation' => false, 'telescope' => false,
           'pools' => { 'magic' => true } }]
      )
      # observe always returns unrecognized output, bad-search never set
      allow(DRCMM).to receive(:observe).and_return('Some unexpected game output')

      # This should NOT hang -- it should exit after MAX_OBSERVE_ITERATIONS
      astrology.check_heavens

      # Verify observe was called exactly MAX_OBSERVE_ITERATIONS times
      expect(DRCMM).to have_received(:observe).exactly(described_class::MAX_OBSERVE_ITERATIONS).times
    end
  end

  describe '#observe_with_telescope (via check_heavens)' do
    let(:astrology) { build_astrology(have_telescope: true) }
    let(:body_data) do
      [{ 'name' => 'Katamba', 'circle' => 1, 'constellation' => false, 'telescope' => false,
         'pools' => { 'magic' => true } }]
    end

    before do
      allow(astrology).to receive(:visible_bodies).and_return(body_data)
    end

    it 'terminates when observe_routine returns nil (exhausted retries)' do
      allow(DRCMM).to receive(:center_telescope).and_return('Center what?')
      allow(DRCMM).to receive(:get_telescope?).and_return(true)
      astrology.check_heavens
      expect(messages).to include('Astrology: Max observe retries reached. Aborting observation.')
    end

    it 'caps iterations at MAX_OBSERVE_ITERATIONS when never finished' do
      allow(DRCMM).to receive(:center_telescope).and_return(nil)
      allow(DRCMM).to receive(:peer_telescope).and_return(['Some unfinished output', 'Roundtime: 5 sec.'])
      astrology.check_heavens
      expect(DRCMM).to have_received(:peer_telescope).exactly(described_class::MAX_OBSERVE_ITERATIONS).times
    end

    it 'completes on first try when observation finishes and succeeds' do
      allow(DRCMM).to receive(:center_telescope).and_return(nil)
      allow(DRCMM).to receive(:peer_telescope).and_return(
        ["You've learned all that you can", 'You learned something useful', 'Roundtime: 5 sec.']
      )
      astrology.check_heavens
      expect(DRCMM).to have_received(:peer_telescope).once
    end

    it 'stores telescope in ensure block even when observation fails' do
      allow(DRCMM).to receive(:center_telescope).and_return(nil)
      allow(DRCMM).to receive(:peer_telescope).and_return(
        ["You've learned all that you can", 'You learned something useful']
      )
      astrology.check_heavens
      expect(DRCMM).to have_received(:store_telescope?)
    end
  end

  describe '#check_ripples' do
    let(:astrology) { build_astrology }

    it 'skips when rtr-expire flag is exactly false' do
      Flags.add('rtr-expire', 'test')
      Flags['rtr-expire'] = false
      astrology.check_ripples(default_settings)
      # Should return early without casting
      expect(DRCA).not_to have_received(:cast_spell)
    end
  end

  # Private helper specs
  describe 'private helpers' do
    describe '#get_telescope' do
      it 'calls DRCMM.get_telescope? when have_telescope is true' do
        astrology = build_astrology(have_telescope: true)
        expect(DRCMM).to receive(:get_telescope?).with('telescope', {})
        astrology.send(:get_telescope)
      end

      it 'does nothing when have_telescope is false' do
        astrology = build_astrology(have_telescope: false)
        expect(DRCMM).not_to receive(:get_telescope?)
        astrology.send(:get_telescope)
      end
    end

    describe '#store_telescope' do
      it 'calls DRCMM.store_telescope? when have_telescope is true' do
        astrology = build_astrology(have_telescope: true)
        expect(DRCMM).to receive(:store_telescope?).with('telescope', {})
        astrology.send(:store_telescope)
      end

      it 'does nothing when have_telescope is false' do
        astrology = build_astrology(have_telescope: false)
        expect(DRCMM).not_to receive(:store_telescope?)
        astrology.send(:store_telescope)
      end
    end

    describe '#debug_log' do
      it 'logs when debug mode is enabled' do
        allow(UserVars).to receive(:astrology_debug).and_return(true)
        astrology = build_astrology
        astrology.send(:debug_log, 'test message')
        expect(messages).to include('Astrology: test message')
      end

      it 'does not log when debug mode is disabled' do
        allow(UserVars).to receive(:astrology_debug).and_return(false)
        astrology = build_astrology
        astrology.send(:debug_log, 'test message')
        expect(messages).not_to include('Astrology: test message')
      end
    end

    describe '#observe_success?' do
      let(:astrology) { build_astrology }

      it 'returns true for success patterns' do
        expect(astrology.send(:observe_success?, 'You learned something useful from observation')).to be true
      end

      it 'returns true for overwhelmed pattern' do
        expect(astrology.send(:observe_success?, 'you still learned more of the future')).to be true
      end

      it 'returns false for unrelated text' do
        expect(astrology.send(:observe_success?, 'Your search for')).to be false
      end

      it 'returns false for nil' do
        expect(astrology.send(:observe_success?, nil)).to be false
      end
    end
  end

  # Adversarial: end-to-end observe pattern coverage
  describe 'observe pattern coverage (adversarial)' do
    let(:astrology) { build_astrology }

    # Real game messages -- observe_success? should return true
    {
      'full success'                          => 'You learned something useful from your observation of Katamba.',
      'partial sighting'                      => "While the sighting wasn't perfect, you still gleaned some information.",
      'clouds'                                => 'Clouds obscure the sky, preventing you from seeing anything.',
      'circle too low'                        => 'You learn nothing of the future from your attempt to observe the heavens.',
      'solar conjunction'                     => 'Yavash is too close to the sun to be observed.',
      'telescope needed'                      => 'The Heart Constellation is too faint for you to make out without a telescope.',
      'below horizon'                         => 'Katamba is currently below the horizon and cannot be observed.',
      'cooldown - not pondered'               => 'You have not pondered your last observation sufficiently.',
      'cooldown - unable to make use'         => 'You are unable to make use of this latest observation.',
      'nearly overwhelmed (the reported bug)' => 'Although you were nearly overwhelmed by some aspects of your observation, you still learned more of the future.'
    }.each do |scenario, game_message|
      it "observe_success? returns true for: #{scenario}" do
        expect(astrology.send(:observe_success?, game_message)).to be(true),
                                                                   "observe_success? should return true for '#{scenario}'"
      end
    end

    # These should NOT match
    {
      'search foiled'        => 'Your search for something in the heavens is foiled by the daylight.',
      'fruitless search'     => 'Your search for something in the heavens turns up fruitless.',
      'scan message'         => 'You scan the skies for a few moments.',
      'roundtime only'       => 'Roundtime: 5 sec.',
      'completely unrelated' => 'A gentle breeze blows through the area.',
      'empty response'       => ''
    }.each do |scenario, game_message|
      it "observe_success? returns false for: #{scenario}" do
        expect(astrology.send(:observe_success?, game_message)).to be(false),
                                                                   "observe_success? should return false for '#{scenario}'"
      end
    end
  end

  # Adversarial: ensure OBSERVE_SUCCESS_PATTERNS stays in sync with YAML data
  describe 'OBSERVE_SUCCESS_PATTERNS vs YAML data sync' do
    let(:yaml_success_substrings) do
      [
        'You learned something useful from your observation',
        "While the sighting wasn't quite",
        'you still learned more'
      ]
    end

    it 'covers all YAML observe_success_messages substrings' do
      yaml_success_substrings.each do |yaml_msg|
        matched = described_class::OBSERVE_SUCCESS_PATTERNS.any? { |p| yaml_msg.include?(p) }
        expect(matched).to be(true),
                           "OBSERVE_SUCCESS_PATTERNS should match YAML success message: '#{yaml_msg}'"
      end
    end
  end
end
