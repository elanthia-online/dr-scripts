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
      # The first cast of Night Ward fizzles; the second sticks.
      allow(DRCA).to receive(:do_buffs) do |_settings, setname|
        do_buffs_calls << setname
        raise 'strict mode is looping forever' if do_buffs_calls.size > 5

        cast = do_buffs_calls.size == 1 ? ['Bless'] : ['Bless', 'Night Ward']
        DRSpells._set_active_spells(DRSpells.active_spells.merge(cast.to_h { |name| [name, 10] }))
      end
      run_strict
      expect(do_buffs_calls.size).to eq(2)
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

    it 'waits on every barbarian ability in the list' do
      DRStats.guild = 'Barbarian'
      expect(waggle.spells_to_wait_on(['Famine', 'Avalanche'])).to eq(['Famine', 'Avalanche'])
    end

    it 'waits on each khri by its active-spell name, ignoring Khri and Delay prefixes' do
      DRStats.guild = 'Thief'
      sets = ['delay Strike Elusion', 'Khri Sight', 'khri delay hasten focus', 'safe']
      expect(waggle.spells_to_wait_on(sets))
        .to eq(['Khri Strike', 'Khri Elusion', 'Khri Sight', 'Khri Hasten', 'Khri Focus', 'Khri Safe'])
    end

    it 'skips a blank thief entry' do
      DRStats.guild = 'Thief'
      expect(waggle.spells_to_wait_on(['', 'Sight'])).to eq(['Khri Sight'])
    end
  end

  describe 'strict mode for list-based guilds' do
    def run_strict_with(set, now_active)
      allow(DRCA).to receive(:do_buffs) do |_settings, setname|
        do_buffs_calls << setname
        raise 'strict mode is looping forever' if do_buffs_calls.size > 5

        DRSpells._set_active_spells(now_active)
      end
      $parsed_args = { 'strict' => true, 'spells' => 'default' }
      $test_settings = OpenStruct.new(waggle_sets: { 'default' => set })
      Waggle.new
    end

    it 'stops once every barbarian ability is up' do
      DRStats.guild = 'Barbarian'
      run_strict_with(['Famine', 'Avalanche'], { 'Famine' => 10, 'Avalanche' => 10 })
      expect(do_buffs_calls.size).to eq(1)
    end

    it 'stops once every khri is up' do
      DRStats.guild = 'Thief'
      run_strict_with(['delay Strike Elusion'], { 'Khri Strike' => 10, 'Khri Elusion' => 10 })
      expect(do_buffs_calls.size).to eq(1)
    end
  end
end
