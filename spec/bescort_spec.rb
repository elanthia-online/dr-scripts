# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('bescort.lic', 'Bescort')

RSpec.describe Bescort do
  let(:equipment_manager) { instance_double(Harness::EquipmentManager, empty_hands: nil) }
  let(:gear_sets) { { 'standard' => ['steel shield'], 'swimming' => ['seal cloak'] } }
  let(:flying_mount) { nil }
  let(:bescort) do
    described_class.allocate.tap do |b|
      b.instance_variable_set(:@settings, OpenStruct.new(gear_sets: gear_sets))
      b.instance_variable_set(:@equipment_manager, equipment_manager)
      b.instance_variable_set(:@flying_mount, flying_mount)
    end
  end

  before(:each) do
    reset_data
    allow(DRC).to receive(:message)
    allow(DRC).to receive(:bput).and_return('')
    allow(DRCT).to receive(:walk_to)
    allow(DRCMM).to receive(:check_moonwatch).and_return(true)
  end

  # Records every gear set worn, answering each with the given result.
  def wear_sets_returning(results)
    worn = []
    allow(equipment_manager).to receive(:wear_equipment_set?) do |set_name|
      worn << set_name
      results.fetch(set_name)
    end
    worn
  end

  describe '#wear_swimming_gear?' do
    context 'when the swimming set is configured' do
      it 'is true when the swimming set was worn' do
        worn = wear_sets_returning('swimming' => true)
        expect(bescort.send(:wear_swimming_gear?)).to be(true)
        expect(worn).to eq(['swimming'])
      end

      it 'is true when wearing the swimming set failed, since standard gear may already be off' do
        worn = wear_sets_returning('swimming' => false)
        expect(bescort.send(:wear_swimming_gear?)).to be(true)
        expect(worn).to eq(['swimming'])
      end

      it 'is true when wear_equipment_set? returns nil' do
        wear_sets_returning('swimming' => nil)
        expect(bescort.send(:wear_swimming_gear?)).to be(true)
      end

      context 'as an empty list' do
        let(:gear_sets) { { 'standard' => ['steel shield'], 'swimming' => [] } }

        it 'is true, since wearing an empty set takes everything else off' do
          wear_sets_returning('swimming' => true)
          expect(bescort.send(:wear_swimming_gear?)).to be(true)
        end
      end
    end

    context 'when the swimming set is not configured' do
      [
        ['no gear_sets at all', nil],
        ['gear_sets without a swimming key', { 'standard' => ['steel shield'] }],
        ['a swimming key with no value', { 'standard' => ['steel shield'], 'swimming' => nil }]
      ].each do |label, sets|
        context "with #{label}" do
          let(:gear_sets) { sets }

          it 'still asks for the swimming set (which reports it missing) and is false' do
            worn = wear_sets_returning('swimming' => false)
            expect(bescort.send(:wear_swimming_gear?)).to be(false)
            expect(worn).to eq(['swimming'])
          end
        end
      end
    end

    context 'with a flying mount' do
      let(:flying_mount) { 'broom' }

      it 'is false and changes no gear' do
        expect(equipment_manager).not_to receive(:wear_equipment_set?)
        expect(bescort.send(:wear_swimming_gear?)).to be(false)
      end
    end
  end

  describe '#cave_trolls' do
    before do
      allow(bescort).to receive(:manual_go2)
      allow(bescort).to receive(:move)
      allow(bescort).to receive(:swim)
      allow(bescort).to receive(:use_flying_mount)
    end

    it 'puts the standard set back on after a swim whose swimming set failed' do
      worn = wear_sets_returning('swimming' => false, 'standard' => true)
      bescort.send(:cave_trolls, 'enter')
      expect(worn).to eq(%w[swimming standard])
    end

    it 'puts the standard set back on after a successful change' do
      worn = wear_sets_returning('swimming' => true, 'standard' => true)
      bescort.send(:cave_trolls, 'exit')
      expect(worn).to eq(%w[swimming standard])
    end

    it 'puts the standard set back on before leaving the stream' do
      calls = []
      allow(equipment_manager).to receive(:wear_equipment_set?) do |set_name|
        calls << "wear #{set_name}"
        set_name == 'standard'
      end
      allow(bescort).to receive(:swim) { |dir| calls << "swim #{dir}" }
      allow(bescort).to receive(:move) { |command| calls << command }
      bescort.send(:cave_trolls, 'enter')
      expect(calls).to eq(['go stream bank', 'wear swimming', 'swim southeast', 'swim southeast', 'swim southeast',
                           'wear standard', 'go stream bank'])
    end

    context 'without a swimming set' do
      let(:gear_sets) { { 'standard' => ['steel shield'] } }

      it 'leaves the worn gear alone afterwards' do
        worn = wear_sets_returning('swimming' => false)
        bescort.send(:cave_trolls, 'enter')
        expect(worn).to eq(['swimming'])
      end
    end

    context 'with a flying mount' do
      let(:flying_mount) { 'broom' }

      it 'changes no gear' do
        expect(equipment_manager).not_to receive(:wear_equipment_set?)
        bescort.send(:cave_trolls, 'enter')
      end
    end
  end

  describe '#segoltha' do
    before do
      allow(bescort).to receive(:move)
      allow(bescort).to receive(:echo)
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: 19_373))
      # No exit to swim toward: the swim loop ends at once.
      allow(XMLData).to receive(:room_exits).and_return(%w[east up out])
    end

    it 'puts the standard set back on after a swim whose swimming set failed' do
      worn = wear_sets_returning('swimming' => false, 'standard' => true)
      bescort.send(:segoltha, 'north')
      expect(worn).to eq(%w[swimming standard])
    end

    context 'without a swimming set' do
      let(:gear_sets) { nil }

      it 'leaves the worn gear alone afterwards' do
        worn = wear_sets_returning('swimming' => false)
        bescort.send(:segoltha, 'north')
        expect(worn).to eq(['swimming'])
      end
    end

    it 'empties hands at the start room before wearing the swimming set' do
      calls = []
      allow(equipment_manager).to receive(:empty_hands) { calls << 'empty hands' }
      allow(Room).to receive(:current) do
        calls << 'start room check'
        OpenStruct.new(id: 19_373)
      end
      allow(equipment_manager).to receive(:wear_equipment_set?) do |set_name|
        calls << "wear #{set_name}"
        true
      end
      bescort.send(:segoltha, 'north')
      expect(calls.first(3)).to eq(['start room check', 'empty hands', 'wear swimming'])
    end

    it 'puts the standard set back on after the swim loop, not before' do
      calls = []
      allow(equipment_manager).to receive(:wear_equipment_set?) do |set_name|
        calls << "wear #{set_name}"
        true
      end
      allow(XMLData).to receive(:room_exits) do
        calls << 'exits'
        %w[east up out]
      end
      bescort.send(:segoltha, 'north')
      expect(calls.first).to eq('wear swimming')
      expect(calls.last).to eq('wear standard')
      expect(calls).to include('exits')
    end

    context 'when not at the start room' do
      before { allow(Room).to receive(:current).and_return(OpenStruct.new(id: 1)) }

      it 'exits without emptying hands or changing gear, so there is nothing to put back' do
        expect(bescort).to receive(:echo).with(/Must start bescort in room 19373/)
        expect(equipment_manager).not_to receive(:empty_hands)
        expect(equipment_manager).not_to receive(:wear_equipment_set?)
        expect { bescort.send(:segoltha, 'north') }.to raise_error(SystemExit)
      end
    end

    context 'with a mode that is not a direction' do
      it 'exits without emptying hands or changing gear' do
        expect(equipment_manager).not_to receive(:empty_hands)
        expect(equipment_manager).not_to receive(:wear_equipment_set?)
        expect { bescort.send(:segoltha, 'east') }.to raise_error(SystemExit)
      end
    end

    context 'with a flying mount' do
      let(:flying_mount) { 'broom' }

      it 'empties hands and mounts without changing gear or checking the start room' do
        allow(Room).to receive(:current).and_return(OpenStruct.new(id: 1))
        expect(equipment_manager).to receive(:empty_hands).ordered
        expect(bescort).to receive(:use_flying_mount).with('broom', 'mount', 'skim').ordered
        expect(bescort).to receive(:use_flying_mount).with('broom', 'dismount').ordered
        expect(equipment_manager).not_to receive(:wear_equipment_set?)
        bescort.send(:segoltha, 'north')
      end

      {
        'broom'           => 'skim',
        'dirigible'       => 'skim',
        'magic carpet'    => 'skim',
        'Rug'             => 'skim',
        'cloud'           => 'hover',
        'phoenix feather' => 'fly',
        'spire'           => 'storm'
      }.each do |mount, speed|
        context "of type #{mount}" do
          let(:flying_mount) { mount }

          it "mounts at #{speed} speed" do
            allow(equipment_manager).to receive(:empty_hands)
            expect(bescort).to receive(:use_flying_mount).with(mount, 'mount', speed).ordered
            expect(bescort).to receive(:use_flying_mount).with(mount, 'dismount').ordered
            bescort.send(:segoltha, 'south')
          end
        end
      end
    end

    context 'with a flying mount of an unknown type' do
      let(:flying_mount) { 'pogo stick' }

      it 'exits without emptying hands, mounting or changing gear' do
        expect(DRC).to receive(:message).with('pogo stick is not a valid type of flying mount.')
        expect(equipment_manager).not_to receive(:empty_hands)
        expect(bescort).not_to receive(:use_flying_mount)
        expect(equipment_manager).not_to receive(:wear_equipment_set?)
        expect { bescort.send(:segoltha, 'north') }.to raise_error(SystemExit)
      end
    end
  end

  describe '#sun_up?' do
    it 'is true by day' do
      UserVars.sun = { 'running' => true, 'day' => true }
      expect(bescort.send(:sun_up?)).to be(true)
    end

    it 'is false by night' do
      UserVars.sun = { 'running' => true, 'day' => false }
      expect(bescort.send(:sun_up?)).to be(false)
    end

    it 'accepts data from a moonwatch without the running key' do
      UserVars.sun = { 'day' => false }
      expect(bescort.send(:sun_up?)).to be(false)
    end

    it 'accepts a check_moonwatch that returns nil (lich versions before it returned a result)' do
      allow(DRCMM).to receive(:check_moonwatch).and_return(nil)
      UserVars.sun = { 'running' => true, 'day' => true }
      expect(bescort.send(:sun_up?)).to be(true)
    end

    it 'is nil without reading the sun data when check_moonwatch returns false' do
      allow(DRCMM).to receive(:check_moonwatch).and_return(false)
      expect(UserVars).not_to receive(:sun)
      expect(bescort.send(:sun_up?)).to be_nil
    end

    it 'waits for a freshly started moonwatch to write the sun data' do
      states = [nil, {}, { 'running' => true }, { 'running' => true, 'day' => false }]
      allow(UserVars).to receive(:sun) { states.length > 1 ? states.shift : states.first }
      expect(bescort).to receive(:pause).with(described_class::SUN_DATA_POLL_INTERVAL).exactly(3).times
      expect(bescort.send(:sun_up?)).to be(false)
    end

    [
      ['never written', nil],
      ['an empty hash', {}],
      ['left over from a stopped moonwatch', { 'running' => false, 'day' => true }],
      ['a day that is not true or false', { 'running' => true, 'day' => 'yes' }],
      ['a day that is missing', { 'running' => true, 'timer' => 12 }]
    ].each do |label, sun|
      it "gives up after a bounded wait when the sun data is #{label}" do
        UserVars.sun = sun
        polls = (described_class::SUN_DATA_TIMEOUT / described_class::SUN_DATA_POLL_INTERVAL).ceil
        expect(bescort).to receive(:pause).with(described_class::SUN_DATA_POLL_INTERVAL).exactly(polls).times
        expect(bescort.send(:sun_up?)).to be_nil
      end
    end
  end

  describe '#coffin' do
    # Game replies for one solve with the boar image: the black wheel shows
    # the dark image on the second look, the white wheel the light image at once.
    let(:replies) { { 'look sunlight' => 'boar', 'look starlight' => 'boar' } }

    before do
      allow(bescort).to receive(:pause)
      allow(equipment_manager).to receive(:empty_hands)
      black_looks = 0
      allow(DRC).to receive(:bput) do |command, *matches|
        case command
        when 'look wooden wheel'
          if matches.include?('berserking barbarian')
            black_looks += 1
            black_looks > 1 ? 'berserking barbarian' : 'grimacing woman'
          else
            'longbow'
          end
        when 'pull iron lever' then 'Roundtime'
        else replies.fetch(command, '')
        end
      end
    end

    context 'when moonwatch cannot provide its data' do
      before { allow(DRCMM).to receive(:check_moonwatch).and_return(false) }

      it 'stops with a message before walking anywhere' do
        expect(DRCT).not_to receive(:walk_to)
        expect(DRC).to receive(:message).with(/moonwatch has not said whether the sun is up/)
        expect { bescort.send(:coffin) }.to raise_error(SystemExit)
      end
    end

    context 'when the sun data never arrives' do
      it 'stops with a message before walking anywhere' do
        UserVars.sun = {}
        expect(DRCT).not_to receive(:walk_to)
        expect(DRC).to receive(:message).with(/moonwatch has not said whether the sun is up/)
        expect { bescort.send(:coffin) }.to raise_error(SystemExit)
      end
    end

    it 'looks at the sunlight by day and solves the puzzle' do
      UserVars.sun = { 'running' => true, 'day' => true }
      bescort.send(:coffin)
      expect(DRC).to have_received(:bput).with('look sunlight', any_args)
      expect(DRC).to have_received(:bput).with('pull rope', any_args).once
      expect(DRC).to have_received(:bput).with('go coffin', any_args)
    end

    it 'looks at the starlight by night' do
      UserVars.sun = { 'running' => true, 'day' => false }
      bescort.send(:coffin)
      expect(DRC).to have_received(:bput).with('look starlight', any_args)
      expect(DRC).not_to have_received(:bput).with('look sunlight', any_args)
    end

    it 'matches the image whatever its case' do
      UserVars.sun = { 'running' => true, 'day' => true }
      replies['look sunlight'] = 'Boar'
      bescort.send(:coffin)
      expect(DRC).to have_received(:bput).with('go coffin', any_args)
    end

    [
      ['the look finds nothing', 'I could not find what'],
      ['the look gets no matching reply', '']
    ].each do |label, reply|
      it "stops instead of turning the wheels forever when #{label}" do
        UserVars.sun = { 'running' => true, 'day' => true }
        replies['look sunlight'] = reply
        expect(DRC).to receive(:message).with(/found no image when looking at the sunlight/)
        expect { bescort.send(:coffin) }.to raise_error(SystemExit)
        expect(DRC).not_to have_received(:bput).with('look wooden wheel', any_args)
        expect(DRC).not_to have_received(:bput).with('pull rope', any_args)
      end
    end
  end

  describe 'transport, maze and passport lines' do
    # Other players' ESP, speech and whispers carrying the same text, as stripped
    # text (what waitfor, bput and reget read) and as raw XML (what Flags read).
    def player_text_lines(text)
      [%([General][Mallory] "#{text}"), %(Mallory says, "#{text}"), %(Mallory whispers, "#{text}")]
    end

    def player_xml_lines(text)
      [%(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
       %(<preset id='speech'>Mallory says</preset>, "#{text}")] + player_text_lines(text)
    end

    # Lich's waitfor: joins the strings into one case-insensitive regex and returns
    # the first incoming line that matches it. Returns the lines that ended a wait.
    def waitfor_reads(lines)
      ended_on = []
      queue = lines.dup
      allow(bescort).to receive(:waitfor) do |*strings|
        regex = /#{strings.flatten.join('|')}/i
        line = nil
        until line&.match?(regex)
          raise 'waitfor would wait forever' if queue.empty?

          line = queue.shift
        end
        ended_on << line
        line
      end
      ended_on
    end

    # Lich's DRC.bput: Strings become case-insensitive regexes, and the first line
    # that matches any of them, in order, returns the matched text.
    def bput_reads(command, lines)
      allow(DRC).to receive(:bput).with(command, any_args) do |_command, *matches|
        regexes = matches.map { |m| m.is_a?(Regexp) ? m : /#{m}/i }
        lines.lazy.filter_map { |line| regexes.filter_map { |regex| line.match(regex)&.to_a&.first }.first }.first || ''
      end
    end

    # Feed a server line through the registered Flags matchers, the way
    # Lich's DRParser.check_events does for every downstream line.
    def deliver(line)
      Flags.matchers.each do |key, regexes|
        regexes.each do |regex|
          if (match = line.match(regex))
            Flags[key] = match
            break
          end
        end
      end
    end

    def at_room(*ids)
      allow(Room).to receive(:current).and_return(*ids.map { |id| double('room', id: id) })
    end

    before do
      allow(bescort).to receive(:hide?).and_return(false)
      allow(bescort).to receive(:move)
      allow(bescort).to receive(:pause)
      allow(bescort).to receive(:manual_go2)
      allow(bescort).to receive(:echo)
      allow(DRCM).to receive(:wealth).and_return(10_000)
    end

    describe 'waiting aboard a transport' do
      it 'stays aboard the Jolas until the captain ties off' do
        real = 'The captain barks the order to tie off the Jolas to the docks.'
        ended_on = waitfor_reads(player_text_lines(real) + [real])
        at_room(6542)
        DRRoom.room_objs = ['The Jolas', 'Sumilo Dock']
        expect { bescort.send(:jolas, 'harajaal') }.to raise_error(SystemExit)
        expect(ended_on).to eq([real])
        expect(bescort).to have_received(:move).with('go dock')
      end

      [['hvaral', 'The sand barge pulls into dock.', 'go dock'],
       ['oasis', 'The sand barge pulls up to a desert oasis.', 'go oasis']].each do |stop, real, exit_move|
        it "stays on the sand barge until it reaches #{stop}" do
          ended_on = waitfor_reads(player_text_lines(real) + [real])
          allow(DRC).to receive(:bput).with('go barge', any_args).and_return("One of the barge's crew members watching")
          bescort.send(:take_sandbarge, 'muspari', stop)
          expect(ended_on).to eq([real])
          expect(bescort).to have_received(:move).with(exit_move)
        end
      end

      it 'waits for a sand barge to arrive before boarding again' do
        arrive = 'A sand barge pulls up to the platform.'
        dock = 'The sand barge pulls into dock.'
        ended_on = waitfor_reads(player_text_lines(arrive) + [arrive] + player_text_lines(dock) + [dock])
        allow(DRC).to receive(:bput).with('go barge', any_args)
                                    .and_return('What were you referring to', "One of the barge's crew members watching")
        bescort.send(:take_sandbarge, 'muspari', 'hvaral')
        expect(ended_on).to eq([arrive, dock])
      end

      it 'stays on the mammoth until it trumpets at the shore' do
        real = 'The burly beast trumpets a series of watery blasts as it nears the shore.'
        ended_on = waitfor_reads(player_text_lines(real) + [real])
        allow(DRC).to receive(:bput).with('join tall mammoth', any_args).and_return('You join the Merelew driver')
        bescort.send(:take_mammoth, 'acen')
        expect(ended_on).to eq([real])
      end

      it 'waits for the mammoth to arrive before joining again' do
        arrive = 'A watery trumpeting sound heralds the swift approach of a mammoth.'
        shore = 'The burly beast trumpets a series of watery blasts as it nears the shore.'
        ended_on = waitfor_reads(player_text_lines(arrive) + [arrive] + player_text_lines(shore) + [shore])
        allow(DRC).to receive(:bput).with('join tall mammoth', any_args)
                                    .and_return('What were you referring to', 'You join the Merelew driver')
        bescort.send(:take_mammoth, 'acen')
        expect(ended_on).to eq([arrive, shore])
      end

      it 'waits for the Riverhaven ferry, then stays aboard until it ties off' do
        arrive = "The ferry Hodierna's Grace pulls into the dock."
        dock = "The ferry Hodierna's Grace reaches the dock and its crew ties the ferry off."
        ended_on = waitfor_reads(player_text_lines(arrive) + [arrive] + player_text_lines(dock) + [dock])
        allow(DRC).to receive(:bput).with('go ferry', any_args).and_return('not here', 'You climb aboard')
        bescort.send(:take_rh_ferry, true)
        expect(ended_on).to eq([arrive, dock])
        expect(bescort).to have_received(:move).with('go dock').once
      end

      it 'waits for the gondola, then stays in the cab until it stops' do
        arrive = 'The gondola stops on the platform and the door silently swings open.'
        stop = 'With a soft bump, the gondola comes to a stop at its destination.'
        ended_on = waitfor_reads(player_text_lines(arrive) + [arrive] + player_text_lines(stop) + [stop])
        at_room(2904, 2904, 9999)
        allow(DRC).to receive(:bput).with('go gondola', any_args).and_return('There is no wooden gondola here', 'Gondola, Cab')
        bescort.send(:ride_gondola, 'north')
        expect(ended_on).to eq([arrive, stop])
        expect(bescort).to have_received(:move).with('out')
      end

      it 'stays on the Crossing ferry until it ties off' do
        real = "The ferry Hodierna's Grace reaches the dock and its crew ties the ferry off."
        ended_on = waitfor_reads(player_text_lines(real) + [real])
        UserVars.citizenship = 'Zoluren'
        at_room(1904, 9999)
        DRRoom.room_objs = ['the ferry']
        allow(DRC).to receive(:bput).with('go ferry', any_args).and_return('You hand him')
        bescort.send(:take_xing_ferry, 'leth')
        expect(ended_on).to eq([real])
        expect(bescort).to have_received(:move).with('go dock')
      end

      it "waits for the Ain Ghazal ferry, then stays aboard until it stops" do
        arrive = 'The Evening Star comes to an easy landing at the dock and the crew quickly begin to unload the supplies they brought across the river while the passengers make their way off as best they can.'
        stop = 'You come to a very soft stop as the ferry reaches the far bank.'
        ended_on = waitfor_reads(player_text_lines(arrive) + [arrive] + player_text_lines(stop) + [stop])
        at_room(3986)
        DRRoom.room_objs = ['Evening Star']
        allow(DRC).to receive(:bput).with('go ferry', any_args).and_return('is steadily approaching', 'You hand him')
        bescort.send(:take_ain_ghazal_ferry, 'shard')
        expect(ended_on).to eq([arrive, stop])
        expect(bescort).to have_received(:move).with('go dock').once
      end

      it 'stays on the Langenfirth barge until it ties off' do
        real = 'The barge Riverhawk reaches its dock and its crew ties the barge off.'
        ended_on = waitfor_reads(player_text_lines(real) + [real])
        at_room(466)
        DRRoom.room_objs = ['the barge']
        allow(DRC).to receive(:bput).with('go barge', any_args).and_return('You hand him')
        bescort.send(:take_rh_lang_barge)
        expect(ended_on).to eq([real])
        expect(bescort).to have_received(:move).with('go pier')
      end

      [['Imperial Glory', 'go glory', 'covered stone dock'],
       ['Riverhawk', 'go riverhawk', 'salt yard dock']].each do |barge, command, dock_name|
        it "waits for a Throne City barge, then stays on the #{barge} until it ties off" do
          arrive = 'A barge pulls into the dock.'
          dock = "The barge #{barge} pulls into dock and its crew quickly ties the barge off."
          ended_on = waitfor_reads(player_text_lines(arrive) + [arrive] + player_text_lines(dock) + [dock])
          at_room(452)
          DRRoom.room_objs = ["the barge #{barge}", dock_name]
          allow(DRC).to receive(:bput).with(command, any_args).and_return('What were you referring to', 'You hand him')
          bescort.send(:take_haven_throne_ferry)
          expect(ended_on).to eq([arrive, dock])
          expect(bescort).to have_received(:move).with('go dock').once
        end
      end
    end

    describe "wander_maze_until 'maze-reset'" do
      let(:maze_room) { double('MazeRoom') }
      let(:moves) { [] }

      before do
        stub_const('MazeRoom', double('MazeRoom class', new: maze_room))
        allow(bescort).to receive(:move) { |dir| moves << dir }
        bput_reads('look', ['Obvious paths: southwest, north.'])
      end

      # One wander step hears the line, then the target comes into view.
      def wander_hearing(*lines)
        allow(maze_room).to receive(:wander) do
          lines.each { |line| deliver(line) }
          DRRoom.room_objs = ['curving path']
          maze_room
        end
        bescort.send(:wander_maze_until, 'curving path', nil)
      end

      it 'looks and takes the first exit on the real line' do
        wander_hearing("<pushBold/>You can't go there.<popBold/>")
        expect(moves).to eq([' southwest'])
      end

      it 'ignores the line from another player' do
        wander_hearing(*player_xml_lines("You can't go there."))
        expect(DRC).not_to have_received(:bput).with('look', any_args)
        expect(moves).to be_empty
      end

      it "takes the exit from the game's own room description, not a player's" do
        bput_reads('look', player_text_lines('Obvious paths: up.') + ['Obvious paths: southwest, north.'])
        wander_hearing("You can't go there.")
        expect(moves).to eq([' southwest'])
      end
    end

    describe '#hvaral_passport' do
      let(:to_licenser) { Class.new(StandardError) }

      before { allow(bescort).to receive(:manual_go2).with(3632).and_raise(to_licenser) }

      ['What were you referring to?', 'Realizing your passport has expired, you put it away.'].each do |reply|
        it "heads to the licenser on the real reply: #{reply}" do
          bput_reads('get my passport', [reply])
          expect { bescort.send(:hvaral_passport) }.to raise_error(to_licenser)
        end
      end

      it 'goes through the gate when the passport is in hand, whatever a player says' do
        lines = player_text_lines('What were you referring to?') + player_text_lines('Realizing your passport has expired') +
                ['You get a passport from inside your pack.']
        bput_reads('get my passport', lines)
        bescort.send(:hvaral_passport)
        expect(bescort).to have_received(:move).with('go gate')
      end
    end

    describe "'bescort-dustroad'" do
      let(:at_licenser) { Class.new(StandardError) }
      let(:road_end) { 'Just when it seems you will never reach the end of the dusty road, the city gates come into view.' }

      # Walk the road hearing the lines in order, one per pause; stop at the
      # licenser with the last line heard before the script went there.
      def walk_road_hearing(lines)
        heard = []
        queue = lines.dup
        allow(bescort).to receive(:pause) do |seconds|
          line = queue.shift
          raise 'still walking the road' if line.nil? && seconds == 1

          heard << line
          deliver(line) if line
        end
        allow(bescort).to receive(:manual_go2).with(3147) { raise at_licenser, heard.compact.last }
        bput_reads('get my passport', ['What were you referring to?'])
        bescort.send(:hvaral_passport)
      end

      it 'walks on to the licenser once the road really ends' do
        expect { walk_road_hearing([road_end]) }.to raise_error(at_licenser, road_end)
      end

      it 'keeps walking when another player says the road has ended' do
        expect { walk_road_hearing(player_xml_lines(road_end) + [road_end]) }.to raise_error(at_licenser, road_end)
      end
    end

    describe '#get_fare? JUSTICE check' do
      let(:necromancer) { 'You are also fairly sure that the people are convinced you are a necromancer.' }

      before do
        bescort.instance_variable_get(:@settings).bescort_fare_handling = true
        allow(bescort).to receive(:get_data).and_return({ 'Crossing' => { 'deposit' => { 'id' => 1 } } })
      end

      it 'refuses to fetch fare when the game says the people think you are a necromancer' do
        $server_buffer = ['After assessing the area, you believe that the people here are watching.', necromancer]
        expect(bescort.send(:get_fare?, 35, 'Crossing', 957)).to be(false)
        expect(bescort).not_to have_received(:manual_go2).with(957)
      end

      it 'fetches fare when only another player says it' do
        $server_buffer = ['After assessing the area, you believe that the people here are watching.'] + player_text_lines(necromancer)
        bescort.send(:get_fare?, 35, 'Crossing', 957)
        expect(bescort).to have_received(:manual_go2).with(957)
      end
    end
  end

  describe 'astral walk flags' do
    # The game's lines for each astral-walk flag, as Flags see them (raw XML). The
    # harness-check adverb stands for any wording other than 'effortlessly'.
    let(:real_lines) do
      {
        'harness-check'   => 'You barely maintain your place among the shifting streams of mana.',
        'pattern-shift'   => 'A wave of rippling air sweeps through the conduit!  The streams of mana writhe violently before settling into new patterns.',
        'gate-failure'    => 'With supreme effort, you are able to bring the spell to an end without harm.',
        'ap-danger'       => "Unlike most astral phenomena, the static does not go away after a few moments. In fact, it's getting stronger. Closer.",
        'walking-circles' => 'You end up walking in circles.'
      }
    end
    let(:center) { /the microcosm is to the (?<direction>.*)\.$/ }

    # Other players' ESP, speech and whispers carrying the same text, raw and stripped.
    def player_lines(text)
      {
        'ESP'       => %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
        'say'       => %(<preset id='speech'>Mallory says</preset>, "#{text}"),
        'whisper'   => %(Mallory whispers, "#{text}"),
        'plain ESP' => %([General][Mallory] "#{text}"),
        'plain say' => %(Mallory says, "#{text}")
      }
    end

    # Feed a server line through the registered Flags matchers, the way
    # Lich's DRParser.check_events does for every downstream line.
    def deliver(line)
      Flags.matchers.each do |key, regexes|
        regexes.each do |regex|
          if (match = line.match(regex))
            Flags[key] = match
            break
          end
        end
      end
    end

    before do
      # astral_walk registers its flags first; an unknown shard stops it right after.
      allow(bescort).to receive(:know_shard?).and_return(false)
      expect { bescort.send(:astral_walk, 'crossing') }.to raise_error(SystemExit)
      allow(bescort).to receive(:fput)
      allow(bescort).to receive(:move)
      allow(bescort).to receive(:waitrt)
      allow(bescort).to receive(:pause)
      allow(DRCA).to receive(:harness_mana)
      allow(DRCA).to receive(:release_cyclics)
      allow(DRC).to receive(:bput).with('pow', anything).and_return('the microcosm is to the north.')
    end

    describe "'ap-danger'" do
      it 'leaves the game on the real warning' do
        deliver(real_lines['ap-danger'])
        bescort.send(:power_walk, center)
        expect(bescort).to have_received(:fput).with('exit')
      end

      it 'still matches the warning after leading tags or another sentence' do
        deliver("<pushBold/>#{real_lines['ap-danger']}<popBold/>")
        expect(Flags['ap-danger']).to be_truthy
        Flags.reset('ap-danger')
        deliver("The static grows louder.  #{real_lines['ap-danger']}")
        expect(Flags['ap-danger']).to be_truthy
      end

      it 'keeps walking when another player repeats it' do
        player_lines(real_lines['ap-danger']).each_value { |line| deliver(line) }
        expect(Flags['ap-danger']).to be_falsey
        bescort.send(:power_walk, center)
        expect(bescort).not_to have_received(:fput).with('exit')
        expect(bescort).to have_received(:move).with('north')
      end
    end

    describe "'harness-check'" do
      it 'harnesses more mana on the real line' do
        deliver(real_lines['harness-check'])
        bescort.send(:power_walk, center)
        expect(DRCA).to have_received(:harness_mana).with([20])
        expect(Flags['harness-check']).to be_falsey
      end

      it 'does not harness on the real effortless line' do
        deliver('You effortlessly maintain your place among the shifting streams of mana.')
        bescort.send(:power_walk, center)
        expect(DRCA).not_to have_received(:harness_mana)
      end

      it 'ignores the line from another player' do
        player_lines(real_lines['harness-check']).each_value { |line| deliver(line) }
        expect(Flags['harness-check']).to be_falsey
        bescort.send(:power_walk, center)
        expect(DRCA).not_to have_received(:harness_mana)
      end
    end

    describe "'pattern-shift'" do
      it 'skips the move on the real line' do
        deliver(real_lines['pattern-shift'])
        bescort.send(:power_walk, center)
        expect(bescort).not_to have_received(:move)
      end

      it 'still moves when another player repeats it' do
        player_lines(real_lines['pattern-shift']).each_value { |line| deliver(line) }
        expect(Flags['pattern-shift']).to be_falsey
        bescort.send(:power_walk, center)
        expect(bescort).to have_received(:move).with('north').once
      end
    end

    describe "'walking-circles'" do
      # The move's reply arrives while the move is sent.
      def walk_hearing(line)
        moves = 0
        allow(bescort).to receive(:move) do
          moves += 1
          deliver(line) if moves == 1
        end
        bescort.send(:power_walk, center)
        moves
      end

      it 'tries the step again on the real line' do
        expect(walk_hearing(real_lines['walking-circles'])).to eq(2)
        expect(DRC).to have_received(:bput).with('pow', center).twice
      end

      ['ESP', 'say', 'whisper', 'plain ESP', 'plain say'].each do |shape|
        it "does not retry on another player's #{shape} line" do
          expect(walk_hearing(player_lines(real_lines['walking-circles'])[shape])).to eq(1)
          expect(DRC).to have_received(:bput).with('pow', center).once
        end
      end
    end

    describe "'gate-failure'" do
      # The failure line arrives during the first cast.
      def open_gate_hearing(line)
        casts = 0
        allow(DRCA).to receive(:cast?) do
          casts += 1
          deliver(line) if casts == 1
          true
        end
        bescort.send(:open_gate, 'Rolagi', false)
        casts
      end

      it 'casts the gate again on the real line' do
        expect(open_gate_hearing(real_lines['gate-failure'])).to eq(2)
        expect(DRCA).to have_received(:release_cyclics).twice
      end

      ['ESP', 'say', 'whisper', 'plain ESP', 'plain say'].each do |shape|
        it "casts once on another player's #{shape} line" do
          expect(open_gate_hearing(player_lines(real_lines['gate-failure'])[shape])).to eq(1)
          expect(DRCA).to have_received(:release_cyclics).once
        end
      end
    end
  end
end
