require_relative 'spec_helper'

# ShockQuest#initialize drives the whole quest through game I/O (DRC.bput,
# DRCT.walk_to, waitfor, pause), so we never call .new in these specs. Instead
# we allocate a bare instance and exercise the decision logic directly, stubbing
# the thin game-facing seams (DRC, DRCT, pause, waitfor, exit).
#
# The classification specs are the heart of the suite: every pattern is fed the
# exact response text captured from live quest logs and the Elanthipedia
# walkthrough, plus adversarial near-misses designed to break naive matchers.
load_lic_class('shockquest.lic', 'ShockQuest')

RSpec.describe ShockQuest do
  # A bare instance with no initialize side effects. Individual specs inject the
  # handful of ivars the method under test actually reads.
  let(:quest) { ShockQuest.allocate }

  # Stub the game-facing modules. Doubles start permissive (message/walk_to are
  # no-ops); specs that care about bput responses override it locally.
  let(:drc)  { double('DRC') }
  let(:drct) { double('DRCT') }

  before(:each) do
    allow(drc).to receive(:message)
    allow(drc).to receive(:bput).and_return('')
    allow(drct).to receive(:walk_to)
    stub_const('DRC', drc)
    stub_const('DRCT', drct)
  end

  # ===========================================================================
  # Verbatim response text captured from live quest logs (2026-07-05/06).
  # Kept as named helpers so each classification assertion reads as a sentence.
  # ===========================================================================
  let(:log_bonded) do
    'As the strange sensations subside, you feel suddenly fatigued and unsteady.  ' \
      'You sense that something is moving between you and the seed as a vast quantity ' \
      'of life energy is rapidly drawn from you to nurture the infant plant growing within the seed.'
  end

  let(:log_cooldown) do
    "As you direct your senses toward your vela'tohr seed, your fingers seem to tingle in " \
      'sympathy with the abundance of energy recently transferred from you to the nascent plant.  ' \
      "Bewildering images briefly flash through your mind's eye as the world seems to lurch around " \
      'you.  As the confusing sensations subside, you sense that the seed is still processing the ' \
      'energy and experiences it took from you during your last meditation.'
  end

  let(:log_full) do
    "As you direct your senses toward your vela'tohr seed, you perceive that it pulses with life " \
      'energy; the manifestation so powerful that your fingers nearly seem to tingle where they ' \
      'grasp the nascent seed.  A burgeoning feeling of vegetable bliss washes over you, and you ' \
      "sense that your bond with the vela'tohr seed is complete.  You recall that you should return " \
      'the seed to Nadigo for germination to complete your quest.'
  end

  let(:log_familiar) do
    'You close your eyes and breathe deeply, directing your mental and magical senses toward the ' \
      "vela'tohr seed dangling from the cord around your neck.  You brush the seed with your " \
      'fingers, attempting to form a bond with the infant plant.  Bewildering alien visions flash ' \
      "through your mind's eye, and you sense that the nascent consciousness growing within the seed " \
      'is already familiar with this area.  A brief surge of vegetable contentment courses through you.'
  end

  let(:log_distracted) { 'You attempt to meditate, but have trouble concentrating.' }

  # ===========================================================================
  # Response text from the Elanthipedia walkthrough (conditions never hit in the
  # captured logs because the default route is all-valid, but that the rewrite
  # must handle for custom routes or map drift).
  # ===========================================================================
  let(:wiki_too_close) do
    "you realize that you are still too close to the area where the tainted vela'tohr grow."
  end

  let(:wiki_bad_location) do
    'You sense some magical stirring within the seed, but nothing more happens despite your concentration.'
  end

  let(:wiki_destroyed) do
    'The seed grows dull and lusterless, before shriveling and crumbling away.'
  end

  # ===========================================================================
  # #classify_meditation
  # ===========================================================================
  describe '#classify_meditation' do
    context 'with exact text captured from live quest logs' do
      it 'classifies a successful bond as :bonded' do
        expect(quest.classify_meditation(log_bonded)).to eq(:bonded)
      end

      it 'classifies the cooldown response as :cooldown' do
        expect(quest.classify_meditation(log_cooldown)).to eq(:cooldown)
      end

      it 'classifies the fully-charged response as :full' do
        expect(quest.classify_meditation(log_full)).to eq(:full)
      end

      it 'classifies the already-visited-zone response as :familiar' do
        expect(quest.classify_meditation(log_familiar)).to eq(:familiar)
      end

      it 'classifies the distraction response as :distracted' do
        expect(quest.classify_meditation(log_distracted)).to eq(:distracted)
      end
    end

    context 'with walkthrough-documented failure conditions' do
      it 'classifies proximity to the tainted woods as :too_close' do
        expect(quest.classify_meditation(wiki_too_close)).to eq(:too_close)
      end

      it 'classifies an unsuitable location as :bad_location' do
        expect(quest.classify_meditation(wiki_bad_location)).to eq(:bad_location)
      end

      it 'classifies a destroyed seed as :destroyed' do
        expect(quest.classify_meditation(wiki_destroyed)).to eq(:destroyed)
      end
    end

    context 'adversarial near-misses' do
      it 'does NOT treat the cooldown response as a bond despite "confusing sensations subside"' do
        # The cooldown flavor text ends "As the confusing sensations subside" - a
        # single character class away from the success phrase. This is the exact
        # trap that would corrupt cooldown handling if the matcher were sloppy.
        expect(quest.classify_meditation(log_cooldown)).not_to eq(:bonded)
      end

      it 'prefers :full over :distracted when a single line contains both phrases' do
        # In the logs the germination line is immediately followed by "trouble
        # concentrating"; if both ever collapse into one response, completion wins.
        combined = 'return the seed to Nadigo for germination to complete your quest. ' \
                   'You attempt to meditate, but have trouble concentrating.'
        expect(quest.classify_meditation(combined)).to eq(:full)
      end

      it 'prefers :destroyed over any lesser outcome' do
        combined = 'the seed is still processing the energy ... shriveling and crumbling away.'
        expect(quest.classify_meditation(combined)).to eq(:destroyed)
      end
    end

    context 'with unrecognized or empty input' do
      it 'returns :unknown for an empty string (bput timeout)' do
        expect(quest.classify_meditation('')).to eq(:unknown)
      end

      it 'returns :unknown for nil' do
        expect(quest.classify_meditation(nil)).to eq(:unknown)
      end

      it 'returns :unknown for unrelated game noise' do
        expect(quest.classify_meditation('Rage of the Clans  (30 roisaen)')).to eq(:unknown)
      end
    end
  end

  # ===========================================================================
  # #meditate_at_spot -- the core bug fix: cooldowns retry in place, they do
  # not consume a route spot.
  # ===========================================================================
  describe '#meditate_at_spot' do
    let(:spot) { { 'room' => '8741', 'safe' => '4105' } }

    before(:each) do
      quest.instance_variable_set(:@max_retries, 3)
      quest.instance_variable_set(:@retry_interval, 120)
      allow(quest).to receive(:pause)
    end

    it 'walks to the spot room before meditating' do
      allow(quest).to receive(:perform_meditation).and_return(log_bonded)
      quest.meditate_at_spot(spot)
      expect(drct).to have_received(:walk_to).with('8741')
    end

    it 'returns :bonded immediately on a first-try success without waiting' do
      allow(quest).to receive(:perform_meditation).and_return(log_bonded)
      expect(quest.meditate_at_spot(spot)).to eq(:bonded)
      expect(quest).not_to have_received(:pause)
    end

    it 'retries the SAME spot on cooldown and succeeds without advancing' do
      allow(quest).to receive(:perform_meditation).and_return(log_cooldown, log_cooldown, log_bonded)
      expect(quest.meditate_at_spot(spot)).to eq(:bonded)
      # Walked to the spot exactly once; two cooldowns => two waits.
      expect(drct).to have_received(:walk_to).once
      expect(quest).to have_received(:pause).with(120).twice
    end

    it 'retries a transient distraction in place then succeeds' do
      allow(quest).to receive(:perform_meditation).and_return(log_distracted, log_bonded)
      expect(quest.meditate_at_spot(spot)).to eq(:bonded)
      expect(quest).to have_received(:pause).once
    end

    it 'gives up as :unknown after exhausting retries on a permanent cooldown' do
      allow(quest).to receive(:perform_meditation).and_return(log_cooldown)
      expect(quest.meditate_at_spot(spot)).to eq(:unknown)
      # max_retries=3 => three waits, then bail (never loops forever).
      expect(quest).to have_received(:pause).exactly(3).times
    end

    it 'returns :full straight through without retrying' do
      allow(quest).to receive(:perform_meditation).and_return(log_full)
      expect(quest.meditate_at_spot(spot)).to eq(:full)
      expect(quest).not_to have_received(:pause)
    end

    it 'returns :familiar immediately so the caller can skip the spot' do
      allow(quest).to receive(:perform_meditation).and_return(log_familiar)
      expect(quest.meditate_at_spot(spot)).to eq(:familiar)
      expect(quest).not_to have_received(:pause)
    end
  end

  # ===========================================================================
  # #charge_seed -- route dispatch
  # ===========================================================================
  describe '#charge_seed' do
    let(:route) do
      [{ 'room' => '1' }, { 'room' => '2' }, { 'room' => '3' }]
    end

    before(:each) do
      quest.instance_variable_set(:@meditation_spots, route)
      allow(quest).to receive(:rest_after_bond)
      allow(quest).to receive(:deliver_seed)
      allow(quest).to receive(:announce_incomplete)
    end

    it 'delivers the seed and stops the route the moment it is full' do
      allow(quest).to receive(:meditate_at_spot).and_return(:full)
      quest.charge_seed
      expect(quest).to have_received(:deliver_seed).once
      expect(quest).to have_received(:meditate_at_spot).once
    end

    it 'rests after a bond and continues to the next spot until full' do
      allow(quest).to receive(:meditate_at_spot).and_return(:bonded, :full)
      quest.charge_seed
      expect(quest).to have_received(:rest_after_bond).once
      expect(quest).to have_received(:deliver_seed).once
      expect(quest).to have_received(:meditate_at_spot).twice
    end

    it 'skips unusable spots without resting or delivering' do
      allow(quest).to receive(:meditate_at_spot).and_return(:familiar, :too_close, :bad_location)
      quest.charge_seed
      expect(quest).not_to have_received(:rest_after_bond)
      expect(quest).not_to have_received(:deliver_seed)
    end

    it 'announces an incomplete quest when the route is exhausted unfilled' do
      allow(quest).to receive(:meditate_at_spot).and_return(:familiar, :familiar, :familiar)
      quest.charge_seed
      expect(quest).to have_received(:announce_incomplete).once
    end

    it 'aborts on a destroyed seed without announcing incomplete or delivering' do
      allow(quest).to receive(:meditate_at_spot).and_return(:destroyed)
      quest.charge_seed
      expect(quest).not_to have_received(:deliver_seed)
      expect(quest).not_to have_received(:announce_incomplete)
      expect(quest).to have_received(:meditate_at_spot).once
    end
  end

  # ===========================================================================
  # #wait_cooldown -- chunked countdown
  # ===========================================================================
  describe '#wait_cooldown' do
    before(:each) { allow(quest).to receive(:pause) }

    it 'sleeps in progress-interval chunks and a final remainder' do
      quest.instance_variable_set(:@cooldown_seconds, 12 * 60)
      quest.wait_cooldown
      expect(quest).to have_received(:pause).with(5 * 60).twice
      expect(quest).to have_received(:pause).with(2 * 60).once
    end

    it 'waits exactly the configured duration when evenly divisible' do
      quest.instance_variable_set(:@cooldown_seconds, 10 * 60)
      quest.wait_cooldown
      expect(quest).to have_received(:pause).with(5 * 60).twice
    end

    it 'does not pause at all for a zero cooldown' do
      quest.instance_variable_set(:@cooldown_seconds, 0)
      quest.wait_cooldown
      expect(quest).not_to have_received(:pause)
    end
  end

  # ===========================================================================
  # #rest_after_bond -- safe-room retreat is conditional
  # ===========================================================================
  describe '#rest_after_bond' do
    before(:each) do
      quest.instance_variable_set(:@cooldown_seconds, 0)
      allow(quest).to receive(:wait_cooldown)
    end

    it 'retreats to the safe room when one is configured' do
      quest.rest_after_bond({ 'room' => '8741', 'safe' => '4105' })
      expect(drct).to have_received(:walk_to).with('4105')
    end

    it 'stays put when the spot has no safe room' do
      quest.rest_after_bond({ 'room' => '4111' })
      expect(drct).not_to have_received(:walk_to)
    end

    it 'always waits out the cooldown' do
      quest.rest_after_bond({ 'room' => '4111' })
      expect(quest).to have_received(:wait_cooldown)
    end
  end

  # ===========================================================================
  # #seed_on_hand?
  # ===========================================================================
  describe '#seed_on_hand?' do
    it 'is true when the seed can be tapped' do
      allow(drc).to receive(:bput).and_return("You tap a lumpy vela'tohr seed dangling from a twisted jute cord")
      expect(quest.seed_on_hand?).to be true
    end

    it 'is false when the seed cannot be found' do
      allow(drc).to receive(:bput).and_return('I could not find what you were referring to')
      expect(quest.seed_on_hand?).to be false
    end
  end

  # ===========================================================================
  # #ensure_seed
  # ===========================================================================
  describe '#ensure_seed' do
    it 'succeeds without travelling when the seed is already on hand' do
      allow(quest).to receive(:seed_on_hand?).and_return(true)
      allow(quest).to receive(:acquire_seed)
      expect(quest.ensure_seed).to be true
      expect(drct).not_to have_received(:walk_to)
      expect(quest).not_to have_received(:acquire_seed)
    end

    it 'travels to Nadigo and succeeds when a seed is acquired' do
      allow(quest).to receive(:seed_on_hand?).and_return(false)
      allow(quest).to receive(:acquire_seed).and_return(true)
      expect(quest.ensure_seed).to be true
      expect(drct).to have_received(:walk_to).with(ShockQuest::NADIGO_ROOM)
      expect(quest).to have_received(:acquire_seed)
    end

    it 'fails fast when Nadigo never hands over a seed' do
      allow(quest).to receive(:seed_on_hand?).and_return(false)
      allow(quest).to receive(:acquire_seed).and_return(false)
      expect(quest.ensure_seed).to be false
      expect(drc).to have_received(:message).with(/aborting/i)
    end
  end

  # ===========================================================================
  # #acquire_seed -- Nadigo's dialogue tree
  # ===========================================================================
  describe '#acquire_seed' do
    before(:each) do
      quest.instance_variable_set(:@max_retries, 5)
      allow(quest).to receive(:waitfor)
      allow(quest).to receive(:exit)
    end

    it 'waits for the medallion line and reports success when Nadigo agrees' do
      allow(drc).to receive(:bput).and_return('gazes at you searchingly, then nods')
      expect(quest.acquire_seed).to be true
      expect(quest).to have_received(:waitfor).with('strung on a medallion')
      expect(quest).not_to have_received(:exit)
    end

    it 'exits when Nadigo says it is still too soon' do
      allow(drc).to receive(:bput).and_return('It is still too soon')
      quest.acquire_seed
      expect(quest).to have_received(:exit)
    end

    it 'keeps asking through the intro dialogue until Nadigo agrees' do
      allow(drc).to receive(:bput).and_return(
        'gives a slight nod of his head',
        'gazes at you searchingly, then nods'
      )
      expect(quest.acquire_seed).to be true
      expect(drc).to have_received(:bput).twice
      expect(quest).to have_received(:waitfor).with('strung on a medallion')
    end

    it 'reports failure when Nadigo never agrees within the retry budget' do
      quest.instance_variable_set(:@max_retries, 3)
      allow(drc).to receive(:bput).and_return('gives a slight nod of his head')
      expect(quest.acquire_seed).to be false
      expect(drc).to have_received(:bput).exactly(3).times
      expect(quest).not_to have_received(:waitfor)
    end
  end

  # ===========================================================================
  # #ensure_empath -- guild guard
  # ===========================================================================
  describe '#ensure_empath' do
    it 'returns true for an Empath' do
      allow(DRStats).to receive(:empath?).and_return(true)
      expect(quest.ensure_empath).to be true
    end

    it 'returns false and warns for a non-Empath' do
      allow(DRStats).to receive(:empath?).and_return(false)
      expect(quest.ensure_empath).to be false
      expect(drc).to have_received(:message).with(/Empath/)
    end
  end

  # ===========================================================================
  # #load_settings -- defaults and overrides
  # ===========================================================================
  describe '#load_settings' do
    it 'falls back to module defaults when settings are blank' do
      quest.load_settings(OpenStruct.new)
      expect(quest.instance_variable_get(:@meditation_spots)).to eq(ShockQuest::DEFAULT_MEDITATION_SPOTS)
      expect(quest.instance_variable_get(:@cooldown_seconds)).to eq(ShockQuest::DEFAULT_COOLDOWN_SECONDS)
      expect(quest.instance_variable_get(:@retry_interval)).to eq(ShockQuest::DEFAULT_RETRY_INTERVAL_SECONDS)
      expect(quest.instance_variable_get(:@max_retries)).to eq(ShockQuest::DEFAULT_MAX_COOLDOWN_RETRIES)
    end

    it 'honors caller-provided overrides' do
      custom_spots = [{ 'room' => '9999' }]
      settings = OpenStruct.new(
        shockquest_meditation_spots: custom_spots,
        shockquest_cooldown_seconds: 3900,
        shockquest_retry_interval_seconds: 90,
        shockquest_max_retries: 4
      )
      quest.load_settings(settings)
      expect(quest.instance_variable_get(:@meditation_spots)).to eq(custom_spots)
      expect(quest.instance_variable_get(:@cooldown_seconds)).to eq(3900)
      expect(quest.instance_variable_get(:@retry_interval)).to eq(90)
      expect(quest.instance_variable_get(:@max_retries)).to eq(4)
    end
  end

  # ===========================================================================
  # #perform_meditation -- sends the command with every classifier pattern
  # ===========================================================================
  describe '#perform_meditation' do
    it 'issues MEDITATE SEED against all classifier patterns' do
      quest.perform_meditation
      patterns = ShockQuest::MEDITATION_RESPONSES.map { |_outcome, pattern| pattern }
      expect(drc).to have_received(:bput).with('meditate seed', *patterns)
    end
  end

  # ===========================================================================
  # Constants and version
  # ===========================================================================
  describe 'constants' do
    it 'exposes a semver VERSION' do
      expect(ShockQuest::VERSION).to match(/^\d+\.\d+\.\d+$/)
    end

    it 'defaults the cooldown near the top of the 56-65 minute window' do
      minutes = ShockQuest::DEFAULT_COOLDOWN_SECONDS / 60.0
      expect(minutes).to be_between(56, 66)
    end

    it 'keeps retry and skip outcome sets disjoint' do
      expect(ShockQuest::RETRY_OUTCOMES & ShockQuest::SKIP_OUTCOMES).to be_empty
    end

    it 'every classifier outcome is terminal, retryable, or a completion state' do
      terminal = ShockQuest::SKIP_OUTCOMES + ShockQuest::RETRY_OUTCOMES + %i[bonded full destroyed]
      classifier_outcomes = ShockQuest::MEDITATION_RESPONSES.map { |outcome, _pattern| outcome }
      expect(classifier_outcomes - terminal).to be_empty
    end
  end
end
