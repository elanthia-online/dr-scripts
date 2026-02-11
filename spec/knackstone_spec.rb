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

# Minimal stub modules for game interaction
module DRC
  def self.left_hand
    $left_hand
  end

  def self.right_hand
    $right_hand
  end

  def self.bput(*_args)
    'Roundtime'
  end

  def self.message(*_args); end
end

module DRCI
  def self.in_hands?(*_args)
    false
  end

  def self.remove_item?(*_args)
    true
  end

  def self.wear_item?(*_args)
    true
  end

  def self.put_away_item?(*_args)
    true
  end

  def self.get_item_if_not_held?(*_args)
    true
  end
end

module Lich
  module Util
    def self.issue_command(*_args)
      []
    end
  end
end

# Load Knackstone class definition (without executing top-level code)
load_lic_class('knackstone.lic', 'Knackstone')

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end
end

RSpec.describe Knackstone do
  let(:settings) do
    OpenStruct.new(
      knackstone_noun: 'knackstone',
      knackstone_container: 'backpack',
      knackstone_worn: false,
      knackstone_preferences: nil,
      knackstone_debug: false
    )
  end

  before(:each) do
    allow_any_instance_of(Knackstone).to receive(:get_settings).and_return(settings)
  end

  # ===========================================================================
  # DEFAULT_PREFERENCES constant
  # ===========================================================================
  describe 'DEFAULT_PREFERENCES' do
    it 'is a frozen array' do
      expect(Knackstone::DEFAULT_PREFERENCES).to be_frozen
    end

    it 'contains expected bonus options' do
      prefs = Knackstone::DEFAULT_PREFERENCES
      expect(prefs).to include('bonus gem value from creatures')
      expect(prefs).to include('bonus creature swarm activity')
      expect(prefs).to include('bonus coins dropped from creatures')
      expect(prefs).to include('bonus REXP value')
      expect(prefs).to include('bonus experience')
      expect(prefs).to include('bonus scroll drop chance')
      expect(prefs).to include('bank fee removal')
      expect(prefs).to include('bonus crafting experience')
      expect(prefs).to include('bonus work order payouts')
      expect(prefs).to include('bonus item drop chance')
      expect(prefs).to include('bonus crafting prestige')
      expect(prefs).to include('bonus to treasure map drop chance')
    end

    it 'has bonus scroll drop chance in the list' do
      expect(Knackstone::DEFAULT_PREFERENCES).to include('bonus scroll drop chance')
    end

    it 'contains 12 options' do
      expect(Knackstone::DEFAULT_PREFERENCES.size).to eq(12)
    end
  end

  # ===========================================================================
  # Regex constants
  # ===========================================================================
  describe 'BONUS_OPTIONS_REGEX' do
    it 'is frozen' do
      expect(Knackstone::BONUS_OPTIONS_REGEX).to be_frozen
    end

    it 'matches the expected knackstone output format' do
      line = 'As best you can tell, it could be bonus gem value from creatures, bonus experience, or bonus REXP value.  '
      match = line.match(Knackstone::BONUS_OPTIONS_REGEX)
      expect(match).not_to be_nil
      expect(match.captures).to eq(['bonus gem value from creatures', 'bonus experience', 'bonus REXP value'])
    end

    it 'captures three options' do
      line = 'As best you can tell, it could be bank fee removal, bonus crafting prestige, or bonus scroll drop chance.  '
      match = line.match(Knackstone::BONUS_OPTIONS_REGEX)
      expect(match).not_to be_nil
      expect(match[1]).to eq('bank fee removal')
      expect(match[2]).to eq('bonus crafting prestige')
      expect(match[3]).to eq('bonus scroll drop chance')
    end
  end

  describe 'ALREADY_USED_REGEX' do
    it 'is frozen' do
      expect(Knackstone::ALREADY_USED_REGEX).to be_frozen
    end

    it 'matches the already used message' do
      line = 'You have already cast your will to influence this cycle\'s future boon options'
      expect(line).to match(Knackstone::ALREADY_USED_REGEX)
    end
  end

  describe 'CONFIRMATION_REGEX' do
    it 'is frozen' do
      expect(Knackstone::CONFIRMATION_REGEX).to be_frozen
    end

    it 'matches the confirmation prompt' do
      line = 'You must repeat the command within 15 seconds to confirm.'
      expect(line).to match(Knackstone::CONFIRMATION_REGEX)
    end
  end

  # ===========================================================================
  # #initialize
  # ===========================================================================
  describe '#initialize' do
    it 'uses default preferences when none specified' do
      knack = Knackstone.new
      prefs = knack.instance_variable_get(:@knackstone_preferences)
      expect(prefs).to eq(Knackstone::DEFAULT_PREFERENCES)
    end

    it 'uses custom preferences when specified' do
      custom_prefs = ['bonus experience', 'bonus REXP value']
      settings.knackstone_preferences = custom_prefs
      knack = Knackstone.new
      prefs = knack.instance_variable_get(:@knackstone_preferences)
      expect(prefs).to eq(custom_prefs)
    end

    it 'defaults knackstone_noun to knackstone' do
      settings.knackstone_noun = nil
      knack = Knackstone.new
      expect(knack.instance_variable_get(:@knackstone)).to eq('knackstone')
    end

    it 'uses custom knackstone noun' do
      settings.knackstone_noun = 'orb'
      knack = Knackstone.new
      expect(knack.instance_variable_get(:@knackstone)).to eq('orb')
    end

    it 'defaults container to watery portal' do
      settings.knackstone_container = nil
      knack = Knackstone.new
      expect(knack.instance_variable_get(:@knackstone_container)).to eq('watery portal')
    end

    it 'uses custom container' do
      settings.knackstone_container = 'satchel'
      knack = Knackstone.new
      expect(knack.instance_variable_get(:@knackstone_container)).to eq('satchel')
    end

    it 'defaults worn to false' do
      settings.knackstone_worn = nil
      knack = Knackstone.new
      expect(knack.instance_variable_get(:@knackstone_worn)).to eq(false)
    end

    it 'uses worn setting when true' do
      settings.knackstone_worn = true
      knack = Knackstone.new
      expect(knack.instance_variable_get(:@knackstone_worn)).to eq(true)
    end

    it 'defaults debug to false' do
      settings.knackstone_debug = nil
      knack = Knackstone.new
      expect(knack.instance_variable_get(:@debug)).to eq(false)
    end

    it 'uses debug setting when true' do
      settings.knackstone_debug = true
      knack = Knackstone.new
      expect(knack.instance_variable_get(:@debug)).to eq(true)
    end
  end

  # ===========================================================================
  # #run
  # ===========================================================================
  describe '#run' do
    let(:knack) { Knackstone.new }

    before(:each) do
      allow(knack).to receive(:unusable_state?).and_return(false)
      allow(knack).to receive(:ensure_knackstone_in_hand).and_return(true)
      allow(knack).to receive(:use_knackstone)
      allow(knack).to receive(:put_away_knackstone)
      allow(knack).to receive(:remove_worn_knackstone).and_return(true)
      allow(knack).to receive(:wear_knackstone)
    end

    context 'when in unusable state' do
      before { allow(knack).to receive(:unusable_state?).and_return(true) }

      it 'returns early without doing anything' do
        expect(knack).not_to receive(:ensure_knackstone_in_hand)
        expect(knack).not_to receive(:use_knackstone)
        knack.run
      end
    end

    context 'when knackstone is not worn (container mode)' do
      before { knack.instance_variable_set(:@knackstone_worn, false) }

      it 'ensures knackstone is in hand' do
        expect(knack).to receive(:ensure_knackstone_in_hand).and_return(true)
        knack.run
      end

      it 'uses the knackstone' do
        expect(knack).to receive(:use_knackstone)
        knack.run
      end

      it 'puts away the knackstone after use' do
        expect(knack).to receive(:put_away_knackstone)
        knack.run
      end

      it 'returns early if cannot get knackstone' do
        allow(knack).to receive(:ensure_knackstone_in_hand).and_return(false)
        expect(knack).not_to receive(:use_knackstone)
        knack.run
      end

      it 'does not try to wear the knackstone' do
        expect(knack).not_to receive(:wear_knackstone)
        knack.run
      end
    end

    context 'when knackstone is worn' do
      before { knack.instance_variable_set(:@knackstone_worn, true) }

      it 'removes the worn knackstone' do
        expect(knack).to receive(:remove_worn_knackstone).and_return(true)
        knack.run
      end

      it 'uses the knackstone after removing' do
        expect(knack).to receive(:use_knackstone)
        knack.run
      end

      it 'wears the knackstone after use' do
        expect(knack).to receive(:wear_knackstone)
        knack.run
      end

      it 'returns early if cannot remove knackstone' do
        allow(knack).to receive(:remove_worn_knackstone).and_return(false)
        expect(knack).not_to receive(:use_knackstone)
        knack.run
      end

      it 'does not try to put away the knackstone' do
        expect(knack).not_to receive(:put_away_knackstone)
        knack.run
      end
    end
  end

  # ===========================================================================
  # #debug? (private)
  # ===========================================================================
  describe '#debug?' do
    it 'returns false when debug is disabled' do
      settings.knackstone_debug = false
      knack = Knackstone.new
      expect(knack.send(:debug?)).to eq(false)
    end

    it 'returns true when debug is enabled' do
      settings.knackstone_debug = true
      knack = Knackstone.new
      expect(knack.send(:debug?)).to eq(true)
    end
  end

  # ===========================================================================
  # #unusable_state? (private)
  # ===========================================================================
  describe '#unusable_state?' do
    let(:knack) { Knackstone.new }

    context 'when not hidden or invisible' do
      before do
        $hidden = false
        $invisible = false
      end

      it 'returns false' do
        expect(knack.send(:unusable_state?)).to eq(false)
      end
    end

    context 'when hidden' do
      before do
        $hidden = true
        $invisible = false
      end

      it 'returns true' do
        expect(knack.send(:unusable_state?)).to eq(true)
      end

      it 'echoes a message' do
        expect(knack).to receive(:echo).with('Cannot use knackstone while hidden or invisible.')
        knack.send(:unusable_state?)
      end
    end

    context 'when invisible' do
      before do
        $hidden = false
        $invisible = true
      end

      it 'returns true' do
        expect(knack.send(:unusable_state?)).to eq(true)
      end

      it 'echoes a message' do
        expect(knack).to receive(:echo).with('Cannot use knackstone while hidden or invisible.')
        knack.send(:unusable_state?)
      end
    end

    context 'when both hidden and invisible' do
      before do
        $hidden = true
        $invisible = true
      end

      it 'returns true' do
        expect(knack.send(:unusable_state?)).to eq(true)
      end
    end
  end

  # ===========================================================================
  # #remove_worn_knackstone (private)
  # ===========================================================================
  describe '#remove_worn_knackstone' do
    let(:knack) { Knackstone.new }

    context 'when knackstone already in hands' do
      before { allow(DRCI).to receive(:in_hands?).with('knackstone').and_return(true) }

      it 'returns true without removing' do
        expect(DRCI).not_to receive(:remove_item?)
        expect(knack.send(:remove_worn_knackstone)).to eq(true)
      end
    end

    context 'when hands are full' do
      before do
        allow(DRCI).to receive(:in_hands?).with('knackstone').and_return(false)
        $left_hand = 'sword'
        $right_hand = 'shield'
      end

      it 'returns false' do
        expect(knack.send(:remove_worn_knackstone)).to eq(false)
      end

      it 'displays a message' do
        expect(DRC).to receive(:message).with('Hands full, cannot remove knackstone.')
        knack.send(:remove_worn_knackstone)
      end
    end

    context 'when hands are free' do
      before do
        allow(DRCI).to receive(:in_hands?).with('knackstone').and_return(false)
        $left_hand = nil
        $right_hand = nil
      end

      it 'removes the knackstone and returns true' do
        allow(DRCI).to receive(:remove_item?).with('knackstone').and_return(true)
        expect(knack.send(:remove_worn_knackstone)).to eq(true)
      end

      it 'exits if remove fails' do
        allow(DRCI).to receive(:remove_item?).with('knackstone').and_return(false)
        expect(DRC).to receive(:message).with('Could not remove knackstone. Something is wrong!')
        expect(knack).to receive(:exit)
        knack.send(:remove_worn_knackstone)
      end
    end

    context 'with custom knackstone noun' do
      before do
        settings.knackstone_noun = 'orb'
        allow(DRCI).to receive(:in_hands?).and_return(false)
        $left_hand = nil
        $right_hand = nil
        allow(DRCI).to receive(:remove_item?).and_return(true)
      end

      it 'uses the custom noun' do
        knack = Knackstone.new
        expect(DRCI).to receive(:in_hands?).with('orb')
        expect(DRCI).to receive(:remove_item?).with('orb')
        knack.send(:remove_worn_knackstone)
      end
    end
  end

  # ===========================================================================
  # #wear_knackstone (private)
  # ===========================================================================
  describe '#wear_knackstone' do
    let(:knack) { Knackstone.new }

    it 'wears the knackstone' do
      allow(DRCI).to receive(:wear_item?).with('knackstone').and_return(true)
      knack.send(:wear_knackstone)
    end

    it 'exits if wear fails' do
      allow(DRCI).to receive(:wear_item?).with('knackstone').and_return(false)
      expect(DRC).to receive(:message).with('Could not wear knackstone. Something is wrong!')
      expect(knack).to receive(:exit)
      knack.send(:wear_knackstone)
    end

    context 'with custom knackstone noun' do
      before do
        settings.knackstone_noun = 'orb'
        allow(DRCI).to receive(:wear_item?).and_return(true)
      end

      it 'uses the custom noun' do
        knack = Knackstone.new
        expect(DRCI).to receive(:wear_item?).with('orb')
        knack.send(:wear_knackstone)
      end
    end
  end

  # ===========================================================================
  # #put_away_knackstone (private)
  # ===========================================================================
  describe '#put_away_knackstone' do
    let(:knack) { Knackstone.new }

    it 'puts away the knackstone' do
      allow(DRCI).to receive(:put_away_item?).with('knackstone', 'backpack').and_return(true)
      knack.send(:put_away_knackstone)
    end

    it 'exits if put away fails' do
      allow(DRCI).to receive(:put_away_item?).with('knackstone', 'backpack').and_return(false)
      expect(DRC).to receive(:message).with('Could not put away knackstone. Something is wrong!')
      expect(knack).to receive(:exit)
      knack.send(:put_away_knackstone)
    end

    context 'with custom settings' do
      before do
        settings.knackstone_noun = 'orb'
        settings.knackstone_container = 'satchel'
        allow(DRCI).to receive(:put_away_item?).and_return(true)
      end

      it 'uses the custom noun and container' do
        knack = Knackstone.new
        expect(DRCI).to receive(:put_away_item?).with('orb', 'satchel')
        knack.send(:put_away_knackstone)
      end
    end
  end

  # ===========================================================================
  # #ensure_knackstone_in_hand (private)
  # ===========================================================================
  describe '#ensure_knackstone_in_hand' do
    let(:knack) { Knackstone.new }

    context 'when knackstone already in hands' do
      before { allow(DRCI).to receive(:in_hands?).with('knackstone').and_return(true) }

      it 'returns true without getting' do
        expect(DRCI).not_to receive(:get_item_if_not_held?)
        expect(knack.send(:ensure_knackstone_in_hand)).to eq(true)
      end
    end

    context 'when hands are full' do
      before do
        allow(DRCI).to receive(:in_hands?).with('knackstone').and_return(false)
        $left_hand = 'sword'
        $right_hand = 'shield'
      end

      it 'returns false' do
        expect(knack.send(:ensure_knackstone_in_hand)).to eq(false)
      end

      it 'displays a message' do
        expect(DRC).to receive(:message).with('Hands full, cannot get knackstone.')
        knack.send(:ensure_knackstone_in_hand)
      end
    end

    context 'when hands are free' do
      before do
        allow(DRCI).to receive(:in_hands?).with('knackstone').and_return(false)
        $left_hand = nil
        $right_hand = nil
      end

      it 'gets the knackstone from container' do
        expect(DRCI).to receive(:get_item_if_not_held?).with('knackstone', 'backpack')
        knack.send(:ensure_knackstone_in_hand)
      end
    end

    context 'with custom settings' do
      before do
        settings.knackstone_noun = 'orb'
        settings.knackstone_container = 'satchel'
        allow(DRCI).to receive(:in_hands?).and_return(false)
        $left_hand = nil
        $right_hand = nil
      end

      it 'uses the custom noun and container' do
        knack = Knackstone.new
        expect(DRCI).to receive(:get_item_if_not_held?).with('orb', 'satchel')
        knack.send(:ensure_knackstone_in_hand)
      end
    end
  end

  # ===========================================================================
  # #use_knackstone (private)
  # ===========================================================================
  describe '#use_knackstone' do
    let(:knack) { Knackstone.new }

    before(:each) do
      allow(knack).to receive(:find_best_option).and_return('bonus experience')
      allow(knack).to receive(:vote_for)
    end

    context 'when already used this cycle' do
      before do
        allow(Lich::Util).to receive(:issue_command).and_return([
                                                                  'As you rub the stone...',
                                                                  'You have already cast your will to influence this cycle\'s future boon options'
                                                                ])
      end

      it 'echoes a message and returns' do
        expect(knack).to receive(:echo).with('Knackstone has already been used for this cycle.')
        expect(knack).not_to receive(:vote_for)
        knack.send(:use_knackstone)
      end
    end

    context 'when options cannot be determined' do
      before do
        allow(Lich::Util).to receive(:issue_command).and_return([
                                                                  'As you rub the stone...',
                                                                  'Something unexpected happened.'
                                                                ])
      end

      it 'echoes a message about missing options' do
        expect(knack).to receive(:echo).with('Could not determine knackstone options from response.')
        expect(knack).not_to receive(:vote_for)
        knack.send(:use_knackstone)
      end
    end

    context 'when options line exists but cannot be parsed' do
      before do
        allow(Lich::Util).to receive(:issue_command).and_return([
                                                                  'As you rub the stone...',
                                                                  'As best you can tell, it has problems.'
                                                                ])
      end

      it 'echoes a message about parsing failure' do
        expect(knack).to receive(:echo).with(/Could not parse knackstone options from:/)
        expect(knack).not_to receive(:vote_for)
        knack.send(:use_knackstone)
      end
    end

    context 'when options are successfully retrieved' do
      before do
        allow(Lich::Util).to receive(:issue_command).and_return([
                                                                  'As you rub the stone...',
                                                                  'As best you can tell, it could be bonus experience, bonus REXP value, or bank fee removal.  '
                                                                ])
      end

      it 'finds the best option and votes' do
        expect(knack).to receive(:find_best_option).with(['bonus experience', 'bonus REXP value', 'bank fee removal']).and_return('bonus experience')
        expect(knack).to receive(:vote_for).with('bonus experience', ['bonus experience', 'bonus REXP value', 'bank fee removal'])
        knack.send(:use_knackstone)
      end
    end

    context 'with custom knackstone noun' do
      before do
        settings.knackstone_noun = 'orb'
        allow(Lich::Util).to receive(:issue_command).and_return([
                                                                  'As you rub the stone...',
                                                                  'You have already cast your will to influence this cycle\'s future boon options'
                                                                ])
      end

      it 'uses the custom noun in the rub command' do
        knack = Knackstone.new
        expect(Lich::Util).to receive(:issue_command).with('rub my orb', /As you rub/, usexml: false)
        knack.send(:use_knackstone)
      end
    end
  end

  # ===========================================================================
  # #find_best_option (private)
  # ===========================================================================
  describe '#find_best_option' do
    let(:knack) { Knackstone.new }

    it 'returns the option with lowest preference index' do
      options = ['bonus crafting prestige', 'bonus gem value from creatures', 'bonus experience']
      result = knack.send(:find_best_option, options)
      expect(result).to eq('bonus gem value from creatures')
    end

    it 'handles options not in preferences (treats as infinite index)' do
      options = ['unknown option', 'bonus experience', 'another unknown']
      result = knack.send(:find_best_option, options)
      expect(result).to eq('bonus experience')
    end

    it 'returns first option if all are unknown' do
      options = ['unknown1', 'unknown2', 'unknown3']
      result = knack.send(:find_best_option, options)
      expect(result).to eq('unknown1')
    end

    it 'echoes the chosen option' do
      options = ['bonus experience', 'bonus crafting prestige']
      expect(knack).to receive(:echo).with('Chosen option: bonus experience')
      knack.send(:find_best_option, options)
    end

    context 'with debug enabled' do
      before { knack.instance_variable_set(:@debug, true) }

      it 'echoes available options' do
        options = ['bonus experience']
        expect(knack).to receive(:echo).with(/Available options:/)
        allow(knack).to receive(:echo)
        knack.send(:find_best_option, options)
      end

      it 'echoes preferences' do
        options = ['bonus experience']
        expect(knack).to receive(:echo).with(/Sorting by preferences:/)
        allow(knack).to receive(:echo)
        knack.send(:find_best_option, options)
      end
    end

    context 'with custom preferences' do
      before do
        settings.knackstone_preferences = ['bonus REXP value', 'bonus experience']
      end

      it 'uses custom preference order' do
        knack = Knackstone.new
        options = ['bonus experience', 'bonus REXP value', 'bonus crafting prestige']
        result = knack.send(:find_best_option, options)
        expect(result).to eq('bonus REXP value')
      end
    end

    context 'with bonus scroll drop chance in options' do
      it 'selects scroll drop chance based on preference position' do
        # Default preferences have scroll drop chance after experience
        options = ['bonus scroll drop chance', 'bonus to treasure map drop chance', 'unknown']
        result = knack.send(:find_best_option, options)
        expect(result).to eq('bonus scroll drop chance')
      end

      it 'prefers higher-ranked options over scroll drop chance' do
        options = ['bonus scroll drop chance', 'bonus experience', 'bonus crafting prestige']
        result = knack.send(:find_best_option, options)
        expect(result).to eq('bonus experience')
      end
    end
  end

  # ===========================================================================
  # #vote_for (private)
  # ===========================================================================
  describe '#vote_for' do
    let(:knack) { Knackstone.new }

    before(:each) do
      allow(knack).to receive(:whisper_command).and_return(false)
    end

    it 'calculates correct choice number (1-indexed)' do
      options = ['option1', 'option2', 'option3']
      expect(knack).to receive(:whisper_command).with('WHISPER MY knackstone 2')
      knack.send(:vote_for, 'option2', options)
    end

    it 'repeats command if confirmation needed' do
      allow(knack).to receive(:whisper_command).and_return(true, false)
      expect(knack).to receive(:whisper_command).twice
      knack.send(:vote_for, 'option1', ['option1', 'option2', 'option3'])
    end

    it 'does not repeat command if no confirmation needed' do
      allow(knack).to receive(:whisper_command).and_return(false)
      expect(knack).to receive(:whisper_command).once
      knack.send(:vote_for, 'option1', ['option1', 'option2', 'option3'])
    end

    context 'with debug enabled' do
      before { knack.instance_variable_set(:@debug, true) }

      it 'echoes the command' do
        expect(knack).to receive(:echo).with(/Executing: WHISPER MY knackstone/)
        knack.send(:vote_for, 'option1', ['option1', 'option2', 'option3'])
      end
    end

    context 'with custom knackstone noun' do
      before do
        settings.knackstone_noun = 'orb'
      end

      it 'uses custom noun in command' do
        knack = Knackstone.new
        expect(knack).to receive(:whisper_command).with('WHISPER MY orb 1')
        knack.send(:vote_for, 'option1', ['option1', 'option2', 'option3'])
      end
    end
  end

  # ===========================================================================
  # #whisper_command (private)
  # ===========================================================================
  describe '#whisper_command' do
    let(:knack) { Knackstone.new }

    it 'returns true if confirmation is needed' do
      allow(Lich::Util).to receive(:issue_command).and_return([
                                                                'You whisper the fate...',
                                                                'You must repeat the command within 15 seconds to confirm.'
                                                              ])
      result = knack.send(:whisper_command, 'WHISPER MY knackstone 1')
      expect(result).to eq(true)
    end

    it 'returns false if no confirmation needed' do
      allow(Lich::Util).to receive(:issue_command).and_return([
                                                                'You whisper the fate...',
                                                                'You have cast your lot to fate!'
                                                              ])
      result = knack.send(:whisper_command, 'WHISPER MY knackstone 1')
      expect(result).to eq(false)
    end

    it 'uses correct start and end patterns' do
      expect(Lich::Util).to receive(:issue_command).with(
        'WHISPER MY knackstone 1',
        /You whisper the fate/,
        /Roundtime|You have cast your lot to fate/,
        usexml: false
      ).and_return([])
      knack.send(:whisper_command, 'WHISPER MY knackstone 1')
    end
  end

  # ===========================================================================
  # Integration scenarios
  # ===========================================================================
  describe 'integration scenarios' do
    context 'full voting flow with container' do
      let(:knack) { Knackstone.new }

      before do
        $hidden = false
        $invisible = false
        $left_hand = nil
        $right_hand = nil

        allow(DRCI).to receive(:in_hands?).and_return(false, true)
        allow(DRCI).to receive(:get_item_if_not_held?).and_return(true)
        allow(DRCI).to receive(:put_away_item?).and_return(true)
        allow(Lich::Util).to receive(:issue_command).and_return(
          ['As you rub...', 'As best you can tell, it could be bonus experience, bonus REXP value, or bank fee removal.  '],
          ['You whisper...', 'You have cast your lot to fate!']
        )
      end

      it 'completes the full flow' do
        expect(DRCI).to receive(:get_item_if_not_held?).with('knackstone', 'backpack')
        expect(Lich::Util).to receive(:issue_command).with('rub my knackstone', /As you rub/, usexml: false)
        expect(Lich::Util).to receive(:issue_command).with(/WHISPER MY knackstone/, anything, anything, usexml: false)
        expect(DRCI).to receive(:put_away_item?).with('knackstone', 'backpack')
        knack.run
      end
    end

    context 'full voting flow with worn knackstone' do
      before do
        settings.knackstone_worn = true
      end

      let(:knack) { Knackstone.new }

      before do
        $hidden = false
        $invisible = false
        $left_hand = nil
        $right_hand = nil

        allow(DRCI).to receive(:in_hands?).and_return(false, true)
        allow(DRCI).to receive(:remove_item?).and_return(true)
        allow(DRCI).to receive(:wear_item?).and_return(true)
        allow(Lich::Util).to receive(:issue_command).and_return(
          ['As you rub...', 'As best you can tell, it could be bonus scroll drop chance, bonus REXP value, or bank fee removal.  '],
          ['You whisper...', 'You have cast your lot to fate!']
        )
      end

      it 'removes, uses, and wears the knackstone' do
        expect(DRCI).to receive(:remove_item?).with('knackstone')
        expect(Lich::Util).to receive(:issue_command).with('rub my knackstone', /As you rub/, usexml: false)
        expect(DRCI).to receive(:wear_item?).with('knackstone')
        knack.run
      end
    end
  end

  # ===========================================================================
  # Source code invariants
  # ===========================================================================
  describe 'source code invariants' do
    let(:source) { File.read(File.join(File.dirname(__FILE__), '..', 'knackstone.lic')) }

    it 'has frozen_string_literal pragma' do
      expect(source.lines.first).to match(/frozen_string_literal: true/)
    end

    it 'has frozen DEFAULT_PREFERENCES constant' do
      expect(source).to include('DEFAULT_PREFERENCES = [')
      expect(source).to include('].freeze')
    end

    it 'has frozen regex constants' do
      expect(source).to include('BONUS_OPTIONS_REGEX = ')
      expect(source).to include('ALREADY_USED_REGEX = ')
      expect(source).to include('CONFIRMATION_REGEX = ')
    end

    it 'includes bonus scroll drop chance in preferences' do
      expect(source).to include('"bonus scroll drop chance"')
    end
  end
end
