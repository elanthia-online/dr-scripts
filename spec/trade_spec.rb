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
            allow(trade).to receive(:pause) { location[:id] = 10 }
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
          allow(trade).to receive(:pause) { location[:id] = 10 }
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
        allow(trade).to receive(:turn_in_items)
        allow(trade).to receive(:empty_storage_box)
        allow(trade).to receive(:should_knit?).and_return(true)
        allow(DRCT).to receive(:walk_to).and_return(true)
        allow(DRC).to receive(:bput).and_return('You drop')
      end

      include_examples 'for both forms of unknown room', proc {
        it 'waits for the room before picking the nearest outpost' do
          allow(trade).to receive(:pause) { location[:id] = 10 }
          expect { trade.close_out }.to raise_error(SystemExit)
          expect(messages).to include(unknown_room_message)
          expect(outpost_lookups.first).to eq(['trader_outpost', 10])
          expect(trade).to have_received(:take_caravan_to).with(20)
        end
      }

      it 'picks the nearest outpost straight away from a known room (unchanged)' do
        location[:id] = 10
        expect(trade).not_to receive(:pause)
        expect { trade.close_out }.to raise_error(SystemExit)
        expect(outpost_lookups.first).to eq(['trader_outpost', 10])
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
end
