require_relative 'spec_helper'

# TendMe#initialize runs the full tend loop (pausing scripts, checking health,
# looping), so we extract the class with load_lic_class and exercise the guarded
# tend on a bare-allocated instance (TendMe.allocate). The game layer (DRC/DRCI/
# DRCH/get_settings/waitrt?) comes from the shared test harness; individual
# examples override return values with allow(...). Every example reads
# top-to-bottom (DAMP).
#
# The focus is tend_wound_safely: a guarded copy of DRCH.bind_wound that only
# disposes a dislodged item while it is in hand, so a maze eject (which clears
# your hands the instant a bolt drops) can never make dispose_trash's blind GET
# grab and trash the character's own like-named ammunition.
load_lic_class('tendme.lic', 'TendMe')

RSpec.describe TendMe do
  let(:tender) { TendMe.allocate }

  describe '#tend_wound_safely' do
    let(:removed_abdomen) do
      'You skillfully remove the crossbow bolt from your abdomen leaving the wound no worse than it was before.'
    end
    let(:tended) { 'That area is not bleeding.' }

    # -- Terminal (non-dislodge) results ------------------------------------
    it 'returns true on a successful tend' do
      allow(DRC).to receive(:bput).and_return('You work carefully at tending your wound.')
      expect(tender.tend_wound_safely('right arm')).to be true
    end

    it 'returns true when the area is already tended' do
      allow(DRC).to receive(:bput).and_return('That area has already been tended to.')
      expect(tender.tend_wound_safely('right arm')).to be true
    end

    it 'returns false when the tend fumbles' do
      allow(DRC).to receive(:bput).and_return('You fumble around with the bandages.')
      expect(tender.tend_wound_safely('right arm')).to be false
    end

    it 'returns false when too injured to tend' do
      allow(DRC).to receive(:bput).and_return('You are too injured for you to do that.')
      expect(tender.tend_wound_safely('right arm')).to be false
    end

    it 'passes the person argument through to the tend command' do
      expect(DRC).to receive(:bput).with('tend Muleoak right arm', any_args).and_return('You work carefully at tending')
      tender.tend_wound_safely('right arm', 'Muleoak')
    end

    # -- Dislodged lodged items --------------------------------------------
    it 'disposes a dislodged item that is in hand, then re-tends to a terminal' do
      allow(DRC).to receive(:bput).and_return(removed_abdomen, tended)
      allow(DRCI).to receive(:in_hands?).with('crossbow bolt').and_return(true)
      expect(DRCI).to receive(:dispose_trash).with('crossbow bolt', anything, anything)

      expect(tender.tend_wound_safely('abdomen')).to be true
    end

    it 'does NOT dispose (never grabs a like-named item) when the dislodged item is gone from hand' do
      # The regression: the maze eject clears the hand before disposal runs.
      allow(DRC).to receive(:bput).and_return(removed_abdomen, tended)
      allow(DRCI).to receive(:in_hands?).with('crossbow bolt').and_return(false)
      expect(DRCI).not_to receive(:dispose_trash)

      tender.tend_wound_safely('abdomen')
    end

    it 'treats a nil in-hands result as not-in-hand and skips disposal' do
      allow(DRC).to receive(:bput).and_return(removed_abdomen, tended)
      allow(DRCI).to receive(:in_hands?).and_return(nil)
      expect(DRCI).not_to receive(:dispose_trash)

      tender.tend_wound_safely('abdomen')
    end

    it 'checks in-hands against the exact removed item, not the whole message' do
      allow(DRC).to receive(:bput).and_return(removed_abdomen, tended)
      allow(DRCI).to receive(:in_hands?).and_return(false)

      tender.tend_wound_safely('abdomen')

      expect(DRCI).to have_received(:in_hands?).with('crossbow bolt')
    end

    it 'captures a "some"-quantified dislodged item' do
      removed_plural = 'You deftly remove some crossbow bolts from your abdomen leaving the wound no worse than it was before.'
      allow(DRC).to receive(:bput).and_return(removed_plural, tended)
      allow(DRCI).to receive(:in_hands?).with('crossbow bolts').and_return(true)
      expect(DRCI).to receive(:dispose_trash).with('crossbow bolts', anything, anything)

      tender.tend_wound_safely('abdomen')
    end

    it 'keeps dislodging and disposing each removed item until the area yields a terminal' do
      removed_bolt = 'You deftly remove a crossbow bolt from your chest leaving the wound no worse than it was before.'
      removed_arrow = 'You skillfully remove the arrow from your chest leaving the wound no worse than it was before.'
      allow(DRC).to receive(:bput).and_return(removed_bolt, removed_arrow, 'You work carefully at tending your wound.')
      allow(DRCI).to receive(:in_hands?).and_return(true)
      expect(DRCI).to receive(:dispose_trash).with('crossbow bolt', anything, anything).ordered
      expect(DRCI).to receive(:dispose_trash).with('arrow', anything, anything).ordered

      expect(tender.tend_wound_safely('chest')).to be true
    end

    it 'does not attempt disposal (or an in-hands check) for a dislodge line with no removable item' do
      # The clay-fragment dislodge line matches TEND_DISLODGE_PATTERNS but has no
      # "remove <item> from" capture, so there is nothing to dispose.
      allow(DRC).to receive(:bput).and_return('As you reach for the clay fragment it crumbles to dust.', tended)
      expect(DRCI).not_to receive(:in_hands?)
      expect(DRCI).not_to receive(:dispose_trash)

      tender.tend_wound_safely('chest')
    end

    it 'preserves the person argument across dislodge recursion' do
      allow(DRCI).to receive(:in_hands?).and_return(false)
      allow(DRC).to receive(:bput).and_return(
        'You skillfully remove the crossbow bolt from your chest leaving the wound no worse than it was before.',
        tended
      )

      tender.tend_wound_safely('chest', 'Muleoak')

      expect(DRC).to have_received(:bput).with('tend Muleoak chest', any_args).twice
    end
  end
end
