require_relative 'spec_helper'

# ItemTransfer#initialize parses command-line args and immediately runs the
# transfer, so we extract the class with load_lic_class and exercise the pure
# transfer logic on bare-allocated instances (ItemTransfer.allocate). The game
# layer (DRC/DRCI) is driven with allow(...).to receive(...) per the harness
# rules; the fatal-guard paths call exit, so they are asserted with
# raise_error(SystemExit). Every example reads top-to-bottom (DAMP).
#
# The focus is the coins-abort regression (coins auto-deposit into the purse, so
# GET "fails" and the old code exited the whole transfer) plus the surrounding
# get/move/trash/pagination branches.
load_lic_class('transfer-items.lic', 'ItemTransfer')

RSpec.describe ItemTransfer do
  let(:mover) { ItemTransfer.allocate }

  # Stub the game seams to benign defaults; individual examples override as needed.
  before do
    allow(DRC).to receive(:bput).and_return('are now at the top')
    allow(DRC).to receive(:message)
    allow(DRC).to receive(:left_hand).and_return(nil)
    allow(DRC).to receive(:right_hand).and_return(nil)
    allow(DRCI).to receive(:get_item).and_return(true)
    allow(DRCI).to receive(:put_away_item?).and_return(true)
    allow(DRCI).to receive(:dispose_trash)
  end

  # ===========================================================================
  # Coins: the regression -- must never abort the transfer
  # ===========================================================================
  describe 'coins handling' do
    it 'pulls coins into the purse and moves on without ever trying to stow them' do
      allow(DRCI).to receive(:get_item_list).and_return(['some copper coins'])

      expect { mover.transfer_items('package', 'canvas sack', nil) }.not_to raise_error
      expect(DRCI).to have_received(:get_item).with('coins', 'package')
      expect(DRCI).not_to have_received(:put_away_item?)
    end

    it 'does NOT exit even though GET reports failure for coins (auto-purse)' do
      # This is the exact live bug: "You pick up 5 copper Lirums" then get_item
      # -> in_hands? -> false. The old code fell into the fatal else and exited.
      allow(DRCI).to receive(:get_item_list).and_return(['some copper coins'])
      allow(DRCI).to receive(:get_item).and_return(false)

      expect { mover.transfer_items('package', 'canvas sack', nil) }.not_to raise_error
    end

    it 'skips coins but still transfers the items listed after them' do
      allow(DRCI).to receive(:get_item_list).and_return(['some copper coins', 'a shiny gem'])

      mover.transfer_items('package', 'canvas sack', nil)

      expect(DRCI).to have_received(:put_away_item?).with('gem', 'canvas sack')
    end
  end

  # ===========================================================================
  # Normal item movement and the destination-too-small fallback
  # ===========================================================================
  describe 'moving items to a container' do
    it 'puts a retrieved item into the destination container' do
      allow(DRCI).to receive(:get_item_list).and_return(['a shiny gem'])

      mover.transfer_items('package', 'canvas sack', nil)

      expect(DRCI).to have_received(:put_away_item?).with('gem', 'canvas sack')
    end

    it 'returns an item to the source when the destination cannot hold it' do
      allow(DRCI).to receive(:get_item_list).and_return(['a shiny gem'])
      allow(DRCI).to receive(:put_away_item?).with('gem', 'canvas sack').and_return(false)
      allow(DRCI).to receive(:put_away_item?).with('gem', 'package').and_return(true)

      mover.transfer_items('package', 'canvas sack', nil)

      expect(DRCI).to have_received(:put_away_item?).with('gem', 'package')
      expect(DRC).to have_received(:message).with(/Unable to put gem in your canvas sack/)
    end
  end

  # ===========================================================================
  # The deliberate fatal guard for genuinely un-gettable (non-coin) items
  # ===========================================================================
  describe 'when a non-coin item cannot be retrieved' do
    before do
      allow(DRCI).to receive(:get_item_list).and_return(['a shiny gem'])
      allow(DRCI).to receive(:get_item).and_return(false)
    end

    it 'reports the failure and exits the script' do
      expect(DRC).to receive(:message).with('Unable to get gem from package.')

      expect { mover.transfer_items('package', 'canvas sack', nil) }.to raise_error(SystemExit)
    end

    it 'warns about full hands when both hands are occupied' do
      allow(DRC).to receive(:left_hand).and_return('sword')
      allow(DRC).to receive(:right_hand).and_return('shield')
      expect(DRC).to receive(:message).with('Your hands are full!')

      expect { mover.transfer_items('package', 'canvas sack', nil) }.to raise_error(SystemExit)
    end
  end

  # ===========================================================================
  # Trash destination routing
  # ===========================================================================
  describe 'trashing items' do
    it 'disposes items instead of stowing them when the destination is trash' do
      allow(DRCI).to receive(:get_item_list).and_return(['a shiny gem'])

      mover.transfer_items('package', 'trash', nil)

      expect(DRCI).to have_received(:dispose_trash).with('gem')
      expect(DRCI).not_to have_received(:put_away_item?)
    end
  end

  # ===========================================================================
  # Noun filtering
  # ===========================================================================
  describe 'noun filtering' do
    it 'transfers only items matching the requested noun and sorts them first' do
      allow(DRCI).to receive(:get_item_list).and_return(['a red gem', 'a blue orb'])

      mover.transfer_items('package', 'canvas sack', 'gem')

      expect(DRC).to have_received(:bput).with(/^sort gem in my package/, any_args)
      expect(DRCI).to have_received(:get_item).with('gem', 'package')
      expect(DRCI).not_to have_received(:get_item).with('orb', 'package')
    end
  end

  # ===========================================================================
  # Noun derivation for decorated items (issue #7491)
  # ===========================================================================
  describe 'deriving the GET noun from a decorated item' do
    it 'strips attached/flavor text instead of grabbing the trailing word' do
      # "...with a wool rug on it" -> the old .split.last picked "it", so
      # "get my it from my package" failed. get_noun resolves the base noun.
      allow(DRCI).to receive(:get_item_list)
        .and_return(['a circle of colorful wool with a wool rug on it'])

      mover.transfer_items('package', 'canvas sack', nil)

      expect(DRCI).to have_received(:get_item).with('wool', 'package')
      expect(DRCI).not_to have_received(:get_item).with('it', 'package')
    end
  end

  # ===========================================================================
  # Pagination: "lot of other stuff" forces another LOOK
  # ===========================================================================
  describe 'pagination for over-full containers' do
    it 're-looks once when the list ends in "lot of other stuff" then stops' do
      allow(DRCI).to receive(:get_item_list)
        .and_return(['a shiny gem', 'a lot of other stuff'], [])

      mover.transfer_items('package', 'canvas sack', nil)

      expect(DRCI).to have_received(:get_item_list).twice
    end
  end

  # ===========================================================================
  # Empty source is a clean no-op
  # ===========================================================================
  describe 'an empty source container' do
    it 'does nothing and never exits' do
      allow(DRCI).to receive(:get_item_list).and_return([])

      expect { mover.transfer_items('package', 'canvas sack', nil) }.not_to raise_error
      expect(DRCI).not_to have_received(:get_item)
    end
  end

  # ===========================================================================
  # move_item in isolation
  # ===========================================================================
  describe '#move_item' do
    it 'does not fall back to the source when the destination accepts the item' do
      allow(DRCI).to receive(:put_away_item?).with('gem', 'canvas sack').and_return(true)

      mover.move_item('gem', 'package', 'canvas sack')

      expect(DRCI).not_to have_received(:put_away_item?).with('gem', 'package')
      expect(DRC).not_to have_received(:message)
    end

    it 'warns and returns the item to the source when the destination refuses it' do
      allow(DRCI).to receive(:put_away_item?).with('gem', 'canvas sack').and_return(false)
      allow(DRCI).to receive(:put_away_item?).with('gem', 'package').and_return(true)

      mover.move_item('gem', 'package', 'canvas sack')

      expect(DRC).to have_received(:message).with(/Unable to put gem in your canvas sack/)
      expect(DRCI).to have_received(:put_away_item?).with('gem', 'package')
    end
  end

  # ===========================================================================
  # trash_item in isolation
  # ===========================================================================
  describe '#trash_item' do
    it 'delegates to the shared trash-disposal helper' do
      mover.trash_item('gem')

      expect(DRCI).to have_received(:dispose_trash).with('gem')
    end
  end
end
