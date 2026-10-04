require_relative 'spec_helper'
require 'yaml'

# SanowretCrystal#initialize parses args, reads settings and starts the passive
# loop, so we extract the class with load_lic_class and drive use_crystal /
# check_crystal on bare-allocated instances with their ivars injected.
#
# The focus is room skipping. When the game answers "This is not a good place for
# that.", the script remembers the room for the rest of the run. It used to push
# the raw DRRoom.title ("[[Crossing, Market]]") into sanowret_no_use_rooms, where
# check_crystal interpolated it into a regex: the brackets made a character class
# that matched nearly every room, so one refusal disabled the crystal everywhere.
load_lic_class('sanowret-crystal.lic', 'SanowretCrystal')

RSpec.describe SanowretCrystal do
  let(:refusal) { 'This is not a good place for that.' }

  # The base.yaml defaults plus a !ruby/regexp entry, parsed the way Lich loads
  # profiles, so each user-supplied entry type is the real one.
  let(:no_use_rooms) do
    YAML.unsafe_load(<<~YAML)
      - Carousel Chamber
      - Carousel Booth
      - 1900
      - Knife Clan, Triage
      - !ruby/regexp /Asemath Academy, (?:Library|Study)/
    YAML
  end

  # A worn crystal, so check_crystal goes straight to use_crystal (no tap/get/stow).
  let(:crystal) do
    described_class.allocate.tap do |c|
      c.instance_variable_set(:@adjective, 'sanowret')
      c.instance_variable_set(:@no_use_scripts, [])
      c.instance_variable_set(:@no_use_rooms, no_use_rooms)
      c.instance_variable_set(:@refused_room_titles, [])
      c.instance_variable_set(:@force_exhale, false)
      c.instance_variable_set(:@worn_crystal, true)
    end
  end

  before do
    DRStats.concentration = 100
    DRSkill._set_xp('Arcana', 0)
  end

  # id: nil puts us in an unmapped room, where Room.current is nil.
  def in_room(title, id: 1)
    DRRoom.title = title
    allow(Room).to receive(:current).and_return(id && instance_double(Map, id: id))
  end

  # ===========================================================================
  # Rooms that refuse the crystal during the run
  # ===========================================================================
  describe 'after a room refuses the crystal' do
    before { allow(DRC).to receive(:bput).and_return(refusal) }

    it 'still uses the crystal in a different room' do
      in_room('[[Crossing, Market]]')
      crystal.check_crystal

      in_room('[[Shard, Bank]]')
      crystal.check_crystal

      expect(DRC).to have_received(:bput).twice
    end

    it 'skips the refusing room for the rest of the run' do
      in_room('[[Crossing, Market]]')
      crystal.check_crystal
      crystal.check_crystal

      expect(DRC).to have_received(:bput).once
    end

    it 'does not skip a room whose title only shares characters or a prefix with it' do
      in_room('[[Crossing, Market]]')
      crystal.check_crystal

      in_room('[[Crossing, Market Plaza]]')
      crystal.check_crystal

      expect(DRC).to have_received(:bput).twice
    end

    it "leaves the user's sanowret_no_use_rooms untouched" do
      in_room('[[Crossing, Market]]')
      crystal.check_crystal

      expect(crystal.instance_variable_get(:@no_use_rooms)).to eq(['Carousel Chamber', 'Carousel Booth', 1900, 'Knife Clan, Triage', /Asemath Academy, (?:Library|Study)/])
    end

    it 'remembers a room title once however often it refuses' do
      in_room('[[Crossing, Market]]')
      crystal.use_crystal
      crystal.use_crystal

      expect(crystal.instance_variable_get(:@refused_room_titles)).to eq(['[[Crossing, Market]]'])
    end

    it 'suggests the room id, which matches exactly even when the title has regex metacharacters' do
      allow(DRC).to receive(:message)
      in_room('[[Who Clothes There?, Sales]]', id: 4321)
      crystal.use_crystal

      expect(DRC).to have_received(:message).with('Could not use crystal in room [[Who Clothes There?, Sales]].')
      expect(DRC).to have_received(:message).with('Consider adding room id 4321 to your sanowret_no_use_rooms settings.')
    end

    it 'suggests the title without its brackets in an unmapped room' do
      allow(DRC).to receive(:message)
      in_room('[[Crossing, Market]]', id: nil)
      crystal.use_crystal

      expect(DRC).to have_received(:message).with("Consider adding 'Crossing, Market' to your sanowret_no_use_rooms settings.")
    end

    # $clean_lich_char is only set when another spec defines it, so match around it.
    { 'a mapped room' => 4321, 'an unmapped room' => nil }.each do |label, id|
      it "asks for the room to be posted in the lich discord for base.yaml in #{label}" do
        allow(DRC).to receive(:message)
        in_room('[[Crossing, Market]]', id: id)
        crystal.use_crystal

        expect(DRC).to have_received(:message)
          .with(/\APlease also post this room in the lich discord \(listed in .?links\) so it can be added to base\.yaml for everyone\.\z/)
      end
    end

    it 'remembers an unmapped room by its title' do
      in_room('[[Crossing, Market]]', id: nil)
      crystal.use_crystal

      expect(crystal.instance_variable_get(:@refused_room_titles)).to eq(['[[Crossing, Market]]'])
    end
  end

  describe 'when the crystal works' do
    it 'does not remember the room' do
      allow(DRC).to receive(:bput).and_return('A soft light blossoms in the very center of the crystal, and begins to fill your mind with the knowledge of Arcana.')
      in_room('[[Crossing, Market]]')
      crystal.use_crystal

      expect(crystal.instance_variable_get(:@refused_room_titles)).to be_empty
    end
  end

  # ===========================================================================
  # User-supplied sanowret_no_use_rooms entries keep their existing matching
  # ===========================================================================
  describe 'sanowret_no_use_rooms entries' do
    before { allow(crystal).to receive(:use_crystal) }

    it 'skips a room whose title contains a plain title fragment' do
      in_room('[[Knife Clan, Triage]]')
      crystal.check_crystal

      expect(crystal).not_to have_received(:use_crystal)
    end

    it 'skips a room by Integer room id, whatever its title' do
      in_room('[[Crossing, Market]]', id: 1900)
      crystal.check_crystal

      expect(crystal).not_to have_received(:use_crystal)
    end

    it 'skips a room matching a !ruby/regexp entry' do
      in_room('[[Asemath Academy, Study]]')
      crystal.check_crystal

      expect(crystal).not_to have_received(:use_crystal)
    end

    it 'uses the crystal in a room none of them match' do
      in_room('[[Shard, Bank]]', id: 1901)
      crystal.check_crystal

      expect(crystal).to have_received(:use_crystal)
    end
  end
end
