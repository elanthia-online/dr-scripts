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

  describe '#sell_items' do
    # DRCI.get_item_list(source, 'look') returns LOOK IN's listing with the
    # articles stripped. When a container holds more than LOOK can show, the
    # game ends the listing with "and a lot of other stuff.", which arrives
    # here as a final 'lot of other stuff' entry.
    let(:sold) { [] }
    let(:script) do
      PawnItems.allocate.tap { |s| s.instance_variable_set(:@return_list, []) }
    end

    before do
      allow(DRC).to receive(:bput).and_return('You lower')
      allow(DRCI).to receive(:get_item?).and_return(true)
      allow(DRCT).to receive(:sell_item) { |room_id, item| sold << [room_id, item] }
    end

    def looks_return(*pages)
      allow(DRCI).to receive(:get_item_list).with('backpack', 'look').and_return(*pages)
    end

    context 'when LOOK cuts the listing short' do
      it 'looks again and sells what the next LOOK shows, at the same pawnshop' do
        looks_return(['steel nodachi', 'hefty battle axe', 'lot of other stuff'], ['thick book'])

        script.sell_items(4321, 'backpack', nil)

        expect(sold).to eq([[4321, 'nodachi'], [4321, 'axe'], [4321, 'book']])
        expect(DRCI).to have_received(:get_item_list).twice
      end

      it 'keeps looking through several cut-short listings until the container is empty' do
        looks_return(['steel nodachi', 'lot of other stuff'],
                     ['hefty battle axe', 'lot of other stuff'],
                     ['thick book'],
                     [])

        script.sell_items(4321, 'backpack', nil)

        expect(sold.map(&:last)).to eq(%w[nodachi axe book])
        expect(DRCI).to have_received(:get_item_list).exactly(3).times
      end

      it 'never tries to get or sell the "lot of other stuff" entry itself' do
        looks_return(['steel nodachi', 'lot of other stuff'], [])

        script.sell_items(4321, 'backpack', nil)

        expect(DRCI).not_to have_received(:get_item?).with(/other stuff/, anything)
        expect(sold.map(&:last)).to eq(['nodachi'])
      end

      it 'remembers items the merchant refuses on every pass so they can be put back' do
        looks_return(['steel nodachi', 'lot of other stuff'], ['thick book'])
        allow(DRCT).to receive(:sell_item).and_return(false)

        script.sell_items(4321, 'backpack', nil)

        expect(script.instance_variable_get(:@return_list)).to eq(%w[nodachi book])
        expect(DRC).to have_received(:bput).with('lower ground', 'You lower').twice
      end

      it 'still stops when an item on a later pass cannot be taken out' do
        looks_return(['steel nodachi', 'lot of other stuff'], ['thick book'])
        allow(DRCI).to receive(:get_item?).with('book', 'backpack').and_return(false)

        expect { script.sell_items(4321, 'backpack', nil) }.to raise_error(SystemExit)
        expect(messages).to include('Unable to get book from backpack.')
        expect(sold.map(&:last)).to eq(['nodachi'])
      end
    end

    context 'when LOOK lists nothing but "lot of other stuff"' do
      # Nothing was taken out, so another LOOK would show the same listing.
      it 'stops after one LOOK and says why instead of looking forever' do
        looks_return(['lot of other stuff'])

        expect { script.sell_items(4321, 'backpack', nil) }.not_to raise_error
        expect(DRCI).to have_received(:get_item_list).once
        expect(DRCI).not_to have_received(:get_item?)
        expect(messages).to include(a_string_matching(/shows no items to sell, only 'a lot of other stuff'/))
      end

      it 'stops when a later LOOK shows only "lot of other stuff"' do
        looks_return(['steel nodachi', 'lot of other stuff'], ['lot of other stuff'])

        script.sell_items(4321, 'backpack', nil)

        expect(sold.map(&:last)).to eq(['nodachi'])
        expect(DRCI).to have_received(:get_item_list).twice
      end
    end

    context 'when a noun is given' do
      it 'drops the "lot of other stuff" entry and looks only once' do
        looks_return(['steel nodachi', 'hefty battle axe', 'curved nodachi', 'lot of other stuff'])

        script.sell_items(4321, 'backpack', 'nodachi')

        expect(DRC).to have_received(:bput).with('sort nodachi in my backpack', any_args)
        expect(sold).to eq([[4321, 'nodachi'], [4321, 'nodachi']])
        expect(DRCI).to have_received(:get_item_list).once
        expect(messages.grep(/lot of other stuff/)).to be_empty
      end
    end

    context 'when LOOK shows everything' do
      it 'looks once and sells each item' do
        looks_return(['steel nodachi', 'thick book'])

        script.sell_items(4321, 'backpack', nil)

        expect(sold).to eq([[4321, 'nodachi'], [4321, 'book']])
        expect(DRCI).to have_received(:get_item_list).once
        expect(messages.grep(/lot of other stuff/)).to be_empty
      end

      it 'does nothing for an empty container' do
        looks_return([])

        script.sell_items(4321, 'backpack', nil)

        expect(sold).to be_empty
        expect(messages).to be_empty
      end
    end
  end
end
