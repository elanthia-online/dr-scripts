# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('buffother.lic', 'BuffOther')

RSpec.describe BuffOther do
  let(:friend_set) do
    {
      'Centering'      => { 'abbrev' => 'centering', 'mana' => 20 },
      'Manifest Force' => { 'abbrev' => 'maf', 'mana' => 20 }
    }
  end

  before(:each) do
    reset_data
    allow(DRC).to receive(:message)
    allow(DRCT).to receive(:walk_to).and_return(true)
    allow(DRCA).to receive(:cast_spell)
    DRRoom.pcs = ['Bobafett']
    DRStats.mana = 100
  end

  def run_buffother(set_name, sets, room: nil)
    $parsed_args = { 'recipient' => 'bobafett', 'waggle' => set_name, 'room' => room }
    $test_settings = OpenStruct.new(waggle_sets: sets, waggle_force_cambrinth: true)
    BuffOther.new
  end

  it 'casts each spell in the set at the recipient' do
    run_buffother('friend', { 'friend' => friend_set })
    expect(DRCA).to have_received(:cast_spell).twice
    expect(friend_set.values).to all(include('cast' => 'cast Bobafett', 'recast' => 99))
  end

  it 'walks to the room first when one is given' do
    run_buffother('friend', { 'friend' => friend_set }, room: '1234')
    expect(DRCT).to have_received(:walk_to).with('1234')
    expect(DRCA).to have_received(:cast_spell).twice
  end

  shared_examples 'a set buffother cannot cast' do |message|
    it 'says why and stops before walking or casting' do
      expect { run_buffother(set_name, sets, room: '1234') }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with(message)
      expect(DRCT).not_to have_received(:walk_to)
      expect(DRCA).not_to have_received(:cast_spell)
    end
  end

  context 'when there is no waggle set with that name' do
    let(:set_name) { 'missing' }
    let(:sets) { { 'friend' => friend_set } }

    include_examples 'a set buffother cannot cast', 'No waggle set found for name: missing'
  end

  context "when the set is a thief's khri list" do
    let(:set_name) { 'carve' }
    let(:sets) { { 'carve' => ['Hasten', 'delay Focus'] } }

    include_examples 'a set buffother cannot cast',
                     'Waggle set "carve" is a list of khri or abilities; buffother can only cast spells on someone else.'
  end

  context 'when the set has no spells' do
    let(:set_name) { 'empty' }
    let(:sets) { { 'empty' => {} } }

    include_examples 'a set buffother cannot cast', 'Waggle set "empty" has no spells to cast.'
  end

  context 'when the recipient is not in the room' do
    before(:each) do
      DRRoom.pcs = ['Hansolo']
    end

    it 'says so and stops without casting' do
      expect { run_buffother('friend', { 'friend' => friend_set }) }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('Bobafett not found in room. Exiting...')
      expect(DRCA).not_to have_received(:cast_spell)
    end
  end
end
