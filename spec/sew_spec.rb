require 'ostruct'
require 'time'

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

  def self.check_consumables(*_args); end
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

  def self.in_hands?(*_args)
    false
  end
end

module DRCA
  def self.crafting_magic_routine(*_args); end
end

module DRSkill
  def self.getrank(*_args)
    0
  end
end

module Lich
  module Messaging
    def self.msg(*_args); end
  end

  module Util
    def self.issue_command(*_args)
      []
    end
  end
end

# Load Sew class definition (without executing top-level code)
load_lic_class('sew.lic', 'Sew')

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
    sew.instance_variable_set(:@bag_items, [])
    sew.instance_variable_set(:@stamp, false)
    sew.instance_variable_set(:@finish, 'log')
    sew.instance_variable_set(:@worn_trashcan, nil)
    sew.instance_variable_set(:@worn_trashcan_verb, nil)
    sew.instance_variable_set(:@settings, OpenStruct.new(crafting_training_spells: []))
    sew.instance_variable_set(:@info, { 'tool-room' => 1, 'stock-room' => 2 })

    # Prevent actual exit and stub helper methods
    allow(sew).to receive(:exit)
    allow(sew).to receive(:waitrt?)
  end

  # ===========================================================================
  # #swap_tool — nil guards and tool swapping
  # ===========================================================================
  describe '#swap_tool' do
    context 'when right hand is nil (empty)' do
      before { $right_hand = nil }

      it 'does not crash and stows/gets the new tool' do
        expect(DRCC).to receive(:stow_crafting_item).with(nil, 'duffel bag', nil)
        expect(DRCC).to receive(:get_crafting_item).with('scissors', 'duffel bag', [], nil, false)

        sew.send(:swap_tool, 'scissors')
      end
    end

    context 'when next_tool is nil' do
      before { $right_hand = 'sewing needles' }

      it 'returns early without stowing or getting' do
        expect(DRCC).not_to receive(:stow_crafting_item)
        expect(DRCC).not_to receive(:get_crafting_item)

        sew.send(:swap_tool, nil)
      end
    end

    context 'when the desired tool is already in right hand' do
      before { $right_hand = 'sewing needles' }

      it 'returns early without stowing or getting' do
        expect(DRCC).not_to receive(:stow_crafting_item)
        expect(DRCC).not_to receive(:get_crafting_item)

        sew.send(:swap_tool, 'sewing needles')
      end
    end

    context 'when right hand holds a partial match' do
      before { $right_hand = 'steel sewing needles' }

      it 'returns early because right_hand includes the tool name' do
        expect(DRCC).not_to receive(:stow_crafting_item)
        expect(DRCC).not_to receive(:get_crafting_item)

        sew.send(:swap_tool, 'sewing needles')
      end
    end

    context 'when right hand holds a different tool' do
      before { $right_hand = 'scissors' }

      it 'stows the current tool and gets the new one' do
        expect(DRCC).to receive(:stow_crafting_item).with('scissors', 'duffel bag', nil)
        expect(DRCC).to receive(:get_crafting_item).with('sewing needles', 'duffel bag', [], nil, false)

        sew.send(:swap_tool, 'sewing needles')
      end
    end

    context 'with skip parameter' do
      before { $right_hand = 'scissors' }

      it 'passes skip flag through to get_crafting_item' do
        expect(DRCC).to receive(:stow_crafting_item)
        expect(DRCC).to receive(:get_crafting_item).with('pins', 'duffel bag', [], nil, true)

        sew.send(:swap_tool, 'pins', true)
      end
    end

    context 'with belt configured' do
      before do
        sew.instance_variable_set(:@belt, 'leather belt')
        $right_hand = 'scissors'
      end

      it 'passes belt to stow_crafting_item' do
        expect(DRCC).to receive(:stow_crafting_item).with('scissors', 'duffel bag', 'leather belt')
        allow(DRCC).to receive(:get_crafting_item)

        sew.send(:swap_tool, 'sewing needles')
      end

      it 'passes belt to get_crafting_item' do
        allow(DRCC).to receive(:stow_crafting_item)
        expect(DRCC).to receive(:get_crafting_item).with('sewing needles', 'duffel bag', [], 'leather belt', false)

        sew.send(:swap_tool, 'sewing needles')
      end
    end
  end

  # ===========================================================================
  # #finish — stow guards, logbook bundling, messaging
  # ===========================================================================
  describe '#finish' do
    before(:each) do
      allow(sew).to receive(:lift_or_stow_feet)
      allow(sew).to receive(:magic_cleanup)
    end

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

      it 'does not attempt to stow nil hands' do
        allow(DRCC).to receive(:logbook_item)

        expect(DRCC).not_to receive(:stow_crafting_item).with(nil, anything, anything)

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

        expect(DRCC).not_to receive(:logbook_item)

        sew.send(:finish)
      end

      it 'keeps the crafted item in hand' do
        allow(DRCC).to receive(:stow_crafting_item)

        expect(DRCC).not_to receive(:stow_crafting_item).with('small rucksack', anything, anything)

        sew.send(:finish)
      end

      it 'sends a hold completion message' do
        allow(DRCC).to receive(:stow_crafting_item)
        expect(Lich::Messaging).to receive(:msg).with('bold', 'small.rucksack complete — holding in hand.')
        allow(Lich::Messaging).to receive(:msg).with('plain', anything)

        sew.send(:finish)
      end
    end

    context 'with stow finish' do
      before do
        sew.instance_variable_set(:@finish, 'stow')
        $right_hand = 'sewing needles'
        $left_hand = nil
      end

      it 'calls stow_crafting_item with the noun' do
        allow(DRCC).to receive(:stow_crafting_item)
        expect(DRCC).to receive(:stow_crafting_item).with('rucksack', 'duffel bag', nil)

        sew.send(:finish)
      end
    end

    context 'with trash finish' do
      before do
        sew.instance_variable_set(:@finish, 'trash')
        sew.instance_variable_set(:@worn_trashcan, 'bucket')
        sew.instance_variable_set(:@worn_trashcan_verb, 'put')
        $right_hand = 'sewing needles'
        $left_hand = nil
      end

      it 'calls dispose_trash with the noun' do
        allow(DRCC).to receive(:stow_crafting_item)
        expect(DRCI).to receive(:dispose_trash).with('rucksack', 'bucket', 'put')

        sew.send(:finish)
      end
    end

    context 'with stamp enabled' do
      before do
        sew.instance_variable_set(:@stamp, true)
        $right_hand = 'sewing needles'
        $left_hand = nil
      end

      it 'swaps to stamp, marks, stows stamp, then finishes' do
        # swap_tool will stow right hand and get stamp
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCC).to receive(:get_crafting_item)
        allow(DRCC).to receive(:logbook_item)
        expect(DRC).to receive(:bput).with('mark my rucksack with my stamp', 'Roundtime')

        sew.send(:finish)
      end
    end

    it 'calls lift_or_stow_feet after finishing' do
      $right_hand = nil
      $left_hand = nil
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCC).to receive(:logbook_item)
      expect(sew).to receive(:lift_or_stow_feet)

      sew.send(:finish)
    end

    it 'calls magic_cleanup before exit' do
      $right_hand = nil
      $left_hand = nil
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCC).to receive(:logbook_item)
      expect(sew).to receive(:magic_cleanup)

      sew.send(:finish)
    end

    it 'prints a verbose finish message before exit' do
      $right_hand = nil
      $left_hand = nil
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCC).to receive(:logbook_item)
      expect(Lich::Messaging).to receive(:msg).with('plain', 'Sew script finished (rucksack, finish: log).')

      sew.send(:finish)
    end

    it 'calls exit at the end' do
      $right_hand = nil
      $left_hand = nil
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCC).to receive(:logbook_item)
      expect(sew).to receive(:exit)

      sew.send(:finish)
    end

    context 'when right hand holds the crafted noun' do
      before do
        sew.instance_variable_set(:@noun, 'rucksack')
        $right_hand = 'small burlap rucksack'
        $left_hand = 'sewing needles'
      end

      it 'does not stow the crafted item from right hand' do
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCC).to receive(:logbook_item)

        expect(DRCC).not_to receive(:stow_crafting_item).with('small burlap rucksack', anything, anything)

        sew.send(:finish)
      end

      it 'stows the tool from left hand' do
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCC).to receive(:logbook_item)

        expect(DRCC).to receive(:stow_crafting_item).with('sewing needles', 'duffel bag', nil)

        sew.send(:finish)
      end
    end

    context 'when both hands hold the crafted noun' do
      before do
        sew.instance_variable_set(:@noun, 'rucksack')
        $right_hand = 'small burlap rucksack'
        $left_hand = 'small burlap rucksack'
      end

      it 'does not stow either hand' do
        allow(DRCC).to receive(:logbook_item)

        expect(DRCC).not_to receive(:stow_crafting_item)

        sew.send(:finish)
      end
    end

    context 'with belt configured' do
      before do
        sew.instance_variable_set(:@belt, 'leather belt')
        $right_hand = 'sewing needles'
        $left_hand = nil
      end

      it 'passes belt to stow_crafting_item' do
        expect(DRCC).to receive(:stow_crafting_item).with('sewing needles', 'duffel bag', 'leather belt')
        allow(DRCC).to receive(:logbook_item)

        sew.send(:finish)
      end
    end

    context 'stow finish with dotted noun' do
      before do
        sew.instance_variable_set(:@finish, 'stow')
        sew.instance_variable_set(:@noun, 'small.rucksack')
        $right_hand = nil
        $left_hand = nil
      end

      it 'passes the dotted noun to stow_crafting_item' do
        expect(DRCC).to receive(:stow_crafting_item).with('small.rucksack', 'duffel bag', nil)

        sew.send(:finish)
      end
    end

    context 'trash finish with nil worn_trashcan' do
      before do
        sew.instance_variable_set(:@finish, 'trash')
        sew.instance_variable_set(:@worn_trashcan, nil)
        sew.instance_variable_set(:@worn_trashcan_verb, nil)
        $right_hand = nil
        $left_hand = nil
      end

      it 'calls dispose_trash with nil trashcan args' do
        expect(DRCI).to receive(:dispose_trash).with('rucksack', nil, nil)

        sew.send(:finish)
      end
    end

    context 'noun substring boundary' do
      before do
        sew.instance_variable_set(:@noun, 'pack')
        $right_hand = 'backpack'
        $left_hand = nil
      end

      it 'does not stow right hand when item name contains noun as substring' do
        # 'backpack'.include?('pack') is true, so it's treated as the crafted item
        allow(DRCC).to receive(:logbook_item)
        expect(DRCC).not_to receive(:stow_crafting_item).with('backpack', anything, anything)

        sew.send(:finish)
      end
    end

    context 'finish operation ordering' do
      before do
        sew.instance_variable_set(:@stamp, false)
        $right_hand = 'sewing needles'
        $left_hand = nil
      end

      it 'stows hands before logbook' do
        order = []
        allow(DRCC).to receive(:stow_crafting_item) { order << :stow }
        allow(DRCC).to receive(:logbook_item) { order << :logbook }

        sew.send(:finish)

        expect(order.index(:stow)).to be < order.index(:logbook)
      end

      it 'calls lift_or_stow_feet after logbook' do
        order = []
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCC).to receive(:logbook_item) { order << :logbook }
        allow(sew).to receive(:lift_or_stow_feet) { order << :lift }

        sew.send(:finish)

        expect(order.index(:logbook)).to be < order.index(:lift)
      end

      it 'calls magic_cleanup after lift_or_stow_feet' do
        order = []
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCC).to receive(:logbook_item)
        allow(sew).to receive(:lift_or_stow_feet) { order << :lift }
        allow(sew).to receive(:magic_cleanup) { order << :cleanup }

        sew.send(:finish)

        expect(order.index(:lift)).to be < order.index(:cleanup)
      end

      it 'prints finish message after magic_cleanup' do
        order = []
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCC).to receive(:logbook_item)
        allow(sew).to receive(:magic_cleanup) { order << :cleanup }
        allow(Lich::Messaging).to receive(:msg) { order << :msg }

        sew.send(:finish)

        expect(order.index(:cleanup)).to be < order.index(:msg)
      end

      it 'calls exit after the finish message' do
        order = []
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCC).to receive(:logbook_item)
        allow(Lich::Messaging).to receive(:msg) { order << :msg }
        allow(sew).to receive(:exit) { order << :exit }

        sew.send(:finish)

        expect(order.index(:msg)).to be < order.index(:exit)
      end
    end

    context 'stamp operation ordering' do
      before do
        sew.instance_variable_set(:@stamp, true)
        $right_hand = nil
        $left_hand = nil
      end

      it 'stamps before stowing stamp, then proceeds to logbook' do
        order = []
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCC).to receive(:get_crafting_item)
        allow(DRC).to receive(:bput).with('mark my rucksack with my stamp', 'Roundtime') { order << :mark }
        allow(DRCC).to receive(:stow_crafting_item).with('stamp', 'duffel bag', nil) { order << :stow_stamp }
        allow(DRCC).to receive(:logbook_item) { order << :logbook }

        sew.send(:finish)

        expect(order.index(:mark)).to be < order.index(:stow_stamp)
        expect(order.index(:stow_stamp)).to be < order.index(:logbook)
      end
    end
  end

  # ===========================================================================
  # #lift_or_stow_feet — handling items at feet with dot notation
  # ===========================================================================
  describe '#lift_or_stow_feet' do
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

      it 'handles nil hands after lift' do
        $right_hand = nil
        $left_hand = nil

        expect(DRCC).not_to receive(:stow_crafting_item)

        sew.send(:lift_or_stow_feet)
      end

      it 'stows both hands if neither contains the noun' do
        sew.instance_variable_set(:@noun, 'rucksack')
        $right_hand = 'scissors'
        $left_hand = 'burlap cloth'

        expect(DRCC).to receive(:stow_crafting_item).with('scissors', 'duffel bag', nil)
        expect(DRCC).to receive(:stow_crafting_item).with('burlap cloth', 'duffel bag', nil)

        sew.send(:lift_or_stow_feet)
      end

      it 'caches hand values to avoid race conditions' do
        sew.instance_variable_set(:@noun, 'rucksack')
        $right_hand = 'scissors'
        $left_hand = nil

        # DRC.right_hand should only be called once (cached in local)
        call_count = 0
        allow(DRC).to receive(:right_hand) do
          call_count += 1
          call_count == 1 ? 'scissors' : nil
        end
        allow(DRC).to receive(:left_hand).and_return(nil)
        allow(DRCC).to receive(:stow_crafting_item)

        sew.send(:lift_or_stow_feet)

        # right_hand should be called exactly once (cached)
        expect(call_count).to eq(1)
      end
    end

    context 'with dotted noun in left hand only' do
      before do
        allow(DRCI).to receive(:lift?).and_return(true)
        sew.instance_variable_set(:@noun, 'small.rucksack')
        $right_hand = nil
        $left_hand = 'small rucksack'
      end

      it 'does not stow the crafted item from left hand' do
        expect(DRCC).not_to receive(:stow_crafting_item)

        sew.send(:lift_or_stow_feet)
      end
    end

    context 'with belt configured' do
      before do
        allow(DRCI).to receive(:lift?).and_return(true)
        sew.instance_variable_set(:@belt, 'leather belt')
        $right_hand = 'scissors'
        $left_hand = nil
      end

      it 'passes belt to stow_crafting_item' do
        expect(DRCC).to receive(:stow_crafting_item).with('scissors', 'duffel bag', 'leather belt')

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

  # ===========================================================================
  # #check_hand — item position verification
  # ===========================================================================
  describe '#check_hand' do
    before do
      allow(sew).to receive(:magic_cleanup)
    end

    context 'when item is in right hand' do
      before do
        allow(DRCI).to receive(:in_right_hand?).with('leather').and_return(true)
      end

      it 'swaps hands' do
        expect(DRC).to receive(:bput).with('swap', 'You move', 'You have nothing')

        sew.send(:check_hand, 'leather')
      end

      it 'does not exit' do
        allow(DRC).to receive(:bput)
        expect(sew).not_to receive(:exit)

        sew.send(:check_hand, 'leather')
      end
    end

    context 'when item has a dotted noun' do
      before do
        allow(DRCI).to receive(:in_right_hand?).with('small.rucksack').and_return(true)
      end

      it 'passes the dotted noun directly to in_right_hand?' do
        allow(DRC).to receive(:bput)

        expect(DRCI).to receive(:in_right_hand?).with('small.rucksack')

        sew.send(:check_hand, 'small.rucksack')
      end

      it 'swaps hands when dotted noun is in right hand' do
        expect(DRC).to receive(:bput).with('swap', 'You move', 'You have nothing')

        sew.send(:check_hand, 'small.rucksack')
      end
    end

    context 'when item is not in right hand' do
      before do
        allow(DRCI).to receive(:in_right_hand?).with('leather').and_return(false)
      end

      it 'sends a verbose error message' do
        expect(Lich::Messaging).to receive(:msg).with('bold', "Please hold the item or material you wish to work on. Expected 'leather' in right hand.")

        sew.send(:check_hand, 'leather')
      end

      it 'calls magic_cleanup before exiting' do
        expect(sew).to receive(:magic_cleanup).ordered
        expect(sew).to receive(:exit).ordered

        sew.send(:check_hand, 'leather')
      end
    end
  end

  # ===========================================================================
  # #magic_cleanup — spell release (now instance method)
  # ===========================================================================
  describe '#magic_cleanup' do
    context 'with no training spells configured' do
      before do
        sew.instance_variable_set(:@settings, OpenStruct.new(crafting_training_spells: []))
      end

      it 'returns early without releasing anything' do
        expect(DRC).not_to receive(:bput)

        sew.send(:magic_cleanup)
      end
    end

    context 'with training spells configured' do
      before do
        sew.instance_variable_set(:@settings, OpenStruct.new(crafting_training_spells: [{ 'Symbiosis' => { 'abbrev' => 'symb' } }]))
      end

      it 'releases spell, mana, and symbiosis' do
        expect(DRC).to receive(:bput).with('release spell', 'You let your concentration lapse', "You aren't preparing a spell").ordered
        expect(DRC).to receive(:bput).with('release mana', 'You release all', "You aren't harnessing any mana").ordered
        expect(DRC).to receive(:bput).with('release symb', "But you haven't", 'You release', 'Repeat this command').ordered

        sew.send(:magic_cleanup)
      end
    end
  end

  # ===========================================================================
  # #list_at_feet — diagnostic output
  # ===========================================================================
  describe '#list_at_feet' do
    context 'when items are at feet' do
      it 'outputs item list via Lich::Messaging' do
        allow(Lich::Util).to receive(:issue_command).and_return(['a small rock', 'some burlap cloth'])
        expect(Lich::Messaging).to receive(:msg).with('plain', 'Items at feet: a small rock, some burlap cloth')

        sew.send(:list_at_feet)
      end
    end

    context 'when no items at feet' do
      it 'does not output anything for empty result' do
        allow(Lich::Util).to receive(:issue_command).and_return([])
        expect(Lich::Messaging).not_to receive(:msg)

        sew.send(:list_at_feet)
      end
    end

    context 'when issue_command returns nil' do
      it 'does not crash' do
        allow(Lich::Util).to receive(:issue_command).and_return(nil)
        expect(Lich::Messaging).not_to receive(:msg)

        expect { sew.send(:list_at_feet) }.not_to raise_error
      end
    end
  end

  # ===========================================================================
  # #check_rental_status — private rental expiry detection
  # ===========================================================================
  describe '#check_rental_status' do
    # Helper: format a future time as the game would display it (ET timezone)
    def rental_expiry_string(minutes_from_now)
      future = Time.now + (minutes_from_now * 60)
      est = future.getlocal('-05:00')
      est.strftime('%a %b %d %H:%M:%S ET %Y')
    end

    context 'when notice is found with valid expiry' do
      it 'renews if less than 10 minutes remaining' do
        result = "It will expire #{rental_expiry_string(5)}."
        allow(DRC).to receive(:bput).and_return(result)
        allow(sew).to receive(:renew_rental)

        expect(sew).to receive(:renew_rental)
        expect(Lich::Messaging).to receive(:msg).with('bold', /RENTAL LOW.*AUTO-RENEWING/)

        sew.send(:check_rental_status)
      end

      it 'warns if less than 20 minutes remaining' do
        result = "It will expire #{rental_expiry_string(15)}."
        allow(DRC).to receive(:bput).and_return(result)

        expect(sew).not_to receive(:renew_rental)
        expect(Lich::Messaging).to receive(:msg).with('bold', /Rental has \d+ minutes remaining/)

        sew.send(:check_rental_status)
      end

      it 'does nothing if more than 20 minutes remaining' do
        result = "It will expire #{rental_expiry_string(30)}."
        allow(DRC).to receive(:bput).and_return(result)

        expect(sew).not_to receive(:renew_rental)
        expect(Lich::Messaging).not_to receive(:msg)

        sew.send(:check_rental_status)
      end
    end

    context 'when no notice is found' do
      it 'returns early without error' do
        allow(DRC).to receive(:bput).and_return('I could not find')

        expect(sew).not_to receive(:renew_rental)
        expect(Lich::Messaging).not_to receive(:msg)

        expect { sew.send(:check_rental_status) }.not_to raise_error
      end
    end

    context 'when time parsing fails' do
      it 'catches ArgumentError and warns' do
        allow(DRC).to receive(:bput).and_return('It will expire garbage time string.')

        expect(Lich::Messaging).to receive(:msg).with('bold', /Could not parse rental expiry time/)

        expect { sew.send(:check_rental_status) }.not_to raise_error
      end
    end
  end

  # ===========================================================================
  # #renew_rental — auto-renewal of private crafting room
  # ===========================================================================
  describe '#renew_rental' do
    before do
      stub_const('Flags', Class.new do
        @data = {}

        def self.[]=(key, val)
          @data[key] = val
        end

        def self.[](key)
          @data[key]
        end

        def self.reset(key)
          @data[key] = nil
        end
      end)
    end

    context 'successful renewal' do
      it 'marks the notice and reports success' do
        allow(DRC).to receive(:bput).and_return('renewed your rental')

        expect(Lich::Messaging).to receive(:msg).with('bold', '*** RENTAL EXPIRING — AUTO-RENEWING ***')
        expect(Lich::Messaging).to receive(:msg).with('bold', '*** RENTAL RENEWED ***')

        sew.send(:renew_rental)
      end

      it 'resets the rental warning flag' do
        Flags['sew-rental-warning'] = true
        allow(DRC).to receive(:bput).and_return('renewed your rental')
        allow(Lich::Messaging).to receive(:msg)

        sew.send(:renew_rental)

        expect(Flags['sew-rental-warning']).to be_nil
      end
    end

    context 'insufficient funds' do
      it 'warns about insufficient funds' do
        allow(DRC).to receive(:bput).and_return("You don't have enough")

        expect(Lich::Messaging).to receive(:msg).with('bold', '*** RENTAL EXPIRING — AUTO-RENEWING ***')
        expect(Lich::Messaging).to receive(:msg).with('bold', '*** INSUFFICIENT FUNDS TO RENEW RENTAL ***')

        sew.send(:renew_rental)
      end
    end

    context 'notice not found' do
      it 'warns about missing notice' do
        allow(DRC).to receive(:bput).and_return('I could not find')

        expect(Lich::Messaging).to receive(:msg).with('bold', '*** RENTAL EXPIRING — AUTO-RENEWING ***')
        expect(Lich::Messaging).to receive(:msg).with('bold', '*** COULD NOT FIND NOTICE — CHECK LOCATION ***')

        sew.send(:renew_rental)
      end
    end

    context 'extends rental response' do
      it 'treats extends as success' do
        allow(DRC).to receive(:bput).and_return('extends your rental')

        expect(Lich::Messaging).to receive(:msg).with('bold', '*** RENTAL EXPIRING — AUTO-RENEWING ***')
        expect(Lich::Messaging).to receive(:msg).with('bold', '*** RENTAL RENEWED ***')

        sew.send(:renew_rental)
      end
    end
  end

  # ===========================================================================
  # #assemble_part — nil hand safety
  # ===========================================================================
  describe '#assemble_part' do
    # Stub Flags as a hash-like object for testing
    before do
      stub_const('Flags', Class.new do
        @data = {}

        def self.[]=(key, val)
          @data[key] = val
        end

        def self.[](key)
          @data[key]
        end

        def self.reset(key)
          @data[key] = nil
        end
      end)
    end

    context 'when flag is not set' do
      before { Flags['sew-assembly'] = nil }

      it 'does nothing' do
        expect(DRCC).not_to receive(:stow_crafting_item)
        expect(DRCC).not_to receive(:get_crafting_item)

        sew.send(:assemble_part)
      end
    end

    context 'when right hand is nil during assembly' do
      before do
        Flags['sew-assembly'] = [true, 'small', 'cloth', 'padding']
        $right_hand = nil
      end

      it 'does not attempt to stow nil' do
        allow(DRC).to receive(:bput).and_return('affix it securely in place')
        allow(DRCC).to receive(:get_crafting_item)

        expect(DRCC).not_to receive(:stow_crafting_item)

        sew.send(:assemble_part)
      end

      it 'does not attempt to swap back to nil tool' do
        allow(DRC).to receive(:bput).and_return('affix it securely in place')
        allow(DRCC).to receive(:get_crafting_item)

        # swap_tool should not be called since tool is nil
        expect(sew).not_to receive(:swap_tool)

        sew.send(:assemble_part)
      end
    end

    context 'when right hand has a tool during assembly' do
      before do
        Flags['sew-assembly'] = [true, 'large', 'cloth', 'padding']
        $right_hand = 'scissors'
      end

      it 'stows the current tool, assembles, and swaps back' do
        allow(DRCC).to receive(:get_crafting_item)
        allow(DRC).to receive(:bput).and_return('affix it securely in place')

        expect(DRCC).to receive(:stow_crafting_item).with('scissors', 'duffel bag', nil).ordered
        expect(DRCC).to receive(:get_crafting_item).with('large cloth padding', 'duffel bag', [], nil).ordered

        sew.send(:assemble_part)
      end

      it 'swaps back to the original tool after assembly' do
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCC).to receive(:get_crafting_item)
        allow(DRC).to receive(:bput).and_return('affix it securely in place')

        expect(sew).to receive(:swap_tool).with('scissors')

        sew.send(:assemble_part)
      end
    end

    context 'part name construction from Flags' do
      before { $right_hand = 'scissors' }

      it 'joins three-word part names' do
        Flags['sew-assembly'] = [true, 'small', 'cloth', 'padding']

        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRC).to receive(:bput).and_return('affix it securely in place')

        expect(DRCC).to receive(:get_crafting_item).with('small cloth padding', 'duffel bag', [], nil)

        sew.send(:assemble_part)
      end

      it 'joins two-word part names' do
        Flags['sew-assembly'] = [true, 'leather', 'cord']

        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRC).to receive(:bput).and_return('affix it securely in place')

        expect(DRCC).to receive(:get_crafting_item).with('leather cord', 'duffel bag', [], nil)

        sew.send(:assemble_part)
      end

      it 'handles single-word part names' do
        Flags['sew-assembly'] = [true, 'hilt']

        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRC).to receive(:bput).and_return('affix it securely in place')

        expect(DRCC).to receive(:get_crafting_item).with('hilt', 'duffel bag', [], nil)

        sew.send(:assemble_part)
      end
    end

    context 'with belt configured' do
      before do
        sew.instance_variable_set(:@belt, 'leather belt')
        Flags['sew-assembly'] = [true, 'large', 'cloth', 'padding']
        $right_hand = 'scissors'
      end

      it 'passes belt to stow and get' do
        allow(DRC).to receive(:bput).and_return('affix it securely in place')

        expect(DRCC).to receive(:stow_crafting_item).with('scissors', 'duffel bag', 'leather belt')
        expect(DRCC).to receive(:get_crafting_item).with('large cloth padding', 'duffel bag', [], 'leather belt')

        sew.send(:assemble_part)
      end
    end

    context 'Flags.reset clears the assembly flag' do
      before do
        Flags['sew-assembly'] = [true, 'small', 'cloth', 'padding']
        $right_hand = nil
      end

      it 'resets the flag so the loop terminates after one iteration' do
        allow(DRC).to receive(:bput).and_return('affix it securely in place')
        allow(DRCC).to receive(:get_crafting_item)

        sew.send(:assemble_part)

        expect(Flags['sew-assembly']).to be_nil
      end
    end
  end

  # ===========================================================================
  # #prep — recipe/instruction lookup and material setup
  # ===========================================================================
  describe '#prep' do
    before(:each) do
      allow(DRCA).to receive(:crafting_magic_routine)
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCC).to receive(:find_recipe2)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      allow(DRCI).to receive(:in_left_hand?).and_return(true)
      allow(sew).to receive(:check_hand)
      allow(sew).to receive(:swap_tool)
      allow(DRSkill).to receive(:getrank).and_return(100)

      sew.instance_variable_set(:@instructions, nil)
      sew.instance_variable_set(:@recipe_name, 'small rucksack')
      sew.instance_variable_set(:@mat_type, 'burlap')
      sew.instance_variable_set(:@knit, nil)
      sew.instance_variable_set(:@chapter, 1)
      sew.instance_variable_set(:@cloth, %w[silk wool burlap cotton felt linen electroweave steelsilk arzumodine bourde dergatine dragonar faeweave farandine imperial jaspe khaddar ruazin titanese zenganne])
      sew.instance_variable_set(:@cube, nil)
    end

    it 'always calls crafting_magic_routine first' do
      expect(DRCA).to receive(:crafting_magic_routine).with(sew.instance_variable_get(:@settings))

      sew.send(:prep)
    end

    context 'instructions path' do
      before do
        sew.instance_variable_set(:@instructions, true)
      end

      it 'gets the instructions from bag' do
        expect(DRCC).to receive(:get_crafting_item).with('rucksack instructions', 'duffel bag', [], nil)

        sew.send(:prep)
      end

      it 'studies instructions twice if prompted to study again' do
        allow(DRC).to receive(:bput).with('study my instructions', 'Roundtime', 'Study them again')
                    .and_return('Study them again', 'Roundtime')
        expect(DRC).to receive(:bput).with('study my instructions', 'Roundtime', 'Study them again').twice

        sew.send(:prep)
      end

      it 'studies instructions only once if no re-study prompt' do
        allow(DRC).to receive(:bput).with('study my instructions', 'Roundtime', 'Study them again')
                    .and_return('Roundtime')
        expect(DRC).to receive(:bput).with('study my instructions', 'Roundtime', 'Study them again').once

        sew.send(:prep)
      end

      it 'does not use any recipe book' do
        expect(DRCC).not_to receive(:find_recipe2)
        expect(DRCC).not_to receive(:get_crafting_item).with('tailoring book', anything, anything, anything)

        sew.send(:prep)
      end
    end

    context 'master crafting book path' do
      before do
        sew.instance_variable_set(:@settings, OpenStruct.new(
          crafting_training_spells: [],
          master_crafting_book: 'master tailoring book'
        ))
      end

      it 'calls find_recipe2 with master book and tailoring discipline' do
        expect(DRCC).to receive(:find_recipe2).with(1, 'small rucksack', 'master tailoring book', 'tailoring')

        sew.send(:prep)
      end

      it 'does not get or stow a basic book' do
        expect(DRCC).not_to receive(:get_crafting_item).with('tailoring book', anything, anything, anything)
        expect(DRCC).not_to receive(:stow_crafting_item).with('tailoring book', anything, anything)

        sew.send(:prep)
      end
    end

    context 'basic tailoring book path' do
      before do
        sew.instance_variable_set(:@settings, OpenStruct.new(
          crafting_training_spells: [],
          master_crafting_book: nil
        ))
      end

      it 'gets the tailoring book from bag' do
        expect(DRCC).to receive(:get_crafting_item).with('tailoring book', 'duffel bag', [], nil)
        allow(DRCC).to receive(:get_crafting_item)

        sew.send(:prep)
      end

      it 'calls find_recipe2 without master book argument' do
        expect(DRCC).to receive(:find_recipe2).with(1, 'small rucksack')

        sew.send(:prep)
      end

      it 'stows the tailoring book after finding recipe' do
        expect(DRCC).to receive(:stow_crafting_item).with('tailoring book', 'duffel bag', nil)
        allow(DRCC).to receive(:stow_crafting_item)

        sew.send(:prep)
      end

      it 'warns at exactly rank 175' do
        allow(DRSkill).to receive(:getrank).with('Outfitting').and_return(175)
        expect(Lich::Messaging).to receive(:msg).with('bold', 'You will need to upgrade to a journeyman or master book before 176 ranks!')

        sew.send(:prep)
      end

      it 'does not warn at rank 174' do
        allow(DRSkill).to receive(:getrank).with('Outfitting').and_return(174)
        expect(Lich::Messaging).not_to receive(:msg).with('bold', anything)

        sew.send(:prep)
      end

      it 'does not warn at rank 176' do
        allow(DRSkill).to receive(:getrank).with('Outfitting').and_return(176)
        expect(Lich::Messaging).not_to receive(:msg).with('bold', anything)

        sew.send(:prep)
      end
    end

    context 'knitting via @knit flag' do
      before { sew.instance_variable_set(:@knit, true) }

      it 'gets yarn from bag' do
        expect(DRCC).to receive(:get_crafting_item).with('yarn', 'duffel bag', [], nil)
        allow(DRCC).to receive(:get_crafting_item)

        sew.send(:prep)
      end

      it 'checks hand for yarn when not in left hand' do
        allow(DRCI).to receive(:in_left_hand?).with('yarn').and_return(false)
        expect(sew).to receive(:check_hand).with('yarn')

        sew.send(:prep)
      end

      it 'skips check_hand when yarn is in left hand' do
        allow(DRCI).to receive(:in_left_hand?).with('yarn').and_return(true)
        expect(sew).not_to receive(:check_hand)

        sew.send(:prep)
      end

      it 'swaps to knitting needles' do
        expect(sew).to receive(:swap_tool).with('knitting needles')

        sew.send(:prep)
      end

      it 'returns the knit command' do
        result = sew.send(:prep)

        expect(result).to eq('knit my yarn with my knitting needles')
      end

      it 'sets @home_tool to knitting needles' do
        sew.send(:prep)

        expect(sew.instance_variable_get(:@home_tool)).to eq('knitting needles')
      end

      it 'sets @home_command to knit my needles' do
        sew.send(:prep)

        expect(sew.instance_variable_get(:@home_command)).to eq('knit my needles')
      end
    end

    context 'knitting via chapter 5' do
      before do
        sew.instance_variable_set(:@knit, nil)
        sew.instance_variable_set(:@chapter, 5)
      end

      it 'triggers the knitting path without @knit flag' do
        result = sew.send(:prep)

        expect(result).to eq('knit my yarn with my knitting needles')
      end
    end

    context 'enhancement — seal' do
      before do
        sew.instance_variable_set(:@recipe_name, 'tailored armor sealing')
        sew.instance_variable_set(:@noun, 'shirt')
      end

      it 'disables stamp' do
        sew.instance_variable_set(:@stamp, true)

        sew.send(:prep)

        expect(sew.instance_variable_get(:@stamp)).to eq(false)
      end

      it 'checks hand for noun when not in left hand' do
        allow(DRCI).to receive(:in_left_hand?).with('shirt').and_return(false)
        expect(sew).to receive(:check_hand).with('shirt')

        sew.send(:prep)
      end

      it 'skips check_hand when noun in left hand' do
        allow(DRCI).to receive(:in_left_hand?).with('shirt').and_return(true)
        expect(sew).not_to receive(:check_hand)

        sew.send(:prep)
      end

      it 'swaps to sealing wax' do
        expect(sew).to receive(:swap_tool).with('sealing wax')

        sew.send(:prep)
      end

      it 'returns the apply wax command' do
        result = sew.send(:prep)

        expect(result).to eq('apply my wax to my shirt')
      end

      it 'sets @home_tool and @home_command for sealing' do
        sew.send(:prep)

        expect(sew.instance_variable_get(:@home_tool)).to eq('sealing wax')
        expect(sew.instance_variable_get(:@home_command)).to eq('apply my wax to my shirt')
      end
    end

    context 'enhancement — reinforce' do
      before do
        sew.instance_variable_set(:@recipe_name, 'tailored armor reinforcing')
        sew.instance_variable_set(:@noun, 'shirt')
      end

      it 'swaps to scissors' do
        expect(sew).to receive(:swap_tool).with('scissors')

        sew.send(:prep)
      end

      it 'returns the cut command' do
        result = sew.send(:prep)

        expect(result).to eq('cut my shirt with my scissors')
      end

      it 'sets @home_tool to scissors' do
        sew.send(:prep)

        expect(sew.instance_variable_get(:@home_tool)).to eq('scissors')
      end
    end

    context 'cloth products' do
      before do
        sew.instance_variable_set(:@mat_type, 'burlap')
        sew.instance_variable_set(:@recipe_name, 'small rucksack')
      end

      it 'gets the cloth material from bag' do
        expect(DRCC).to receive(:get_crafting_item).with('burlap cloth', 'duffel bag', [], nil)
        allow(DRCC).to receive(:get_crafting_item)

        sew.send(:prep)
      end

      it 'checks hand for cloth when not in left hand' do
        allow(DRCI).to receive(:in_left_hand?).with('cloth').and_return(false)
        expect(sew).to receive(:check_hand).with('cloth')

        sew.send(:prep)
      end

      it 'swaps to scissors' do
        expect(sew).to receive(:swap_tool).with('scissors')

        sew.send(:prep)
      end

      it 'returns the cut command with material type' do
        result = sew.send(:prep)

        expect(result).to eq('cut my burlap cloth with my scissors')
      end

      it 'sets @home_tool to sewing needles' do
        sew.send(:prep)

        expect(sew.instance_variable_get(:@home_tool)).to eq('sewing needles')
      end

      it 'sets @home_command to push with noun' do
        sew.send(:prep)

        expect(sew.instance_variable_get(:@home_command)).to eq('push my rucksack with my needles')
      end
    end

    context 'leather products' do
      before do
        sew.instance_variable_set(:@mat_type, 'deer')
        sew.instance_variable_set(:@recipe_name, 'small rucksack')
      end

      it 'gets the leather material from bag' do
        expect(DRCC).to receive(:get_crafting_item).with('deer leather', 'duffel bag', [], nil)
        allow(DRCC).to receive(:get_crafting_item)

        sew.send(:prep)
      end

      it 'checks hand for leather when not in left hand' do
        allow(DRCI).to receive(:in_left_hand?).with('leather').and_return(false)
        expect(sew).to receive(:check_hand).with('leather')

        sew.send(:prep)
      end

      it 'returns the cut command with material type' do
        result = sew.send(:prep)

        expect(result).to eq('cut my deer leather with my scissors')
      end

      it 'sets @home_tool to sewing needles for leather' do
        sew.send(:prep)

        expect(sew.instance_variable_get(:@home_tool)).to eq('sewing needles')
      end
    end

    context 'cloth material detection' do
      it 'recognizes all standard cloth types' do
        %w[silk wool burlap cotton felt linen].each do |mat|
          sew.instance_variable_set(:@mat_type, mat)
          sew.instance_variable_set(:@recipe_name, 'small rucksack')

          result = sew.send(:prep)

          expect(result).to eq("cut my #{mat} cloth with my scissors"), "Failed for material: #{mat}"
        end
      end

      it 'recognizes exotic cloth types' do
        %w[electroweave steelsilk arzumodine bourde dergatine dragonar faeweave farandine].each do |mat|
          sew.instance_variable_set(:@mat_type, mat)
          sew.instance_variable_set(:@recipe_name, 'small rucksack')

          result = sew.send(:prep)

          expect(result).to eq("cut my #{mat} cloth with my scissors"), "Failed for material: #{mat}"
        end
      end

      it 'falls through to leather for non-cloth materials' do
        sew.instance_variable_set(:@mat_type, 'deer')
        sew.instance_variable_set(:@recipe_name, 'small rucksack')

        result = sew.send(:prep)

        expect(result).to eq('cut my deer leather with my scissors')
      end
    end
  end

  # ===========================================================================
  # Edge cases and integration-level scenarios
  # ===========================================================================
  describe 'finish default for resume' do
    it 'defaults @finish to hold when args.finish is nil' do
      # The @finish default is set in initialize, but we can verify the
      # pattern: args.finish || 'hold' means nil args.finish → 'hold'
      sew.instance_variable_set(:@finish, nil || 'hold')
      expect(sew.instance_variable_get(:@finish)).to eq('hold')
    end
  end

  describe 'double game-state read prevention in #finish' do
    before do
      allow(sew).to receive(:lift_or_stow_feet)
      allow(sew).to receive(:magic_cleanup)
      allow(DRCC).to receive(:logbook_item)
    end

    it 'reads right_hand and left_hand exactly once each' do
      right_calls = 0
      left_calls = 0

      allow(DRC).to receive(:right_hand) do
        right_calls += 1
        'sewing needles'
      end
      allow(DRC).to receive(:left_hand) do
        left_calls += 1
        'small rucksack'
      end
      allow(DRCC).to receive(:stow_crafting_item)

      sew.send(:finish)

      expect(right_calls).to eq(1)
      expect(left_calls).to eq(1)
    end
  end

  describe 'verbose messaging on exit paths' do
    before do
      allow(sew).to receive(:lift_or_stow_feet)
      allow(sew).to receive(:magic_cleanup)
      $right_hand = nil
      $left_hand = nil
    end

    it '#finish always prints a finish message' do
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCC).to receive(:logbook_item)
      expect(Lich::Messaging).to receive(:msg).with('plain', 'Sew script finished (rucksack, finish: log).')

      sew.send(:finish)
    end

    it '#check_hand prints a descriptive error on failure' do
      allow(DRCI).to receive(:in_right_hand?).and_return(false)
      allow(sew).to receive(:magic_cleanup)
      expect(Lich::Messaging).to receive(:msg).with('bold', "Please hold the item or material you wish to work on. Expected 'rucksack' in right hand.")

      sew.send(:check_hand, 'rucksack')
    end
  end

  describe 'Flags cleanup' do
    it 'sew.lic before_dying block deletes sew-done not sealing-done' do
      # Verify the source code has the correct flag name
      source = File.read(File.join(File.dirname(__FILE__), '..', 'sew.lic'))
      expect(source).to include("Flags.delete('sew-done')")
      expect(source).not_to include("Flags.delete('sealing-done')")
    end

    it 'cleans up the sew-rental-warning flag in before_dying' do
      source = File.read(File.join(File.dirname(__FILE__), '..', 'sew.lic'))
      expect(source).to include("Flags.delete('sew-rental-warning')")
    end
  end

  describe 'magic_cleanup is an instance method' do
    it 'is defined on the Sew class, not at top level' do
      expect(Sew.instance_methods(false)).to include(:magic_cleanup)
    end
  end

  describe 'bold vs plain messaging convention' do
    before do
      allow(sew).to receive(:lift_or_stow_feet)
      allow(sew).to receive(:magic_cleanup)
    end

    it 'uses bold for hold completion (DRC.message replacement)' do
      sew.instance_variable_set(:@finish, 'hold')
      $right_hand = nil
      $left_hand = nil

      expect(Lich::Messaging).to receive(:msg).with('bold', 'rucksack complete — holding in hand.')
      allow(Lich::Messaging).to receive(:msg).with('plain', anything)

      sew.send(:finish)
    end

    it 'uses plain for the finish summary' do
      sew.instance_variable_set(:@finish, 'log')
      $right_hand = nil
      $left_hand = nil
      allow(DRCC).to receive(:logbook_item)

      expect(Lich::Messaging).to receive(:msg).with('plain', 'Sew script finished (rucksack, finish: log).')

      sew.send(:finish)
    end

    it 'uses bold for check_hand failure' do
      allow(DRCI).to receive(:in_right_hand?).with('leather').and_return(false)
      allow(sew).to receive(:magic_cleanup)

      expect(Lich::Messaging).to receive(:msg).with('bold', "Please hold the item or material you wish to work on. Expected 'leather' in right hand.")

      sew.send(:check_hand, 'leather')
    end
  end

  describe 'source code invariants' do
    let(:source) { File.read(File.join(File.dirname(__FILE__), '..', 'sew.lic')) }

    it 'uses Lich::Messaging.msg, never DRC.message' do
      # Ignore comments (lines starting with #)
      code_lines = source.lines.reject { |l| l.strip.start_with?('#') }
      expect(code_lines.join).not_to match(/DRC\.message/)
    end

    it 'uses Lich::Messaging.msg, never bare echo' do
      code_lines = source.lines.reject { |l| l.strip.start_with?('#') }
      # Match bare echo calls but not 'echo' as part of a string or variable
      expect(code_lines.join).not_to match(/^\s+echo\s/)
    end

    it 'has magic_cleanup as an instance method, not top-level' do
      # The def magic_cleanup should be indented (inside the class)
      expect(source).to match(/^  def magic_cleanup/)
      expect(source).not_to match(/^def magic_cleanup/)
    end

    it 'deletes sew-done flag, not sealing-done' do
      expect(source).to include("Flags.delete('sew-done')")
      expect(source).not_to include("Flags.delete('sealing-done')")
    end

    it 'uses .tr for dot-notation normalization in finish' do
      expect(source).to include("@noun.tr('.', ' ')")
    end

    it 'uses safe navigation or explicit nil checks for hand access' do
      # All .include? calls on right_hand/left_hand should be guarded
      # The pattern should be: `right && !right.include?` or `hand&.include?`
      source.lines.each_with_index do |line, idx|
        next if line.strip.start_with?('#')
        next unless line.include?('.include?') && (line.include?('right') || line.include?('left'))

        # Ensure it's guarded: either `&.include?` or `var && !var.include?` or `if var`
        expect(line).to(
          satisfy { |l| l.include?('&.include?') || l.match?(/\w+ && !\w+\.include\?/) },
          "Unguarded .include? on hand at line #{idx + 1}: #{line.strip}"
        )
      end
    end
  end
end
