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
  # Replies that match send_use's patterns for an exhale and a gaze.
  let(:exhale_ok) { 'you come away from the experience with a further understanding of Arcana as the scintillating lights fade again.' }
  let(:gaze_ok) { 'A soft light blossoms in the very center of the crystal, and begins to fill your mind with the knowledge of Arcana.' }
  # Every gaze and exhale send_use puts, in order.
  let(:uses) { [] }

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
      c.instance_variable_set(:@suggested_no_use_entries, [])
      c.instance_variable_set(:@force_exhale, false)
      c.instance_variable_set(:@worn_crystal, true)
    end
  end

  before do
    DRStats.concentration = 100
    DRSkill._set_xp('Arcana', 0)
    # A reply that matches nothing ends send_use's read at once instead of after 15 s.
    stub_const('SanowretCrystal::USE_REPLY_SECONDS', 0.05)
    answer_uses
  end

  # send_use puts gaze and exhale itself and reads the reply with get?. Each one is
  # recorded in uses and answered by the block (given the command), or by a success.
  def answer_uses(&reply)
    reply ||= ->(command) { command.start_with?('gaze') ? gaze_ok : exhale_ok }
    pending = []
    allow(crystal).to receive(:clear)
    allow(crystal).to receive(:put) do |command|
      uses << command
      pending << reply.call(command)
    end
    allow(crystal).to receive(:get?) { pending.shift }
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
    before { answer_uses { refusal } }

    it 'still uses the crystal in a different room' do
      in_room('[[Crossing, Market]]')
      crystal.check_crystal

      in_room('[[Shard, Bank]]')
      crystal.check_crystal

      expect(uses.size).to eq(2)
    end

    it 'skips the refusing room for the rest of the run' do
      in_room('[[Crossing, Market]]')
      crystal.check_crystal
      crystal.check_crystal

      expect(uses.size).to eq(1)
    end

    it 'does not skip a room whose title only shares characters or a prefix with it' do
      in_room('[[Crossing, Market]]')
      crystal.check_crystal

      in_room('[[Crossing, Market Plaza]]')
      crystal.check_crystal

      expect(uses.size).to eq(2)
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

  # The character can move while the exhale or gaze is out. The refusal may then be
  # about either room, so the room it arrives in must not be ruled out on its strength.
  describe 'when the character moves before a refusal of the crystal arrives' do
    before do
      allow(DRC).to receive(:message)
      in_room('[[Crossing, Market]]', id: 10)
    end

    def refuse_after_moving_to(title, id)
      answer_uses do
        in_room(title, id: id)
        refusal
      end
    end

    it 'neither remembers nor suggests the room it arrived in' do
      refuse_after_moving_to('[[Crossing, Square]]', 11)

      crystal.use_crystal

      expect(crystal.instance_variable_get(:@refused_room_titles)).to be_empty
      expect(DRC).not_to have_received(:message)
    end

    it 'uses the crystal in the arrival room on the next pass' do
      refuse_after_moving_to('[[Crossing, Square]]', 11)
      crystal.check_crystal
      answer_uses

      crystal.check_crystal

      expect(uses.size).to eq(2)
    end

    it 'also leaves an unmapped arrival room usable' do
      refuse_after_moving_to('[[Ruins, Hall]]', nil)

      crystal.use_crystal

      expect(crystal.instance_variable_get(:@refused_room_titles)).to be_empty
    end
  end

  # ===========================================================================
  # Replies DRC.bput would answer by sending the command again
  # ===========================================================================
  # DRC.bput sends again after a roundtime wait (and a few other replies) without
  # asking skip_use?, so a go2 started during the wait couldn't stop it. send_use
  # asks before every send.
  describe 'when a gaze is answered by a reply DRC.bput would send it again after' do
    let(:wait_reply) { '...wait 3 seconds.' }
    let(:replies) { [] }

    before do
      in_room('[[Crossing, Market]]', id: 10)
      allow(crystal).to receive(:pause)
      allow(DRC).to receive(:fix_standing)
      answer_uses { replies.shift.then { |reply| reply.respond_to?(:call) ? reply.call : reply } }
    end

    it 'does not send again once a sanowret_no_use_scripts script starts during the wait' do
      crystal.instance_variable_set(:@no_use_scripts, ['go2'])
      allow(Script).to receive(:running?).with('go2').and_return(false)
      go2_starts = lambda do
        allow(Script).to receive(:running?).with('go2').and_return(true)
        wait_reply
      end
      replies.push(go2_starts, gaze_ok)

      crystal.use_crystal

      expect(uses).to eq(['gaze my sanowret crystal'])
    end

    it 'does not send again once the character has moved into a no-use room during the wait' do
      walks_into_bank = lambda do
        in_room('[[Provincial Bank, Teller]]', id: 1900)
        wait_reply
      end
      replies.push(walks_into_bank, gaze_ok)

      crystal.use_crystal

      expect(uses).to eq(['gaze my sanowret crystal'])
    end

    it 'waits out the roundtime and sends again when nothing has changed' do
      replies.push(wait_reply, gaze_ok)

      crystal.use_crystal

      expect(uses).to eq(['gaze my sanowret crystal'] * 2)
      expect(crystal).to have_received(:pause).with(3)
    end

    it 'pauses a second and sends again after a type-ahead refusal' do
      replies.push('Sorry, you may only type ahead 1 command.', gaze_ok)

      crystal.use_crystal

      expect(uses).to eq(['gaze my sanowret crystal'] * 2)
      expect(crystal).to have_received(:pause).with(1)
    end

    it 'stands and sends again when told to stand' do
      replies.push('You must be standing to do that.', gaze_ok)

      crystal.use_crystal

      expect(DRC).to have_received(:fix_standing)
      expect(uses).to eq(['gaze my sanowret crystal'] * 2)
    end

    it 'leaves the crystal for a later pass when webbed, without sending again' do
      replies.push("You can't do that while entangled in a web.")

      crystal.use_crystal

      expect(uses).to eq(['gaze my sanowret crystal'])
    end

    it 'gives up after USE_SENDS sends that each draw a wait' do
      replies.push(*([wait_reply] * 5))

      crystal.use_crystal

      expect(uses.size).to eq(described_class::USE_SENDS)
    end

    it 'remembers a room that refuses the send made there after a wait' do
      walks_on = lambda do
        in_room('[[Crossing, Square]]', id: 11)
        wait_reply
      end
      replies.push(walks_on, refusal)

      crystal.use_crystal

      expect(crystal.instance_variable_get(:@refused_room_titles)).to eq(['[[Crossing, Square]]'])
    end
  end

  describe 'when the crystal works' do
    it 'does not remember the room' do
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
  # Moving into a no-use room before the crystal is used
  # ===========================================================================
  # check_crystal checks the room before it taps, but getting a stowed crystal takes
  # round trips, and the character can walk on meanwhile (go2 under another script).
  # A check made only before the tap would let the crystal be exhaled in any no-use
  # room the character reached during those round trips, such as the Crossing bank
  # teller room (1900, in base.yaml).
  describe 'when the character moves into a no-use room before the crystal is used' do
    let(:stowed) do
      crystal.tap { |c| c.instance_variable_set(:@worn_crystal, false) }
    end

    before do
      allow(DRC).to receive(:message)
      allow(DRC).to receive(:bput).with('tap my sanowret crystal', any_args)
                                  .and_return('You tap a sanowret crystal inside your leather backpack.')
      # The character arrives somewhere else while the get is in flight.
      allow(DRC).to receive(:bput).with('get my sanowret crystal', any_args) do
        @arrival.call
        'You get'
      end
      allow(DRC).to receive(:bput).with('stow my sanowret crystal', any_args).and_return('You put')
      in_room('[[Crossing, Market]]', id: 10)
    end

    it 'does not exhale in a room listed by id' do
      @arrival = -> { in_room('[[Provincial Bank, Teller]]', id: 1900) }

      stowed.check_crystal

      expect(uses).to be_empty
      expect(DRC).to have_received(:bput).with('stow my sanowret crystal', any_args)
      expect(DRC).not_to have_received(:message).with(/Could not use crystal/)
    end

    it 'does not exhale in a room matching a !ruby/regexp entry' do
      @arrival = -> { in_room('[[Asemath Academy, Library]]', id: 20) }

      stowed.check_crystal

      expect(uses).to be_empty
    end

    it 'does not exhale once a sanowret_no_use_scripts script has started' do
      stowed.instance_variable_set(:@no_use_scripts, ['go2'])
      allow(Script).to receive(:running?).with('go2').and_return(false)
      @arrival = -> { allow(Script).to receive(:running?).with('go2').and_return(true) }

      stowed.check_crystal

      expect(uses).to be_empty
    end

    it 'does not gaze into a worn crystal in a no-use room' do
      in_room('[[Provincial Bank, Teller]]', id: 1900)

      crystal.use_crystal

      expect(uses).to be_empty
    end

    it 'still exhales when the new room is not a no-use room' do
      @arrival = -> { in_room('[[Crossing, Square]]', id: 11) }

      stowed.check_crystal

      expect(uses).to eq(['exhale my sanowret crystal'])
      expect(DRC).to have_received(:bput).with('stow my sanowret crystal', any_args)
    end
  end

  # ===========================================================================
  # A stowed crystal and no free hand to get it with
  # ===========================================================================
  # It used to pause until a hand came free, without a limit: a single run (which
  # crossing-training waits on) never ended, and the passive loop stopped with it.
  describe 'with a stowed crystal and both hands full' do
    let(:stowed) do
      crystal.tap do |c|
        c.instance_variable_set(:@worn_crystal, false)
        # A wait for a free hand fails the example instead of hanging the suite.
        allow(c).to receive(:pause) { raise 'waited for a free hand' }
      end
    end
    let(:exhale) { /\A(?:exhale|gaze) / }

    def hands(left, right)
      allow(DRC).to receive(:left_hand).and_return(left)
      allow(DRC).to receive(:right_hand).and_return(right)
    end

    before do
      allow(DRC).to receive(:message)
      allow(DRCI).to receive(:in_hands?).and_return(false)
      allow(DRC).to receive(:bput).with('tap my sanowret crystal', any_args)
                                  .and_return('You tap a sanowret crystal inside your leather backpack.')
      allow(DRC).to receive(:bput).with('get my sanowret crystal', any_args).and_return('You get')
      allow(DRC).to receive(:bput).with('stow my sanowret crystal', any_args).and_return('You put')
      allow(DRC).to receive(:bput).with(exhale, any_args).and_return('fade again.')
      hands('steel shield', 'steel sword')
      in_room('[[Crossing, Market]]', id: 10)
    end

    it 'returns without waiting, getting, using or stowing the crystal' do
      stowed.check_crystal

      expect(DRC).not_to have_received(:bput).with('get my sanowret crystal', any_args)
      expect(DRC).not_to have_received(:bput).with(exhale, any_args)
      expect(DRC).not_to have_received(:bput).with('stow my sanowret crystal', any_args)
    end

    it 'says why in a single run' do
      stowed.instance_variable_set(:@run_once, true)

      stowed.check_crystal

      expect(DRC).to have_received(:message).with('Both hands are full, so the sanowret crystal stays stowed.')
    end

    it 'stays quiet in the passive loop, which tries again on its next pass' do
      stowed.check_crystal

      expect(DRC).not_to have_received(:message)
    end

    it 'does not tap again on later passes while both hands stay full' do
      3.times { stowed.check_crystal }

      expect(DRC).to have_received(:bput).with('tap my sanowret crystal', any_args).once
    end

    it 'gets, uses and stows the crystal on the first pass after a hand comes free' do
      stowed.check_crystal
      hands(nil, 'steel sword')

      stowed.check_crystal

      expect(DRC).to have_received(:bput).with('tap my sanowret crystal', any_args).twice
      expect(DRC).to have_received(:bput).with('get my sanowret crystal', any_args).once
      expect(DRC).to have_received(:bput).with('exhale my sanowret crystal', any_args).once
      expect(DRC).to have_received(:bput).with('stow my sanowret crystal', any_args).once
    end

    it 'taps a crystal that is now held, though both hands are full' do
      stowed.check_crystal
      allow(DRCI).to receive(:in_hands?).with('sanowret crystal').and_return(true)
      allow(DRC).to receive(:bput).with('tap my sanowret crystal', any_args)
                                  .and_return('You tap a sanowret crystal that you are holding.')

      stowed.check_crystal

      expect(DRC).to have_received(:bput).with('exhale my sanowret crystal', any_args).once
    end

    it 'ends a single run started with both hands full' do
      settings = OpenStruct.new(sanowret_adjective: 'sanowret', sanowret_no_use_scripts: [], sanowret_no_use_rooms: [],
                                sanowret_force_exhale: false, ephemeron: nil)
      allow_any_instance_of(described_class).to receive(:get_settings).and_return(settings)
      allow_any_instance_of(described_class).to receive(:parse_args).and_return(OpenStruct.new(run: 'run'))
      allow_any_instance_of(described_class).to receive(:pause) { raise 'waited for a free hand' }
      DRSkill._set_rank('Arcana', 100)

      described_class.new

      expect(DRC).to have_received(:message).with('Both hands are full, so the sanowret crystal stays stowed.')
    end
  end

  describe 'when the get fails' do
    let(:stowed) do
      crystal.tap { |c| c.instance_variable_set(:@worn_crystal, false) }
    end

    before do
      allow(DRC).to receive(:bput).with('tap my sanowret crystal', any_args)
                                  .and_return('You tap a sanowret crystal inside your leather backpack.')
      allow(DRC).to receive(:bput).with('stow my sanowret crystal', any_args).and_return('You put')
      allow(DRC).to receive(:bput).with(/\A(?:exhale|gaze) /, any_args).and_return('fade again.')
      in_room('[[Crossing, Market]]', id: 10)
    end

    ['You need a free hand', 'What were you referring to'].each do |reply|
      it "neither uses nor stows the crystal after \"#{reply}\"" do
        allow(DRC).to receive(:bput).with('get my sanowret crystal', any_args).and_return(reply)

        stowed.check_crystal

        expect(DRC).not_to have_received(:bput).with(/\A(?:exhale|gaze) /, any_args)
        expect(DRC).not_to have_received(:bput).with('stow my sanowret crystal', any_args)
      end
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

    # A refusal that never lifts would otherwise cost a tap every pass (every ~14 s
    # under crossing-training), so point at the setting check_crystal honours.
    # Conditional, since a refusal might only be temporary.
    { 'a mapped room' => [10, 'room id 10'], 'an unmapped room' => [nil, "'Ruins, Hall'"] }.each do |label, (id, entry)|
      it "suggests sanowret_no_use_rooms by #{id ? 'room id' : 'bracket-stripped title'} in #{label}" do
        in_room('[[Ruins, Hall]]', id: id)
        on_pause(tapper)

        tapper.check_crystal

        expect(DRC).to have_received(:message)
          .with("If this room always refuses the crystal, add #{entry} to your sanowret_no_use_rooms settings.")
      end
    end

    # The passive loop taps again after each 5-minute wait. Repeating the same
    # suggestion every time tells the player nothing new.
    describe 'the sanowret_no_use_rooms suggestion in the passive loop' do
      let(:hint) { /\AIf this room always refuses the crystal, add / }

      def hints_for(entry)
        "If this room always refuses the crystal, add #{entry} to your sanowret_no_use_rooms settings."
      end

      it 'is given once however many times a mapped room refuses' do
        in_room('[[Crossing, Market]]', id: 10)
        on_pause(tapper)

        3.times { tapper.check_crystal }

        expect(DRC).to have_received(:bput).exactly(3).times
        expect(DRC).to have_received(:message).with(hints_for('room id 10')).once
        expect(DRC).to have_received(:message)
          .with('Pausing test-script script until you move to another room, for up to 5 minutes.').exactly(3).times
      end

      it 'is given once in an unmapped room, even when its description changes between passes' do
        in_unmapped_room('[[Ruins, Hall]]', 'Dust drifts.')
        on_pause(tapper, 1 => -> { in_unmapped_room('[[Ruins, Hall]]', 'Dust settles.') })

        tapper.check_crystal
        tapper.check_crystal

        expect(DRC).to have_received(:bput).twice
        expect(DRC).to have_received(:message).with(hints_for("'Ruins, Hall'")).once
      end

      it 'is given again for each new refusing room' do
        in_room('[[Crossing, Market]]', id: 10)
        on_pause(tapper, 1 => -> { in_room('[[Crossing, Bank]]', id: 11) })

        tapper.check_crystal
        tapper.check_crystal
        in_room('[[Crossing, Market]]', id: 10)
        tapper.check_crystal

        expect(DRC).to have_received(:message).with(hint).twice
        expect(DRC).to have_received(:message).with(hints_for('room id 10')).once
        expect(DRC).to have_received(:message).with(hints_for('room id 11')).once
      end
    end

    # The character can move while the tap is out. The arrival room may take the
    # crystal, and the move the wait is for has already happened.
    describe 'after moving while the tap was out' do
      before do
        in_room('[[Crossing, Market]]', id: 10)
        allow(DRC).to receive(:bput) do
          in_room('[[Crossing, Square]]', id: 11)
          tap_refusal
        end
        on_pause(tapper)
      end

      it 'neither suggests the arrival room nor waits there' do
        tapper.check_crystal

        expect(pauses).to be_empty
        expect(DRC).not_to have_received(:message)
      end

      it 'says nothing about this room in a single run' do
        tapper.instance_variable_set(:@run_once, true)

        tapper.check_crystal

        expect(DRC).not_to have_received(:message)
      end
    end

    it 'skips the room on the next pass once the suggested room id is in sanowret_no_use_rooms' do
      in_room('[[Crossing, Market]]', id: 10)
      on_pause(tapper)
      tapper.check_crystal
      tapper.instance_variable_set(:@no_use_rooms, [10])

      tapper.check_crystal

      expect(DRC).to have_received(:bput).once
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

      it 'suggests sanowret_no_use_rooms so a refusing room stops costing a tap every run' do
        in_room('[[Crossing, Market]]', id: 10)
        on_pause(tapper)

        tapper.check_crystal

        expect(DRC).to have_received(:message)
          .with('If this room always refuses the crystal, add room id 10 to your sanowret_no_use_rooms settings.')
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
