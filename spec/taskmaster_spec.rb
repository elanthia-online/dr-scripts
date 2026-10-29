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
end
