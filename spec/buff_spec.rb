# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('buff.lic', 'Waggle')

RSpec.describe Waggle do
  let(:waggle_set) do
    {
      'Bless'      => { 'abbrev' => 'bless' },
      'Night Ward' => { 'abbrev' => 'nw', 'night' => true },
      'Day Ward'   => { 'abbrev' => 'dw', 'day' => true }
    }
  end
  let(:night) { { 'day' => false, 'night' => true } }
  let(:day) { { 'day' => true, 'night' => false } }
  let(:do_buffs_calls) { [] }

  # Stands in for a DRCA.do_buffs that skips out-of-season spells and leaves
  # settings alone, as lich-5 does once #1679 is fixed. Raises instead of
  # spinning when strict mode would loop forever.
  def cast_in_season_spells
    allow(DRCA).to receive(:do_buffs) do |settings, setname|
      do_buffs_calls << setname
      raise 'strict mode is looping forever' if do_buffs_calls.size > 5

      in_season = settings.waggle_sets[setname].reject do |_name, data|
        (data['night'] && !UserVars.sun['night']) || (data['day'] && !UserVars.sun['day'])
      end
      DRSpells._set_active_spells(DRSpells.active_spells.merge(in_season.keys.to_h { |name| [name, 10] }))
    end
  end

  def run_strict
    $parsed_args = { 'strict' => true, 'spells' => 'outdoors' }
    $test_settings = OpenStruct.new(waggle_sets: { 'outdoors' => waggle_set })
    Waggle.new
  end

  before(:each) do
    DRStats.guild = 'Cleric'
    DRSpells._set_active_spells({})
    cast_in_season_spells
  end

  describe 'strict mode' do
    it 'stops once the in-season spells are up at night' do
      UserVars.sun = night
      run_strict
      expect(do_buffs_calls.size).to eq(1)
      expect(DRSpells.active_spells.keys).to contain_exactly('Bless', 'Night Ward')
    end

    it 'stops once the in-season spells are up by day' do
      UserVars.sun = day
      run_strict
      expect(do_buffs_calls.size).to eq(1)
      expect(DRSpells.active_spells.keys).to contain_exactly('Bless', 'Day Ward')
    end

    it 'keeps casting until every in-season spell is up' do
      UserVars.sun = night
      DRSpells._set_active_spells({ 'Day Ward' => 10 })
      run_strict
      expect(do_buffs_calls.size).to eq(1)
    end
  end

  describe 'strict mode with the do_buffs in lich-5 before #1679' do
    # That do_buffs casts day: spells at night and deletes night: spells
    # from the settings by day.
    before(:each) do
      allow(DRCA).to receive(:do_buffs) do |settings, setname|
        do_buffs_calls << setname
        raise 'strict mode is looping forever' if do_buffs_calls.size > 5

        spells = settings.waggle_sets[setname]
        spells.reject! { |_name, data| data['night'] } unless UserVars.sun['night']
        DRSpells._set_active_spells(DRSpells.active_spells.merge(spells.keys.to_h { |name| [name, 10] }))
      end
    end

    it 'still stops at night and by day' do
      [night, day].each do |sun|
        UserVars.sun = sun
        DRSpells._set_active_spells({})
        do_buffs_calls.clear
        run_strict
        expect(do_buffs_calls.size).to eq(1)
      end
    end
  end

  describe '#spells_to_wait_on' do
    let(:waggle) { described_class.allocate }

    it 'drops night spells by day and day spells at night' do
      UserVars.sun = day
      expect(waggle.spells_to_wait_on(waggle_set)).to eq(['Bless', 'Day Ward'])
      UserVars.sun = night
      expect(waggle.spells_to_wait_on(waggle_set)).to eq(['Bless', 'Night Ward'])
    end

    it 'leaves the waggle set untouched' do
      UserVars.sun = day
      waggle_set.freeze
      waggle.spells_to_wait_on(waggle_set)
      expect(waggle_set.keys).to eq(['Bless', 'Night Ward', 'Day Ward'])
    end

    it 'waits on every entry for barbarians and thieves, whom do_buffs does not filter' do
      UserVars.sun = day
      DRStats.guild = 'Barbarian'
      expect(waggle.spells_to_wait_on(waggle_set)).to eq(['Bless', 'Night Ward', 'Day Ward'])
      DRStats.guild = 'Thief'
      expect(waggle.spells_to_wait_on(waggle_set)).to eq(['Bless', 'Night Ward', 'Day Ward'])
    end
  end
end
