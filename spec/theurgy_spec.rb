# frozen_string_literal: true

require 'ostruct'

load_lic_class('theurgy.lic', 'TheurgyActions')

RSpec.describe TheurgyActions do
  # Creature roster entry: what Lich::DragonRealms::Creature.in_room yields.
  def creature(id, name, noun, dead: false)
    double("creature #{id}", id: id, name: name, noun: noun, crtr_flag?: dead)
  end

  let(:pet_name) { 'a spectral white leopard with luminous blue eyes' }

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

    context 'with a full-name ignore entry' do
      let(:ignored_npcs) { ['spectral white leopard'] }

      it 'gathers when the only creature is the named pet' do
        Lich::DragonRealms::Creature._set_room([creature(10, pet_name, 'leopard')])
        DRRoom.npcs = ['leopard']
        gathers_seed
      end

      it 'aborts when a wild creature with the same noun is also present' do
        Lich::DragonRealms::Creature._set_room([creature(10, pet_name, 'leopard'),
                                                creature(11, 'a sinewy leopard', 'leopard')])
        DRRoom.npcs = %w[leopard leopard]
        aborts_on_invasion
      end

      it 'gathers when the same-noun creature beside the pet is dead' do
        Lich::DragonRealms::Creature._set_room([creature(10, pet_name, 'leopard'),
                                                creature(11, 'a sinewy leopard', 'leopard', dead: true)])
        DRRoom.npcs = ['leopard']
        gathers_seed
      end

      it 'aborts (noun rule only) while the pet has no name yet' do
        Lich::DragonRealms::Creature._set_room([creature(10, nil, 'leopard')])
        DRRoom.npcs = ['leopard']
        aborts_on_invasion
      end

      it 'aborts when there is no creature roster to match the name against' do
        DRRoom.npcs = ['leopard']
        aborts_on_invasion
      end
    end

    context 'with a single-word entry that is not the noun' do
      let(:ignored_npcs) { ['eyes'] }

      it 'does not skip a creature whose name merely contains the word' do
        Lich::DragonRealms::Creature._set_room([creature(10, pet_name, 'leopard')])
        DRRoom.npcs = ['leopard']
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
