# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')

RSpec.describe TaskMaster do
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
