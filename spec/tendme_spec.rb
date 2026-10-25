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

    it 'returns true when a parasite slips free' do
      allow(DRC).to receive(:bput).and_return('The blood mite slips free and quickly slithers away, vanishing from sight within moments.')
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

    it 'returns false on a careless tend attempt' do
      allow(DRC).to receive(:bput).and_return('You carelessly attempt to remove the blood mite from your neck leaving the wound more severe than before.')
      expect(tender.tend_wound_safely('neck')).to be false
    end

    it 'returns false on a foolish tend attempt' do
      allow(DRC).to receive(:bput).and_return('You foolishly attempt to remove the blood mite from your right eye tearing the flesh and horribly aggravating the wound!')
      expect(tender.tend_wound_safely('right eye')).to be false
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

  # monitor_health registers four Flags and loops forever. Each example runs
  # one pass: the first pause delivers a server line through the registered
  # matchers (as lich-5's DRParser.check_events does for every raw XML line),
  # the second pause ends the loop. Only the game's own lines may trigger a
  # re-tend or an unwrap; another player's speech, whisper or ESP may not.
  describe '#monitor_health' do
    subject(:tend_me) { TendMe.allocate }

    before(:each) do
      reset_data
      DRSkill._set_xp('First Aid', 10)
      allow(tend_me).to receive(:bind_open_wounds?)
      allow(DRCH).to receive(:unwrap_wound)
    end

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

    def monitor_once(line, train: true)
      pauses = 0
      allow(tend_me).to receive(:pause) do
        pauses += 1
        deliver(line) if pauses == 1
        throw :monitor_stopped if pauses == 2
      end
      catch(:monitor_stopped) { tend_me.monitor_health(train) }
    end

    def player_shapes(text)
      [
        %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
        %([General][Mallory] "#{text}"),
        %(<preset id='speech'>Mallory says</preset>, "#{text}"),
        %(Mallory says, "#{text}"),
        %(<preset id='speech'>Mallory whispers</preset>, "#{text}"),
        %(Mallory whispers, "#{text}")
      ]
    end

    rewrap_text = 'You feel like now might be a good time to change the bandages on your neck.'
    retend_texts = {
      'a new lodged item'         => 'The goblin arrow lodges itself deep in your chest!',
      'a lodged item'             => 'You feel a slight pain from the crossbow bolt lodged in your chest.',
      'bleeding through bandages' => 'The bandages binding your left arm soak through with blood as it begins bleeding again.',
      'bandages falling apart'    => 'The bandages binding your chest become useless and fall apart.',
      'compress soaking through'  => 'The bandages compressing your neck soak through with blood as it begins bleeding again.'
    }

    context 'when the game says it is time to change bandages (train mode)' do
      it 'unwraps the named body part and re-tends' do
        monitor_once(rewrap_text)

        expect(DRCH).to have_received(:unwrap_wound).with('neck')
        expect(tend_me).to have_received(:bind_open_wounds?)
      end

      it 'unwraps when the line arrives behind a leading tag' do
        monitor_once("<pushBold/>#{rewrap_text}")

        expect(DRCH).to have_received(:unwrap_wound).with('neck')
      end

      it 'accepts the bindings wording' do
        monitor_once('You feel like now might be a good time to change the bindings on your right leg.')

        expect(DRCH).to have_received(:unwrap_wound).with('right leg')
      end

      it 'unwraps nothing when another player says, whispers or thinks that line' do
        player_shapes(rewrap_text).each { |line| monitor_once(line) }

        expect(DRCH).not_to have_received(:unwrap_wound)
        expect(tend_me).not_to have_received(:bind_open_wounds?)
      end
    end

    retend_texts.each do |label, text|
      context "when the game reports #{label}" do
        it 're-tends' do
          monitor_once(text)

          expect(tend_me).to have_received(:bind_open_wounds?)
        end

        it 're-tends when the line arrives behind a leading tag' do
          monitor_once("<pushBold/>#{text}")

          expect(tend_me).to have_received(:bind_open_wounds?)
        end

        it 'does not re-tend when another player says, whispers or thinks that line' do
          player_shapes(text).each { |line| monitor_once(line) }

          expect(tend_me).not_to have_received(:bind_open_wounds?)
        end
      end
    end

    it 're-tends on a lodge in the combat stream after a creature attack' do
      monitor_once('<pushStream id="combat" />A goblin fires an arrow at you.  The arrow lodges itself deep in your chest!')

      expect(tend_me).to have_received(:bind_open_wounds?)
    end
  end

  describe '#bind_open_wounds?' do
    subject(:tend_me) { TendMe.allocate }

    def tendme_health_result(overrides = {})
      { 'lodged' => {}, 'parasites' => {}, 'bleeders' => {} }.merge(overrides)
    end

    before(:each) do
      reset_data
      allow(DRCH).to receive(:check_health).and_return(tendme_health_result)
    end

    it 'lifts the item back up after lowering it to free a hand for binding' do
      $left_hand = 'broadsword'
      $right_hand = 'buckler'
      allow(DRCI).to receive(:lower_item?).and_return(true)

      expect(DRCI).to receive(:lift?).with('broadsword')

      tend_me.bind_open_wounds?
    end

    it 'does not lower or lift anything when a hand is free' do
      $left_hand = 'broadsword'
      $right_hand = nil

      expect(DRCI).not_to receive(:lower_item?)
      expect(DRCI).not_to receive(:lift?)

      tend_me.bind_open_wounds?
    end
  end
end
