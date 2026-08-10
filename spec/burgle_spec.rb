# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('burgle.lic', 'Burgle')

# Stands in for a burgled house so the traversal methods can be driven end to end.
#
# Rooms are keyed by their direction-path from the entry room, which is exactly the key
# map_house builds -- so the expected map in a test reads as the house definition itself.
# Every move is recorded, and walking into a room that was never defined raises rather than
# silently returning a nil title, which would otherwise mask a pathing bug as a passing test.
class SimulatedHouse
  attr_reader :moves

  def initialize(rooms, reverse_direction_map)
    @rooms = rooms
    @reverse_direction_map = reverse_direction_map
    @path = []
    @moves = []
  end

  def room_title
    "[[Someone Else's Home, #{@rooms.fetch(@path)['title']}]]"
  end

  def room_exits
    @rooms.fetch(@path)['exits']
  end

  def move(direction)
    @moves << direction
    if !@path.empty? && direction == @reverse_direction_map[@path.last]
      @path.pop
    else
      @path.push(direction)
    end
    raise "moved #{direction} into a room that does not exist: #{@path.inspect}" unless @rooms.key?(@path)
  end

  def at_entry_room?
    @path.empty?
  end
end

# Stands in for a burgled house that contains a cycle.
#
# SimulatedHouse keys its rooms by direction-path, which cannot represent a room reachable by
# two different paths -- so it can't express a cycle at all. This one keys rooms by name and
# holds exits as edges between them instead. Real houses do contain cycles.
#
# A move in a direction the current room has no exit for raises: in game that is
# `DRC.bput(direction, "Someone Else's Home")` waiting on a room title that never arrives.
class CyclicHouse
  attr_reader :moves, :current

  def initialize(rooms, entry)
    @rooms = rooms
    @entry = entry
    @current = entry
    @moves = []
  end

  def room_title
    "[[Someone Else's Home, #{@current}]]"
  end

  def room_exits
    @rooms.fetch(@current).keys
  end

  def move(direction)
    @moves << direction
    destination = @rooms.fetch(@current)[direction]
    raise "walked #{direction.inspect} out of the #{@current}, which has no such exit" unless destination

    @current = destination
  end

  def at_entry_room?
    @current == @entry
  end

  # Walks a recorded direction-path from the entry room and reports where it lands, so a map
  # can be checked against the house rather than against a hand-written expectation.
  def room_at(path)
    walker = CyclicHouse.new(@rooms, @entry)
    path.each { |direction| walker.move(direction) }
    walker.current
  end
end

