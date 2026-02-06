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

# Minimal stub modules for game interaction.
# These must be defined before loading the Sew class so that
# method bodies referencing them can be parsed without error.
module DRC
  def self.right_hand
    $right_hand
  end

  def self.left_hand
    $left_hand
  end

  def self.bput(*_args)
    'Roundtime'
  end

  def self.message(*_args); end

  def self.release_invisibility; end
end

module DRCC
  def self.stow_crafting_item(*_args)
    true
  end

  def self.logbook_item(*_args); end

  def self.get_crafting_item(*_args); end
end

module DRCI
  def self.lift?
    false
  end

  def self.dispose_trash(*_args); end

  def self.in_left_hand?(*_args)
    false
  end

  def self.in_right_hand?(*_args)
    false
  end
end

module DRCA
  def self.crafting_magic_routine(*_args); end
end

# Load Sew class definition (without executing top-level code)
load_lic_class('sew.lic', 'Sew')

# Define magic_cleanup (top-level method called by Sew#finish)
def magic_cleanup; end

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end
end

RSpec.describe Sew do
  # Allocate a bare instance without calling initialize, then inject
  # the instance variables that the methods under test depend on.
  let(:sew) { Sew.allocate }

  before(:each) do
    sew.instance_variable_set(:@noun, 'rucksack')
    sew.instance_variable_set(:@bag, 'duffel bag')
    sew.instance_variable_set(:@belt, nil)
    sew.instance_variable_set(:@stamp, false)
    sew.instance_variable_set(:@finish, 'log')
    sew.instance_variable_set(:@worn_trashcan, nil)
    sew.instance_variable_set(:@worn_trashcan_verb, nil)
    sew.instance_variable_set(:@settings, OpenStruct.new(crafting_training_spells: []))

    # Prevent actual exit and stub helper methods
    allow(sew).to receive(:exit)
    allow(sew).to receive(:magic_cleanup)
    allow(sew).to receive(:lift_or_stow_feet)
  end

  # ===========================================================================
  # #finish — stow guards and logbook bundling
  # ===========================================================================
  describe '#finish' do
    context 'with a simple noun (no dot notation)' do
      before do
        sew.instance_variable_set(:@noun, 'rucksack')
        $right_hand = 'sewing needles'
        $left_hand = 'small burlap rucksack'
      end

      it 'stows the tool from right hand' do
        expect(DRCC).to receive(:stow_crafting_item).with('sewing needles', 'duffel bag', nil).once
        allow(DRCC).to receive(:stow_crafting_item).with(anything, 'duffel bag', nil)
        allow(DRCC).to receive(:logbook_item)

        sew.send(:finish)
      end

      it 'does not stow the crafted item from left hand' do
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCC).to receive(:logbook_item)

        expect(DRCC).not_to receive(:stow_crafting_item).with('small burlap rucksack', anything, anything)

        sew.send(:finish)
      end

      it 'calls logbook_item for log finish' do
        allow(DRCC).to receive(:stow_crafting_item)
        expect(DRCC).to receive(:logbook_item).with('outfitting', 'rucksack', 'duffel bag')

        sew.send(:finish)
      end
    end

    context 'with a dotted noun (game disambiguation syntax)' do
      before do
        sew.instance_variable_set(:@noun, 'small.rucksack')
        $right_hand = 'sewing needles'
        $left_hand = 'small rucksack' # game XML uses space, not dot
      end

      it 'stows the tool from right hand' do
        expect(DRCC).to receive(:stow_crafting_item).with('sewing needles', 'duffel bag', nil).once
        allow(DRCC).to receive(:stow_crafting_item).with(anything, 'duffel bag', nil)
        allow(DRCC).to receive(:logbook_item)

        sew.send(:finish)
      end

      it 'does not stow the crafted item despite dot-vs-space mismatch' do
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCC).to receive(:logbook_item)

        expect(DRCC).not_to receive(:stow_crafting_item).with('small rucksack', anything, anything)

        sew.send(:finish)
      end

      it 'calls logbook_item with the dotted noun' do
        allow(DRCC).to receive(:stow_crafting_item)
        expect(DRCC).to receive(:logbook_item).with('outfitting', 'small.rucksack', 'duffel bag')

        sew.send(:finish)
      end
    end

    context 'with nil hands (empty)' do
      before do
        $right_hand = nil
        $left_hand = nil
      end

      it 'handles nil gracefully and still calls logbook_item' do
        allow(DRCC).to receive(:stow_crafting_item)
        expect(DRCC).to receive(:logbook_item).with('outfitting', 'rucksack', 'duffel bag')

        sew.send(:finish)
      end
    end

    context 'with hold finish' do
      before do
        sew.instance_variable_set(:@finish, 'hold')
        sew.instance_variable_set(:@noun, 'small.rucksack')
        $right_hand = 'sewing needles'
        $left_hand = 'small rucksack'
      end

      it 'does not call logbook_item' do
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRC).to receive(:message)

        expect(DRCC).not_to receive(:logbook_item)

        sew.send(:finish)
      end

      it 'keeps the crafted item in hand' do
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRC).to receive(:message)

        expect(DRCC).not_to receive(:stow_crafting_item).with('small rucksack', anything, anything)

        sew.send(:finish)
      end
    end
  end

  # ===========================================================================
  # #lift_or_stow_feet — handling items at feet with dot notation
  # ===========================================================================
  describe '#lift_or_stow_feet' do
    before do
      # Unstub so we test the real method
      allow(sew).to receive(:lift_or_stow_feet).and_call_original
    end

    context 'when items at feet and lift succeeds' do
      before do
        allow(DRCI).to receive(:lift?).and_return(true)
      end

      it 'stows non-noun items picked up from feet' do
        sew.instance_variable_set(:@noun, 'small.rucksack')
        $right_hand = 'burlap cloth'
        $left_hand = nil

        expect(DRCC).to receive(:stow_crafting_item).with('burlap cloth', 'duffel bag', nil)

        sew.send(:lift_or_stow_feet)
      end

      it 'does not stow the crafted item even with dot notation' do
        sew.instance_variable_set(:@noun, 'small.rucksack')
        $right_hand = 'small rucksack'
        $left_hand = nil

        expect(DRCC).not_to receive(:stow_crafting_item)

        sew.send(:lift_or_stow_feet)
      end

      it 'handles simple nouns correctly' do
        sew.instance_variable_set(:@noun, 'rucksack')
        $right_hand = 'small burlap rucksack'
        $left_hand = nil

        expect(DRCC).not_to receive(:stow_crafting_item)

        sew.send(:lift_or_stow_feet)
      end
    end

    context 'when no items at feet' do
      before do
        allow(DRCI).to receive(:lift?).and_return(false)
      end

      it 'calls stow feet command' do
        expect(DRC).to receive(:bput).with('stow feet', 'You put', 'Stow what')

        sew.send(:lift_or_stow_feet)
      end
    end
  end
end
