# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')

RSpec.describe TaskMaster do
  describe 'lumber repair' do
    # A bare instance: initialize runs the whole script, so each example injects
    # only the state the method under test reads.
    def build(settings)
      tm = described_class.allocate
      tm.instance_variable_set(:@settings, OpenStruct.new(settings))
      tm.instance_variable_set(:@bag, 'duffel bag')
      tm.instance_variable_set(:@bag_items, [])
      tm.instance_variable_set(:@no_repair, false)
      tm.instance_variable_set(:@self_repair, false)
      tm
    end

    describe '#bradyn lumber tasks' do
      # Runs the real lumber branch down to the Rangu hand-off and reports which
      # tools were fetched for repair. Buying, shaping and disposal are not under
      # test, so they are stubbed out on the instance.
      def tools_sent_for_repair(settings)
        tm = build(settings)
        allow(tm).to receive(:buy_stackables)
        allow(tm).to receive(:shape_item)
        allow(tm).to receive(:trash)
        fetched = []
        allow(DRCT).to receive(:walk_to)
        allow(DRCC).to receive(:get_crafting_item) { |tool, *_rest| fetched << tool }
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRC).to receive(:bput).and_return("There isn't a scratch on that")

        tm.bradyn('bowl', 2, 5, 'lumber', 'balsa')
        fetched
      end

      it 'repairs the shaping_tools that base.yaml defines' do
        tools = tools_sent_for_repair(shaping_tools: %w[shaper drawknife], engineering_belt: nil)
        expect(tools).to eq(%w[shaper drawknife])
      end

      it 'falls back to the older engineering_tools key when shaping_tools is unset' do
        tools = tools_sent_for_repair(engineering_tools: ['rasp'], engineering_belt: nil)
        expect(tools).to eq(['rasp'])
      end

      it 'prefers shaping_tools when both keys are set' do
        tools = tools_sent_for_repair(shaping_tools: ['shaper'], engineering_tools: ['rasp'], engineering_belt: nil)
        expect(tools).to eq(['shaper'])
      end

      it 'repairs nothing, without raising, when neither key is set' do
        expect(tools_sent_for_repair(engineering_belt: nil)).to eq([])
      end
    end
  end

  describe 'thread restock' do
    describe '#restock (marathon)' do
      # Stock prices and order numbers mirroring data/base-crafting.yaml.
      let(:stockdata) do
        { 'burlap' => { 'stock-value' => 437, 'stock-number' => 8 }, 'rat' => { 'stock-value' => 750, 'stock-number' => 2 },
          'yarn' => { 'stock-value' => 625, 'stock-number' => 13 }, 'thread' => { 'stock-value' => 971, 'stock-number' => 6 } }
      end

      # Runs the real restock with the script's own stack map and an empty bag,
      # recording every order placed.
      def restock_orders
        tm = described_class.allocate
        tm.instance_variable_set(:@settings, OpenStruct.new)
        tm.instance_variable_set(:@bag, 'duffel bag')
        tm.instance_variable_set(:@bag_items, [])
        tm.instance_variable_set(:@stockdata, stockdata)
        tm.instance_variable_set(:@stackmap, described_class::STACKMAP)
        allow(tm).to receive(:get_data).and_return({ 'tailoring' => { 'Crossing' => { 'tool-room' => 16667 } } })
        allow(tm).to receive(:exchange_coins)
        allow(DRCC).to receive(:check_consumables)
        allow(DRCI).to receive(:exists?).and_return(false)
        allow(DRCT).to receive(:walk_to)
        orders = []
        allow(DRCT).to receive(:order_item) { |room, number| orders << [room, number] }
        allow(DRC).to receive(:bput).and_return('You combine')
        allow(DRCC).to receive(:stow_crafting_item)
        tm.restock
        orders
      end

      it 'restocks thread without tripping over a missing stack map entry' do
        expect { restock_orders }.not_to raise_error
      end

      it 'orders four spools of cotton thread from the tailoring supply room when none is carried' do
        expect(restock_orders.count([16667, 6])).to eq(4)
      end

      it 'still orders cloth, leather and yarn' do
        orders = restock_orders
        expect(orders.count([16667, 8])).to eq(10)
        expect(orders.count([16667, 2])).to eq(10)
        expect(orders.count([16667, 13])).to eq(4)
      end
    end
  end

  describe 'sewing consumables' do
    describe '#tailor_item' do
      let(:tailoring) { { 'tailoring' => { 'Crossing' => { 'tool-room' => 16666, 'stock-room' => 16667 } } } }

      # Runs the real tailor_item and records consumable checks and sew launches.
      def tailor(base, count: 6, marathon: false)
        tm = described_class.allocate
        tm.instance_variable_set(:@settings, OpenStruct.new(outfitting_belt: { 'name' => 'toolbelt', 'items' => [] }))
        tm.instance_variable_set(:@bag, 'duffel bag')
        tm.instance_variable_set(:@bag_items, [])
        tm.instance_variable_set(:@crafting_room, 16_936)
        tm.instance_variable_set(:@marathon, marathon)
        allow(tm).to receive(:get_data).and_return(tailoring)
        allow(DRCT).to receive(:walk_to)
        allow(DRC).to receive(:message)
        checks = []
        allow(DRCC).to receive(:check_consumables) { |name, room, number, *rest| checks << [name, room, number, rest.last] }
        launches = []
        allow(DRC).to receive(:wait_for_script_to_complete) { |name, args| launches << [name, args] }
        tm.tailor_item('netting', count, base, 'burlap')
        [checks, launches]
      end

      it 'checks pins once for the whole task, enough for every item' do
        checks, = tailor('cloth', count: 8)
        expect(checks.count { |c| c.first == 'pins' }).to eq(1)
        expect(checks.find { |c| c.first == 'pins' }).to eq(['pins', 16666, 5, 29])
      end

      it 'checks thread once, from the stock room' do
        checks, = tailor('leather')
        expect(checks.select { |c| c.first == 'thread' }.map { |c| c[1..2] }).to eq([[16667, 6]])
      end

      it 'tells every sew run to skip its own consumable check' do
        _, launches = tailor('cloth', count: 3)
        expect(launches.size).to eq(3)
        expect(launches).to all(satisfy { |name, args| name == 'sew' && args.include?('skip') })
      end

      it 'skips pins and thread entirely for knitting' do
        checks, launches = tailor('yarn')
        expect(checks).to be_empty
        expect(launches.first.last).to include('knit', 'skip')
      end

      it 'behaves the same in marathon mode' do
        checks, launches = tailor('cloth', count: 2, marathon: true)
        expect(checks.map(&:first)).to eq(%w[pins thread])
        expect(launches).to all(satisfy { |_, args| args.include?('skip') })
      end
    end
  end

  describe 'npc search' do
    # Zasele's search rooms, in the script's order.
    let(:rooms) { [16_145, 16_146, 16_148, 16_150, 16_153, 16_154, 16_147, 16_276, 16_277, 16_278, 16_290] }

    describe '#search_order' do
      let(:tm) { described_class.allocate }

      it 'keeps the list as it is with no last-seen room' do
        expect(tm.search_order(rooms, nil)).to eq(rooms)
      end

      it 'keeps the list as it is when the last-seen room is not one of the search rooms' do
        expect(tm.search_order(rooms, 12_345)).to eq(rooms)
      end

      it 'starts at the last-seen room and alternates outwards' do
        expect(tm.search_order(rooms, 16_150).first(5)).to eq([16_150, 16_153, 16_148, 16_154, 16_146])
      end

      it 'visits every room exactly once from any starting point' do
        rooms.each do |start|
          expect(tm.search_order(rooms, start)).to match_array(rooms)
        end
      end

      it 'handles the ends of the list' do
        expect(tm.search_order(rooms, rooms.last).first(3)).to eq([16_290, 16_278, 16_277])
        expect(tm.search_order(rooms, rooms.first).first(3)).to eq([16_145, 16_146, 16_148])
      end
    end

    describe '#find_npc' do
      # A small world: walking changes the current room, and Zasele is listed
      # among the NPCs only in her room. Returns the rooms walked to.
      def search(zasele_in:, start_in:)
        tm = described_class.allocate
        here = start_in
        walked = []
        allow(Room).to receive(:current) { OpenStruct.new(id: here) }
        allow(DRRoom).to receive(:npcs) { here == zasele_in ? ['Zasele'] : [] }
        allow(DRCT).to receive(:walk_to) do |room|
          walked << room
          here = room
        end
        tm.find_npc(rooms, 'zasele')
        walked
      end

      it 'remembers where the taskmaster was found' do
        search(zasele_in: 16_276, start_in: 16_936)
        expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_276)
      end

      it 'goes straight back to the last-seen room when she is still there' do
        UserVars.taskmaster_last_seen = { 'zasele' => 16_276 }
        expect(search(zasele_in: 16_276, start_in: 16_936)).to eq([16_276])
      end

      it 'finds her a room or two away from where she was last seen' do
        UserVars.taskmaster_last_seen = { 'zasele' => 16_276 }
        expect(search(zasele_in: 16_154, start_in: 16_936)).to eq([16_276, 16_277, 16_147, 16_278, 16_154])
      end

      it 'searches the whole list in its own order the first time' do
        expect(search(zasele_in: 16_150, start_in: 16_936)).to eq([16_145, 16_146, 16_148, 16_150])
      end

      it 'does not move, and still remembers the room, when she is already here' do
        expect(search(zasele_in: 16_153, start_in: 16_153)).to eq([])
        expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_153)
      end

      it 'keeps the old last-seen room when she cannot be found at all' do
        UserVars.taskmaster_last_seen = { 'zasele' => 16_150 }
        expect(search(zasele_in: 99_999, start_in: 16_936)).to match_array(rooms)
        expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_150)
      end

      it 'remembers each taskmaster separately' do
        UserVars.taskmaster_last_seen = { 'poltu' => 16_290 }
        search(zasele_in: 16_146, start_in: 16_936)
        expect(UserVars.taskmaster_last_seen).to eq('poltu' => 16_290, 'zasele' => 16_146)
      end
    end
  end

  describe 'loot history' do
    describe '#remember_sack' do
      def build(npc = 'zasele')
        tm = described_class.allocate
        tm.instance_variable_set(:@npc, npc)
        tm
      end

      it 'records each sack for loot_history' do
        UserVars.taskmaster_sacks = { 'zasele' => [] }
        build.remember_sack(' a large haledroth shard.')
        expect(UserVars.taskmaster_sacks['zasele']).to eq([' a large haledroth shard.'])
      end

      it 'keeps only the most recent 100 sacks' do
        UserVars.taskmaster_sacks = { 'zasele' => [] }
        tm = build
        150.times { |i| tm.remember_sack("sack #{i}") }
        history = UserVars.taskmaster_sacks['zasele']
        expect(history.size).to eq(100)
        expect(history.first).to eq('sack 50')
        expect(history.last).to eq('sack 149')
      end

      it 'trims an already oversized history from older runs on the next sack' do
        UserVars.taskmaster_sacks = { 'zasele' => Array.new(3_000) { |i| "old #{i}" } }
        build.remember_sack('new')
        expect(UserVars.taskmaster_sacks['zasele'].size).to eq(100)
        expect(UserVars.taskmaster_sacks['zasele'].last).to eq('new')
      end

      it 'starts a history for a taskmaster with none yet' do
        UserVars.taskmaster_sacks = nil
        build('poltu').remember_sack('a bronze bar.')
        expect(UserVars.taskmaster_sacks).to eq('poltu' => ['a bronze bar.'])
      end
    end
  end

  describe 'turn-in misses' do
    # A bare instance: initialize runs the whole script, so each example injects
    # only the state the method under test reads.
    def build
      tm = described_class.allocate
      tm.instance_variable_set(:@settings, OpenStruct.new)
      tm.instance_variable_set(:@bag, 'duffel bag')
      tm.instance_variable_set(:@npc, 'zasele')
      tm.instance_variable_set(:@rooms, [16_145])
      allow(tm).to receive(:sort_sack)
      allow(tm).to receive(:fput)
      allow(DRC).to receive(:message)
      tm
    end

    describe '#complete_task' do
      # Turn-in responses as the game prints them (2025 Hollow Eve logs).
      let(:more_needed) { 'Zasele holds up her fingers indicating 1 more is needed.' }
      let(:done) { 'Seamstress Zasele hands you a woven sack.' }
      let(:missed) { "What is it you're trying to give?" }

      # Plays the given give responses in order and tracks what is in hand: a
      # successful give empties the hand, a missed one leaves the item there.
      def turn_in(tm, responses)
        holding = false
        gets = 0
        allow(tm).to receive(:find_npc)
        allow(DRCI).to receive(:in_hands?) { holding }
        allow(DRCI).to receive(:get_item?) do
          gets += 1
          holding = true
        end
        allow(DRC).to receive(:bput) do |command, *_matchers|
          next '' unless command.start_with?('give my rope to zasele')

          response = responses.shift
          holding = false unless response == missed
          response
        end
        tm.complete_task('rope', 2)
        gets
      end

      it 'fetches one item per accepted give' do
        tm = build
        expect(turn_in(tm, [more_needed, done])).to eq(2)
        expect(tm).to have_received(:sort_sack).with('rope')
      end

      it 'gives the item still in hand when the taskmaster wandered off, instead of fetching another' do
        tm = build
        expect(turn_in(tm, [more_needed, missed, done])).to eq(2)
        expect(tm).to have_received(:find_npc).exactly(3).times
        expect(tm).to have_received(:sort_sack).with('rope')
      end

      it 'stops after repeated misses rather than looping forever' do
        tm = build
        expect { turn_in(tm, Array.new(10, missed)) }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/after 5 tries/)
        expect(tm).not_to have_received(:sort_sack)
      end

      it 'resets the miss count after a give lands' do
        tm = build
        responses = [missed, missed, missed, missed, more_needed, missed, missed, missed, missed, done]
        expect { turn_in(tm, responses) }.not_to raise_error
        expect(tm).to have_received(:sort_sack)
      end

      it 'exits when the bag runs out of items, as before' do
        tm = build
        allow(tm).to receive(:find_npc)
        allow(DRCI).to receive(:in_hands?).and_return(false)
        allow(DRCI).to receive(:get_item?).and_return(false)
        expect { tm.complete_task('rope', 2) }.to raise_error(SystemExit)
      end
    end
  end
end
