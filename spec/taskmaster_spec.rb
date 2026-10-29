# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')

RSpec.describe TaskMaster do
  describe '#reconcile_hands' do
    # Hands as the game described them after Hollow Eve 2025 disconnects.
    # after_sew: the hands once sew has run, which is how the result is judged.
    def reconcile(right:, left:, npc: 'zasele', after_sew: nil)
      tm = described_class.allocate
      tm.instance_variable_set(:@npc, npc)
      tm.instance_variable_set(:@bag, 'duffel bag')
      tm.instance_variable_set(:@worn_trashcan, nil)
      tm.instance_variable_set(:@worn_trashcan_verb, nil)
      tm.instance_variable_set(:@settings, OpenStruct.new(outfitting_belt: outfitting_belt))
      hands = { right: right, left: left }
      allow(DRC).to receive(:right_hand) { hands[:right] }
      allow(DRC).to receive(:left_hand) { hands[:left] }
      allow(DRC).to receive(:message)
      allow(tm).to receive(:sort_sack)
      launched = []
      allow(DRC).to receive(:wait_for_script_to_complete) do |name, args|
        launched << [name, args]
        hands.merge!(after_sew) if after_sew
      end
      # As lich-5 matches a noun string (DRC::Item.from_text + short_regex):
      # no adjective, so the noun alone, /\bnetting/i.
      allow(DRCI).to receive(:in_hands?) { |noun| hands.values.compact.any? { |held| held =~ /\b#{noun}/i } }
      allow(DRCI).to receive(:dispose_trash)
      allow(DRCC).to receive(:stow_crafting_item)
      tm.reconcile_hands
      [tm, launched]
    end

    def outfitting_belt
      { 'name' => 'tailor belt', 'items' => ['sewing needles', 'scissors'] }
    end

    it 'finishes an unfinished sewn item with sew resume and bags it' do
      _, launched = reconcile(right: 'loimic serrated scissors', left: 'coil of unfinished burlap reinforced rope',
                              after_sew: { right: nil, left: 'coil of burlap reinforced rope' })
      expect(launched).to eq([['sew', %w[resume rope]]])
      expect(DRCC).to have_received(:stow_crafting_item).with('rope', 'duffel bag', nil)
      expect(DRCI).not_to have_received(:dispose_trash)
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

    it 'throws away an item sew could not finish, stows the tool and carries on' do
      expect do
        reconcile(right: 'unfinished burlap reinforced netting', left: nil,
                  after_sew: { right: 'unfinished burlap reinforced netting', left: 'slender agonite sewing needles' })
      end.not_to raise_error
      expect(DRCC).not_to have_received(:stow_crafting_item).with('netting', anything, anything)
      expect(DRCI).to have_received(:dispose_trash).with('netting', nil, nil)
      expect(DRCC).to have_received(:stow_crafting_item).with('slender agonite sewing needles', 'duffel bag', outfitting_belt)
      expect(DRC).to have_received(:message).with(/could not finish/)
    end

    it 'bags nothing when the item left the hands during sew' do
      reconcile(right: 'wide unfinished rat-pelt leather straps', left: nil, after_sew: { right: nil, left: nil })
      expect(DRCC).not_to have_received(:stow_crafting_item)
      expect(DRCI).not_to have_received(:dispose_trash)
    end
  end
end
