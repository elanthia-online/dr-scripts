# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('walkingastro.lic', 'WalkingAstro')

RSpec.describe WalkingAstro do
  let(:telescope_storage) { { 'container' => 'backpack' } }
  let(:mirror) { { 'name' => 'mirror', 'container' => 'bag' } }

  # The observe_* message lists from data/base-constellations.yaml.
  let(:full_messages) { ["You believe you've learned", 'Too many futures'] }
  let(:partial_messages) { ['You learned something useful', 'Although you were nearly'] }
  let(:failed_messages) do
    [
      'You are unable to make use of this latest observation',
      'You have not pondered your last observation sufficiently',
      'You see nothing regarding the future'
    ]
  end

  # A WalkingAstro with the ivars initialize would set, without running its
  # main loop. Any ivar can be overridden by keyword.
  def build_walker(**overrides)
    ivars = {
      settings: OpenStruct.new(walkingastro: {}),
      telescope_name: 'telescope',
      telescope_storage: telescope_storage,
      no_use_scripts: [],
      full_messages: full_messages,
      partial_messages: partial_messages,
      failed_messages: failed_messages,
      divination_tool: nil,
      divination_bones_storage: nil,
      use_tools: false,
      use_partial_pools: false,
      predict_regardless_of_mindstate: false
    }.merge(overrides)

    walker = WalkingAstro.allocate
    ivars.each { |name, value| walker.instance_variable_set("@#{name}", value) }
    walker
  end

  before(:each) do
    DRStats.circle = 50
    allow(DRC).to receive(:message)
  end

  describe '#get_telescope' do
    context 'when get_telescope? gets the telescope' do
      it 'goes on to determine_time' do
        walker = build_walker
        expect(DRCMM).to receive(:get_telescope?).with('telescope', telescope_storage).and_return(true)
        expect(walker).to receive(:determine_time)

        expect(walker.get_telescope).to be(true)
      end

      it 'asks for the telescope by the telescope_name setting' do
        walker = build_walker(telescope_name: 'spyglass')
        allow(walker).to receive(:determine_time)

        expect(DRCMM).to receive(:get_telescope?).with('spyglass', telescope_storage).and_return(true)

        walker.get_telescope
      end

      it 'puts the telescope away afterwards, so should_observe? sees empty hands next time' do
        walker = build_walker
        allow(DRCMM).to receive(:get_telescope?).and_return(true)
        expect(walker).to receive(:determine_time).ordered
        expect(DRCMM).to receive(:store_telescope?).with('telescope', telescope_storage).ordered.and_return(true)

        walker.get_telescope
      end

      it 'still puts the telescope away when TIME gets no reply' do
        walker = build_walker
        allow(DRCMM).to receive(:get_telescope?).and_return(true)
        allow(DRC).to receive(:bput).with('time', any_args).and_return('')

        expect(DRCMM).not_to receive(:center_telescope)
        expect(DRCMM).to receive(:store_telescope?).with('telescope', telescope_storage).and_return(true)

        walker.get_telescope
      end
    end

    context 'when both hands are full' do
      before(:each) do
        $left_hand = 'steel sword'
        $right_hand = 'target shield'
        allow(DRCMM).to receive(:get_telescope?).and_return(false)
      end

      it 'returns false so the main loop tries again once the hands are empty' do
        walker = build_walker
        expect(walker).not_to receive(:determine_time)

        expect(walker.get_telescope).to be(false)
        expect(DRC).to have_received(:message).with(/No free hand to get your telescope/)
      end

      it 'does not pause and retry while the other scripts are still paused' do
        walker = build_walker
        expect(walker).not_to receive(:pause)

        walker.get_telescope
      end
    end

    context 'when the telescope cannot be found' do
      before(:each) do
        allow(DRCMM).to receive(:get_telescope?).and_return(false)
      end

      it 'says so and returns true, so the next try waits for the observation timer' do
        walker = build_walker
        expect(walker).not_to receive(:determine_time)

        expect(walker.get_telescope).to be(true)
        expect(DRC).to have_received(:message).with(/Couldn't get your telescope\. Check telescope_name and telescope_storage/)
      end

      it 'puts away a telescope that a slow reply left in hand' do
        walker = build_walker
        expect(DRCMM).to receive(:store_telescope?).with('telescope', telescope_storage).and_return(true)

        walker.get_telescope
      end
    end

    context 'when every prediction pool is already full' do
      it 'goes straight to predicting without getting the telescope' do
        %w[offense defense magic survival lore].each { |pool| Flags["#{pool}-full"] = true }
        walker = build_walker
        expect(DRCMM).not_to receive(:get_telescope?)
        expect(walker).to receive(:check_predict)

        expect(walker.get_telescope).to be(true)
      end
    end
  end

  describe '#store_telescope' do
    it 'says so when the telescope will not go away' do
      walker = build_walker
      allow(DRCMM).to receive(:store_telescope?).and_return(false)

      walker.store_telescope

      expect(DRC).to have_received(:message).with(/Couldn't put your telescope away/)
    end
  end

  describe '#main_loop' do
    # Kernel#loop ends quietly on StopIteration, so a pause stub that raises it
    # after a few ticks stops the otherwise endless loop.
    it 'tries again on the next tick once hands that were full are empty' do
      $left_hand = 'steel sword'
      $right_hand = 'target shield'
      walker = build_walker
      allow(walker).to receive(:can_see_sky?).and_return(true)
      allow(DRCMM).to receive(:get_telescope?) { $left_hand.nil? && $right_hand.nil? }
      allow(walker).to receive(:determine_time)

      ticks = 0
      allow(walker).to receive(:pause) do
        ticks += 1
        # The player frees their hands during the first tick.
        $left_hand = nil
        $right_hand = nil
        raise StopIteration if ticks >= 3
      end

      walker.main_loop

      expect(DRCMM).to have_received(:get_telescope?).twice
      expect(walker).to have_received(:determine_time).once
      expect(Flags['observation-ready']).to be_falsey
    end

    it 'does not keep asking for a missing telescope, but tries again after the observation timer' do
      walker = build_walker
      allow(walker).to receive(:can_see_sky?).and_return(true)

      clock = Time.at(0)
      allow(Time).to receive(:now) { clock }

      attempts = []
      allow(DRCMM).to receive(:get_telescope?) do
        attempts << clock.to_i
        false
      end

      ticks = 0
      allow(walker).to receive(:pause) do
        ticks += 1
        clock += 60
        raise StopIteration if ticks >= 5
      end

      walker.main_loop

      # Once at startup, then once more after the 205 second timer, with
      # empty hands throughout -- never every 10 second tick.
      expect(attempts).to eq([0, 240])
    end
  end

  describe '#determine_time' do
    def centered_targets(walker, times: 20)
      targets = []
      allow(walker).to receive(:center) { |target| targets << target }
      times.times { walker.determine_time }
      targets.uniq
    end

    it 'centers on the Elanthian sun by day' do
      allow(DRC).to receive(:bput).with('time', any_args).and_return('afternoon')
      walker = build_walker

      expect(centered_targets(walker)).to eq(['elanthian sun'])
    end

    it 'aligns to survival for the sun when use_partial_pools is on' do
      allow(DRC).to receive(:bput).with('time', any_args).and_return('morning')
      walker = build_walker(use_partial_pools: true)
      allow(walker).to receive(:center)

      walker.determine_time

      expect(walker.instance_variable_get(:@pool)).to eq('survival')
    end

    it 'picks a night constellation by circle, not the Wild Magic Heralds' do
      allow(DRC).to receive(:bput).with('time', any_args).and_return('night')
      DRStats.circle = 50
      walker = build_walker

      targets = centered_targets(walker, times: 50)

      expect(%w[toad raven spider ram magpie]).to include(*targets)
      expect(targets).not_to include('champions', 'elide', 'issendar', 'kirmhara')
    end

    it 'uses the Heart for a first circle Moon Mage at night, feeding survival' do
      allow(DRC).to receive(:bput).with('time', any_args).and_return('evening')
      DRStats.circle = 1
      walker = build_walker(use_partial_pools: true)

      expect(centered_targets(walker)).to eq(['heart'])
      expect(walker.instance_variable_get(:@pool)).to eq('survival')
    end
  end

  describe '#center' do
    it 'peers after centering, because center_telescope does not return the reply' do
      walker = build_walker
      expect(DRCMM).to receive(:center_telescope).with('heart').ordered.and_return(nil)
      expect(walker).to receive(:observe).ordered

      walker.center('heart')
    end
  end

  describe '#observe' do
    it 'stores the telescope and predicts when a pool is full' do
      walker = build_walker
      allow(DRCMM).to receive(:peer_telescope).and_return(
        ["You believe you've learned all that you can about survival.", 'Roundtime: 4 sec.']
      )
      expect(DRCMM).to receive(:store_telescope?).with('telescope', telescope_storage).ordered.and_return(true)
      expect(walker).to receive(:check_predict).ordered

      walker.observe
    end

    it 'finds the full-pool line anywhere in the multi-line result' do
      walker = build_walker
      allow(DRCMM).to receive(:peer_telescope).and_return(
        [
          'You peer through your telescope at the Heart.',
          'You learned something useful from your observation.',
          'Too many futures cloud your mind - you learn nothing.',
          'Roundtime: 4 sec.'
        ]
      )
      expect(walker).to receive(:check_predict)

      walker.observe
    end

    it 'does not predict from a partial pool unless use_partial_pools is on' do
      walker = build_walker
      allow(DRCMM).to receive(:peer_telescope).and_return(['You learned something useful from your observation.'])
      expect(walker).not_to receive(:check_predict)
      expect(DRCMM).to receive(:store_telescope?).and_return(true)

      walker.observe
    end

    it 'predicts from a partial pool when use_partial_pools is on' do
      walker = build_walker(use_partial_pools: true)
      allow(DRCMM).to receive(:peer_telescope).and_return(['You learned something useful from your observation.'])
      expect(walker).to receive(:check_predict)

      walker.observe
    end

    it 'stores the telescope without predicting after a failed observation' do
      walker = build_walker
      allow(DRCMM).to receive(:peer_telescope).and_return(['You have not pondered your last observation sufficiently.'])
      expect(walker).not_to receive(:check_predict)
      expect(DRCMM).to receive(:store_telescope?).and_return(true)

      walker.observe
    end

    it 'stores the telescope when peering timed out and returned no lines' do
      walker = build_walker
      allow(DRCMM).to receive(:peer_telescope).and_return([])
      expect(walker).not_to receive(:check_predict)
      expect(DRCMM).to receive(:store_telescope?).and_return(true)

      walker.observe
    end
  end

  describe '#check_predict' do
    before(:each) do
      DRSkill._set_xp('Astrology', 0)
      Flags['survival-full'] = true
    end

    it 'uses the divination tool when no bones are set up' do
      walker = build_walker(use_tools: true, divination_tool: mirror, divination_bones_storage: nil)
      expect(DRCMM).not_to receive(:roll_bones)
      expect(DRCMM).to receive(:use_div_tool).with(mirror)

      walker.check_predict
    end

    it 'rolls the bones when they are set up' do
      bones = { 'container' => 'bag' }
      walker = build_walker(use_tools: true, divination_tool: mirror, divination_bones_storage: bones)
      expect(DRCMM).to receive(:roll_bones).with(bones)
      expect(DRCMM).not_to receive(:use_div_tool)

      walker.check_predict
    end

    it 'predicts the future when use_tools is on but no tool is set up' do
      walker = build_walker(use_tools: true)
      expect(DRCMM).to receive(:predict).with('future')

      walker.check_predict
    end

    context 'with analyze_divination_tool on' do
      let(:settings) { OpenStruct.new(walkingastro: { 'analyze_divination_tool' => true }) }

      it 'analyzes the tool and puts it back' do
        walker = build_walker(settings: settings, use_tools: true, divination_tool: mirror)
        expect(DRCMM).to receive(:get_div_tool?).with(mirror).ordered.and_return(true)
        expect(DRC).to receive(:bput).with('analyze my mirror', 'Roundtime').ordered
        expect(DRCMM).to receive(:store_div_tool?).with(mirror).ordered.and_return(true)

        walker.check_predict
      end

      it 'skips the analysis when the tool cannot be fetched' do
        walker = build_walker(settings: settings, use_tools: true, divination_tool: mirror)
        allow(DRCMM).to receive(:get_div_tool?).and_return(false)
        expect(DRC).not_to receive(:bput).with('analyze my mirror', anything)
        expect(DRCMM).not_to receive(:store_div_tool?)

        walker.check_predict

        expect(DRC).to have_received(:message).with(/Couldn't get your mirror to analyze it/)
      end

      it 'says so when the tool will not go back' do
        walker = build_walker(settings: settings, use_tools: true, divination_tool: mirror)
        allow(DRCMM).to receive(:store_div_tool?).and_return(false)

        walker.check_predict

        expect(DRC).to have_received(:message).with(/Couldn't put your mirror away/)
      end
    end
  end
end
