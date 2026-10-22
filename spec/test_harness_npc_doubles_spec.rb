# frozen_string_literal: true

# Pins the shared doubles for lich-5's DRRoom.unignored_npcs and
# CreatureInstance#matches? (lich-5 #1817), so specs that lean on them get the
# behavior the harness comments promise.
RSpec.describe 'test harness NPC doubles' do
  describe 'DRRoom.unignored_npcs' do
    it 'drops every NPC whose noun is an entry and keeps duplicates of the rest' do
      DRRoom.npcs = %w[goblin goblin rat rat]
      expect(DRRoom.unignored_npcs(['rat'])).to eq(%w[goblin goblin])
    end

    it 'applies the noun rule only, ignoring a full-name entry' do
      DRRoom.npcs = %w[leopard leopard]
      Lich::DragonRealms::Creature._set_room(
        [Lich::DragonRealms::CreatureInstance.new(1, 'leopard', 'a spectral white leopard'),
         Lich::DragonRealms::CreatureInstance.new(2, 'leopard', 'a sinewy leopard')]
      )
      expect(DRRoom.unignored_npcs(['spectral white leopard'])).to eq(%w[leopard leopard])
    end

    it 'treats nil, a bare string and symbols like lich-5 does' do
      DRRoom.npcs = %w[goblin rat]
      expect(DRRoom.unignored_npcs(nil)).to eq(%w[goblin rat])
      expect(DRRoom.unignored_npcs('rat')).to eq(%w[goblin])
      expect(DRRoom.unignored_npcs([nil, :goblin])).to eq(%w[rat])
    end

    it 'returns a new array, leaving DRRoom.npcs and the ignore list untouched' do
      DRRoom.npcs = %w[goblin rat]
      ignored = ['rat']
      result = DRRoom.unignored_npcs(ignored)
      result << 'troll'
      expect(DRRoom.npcs).to eq(%w[goblin rat])
      expect(ignored).to eq(['rat'])
    end

    it 'returns [] for an empty room' do
      expect(DRRoom.unignored_npcs(['rat'])).to eq([])
    end
  end

  describe Lich::DragonRealms::CreatureInstance do
    let(:leopard) { described_class.new(7, 'leopard', 'a spectral white leopard with luminous blue eyes') }

    it 'exposes id, noun and name' do
      expect([leopard.id, leopard.noun, leopard.name])
        .to eq([7, 'leopard', 'a spectral white leopard with luminous blue eyes'])
    end

    it 'matches the noun, case-insensitively' do
      expect(leopard.matches?('LEOPARD')).to be(true)
    end

    it 'matches the whole name without its article, ignoring extra spaces' do
      expect(leopard.matches?('  spectral  white leopard with luminous blue eyes ')).to be(true)
    end

    it 'matches a phrase of two or more whole words in the name' do
      expect(leopard.matches?('spectral white leopard')).to be(true)
      expect(leopard.matches?('luminous blue')).to be(true)
    end

    it 'does not match a single non-noun word, a partial word or a phrase out of order' do
      expect(leopard.matches?('eyes')).to be(false)
      expect(leopard.matches?('ectral white')).to be(false)
      expect(leopard.matches?('white spectral')).to be(false)
    end

    it 'does not match nil or a blank entry' do
      expect(leopard.matches?(nil)).to be(false)
      expect(leopard.matches?('   ')).to be(false)
    end

    it 'falls back to the noun when the name is nil' do
      nameless = described_class.new(8, 'leopard', nil)
      expect(nameless.matches?('leopard')).to be(true)
      expect(nameless.matches?('white leopard')).to be(false)
    end

    it 'ignores a leading article on the name and on the entry' do
      cat = described_class.new(9, 'cat', 'The Great Cat')
      expect(cat.matches?('great cat')).to be(true)
      expect(cat.matches?('the great cat')).to be(true)
      expect(cat.matches?('a great cat')).to be(true)
      expect(cat.matches?('great the cat')).to be(false)
    end

    it 'reports :dead only when built dead, and no other flag' do
      expect(leopard.crtr_flag?(:dead)).to be(false)
      corpse = described_class.new(10, 'leopard', 'a sinewy leopard', dead: true)
      expect(corpse.crtr_flag?(:dead)).to be(true)
      expect(corpse.crtr_flag?(:stunned)).to be(false)
    end

    it 'resolves through the Creature roster by id' do
      Lich::DragonRealms::Creature._set_room([leopard])
      expect(Lich::DragonRealms::Creature[7]).to be(leopard)
    end
  end
end
