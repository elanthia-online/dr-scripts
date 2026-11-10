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

    # Lich's matchtimeout: the same case-insensitive regex as waitfor, but it
    # returns false once the time is up. Here the time is up when the queued
    # lines run out. Returns the lines that ended a wait (false for a timeout)
    # and records each wait's seconds.
    def matchtimeout_reads(lines, seconds: [])
      ended_on = []
      queue = lines.dup
      allow(bescort).to receive(:matchtimeout) do |secs, *strings|
        seconds << secs
        regex = /#{strings.flatten.join('|')}/i
        line = queue.shift until queue.empty? || line&.match?(regex)
        result = line&.match?(regex) ? line : false
        ended_on << result
        result
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

      describe '#take_mammoth' do
        let(:arrive) { 'A watery trumpeting sound heralds the swift approach of a mammoth.' }
        let(:shore) { 'The burly beast trumpets a series of watery blasts as it nears the shore.' }

        before { at_room(8301) }

        it 'stays on the mammoth until it trumpets at the shore' do
          ended_on = matchtimeout_reads(player_text_lines(shore) + [shore])
          allow(DRC).to receive(:bput).with('join tall mammoth', any_args).and_return('You join the Merelew driver')
          bescort.send(:take_mammoth, 'acen')
          expect(ended_on).to eq([shore])
        end

        it 'waits for the mammoth to arrive before joining again' do
          ended_on = matchtimeout_reads(player_text_lines(arrive) + [arrive] + player_text_lines(shore) + [shore])
          allow(DRC).to receive(:bput).with('join tall mammoth', any_args)
                                      .and_return('What were you referring to', 'You join the Merelew driver')
          bescort.send(:take_mammoth, 'acen')
          expect(ended_on).to eq([arrive, shore])
        end

        it 'caps both waits at MAMMOTH_WAIT_TIMEOUT seconds' do
          seconds = []
          matchtimeout_reads([arrive, shore], seconds: seconds)
          allow(DRC).to receive(:bput).with('join tall mammoth', any_args)
                                      .and_return('What were you referring to', 'You join the Merelew driver')
          bescort.send(:take_mammoth, 'acen')
          expect(seconds).to eq([described_class::MAMMOTH_WAIT_TIMEOUT] * 2)
        end

        it 'joins the sea mammoth at the Fang Cove dock for ratha' do
          matchtimeout_reads([shore])
          allow(DRC).to receive(:bput).with('join sea mammoth', any_args).and_return('You join the Merelew driver')
          bescort.send(:take_mammoth, 'ratha')
          expect(bescort).to have_received(:manual_go2).with(8301)
          expect(DRC).to have_received(:bput).with('join sea mammoth', any_args)
        end

        it 'walks to the closest mainland dock for fang and checks it is there' do
          allow(DRCT).to receive(:sort_destinations).with([2239, 11_130]).and_return([11_130, 2239])
          at_room(11_130)
          matchtimeout_reads([shore])
          allow(DRC).to receive(:bput).with('join sea mammoth', any_args).and_return('You join the Merelew driver')
          bescort.send(:take_mammoth, 'fang')
          expect(bescort).to have_received(:manual_go2).with(11_130)
        end

        context 'when the walk to the dock ends somewhere else' do
          # A go2 restarted from a stale room can start bescort while the
          # character is really elsewhere; the walk then stops short.
          before { at_room(16_667) }

          it 'stops without trying to join a mammoth there' do
            expect { bescort.send(:take_mammoth, 'acen') }.to raise_error(SystemExit)
            expect(DRC).not_to have_received(:bput).with(/join .* mammoth/, any_args)
            expect(DRC).to have_received(:message).with(/Couldn't reach the mammoth dock \(room 8301\); stopped in room 16667/)
          end
        end

        context 'when Lich does not know the room after the walk' do
          before { at_room(nil) }

          it 'stops without trying to join' do
            expect { bescort.send(:take_mammoth, 'acen') }.to raise_error(SystemExit)
            expect(DRC).not_to have_received(:bput).with(/join .* mammoth/, any_args)
          end
        end

        context 'when there is no reachable dock for fang' do
          before do
            allow(DRCT).to receive(:sort_destinations).and_return([])
            at_room(nil)
          end

          it 'stops without walking or joining, even though an unknown room and no dock are both nil' do
            expect { bescort.send(:take_mammoth, 'fang') }.to raise_error(SystemExit)
            expect(bescort).not_to have_received(:manual_go2)
            expect(DRC).not_to have_received(:bput).with(/join .* mammoth/, any_args)
            expect(DRC).to have_received(:message).with("No mammoth dock to walk to for 'fang' from room nil. Not joining a mammoth.")
          end
        end

        context 'when every arriving mammoth still cannot be joined' do
          it "stops after #{described_class::MAMMOTH_JOIN_ATTEMPTS} tries instead of waiting through arrival after arrival" do
            matchtimeout_reads([arrive] * 10)
            allow(DRC).to receive(:bput).with('join tall mammoth', any_args).and_return('What were you referring to')
            expect { bescort.send(:take_mammoth, 'acen') }.to raise_error(SystemExit)
            expect(DRC).to have_received(:bput).with('join tall mammoth', any_args).exactly(described_class::MAMMOTH_JOIN_ATTEMPTS).times
            expect(DRC).to have_received(:message).with(/Tried to join the tall mammoth 3 times at room 8301/)
          end
        end

        context 'when JOIN gets neither expected reply' do
          ['', 'You are too busy to do that.'].each do |reply|
            it "says so and stops instead of ending silently (#{reply.inspect})" do
              matchtimeout_reads([arrive, shore])
              allow(DRC).to receive(:bput).with('join tall mammoth', any_args).and_return(reply)
              expect { bescort.send(:take_mammoth, 'acen') }.to raise_error(SystemExit)
              expect(DRC).to have_received(:message).with(/Unexpected reply to 'join tall mammoth'/)
              expect(bescort).not_to have_received(:matchtimeout)
            end
          end
        end

        context 'when no mammoth arrives in time' do
          it 'gives up instead of waiting forever, and does not try again' do
            matchtimeout_reads(player_text_lines(arrive))
            allow(DRC).to receive(:bput).with('join tall mammoth', any_args).and_return('What were you referring to')
            expect { bescort.send(:take_mammoth, 'acen') }.to raise_error(SystemExit)
            expect(DRC).to have_received(:bput).with('join tall mammoth', any_args).once
            expect(DRC).to have_received(:message).with(/No tall mammoth reached room 8301 in 20 minutes/)
          end
        end

        context 'when the mammoth never reaches the shore' do
          it 'gives up aboard instead of waiting forever' do
            matchtimeout_reads(player_text_lines(shore))
            allow(DRC).to receive(:bput).with('join tall mammoth', any_args).and_return('You join the Merelew driver')
            expect { bescort.send(:take_mammoth, 'acen') }.to raise_error(SystemExit)
            expect(DRC).to have_received(:message).with(/hasn't reached the shore after 20 minutes/)
          end
        end
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

      # Verbatim from a live North Road -> Riverhaven ride (2026-11-10): the game
      # quotes the ferry's name both on the dock and aboard. The departure calls
      # come first and must not end either wait.
      it 'boards the Riverhaven ferry and stays aboard when both lines quote its name' do
        arrive = 'The ferry "His Daring Exploit" pulls up to the dock.'
        dock = 'The ferry "His Daring Exploit" reaches the dock and its crew ties the ferry off.'
        departure = ['A great clanging bell rings out and a hearty voice calls, "Next departure in one minute!"',
                     %(A great clanging bell peals three times, and a booming voice cries, "All ashore who's going ashore!"),
                     'You hear a shrill whistle and a voice call out, "Cast off!"',
                     'You feel the ferry shudder slightly as it shoves off.',
                     'You are nearing the docks.']
        ended_on = waitfor_reads(player_text_lines(arrive) + [arrive] + departure + player_text_lines(dock) + [dock])
        allow(DRC).to receive(:bput).with('go ferry', any_args).and_return('I could not find what you were referring to', 'You hand him your lirums and climb aboard')
        bescort.send(:take_rh_ferry, true)
        expect(ended_on).to eq([arrive, dock])
        expect(DRC).to have_received(:bput).with('go ferry', any_args).twice
        expect(bescort).to have_received(:move).with('go dock').once
      end

      # Southbound from the same session: Tenuk waited on the Riverhaven dock and
      # rode back on the other ferry.
      it 'boards at Riverhaven and steps off at North Road with the quoted lines' do
        arrive = 'The ferry "Her Opulence" pulls up to the dock.'
        dock = 'The ferry "His Daring Exploit" reaches the dock and its crew ties the ferry off.'
        ended_on = waitfor_reads([%(You can see the ferry "Her Opulence" approaching the dock.), arrive, 'You are nearing the docks.', dock])
        allow(DRC).to receive(:bput).with('go ferry', any_args).and_return('I could not find what you were referring to', 'You hand him your lirums and climb aboard')
        bescort.send(:take_rh_ferry, false)
        expect(bescort).to have_received(:manual_go2).with(470).at_least(:once)
        expect(bescort).not_to have_received(:manual_go2).with(1385)
        expect(ended_on).to eq([arrive, dock])
        expect(bescort).to have_received(:move).with('go dock').once
      end

      it 'stays aboard when only a player repeats the quoted tie-off line' do
        dock = 'The ferry "His Daring Exploit" reaches the dock and its crew ties the ferry off.'
        waitfor_reads(player_text_lines(dock))
        allow(DRC).to receive(:bput).with('go ferry', any_args).and_return('You hand him your lirums and climb aboard')
        expect { bescort.send(:take_rh_ferry, true) }.to raise_error(RuntimeError, 'waitfor would wait forever')
        expect(bescort).not_to have_received(:move).with('go dock')
      end

      it 'does not board when only a player repeats the quoted dock line' do
        arrive = 'The ferry "His Daring Exploit" pulls up to the dock.'
        waitfor_reads(player_text_lines(arrive) + player_text_lines("The ferry \"#{arrive}"))
        allow(DRC).to receive(:bput).with('go ferry', any_args).and_return('not here')
        expect { bescort.send(:take_rh_ferry, true) }.to raise_error(RuntimeError, 'waitfor would wait forever')
        expect(DRC).to have_received(:bput).with('go ferry', any_args).once
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

    # The dirigible lines are from a player's log; the balloon's are modelled on
    # them, since board_flight drives both with the operator's name swapped in.
    [
      { method: :take_dirigible, mode: 'shard', noun: 'dirigible', operator: 'The Elothean aeromancer',
        gondola: '[[Aboard the Dirigible, Gondola]]', arrival: 'JOIN CHARCOAL DIRIGIBLE' },
      { method: :take_balloon, mode: 'langenfirth', noun: 'balloon', operator: 'The Gnomish operator',
        gondola: '[[Aboard the Balloon, Gondola]]', arrival: 'JOIN GNOMISH BALLOON' }
    ].each do |flight|
      describe "##{flight[:method]}" do
        let(:flight) { flight }
        let(:join) { "join #{flight[:noun]}" }
        let(:one_step) { %(#{flight[:operator]} says, "Alright.  That'll be 3150 Lirums."  You hand over your funds and step closer.  You join #{flight[:operator].sub('The ', 'the ')}.  "Right this way, madam.") }
        let(:quoted) { %(#{flight[:operator]} says, "Woah there, madam.  I can only take a handful with me at a time.  It's going to cost you if you want to come along.  I'll accept 3150 copper Lirums.") }
        let(:paid) { 'You hand over your funds and step closer.' }
        let(:cannot_pay) { 'You reach your funds, but realize you cannot afford it.' }

        # Each JOIN reads the next set of lines, the way Lich's DRC.bput does:
        # the first line matching any pattern returns the matched text.
        def join_replies(*line_sets)
          sets = line_sets.dup
          allow(DRC).to receive(:bput).with(join, any_args) do |_command, *matches|
            regexes = matches.map { |m| m.is_a?(Regexp) ? m : /#{m}/i }
            (sets.shift || []).lazy.filter_map { |line| regexes.filter_map { |regex| line.match(regex)&.to_a&.first }.first }.first || ''
          end
        end

        # The ride: pause is stubbed, so step the room title off the gondola
        # after a few polls and count them.
        def fly(polls_aboard)
          XMLData.room_title = flight[:gondola]
          polls = 0
          allow(bescort).to receive(:pause) do
            polls += 1
            XMLData.room_title = '[[Landing Field]]' if polls > polls_aboard
          end
          -> { polls }
        end

        def take
          bescort.send(flight[:method], flight[:mode])
        end

        before { DRStats.circle = 63 }

        after { XMLData.room_title = nil }

        it 'stays aboard when the first JOIN pays the fare' do
          join_replies(player_text_lines(paid) + [one_step])
          polls = fly(3)
          take
          expect(DRC).to have_received(:bput).with(join, any_args).once
          expect(polls.call).to be > 3
          expect(XMLData.room_title).not_to eq(flight[:gondola])
        end

        it 'pays on the second JOIN when the first only quotes the fare' do
          join_replies([quoted], [paid])
          polls = fly(2)
          take
          expect(DRC).to have_received(:bput).with(join, any_args).twice
          expect(polls.call).to be > 2
        end

        it 'pays on the second JOIN when the operator says the boarding line' do
          join_replies([quoted], [one_step])
          polls = fly(2)
          take
          expect(polls.call).to be > 2
        end

        it 'gets off the ride path when the second JOIN cannot pay' do
          join_replies([quoted], [cannot_pay])
          take
          expect(bescort).not_to have_received(:pause)
        end

        it 'stays on the ride path when another player repeats the cannot-pay line' do
          join_replies([quoted], player_text_lines(cannot_pay) + [paid])
          polls = fly(2)
          take
          expect(polls.call).to be > 2
        end

        it 'waits for it when there is nothing to join, then boards' do
          join_replies(['What were you referring to?'], [one_step])
          allow(bescort).to receive(:waitfor).with(flight[:arrival])
          take
          expect(bescort).to have_received(:waitfor).with(flight[:arrival]).once
          expect(DRC).to have_received(:bput).with(join, any_args).twice
        end

        it 'ignores the fare lines when another player repeats them' do
          join_replies(player_text_lines(quoted) + player_text_lines(one_step) + ['What were you referring to?'], [one_step])
          allow(bescort).to receive(:waitfor)
          take
          expect(bescort).to have_received(:waitfor).with(flight[:arrival]).once
          expect(DRC).to have_received(:bput).with(join, any_args).twice
        end

        it 'gives up without riding when the JOIN reply is unrecognised' do
          join_replies(['You are already part of a group.'])
          allow(bescort).to receive(:waitfor)
          take
          expect(bescort).not_to have_received(:pause)
          expect(bescort).not_to have_received(:waitfor)
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

  describe '#get_fare? without bescort_fare_handling' do
    # A Lich script that the player unpauses after `polls` checks.
    let(:script_class) do
      Class.new do
        attr_reader :name, :pauses, :unpauses

        def initialize(name, polls)
          @name = name
          @polls = polls
          @pauses = 0
          @unpauses = 0
          @left = 0
        end

        def pause
          @pauses += 1
          raise 'bescort paused again and again without re-checking' if @pauses > 50

          @left = @polls
        end

        def paused?
          return false if @left <= 0

          @left -= 1
          true
        end

        def unpause
          @unpauses += 1
          @left = 0
        end
      end
    end
    let(:me) { script_class.new('bescort', 2) }
    let(:go2) { script_class.new('go2', 0) }
    let(:running) { [go2, me] }
    let(:messages) { [] }
    let(:dock) { 12_942 }
    let(:bank) { 7224 }

    before do
      $test_data.town = { 'Aesry' => { 'currency' => 'lirums', 'deposit' => { 'id' => bank } } }
      allow(DRCM).to receive(:hometown_currency).with('Aesry').and_return('lirums')
      # Lich's DRCM.minimize_coins: copper split into the fewest coins.
      allow(DRCM).to receive(:minimize_coins) do |copper|
        [[10_000, 'platinum'], [1000, 'gold'], [100, 'silver'], [10, 'bronze'], [1, 'copper']].each_with_object([]) do |(value, name), coins|
          coins << "#{copper / value} #{name}" if copper >= value
          copper %= value
        end
      end
      allow(DRC).to receive(:message) { |text| messages << text }
      allow(Script).to receive(:current).and_return(me)
      allow(Script).to receive(:running) { running.dup }
      allow(bescort).to receive(:pause)
      allow(bescort).to receive(:echo)
      titles = { bank => ['[[Tona Kertigen, Deposit Window]]'], dock => ["[[Aesry Surlaenis'a, Landing Field]]"] }
      allow(Map).to receive(:[]) { |id| titles[id] && double('map room', title: titles[id]) }
    end

    # go2 is killed on the first poll; a bescort that never notices would wait
    # forever, so fail instead of hanging.
    def kill_go2_while_paused
      polls = 0
      allow(bescort).to receive(:pause) do
        running.delete(go2)
        raise 'bescort never noticed go2 was killed' if (polls += 1) > 500
      end
    end

    def at_rooms(*ids)
      allow(Room).to receive(:current).and_return(*ids.map { |id| double('room', id: id) })
    end

    it 'pauses with the bank, the coins to withdraw and the room to come back to' do
      allow(DRCM).to receive(:wealth).with('Aesry').and_return(3000, 3150)
      at_rooms(dock)
      expect(bescort.send(:get_fare?, 3150, 'Aesry', dock)).to be true
      expect(me.pauses).to eq(1)
      expect(messages).to eq(
        [
          'Not enough lirums for the fare: you need 3150 copper lirums and are carrying 3000. bescort is paused.',
          '  1. Go to the bank: Tona Kertigen, Deposit Window (room 7224). go2 is still waiting on this trip, so use ;force go2 7224',
          '  2. withdraw 1 silver, withdraw 5 bronze',
          "  3. Return to Aesry Surlaenis'a, Landing Field (room 12942), then ;unpause bescort",
          '  Set bescort_fare_handling: true in your yaml to have bescort do this for you.'
        ]
      )
    end

    it 'pauses again when unpaused still short, with the new shortfall' do
      allow(DRCM).to receive(:wealth).with('Aesry').and_return(3000, 3100, 3150)
      at_rooms(dock)
      expect(bescort.send(:get_fare?, 3150, 'Aesry', dock)).to be true
      expect(me.pauses).to eq(2)
      expect(messages.grep(/^  2\./)).to eq(['  2. withdraw 1 silver, withdraw 5 bronze', '  2. withdraw 5 bronze'])
    end

    it 'pauses again when unpaused with the fare but away from the room' do
      allow(DRCM).to receive(:wealth).with('Aesry').and_return(3000, 3150, 3150)
      at_rooms(bank, dock)
      expect(bescort.send(:get_fare?, 3150, 'Aesry', dock)).to be true
      expect(me.pauses).to eq(2)
      expect(messages.last).to eq("You have the fare. Return to Aesry Surlaenis'a, Landing Field (room 12942), then ;unpause bescort")
    end

    it 'unpauses and gives up when go2 is killed while paused' do
      allow(DRCM).to receive(:wealth).with('Aesry').and_return(3000)
      at_rooms(dock)
      paused_me = script_class.new('bescort', 100)
      allow(Script).to receive(:current).and_return(paused_me)
      kill_go2_while_paused
      expect(bescort.send(:get_fare?, 3150, 'Aesry', dock)).to be false
      expect(paused_me.unpauses).to eq(1)
      expect(messages.last).to eq('go2 has stopped, so bescort is stopping too.')
    end

    it 'waits on the pause alone when bescort was started without go2' do
      running.delete(go2)
      allow(DRCM).to receive(:wealth).with('Aesry').and_return(3000, 3150)
      at_rooms(dock)
      expect(bescort.send(:get_fare?, 3150, 'Aesry', dock)).to be true
      expect(me.unpauses).to eq(0)
    end

    it 'names a room the map does not have by its id' do
      allow(Map).to receive(:[]).and_return(nil)
      allow(DRCM).to receive(:wealth).with('Aesry').and_return(3000, 3150)
      at_rooms(dock)
      bescort.send(:get_fare?, 3150, 'Aesry', dock)
      expect(messages).to include('  1. Go to the bank: room 7224. go2 is still waiting on this trip, so use ;force go2 7224')
    end

    it 'boards the dirigible after the player fetches the fare, with one WEALTH per check' do
      DRStats.circle = 63
      allow(DRCM).to receive(:wealth).with('Aesry').and_return(3000, 3150)
      at_rooms(dock)
      allow(bescort).to receive(:manual_go2)
      allow(DRC).to receive(:bput).with('join dirigible', any_args).and_return('You hand over your funds and step closer')
      bescort.send(:take_dirigible, 'shard')
      expect(me.pauses).to eq(1)
      expect(DRCM).to have_received(:wealth).twice
      expect(messages.grep(/^Not enough/).size).to eq(1)
      expect(bescort).not_to have_received(:echo).with('Get money you slob!')
      expect(DRC).to have_received(:bput).with('join dirigible', any_args).at_least(:once)
    end

    # Every site that hands a shortfall to get_fare? passes the coins its own
    # WEALTH found and leaves the shortfall message to get_fare?.
    [
      [:take_m_m_galley, 'mriss', 6555, "Mer'Kresh", [300, "Mer'Kresh", 6555]],
      [:take_dirigible, 'aesry', 12_862, 'Shard', [3150, 'Shard', 12_862]],
      [:take_dirigible, 'shard', 12_942, 'Aesry', [3150, 'Aesry', 12_942]],
      [:take_balloon, 'mriss', 8793, 'Therenborough', [3150, 'Therenborough', 8793]],
      [:take_balloon, 'langenfirth', 8794, "Mer'Kresh", [3150, "Mer'Kresh", 8794]],
      [:take_xing_ferry, 'crossing', 1904, 'Crossing', [35, 'Leth Deriel', 1904]],
      [:take_xing_ferry, 'leth', 957, 'Crossing', [70, 'Crossing', 957]],
      [:take_ain_ghazal_ferry, 'ainghazal', 3986, 'Shard', [62, 'Hibarnhvidar', 3986]],
      [:take_rh_lang_barge, nil, 3434, 'Riverhaven', [300, 'Therenborough', 3434]],
      [:take_rh_lang_barge, nil, 466, 'Riverhaven', [300, 'Riverhaven', 466]],
      [:take_haven_throne_ferry, nil, 452, 'Riverhaven', [300, 'Riverhaven', 452]],
      [:take_haven_throne_ferry, nil, 3084, 'Riverhaven', [300, 'Throne City', 3084]]
    ].each do |method, mode, room, wealth_town, fare_args|
      it "#{method} from room #{room} hands its WEALTH to get_fare? and leaves the message to it" do
        DRStats.circle = 63
        UserVars.citizenship = 'Ilithi'
        at_rooms(room)
        allow(bescort).to receive(:manual_go2)
        allow(DRCM).to receive(:wealth).with(wealth_town).and_return(10)
        allow(bescort).to receive(:get_fare?).and_return(false)
        mode ? bescort.send(method, mode) : bescort.send(method)
        expect(bescort).to have_received(:get_fare?).with(*fare_args, 10)
        expect(DRCM).to have_received(:wealth).once
        expect(bescort).not_to have_received(:echo).with('Get money you slob!')
      end
    end

    it 'still says Get money you slob! on the Ain Ghazal dock that fetches no fare' do
      at_rooms(11_027)
      allow(DRCM).to receive(:wealth).with('Shard').and_return(10)
      allow(bescort).to receive(:get_fare?)
      bescort.send(:take_ain_ghazal_ferry, 'shard')
      expect(bescort).to have_received(:echo).with('Get money you slob!')
      expect(bescort).not_to have_received(:get_fare?)
    end

    it 'leaves the dirigible alone when go2 is killed while paused' do
      DRStats.circle = 63
      allow(DRCM).to receive(:wealth).with('Aesry').and_return(3000)
      at_rooms(dock)
      allow(Script).to receive(:current).and_return(script_class.new('bescort', 100))
      kill_go2_while_paused
      allow(bescort).to receive(:manual_go2)
      bescort.send(:take_dirigible, 'shard')
      expect(DRC).not_to have_received(:bput).with('join dirigible', any_args)
      expect(bescort).not_to have_received(:manual_go2)
    end

    it 'still fetches the fare itself when bescort_fare_handling is on' do
      bescort.instance_variable_get(:@settings).bescort_fare_handling = true
      allow(bescort).to receive(:manual_go2)
      allow(bescort).to receive(:reget).and_return(nil)
      allow(DRCM).to receive(:get_money_from_bank).and_return(true)
      expect(bescort.send(:get_fare?, 3150, 'Aesry', dock)).to be true
      expect(me.pauses).to eq(0)
      expect(bescort).to have_received(:manual_go2).with(bank)
    end
  end

  describe '#manual_go2' do
    let(:riverbank) { double('room', id: 1384, wayto: { '1385' => 'north' }) }
    let(:ferry_dock) { double('room', id: 1385, wayto: { '470' => 'ferry', '1384' => 'south' }) }

    before do
      stub_const('StringProc', Class.new) unless defined?(StringProc)
      allow(bescort).to receive(:move)
      allow(Map).to receive(:[]).with(1385).and_return(ferry_dock)
    end

    it 'walks into the goal room once when the path ends with it' do
      here = riverbank
      allow(Room).to receive(:current) { here }
      allow(bescort).to receive(:move) { |dir| here = ferry_dock if dir == 'north' }
      allow(Map).to receive(:findpath).with(1384, ferry_dock).and_return([1385])
      bescort.send(:manual_go2, 1385)
      expect(bescort).to have_received(:move).with('north').once
      expect(bescort).not_to have_received(:move).with(nil)
    end

    it 'still takes the last step when the path stops one room short' do
      here = riverbank
      allow(Room).to receive(:current) { here }
      allow(bescort).to receive(:move) { |dir| here = ferry_dock if dir == 'north' }
      allow(Map).to receive(:findpath).with(1384, ferry_dock).and_return([])
      bescort.send(:manual_go2, 1385)
      expect(bescort).to have_received(:move).with('north').once
    end

    it 'does nothing when already in the goal room' do
      allow(Room).to receive(:current).and_return(ferry_dock)
      allow(Map).to receive(:findpath)
      bescort.send(:manual_go2, 1385)
      expect(Map).not_to have_received(:findpath)
      expect(bescort).not_to have_received(:move)
    end
  end
end
