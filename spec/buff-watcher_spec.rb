# frozen_string_literal: true

require 'spec_helper'

describe 'BuffWatcher' do
  before(:all) { load_lic_class('buff-watcher.lic', 'BuffWatcher') }

  let(:buff_watcher) { BuffWatcher.allocate }

  describe '#almanac?' do
    before do
      allow(Script).to receive(:running?).with('almanac').and_return(false)
      allow(DRC).to receive(:left_hand).and_return(nil)
      allow(DRC).to receive(:right_hand).and_return(nil)
    end

    it 'returns true when the almanac script is running' do
      allow(Script).to receive(:running?).with('almanac').and_return(true)
      expect(buff_watcher.almanac?).to be(true)
    end

    it 'returns true when holding an almanac in the left hand' do
      allow(DRC).to receive(:left_hand).and_return('omnibus almanac')
      expect(buff_watcher.almanac?).to be(true)
    end

    it 'returns true when holding an almanac in the right hand' do
      allow(DRC).to receive(:right_hand).and_return('weathered almanac')
      expect(buff_watcher.almanac?).to be(true)
    end

    it 'returns false when neither hand holds an almanac and script is not running' do
      allow(DRC).to receive(:left_hand).and_return('broadsword')
      allow(DRC).to receive(:right_hand).and_return('targe')
      expect(buff_watcher.almanac?).to be(false)
    end

    it 'returns false when hands are empty and script is not running' do
      expect(buff_watcher.almanac?).to be(false)
    end
  end

  describe '#should_activate_buffs?' do
    before do
      allow(buff_watcher).to receive(:hidden?).and_return(false)
      allow(buff_watcher).to receive(:invisible?).and_return(false)
      allow(buff_watcher).to receive(:running_no_use_scripts?).and_return(false)
      allow(buff_watcher).to receive(:inside_no_use_room?).and_return(false)
      allow(buff_watcher).to receive(:need_inner_fire?).and_return(false)
      allow(buff_watcher).to receive(:buffs_active?).and_return(false)
      allow(buff_watcher).to receive(:almanac?).and_return(false)
      allow(DRStats).to receive(:guild).and_return('Warrior Mage')
    end

    it 'returns true when all conditions pass and no almanac is in use' do
      expect(buff_watcher.should_activate_buffs?).to be(true)
    end

    it 'returns false when almanac? is true' do
      allow(buff_watcher).to receive(:almanac?).and_return(true)
      expect(buff_watcher.should_activate_buffs?).to be(false)
    end

    it 'returns false when buffs are already active' do
      allow(buff_watcher).to receive(:buffs_active?).and_return(true)
      expect(buff_watcher.should_activate_buffs?).to be(false)
    end

    it 'returns false when character is hidden' do
      allow(buff_watcher).to receive(:hidden?).and_return(true)
      expect(buff_watcher.should_activate_buffs?).to be(false)
    end
  end
end
