require 'ostruct'
require 'time'

require_relative 'spec_helper'

# Load Sew class definition (without executing top-level code)
load_lic_class('sew.lic', 'Sew')

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

    # Default skill rank of 0 (individual examples override via .with(...)).
    allow(DRSkill).to receive(:getrank).and_return(0)

    # Prevent actual exit and stub helper methods
    allow(sew).to receive(:exit)
    allow(sew).to receive(:waitrt?)
  end

  # ===========================================================================
  # #swap_tool -- nil guards and tool swapping
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
  # #finish -- stow guards, logbook bundling, messaging
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
        expect(Lich::Messaging).to receive(:msg).with('bold', 'small.rucksack complete -- holding in hand.')
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
      expect(Lich::Messaging).to receive(:msg).with('plain', a_string_matching(/\Asew: Completed .*rucksack.* finish: log\z/))

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
  # #lift_or_stow_feet -- handling items at feet with dot notation
  # ===========================================================================
  describe '#lift_or_stow_feet' do
    before do
      sew.instance_variable_set(:@offcut, 'cloth')
    end

    # Like lich-5's DRCI.lift?: no item means no command and false, and
    # 'lift <noun>' succeeds only when that noun is at your feet.
    def stub_lift_with_at_feet(*nouns)
      allow(DRCI).to receive(:lift?) do |item = nil, *_|
        !item.nil? && nouns.include?(item)
      end
    end

    context 'when the cut left cloth at your feet' do
      before do
        stub_lift_with_at_feet('cloth')
        $right_hand = 'burlap cloth'
        $left_hand = 'small rucksack'
      end

      it 'lifts the offcut by its noun' do
        allow(DRCC).to receive(:stow_crafting_item)
        expect(DRCI).to receive(:lift?).with('cloth')

        sew.send(:lift_or_stow_feet)
      end

      it 'puts the offcut in the crafting bag, not the default stow container' do
        expect(DRCC).to receive(:stow_crafting_item).with('burlap cloth', 'duffel bag', nil)
        expect(DRC).not_to receive(:bput).with('stow feet', anything, anything)

        sew.send(:lift_or_stow_feet)
      end
    end

    context 'when the cut left leather at your feet' do
      before do
        sew.instance_variable_set(:@offcut, 'leather')
        stub_lift_with_at_feet('leather')
        $right_hand = 'deer leather'
        $left_hand = nil
      end

      it 'lifts the leather and puts it in the crafting bag' do
        expect(DRCC).to receive(:stow_crafting_item).with('deer leather', 'duffel bag', nil)
        expect(DRC).not_to receive(:bput).with('stow feet', anything, anything)

        sew.send(:lift_or_stow_feet)
      end
    end

    context 'when the lift fails' do
      before do
        stub_lift_with_at_feet
      end

      it 'falls back to stow feet' do
        expect(DRC).to receive(:bput).with('stow feet', 'You put', 'Stow what')
        expect(DRCC).not_to receive(:stow_crafting_item)

        sew.send(:lift_or_stow_feet)
      end
    end

    context 'when nothing was cut (knitting, enhancements, resume)' do
      before do
        sew.instance_variable_set(:@offcut, nil)
      end

      it 'sends no lift and falls back to stow feet' do
        expect(DRCI).not_to receive(:lift?)
        expect(DRC).to receive(:bput).with('stow feet', 'You put', 'Stow what')

        sew.send(:lift_or_stow_feet)
      end
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
  # #check_hand -- item position verification
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
  # #magic_cleanup -- spell release (now instance method)
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
  # #list_at_feet -- diagnostic output
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
  # #check_rental_status -- private rental expiry detection
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
  # #renew_rental -- auto-renewal of private crafting room
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

    # The game's reply to MARK NOTICE (angua DR logs, 2026-10-12 to
    # 2026-11-02): one line with the sentry's speech, then a bracketed line.
    let(:renewal_reply) do
      [
        %(You reach to make your mark, signaling your intent to extend your forge rental.  The sentry holds out her hand, saying, "That'll be 19560 Kronars, madam."  You hand over the coins.  The sentry drops them into a nearby locked coffer.  "Right then, that's all settled.  You've got more time."),
        '[Your private forge rental has been extended until Sat Nov 14 14:56:41 ET 2026.]'
      ]
    end

    def bput_returns
      @bput_returns ||= []
    end

    # Answers bput the way lich-5's DRC.bput does: strings become
    # case-insensitive regexes, each line is tried against every pattern,
    # the first match's text is returned, and '' means it timed out.
    def reply_with(lines)
      allow(DRC).to receive(:bput) do |_command, *matches|
        regexes = matches.flatten.map { |m| m.is_a?(Regexp) ? m : /#{m}/i }
        hit = nil
        lines.find { |line| regexes.find { |re| (hit = line.match(re)) } }
        (bput_returns << (hit ? hit.to_a.first : '')).last
      end
    end

    context 'successful renewal' do
      it "recognizes the game's renewal reply instead of timing out" do
        reply_with(renewal_reply)
        allow(Lich::Messaging).to receive(:msg)

        sew.send(:renew_rental)

        expect(bput_returns).to eq(['[Your private forge rental has been extended until'])
        expect(Lich::Messaging).to have_received(:msg).with('bold', '*** RENTAL RENEWED ***')
        expect(Lich::Messaging).not_to have_received(:msg).with('bold', /NOT CONFIRMED/)
      end

      it 'recognizes the bracketed line with leading XML tags' do
        reply_with(['<pushBold/>[Your private forge rental has been extended until Thu Dec  3 00:56:41 ET 2026.]'])
        allow(Lich::Messaging).to receive(:msg)

        sew.send(:renew_rental)

        expect(bput_returns).to eq(['<pushBold/>[Your private forge rental has been extended until'])
        expect(Lich::Messaging).to have_received(:msg).with('bold', '*** RENTAL RENEWED ***')
      end

      it 'resets the rental warning flag' do
        Flags['sew-rental-warning'] = true
        reply_with(renewal_reply)
        allow(Lich::Messaging).to receive(:msg)

        sew.send(:renew_rental)

        expect(Flags['sew-rental-warning']).to be_nil
      end
    end

    context 'no recognized reply' do
      it 'does not report a renewal when bput times out' do
        reply_with(['You glance around.'])
        allow(Lich::Messaging).to receive(:msg)

        sew.send(:renew_rental)

        expect(Lich::Messaging).not_to have_received(:msg).with('bold', '*** RENTAL RENEWED ***')
        expect(Lich::Messaging).to have_received(:msg).with('bold', '*** RENTAL RENEWAL NOT CONFIRMED -- CHECK THE NOTICE ***')
      end

      it "does not take other players' text of the bracketed line as a renewal" do
        allow(Lich::Messaging).to receive(:msg)
        line = '[Your private forge rental has been extended until Sat Nov 14 14:56:41 ET 2026.]'
        [%([General][Mallory] "#{line}"), %(Mallory says, "#{line}"), %(Mallory whispers, "#{line}")].each do |heard|
          reply_with([heard])
          sew.send(:renew_rental)
        end

        expect(Lich::Messaging).not_to have_received(:msg).with('bold', '*** RENTAL RENEWED ***')
      end
    end

    context 'insufficient funds' do
      # Unverified wording: no failed renewal is in the logs.
      it 'warns about insufficient funds' do
        allow(DRC).to receive(:bput).and_return("You don't have enough")

        expect(Lich::Messaging).to receive(:msg).with('bold', '*** RENTAL EXPIRING -- AUTO-RENEWING ***')
        expect(Lich::Messaging).to receive(:msg).with('bold', '*** INSUFFICIENT FUNDS TO RENEW RENTAL ***')

        sew.send(:renew_rental)
      end
    end

    context 'notice not found' do
      it 'warns about missing notice' do
        allow(DRC).to receive(:bput).and_return('I could not find')

        expect(Lich::Messaging).to receive(:msg).with('bold', '*** RENTAL EXPIRING -- AUTO-RENEWING ***')
        expect(Lich::Messaging).to receive(:msg).with('bold', '*** COULD NOT FIND NOTICE -- CHECK LOCATION ***')

        sew.send(:renew_rental)
      end
    end
  end

  # ===========================================================================
  # #start_item -- a completion left over from an earlier run
  # ===========================================================================
  describe '#start_item' do
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
      sew.instance_variable_set(:@noun, 'netting')
      sew.instance_variable_set(:@home_tool, 'sewing needles')
      sew.instance_variable_set(:@home_command, 'push my netting with my needles')
      allow(DRCA).to receive(:crafting_magic_routine)
      allow(sew).to receive(:assemble_part)
      allow(sew).to receive(:swap_tool)
      allow(sew).to receive(:finish)
    end

    # Mahtra, 2026-11-06 00:30:57 NZDT: a stopped sew's backlogged push ended
    # with "Applying the final touches, you complete working on some burlap
    # reinforced netting." while taskmaster's next sew was starting. That
    # run's first cut ("Roundtime: 8 sec.") then went to finish, and a
    # netting cut once was stowed as done.
    it 'does not take a completion seen before the first cut as this item being done' do
      allow(sew).to receive(:prep) do
        Flags['sew-done'] = ['Applying the final touches, you complete working on some burlap reinforced netting.']
        'cut my burlap cloth with my scissors'
      end
      sent = []
      stop = Class.new(StandardError)
      allow(DRC).to receive(:bput) do |command, *|
        sent << command
        raise stop if sent.size > 1

        'Roundtime: 8 sec.'
      end

      expect { sew.start_item }.to raise_error(stop)

      expect(sew).not_to have_received(:finish)
      expect(sent).to eq(['cut my burlap cloth with my scissors', 'push my netting with my needles'])
    end

    it "still finishes on this item's own completion" do
      allow(sew).to receive(:prep).and_return('push my netting with my needles')
      allow(DRC).to receive(:bput) do |*|
        Flags['sew-done'] = ['Applying the final touches, you complete working on some burlap reinforced netting.']
        'Roundtime: 5 sec.'
      end
      allow(sew).to receive(:finish) { raise 'finished' }

      expect { sew.start_item }.to raise_error('finished')
    end
  end

  # ===========================================================================
  # #assemble_part -- nil hand safety
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
  # #clear_hands -- a new item starts with empty hands
  # ===========================================================================
  describe '#clear_hands' do
    before(:each) do
      allow(DRCC).to receive(:stow_crafting_item)
      sew.instance_variable_set(:@noun, 'rope')
      sew.instance_variable_set(:@recipe_name, 'reinforced rope')
      $right_hand = nil
      $left_hand = nil
    end

    it 'stows a finished item left in hand by an earlier run, even with the same noun' do
      $left_hand = 'burlap reinforced rope'

      sew.send(:clear_hands)

      expect(DRCC).to have_received(:stow_crafting_item).with('burlap reinforced rope', 'duffel bag', nil)
    end

    it 'stows both hands, right first' do
      $right_hand = 'clockwork scissors'
      $left_hand = 'burlap reinforced rope'

      sew.send(:clear_hands)

      expect(DRCC).to have_received(:stow_crafting_item).with('clockwork scissors', 'duffel bag', nil).ordered
      expect(DRCC).to have_received(:stow_crafting_item).with('burlap reinforced rope', 'duffel bag', nil).ordered
    end

    it 'does nothing with empty hands' do
      sew.send(:clear_hands)

      expect(DRCC).not_to have_received(:stow_crafting_item)
    end

    it 'passes the belt so belt tools are tied back on' do
      belt = { 'name' => "tailor's toolbelt", 'items' => ['scissors'] }
      sew.instance_variable_set(:@belt, belt)
      $right_hand = 'clockwork scissors'

      sew.send(:clear_hands)

      expect(DRCC).to have_received(:stow_crafting_item).with('clockwork scissors', 'duffel bag', belt)
    end

    context 'for an enhancement' do
      before(:each) do
        sew.instance_variable_set(:@noun, 'shirt')
        sew.instance_variable_set(:@recipe_name, 'tailored armor sealing')
      end

      it 'keeps the item being enhanced' do
        $left_hand = 'quilted cloth shirt'

        sew.send(:clear_hands)

        expect(DRCC).not_to have_received(:stow_crafting_item)
      end

      # DRC.left_hand shortens 'quilted cloth shirt' to 'quilted shirt'
      # (fix_dr_bullshit keeps the first and last word), so these fixtures
      # use the shortened names the real hand readers return.
      it 'keeps a dotted noun when the hand name has been shortened' do
        sew.instance_variable_set(:@noun, 'cloth.shirt')
        $left_hand = 'quilted shirt'

        sew.send(:clear_hands)

        expect(DRCC).not_to have_received(:stow_crafting_item)
      end

      it 'keeps a dotted noun when the hand name was short enough to keep' do
        sew.instance_variable_set(:@noun, 'cloth.shirt')
        $left_hand = 'cloth shirt'

        sew.send(:clear_hands)

        expect(DRCC).not_to have_received(:stow_crafting_item)
      end

      it 'still stows anything else' do
        $right_hand = 'sealing wax'
        $left_hand = 'quilted shirt'

        sew.send(:clear_hands)

        expect(DRCC).to have_received(:stow_crafting_item).with('sealing wax', 'duffel bag', nil)
        expect(DRCC).not_to have_received(:stow_crafting_item).with('quilted shirt', anything, anything)
      end
    end
  end

  # ===========================================================================
  # #prep -- recipe/instruction lookup and material setup
  # ===========================================================================
  describe '#prep' do
    before(:each) do
      allow(DRCA).to receive(:crafting_magic_routine)
      allow(DRCC).to receive(:get_crafting_item).and_return(true)
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
      sew.instance_variable_set(:@cloth, Sew::CLOTH)
      sew.instance_variable_set(:@cube, nil)
    end

    it 'always calls crafting_magic_routine first' do
      expect(DRCA).to receive(:crafting_magic_routine).with(sew.instance_variable_get(:@settings))

      sew.send(:prep)
    end

    # Each study uses one of the instructions' uses, so the material is
    # fetched first and a missing one stops the run before any study.
    # The DRCC double follows the real get_crafting_item: "What were you
    # referring to?" stops the script itself unless skip_exit is set, in
    # which case it returns false.
    context 'material before the recipe' do
      let(:sent) { [] }
      let(:replies) { {} }

      before do
        sew.instance_variable_set(:@instructions, true)
        allow(sew).to receive(:exit).and_raise(SystemExit)
        allow(DRC).to receive(:bput) do |command, *|
          sent << command
          replies.fetch(command, 'Roundtime')
        end
        allow(DRCC).to receive(:get_crafting_item) do |name, _bag, _items, _belt, skip_exit = false|
          reply = DRC.bput("get my #{name}", /^You get/, /^What were you/)
          next true unless reply.start_with?('What were you')
          raise SystemExit unless skip_exit

          false
        end
      end

      it 'sends no study when the cloth is gone' do
        replies['get my burlap cloth'] = 'What were you referring to?'

        expect { sew.send(:prep) }.to raise_error(SystemExit)

        expect(sent).to eq(['get my burlap cloth'])
      end

      it 'sends no study when the leather is gone' do
        sew.instance_variable_set(:@mat_type, 'rat')
        replies['get my rat leather'] = 'What were you referring to?'

        expect { sew.send(:prep) }.to raise_error(SystemExit)

        expect(sent).not_to include('study my instructions')
      end

      it 'sends no study when the yarn is gone' do
        sew.instance_variable_set(:@knit, true)
        replies['get my yarn'] = 'What were you referring to?'

        expect { sew.send(:prep) }.to raise_error(SystemExit)

        expect(sent).not_to include('study my instructions')
      end

      it 'leaves the tailoring book shut when the cloth is gone' do
        sew.instance_variable_set(:@instructions, nil)
        sew.instance_variable_set(:@settings, OpenStruct.new(crafting_training_spells: [], master_crafting_book: nil))
        replies['get my burlap cloth'] = 'What were you referring to?'
        expect(DRCC).not_to receive(:find_recipe2)

        expect { sew.send(:prep) }.to raise_error(SystemExit)

        expect(sent).not_to include('get my tailoring book')
      end

      it 'names the missing material instead of asking to hold it' do
        replies['get my burlap cloth'] = 'What were you referring to?'
        expect(sew).not_to receive(:check_hand)
        expect(sew).to receive(:magic_cleanup)
        expect(Lich::Messaging).to receive(:msg)
          .with('bold', "sew: Could not get 'burlap cloth'. Stopping before the recipe is studied.")

        expect { sew.send(:prep) }.to raise_error(SystemExit)
      end

      # A get with no free hand times out on v5.23.0: DRCC then returns
      # whether the cloth is in hand, false, without stopping the script.
      it 'stops on a get that returns false without stopping the script' do
        allow(DRCC).to receive(:get_crafting_item) do |name, *|
          DRC.bput("get my #{name}", /^You get/, /^What were you/)
          !name.end_with?('cloth')
        end
        replies['get my burlap cloth'] = 'You need a free hand to do that.'
        expect(sew).not_to receive(:check_hand)

        expect { sew.send(:prep) }.to raise_error(SystemExit)

        expect(sent).not_to include('study my instructions')
      end

      # From here the material is already in hand when the recipe item is
      # fetched, so a failed get must put it back before stopping.
      context 'when the recipe item fails after the material is held' do
        let(:stowed) { [] }

        # The material is in the left hand until the stow puts it away.
        before do
          allow(DRCC).to receive(:stow_crafting_item) do |name, bag, _belt|
            sent << "put my #{name} in my #{bag}"
            stowed << name
            true
          end
          allow(DRCI).to receive(:in_left_hand?) { stowed.empty? }
        end

        it 'puts the cloth back and sends no study when the instructions are gone' do
          replies['get my rucksack instructions'] = 'What were you referring to?'

          expect { sew.send(:prep) }.to raise_error(SystemExit)

          expect(sent).to eq(['get my burlap cloth', 'get my rucksack instructions', 'put my burlap cloth in my duffel bag'])
        end

        it 'names the missing instructions and releases the magic' do
          replies['get my rucksack instructions'] = 'What were you referring to?'
          expect(sew).to receive(:magic_cleanup)
          expect(Lich::Messaging).to receive(:msg)
            .with('bold', "sew: Could not get 'rucksack instructions'. Stopping before the recipe is studied.")

          expect { sew.send(:prep) }.to raise_error(SystemExit)
        end

        it 'puts the leather back when the instructions are gone' do
          sew.instance_variable_set(:@mat_type, 'rat')
          replies['get my rucksack instructions'] = 'What were you referring to?'

          expect { sew.send(:prep) }.to raise_error(SystemExit)

          expect(sent.last).to eq('put my rat leather in my duffel bag')
        end

        it 'puts the yarn back when the instructions are gone' do
          sew.instance_variable_set(:@knit, true)
          replies['get my rucksack instructions'] = 'What were you referring to?'

          expect { sew.send(:prep) }.to raise_error(SystemExit)

          expect(sent.last).to eq('put my yarn in my duffel bag')
        end

        # No id was seen, so the put-back goes by name and its result says
        # nothing: v5.23.0 stow_crafting_item returns true even after its
        # "stow" fallback fails. The left hand decides, matched by name as
        # v5.23.0 in_left_hand? does for a plain noun.
        context 'when the put-back by name leaves the material in hand' do
          before do
            replies['get my rucksack instructions'] = 'What were you referring to?'
            allow(DRCC).to receive(:get_crafting_item) do |name, *|
              reply = DRC.bput("get my #{name}", /^You get/, /^What were you/)
              next false if reply.start_with?('What were you')

              $left_hand = name
              true
            end
            allow(DRCI).to receive(:in_left_hand?) { |item| DRC.left_hand.to_s.include?(item.to_s) }
          end

          it 'names the cloth still in hand' do
            expect(Lich::Messaging).to receive(:msg)
              .with('bold', "sew: Could not get 'rucksack instructions'. Stopping before the recipe is studied. " \
                            'The burlap cloth is still in your left hand.')

            expect { sew.send(:prep) }.to raise_error(SystemExit)
          end

          it 'names the leather still in hand' do
            sew.instance_variable_set(:@mat_type, 'rat')
            expect(Lich::Messaging).to receive(:msg)
              .with('bold', "sew: Could not get 'rucksack instructions'. Stopping before the recipe is studied. " \
                            'The rat leather is still in your left hand.')

            expect { sew.send(:prep) }.to raise_error(SystemExit)
          end

          it 'names no hand once the stow empties it' do
            allow(DRCC).to receive(:stow_crafting_item) do |name, bag, _belt|
              sent << "put my #{name} in my #{bag}"
              $left_hand = nil
              true
            end
            expect(Lich::Messaging).to receive(:msg)
              .with('bold', "sew: Could not get 'rucksack instructions'. Stopping before the recipe is studied.")

            expect { sew.send(:prep) }.to raise_error(SystemExit)
          end

          it 'never asks about the hand with an empty id reference' do
            expect(DRCI).not_to receive(:in_left_hand?).with('#')

            expect { sew.send(:prep) }.to raise_error(SystemExit)
          end
        end

        it 'puts the cloth back and reads no recipe when the tailoring book is gone' do
          sew.instance_variable_set(:@instructions, nil)
          sew.instance_variable_set(:@settings, OpenStruct.new(crafting_training_spells: [], master_crafting_book: nil))
          replies['get my tailoring book'] = 'What were you referring to?'
          expect(DRCC).not_to receive(:find_recipe2)

          expect { sew.send(:prep) }.to raise_error(SystemExit)

          expect(sent).to eq(['get my burlap cloth', 'get my tailoring book', 'put my burlap cloth in my duffel bag'])
        end

        # With a leftover in the other hand, the instructions get finds no
        # free hand and times out; v5.23.0 DRCC then returns false (not in
        # hand) without stopping the script.
        it 'stops before the study when the instructions get times out' do
          allow(DRCC).to receive(:get_crafting_item) do |name, *|
            DRC.bput("get my #{name}", /^You get/, /^What were you/)
            !name.end_with?('instructions')
          end

          expect { sew.send(:prep) }.to raise_error(SystemExit)

          expect(sent).not_to include('study my instructions')
          expect(sent.last).to eq('put my burlap cloth in my duffel bag')
        end

        it 'never reaches the tool swap when the instructions get times out' do
          allow(DRCC).to receive(:get_crafting_item) { |name, *| !name.end_with?('instructions') }
          expect(sew).not_to receive(:swap_tool)

          expect { sew.send(:prep) }.to raise_error(SystemExit)
        end

        # The enhancement piece was in hand before the run started, so it
        # stays there; only the study is skipped.
        it 'keeps an enhancement piece in hand when the instructions are gone' do
          sew.instance_variable_set(:@recipe_name, 'tailored armor reinforcing')
          sew.instance_variable_set(:@noun, 'shirt')
          replies['get my shirt instructions'] = 'What were you referring to?'
          expect(DRCC).not_to receive(:stow_crafting_item)

          expect { sew.send(:prep) }.to raise_error(SystemExit)

          expect(sent).to eq(['get my shirt instructions'])
        end

        # The game gives the held material an id, so the put-back goes by
        # id. The DRCI double follows v5.23.0 put_away_item?: it returns
        # false at once on a reply in PUT_AWAY_ITEM_FAILURE_PATTERNS, such
        # as a full bag, and on a timeout (''), where the by-name DRCC stow
        # waits out its 15 second timeout and returns true. A put that lands
        # empties the left hand. in_left_hand? follows v5.23.0 for a "#id"
        # argument: it compares the id against GameObj.left_hand.id.
        context 'when the held material has an id' do
          before do
            allow(DRCC).to receive(:get_crafting_item) do |name, _bag, _items, _belt, _skip_exit|
              reply = DRC.bput("get my #{name}", /^You get/, /^What were you/)
              next false if reply.start_with?('What were you')

              $left_hand = name unless name.end_with?('instructions')
              true
            end
            $hand_ids = { 'burlap cloth' => '2222485', 'rat leather' => '2222486' }
            allow(DRCI).to receive(:put_away_item?) do |item, container|
              command = "put #{item} in my #{container}"
              sent << command
              reply = replies.fetch(command, 'You put your cloth in your duffel bag.')
              landed = reply.start_with?('You put')
              $left_hand = nil if landed
              landed
            end
            allow(DRCI).to receive(:in_left_hand?).and_wrap_original do |original, item|
              id = item.to_s[/\A#(\d+)\z/, 1]
              id ? GameObj.left_hand.id.to_s == id : original.call(item)
            end
            replies['get my rucksack instructions'] = 'What were you referring to?'
          end

          # Something outside sew takes the piece from the left hand while
          # the instructions get is out, so the put-back finds nothing held.
          def lose_material_during_instructions_get(replacement_id: nil)
            allow(DRCC).to receive(:get_crafting_item) do |name, *|
              reply = DRC.bput("get my #{name}", /^You get/, /^What were you/)
              if reply.start_with?('What were you')
                if replacement_id
                  $hand_ids = $hand_ids.merge($left_hand => replacement_id)
                else
                  $left_hand = nil
                end
                next false
              end

              $left_hand = name
              true
            end
          end

          it 'puts the cloth back by its id' do
            expect { sew.send(:prep) }.to raise_error(SystemExit)

            expect(sent).to eq(['get my burlap cloth', 'get my rucksack instructions', 'put #2222485 in my duffel bag'])
          end

          it 'puts the leather back by its id, never by name' do
            sew.instance_variable_set(:@mat_type, 'rat')

            expect { sew.send(:prep) }.to raise_error(SystemExit)

            expect(sent.last).to eq('put #2222486 in my duffel bag')
            expect(sent).not_to include('put my rat leather in my duffel bag')
          end

          it 'says only that the instructions are missing when the put-back lands' do
            expect(Lich::Messaging).to receive(:msg)
              .with('bold', "sew: Could not get 'rucksack instructions'. Stopping before the recipe is studied.")

            expect { sew.send(:prep) }.to raise_error(SystemExit)
          end

          it 'names the cloth still in hand when the bag is full' do
            replies['put #2222485 in my duffel bag'] = "There isn't any more room in the duffel bag for that."
            expect(sew).to receive(:magic_cleanup)
            expect(Lich::Messaging).to receive(:msg)
              .with('bold', "sew: Could not get 'rucksack instructions'. Stopping before the recipe is studied. " \
                            'The burlap cloth is still in your left hand.')

            expect { sew.send(:prep) }.to raise_error(SystemExit)
          end

          it 'sends no study and no second put when the bag is full' do
            replies['put #2222485 in my duffel bag'] = "There isn't any more room in the duffel bag for that."

            expect { sew.send(:prep) }.to raise_error(SystemExit)

            expect(sent).to eq(['get my burlap cloth', 'get my rucksack instructions', 'put #2222485 in my duffel bag'])
          end

          it 'names the leather still in hand when the bag is full' do
            sew.instance_variable_set(:@mat_type, 'rat')
            replies['put #2222486 in my duffel bag'] = "There isn't any more room in the duffel bag for that."
            expect(Lich::Messaging).to receive(:msg)
              .with('bold', "sew: Could not get 'rucksack instructions'. Stopping before the recipe is studied. " \
                            'The rat leather is still in your left hand.')

            expect { sew.send(:prep) }.to raise_error(SystemExit)
          end

          it 'names the cloth still in hand when the bag is unknown' do
            replies['put #2222485 in my duffel bag'] = 'What were you referring to?'
            expect(Lich::Messaging).to receive(:msg)
              .with('bold', "sew: Could not get 'rucksack instructions'. Stopping before the recipe is studied. " \
                            'The burlap cloth is still in your left hand.')

            expect { sew.send(:prep) }.to raise_error(SystemExit)
          end

          # "Perhaps you should be holding that first." means the piece is
          # not held, yet put_away_item? returns false for it as for a full
          # bag. The message must not claim the leather is in hand.
          it 'does not claim the leather is in hand when the put finds it gone' do
            sew.instance_variable_set(:@mat_type, 'rat')
            lose_material_during_instructions_get
            replies['put #2222486 in my duffel bag'] = 'Perhaps you should be holding that first.'
            expect(Lich::Messaging).to receive(:msg)
              .with('bold', "sew: Could not get 'rucksack instructions'. Stopping before the recipe is studied.")

            expect { sew.send(:prep) }.to raise_error(SystemExit)

            expect($left_hand).to be_nil
          end

          it 'still sends the put and stops when the put finds the leather gone' do
            sew.instance_variable_set(:@mat_type, 'rat')
            lose_material_during_instructions_get
            replies['put #2222486 in my duffel bag'] = 'Perhaps you should be holding that first.'

            expect { sew.send(:prep) }.to raise_error(SystemExit)

            expect(sent).to eq(['get my rat leather', 'get my rucksack instructions', 'put #2222486 in my duffel bag'])
          end

          # The check is by id: a lookalike cloth in the left hand is not
          # the piece the run got, so the message stays silent about it.
          it 'does not claim the cloth is in hand when a lookalike holds the left hand' do
            lose_material_during_instructions_get(replacement_id: '3333333')
            replies['put #2222485 in my duffel bag'] = 'Perhaps you should be holding that first.'
            expect(Lich::Messaging).to receive(:msg)
              .with('bold', "sew: Could not get 'rucksack instructions'. Stopping before the recipe is studied.")

            expect { sew.send(:prep) }.to raise_error(SystemExit)

            expect($left_hand).to eq('burlap cloth')
          end

          # A timeout says nothing about where the piece went; the hands
          # decide. Still held: name the hand.
          it 'names the cloth still in hand when the put times out while it is held' do
            replies['put #2222485 in my duffel bag'] = ''
            expect(Lich::Messaging).to receive(:msg)
              .with('bold', "sew: Could not get 'rucksack instructions'. Stopping before the recipe is studied. " \
                            'The burlap cloth is still in your left hand.')

            expect { sew.send(:prep) }.to raise_error(SystemExit)
          end

          it 'does not claim the cloth is in hand when the put times out after it left' do
            lose_material_during_instructions_get
            replies['put #2222485 in my duffel bag'] = ''
            expect(Lich::Messaging).to receive(:msg)
              .with('bold', "sew: Could not get 'rucksack instructions'. Stopping before the recipe is studied.")

            expect { sew.send(:prep) }.to raise_error(SystemExit)
          end

          it 'does not check the hand when the put-back lands' do
            expect(DRCI).not_to receive(:in_left_hand?).with('#2222485')

            expect { sew.send(:prep) }.to raise_error(SystemExit)

            expect($left_hand).to be_nil
          end

          it 'puts back by id after the cloth is swapped from the right hand' do
            allow(DRCC).to receive(:get_crafting_item) do |name, *|
              DRC.bput("get my #{name}", /^You get/, /^What were you/)
              next false if name.end_with?('instructions')

              $right_hand = name
              true
            end
            allow(DRCI).to receive(:in_left_hand?).and_return(false)
            allow(sew).to receive(:check_hand) do
              $left_hand = $right_hand
              $right_hand = nil
            end

            expect { sew.send(:prep) }.to raise_error(SystemExit)

            expect(sent.last).to eq('put #2222485 in my duffel bag')
          end
        end
      end

      it 'gets the cloth, then the instructions, then studies' do
        sew.send(:prep)

        expect(sent).to eq(['get my burlap cloth', 'get my rucksack instructions', 'study my instructions'])
      end

      it 'checks an enhancement piece in hand before studying' do
        sew.instance_variable_set(:@recipe_name, 'tailored armor reinforcing')
        sew.instance_variable_set(:@noun, 'shirt')
        allow(DRCI).to receive(:in_left_hand?).with('shirt').and_return(false)
        allow(sew).to receive(:check_hand) { sent << 'check_hand' }

        sew.send(:prep)

        expect(sent).to eq(['check_hand', 'get my shirt instructions', 'study my instructions'])
      end
    end

    context 'instructions path' do
      before do
        sew.instance_variable_set(:@instructions, true)
      end

      it 'gets the instructions from bag' do
        expect(DRCC).to receive(:get_crafting_item).with('rucksack instructions', 'duffel bag', [], nil, true).and_return(true)

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
        expect(DRCC).to receive(:get_crafting_item).with('tailoring book', 'duffel bag', [], nil, true).and_return(true)

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
        expect(DRCC).to receive(:get_crafting_item).with('yarn', 'duffel bag', [], nil, true).and_return(true)

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

      it 'leaves @offcut unset, since knitting cuts nothing' do
        sew.send(:prep)

        expect(sew.instance_variable_get(:@offcut)).to be_nil
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

    context 'enhancement -- seal' do
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

    context 'enhancement -- reinforce' do
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

      it 'leaves @offcut unset, since no stock is cut' do
        sew.send(:prep)

        expect(sew.instance_variable_get(:@offcut)).to be_nil
      end
    end

    context 'cloth products' do
      before do
        sew.instance_variable_set(:@mat_type, 'burlap')
        sew.instance_variable_set(:@recipe_name, 'small rucksack')
      end

      it 'gets the cloth material from bag' do
        expect(DRCC).to receive(:get_crafting_item).with('burlap cloth', 'duffel bag', [], nil, true).and_return(true)

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

      it 'sets @offcut to cloth, the noun of the excess the cut leaves at your feet' do
        sew.send(:prep)

        expect(sew.instance_variable_get(:@offcut)).to eq('cloth')
      end
    end

    context 'leather products' do
      before do
        sew.instance_variable_set(:@mat_type, 'deer')
        sew.instance_variable_set(:@recipe_name, 'small rucksack')
      end

      it 'gets the leather material from bag' do
        expect(DRCC).to receive(:get_crafting_item).with('deer leather', 'duffel bag', [], nil, true).and_return(true)

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

      it 'sets @offcut to leather, the noun of the excess the cut leaves at your feet' do
        sew.send(:prep)

        expect(sew.instance_variable_get(:@offcut)).to eq('leather')
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
        ['electroweave', 'steelsilk', 'arzumodine', 'bourde', 'dergatine', 'dragonar', 'faeweave', 'farandine', 'imperial', 'imperial weave'].each do |mat|
          sew.instance_variable_set(:@mat_type, mat)
          sew.instance_variable_set(:@recipe_name, 'small rucksack')

          result = sew.send(:prep)

          expect(result).to eq("cut my #{mat} cloth with my scissors"), "Failed for material: #{mat}"
        end
      end

      # "imperial" is the adjective the game matches for imperial weave cloth:
      # TAP MY IMPERIAL CLOTH -> "You tap some heavy Imperial weave cloth".
      it 'gets bare imperial as cloth, not leather' do
        sew.instance_variable_set(:@mat_type, 'imperial')
        sew.instance_variable_set(:@recipe_name, 'small rucksack')

        expect(DRCC).to receive(:get_crafting_item).with('imperial cloth', 'duffel bag', [], nil, true).and_return(true)
        expect(DRCC).not_to receive(:get_crafting_item).with('imperial leather', anything, anything, anything, anything)

        result = sew.send(:prep)

        expect(result).to eq('cut my imperial cloth with my scissors')
        expect(sew.instance_variable_get(:@home_command)).to eq('push my rucksack with my needles')
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
  # #work -- re-threading the sewing needles
  # ===========================================================================
  describe '#work re-threading' do
    let(:needs_thread) { 'The needles need to have thread put on them before they can be used for sewing' }
    let(:out_of_material) { 'You need a larger amount of material to continue crafting' }
    let(:needles) { OpenStruct.new(name: 'sewing needles', noun: 'needles', id: '63049908') }
    let(:thread) { OpenStruct.new(name: 'cotton thread', noun: 'thread', id: '63116961') }
    let(:sent) { [] }

    # Feeds the replies in order (as bput returns them: the matched text)
    # and records each command sent.
    # The last reply exits #work through the out-of-material branch.
    # Running out of replies raises, so a regression fails instead of
    # looping forever.
    def run_work(*replies)
      allow(DRC).to receive(:bput) do |command, *|
        sent << command
        raise 'too many bput calls' if replies.empty?

        replies.shift
      end
      expect { sew.send(:work, 'push my rucksack with my sewing needles') }.to raise_error(SystemExit)
    end

    before(:each) do
      sew.instance_variable_set(:@cube, nil)
      allow(DRCA).to receive(:crafting_magic_routine)
      allow(sew).to receive(:magic_cleanup)
      allow(sew).to receive(:exit).and_raise(SystemExit)
      allow(Lich::Messaging).to receive(:msg)
      allow(GameObj).to receive(:right_hand).and_return(needles)
      allow(sew).to receive(:swap_tool) do |tool, *|
        allow(GameObj).to receive(:right_hand).and_return(thread) if tool == 'cotton thread'
      end
    end

    it 'threads the needles it was using by id, not by noun' do
      run_work(needs_thread, 'You carefully thread some cotton thread', out_of_material)

      expect(sent).to include('put my thread on #63049908')
      expect(sent).not_to include('put thread on my sewing needles')
    end

    it 'reads the needles id before swap_tool puts the thread in hand' do
      run_work(needs_thread, out_of_material)

      expect(sent[1]).to eq('put my thread on #63049908')
      expect(sent[1]).not_to include('63116961')
    end

    it 'gets the cotton thread, skipping the restock exit' do
      run_work(needs_thread, out_of_material)

      expect(sew).to have_received(:swap_tool).with('cotton thread', true)
    end

    it 'goes back to the needles after threading' do
      run_work(needs_thread, 'You carefully thread some cotton thread', out_of_material)

      expect(sew).to have_received(:swap_tool).with('sewing needles')
      expect(sent[2]).to eq('push my rucksack with my sewing needles')
    end

    it 'treats "already threaded" as ready to sew instead of retrying the put' do
      run_work(needs_thread, 'is already threaded with', out_of_material)

      expect(sent).to eq(['push my rucksack with my sewing needles', 'put my thread on #63049908', 'push my rucksack with my sewing needles'])
    end

    it 'exits with a message when the needles have no id' do
      allow(GameObj).to receive(:right_hand).and_return(OpenStruct.new(name: 'Empty', noun: 'Empty', id: nil))

      run_work(needs_thread)

      expect(Lich::Messaging).to have_received(:msg).with('bold', 'sew: Could not identify the sewing needles to thread. Cannot continue crafting.')
      expect(sew).to have_received(:magic_cleanup)
      expect(sew).not_to have_received(:swap_tool)
      expect(sent).to eq(['push my rucksack with my sewing needles'])
    end
  end

  # ===========================================================================
  # #work -- unrecognized replies must not loop forever
  # ===========================================================================
  describe '#work unrecognized replies' do
    let(:sent) { [] }
    let(:timeouts) { [] }
    let(:analyze) { 'analyze my rucksack' }

    def give_up_message(command)
      "sew: No reply sew could act on to '#{command}', or to ANALYZE after it, in #{Sew::MAX_UNMATCHED} tries. Cannot continue crafting."
    end

    # Feeds the replies in order (as bput returns them: the matched text,
    # or '' on a timeout) and records each command sent and the timeout it
    # was given (nil for bput's default). A reply may be a lambda, run when
    # it is due. Runs out of replies with an exit so a broken guard cannot
    # hang the suite.
    def run_work(command, *replies)
      allow(DRC).to receive(:bput) do |cmd, *matchers|
        sent << cmd
        timeouts << (matchers.first.is_a?(Hash) ? matchers.first['timeout'] : nil)
        raise 'too many bput calls' if replies.empty?

        reply = replies.shift
        reply.respond_to?(:call) ? reply.call : reply
      end
      expect { sew.send(:work, command) }.to raise_error(SystemExit)
    end

    before(:each) do
      sew.instance_variable_set(:@cube, nil)
      allow(DRCA).to receive(:crafting_magic_routine)
      allow(GameObj).to receive(:right_hand).and_return(OpenStruct.new(name: 'Empty', noun: nil, id: nil))
      allow(GameObj).to receive(:left_hand).and_return(OpenStruct.new(name: 'Empty', noun: nil, id: nil))
      allow(sew).to receive(:magic_cleanup)
      allow(sew).to receive(:swap_tool)
      allow(sew).to receive(:finish).and_raise(SystemExit)
      allow(sew).to receive(:exit).and_raise(SystemExit)
      allow(Lich::Messaging).to receive(:msg)
    end

    # Mahtra, 2026-11-06 00:29:13-00:30:57 NZDT: three pushes went unanswered
    # through a lag, sew gave up, and the backlog then finished the netting
    # with nobody left to stow it.
    it 'never resends the crafting command that went unanswered: it ANALYZEs instead, waiting longer' do
      run_work('push my rucksack with my sewing needles', '', 'pushing it with a needle and thread', 'You need a larger amount of material to continue crafting')

      expect(sent).to eq(['push my rucksack with my sewing needles', analyze, 'push my rucksack with my sewing needles'])
      expect(timeouts).to eq([nil, Sew::ANALYZE_TIMEOUT, nil])
    end

    it "goes on from where ANALYZE says the item stands, here the pins" do
      sew.instance_variable_set(:@pin_pokes, 0)
      run_work('push my rucksack with my sewing needles', '', 'is in need of pinning to help arrange the material for further sewing', 'You need a larger amount of material to continue crafting')

      expect(sew).to have_received(:swap_tool).with('pins', true)
      expect(sent.last).to eq('poke my rucksack with my pins')
    end

    it 'finishes, with no ANALYZE, when the item was finished while the reply was held up' do
      run_work('push my rucksack with my sewing needles', lambda {
        Flags['sew-done'] = ['Applying the final touches, you complete working on some burlap reinforced netting.']
        ''
      })

      expect(sew).to have_received(:finish)
      expect(sent).to eq(['push my rucksack with my sewing needles'])
    end

    it 'analyzes the knitting needles while knitting' do
      allow(GameObj).to receive(:right_hand).and_return(OpenStruct.new(name: 'knitting needles', noun: 'needles', id: '1'))
      allow(GameObj).to receive(:left_hand).and_return(OpenStruct.new(name: 'Empty', noun: nil, id: nil))

      run_work('knit my needles', '', 'Now the needles must be turned', 'You need a larger amount of material to continue crafting')

      expect(sent).to eq(['knit my needles', 'analyze my knitting needles', 'turn my needles'])
    end

    it 'gives up after MAX_UNMATCHED misses, naming the command that stalled' do
      run_work('put thread on my sewing needles', '', '', '')

      expect(sent).to eq(['put thread on my sewing needles', analyze, analyze])
      expect(Lich::Messaging).to have_received(:msg).with('bold', give_up_message('put thread on my sewing needles'))
      expect(sew).to have_received(:magic_cleanup)
    end

    it 'cannot cycle forever between a command sew never knows and ANALYZE' do
      # ANALYZE always ends with a Roundtime, which sends the home command
      # again; its reply is never one sew knows.
      sew.instance_variable_set(:@home_command, 'push my rucksack with my sewing needles')
      replies = ['', 'Roundtime: 4 sec.', '', 'Roundtime: 4 sec.', '', 'Roundtime: 4 sec.', '']

      run_work('push my rucksack with my sewing needles', *replies)

      expect(sent.count(analyze)).to eq(Sew::MAX_UNMATCHED - 1)
      expect(Lich::Messaging).to have_received(:msg).with('bold', give_up_message('push my rucksack with my sewing needles'))
    end

    it 'starts the count again once a crafting command gets a reply it knows' do
      run_work('push my rucksack with my sewing needles',
               '', 'scissor cuts', 'scissor cuts', '', 'scissor cuts', 'scissor cuts', '', 'You need a larger amount of material to continue crafting')

      expect(Lich::Messaging).not_to have_received(:msg).with('bold', a_string_starting_with('sew: No reply sew could act on'))
    end

    # Review of #8067 (mrhoribu): crafted needles have three-word names, and
    # DRC.right_hand shortens "smooth knitting needles" to "smooth needles"
    # (data/base-recipes.yaml), so DRCI.in_hands?('knitting needles') is
    # false mid-knit and the ANALYZE went to the item instead.
    it 'analyzes the knitting needles while knitting, whatever the needles are called' do
      sew.instance_variable_set(:@home_tool, 'knitting needles')

      run_work('knit my needles', '', 'Now the needles must be turned', 'You need a larger amount of material to continue crafting')

      expect(sent[1]).to eq('analyze my knitting needles')
    end

    it 'knows knitting needles in hand by their whole name, as a resume finds them' do
      allow(GameObj).to receive(:right_hand).and_return(OpenStruct.new(name: 'smooth knitting needles', noun: 'needles', id: '1'))
      allow(GameObj).to receive(:left_hand).and_return(OpenStruct.new(name: 'Empty', noun: nil, id: nil))

      expect(sew.send(:analyze_command)).to eq('analyze my knitting needles')
    end

    it 'does not take sewing needles for knitting needles' do
      sew.instance_variable_set(:@home_tool, 'sewing needles')
      allow(GameObj).to receive(:right_hand).and_return(OpenStruct.new(name: 'slender agonite sewing needles capped with tiny tidal bloodstones', noun: 'needles', id: '1'))
      allow(GameObj).to receive(:left_hand).and_return(OpenStruct.new(name: 'burlap reinforced netting', noun: 'netting', id: '2'))

      expect(sew.send(:analyze_command)).to eq(analyze)
    end

    # Review of #8067 (mrhoribu): an ANALYZE that finds nothing to analyze
    # ("I could not find what you were referring to.") was taken as a reply
    # sew knows, so the count started again and ANALYZE, INV ATFEET and the
    # lift went round without end.
    it 'counts an ANALYZE that finds nothing as a miss, so it cannot go round forever' do
      allow(sew).to receive(:list_at_feet)
      allow(sew).to receive(:lift_or_stow_feet)

      run_work('push my rucksack with my sewing needles', '', 'I could not find what you were', 'What were you referring')

      expect(sent).to eq(['push my rucksack with my sewing needles', analyze, analyze])
      expect(sew).not_to have_received(:list_at_feet)
      expect(Lich::Messaging).to have_received(:msg).with('bold', give_up_message('push my rucksack with my sewing needles'))
    end

    it 'stops the same way when the first cut gets a reply sew does not know and there is no item yet to analyze' do
      allow(sew).to receive(:list_at_feet)
      allow(sew).to receive(:lift_or_stow_feet)

      run_work('cut my burlap cloth with my scissors', '', 'I could not find what you were', 'I could not find what you were')

      expect(sent.count(analyze)).to eq(Sew::MAX_UNMATCHED - 1)
      expect(Lich::Messaging).to have_received(:msg).with('bold', give_up_message('cut my burlap cloth with my scissors'))
    end

    it 'still treats "I could not find" to a crafting command as a missing tool or item' do
      allow(sew).to receive(:list_at_feet)
      allow(sew).to receive(:lift_or_stow_feet)
      allow(DRCC).to receive(:check_consumables)

      run_work('poke my rucksack with my pins', 'I could not find what you were', 'You need a larger amount of material to continue crafting')

      expect(sew).to have_received(:list_at_feet)
      expect(DRCC).to have_received(:check_consumables).with('pins', 1, 5, 'duffel bag', [], nil)
    end

    it 'keeps MAX_UNMATCHED above one so a missed reply gets an ANALYZE' do
      expect(Sew::MAX_UNMATCHED).to be > 1
    end
  end

  # ===========================================================================
  # Edge cases and integration-level scenarios
  # ===========================================================================
  describe 'finish default for resume' do
    it 'defaults @finish to hold when args.finish is nil' do
      # The @finish default is set in initialize, but we can verify the
      # pattern: args.finish || 'hold' means nil args.finish -> 'hold'
      sew.instance_variable_set(:@finish, 'hold')
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
      expect(Lich::Messaging).to receive(:msg).with('plain', a_string_matching(/\Asew: Completed .*rucksack.* finish: log\z/))

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

      expect(Lich::Messaging).to receive(:msg).with('bold', 'rucksack complete -- holding in hand.')
      allow(Lich::Messaging).to receive(:msg).with('plain', anything)

      sew.send(:finish)
    end

    it 'uses plain for the finish summary' do
      sew.instance_variable_set(:@finish, 'log')
      $right_hand = nil
      $left_hand = nil
      allow(DRCC).to receive(:logbook_item)

      expect(Lich::Messaging).to receive(:msg).with('plain', a_string_matching(/\Asew: Completed .*rucksack.* finish: log\z/))

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

  # ===========================================================================
  # Flags matchers -- only the game's own lines, not other players' text
  # ===========================================================================
  # ===========================================================================
  # #initialize -- hands are cleared before the consumables check
  # ===========================================================================
  describe '#initialize clearing hands' do
    let(:calls) { [] }

    before(:each) do
      $test_settings = OpenStruct.new(hometown: 'Crossing', crafting_training_spells: [])
      $test_data = OpenStruct.new(crafting: { 'tailoring' => { 'Crossing' => { 'tool-room' => 1, 'stock-room' => 2 } } })
      allow(sew).to receive(:clear_hands) { calls << :clear_hands }
      allow(DRCC).to receive(:check_consumables) { |name, *| calls << "check_consumables #{name}" }
      allow(sew).to receive(:check_rental_status)
      allow(sew).to receive(:prep).and_return('push my rucksack with my needles')
      allow(sew).to receive(:work)
    end

    # check_consumables starts with a get, which a full pair of hands
    # answers with "You need a free hand"; it matches neither of its
    # patterns, so it would time out and buy stock the player owns.
    it 'clears hands before checking pins and thread' do
      $parsed_args = OpenStruct.new(finish: 'stow', type: 'sewing', chapter: '2', recipe_name: +'rucksack',
                                    material: 'burlap', noun: 'rucksack')

      sew.send(:initialize)

      expect(calls).to eq([:clear_hands, 'check_consumables pins', 'check_consumables cotton thread'])
    end

    # spin keeps its spools ("some heavy silk thread") in the crafting
    # container, and `get my thread from my <bag>` would take one for the
    # sewing thread, count its yards as uses, and skip buying cotton thread.
    it 'checks the cotton thread by name, never the bare noun a spun spool shares' do
      $parsed_args = OpenStruct.new(finish: 'stow', type: 'sewing', chapter: '2', recipe_name: +'rucksack',
                                    material: 'burlap', noun: 'rucksack')

      sew.send(:initialize)

      expect(DRCC).to have_received(:check_consumables).with('cotton thread', 2, 6, any_args)
      expect(DRCC).not_to have_received(:check_consumables).with('thread', any_args)
    end

    it 'clears hands before checking wax for a seal' do
      $parsed_args = OpenStruct.new(recipe_name: +'seal', noun: 'shirt')

      sew.send(:initialize)

      expect(calls).to eq([:clear_hands, 'check_consumables wax'])
    end

    it 'still clears hands when skip turns the consumables check off' do
      $parsed_args = OpenStruct.new(finish: 'stow', type: 'sewing', chapter: '2', recipe_name: +'rucksack',
                                    material: 'burlap', noun: 'rucksack', skip: 'skip')

      sew.send(:initialize)

      expect(calls).to eq([:clear_hands])
    end
  end

  describe 'flag matchers registered by #initialize' do
    # Feed a server line through the registered Flags matchers, the way
    # Lich's DRParser.check_events does for every downstream line.
    def deliver(line)
      Flags.matchers.each do |key, regexes|
        regexes.each do |regex|
          if (match = line.match(regex))
            Flags[key] = match
            break
          end
        end
      end
    end

    # The line shapes other players' text arrives in: ESP, say and whisper,
    # as stripped text and as the raw XML the Flags see.
    def player_shapes(text)
      [
        %([General][Mallory] "#{text}"),
        %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
        %(Mallory says, "#{text}"),
        %(<preset id='speech'>Mallory says</preset>, "#{text}"),
        %(Mallory whispers, "#{text}"),
        %(<pushStream id="whispers"/><preset id="whisper">Mallory whispers,</preset> "#{text}"<popStream/>)
      ]
    end

    let(:sent) { [] }

    before(:each) do
      $test_settings = OpenStruct.new(hometown: 'Crossing', crafting_training_spells: [])
      $test_data = OpenStruct.new(crafting: { 'tailoring' => { 'Crossing' => { 'tool-room' => 1, 'stock-room' => 2 } } })
      $parsed_args = OpenStruct.new(finish: 'trash', type: 'sewing', chapter: '2', recipe_name: +'rucksack',
                                    material: 'burlap', noun: 'rucksack', skip: 'skip')
      allow(sew).to receive(:prep).and_return('push my rucksack with my needles')
      allow(sew).to receive(:check_rental_status)
      allow(sew).to receive(:work)
      sew.send(:initialize)
      allow(sew).to receive(:work).and_call_original
      allow(sew).to receive(:exit).and_raise(SystemExit)
    end

    # Runs the craft loop: `heard` arrives during the first push, the second
    # push returns Roundtime too, and the third ends the loop.
    def run_work(heard)
      pushes = 0
      allow(DRC).to receive(:bput) do |command, *_matches|
        sent << command
        next 'You put' unless command.start_with?('push my rucksack')

        pushes += 1
        raise StopIteration if pushes > 2

        deliver(heard) if pushes == 1
        'Roundtime: 5 sec.'
      end
      sew.send(:work, 'push my rucksack with my needles')
      :kept_working
    rescue SystemExit
      :finished
    end

    describe "'sew-done'" do
      real_done_lines = [
        'Applying the final touches, you complete working on a burlap rucksack.',
        '<pushBold/>Applying the final touches, you complete working on a burlap rucksack.',
        'The burlap rucksack shows improved protection.',
        'The burlap rucksack shows a slightly reduced weight.',
        'You realize that cannot be repaired, and stop.',
        # Lich prepends this tag to the line after an atmospherics push.
        '<popStream id="atmospherics" />You realize that cannot be repaired, and stop.'
      ]
      done_phrases = [
        'Applying the final touches, you complete working on a burlap rucksack.',
        'The burlap rucksack shows improved protection.',
        'The burlap rucksack shows a slightly reduced weight.',
        'You realize that cannot be repaired, and stop.'
      ]

      real_done_lines.each do |line|
        it "finishes and disposes of the item on the game line: #{line}" do
          expect(DRCI).to receive(:dispose_trash).with('rucksack', nil, nil)

          expect(run_work(line)).to eq(:finished)
        end
      end

      done_phrases.each do |phrase|
        it "keeps crafting when other players' text carries: #{phrase}" do
          expect(DRCI).not_to receive(:dispose_trash)

          player_shapes(phrase).each { |line| expect(run_work(line)).to eq(:kept_working) }
          expect(Flags['sew-done']).to be(false)
        end
      end

      it 'finishes when the game line follows a player line in the same chunk' do
        expect(DRCI).to receive(:dispose_trash).with('rucksack', nil, nil)

        chunk = %(Mallory says, "nearly there"\r\nApplying the final touches, you complete working on a burlap rucksack.)
        expect(run_work(chunk)).to eq(:finished)
      end
    end

    describe "'sew-assembly'" do
      real_assembly_lines = {
        'You need another finished small cloth padding to continue crafting a burlap rucksack.'          => 'small padding',
        'The burlap rucksack is ready to be lined with some large cloth padding.'                        => 'large padding',
        'You need another finished target shield handle to continue crafting a burlap rucksack.'         => 'handle',
        'You need another finished wooden hilt to continue crafting a burlap rucksack.'                  => 'hilt',
        '<pushBold/>You need another finished long leather cord to continue crafting a burlap rucksack.' => 'long cord',
        'You need another finished short wooden pole to continue crafting a burlap rucksack.'            => 'short pole'
      }

      real_assembly_lines.each do |line, part|
        it "assembles '#{part}' on the game line: #{line}" do
          run_work(line)

          expect(sent).to include("assemble my rucksack with my #{part}")
        end
      end

      real_assembly_lines.each_key.map { |line| line.delete_prefix('<pushBold/>') }.each do |phrase|
        it "assembles nothing when other players' text carries: #{phrase}" do
          player_shapes(phrase).each { |line| run_work(line) }

          expect(sent.grep(/^assemble/)).to be_empty
          expect(Flags['sew-assembly']).to be(false)
        end
      end
    end

    describe "'sew-rental-warning'" do
      # The game's warning (angua DR log 2026-11-02): the sentry's speech,
      # then a bracketed line. In the raw XML <pushBold/> is on its own line.
      sentry_line = 'The sentry peeks in and gruffly announces, "Your rental time is almost up.  If you want to stay longer, you gotta pay up again."'
      notice_line = '[You have less than 10 minutes remaining.  If you wish to renew your rental, simply MARK NOTICE to signal the sentry.]'

      [notice_line, "<pushBold/>#{notice_line}"].each do |line|
        it "renews the rental on the game line: #{line}" do
          run_work(line)

          expect(sent).to include('mark notice')
        end
      end

      it 'renews when the warning arrives as the two game lines in one chunk' do
        run_work("#{sentry_line}\r\n#{notice_line}")

        expect(sent).to include('mark notice')
      end

      it "does not renew when other players' text carries the warning" do
        (player_shapes(notice_line) + player_shapes('Your rental time is almost up.')).each { |line| run_work(line) }

        expect(sent).not_to include('mark notice')
        expect(Flags['sew-rental-warning']).to be(false)
      end
    end
  end

  describe 'CLOTH' do
    it 'includes both bare imperial and imperial weave' do
      expect(Sew::CLOTH).to include('imperial', 'imperial weave')
    end

    it 'is frozen' do
      expect(Sew::CLOTH).to be_frozen
    end
  end
end
