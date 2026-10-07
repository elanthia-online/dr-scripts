# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('buff-watcher.lic', 'BuffWatcher')

RSpec.describe BuffWatcher do
  let(:watcher) do
    described_class.allocate.tap { |w| w.instance_variable_set(:@buff_set_name, 'outdoors') }
  end
  let(:waggle_set) do
    {
      'Bless'      => { 'abbrev' => 'bless' },
      'Night Ward' => { 'abbrev' => 'nw', 'night' => true },
      'Day Ward'   => { 'abbrev' => 'dw', 'day' => true, 'recast' => 2 }
    }
  end

  before(:each) do
    DRStats.guild = 'Cleric'
    $test_settings = OpenStruct.new(waggle_sets: { 'outdoors' => waggle_set })
  end

  describe '#buffs_active?' do
    it 'does not count night spells as missing by day' do
      UserVars.sun = { 'day' => true, 'night' => false }
      DRSpells._set_active_spells({ 'Bless' => 10, 'Day Ward' => 10 })
      expect(watcher.buffs_active?).to be(true)
    end

    it 'does not count day spells as missing at night' do
      UserVars.sun = { 'day' => false, 'night' => true }
      DRSpells._set_active_spells({ 'Bless' => 10, 'Night Ward' => 10 })
      expect(watcher.buffs_active?).to be(true)
    end

    it 'reports an in-season spell that is down' do
      UserVars.sun = { 'day' => false, 'night' => true }
      DRSpells._set_active_spells({ 'Bless' => 10 })
      expect(watcher.buffs_active?).to be(false)
    end

    it 'still honours recast for in-season spells' do
      UserVars.sun = { 'day' => true, 'night' => false }
      DRSpells._set_active_spells({ 'Bless' => 10, 'Day Ward' => 2 })
      expect(watcher.buffs_active?).to be(false)
    end
  end
end
