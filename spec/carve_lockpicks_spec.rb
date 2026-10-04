# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('carve-lockpicks.lic', 'CarveLockpicks')

RSpec.describe CarveLockpicks do
  let(:lockpick_carve_settings) do
    {
      'grand_container'  => 'carryall',
      'master_container' => 'toolkit'
    }
  end

  # Build an instance without running initialize (which parses args and starts carving).
  def build_carver(waggle_sets: {})
    carver = described_class.allocate
    carver.instance_variable_set(:@settings, OpenStruct.new(waggle_sets: waggle_sets))
    carver.instance_variable_set(:@lockpick_carve_settings, lockpick_carve_settings)
    allow(carver).to receive(:sleep)
    carver
  end

  describe '#purchase_rings' do
    let(:carver) { build_carver }
    let(:bought) { [] }
    let(:stored) { [] }

    before(:each) do
      # Masters are the first ring on the shop list, grandmasters the second.
      allow(DRC).to receive(:bput) do |command, *_patterns|
        command.start_with?('shop first') ? 'Cost: 100 Kronars' : 'Cost: 300 Kronars'
      end
      allow(DRCM).to receive(:check_wealth).with('Kronars').and_return(100_000)
      allow(DRCT).to receive(:buy_item) { |_room, item| bought << item }
      allow(DRCI).to receive(:put_away_item?) do |item, container|
        stored << [item, container]
        true
      end
    end

    context 'with a recorded 40% grandmaster ratio and 5 pockets' do
      # 5 pockets -> 10 rings: 4 grand + 6 master, plus a spare each ([n / 5, 1].max) -> 5 and 7.
      before(:each) { UserVars.grands_ratio = { Time.at(0) => 40 } }

      it 'buys @grings grandmaster rings into the grand container, then @mrings master rings into the master container' do
        expect { carver.purchase_rings(5, 'first', 'second') }.to raise_error(SystemExit)

        expect(bought).to eq(['second lockpick ring'] * 5 + ['first lockpick ring'] * 7)
        expect(stored).to eq([['lockpick ring', 'carryall']] * 5 + [['lockpick ring', 'toolkit']] * 7)
      end

      it 'prices each ordinal by its own ring count before buying' do
        allow(DRCM).to receive(:check_wealth).with('Kronars').and_return(500)

        # 7 masters at 100 + 5 grandmasters at 300 = 2200; swapping the counts would give 2600.
        expect(DRCM).to receive(:minimize_coins).with(2200).ordered
        expect(DRCM).to receive(:minimize_coins).with(1700).ordered

        expect { carver.purchase_rings(5, 'first', 'second') }.to raise_error(SystemExit)
        expect(bought).to be_empty
      end
    end

    context 'with no recorded runs' do
      before(:each) { UserVars.grands_ratio = {} }

      it 'splits evenly, buying one more ring of each kind than there are pockets' do
        expect { carver.purchase_rings(2, 'first', 'second') }.to raise_error(SystemExit)

        expect(bought).to eq(['second lockpick ring'] * 3 + ['first lockpick ring'] * 3)
      end
    end

    context 'when a bought ring cannot be put away' do
      before(:each) { UserVars.grands_ratio = {} }

      it 'stops buying instead of piling paid-for rings in your hands' do
        allow(DRCI).to receive(:put_away_item?).and_return(false)
        messages = []
        allow(DRC).to receive(:message) { |text| messages << text }

        expect { carver.purchase_rings(2, 'first', 'second') }.to raise_error(SystemExit)

        expect(bought).to eq(['second lockpick ring'])
        expect(messages.last).to match(/Couldn't put a lockpick ring in your carryall/)
      end
    end
  end

  describe '#check_status' do
    before(:each) { $sitting = true }

    context "with a Thief's khri list (Array)" do
      let(:carver) { build_carver(waggle_sets: { 'carve' => ['Khri Delay Focus', 'Sagacity'] }) }

      it 'skips buff when every khri is active' do
        DRSpells._set_active_spells('Khri Focus' => 10, 'Khri Sagacity' => 10)

        expect(DRC).not_to receive(:wait_for_script_to_complete)
        carver.check_status
      end

      it 'runs buff when a khri has dropped' do
        DRSpells._set_active_spells('Khri Focus' => 10)

        expect(DRC).to receive(:wait_for_script_to_complete).with('buff', ['carve'])
        carver.check_status
      end
    end

    context 'with a spell set (Hash of spell name to data)' do
      let(:carver) do
        build_carver(waggle_sets: {
          'carve' => {
            'Manifest Force' => { 'abbrev' => 'maf', 'recast' => 2 },
            'Ease Burden'    => { 'abbrev' => 'ease' }
          }
        })
      end

      it 'skips buff when every spell is active above its recast threshold' do
        DRSpells._set_active_spells('Manifest Force' => 10, 'Ease Burden' => 10)

        expect(DRC).not_to receive(:wait_for_script_to_complete)
        carver.check_status
      end

      it 'runs buff when a spell has dropped' do
        DRSpells._set_active_spells('Manifest Force' => 10)

        expect(DRC).to receive(:wait_for_script_to_complete).with('buff', ['carve'])
        carver.check_status
      end

      it 'runs buff when a spell is down to its recast threshold' do
        DRSpells._set_active_spells('Manifest Force' => 2, 'Ease Burden' => 10)

        expect(DRC).to receive(:wait_for_script_to_complete).with('buff', ['carve'])
        carver.check_status
      end
    end

    context 'with night-only and day-only spells in the set' do
      let(:carver) do
        build_carver(waggle_sets: {
          'carve' => {
            'Ease Burden' => { 'abbrev' => 'ease' },
            'Shadows'     => { 'abbrev' => 'shadows', 'night' => true },
            'Sun Spell'   => { 'abbrev' => 'sun', 'day' => true }
          }
        })
      end

      it 'ignores the night-only spell during the day, since buff would not cast it' do
        UserVars.sun = { 'day' => true, 'night' => false }
        DRSpells._set_active_spells('Ease Burden' => 10, 'Sun Spell' => 10)

        expect(DRC).not_to receive(:wait_for_script_to_complete)
        3.times { carver.check_status }
      end

      it 'ignores the day-only spell at night, since buff would not cast it' do
        UserVars.sun = { 'day' => false, 'night' => true }
        DRSpells._set_active_spells('Ease Burden' => 10, 'Shadows' => 10)

        expect(DRC).not_to receive(:wait_for_script_to_complete)
        carver.check_status
      end

      it 'runs buff when the in-season spell has dropped' do
        UserVars.sun = { 'day' => false, 'night' => true }
        DRSpells._set_active_spells('Ease Burden' => 10)

        expect(DRC).to receive(:wait_for_script_to_complete).with('buff', ['carve'])
        carver.check_status
      end
    end

    context "with a Barbarian's ability list (Array)" do
      let(:carver) { build_carver(waggle_sets: { 'carve' => %w[Bear Focus] }) }

      before(:each) { DRStats.guild = 'Barbarian' }

      it 'skips buff when every ability is active, checked by its own name rather than as a khri' do
        DRSpells._set_active_spells('Bear' => 10, 'Focus' => 10)

        expect(DRC).not_to receive(:wait_for_script_to_complete)
        3.times { carver.check_status }
      end

      it 'runs buff when an ability has dropped' do
        DRSpells._set_active_spells('Bear' => 10)

        expect(DRC).to receive(:wait_for_script_to_complete).with('buff', ['carve'])
        carver.check_status
      end
    end

    context 'with no carve set' do
      let(:carver) { build_carver(waggle_sets: {}) }

      # Pins the else branch. Under Lich the old code also skipped buff here: the NilClass patch
      # turned nil.join(' ').split(' ') into [], which the harness doesn't load.
      it 'does not buff' do
        expect(DRC).not_to receive(:wait_for_script_to_complete)
        carver.check_status
      end
    end
  end

  describe '#stow_lockpick when the grand container has no empty rings left' do
    let(:carver) do
      carver = build_carver
      carver.instance_variable_set(:@grand_batch, true)
      carver.instance_variable_set(:@grands_ring_ready, 0)
      carver
    end
    let(:messages) { [] }

    before(:each) do
      # PUT only works on a held item; with empty hands the game answers "What were you referring to?".
      holding_pick = true
      allow(DRCI).to receive(:put_away_item?) do |item, _container|
        next false unless item == 'lockpick' && holding_pick

        holding_pick = false
        true
      end
      allow(DRCI).to receive(:get_item?).with('lockpick ring', 'carryall').and_return(false)
      allow(DRC).to receive(:message) { |text| messages << text }
    end

    context 'with carve_past_ring_capacity: true' do
      let(:lockpick_carve_settings) do
        { 'grand_container' => 'carryall', 'master_container' => 'toolkit', 'carve_past_ring_capacity' => true }
      end

      it 'stops ringing grandmasters and picks the knife back up to keep carving' do
        expect(DRCC).to receive(:get_crafting_item).with('carving knife', anything, anything, anything)

        # Wrapped so a regression fails this example instead of exiting the whole run
        expect { carver.stow_lockpick('carryall') }.not_to raise_error

        expect(messages).to eq(['Out of empty rings for grand picks'])
        expect(carver.instance_variable_get(:@grand_batch)).to be(false)
        expect(carver.instance_variable_get(:@grands_ring_ready)).to eq(25)
      end
    end

    context 'with carve_past_ring_capacity: false' do
      let(:lockpick_carve_settings) do
        { 'grand_container' => 'carryall', 'master_container' => 'toolkit', 'carve_past_ring_capacity' => false }
      end

      it 'exits saying it is out of rings, not that the bag is full' do
        expect { carver.stow_lockpick('carryall') }.to raise_error(SystemExit)

        expect(messages).to eq(['Out of empty rings for grand picks'])
      end
    end
  end

  describe '#calc_ratio' do
    let(:carver) { build_carver }

    it 'returns nil instead of dividing by zero when no runs are recorded' do
      UserVars.grands_ratio = {}

      expect(carver.calc_ratio).to be_nil
    end

    it 'averages the recorded grandmaster percentages' do
      UserVars.grands_ratio = { Time.at(0) => 40, Time.at(60) => 60 }

      expect(carver.calc_ratio).to eq(50)
    end
  end

  describe 'ratio arguments' do
    let(:messages) { [] }

    before(:each) do
      $test_settings = OpenStruct.new(lockpick_carve_settings: lockpick_carve_settings, waggle_sets: {})
      allow(DRC).to receive(:message) { |text| messages << text }
    end

    %w[ratio_last ratio_all].each do |arg|
      it "#{arg} says no runs are recorded yet when there is no history" do
        $parsed_args = OpenStruct.new(arg => arg)

        expect { described_class.new }.to raise_error(SystemExit)
        expect(messages).to eq(['No carving runs recorded yet'])
      end
    end

    it 'ratio_last shows the most recent run' do
      UserVars.grands_ratio = { Time.at(0) => 40, Time.at(60) => 55 }
      $parsed_args = OpenStruct.new(ratio_last: 'ratio_last')

      expect { described_class.new }.to raise_error(SystemExit)
      expect(messages).to eq(["Most recent percentage of Grandmaster's to Master's picks: 55"])
    end

    it 'ratio_all shows the average of all runs' do
      UserVars.grands_ratio = { Time.at(0) => 40, Time.at(60) => 60 }
      $parsed_args = OpenStruct.new(ratio_all: 'ratio_all')

      expect { described_class.new }.to raise_error(SystemExit)
      expect(messages).to eq(["Average of all recorded carving projects to date, Grandmaster's percentages: 50"])
    end
  end
end
