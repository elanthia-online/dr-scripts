# See spec/spec_helper.rb for the shared harness conventions relied on here:
# the game/commons doubles (DRC, get_noun, list_to_array, fput) and the
# load_lic_class extractor are provided centrally, so this spec neither
# reopens a module nor redefines a top-level method (doing so would clobber
# the shared doubles for the whole run and break other specs).

load_lic_class('trade.lic', 'Trade')

RSpec.describe Trade do
  # find_contracts takes only a container noun; no instance state is needed,
  # so a bare allocated instance keeps the parse/filter logic isolated.
  let(:trade) { Trade.allocate }

  # Issue #4201: the container is rummaged and each entry kept only if it is
  # actually a contract. The bug was a substring match (item.include?('contract'))
  # that also matched a "contract case", so the fix matches on the item noun.
  # DRC.list_to_array preserves the leading space on non-first items (real game
  # behaviour), so results are compared after stripping that incidental space.
  describe '#find_contracts' do
    def stub_look(*items)
      sentence = items.join(', ')
      allow(DRC).to receive(:bput).and_return("you see #{sentence}.")
    end

    def contracts_in(container)
      trade.find_contracts(container).map(&:strip)
    end

    it 'keeps a real contract and rejects a contract case in the same container' do
      stub_look('a Trading contract', 'a contract case', 'some silver coins')
      expect(contracts_in('backpack')).to eq(['a Trading contract'])
    end

    it 'rejects a contract case even when it is the only item (the exact #4201 bug)' do
      stub_look('a contract case')
      expect(contracts_in('backpack')).to eq([])
    end

    it 'returns every contract when several are present' do
      stub_look('a Trading contract', 'a Trading contract', 'a contract case')
      expect(contracts_in('backpack')).to eq(['a Trading contract', 'a Trading contract'])
    end

    it 'returns an empty array when no contracts are present' do
      stub_look('a contract case', 'a leather duffel bag', 'some grass')
      expect(contracts_in('backpack')).to eq([])
    end

    it 'does not match a plural "contracts" noun (only a single contract counts)' do
      stub_look('a bundle of contracts', 'a Trading contract')
      expect(contracts_in('backpack')).to eq(['a Trading contract'])
    end

    it 'reopens a closed container and retries before parsing' do
      responses = ['That is closed', 'you see a Trading contract.']
      allow(DRC).to receive(:bput) { responses.shift }
      expect(contracts_in('contract case')).to eq(['a Trading contract'])

      sent = []
      sent << $sent_messages.pop until $sent_messages.empty?
      expect(sent).to include('open my contract case')
    end
  end

  # Room.current is nil until Lich has worked out which room you're in, and
  # under Lich's NilClass patch nil.id returns nil instead of raising. Any
  # "am I in room X?" check that compares Room.current.id with an id that can
  # itself be nil (a failed tag_to_id lookup, a caravan last seen in an unknown
  # room, a fresh @last_seen_caravan) then passes as nil == nil. These examples
  # pin that an unknown room is never "here".
  describe 'room checks when Lich does not know the current room' do
    let(:messages) { [] }
    # nil means "Lich doesn't know the room". unknown_room picks how that shows
    # up: Room.current itself nil, or a room whose id is nil (a stand-in for
    # nil.id under the NilClass patch, which rspec does not load).
    let(:location) { { id: nil } }
    let(:unknown_room) { double('unknown room', id: nil) }

    before do
      allow(DRC).to receive(:message) { |text| messages << text }
      allow(Room).to receive(:current) do
        location[:id].nil? ? unknown_room : double('room', id: location[:id])
      end
      trade.instance_variable_set(:@caravan, OpenStruct.new(adjective: 'ox-drawn', noun: 'caravan'))
      trade.instance_variable_set(:@last_seen_caravan, [])
      trade.instance_variable_set(:@step_toggle, 0)
    end

    def unknown_room_message
      a_string_matching(/doesn't know what room it's in/)
    end

    shared_examples 'for both forms of unknown room' do |examples|
      context 'with Room.current nil' do
        let(:unknown_room) { nil }

        instance_exec(&examples)
      end

      context 'with Room.current.id nil (nil.id under the NilClass patch)' do
        instance_exec(&examples)
      end
    end

    describe '#take_caravan_to' do
      let(:steps) { [] }
      # room => [direction, room it leads to]
      let(:exits) { { 10 => ['north', 11], 11 => ['east', 12] } }

      before do
        allow(trade).to receive(:be_outside_caravan)
        allow(trade).to receive(:track_caravan)
        allow(trade).to receive(:forbid_certain_transport)
        allow(trade).to receive(:command_caravan?).and_return(true)
        allow(trade).to receive(:caravan_check?).and_return(true)
        allow(trade).to receive(:caravan_present?).and_return(true)
        allow(trade).to receive(:save_caravan_position)
        allow(trade).to receive(:training_cleanup)
        allow(trade).to receive(:wait_for_caravan)
        allow(trade).to receive(:handle_special_room?).and_return(false)
        allow(trade).to receive(:compute_path) { |dest| [location[:id], dest] }
        allow(trade).to receive(:get_next_dir) { exits.fetch(location[:id], [nil]).first }
        allow(trade).to receive(:step) do |dir|
          steps << dir
          exit_for = exits[location[:id]]
          location[:id] = exit_for.last if exit_for && exit_for.first == dir
        end
        # A bounded walk: on main an unknown room or nil destination makes the
        # step loop spin forever, so fail fast instead of hanging the suite.
        walked = 0
        allow(trade).to receive(:walk_training) { raise 'take_caravan_to is spinning' if (walked += 1) > 20 }
        allow(Trade).to receive(:restore_certain_transport)
      end

      describe 'with no destination (nil room id)' do
        include_examples 'for both forms of unknown room', proc {
          it 'stops with a message instead of treating the unknown room as the destination' do
            expect { trade.take_caravan_to(nil) }.to raise_error(SystemExit)
            expect(messages).to include(a_string_matching(/No destination room was found/))
          end

          it 'never tells the caravan to follow or wait' do
            expect(trade).not_to receive(:command_caravan?)
            expect { trade.take_caravan_to(nil) }.to raise_error(SystemExit)
          end
        }

        it 'stops from a known room too instead of walking towards nil' do
          location[:id] = 10
          expect(trade).not_to receive(:step)
          expect { trade.take_caravan_to(nil) }.to raise_error(SystemExit)
          expect(messages).to include(a_string_matching(/No destination room was found/))
        end
      end

      describe 'starting in an unknown room' do
        include_examples 'for both forms of unknown room', proc {
          it 'waits for Lich to place the room, then leads the caravan to the destination' do
            # Moving on and back (the 1 s wait after the message) puts you in 10.
            allow(trade).to receive(:pause) { |secs| location[:id] = 10 if secs == 1 }
            trade.take_caravan_to(12)
            expect(messages).to include(unknown_room_message)
            expect(steps).to eq(%w[north east])
            expect(location[:id]).to eq(12)
          end

          it 'does not plan a path until the room is known' do
            allow(trade).to receive(:pause) { location[:id] = 10 }
            expect(trade).to receive(:compute_path).with(12).once.and_wrap_original do |_m, dest|
              expect(location[:id]).to eq(10)
              [10, dest]
            end
            trade.take_caravan_to(12)
          end

          it 'does not ask you to move when the room resolves on its own a moment later' do
            polls = 0
            allow(trade).to receive(:pause) { location[:id] = 10 if (polls += 1) == 3 }
            trade.take_caravan_to(12)
            expect(messages).not_to include(unknown_room_message)
            expect(steps).to eq(%w[north east])
          end

          it 'returns without walking when the now-known room is the destination' do
            allow(trade).to receive(:pause) { location[:id] = 12 }
            trade.take_caravan_to(12)
            expect(steps).to be_empty
          end
        }
      end

      describe 'stepping into an unknown room part-way' do
        include_examples 'for both forms of unknown room', proc {
          it 'waits for the room, re-plans from there and finishes the walk' do
            # The north exit from 10 lands somewhere Lich can't place; moving
            # on and back (the 1 s wait after the message) puts you in 11.
            exits[10] = ['north', nil]
            allow(trade).to receive(:pause) { |secs| location[:id] = 11 if secs == 1 }
            location[:id] = 10
            trade.take_caravan_to(12)
            expect(messages).to include(unknown_room_message)
            expect(steps).to eq(%w[north east])
            expect(trade).to have_received(:compute_path).twice
          end

          it 'polls quietly for 2 seconds before asking you to move' do
            exits[10] = ['north', nil]
            allow(trade).to receive(:pause) { |secs| location[:id] = 11 if secs == 1 }
            location[:id] = 10
            trade.take_caravan_to(12)
            expect(trade).to have_received(:pause).with(0.25).exactly(8).times
          end

          it 'does not ask you to move when the room resolves on its own a moment later' do
            exits[10] = ['north', nil]
            polls = 0
            allow(trade).to receive(:pause) { location[:id] = 11 if location[:id].nil? && (polls += 1) == 3 }
            location[:id] = 10
            trade.take_caravan_to(12)
            expect(messages).not_to include(unknown_room_message)
            expect(steps).to eq(%w[north east])
            expect(trade).to have_received(:compute_path).twice
          end

          it 'never steps with a missing direction while the room is unknown' do
            exits[10] = ['north', nil]
            allow(trade).to receive(:pause) { location[:id] = 11 if location[:id].nil? }
            location[:id] = 10
            trade.take_caravan_to(12)
            expect(steps).not_to include(nil)
          end
        }
      end

      it 'walks a known route without waiting or messaging (unchanged)' do
        location[:id] = 10
        expect(trade).not_to receive(:pause)
        trade.take_caravan_to(12)
        expect(steps).to eq(%w[north east])
        expect(messages).to be_empty
      end

      it 'returns straight away when already at the destination (unchanged)' do
        location[:id] = 12
        expect(trade).not_to receive(:command_caravan?)
        trade.take_caravan_to(12)
        expect(steps).to be_empty
      end
    end

    # The real track_caravan, wait_for_caravan, caravan_check?, recall_caravan?,
    # command_caravan?, compute_path and get_next_dir, so the order of the waits
    # is what's tested. Only the game is simulated: rooms in an east-west line,
    # a clock that moves on with each pause, a caravan that follows a room at a
    # time, a second behind, once told to (setting the arrival flag when it
    # reaches you), and a player who does exactly what the unknown-room message
    # says: moves one room away, then comes back back_after seconds later only
    # if told to.
    describe '#take_caravan_to when you move one room away' do
      let(:echoes) { [] }
      let(:world) do
        { player: 10, caravan: 10, unknown: [], following: false, clock: Time.at(1_000_000),
          away_dir: 'west', away_since: nil, coming_back: false, back_after: 5, apart: 0, follow_told_from: [], steps: [],
          caravan_barred: [], gone_back: false }
      end

      def leave(dir)
        world[:unknown].delete(world[:player]) # coming back in lets Lich place the room
        world[:player] += dir == 'east' ? 1 : -1
      end

      # One pause: the player reacts to the message, then the caravan moves.
      def tick(secs)
        world[:clock] += secs
        instruction = messages.find { |m| m =~ /doesn't know what room/ }
        if instruction && world[:away_since].nil?
          leave(world[:away_dir])
          world[:away_since] = world[:clock]
          world[:coming_back] = instruction.match?(/return|come straight back/)
        elsif world[:coming_back] && world[:clock] - world[:away_since] >= world[:back_after]
          leave(world[:away_dir] == 'west' ? 'east' : 'west')
          world[:coming_back] = false
        elsif !world[:gone_back] && messages.any? { |m| m =~ /caravan hasn't caught up/ }
          # Told the caravan can't reach you: walk back to it.
          leave(world[:caravan] > world[:player] ? 'east' : 'west')
          world[:gone_back] = true
        end
        world[:apart] = 0 if world[:caravan] == world[:player]
        return unless world[:following] && world[:caravan] != world[:player]

        # The caravan takes a second to follow you into the next room.
        world[:apart] += secs
        return if world[:apart] < 1

        world[:apart] = 0
        next_room = world[:caravan] + (world[:player] <=> world[:caravan])
        return if world[:caravan_barred].include?(next_room) # a room the caravan can't enter

        world[:caravan] = next_room
        Flags['caravan-arrived'] = true if world[:caravan] == world[:player]
      end

      before do
        allow(Time).to receive(:now) { world[:clock] }
        allow(trade).to receive(:pause) do |secs = 1|
          raise 'take_caravan_to is spinning' if world[:clock] - Time.at(1_000_000) > 600

          tick(secs.to_f)
        end
        allow(Room).to receive(:current) do
          next nil if world[:unknown].include?(world[:player])

          here = world[:player]
          double('room', id: here, title: ['[Road]'], wayto: { (here + 1).to_s => 'east', (here - 1).to_s => 'west' })
        end
        allow(Map).to receive(:dijkstra) do |from, _to|
          [(8..14).to_h { |id| [id, id == from ? nil : id - (id <=> from)] }, {}]
        end
        allow(DRRoom).to receive(:room_objs) { world[:caravan] == world[:player] ? ['an ox-drawn caravan'] : [] }
        allow(DRC).to receive(:bput) do |command, *_replies|
          case command
          when 'recall caravan'
            if world[:caravan] == world[:player]
              'You seem to recall that you left your ox-drawn caravan right behind you.'
            else
              'You recall that your ox-drawn caravan is to the west.'
            end
          when /to follow/
            world[:follow_told_from] << world[:player]
            world[:following] = true
            'You grab hold of your ox-drawn caravan harness and make it follow.'
          else
            'You grab hold of your ox-drawn caravan harness and make it wait.'
          end
        end
        allow(trade).to receive(:move) do |dir|
          world[:steps] << [world[:player], dir, world[:caravan] == world[:player]]
          leave(dir)
          tick(0.5)
        end
        %i[be_outside_caravan forbid_certain_transport walk_training training_cleanup].each do |name|
          allow(trade).to receive(name)
        end
        allow(trade).to receive(:handle_special_room?).and_return(false)
        allow(trade).to receive(:echo) { |text| echoes << text }
        allow(Trade).to receive(:restore_certain_transport)
        trade.instance_variable_set(:@caravan_room_descriptions, {})
        Flags.add('caravan-arrived', /^Your .*, following you/)
      end

      def caravan_left_behind
        world[:steps].reject(&:last).map { |from, dir, _| "#{from} #{dir}" }
      end

      %w[west east].each do |away|
        context "when Lich doesn't know the start room and you step #{away} and back" do
          before do
            world[:unknown] << 10
            world[:away_dir] = away
          end

          it 'tells the caravan to follow only once you are back in its room' do
            trade.take_caravan_to(13)
            expect(world[:follow_told_from]).to eq([10])
          end

          it 'leads the caravan all the way, never stepping without it' do
            trade.take_caravan_to(13)
            expect(world.values_at(:player, :caravan)).to eq([13, 13])
            expect(caravan_left_behind).to be_empty
          end

          it 'asks you to come straight back to the caravan' do
            trade.take_caravan_to(13)
            expect(messages).to include(a_string_matching(/come straight back to your caravan/))
          end

          it 'does not warn that the caravan is missing while you walk back to it' do
            trade.take_caravan_to(13)
            expect(echoes).not_to include(a_string_matching(/CARAVAN NOT PRESENT/))
          end

          it 'keeps waiting for you, with a reminder, however long you take to come back' do
            world[:back_after] = 200
            trade.take_caravan_to(13)
            expect(world[:follow_told_from]).to eq([10])
            expect(echoes).not_to include(a_string_matching(/CARAVAN NOT PRESENT/))
            expect(messages).to include('Still waiting for you to come back to your caravan.')
            expect(caravan_left_behind).to be_empty
          end
        end

        context "when a step lands in a room Lich can't place and you step #{away} from there" do
          before do
            world[:unknown] << 11
            world[:away_dir] = away
          end

          it 'waits for the caravan to catch up before the next step' do
            trade.take_caravan_to(13)
            expect(caravan_left_behind).to be_empty
            expect(world.values_at(:player, :caravan)).to eq([13, 13])
          end

          it 'tells you to stay in the room you moved to, since the caravan follows you there' do
            trade.take_caravan_to(13)
            instructions = messages.grep(/doesn't know what room/)
            expect(instructions).not_to be_empty
            expect(instructions).to all(include('Your caravan will follow you'))
            expect(instructions).not_to include(a_string_matching(/return|come straight back/))
          end

          it "tells you to move somewhere the caravan can follow" do
            trade.take_caravan_to(13)
            expect(messages.grep(/doesn't know what room/)).to all(include('somewhere your caravan can follow'))
          end

          it 'carries on from the room you moved to without you stepping back' do
            trade.take_caravan_to(13)
            # The script's steps only: 10 east into 11 (unknown), then on from
            # wherever you moved to, with the caravan beside you each time.
            expected = away == 'west' ? [[10, 'east'], [10, 'east'], [11, 'east'], [12, 'east']] : [[10, 'east'], [12, 'east']]
            expect(world[:steps].map { |from, dir, _| [from, dir] }).to eq(expected)
          end
        end
      end

      # Rooms are in a line, so only a room off the route (west of 11, with the
      # destination east) can be one the caravan can't enter.
      context "when a step lands in a room Lich can't place and you step west into a room the caravan can't enter" do
        before do
          world[:unknown] << 11
          world[:away_dir] = 'west'
          world[:caravan_barred] << 10
        end

        it "tells you to go back to the caravan if it can't follow you, then carries on with it" do
          trade.take_caravan_to(13)
          expect(messages).to include(a_string_matching(/caravan hasn't caught up/))
          expect(world.values_at(:player, :caravan)).to eq([13, 13])
          expect(caravan_left_behind).to be_empty
        end

        it 'waits about 15 seconds for the caravan before telling you to go back' do
          told_at = nil
          allow(DRC).to receive(:message) do |text|
            messages << text
            told_at ||= world[:clock] if text.include?("caravan hasn't caught up")
          end
          trade.take_caravan_to(13)
          expect(told_at - world[:away_since]).to be_between(15, 17)
        end
      end

      it 'walks a known route with the caravan in tow (unchanged)' do
        trade.take_caravan_to(13)
        expect(world[:steps].map { |from, dir, with| [from, dir, with] })
          .to eq([[10, 'east', true], [11, 'east', true], [12, 'east', true]])
        expect(messages).to be_empty
      end
    end

    describe '#close_out_stable' do
      let(:stable_id) { 50 }
      let(:paid_in) { [] }

      before do
        trade.instance_variable_set(:@caravan_training_skills, {})
        trade.instance_variable_set(:@exit, nil)
        UserVars.last_seen_caravan = { 'room' => nil, 'stabled' => false }
        allow(trade).to receive(:turn_in_items)
        # Like the real tag_to_id: pathfinding from an unknown room fails.
        allow(DRCT).to receive(:tag_to_id).with('caravan_stable') { location[:id].nil? ? nil : stable_id }
        allow(trade).to receive(:take_caravan_to).and_call_original
        allow(trade).to receive(:be_outside_caravan)
        allow(trade).to receive(:track_caravan)
        allow(trade).to receive(:forbid_certain_transport)
        allow(trade).to receive(:command_caravan?).and_return(true)
        allow(trade).to receive(:caravan_check?).and_return(true)
        allow(trade).to receive(:caravan_present?).and_return(true)
        allow(trade).to receive(:save_caravan_position)
        allow(trade).to receive(:training_cleanup)
        allow(trade).to receive(:wait_for_caravan)
        allow(trade).to receive(:handle_special_room?).and_return(false)
        walked = 0
        allow(trade).to receive(:walk_training) { raise 'take_caravan_to is spinning' if (walked += 1) > 20 }
        allow(trade).to receive(:compute_path) { |dest| [location[:id], dest] }
        allow(trade).to receive(:get_next_dir).and_return('west')
        allow(trade).to receive(:step) { location[:id] = stable_id }
        allow(Trade).to receive(:restore_certain_transport)
        allow(DRC).to receive(:bput) do |command, *_|
          paid_in << location[:id] if command.start_with?('pay')
          command == 'pay' ? 'The cost for stabling is 12 Kronars for a caravan' : 'The stable boy who runs up and leads your caravan away'
        end
      end

      include_examples 'for both forms of unknown room', proc {
        it 'does not pay for stabling in the room you are standing in' do
          walked = 0
          # Stay lost for a while, then let Lich place you in room 10.
          allow(trade).to receive(:pause) { location[:id] = 10 if (walked += 1) > 2 }
          expect { trade.close_out_stable }.to raise_error(SystemExit)
          expect(paid_in).to all(eq(stable_id))
          expect(paid_in).not_to be_empty
        end

        it 'looks up the stable only once the room is known, then leads the caravan there' do
          allow(trade).to receive(:pause) { |secs| location[:id] = 10 if secs == 1 }
          expect { trade.close_out_stable }.to raise_error(SystemExit)
          expect(messages).to include(unknown_room_message)
          expect(trade).to have_received(:take_caravan_to).with(stable_id)
          expect(UserVars.last_seen_caravan['stabled']).to be(true)
        end
      }

      it 'stops without paying when no stable can be found from a known room' do
        location[:id] = 10
        allow(DRCT).to receive(:tag_to_id).with('caravan_stable').and_return(nil)
        expect(trade).not_to receive(:step)
        expect { trade.close_out_stable }.to raise_error(SystemExit)
        expect(paid_in).to be_empty
        expect(messages).to include(a_string_matching(/No destination room was found/))
      end

      it 'does not log out when it stops without a stable' do
        location[:id] = 10
        trade.instance_variable_set(:@exit, true)
        allow(DRCT).to receive(:tag_to_id).with('caravan_stable').and_return(nil)
        expect { trade.close_out_stable }.to raise_error(SystemExit)
        sent = []
        sent << $sent_messages.pop until $sent_messages.empty?
        expect(sent).not_to include('exit')
      end

      it 'leads to the stable and pays there from a known room (unchanged)' do
        location[:id] = 10
        expect { trade.close_out_stable }.to raise_error(SystemExit)
        expect(paid_in).to eq([stable_id, stable_id])
        expect(UserVars.last_seen_caravan['stabled']).to be(true)
      end
    end

    describe '#close_out' do
      let(:outpost_lookups) { [] }

      before do
        trade.instance_variable_set(:@use_stable, false)
        trade.instance_variable_set(:@exit, nil)
        allow(trade).to receive(:find_closest_id) do |entity|
          outpost_lookups << [entity, location[:id]]
          { 'trader_outpost' => 20, 'shipment_clerk' => 21 }[entity]
        end
        allow(trade).to receive(:take_caravan_to)
        allow(trade).to receive(:caravan_present?).and_return(true)
        allow(trade).to receive(:turn_in_items)
        allow(trade).to receive(:empty_storage_box)
        allow(trade).to receive(:should_knit?).and_return(true)
        allow(DRCT).to receive(:walk_to).and_return(true)
        allow(DRC).to receive(:bput).and_return('You drop')
      end

      include_examples 'for both forms of unknown room', proc {
        it 'waits for the room before picking the nearest outpost' do
          allow(trade).to receive(:pause) { |secs| location[:id] = 10 if secs == 1 }
          expect { trade.close_out }.to raise_error(SystemExit)
          expect(messages).to include(unknown_room_message)
          expect(outpost_lookups.first).to eq(['trader_outpost', 10])
          expect(trade).to have_received(:take_caravan_to).with(20)
        end

        it 'waits for you to come back to the caravan before picking the nearest outpost' do
          # Moving away puts you in 9; you come back to the caravan in 10 a few
          # seconds later.
          away_for = 0
          allow(trade).to receive(:pause) do |secs|
            if location[:id].nil?
              location[:id] = 9 if secs == 1
            elsif location[:id] == 9 && (away_for += secs) >= 5
              location[:id] = 10
            end
          end
          allow(trade).to receive(:caravan_present?) { location[:id] == 10 }
          expect { trade.close_out }.to raise_error(SystemExit)
          expect(messages).to include(a_string_matching(/come straight back to your caravan/))
          expect(outpost_lookups.first).to eq(['trader_outpost', 10])
        end
      }

      it 'picks the nearest outpost straight away from a known room (unchanged)' do
        location[:id] = 10
        expect(trade).not_to receive(:pause)
        expect { trade.close_out }.to raise_error(SystemExit)
        expect(outpost_lookups.first).to eq(['trader_outpost', 10])
      end
    end

    describe '#wait_for_known_room_at_caravan' do
      it "does not wait for a caravan whose look isn't known, which could never match" do
        trade.instance_variable_set(:@caravan, OpenStruct.new)
        allow(trade).to receive(:pause) { |secs| location[:id] = 9 if secs == 1 }
        expect(trade).not_to receive(:caravan_present?)
        trade.wait_for_known_room_at_caravan
        expect(location[:id]).to eq(9)
      end

      it 'returns straight away from a known room, without looking for the caravan (unchanged)' do
        location[:id] = 10
        expect(trade).not_to receive(:pause)
        expect(trade).not_to receive(:caravan_present?)
        trade.wait_for_known_room_at_caravan
        expect(messages).to be_empty
      end
    end

    describe '#recall_caravan?' do
      before do
        allow(DRC).to receive(:bput).and_return("You don't recall where you left your caravan.")
      end

      include_examples 'for both forms of unknown room', proc {
        it 'asks the game when the caravan was last seen in an unknown room' do
          trade.instance_variable_set(:@last_seen_caravan, [nil, Time.now])
          expect(DRC).to receive(:bput).with('recall caravan', anything).and_return("You don't recall where you left your caravan.")
          expect(trade.recall_caravan?).to be(false)
        end

        it 'asks the game when the caravan has never been seen' do
          trade.instance_variable_set(:@last_seen_caravan, [])
          expect(DRC).to receive(:bput).with('recall caravan', anything).and_return("You don't recall where you left your caravan.")
          expect(trade.recall_caravan?).to be(false)
        end

        it 'still trusts the game saying the caravan is right behind you' do
          allow(DRC).to receive(:bput).and_return('You seem to recall that you left your ox-drawn caravan right behind you.')
          expect(trade.recall_caravan?).to be(true)
        end
      }

      it 'skips the game check when the caravan was seen here moments ago (unchanged)' do
        location[:id] = 10
        trade.instance_variable_set(:@last_seen_caravan, [10, Time.now])
        expect(DRC).not_to receive(:bput)
        expect(trade.recall_caravan?).to be(true)
      end

      it 'asks the game when the caravan was seen in another room (unchanged)' do
        location[:id] = 10
        trade.instance_variable_set(:@last_seen_caravan, [11, Time.now])
        expect(DRC).to receive(:bput).with('recall caravan', anything)
        trade.recall_caravan?
      end
    end

    describe '#wait_for_caravan' do
      before do
        trade.instance_variable_set(:@caravan_being_led, false)
        allow(trade).to receive(:pause)
      end

      include_examples 'for both forms of unknown room', proc {
        it 'waits for the caravan when it was last seen in an unknown room' do
          trade.instance_variable_set(:@last_seen_caravan, [nil, Time.now])
          Flags['caravan-arrived'] = nil
          allow(trade).to receive(:pause) { Flags['caravan-arrived'] = true }
          trade.wait_for_caravan
          expect(trade).to have_received(:pause).at_least(:once)
          expect(Flags['caravan-arrived']).to be_falsey
        end
      }

      it 'returns straight away when the caravan was seen here moments ago (unchanged)' do
        location[:id] = 10
        trade.instance_variable_set(:@last_seen_caravan, [10, Time.now])
        expect(trade).not_to receive(:pause)
        trade.wait_for_caravan
      end
    end

    describe '#return_to_caravan' do
      before do
        allow(DRCT).to receive(:walk_to).and_return(true)
      end

      include_examples 'for both forms of unknown room', proc {
        it 'carries on when the caravan, last seen in an unknown room, is right here' do
          trade.instance_variable_set(:@last_seen_caravan, [nil, Time.now])
          allow(trade).to receive(:caravan_check?).and_return(true)
          expect(DRCT).not_to receive(:walk_to)
          expect { trade.return_to_caravan }.not_to raise_error
        end

        it 'stops when the caravan was last seen in an unknown room and is not here' do
          trade.instance_variable_set(:@last_seen_caravan, [nil, Time.now])
          allow(trade).to receive(:caravan_check?).and_return(false)
          expect { trade.return_to_caravan }.to raise_error(SystemExit)
          expect(messages).to include(a_string_matching(/Lost track of the caravan/))
        end

        it 'walks back to a known last-seen room (unchanged)' do
          trade.instance_variable_set(:@last_seen_caravan, [10, Time.now])
          expect(DRCT).to receive(:walk_to).with(10)
          trade.return_to_caravan
        end
      }

      it 'stops from a known room when the caravan was last seen in an unknown room and is not here' do
        location[:id] = 10
        trade.instance_variable_set(:@last_seen_caravan, [nil, Time.now])
        allow(trade).to receive(:caravan_check?).and_return(false)
        expect(DRCT).not_to receive(:walk_to)
        expect { trade.return_to_caravan }.to raise_error(SystemExit)
      end

      it 'stays put when already in the last-seen room (unchanged)' do
        location[:id] = 10
        trade.instance_variable_set(:@last_seen_caravan, [10, Time.now])
        expect(DRCT).not_to receive(:walk_to)
        trade.return_to_caravan
      end

      # A fresh @last_seen_caravan ([]) means the caravan hasn't been seen in
      # your room since the script started. That is not an unknown room, so
      # return_to_caravan keeps its old no-op: nothing to walk back to.
      [[:known, 10], [:unknown, nil]].each do |label, id|
        it "does nothing when the caravan has never been seen (#{label} room, unchanged)" do
          location[:id] = id
          trade.instance_variable_set(:@last_seen_caravan, [])
          allow(trade).to receive(:caravan_check?).and_return(false)
          expect(DRCT).not_to receive(:walk_to)
          expect { trade.return_to_caravan }.not_to raise_error
          expect(messages).to be_empty
        end
      end

      it 'walks back from another known room (unchanged)' do
        location[:id] = 11
        trade.instance_variable_set(:@last_seen_caravan, [10, Time.now])
        expect(DRCT).to receive(:walk_to).with(10)
        trade.return_to_caravan
      end
    end
  end

  # Issue #7679: since the 2026-03-22 mapdb update, the only map route between
  # Therengia's east (Therenborough, Langenfirth, Riverhaven) and west
  # (Fornsted, Hvaral, Muspar'i) climbs Ker'Leor's fallen tree and fallen
  # trunk. You climb over; the caravan can't follow, and the script waited for
  # it forever. The map below keeps that shape: Fornsted is the nearest outpost
  # to Therenborough, but only over the tree and trunk. Room is the map, and
  # Map.dijkstra skips an exit with no timeto, as Lich's does, so the real
  # forbid_certain_transport and restore_certain_transport decide what the
  # caravan can reach.
  describe "Therengia split by Ker'Leor's fallen tree" do
    # [from, to, way there, way back, time]
    let(:edges) do
      [[3155, 3407, 'east', 'west', 13.0],
       [3155, 386, 'south', 'north', 17.0],
       [3155, 3640, 'northwest', 'southeast', 1.0],
       [3640, 3641, 'climb fallen tree', 'climb fallen tree', 0.2],
       [3641, 3647, 'north', 'south', 1.0],
       [3647, 3648, 'climb fallen trunk', 'climb fallen trunk', 0.2],
       [3648, 3693, 'west', 'east', 1.0],
       [3693, 3751, 'north', 'south', 10.0],
       [3751, 14_282, 'go barge', 'go barge', 800.0]]
    end
    let(:rooms) do
      map = Hash.new { |all, id| all[id] = OpenStruct.new(id: id, wayto: {}, timeto: {}) }
      edges.each do |from, to, there, back, time|
        map[from].wayto[to.to_s] = there
        map[from].timeto[to.to_s] = time
        map[to].wayto[from.to_s] = back
        map[to].timeto[from.to_s] = time
      end
      map
    end
    let(:outposts) do
      { 'Therenborough' => 3155, 'Langenfirth' => 3407, 'Riverhaven' => 386,
        'Fornsted' => 3693, 'Hvaral' => 3751, "Muspar'i" => 14_282 }
    end
    let(:location) { { id: 3155 } }
    let(:clock) { { now: Time.at(1_000_000) } }
    # The contracts in your contract container, in order.
    let(:held) { [] }
    let(:dropped) { [] }
    let(:messages) { [] }

    def contract(from, to, expires_after: nil)
      OpenStruct.new(origin_town: from, destination_town: to, expired: false, expires_after: expires_after)
    end

    def destination_town
      outposts.key(trade.instance_variable_get(:@current_caravan_destination))
    end

    before do
      allow(Room).to receive(:[]) { |id| rooms[id.to_i] }
      allow(Room).to receive(:current) { rooms[location[:id]] }
      allow(Map).to receive(:dijkstra) do |source, _destination = nil|
        distances = { source => 0 }
        previous = {}
        queue = [source]
        until queue.empty?
          here = queue.min_by { |id| distances[id] }
          queue.delete(here)
          rooms[here].wayto.each_key do |key|
            time = rooms[here].timeto[key]
            next unless time

            there = key.to_i
            next if distances[there] && distances[there] <= distances[here] + time

            distances[there] = distances[here] + time
            previous[there] = here
            queue << there
          end
        end
        [previous, distances]
      end
      # Like the real one: closest first, rooms it can't reach dropped.
      allow(DRCT).to receive(:sort_destinations) do |ids|
        _previous, distances = Map.dijkstra(Room.current.id)
        ids.map(&:to_i).select { |id| distances[id] }.sort_by { |id| distances[id] }
      end
      allow(Time).to receive(:now) { clock[:now] }
      allow(trade).to receive(:pause) do |secs = 1|
        clock[:now] += secs
        raise 'waiting forever' if clock[:now] - Time.at(1_000_000) > 86_400

        held.each { |c| c.expired = true if c.expires_after && clock[:now] - Time.at(1_000_000) >= c.expires_after }
      end
      allow(trade).to receive(:gather_contracts) { trade.instance_variable_set(:@held_contracts, held.dup) }
      allow(trade).to receive(:find_crates)
      in_hand = nil
      allow(DRC).to receive(:bput) do |command, *_|
        if (ordinal = command[/^get my (\w+) contract/, 1])
          in_hand = held.delete_at($ORDINALS.index(ordinal))
        elsif command == 'drop my contract'
          dropped << in_hand
        end
        'You get'
      end
      allow(DRC).to receive(:message) { |text| messages << text }
      allow(trade).to receive(:echo)
      allow(trade).to receive(:close_out) { exit }

      towns = outposts.to_h do |name, id|
        [name, { 'trader_outpost' => { 'id' => id }, 'shipment_clerk' => { 'id' => id }, 'trade_minister' => { 'id' => id } }]
      end
      trade.instance_variable_set(:@town_data, towns)
      trade.instance_variable_set(:@trading_towns, {})
      trade.instance_variable_set(:@force_contract_from, [])
      trade.instance_variable_set(:@inconvenient_towns, ['Dirge', 'Riverhaven', "Muspar'i", 'Leth Deriel', 'Ain Ghazal'])
      trade.instance_variable_set(:@emergency_delivery_town, nil)
      trade.instance_variable_set(:@closeup, nil)
      trade.instance_variable_set(:@time_to_end, nil)
    end

    # What run does at an outpost before setting off.
    def plan_next_leg
      trade.mark_towns
      trade.check_for_emergency_delivery
      trade.set_next_outpost
    end

    describe '#forbid_certain_transport' do
      it 'takes out the fallen tree and trunk both ways, and restore_certain_transport puts them back' do
        trade.forbid_certain_transport
        expect([rooms[3640].timeto['3641'], rooms[3641].timeto['3640'],
                rooms[3647].timeto['3648'], rooms[3648].timeto['3647']]).to all(be_nil)
        Trade.restore_certain_transport
        expect([rooms[3640].timeto['3641'], rooms[3641].timeto['3640'],
                rooms[3647].timeto['3648'], rooms[3648].timeto['3647']]).to all(eq(0.2))
      end
    end

    describe '#set_next_outpost' do
      it 'heads for Langenfirth, not the nearer Fornsted that only the tree reaches' do
        held.push(contract('Therenborough', 'Fornsted'), contract('Riverhaven', 'Langenfirth'))
        plan_next_leg
        expect(destination_town).to eq('Langenfirth')
      end

      it 'still trades across the west: from Fornsted it heads for Hvaral' do
        location[:id] = 3693
        held.push(contract('Fornsted', 'Hvaral'))
        plan_next_leg
        expect(destination_town).to eq('Hvaral')
      end

      context 'when every contract you hold is for the other half' do
        before do
          held.push(contract('Therenborough', 'Fornsted', expires_after: 1800),
                    contract('Langenfirth', 'Hvaral'),
                    contract('Riverhaven', "Muspar'i"))
        end

        it 'waits at the outpost for one to expire, drops it, then picks the town whose minister is free again' do
          plan_next_leg
          expect(messages).to include(a_string_matching(/can't reach any town you hold a contract for/))
          expect(dropped.map(&:destination_town)).to eq(['Fornsted'])
          expect(held.map(&:destination_town)).to eq(%w[Hvaral Muspar'i])
          expect(destination_town).to eq('Therenborough')
          expect(clock[:now] - Time.at(1_000_000)).to be_between(1800, 2100)
        end

        it 'drops a contract that has already expired without waiting' do
          held.first.expired = true
          plan_next_leg
          expect(trade).not_to have_received(:pause)
          expect(destination_town).to eq('Therenborough')
        end

        it 'when closing up, waits for them all to expire and then returns the caravan' do
          held.each_with_index { |c, i| c.expires_after = 600 * (i + 1) }
          trade.instance_variable_set(:@closeup, true)
          expect { plan_next_leg }.to raise_error(SystemExit)
          expect(trade).to have_received(:close_out)
          expect(dropped.size).to eq(3)
        end

        it 'notices the time limit passing while it waits' do
          trade.instance_variable_set(:@time_to_end, clock[:now] + 600)
          held.each { |c| c.expires_after = 3600 }
          expect { plan_next_leg }.to raise_error(SystemExit)
          expect(trade.instance_variable_get(:@closeup)).to be(true)
        end
      end

      it 'does not wait with no contract to expire, and reports the error as before' do
        trade.instance_variable_set(:@force_contract_from, %w[Therenborough Langenfirth Riverhaven])
        plan_next_leg
        expect(trade).not_to have_received(:pause)
        expect(trade.instance_variable_get(:@current_caravan_destination)).to be_nil
        expect(messages).to include(a_string_matching(/encountered an error/))
      end
    end

    describe '#check_for_emergency_delivery' do
      it "doesn't count contracts for Muspar'i, which the caravan can't reach from the east" do
        3.times { held.push(contract('Therenborough', "Muspar'i")) }
        trade.mark_towns
        trade.check_for_emergency_delivery
        expect(trade.instance_variable_get(:@emergency_delivery_town)).to be_nil
      end

      it 'still calls an emergency for Riverhaven' do
        3.times { held.push(contract('Langenfirth', 'Riverhaven')) }
        trade.mark_towns
        trade.check_for_emergency_delivery
        expect(trade.instance_variable_get(:@emergency_delivery_town)).to eq('Riverhaven')
      end

      it "doesn't call an emergency for Fornsted however many you hold for it" do
        2.times { held.push(contract('Langenfirth', 'Fornsted')) }
        trade.mark_towns
        trade.check_for_emergency_delivery
        expect(trade.instance_variable_get(:@emergency_delivery_town)).to be_nil
      end

      # From Riverhaven, the western outposts have no distance at all. They
      # must drop out rather than be compared with the ones that do.
      it 'heads for the emergency town by way of the outposts the caravan can reach' do
        3.times { held.push(contract('Langenfirth', 'Riverhaven')) }
        location[:id] = 3407
        plan_next_leg
        # Therenborough is on the way and its minister has a contract for you.
        expect(destination_town).to eq('Therenborough')
      end
    end

    describe '#take_caravan_to' do
      let(:steps) { [] }

      before do
        trade.instance_variable_set(:@caravan, OpenStruct.new(adjective: 'ox-drawn', noun: 'caravan'))
        trade.instance_variable_set(:@last_seen_caravan, [])
        trade.instance_variable_set(:@step_toggle, 0)
        %i[be_outside_caravan wait_for_known_room_at_caravan track_caravan save_caravan_position
           training_cleanup wait_for_caravan walk_training].each { |name| allow(trade).to receive(name) }
        allow(trade).to receive(:command_caravan?).and_return(true)
        allow(trade).to receive(:caravan_check?).and_return(true)
        allow(trade).to receive(:handle_special_room?).and_return(false)
        allow(trade).to receive(:step) do |dir|
          steps << dir
          raise 'take_caravan_to is spinning' if steps.size > 20

          location[:id] = rooms[location[:id]].wayto.key(dir).to_i
        end
      end

      it 'stops with a message, without the caravan following, when it has no way to the room' do
        expect(trade).not_to receive(:command_caravan?).with('follow')
        expect { trade.take_caravan_to(3693) }.to raise_error(SystemExit)
        expect(steps).to be_empty
        expect(messages).to include(a_string_matching(/no way to room 3693/))
      end

      it 'walks the west without the tree: Fornsted to Hvaral' do
        location[:id] = 3693
        trade.take_caravan_to(3751)
        expect(steps).to eq(['north'])
        expect(location[:id]).to eq(3751)
      end
    end
  end
end
