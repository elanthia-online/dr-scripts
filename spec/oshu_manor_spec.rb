# frozen_string_literal: true

load_lic_class('oshu_manor.lic', 'Oshu')

RSpec.describe Oshu do
  # Creature roster entry: what Lich::DragonRealms::Creature.in_room yields.
  def creature(id, name, noun, dead: false)
    double("creature #{id}", id: id, name: name, noun: noun, crtr_flag?: dead)
  end

  let(:pet_name) { 'a spectral white leopard with luminous blue eyes' }
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

    context 'with a full-name ignore entry' do
      let(:ignored_npcs) { ['spectral white leopard'] }

      it 'is safe when the only creature is the named pet' do
        Lich::DragonRealms::Creature._set_room([creature(10, pet_name, 'leopard')])
        DRRoom.npcs = ['leopard']
        expect(oshu.safe_to_dig?).to be(true)
      end

      it 'is unsafe when a wild creature with the same noun is also present' do
        Lich::DragonRealms::Creature._set_room([creature(10, pet_name, 'leopard'),
                                                creature(11, 'a sinewy leopard', 'leopard')])
        DRRoom.npcs = %w[leopard leopard]
        expect(oshu.safe_to_dig?).to be(false)
      end

      it 'is safe when the same-noun creature beside the pet is dead' do
        Lich::DragonRealms::Creature._set_room([creature(10, pet_name, 'leopard'),
                                                creature(11, 'a sinewy leopard', 'leopard', dead: true)])
        DRRoom.npcs = ['leopard']
        expect(oshu.safe_to_dig?).to be(true)
      end

      it 'is unsafe (noun rule only) while the pet has no name yet' do
        Lich::DragonRealms::Creature._set_room([creature(10, nil, 'leopard')])
        DRRoom.npcs = ['leopard']
        expect(oshu.safe_to_dig?).to be(false)
      end

      it 'is unsafe when there is no creature roster to match the name against' do
        DRRoom.npcs = ['leopard']
        expect(oshu.safe_to_dig?).to be(false)
      end
    end

    context 'with a single-word entry that is not the noun' do
      let(:ignored_npcs) { ['eyes'] }

      it 'does not skip a creature whose name merely contains the word' do
        Lich::DragonRealms::Creature._set_room([creature(10, pet_name, 'leopard')])
        DRRoom.npcs = ['leopard']
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
