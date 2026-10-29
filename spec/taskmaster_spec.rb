# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')

RSpec.describe TaskMaster do
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
