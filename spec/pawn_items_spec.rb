# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('pawn-items.lic', 'PawnItems')

RSpec.describe PawnItems do
  let(:messages) { [] }
  let(:settings) { OpenStruct.new(hometown: 'Crossing', sell_loot_town: nil) }
  let(:args) { OpenStruct.new(source: 'backpack', town: nil, noun: nil) }

  before do
    allow(DRC).to receive(:message) { |text| messages << text }
    allow(DRC).to receive(:get_town_name) { |town| town }
  end

  # Run the script's initialize on a bare instance with the item-moving steps
  # stubbed out, so each example sees only which pawnshop was picked (or that
  # the script stopped before touching anything).
  def run_script
    script = PawnItems.allocate
    allow(script).to receive(:parse_args).and_return(args)
    allow(script).to receive(:get_settings).and_return(settings)
    allow(script).to receive(:warn_before_sell)
    allow(script).to receive(:sell_items)
    script.send(:initialize)
    script
  end

  def room(id)
    double('room', id: id)
  end

  describe 'when Lich has not worked out the current room' do
    # In game Room.current is nil here. Under Lich's NilClass patch, nil.id
    # returns nil instead of raising, so the script must treat both a nil room
    # and a nil id as "room unknown".
    shared_examples 'stops before touching any items' do
      it 'stops with a message saying the room is unknown' do
        expect { run_script }.to raise_error(SystemExit)
        expect(messages).to include(a_string_matching(/doesn't know which room you're in/))
      end

      it 'does not claim the town has no pawnshop' do
        expect { run_script }.to raise_error(SystemExit)
        expect(messages.grep(/Pawning not supported/)).to be_empty
      end

      it 'never warns, releases invisibility or sells' do
        script = PawnItems.allocate
        allow(script).to receive(:parse_args).and_return(args)
        allow(script).to receive(:get_settings).and_return(settings)
        expect(script).not_to receive(:warn_before_sell)
        expect(script).not_to receive(:sell_items)
        expect(DRC).not_to receive(:release_invisibility)
        expect { script.send(:initialize) }.to raise_error(SystemExit)
      end

      it 'does not fall back to walking to the hometown pawnshop' do
        expect(DRCT).not_to receive(:get_hometown_target_id)
        expect { run_script }.to raise_error(SystemExit)
      end

      it 'stops even when a town is given on the command line' do
        args.town = 'Riverhaven'
        expect(DRCT).not_to receive(:get_hometown_target_id)
        expect { run_script }.to raise_error(SystemExit)
      end
    end

    context 'with Room.current nil' do
      before do
        allow(Room).to receive(:current).and_return(nil)
        allow(DRCT).to receive(:tag_to_id).with('pawnshop').and_return(nil)
      end

      include_examples 'stops before touching any items'
    end

    context 'with Room.current.id returning nil (as nil.id does under the NilClass patch)' do
      # Lich never builds a room object with a nil id; this double stands in
      # for nil.id returning nil once the NilClass patch is loaded.
      before do
        allow(Room).to receive(:current).and_return(room(nil))
        allow(DRCT).to receive(:tag_to_id).with('pawnshop').and_return(nil)
      end

      include_examples 'stops before touching any items'
    end

    context 'when the room becomes unknown after the pawnshop lookup returned an id' do
      # DRCT.tag_to_id returns nil when the room is unknown, so this needs a
      # narrow race: the room was known for the lookup and is unknown by the
      # time the script reads Room.current. The current room must decide.
      before do
        allow(Room).to receive(:current).and_return(nil)
        allow(DRCT).to receive(:tag_to_id).with('pawnshop').and_return(4321)
        # A hometown pawnshop exists, so main's fallback would walk there and
        # sell instead of stopping on "Pawning not supported".
        allow(DRCT).to receive(:get_hometown_target_id).and_return(8888)
      end

      include_examples 'stops before touching any items'
    end
  end

  describe 'when standing in the nearest pawnshop' do
    before do
      allow(Room).to receive(:current).and_return(room(4321))
      allow(DRCT).to receive(:tag_to_id).with('pawnshop').and_return(4321)
    end

    it 'sells right here without looking up the hometown pawnshop' do
      expect(DRCT).not_to receive(:get_hometown_target_id)
      script = run_script
      expect(script).to have_received(:sell_items).with(4321, 'backpack', nil)
    end
  end

  describe 'when somewhere else Lich knows' do
    before do
      allow(Room).to receive(:current).and_return(room(1000))
    end

    it 'sells in the hometown pawnshop when the nearest pawnshop is elsewhere' do
      allow(DRCT).to receive(:tag_to_id).with('pawnshop').and_return(4321)
      allow(DRCT).to receive(:get_hometown_target_id).with('Crossing', 'pawnshop').and_return(8888)
      script = run_script
      expect(script).to have_received(:sell_items).with(8888, 'backpack', nil)
    end

    it 'sells in the hometown pawnshop when no pawnshop can be found from here' do
      allow(DRCT).to receive(:tag_to_id).with('pawnshop').and_return(nil)
      allow(DRCT).to receive(:get_hometown_target_id).with('Crossing', 'pawnshop').and_return(8888)
      script = run_script
      expect(script).to have_received(:sell_items).with(8888, 'backpack', nil)
    end

    it 'prefers the town argument over sell_loot_town and hometown' do
      args.town = 'Riverhaven'
      settings.sell_loot_town = 'Shard'
      allow(DRCT).to receive(:tag_to_id).with('pawnshop').and_return(nil)
      expect(DRCT).to receive(:get_hometown_target_id).with('Riverhaven', 'pawnshop').and_return(7777)
      run_script
    end

    it 'prefers sell_loot_town over hometown' do
      settings.sell_loot_town = 'Shard'
      allow(DRCT).to receive(:tag_to_id).with('pawnshop').and_return(nil)
      expect(DRCT).to receive(:get_hometown_target_id).with('Shard', 'pawnshop').and_return(7777)
      run_script
    end

    it 'stops and names the town when it has no pawnshop' do
      allow(DRCT).to receive(:tag_to_id).with('pawnshop').and_return(nil)
      allow(DRCT).to receive(:get_hometown_target_id).with('Crossing', 'pawnshop').and_return(nil)
      expect { run_script }.to raise_error(SystemExit)
      expect(messages).to include('Pawning not supported in Crossing.')
    end
  end
end
