# frozen_string_literal: true

require_relative 'spec_helper'

# use_almanac pauses other scripts, then gets the almanac. should_not_use_almanac?
# checks almanac_no_use_scripts before that, but a script can start between the
# check and the pause: taskmaster started remedy in that gap, remedy wasn't in
# the pause list, and the almanac took the hand remedy needed for its
# instructions ("Remedy: could not study the potion instructions. Stopping.").
RSpec.describe 'Almanac#use_almanac' do
  before(:all) { load_lic_class('almanac.lic', 'Almanac') }

  let(:almanac) do
    instance = Almanac.allocate
    instance.instance_variable_set(:@no_use_scripts, ['remedy', 'sew'])
    instance.instance_variable_set(:@almanac_skills, [])
    instance.instance_variable_set(:@almanac, 'almanac')
    instance.instance_variable_set(:@report_usage_details, false)
    instance
  end

  before do
    reset_data
    $running_scripts = []
    allow(almanac).to receive(:pause)
    allow(DRC).to receive(:safe_pause_list).and_return(['t2', 'taskmaster'])
    allow(DRC).to receive(:safe_unpause_list)
    allow(DRC).to receive(:bput) do |command, *_patterns|
      command.start_with?('study') ? "You believe you've learned something significant about Bow!" : 'You turn'
    end
    allow(DRCI).to receive(:get_item_if_not_held?).and_return(true)
    allow(DRCI).to receive(:in_hands?).and_return(true)
    allow(DRCI).to receive(:put_away_item?).and_return(true)
  end

  context 'when a no-use script starts after the check but before the pause' do
    before do
      allow(DRC).to receive(:safe_pause_list) do
        $running_scripts << 'remedy'
        ['t2', 'taskmaster']
      end
    end

    it 'does not get the almanac' do
      almanac.use_almanac

      expect(DRCI).not_to have_received(:get_item_if_not_held?)
      expect(DRC).not_to have_received(:bput)
    end

    it 'unpauses exactly the scripts it paused' do
      almanac.use_almanac

      expect(DRC).to have_received(:safe_unpause_list).with(['t2', 'taskmaster']).once
    end

    it 'leaves the use timer alone, so the next loop tries again' do
      UserVars.almanac_last_use = Time.at(0)

      almanac.use_almanac

      expect(UserVars.almanac_last_use).to eq(Time.at(0))
    end
  end

  context 'when no no-use script is running after the pause' do
    before { $running_scripts = ['t2', 'taskmaster', 'go2'] }

    it 'gets and studies the almanac, then unpauses' do
      almanac.use_almanac

      expect(DRCI).to have_received(:get_item_if_not_held?).with('almanac')
      expect(DRC).to have_received(:bput).with('study my almanac', any_args)
      expect(DRC).to have_received(:safe_unpause_list).with(['t2', 'taskmaster']).once
    end
  end
end
