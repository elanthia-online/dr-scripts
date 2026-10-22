# frozen_string_literal: true

require 'ostruct'

load_lic_class('theurgy.lic', 'TheurgyActions')

RSpec.describe TheurgyActions do
  describe '#sirese_seed invasion check' do
    let(:ignored_npcs) { %w[cat leopard] }
    let(:actions) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@settings, OpenStruct.new(ignored_npcs: ignored_npcs))
        a.instance_variable_set(:@data, { 'gather_sirese' => { 'id' => 1 }, 'plant_sirese' => { 'id' => 2 } })
        a.instance_variable_set(:@water_holder, 'chalice')
        a.instance_variable_set(:@theurgy_supply_container, 'bag')
      end
    end

    before do
      allow(actions).to receive(:holy_water?).and_return(true)
      allow(actions).to receive(:safe_walk_to)
      allow(DRC).to receive(:bput).and_return('You find a tiny')
    end

    # An unexpected exit must fail the example, not end the whole run.
    def gathers_seed
      result = nil
      expect { result = actions.sirese_seed }.not_to raise_error
      expect(result).to be(true)
      expect(DRC).to have_received(:bput).with('gather seed', any_args)
    end

    def aborts_on_invasion
      expect { actions.sirese_seed }.to raise_error(SystemExit)
      expect(DRC).not_to have_received(:bput).with('gather seed', any_args)
    end

    it 'gathers in an empty room' do
      DRRoom.npcs = []
      gathers_seed
    end

    it 'gathers when two creatures share an ignored noun' do
      DRRoom.npcs = %w[cat cat]
      gathers_seed
    end

    it 'aborts when an unignored creature shares the room with duplicate ignored ones' do
      DRRoom.npcs = %w[cat cat moradu]
      aborts_on_invasion
    end

    # Which creatures a full-name entry names is DRRoom.unignored_npcs's rule
    # (lich-5, tested there); these stub it and check the check passes the
    # configured list through and acts on what comes back.
    context 'with a full-name ignore entry' do
      let(:ignored_npcs) { ['spectral white leopard'] }

      it 'gathers when DRRoom.unignored_npcs drops the only creature, the named pet' do
        DRRoom.npcs = ['leopard']
        allow(DRRoom).to receive(:unignored_npcs).and_return([])
        gathers_seed
        expect(DRRoom).to have_received(:unignored_npcs).with(['spectral white leopard'])
      end

      it 'aborts when DRRoom.unignored_npcs keeps a wild creature with the same noun' do
        DRRoom.npcs = %w[leopard leopard]
        allow(DRRoom).to receive(:unignored_npcs).with(['spectral white leopard']).and_return(['leopard'])
        aborts_on_invasion
      end
    end

    context 'when ignored_npcs is nil' do
      let(:ignored_npcs) { nil }

      it 'gathers in an empty room' do
        DRRoom.npcs = []
        gathers_seed
      end

      it 'aborts when any creature is present' do
        DRRoom.npcs = ['cat']
        aborts_on_invasion
      end
    end
  end
end
