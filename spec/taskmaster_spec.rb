# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')

RSpec.describe TaskMaster do
  # A bare instance: initialize runs the whole script, so each example injects
  # only the state the method under test reads.
  def build(settings = {})
    tm = described_class.allocate
    tm.instance_variable_set(:@settings, OpenStruct.new(settings))
    tm.instance_variable_set(:@bag, 'duffel bag')
    tm.instance_variable_set(:@bag_items, [])
    tm.send(:configure_copper)
    tm
  end

  describe '#configure_copper' do
    it 'defaults to a 20000 floor and a 110000 target' do
      tm = build
      expect(tm.instance_variable_get(:@copper_floor)).to eq(20_000)
      expect(tm.instance_variable_get(:@copper_target)).to eq(110_000)
    end

    it 'reads task_copper_floor and task_copper_target' do
      tm = build(task_copper_floor: 30_000, task_copper_target: 150_000)
      expect(tm.instance_variable_get(:@copper_floor)).to eq(30_000)
      expect(tm.instance_variable_get(:@copper_target)).to eq(150_000)
    end

    it 'never targets less than the floor, which would mean a bank trip every task' do
      tm = build(task_copper_floor: 50_000, task_copper_target: 10_000)
      expect(tm.instance_variable_get(:@copper_target)).to eq(50_000)
    end
  end

  describe '#top_up_copper' do
    before do
      allow(DRCM).to receive(:ensure_copper_on_hand)
    end

    it 'does nothing but check wealth while at or above the floor' do
      tm = build
      allow(DRCM).to receive(:wealth).with('Crossing').and_return(20_000)
      expect(tm).not_to receive(:exchange_coins)
      tm.top_up_copper
      expect(DRCM).not_to have_received(:ensure_copper_on_hand)
    end

    it 'exchanges foreign coins and refills to the target once below the floor' do
      tm = build
      allow(DRCM).to receive(:wealth).and_return(19_999)
      expect(tm).to receive(:exchange_coins).ordered
      expect(DRCM).to receive(:ensure_copper_on_hand).with(110_000, anything, 'Crossing').ordered
      tm.top_up_copper
    end

    it 'treats an unreadable WEALTH reply (0) as broke and tops up' do
      tm = build
      allow(DRCM).to receive(:wealth).and_return(0)
      allow(tm).to receive(:exchange_coins)
      tm.top_up_copper
      expect(DRCM).to have_received(:ensure_copper_on_hand).with(110_000, anything, 'Crossing')
    end

    it 'makes one bank trip across many cheap tasks, not one per task' do
      tm = build
      on_hand = 110_000
      allow(DRCM).to receive(:wealth) { on_hand }
      trips = 0
      allow(tm).to receive(:exchange_coins) { trips += 1 }
      allow(DRCM).to receive(:ensure_copper_on_hand) { |amount, *_| on_hand = [on_hand, amount].max }
      14.times do
        tm.top_up_copper
        on_hand -= 8_000 # a typical Zasele task, fee included
      end
      expect(trips).to eq(1)
    end
  end

  describe '#restock (marathon)' do
    let(:stockdata) do
      { 'burlap' => { 'stock-value' => 1000, 'stock-number' => 1 }, 'rat' => { 'stock-value' => 1000, 'stock-number' => 2 },
        'yarn' => { 'stock-value' => 500, 'stock-number' => 3 }, 'thread' => { 'stock-value' => 300, 'stock-number' => 4 } }
    end

    it 'keeps the float instead of depositing down to 5000 before buying' do
      tm = build
      tm.instance_variable_set(:@stockdata, stockdata)
      # restock also walks a 'thread' entry; the script's own map lacks one, so
      # supply it here to reach the money handling under test.
      tm.instance_variable_set(:@stackmap, { 'leather' => ['rat', 16667], 'cloth' => ['burlap', 16667], 'yarn' => ['wool', 16667], 'thread' => ['cotton', 16667] })
      allow(tm).to receive(:get_data).and_return({ 'tailoring' => { 'Crossing' => { 'tool-room' => 16667 } } })
      allow(DRCC).to receive(:check_consumables)
      allow(DRCI).to receive(:exists?).and_return(false)
      allow(DRCT).to receive(:walk_to)
      allow(DRCT).to receive(:order_item)
      allow(DRC).to receive(:bput).and_return('You combine')
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCM).to receive(:deposit_coins)
      expect(tm).to receive(:top_up_copper)
      tm.restock
      expect(DRCM).not_to have_received(:deposit_coins)
    end
  end
end
