# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')

RSpec.describe TaskMaster do
  describe '#reconcile_hands' do
    # Hands as the game described them after Hollow Eve 2025 disconnects.
    def reconcile(right:, left:, npc: 'zasele')
      tm = described_class.allocate
      tm.instance_variable_set(:@npc, npc)
      tm.instance_variable_set(:@bag, 'duffel bag')
      allow(DRC).to receive(:right_hand).and_return(right)
      allow(DRC).to receive(:left_hand).and_return(left)
      allow(tm).to receive(:sort_sack)
      launched = []
      allow(DRC).to receive(:wait_for_script_to_complete) { |name, args| launched << [name, args] }
      allow(DRCI).to receive(:in_hands?).and_return(true)
      allow(DRCC).to receive(:stow_crafting_item)
      tm.reconcile_hands
      [tm, launched]
    end

    it 'finishes an unfinished sewn item with sew resume and bags it' do
      _, launched = reconcile(right: 'loimic serrated scissors', left: 'coil of unfinished burlap reinforced rope')
      expect(launched).to eq([['sew', %w[resume rope]]])
      expect(DRCC).to have_received(:stow_crafting_item).with('rope', 'duffel bag', nil)
    end

    it 'finds the unfinished item in either hand' do
      _, launched = reconcile(right: 'wide unfinished rat-pelt leather straps', left: nil)
      expect(launched).to eq([['sew', %w[resume straps]]])
    end

    it 'sorts a reward sack held at start' do
      tm, = reconcile(right: 'woven sack', left: nil)
      expect(tm).to have_received(:sort_sack)
    end

    it 'leaves finished items, tools and empty hands alone' do
      _, launched = reconcile(right: 'slender agonite sewing needles', left: 'burlap reinforced netting')
      expect(launched).to be_empty
      _, launched = reconcile(right: nil, left: nil)
      expect(launched).to be_empty
    end

    it 'does not try to resume knitting, whose work does not show in the hand' do
      _, launched = reconcile(right: 'polished loimic knitting needles', left: nil)
      expect(launched).to be_empty
    end

    it 'only resumes tailoring, never another taskmaster\'s unfinished item' do
      _, launched = reconcile(right: 'unfinished bronze dagger', left: nil, npc: 'poltu')
      expect(launched).to be_empty
    end

    it 'does not bag the item when sew could not finish it' do
      tm = described_class.allocate
      tm.instance_variable_set(:@npc, 'zasele')
      tm.instance_variable_set(:@bag, 'duffel bag')
      allow(DRC).to receive(:right_hand).and_return('unfinished burlap reinforced netting')
      allow(DRC).to receive(:left_hand).and_return(nil)
      allow(DRC).to receive(:wait_for_script_to_complete)
      allow(DRCI).to receive(:in_hands?).and_return(false)
      expect(DRCC).not_to receive(:stow_crafting_item)
      tm.reconcile_hands
    end
  end
end