RSpec.describe Burgle do
  let(:messages) { [] }

  let(:reverse_direction_map) do
    {
      'east'      => 'west',
      'west'      => 'east',
      'south'     => 'north',
      'north'     => 'south',
      'northeast' => 'southwest',
      'southwest' => 'northeast',
      'northwest' => 'southeast',
      'southeast' => 'northwest'
    }
  end

  let(:room_searchable_objects_map) do
    {
      "Kitchen"   => 'counter',
      "Bedroom"   => 'bed',
      "Armory"    => 'rack',
      "Library"   => 'bookshelf',
      "Sanctum"   => 'desk',
      "Work Room" => 'table'
    }
  end

  #     Bedroom
  #        |
  #      north
  #        |
  #   Kitchen --east-- Library --north-- Armory
  #   (entry)
  #
  # A branching layout: a dead end off the entry room, and a two-deep branch beside it. The
  # two leaves share no prefix, so it also exercises path_between's shared-prefix trimming.
  let(:branching_house) do
    {
      []             => { 'title' => 'Kitchen', 'exits' => %w[north east] },
      ['north']      => { 'title' => 'Bedroom', 'exits' => %w[south] },
      ['east']       => { 'title' => 'Library', 'exits' => %w[west north] },
      %w[east north] => { 'title' => 'Armory', 'exits' => %w[south] }
    }
  end

  let(:house) { SimulatedHouse.new(branching_house, reverse_direction_map) }

  before(:each) do
    reset_data

    allow(DRC).to receive(:message) { |msg| messages << msg }
    allow(XMLData).to receive(:room_title) { house.room_title }
    allow(XMLData).to receive(:room_exits) { house.room_exits }
  end

  # Helper: create a bare Burgle instance without running initialize
  def build_instance(**overrides)
    instance = Burgle.allocate
    instance.instance_variable_set(:@reverse_direction_map, reverse_direction_map)
    instance.instance_variable_set(:@room_searchable_objects_map, room_searchable_objects_map)
    instance.instance_variable_set(:@burgle_settings, { 'max_search_count' => 2, 'room_blacklist' => [] })
    instance.instance_variable_set(:@prioritize_rooms, [])
    instance.instance_variable_set(:@room_priority_type, 'any')
    instance.instance_variable_set(:@search_count, 0)
    instance.instance_variable_set(:@stealth_inside, true)

    overrides.each { |k, v| instance.instance_variable_set(:"@#{k}", v) }
    instance
  end

  # Wires an instance up to the simulated house: moves drive the house, and searches record
  # what was searched while consuming budget the way the real search_for_loot does.
  def drive_house(instance, searched)
    allow(instance).to receive(:burgle_move) { |direction| house.move(direction) }
    allow(instance).to receive(:search_for_loot) do |target|
      searched << target
      instance.instance_variable_set(:@search_count, instance.instance_variable_get(:@search_count) + 1)
    end
  end

  # ---------------------------------------------------------------------------
  # path_between
  # ---------------------------------------------------------------------------

  describe '#path_between' do
    let(:instance) { build_instance }

    it 'returns no moves for identical paths' do
      expect(instance.send(:path_between, %w[east north], %w[east north])).to eq([])
    end

    it 'walks out from the entry room' do
      expect(instance.send(:path_between, [], %w[east north])).to eq(%w[east north])
    end

    it 'walks back to the entry room in reverse' do
      expect(instance.send(:path_between, %w[east north], [])).to eq(%w[south west])
    end

    it 'drops the shared prefix between sibling branches' do
      # Library at [north, east] to Armory at [north, west] is two moves, not four via entry
      expect(instance.send(:path_between, %w[north east], %w[north west])).to eq(%w[west west])
    end

    it 'handles branches that share no prefix' do
      expect(instance.send(:path_between, ['north'], %w[east north])).to eq(%w[south east north])
    end

    it 'handles a nested common prefix' do
      from = %w[north east south]
      to = %w[north east west]
      expect(instance.send(:path_between, from, to)).to eq(%w[north west])
    end

    it 'descends when the target extends the current path' do
      expect(instance.send(:path_between, ['north'], %w[north east south])).to eq(%w[east south])
    end
  end

  # ---------------------------------------------------------------------------
  # build_search_queue
  # ---------------------------------------------------------------------------

  describe '#build_search_queue' do
    let(:map) do
      { 'Kitchen' => [], 'Bedroom' => ['north'], 'Library' => ['east'], 'Armory' => %w[east north] }
    end

    it 'puts priority rooms first, in discovery order' do
      instance = build_instance(prioritize_rooms: %w[Armory Library])

      expect(instance.send(:build_search_queue, map)).to eq(%w[Library Armory Kitchen Bedroom])
    end

    context 'when room_priority_type is inorder' do
      it 'honors the listed order over discovery order' do
        # Library is discovered before Armory, but Armory is listed first
        instance = build_instance(prioritize_rooms: %w[Armory Library], room_priority_type: 'inorder')

        expect(instance.send(:build_search_queue, map)).to eq(%w[Armory Library Kitchen Bedroom])
      end

      it 'still appends non-priority rooms in discovery order' do
        instance = build_instance(prioritize_rooms: %w[Armory Kitchen], room_priority_type: 'inorder')

        expect(instance.send(:build_search_queue, map)).to eq(%w[Armory Kitchen Bedroom Library])
      end

      it 'closes the gaps left by priority rooms that are not in this house' do
        instance = build_instance(
          prioritize_rooms: %w[Sanctum Armory Work\ Room Library],
          room_priority_type: 'inorder'
        )

        expect(instance.send(:build_search_queue, map)).to eq(%w[Armory Library Kitchen Bedroom])
      end

      it 'excludes blacklisted rooms without disturbing the listed order' do
        instance = build_instance(
          prioritize_rooms: %w[Bedroom Armory Library],
          room_priority_type: 'inorder',
          burgle_settings: { 'room_blacklist' => ['Bedroom'] }
        )

        expect(instance.send(:build_search_queue, map)).to eq(%w[Armory Library Kitchen])
      end

      it 'uses the first position of a room listed more than once' do
        instance = build_instance(
          prioritize_rooms: %w[Armory Library Armory],
          room_priority_type: 'inorder'
        )

        expect(instance.send(:build_search_queue, map)).to eq(%w[Armory Library Kitchen Bedroom])
      end

      it 'changes nothing when no rooms are prioritized' do
        instance = build_instance(room_priority_type: 'inorder')

        expect(instance.send(:build_search_queue, map)).to eq(%w[Kitchen Bedroom Library Armory])
      end
    end

    it 'appends non-priority rooms in discovery order' do
      instance = build_instance(prioritize_rooms: ['Armory'])

      expect(instance.send(:build_search_queue, map)).to eq(%w[Armory Kitchen Bedroom Library])
    end

    it 'excludes blacklisted rooms' do
      instance = build_instance(
        prioritize_rooms: ['Library'],
        burgle_settings: { 'room_blacklist' => %w[Kitchen Bedroom] }
      )

      expect(instance.send(:build_search_queue, map)).to eq(%w[Library Armory])
    end

    it 'treats a nil room_blacklist as empty' do
      instance = build_instance(prioritize_rooms: ['Library'], burgle_settings: {})

      expect(instance.send(:build_search_queue, map)).to eq(%w[Library Kitchen Bedroom Armory])
    end

    it 'skips priority rooms that are not in this house' do
      instance = build_instance(prioritize_rooms: %w[Sanctum Library])

      expect(instance.send(:build_search_queue, map)).to eq(%w[Library Kitchen Bedroom Armory])
    end

    it 'returns every room in discovery order when nothing is prioritized' do
      instance = build_instance

      expect(instance.send(:build_search_queue, map)).to eq(%w[Kitchen Bedroom Library Armory])
    end
  end

  # ---------------------------------------------------------------------------
  # validate_prioritize_rooms
  # ---------------------------------------------------------------------------

  describe '#validate_prioritize_rooms' do
    it 'does nothing when no rooms are prioritized' do
      instance = build_instance

      instance.send(:validate_prioritize_rooms)

      expect(messages).to be_empty
    end

    it 'warns about unknown room names and strips them' do
      instance = build_instance(prioritize_rooms: ['library', 'Armory'])

      instance.send(:validate_prioritize_rooms)

      expect(messages.first).to include('Unknown burgle_settings:prioritize_rooms entries')
      expect(messages.first).to include('library')
      expect(messages[1]).to include('Valid room names:')
      expect(instance.instance_variable_get(:@prioritize_rooms)).to eq(['Armory'])
    end

    it 'warns about blacklist conflicts and lets the blacklist win' do
      instance = build_instance(
        prioritize_rooms: %w[Kitchen Library],
        burgle_settings: { 'room_blacklist' => ['Kitchen'] }
      )

      instance.send(:validate_prioritize_rooms)

      expect(messages.last).to include('blacklist wins: Kitchen')
      expect(instance.instance_variable_get(:@prioritize_rooms)).to eq(['Library'])
    end

    it 'tolerates a nil room_blacklist' do
      instance = build_instance(prioritize_rooms: ['Library'], burgle_settings: {})

      instance.send(:validate_prioritize_rooms)

      expect(instance.instance_variable_get(:@prioritize_rooms)).to eq(['Library'])
    end

    it 'says nothing for the default any ordering' do
      instance = build_instance(prioritize_rooms: ['Library'])

      instance.send(:validate_prioritize_rooms)

      expect(messages).to be_empty
    end

    it 'says nothing for inorder ordering' do
      instance = build_instance(prioritize_rooms: ['Library'], room_priority_type: 'inorder')

      instance.send(:validate_prioritize_rooms)

      expect(messages).to be_empty
      expect(instance.instance_variable_get(:@room_priority_type)).to eq('inorder')
    end

    it 'falls back to any for an invalid room_priority_type' do
      instance = build_instance(prioritize_rooms: ['Library'], room_priority_type: 'nearest')

      instance.send(:validate_prioritize_rooms)

      expect(messages.last).to include("Invalid burgle_settings:room_priority_type 'nearest'")
      expect(instance.instance_variable_get(:@room_priority_type)).to eq('any')
    end
  end

  # ---------------------------------------------------------------------------
  # map_house
  # ---------------------------------------------------------------------------

  describe '#map_house' do
    it 'records the direction-path from the entry room to every room' do
      instance = build_instance
      drive_house(instance, [])

      expect(instance.send(:map_house)).to eq(
        'Kitchen' => [],
        'Bedroom' => ['north'],
        'Library' => ['east'],
        'Armory'  => %w[east north]
      )
    end

    it 'returns the character to the entry room' do
      instance = build_instance
      drive_house(instance, [])

      instance.send(:map_house)

      expect(house).to be_at_entry_room
    end

    it 'searches nothing and spends no search budget' do
      instance = build_instance
      searched = []
      drive_house(instance, searched)

      instance.send(:map_house)

      expect(searched).to be_empty
      expect(instance.instance_variable_get(:@search_count)).to eq(0)
    end

    it 'visits every room exactly once regardless of which exit it samples first' do
      instance = build_instance
      drive_house(instance, [])

      # each of the three non-entry rooms costs one move out and one move back
      expect(instance.send(:map_house).keys.count).to eq(4)
      expect(house.moves.count).to eq(6)
    end

    it 'stops mapping and returns to the entry room when footsteps are heard' do
      Flags.add('burgle-footsteps', 'Footsteps nearby')
      instance = build_instance
      drive_house(instance, [])
      allow(instance).to receive(:burgle_move) do |direction|
        house.move(direction)
        Flags['burgle-footsteps'] = true
      end

      instance.send(:map_house)

      expect(house).to be_at_entry_room
    end
  end

  # ---------------------------------------------------------------------------
  # rob_the_place_prioritized
  # ---------------------------------------------------------------------------

  describe '#rob_the_place_prioritized' do
    before(:each) do
      Flags.add('burgle-footsteps', 'Footsteps nearby')
      # Exit selection is `.sample`, so recon discovery order -- and therefore the order
      # build_search_queue emits rooms in -- is random in a branching house. Pin it to the
      # first unvisited exit so the queue is assertable. That yields a recon discovery order
      # of Kitchen, Bedroom, Library, Armory for branching_house.
      allow_any_instance_of(Array).to receive(:sample) { |exits| exits.first }
    end

    it 'searches the priority room before any other room' do
      instance = build_instance(
        prioritize_rooms: ['Armory'],
        burgle_settings: { 'max_search_count' => 1, 'room_blacklist' => [] }
      )
      searched = []
      drive_house(instance, searched)

      instance.send(:rob_the_place_prioritized)

      expect(searched).to eq(['rack'])
    end

    it 'searches priority rooms in discovery order, then the rest' do
      instance = build_instance(
        prioritize_rooms: %w[Armory Library],
        burgle_settings: { 'max_search_count' => 4, 'room_blacklist' => [] }
      )
      searched = []
      drive_house(instance, searched)

      instance.send(:rob_the_place_prioritized)

      expect(searched).to eq(%w[bookshelf rack counter bed])
    end

    it 'searches a farther listed-first room before a nearer listed-second one under inorder' do
      # Library is at [east] and Armory at [east, north], so 'any' would take Library first
      instance = build_instance(
        prioritize_rooms: %w[Armory Library],
        room_priority_type: 'inorder',
        burgle_settings: { 'max_search_count' => 4, 'room_blacklist' => [] }
      )
      searched = []
      drive_house(instance, searched)

      instance.send(:rob_the_place_prioritized)

      expect(searched).to eq(%w[rack bookshelf counter bed])
    end

    it 'spends a single search on the first listed room under inorder' do
      instance = build_instance(
        prioritize_rooms: %w[Armory Library],
        room_priority_type: 'inorder',
        burgle_settings: { 'max_search_count' => 1, 'room_blacklist' => [] }
      )
      searched = []
      drive_house(instance, searched)

      instance.send(:rob_the_place_prioritized)

      expect(searched).to eq(['rack'])
      expect(house).to be_at_entry_room
    end

    it 'skips blacklisted rooms entirely' do
      instance = build_instance(
        prioritize_rooms: ['Armory'],
        burgle_settings: { 'max_search_count' => 4, 'room_blacklist' => ['Kitchen'] }
      )
      searched = []
      drive_house(instance, searched)

      instance.send(:rob_the_place_prioritized)

      expect(searched).to eq(%w[rack bed bookshelf])
    end

    it 'stops searching once the search budget is spent' do
      instance = build_instance(
        prioritize_rooms: ['Armory'],
        burgle_settings: { 'max_search_count' => 2, 'room_blacklist' => [] }
      )
      searched = []
      drive_house(instance, searched)

      instance.send(:rob_the_place_prioritized)

      expect(searched.count).to eq(2)
    end

    it 'ends at the entry room after spending the whole budget' do
      instance = build_instance(
        prioritize_rooms: ['Armory'],
        burgle_settings: { 'max_search_count' => 1, 'room_blacklist' => [] }
      )
      drive_house(instance, [])

      instance.send(:rob_the_place_prioritized)

      expect(house).to be_at_entry_room
    end

    it 'ends at the entry room after searching every room' do
      instance = build_instance(
        prioritize_rooms: ['Armory'],
        burgle_settings: { 'max_search_count' => 99, 'room_blacklist' => [] }
      )
      drive_house(instance, [])

      instance.send(:rob_the_place_prioritized)

      expect(house).to be_at_entry_room
    end

    it 'searches nothing when footsteps abort the recon pass' do
      instance = build_instance(prioritize_rooms: ['Armory'])
      searched = []
      drive_house(instance, searched)
      allow(instance).to receive(:map_house) do
        Flags['burgle-footsteps'] = true
        {}
      end

      instance.send(:rob_the_place_prioritized)

      expect(searched).to be_empty
    end

    it 'returns to the entry room when footsteps interrupt the search pass' do
      instance = build_instance(
        prioritize_rooms: ['Armory'],
        burgle_settings: { 'max_search_count' => 99, 'room_blacklist' => [] }
      )
      searched = []
      drive_house(instance, searched)
      allow(instance).to receive(:search_for_loot) do |target|
        searched << target
        Flags['burgle-footsteps'] = true
      end

      instance.send(:rob_the_place_prioritized)

      expect(searched).to eq(['rack'])
      expect(house).to be_at_entry_room
    end
  end

  # ---------------------------------------------------------------------------
  # houses with cycles
  # ---------------------------------------------------------------------------

  #   Kitchen --east-- Bedroom
  #   (entry)     \       |
  #              south  southwest
  #                 \    |
  #                  Armory
  #
  # Every room reaches every other, so the recon walk comes back into rooms it has already
  # mapped. Without a guard that is an unbounded walk: paths get overwritten with longer ones
  # (including the entry room's own empty path), and the search pass then computes moves from a
  # wrong origin and walks into exits that do not exist.
  describe 'when the house contains a cycle' do
    let(:cyclic_rooms) do
      {
        'Kitchen' => { 'south' => 'Armory', 'east' => 'Bedroom' },
        'Armory'  => { 'north' => 'Kitchen', 'northeast' => 'Bedroom' },
        'Bedroom' => { 'west' => 'Kitchen', 'southwest' => 'Armory' }
      }
    end

    let(:house) { CyclicHouse.new(cyclic_rooms, 'Kitchen') }

    before(:each) do
      Flags.add('burgle-footsteps', 'Footsteps nearby')
      allow_any_instance_of(Array).to receive(:sample) { |exits| exits.first }
    end

    it 'maps every room to a path that leads to that room' do
      instance = build_instance(prioritize_rooms: ['Library'])
      drive_house(instance, [])

      map = instance.send(:map_house)

      expect(map.keys).to contain_exactly('Kitchen', 'Bedroom', 'Armory')
      map.each { |room, path| expect(house.room_at(path)).to eq(room) }
    end

    it 'keeps the entry room reachable by an empty path' do
      instance = build_instance(prioritize_rooms: ['Library'])
      drive_house(instance, [])

      expect(instance.send(:map_house)['Kitchen']).to eq([])
    end

    it 'maps each room once instead of walking the cycle repeatedly' do
      instance = build_instance(prioritize_rooms: ['Library'])
      drive_house(instance, [])

      instance.send(:map_house)

      # three rooms in a triangle: the two non-entry rooms are entered once each, and each of
      # the remaining exits is stepped through and backed out of once
      expect(house.moves.count).to be <= 10
      expect(house).to be_at_entry_room
    end

    it 'spends the whole search budget when no prioritized room is in the house' do
      instance = build_instance(
        prioritize_rooms: ['Library', 'Sanctum', 'Work Room'],
        room_priority_type: 'inorder',
        burgle_settings: { 'max_search_count' => 2, 'room_blacklist' => nil }
      )
      searched = []
      drive_house(instance, searched)

      instance.send(:rob_the_place_prioritized)

      expect(searched.count).to eq(2)
      expect(house).to be_at_entry_room
    end

    it 'still searches a prioritized room first' do
      instance = build_instance(
        prioritize_rooms: ['Armory'],
        room_priority_type: 'inorder',
        burgle_settings: { 'max_search_count' => 1, 'room_blacklist' => nil }
      )
      searched = []
      drive_house(instance, searched)

      instance.send(:rob_the_place_prioritized)

      expect(searched).to eq(['rack'])
      expect(house).to be_at_entry_room
    end
  end

  # ---------------------------------------------------------------------------
  # no prioritized room is present in the house
  # ---------------------------------------------------------------------------

  describe 'when none of the prioritized rooms are in the house' do
    before(:each) do
      Flags.add('burgle-footsteps', 'Footsteps nearby')
      allow_any_instance_of(Array).to receive(:sample) { |exits| exits.first }
    end

    it 'build_search_queue falls back to discovery order' do
      instance = build_instance(
        prioritize_rooms: ['Sanctum', 'Work Room'],
        room_priority_type: 'inorder'
      )
      map = { 'Kitchen' => [], 'Bedroom' => ['north'], 'Library' => ['east'], 'Armory' => %w[east north] }

      expect(instance.send(:build_search_queue, map)).to eq(%w[Kitchen Bedroom Library Armory])
    end

    it 'searches every room in discovery order' do
      instance = build_instance(
        prioritize_rooms: ['Sanctum', 'Work Room'],
        room_priority_type: 'inorder',
        burgle_settings: { 'max_search_count' => 4, 'room_blacklist' => [] }
      )
      searched = []
      drive_house(instance, searched)

      instance.send(:rob_the_place_prioritized)

      expect(searched).to eq(%w[counter bed bookshelf rack])
      expect(house).to be_at_entry_room
    end
  end

  # ---------------------------------------------------------------------------
  # search_the_place (dispatch)
  # ---------------------------------------------------------------------------

  describe '#search_the_place' do
    it 'uses the original walk when no rooms are prioritized' do
      instance = build_instance(prioritize_rooms: [])
      allow(instance).to receive(:rob_the_place)
      allow(instance).to receive(:rob_the_place_prioritized)

      instance.send(:search_the_place)

      expect(instance).to have_received(:rob_the_place)
      expect(instance).not_to have_received(:rob_the_place_prioritized)
    end

    it 'uses the prioritized walk when rooms are prioritized' do
      instance = build_instance(prioritize_rooms: ['Library'])
      allow(instance).to receive(:rob_the_place)
      allow(instance).to receive(:rob_the_place_prioritized)

      instance.send(:search_the_place)

      expect(instance).to have_received(:rob_the_place_prioritized)
      expect(instance).not_to have_received(:rob_the_place)
    end
  end

  # ---------------------------------------------------------------------------
  # stealth_inside
  #
  # These are the only specs that run the real burgle_move and search_for_loot bodies --
  # everywhere else drive_house stubs both out.
  # ---------------------------------------------------------------------------

  describe 'burgle_settings:stealth_inside' do
    let(:commands) { [] }

    before(:each) do
      $invisible = false
      Flags['burgle-footsteps'] = false
      allow(DRC).to receive(:bput) do |command, *_matches|
        commands << command
        "Someone Else's Home"
      end
    end

    after(:each) do
      $hidden = nil
      $invisible = nil
    end

    describe '#burgle_move' do
      before(:each) { $hidden = true }

      it 'sneaks between rooms when stealth_inside is on' do
        instance = build_instance(stealth_inside: true)

        instance.send(:burgle_move, 'north')

        expect(commands).to eq(['sneak north'])
      end

      it 'walks between rooms when stealth_inside is off' do
        instance = build_instance(stealth_inside: false)

        instance.send(:burgle_move, 'north')

        expect(commands).to eq(['north'])
      end

      it 'walks when stealth_inside is on but the search budget is spent' do
        # pre-existing behavior, unchanged by the flag
        instance = build_instance(stealth_inside: true, search_count: 2)

        instance.send(:burgle_move, 'north')

        expect(commands).to eq(['north'])
      end
    end

    describe '#search_for_loot' do
      before(:each) do
        # not hidden and not invisible, so the re-hide is the only thing that could hide us
        $hidden = false
        allow(DRC).to receive(:hide?).and_return(false)
      end

      it 'tries to hide before searching when stealth_inside is on' do
        instance = build_instance(stealth_inside: true)

        instance.send(:search_for_loot, 'bookshelf')

        expect(DRC).to have_received(:hide?)
        expect(messages).to include("Couldn't hide.  Searching to avoid delays.")
        expect(commands).to eq(['search bookshelf'])
      end

      it 'searches without hiding when stealth_inside is off' do
        instance = build_instance(stealth_inside: false)

        instance.send(:search_for_loot, 'bookshelf')

        expect(DRC).not_to have_received(:hide?)
        expect(messages).to be_empty
        expect(commands).to eq(['search bookshelf'])
      end

      it 'consumes search budget either way' do
        instance = build_instance(stealth_inside: false)

        instance.send(:search_for_loot, 'bookshelf')

        expect(instance.instance_variable_get(:@search_count)).to eq(1)
      end
    end
  end
end
