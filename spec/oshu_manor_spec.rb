# frozen_string_literal: true

load_lic_class('oshu_manor.lic', 'Oshu')

RSpec.describe Oshu do
  let(:ignored_npcs) { %w[cat leopard] }
  let(:oshu) do
    described_class.allocate.tap { |o| o.instance_variable_set(:@ignored_npcs, ignored_npcs) }
  end

  describe '#safe_to_dig?' do
    it 'is safe in an empty room' do
      DRRoom.npcs = []
      expect(oshu.safe_to_dig?).to be(true)
    end

    it 'is safe when two creatures share an ignored noun' do
      DRRoom.npcs = %w[cat cat]
      expect(oshu.safe_to_dig?).to be(true)
    end

    it 'is unsafe when an unignored creature shares the room with duplicate ignored ones' do
      DRRoom.npcs = %w[cat cat worm]
      expect(oshu.safe_to_dig?).to be(false)
    end

    # Which creatures a full-name entry names is DRRoom.unignored_npcs's rule
    # (lich-5, tested there); these stub it and check safe_to_dig? passes the
    # configured list through and acts on what comes back.
    context 'with a full-name ignore entry' do
      let(:ignored_npcs) { ['spectral white leopard'] }

      it 'is safe when DRRoom.unignored_npcs drops the only creature, the named pet' do
        DRRoom.npcs = ['leopard']
        allow(DRRoom).to receive(:unignored_npcs).and_return([])
        expect(oshu.safe_to_dig?).to be(true)
        expect(DRRoom).to have_received(:unignored_npcs).with(['spectral white leopard'])
      end

      it 'is unsafe when DRRoom.unignored_npcs keeps a wild creature with the same noun' do
        DRRoom.npcs = %w[leopard leopard]
        allow(DRRoom).to receive(:unignored_npcs).with(['spectral white leopard']).and_return(['leopard'])
        expect(oshu.safe_to_dig?).to be(false)
      end
    end

    context 'when ignored_npcs is nil' do
      let(:ignored_npcs) { nil }

      it 'is safe in an empty room' do
        DRRoom.npcs = []
        expect(oshu.safe_to_dig?).to be(true)
      end

      it 'is unsafe when any creature is present' do
        DRRoom.npcs = ['worm']
        expect(oshu.safe_to_dig?).to be(false)
      end
    end
  end
end
