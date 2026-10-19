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

  # ===========================================================================
  # A room where the crystal can't be tapped at all ("Not here, ...")
  # ===========================================================================
  describe 'when the tap is refused in this room' do
    let(:tap_refusal) { 'Not here, ' }
    let(:pauses) { [] }

    # A crystal in a container, so check_crystal taps it first.
    let(:tapper) do
      crystal.tap { |c| c.instance_variable_set(:@worn_crystal, false) }
    end

    before do
      allow(DRC).to receive(:message)
      allow(DRC).to receive(:bput).and_return(tap_refusal)
    end

    # Stubs the one-second pause in the wait loop. Each pause runs the next step
    # (a room change, say) and a runaway wait raises instead of hanging the suite.
    def on_pause(tapper, steps = {})
      allow(tapper).to receive(:pause) do |seconds|
        pauses << seconds
        raise 'still waiting after 1000 pauses' if pauses.size > 1000

        steps[pauses.size]&.call
      end
    end

    def in_unmapped_room(title, description = 'A dusty room.')
      in_room(title, id: nil)
      DRRoom.description = description
    end

    it 'stops waiting when the character moves from one unmapped room to another' do
      in_unmapped_room('[[Ruins, Hall]]')
      on_pause(tapper, 3 => -> { in_unmapped_room('[[Ruins, Courtyard]]', 'Weeds grow here.') })

      tapper.check_crystal

      expect(pauses.size).to eq(3)
    end

    it 'treats an unmapped room with the same title but a different description as a new room' do
      in_unmapped_room('[[Ruins, Corridor]]', 'The corridor bends east.')
      on_pause(tapper, 2 => -> { in_unmapped_room('[[Ruins, Corridor]]', 'The corridor ends at a wall.') })

      tapper.check_crystal

      expect(pauses.size).to eq(2)
    end

    it 'stops waiting when the character moves from a mapped room to another mapped room' do
      in_room('[[Crossing, Market]]', id: 10)
      on_pause(tapper, 2 => -> { in_room('[[Crossing, Market]]', id: 11) })

      tapper.check_crystal

      expect(pauses.size).to eq(2)
    end

    it 'stops waiting when the character moves from a mapped room into an unmapped one' do
      in_room('[[Crossing, Market]]', id: 10)
      on_pause(tapper, 1 => -> { in_unmapped_room('[[Ruins, Hall]]') })

      tapper.check_crystal

      expect(pauses.size).to eq(1)
    end

    it 'stops waiting when the character moves from an unmapped room into a mapped one' do
      in_unmapped_room('[[Ruins, Hall]]')
      on_pause(tapper, 4 => -> { in_room('[[Crossing, Market]]', id: 10) })

      tapper.check_crystal

      expect(pauses.size).to eq(4)
    end

    it 'gives up after 300 one-second pauses when the character stays in a mapped room' do
      in_room('[[Crossing, Market]]', id: 10)
      on_pause(tapper)

      tapper.check_crystal

      expect(pauses).to eq([1] * 300)
    end

    it 'gives up after 300 one-second pauses when the character stays in an unmapped room' do
      in_unmapped_room('[[Ruins, Hall]]')
      on_pause(tapper)

      tapper.check_crystal

      expect(pauses).to eq([1] * 300)
    end

    it 'says how long it will wait' do
      in_room('[[Crossing, Market]]', id: 10)
      on_pause(tapper)

      tapper.check_crystal

      expect(DRC).to have_received(:message)
        .with('Pausing test-script script until you move to another room, for up to 5 minutes.')
    end

    it 'waits the same way after a wave of Corruption magic' do
      allow(DRC).to receive(:bput).and_return('a wave of Corruption magic')
      in_unmapped_room('[[Ruins, Hall]]')
      on_pause(tapper, 2 => -> { in_unmapped_room('[[Ruins, Courtyard]]', 'Weeds grow here.') })

      tapper.check_crystal

      expect(pauses.size).to eq(2)
    end

    it 'does not use or stow the crystal' do
      in_room('[[Crossing, Market]]', id: 10)
      on_pause(tapper, 1 => -> { in_room('[[Crossing, Bank]]', id: 11) })

      tapper.check_crystal

      expect(DRC).to have_received(:bput).once
    end

    # crossing-training runs `sanowret-crystal run` and waits for it to finish
    # before it moves on, so a single run that waited for a room change would
    # never end.
    context 'in a single run' do
      before { tapper.instance_variable_set(:@run_once, true) }

      it 'returns without waiting' do
        in_room('[[Crossing, Market]]', id: 10)
        on_pause(tapper)

        tapper.check_crystal

        expect(pauses).to be_empty
        expect(DRC).to have_received(:message).with('Cannot use the sanowret crystal in this room.')
      end

      it 'returns without waiting in an unmapped room' do
        in_unmapped_room('[[Ruins, Hall]]')
        on_pause(tapper)

        tapper.check_crystal

        expect(pauses).to be_empty
      end
    end

    describe 'setting up a single run' do
      let(:settings) do
        OpenStruct.new(sanowret_adjective: 'sanowret', sanowret_no_use_scripts: [], sanowret_no_use_rooms: [],
                       sanowret_force_exhale: false, ephemeron: nil)
      end

      before do
        allow_any_instance_of(described_class).to receive(:get_settings).and_return(settings)
        allow_any_instance_of(described_class).to receive(:pause) do |_instance, seconds|
          pauses << seconds
          raise 'still waiting after 1000 pauses' if pauses.size > 1000
        end
        DRSkill._set_rank('Arcana', 100)
        in_room('[[Crossing, Market]]', id: 10)
      end

      it 'does not wait for a room change when started with run' do
        allow_any_instance_of(described_class).to receive(:parse_args).and_return(OpenStruct.new(run: 'run'))

        described_class.new

        expect(DRC).to have_received(:bput).with('tap my sanowret crystal', any_args).once
        expect(pauses).to be_empty
        expect(DRC).to have_received(:message).with('Cannot use the sanowret crystal in this room.')
      end

      it 'still waits for a room change when started without run' do
        allow_any_instance_of(described_class).to receive(:parse_args).and_return(OpenStruct.new)
        allow_any_instance_of(described_class).to receive(:passive) { |instance| instance.check_crystal }

        described_class.new

        expect(pauses).to eq([1] * 300)
      end
    end
  end
end
