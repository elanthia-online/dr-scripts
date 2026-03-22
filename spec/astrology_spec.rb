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

      it 'includes nearly overwhelmed pattern' do
        expect(described_class::OBSERVE_SUCCESS_PATTERNS).to include('you still learned more')
      end

      it 'includes clouds obscure pattern' do
        expect(described_class::OBSERVE_SUCCESS_PATTERNS).to include('Clouds obscure')
      end

      it 'includes telescope needed pattern' do
        expect(described_class::OBSERVE_SUCCESS_PATTERNS).to include('too faint for you')
      end

      it 'includes below horizon pattern' do
        expect(described_class::OBSERVE_SUCCESS_PATTERNS).to include('below the horizon')
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

      it 'has 8 targets' do
        expect(described_class::PERCEIVE_TARGETS.size).to eq(8)
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

    it 'returns all six pool keys' do
      pools = astrology.check_pools
      expect(pools.keys).to contain_exactly(
        'lore', 'magic', 'survival',
        'offensive combat', 'defensive combat', 'future events'
      )
    end

    context 'when all pools are at maximum' do
      let(:pool_output) do
        [
          'You have a complete understanding of the celestial influences over magic.',
          'You have a complete understanding of the celestial influences over lore.',
          'You have a complete understanding of the celestial influences over survival.',
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

    context 'when issue_command returns empty array' do
      before do
        allow(Lich::Util).to receive(:issue_command).and_return([])
      end

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
      before do
        allow(DRSkill).to receive(:getxp).with('Attunement').and_return(31)
      end

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

      it 'returns true for second finished message variant' do
        result = ['You believe you have learned', 'Roundtime: 5 sec.']
        expect(astrology.check_observation_finished?(result)).to be true
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

      it 'returns false for empty string' do
        expect(astrology.check_observation_finished?('')).to be false
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

      it 'returns true for partial success' do
        result = ['While the sighting was not ideal', 'Roundtime: 5 sec.']
        expect(astrology.check_observation_success?(result)).to be true
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

    context 'with array result containing fuzzy vision injury' do
      it 'returns injuries=true' do
        result = ['Your vision is too fuzzy to make out details', 'Roundtime: 5 sec.']
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

    context 'with empty array' do
      it 'returns both false' do
        injuries, closed = astrology.check_telescope_result([])
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

    it 'always calls equipment_manager.empty_hands' do
      allow(DRCI).to receive(:in_hands?).and_return(false)
      expect(mock_equipment_manager).to receive(:empty_hands)
      astrology.empty_hands
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

      it 'predicts future when no divination tools configured' do
        expect(DRCMM).to receive(:predict).with('future')
        astrology.align_routine('Arcana')
      end
    end

    context 'with nil skill' do
      it 'aligns with nil' do
        expect(DRCMM).to receive(:align).with(nil)
        astrology.align_routine(nil)
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

    context 'with both bones and tool configured' do
      before do
        astrology.instance_variable_set(:@divination_bones_storage, { 'container' => 'backpack' })
        astrology.instance_variable_set(:@divination_tool, { 'name' => 'mirror' })
      end

      it 'prefers bones over tool' do
        expect(DRCMM).to receive(:roll_bones)
        expect(DRCMM).not_to receive(:use_div_tool)
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

    context 'with empty string bones storage' do
      before do
        astrology.instance_variable_set(:@divination_bones_storage, '')
      end

      it 'falls through to divination tool or predict' do
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

    context 'with all pools at zero' do
      let(:pools) do
        {
          'magic' => 0, 'lore' => 0, 'survival' => 0,
          'offensive combat' => 0, 'defensive combat' => 0, 'future events' => 0
        }
      end

      it 'does not align for any pool' do
        expect(astrology).not_to receive(:align_routine)
        astrology.predict_all(pools)
      end
    end

    context 'with pool target set to 0' do
      before do
        astrology.instance_variable_set(:@prediction_pool_target, 0)
      end

      it 'aligns for all pools since all are >= 0' do
        expect(astrology).to receive(:align_routine).exactly(6).times
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

      # Adversarial test: the bug that prompted this PR
      it 'returns true when nearly overwhelmed but still learned' do
        overwhelmed_msg = 'Although you were nearly overwhelmed by some aspects of your observation, ' \
                          'you still learned more of the future.'
        allow(DRCMM).to receive(:observe).with('Dawgolesh').and_return(overwhelmed_msg)
        result = astrology.observe_routine('Dawgolesh')
        expect(result).to be true
      end

      it 'returns true for partial sighting' do
        allow(DRCMM).to receive(:observe).with('Katamba').and_return('While the sighting was not ideal')
        result = astrology.observe_routine('Katamba')
        expect(result).to be true
      end

      it 'returns true for clouds obscure' do
        allow(DRCMM).to receive(:observe).with('Katamba').and_return('Clouds obscure the sky')
        result = astrology.observe_routine('Katamba')
        expect(result).to be true
      end

      it 'returns true for learn nothing' do
        allow(DRCMM).to receive(:observe).with('Katamba').and_return('You learn nothing of the future')
        result = astrology.observe_routine('Katamba')
        expect(result).to be true
      end

      it 'returns true for too close to sun' do
        allow(DRCMM).to receive(:observe).with('Katamba').and_return('Katamba is too close to the sun')
        result = astrology.observe_routine('Katamba')
        expect(result).to be true
      end

      it 'returns true for too faint' do
        allow(DRCMM).to receive(:observe).with('Xibar').and_return('Xibar is too faint for you to pick out')
        result = astrology.observe_routine('Xibar')
        expect(result).to be true
      end

      it 'returns true for below horizon' do
        allow(DRCMM).to receive(:observe).with('Katamba').and_return('Katamba is below the horizon')
        result = astrology.observe_routine('Katamba')
        expect(result).to be true
      end

      it 'returns true for not pondered' do
        allow(DRCMM).to receive(:observe).with('Katamba').and_return('You have not pondered your last observation')
        result = astrology.observe_routine('Katamba')
        expect(result).to be true
      end

      it 'returns true for unable to make use' do
        allow(DRCMM).to receive(:observe).with('Katamba').and_return('You are unable to make use of this')
        result = astrology.observe_routine('Katamba')
        expect(result).to be true
      end

      it 'returns false for nil observe result' do
        allow(DRCMM).to receive(:observe).with('Katamba').and_return(nil)
        result = astrology.observe_routine('Katamba')
        expect(result).to be false
      end

      it 'returns false for empty string observe result' do
        allow(DRCMM).to receive(:observe).with('Katamba').and_return('')
        result = astrology.observe_routine('Katamba')
        expect(result).to be false
      end

      it 'resets bad-search flag after observation' do
        allow(DRCMM).to receive(:observe).and_return('You learned something useful')
        Flags.add('bad-search', 'test')
        Flags['bad-search'] = 'turns up fruitless'
        astrology.observe_routine('Katamba')
        expect(Flags['bad-search']).to be false
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

    context 'with weather training task' do
      before do
        allow(DRSkill).to receive(:getxp).with('Astrology').and_return(10, 33)
        allow(Lich::Util).to receive(:issue_command).and_return([])
      end

      it 'calls check_weather' do
        expect(DRCMM).to receive(:predict).with('weather')
        settings = OpenStruct.new(astrology_training: ['weather'])
        astrology.train_astrology(settings)
      end
    end

    context 'with attunement training task' do
      before do
        allow(DRSkill).to receive(:getxp).with('Astrology').and_return(10, 33)
        allow(DRSkill).to receive(:getxp).with('Attunement').and_return(5)
        allow(Lich::Util).to receive(:issue_command).and_return([])
      end

      it 'calls check_attunement' do
        expect(DRC).to receive(:bput).with('perceive ', 'roundtime').at_least(:once)
        settings = OpenStruct.new(astrology_training: ['attunement'])
        astrology.train_astrology(settings)
      end
    end
  end

  describe '#check_astral' do
    let(:astrology) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@astral_place_source, 'some_source')
        a.instance_variable_set(:@astral_plane_destination, 'some_dest')
        a.instance_variable_set(:@settings, default_settings)
        a.instance_variable_set(:@have_telescope, false)
        a.instance_variable_set(:@telescope_name, 'telescope')
        a.instance_variable_set(:@telescope_storage, {})
        a.instance_variable_set(:@equipment_manager, instance_double('EquipmentManager', empty_hands: nil))
      end
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

      context 'when no source configured' do
        before do
          astrology.instance_variable_set(:@astral_place_source, nil)
        end

        it 'returns early' do
          expect(DRC).not_to receive(:wait_for_script_to_complete)
          astrology.check_astral
        end
      end

      context 'when no destination configured' do
        before do
          astrology.instance_variable_set(:@astral_plane_destination, nil)
        end

        it 'returns early' do
          expect(DRC).not_to receive(:wait_for_script_to_complete)
          astrology.check_astral
        end
      end

      context 'when on cooldown' do
        before do
          allow(UserVars).to receive(:astral_plane_exp_timer).and_return(Time.now - 1800) # 30 min ago
        end

        it 'returns early (cooldown is 3600 seconds)' do
          expect(DRC).not_to receive(:wait_for_script_to_complete)
          astrology.check_astral
        end
      end

      context 'when ready to train' do
        before do
          allow(UserVars).to receive(:astral_plane_exp_timer).and_return(nil)
        end

        it 'walks to destination then source' do
          expect(DRC).to receive(:wait_for_script_to_complete).with('bescort', ['ways', 'some_dest']).ordered
          expect(DRC).to receive(:wait_for_script_to_complete).with('bescort', ['ways', 'some_source']).ordered
          astrology.check_astral
        end
      end
    end
  end

  describe '#check_events' do
    let(:astrology) { described_class.allocate }

    context 'when study_sky returns inability message' do
      before do
        allow(DRCMM).to receive(:study_sky).and_return('You are unable to sense additional information')
      end

      it 'returns early without predicting' do
        expect(DRCMM).not_to receive(:predict)
        astrology.check_events({ 'future events' => 0 })
      end
    end

    context 'when study_sky detects no portents' do
      before do
        allow(DRCMM).to receive(:study_sky).and_return('You fail to detect any portents')
      end

      it 'returns early without predicting' do
        expect(DRCMM).not_to receive(:predict)
        astrology.check_events({ 'future events' => 0 })
      end
    end
  end

  # Adversarial: test the interaction between OBSERVE_SUCCESS_PATTERNS and observe_routine
  # to ensure all known game messages are properly handled end-to-end
  describe 'observe pattern coverage (adversarial)' do
    let(:astrology) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@have_telescope, false)
        a.instance_variable_set(:@telescope_name, 'telescope')
        a.instance_variable_set(:@telescope_storage, {})
        a.instance_variable_set(:@injured_messages, constellations_data.observe_injured_messages)
      end
    end

    # These are real game messages that DRCMM.observe can return
    # Each should result in observe_routine returning true (observation is "done")
    {
      'full success'                          =>
                                                 'You learned something useful from your observation of Katamba.',
      'partial sighting'                      =>
                                                 "While the sighting wasn't perfect, you still gleaned some information from your study of Xibar.",
      'clouds'                                =>
                                                 'Clouds obscure the sky, preventing you from seeing anything.',
      'circle too low'                        =>
                                                 'You learn nothing of the future from your attempt to observe the heavens.',
      'solar conjunction'                     =>
                                                 'Yavash is too close to the sun to be observed.',
      'telescope needed'                      =>
                                                 'The Heart Constellation is too faint for you to make out without a telescope.',
      'below horizon'                         =>
                                                 'Katamba is currently below the horizon and cannot be observed.',
      'cooldown - not pondered'               =>
                                                 'You have not pondered your last observation sufficiently to gain insight from a new one.',
      'cooldown - unable to make use'         =>
                                                 'You are unable to make use of this latest observation.',
      'nearly overwhelmed (the reported bug)' =>
                                                 'Although you were nearly overwhelmed by some aspects of your observation, you still learned more of the future.'
    }.each do |scenario, game_message|
      it "returns true for: #{scenario}" do
        allow(DRCMM).to receive(:observe).with('Katamba').and_return(game_message)
        result = astrology.observe_routine('Katamba')
        expect(result).to be(true), "observe_routine should return true for '#{scenario}': #{game_message}"
      end
    end

    # These messages should NOT be matched -- observe_routine should return false
    {
      'search foiled (separate flag handling)'    =>
                                                     'Your search for something in the heavens is foiled by the daylight.',
      'fruitless search (separate flag handling)' =>
                                                     'Your search for something in the heavens turns up fruitless.',
      'scan message'                              =>
                                                     'You scan the skies for a few moments.',
      'roundtime only'                            =>
                                                     'Roundtime: 5 sec.',
      'completely unrelated'                      =>
                                                     'A gentle breeze blows through the area.',
      'empty response'                            =>
                                                     ''
    }.each do |scenario, game_message|
      it "returns false for: #{scenario}" do
        allow(DRCMM).to receive(:observe).with('Katamba').and_return(game_message)
        result = astrology.observe_routine('Katamba')
        expect(result).to be(false), "observe_routine should return false for '#{scenario}': #{game_message}"
      end
    end
  end

  # Adversarial: ensure OBSERVE_SUCCESS_PATTERNS stays in sync with YAML data
  describe 'OBSERVE_SUCCESS_PATTERNS vs YAML data sync' do
    # The YAML observe_success_messages and observe_finished_messages contain
    # substrings that should also be matchable by OBSERVE_SUCCESS_PATTERNS.
    # This test verifies the hardcoded constant covers the YAML success messages.
    let(:yaml_success_substrings) do
      # From base-constellations.yaml observe_success_messages
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
