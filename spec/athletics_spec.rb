# frozen_string_literal: true

require 'ostruct'
require 'yaml'

require_relative 'spec_helper'

load_lic_class('athletics.lic', 'Athletics')

RSpec.describe Athletics do
  before(:each) do
    reset_data

    allow(DRC).to receive(:wait_for_script_to_complete)
    allow(DRC).to receive(:bput)
    allow(DRC).to receive(:message)
    allow(DRCT).to receive(:walk_to).and_return(true)
  end

  describe '#outdoorsmanship_waiting' do
    let(:athletics) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@outdoorsmanship_rooms, [])
        a.instance_variable_set(:@settings, OpenStruct.new(held_athletics_items: []))
      end
    end

    context 'when skip_magic is enabled' do
      before do
        athletics.instance_variable_set(:@skip_magic, true)
      end

      it 'forwards skip_magic to the outdoorsmanship script' do
        expect(DRC).to receive(:wait_for_script_to_complete).with(
          'outdoorsmanship',
          [4, "room=#{Room.current.id}", 'rock', 'skip_magic']
        )
        athletics.outdoorsmanship_waiting(4)
      end
    end

    context 'when skip_magic is not set' do
      before do
        athletics.instance_variable_set(:@skip_magic, nil)
      end

      it 'passes an empty string for the skip_magic argument' do
        expect(DRC).to receive(:wait_for_script_to_complete).with(
          'outdoorsmanship',
          [3, "room=#{Room.current.id}", 'rock', '']
        )
        athletics.outdoorsmanship_waiting(3)
      end
    end

    context 'with outdoorsmanship rooms configured' do
      before do
        athletics.instance_variable_set(:@skip_magic, nil)
        athletics.instance_variable_set(:@outdoorsmanship_rooms, [5678, 9012])
      end

      it 'walks to a random room before starting outdoorsmanship' do
        expect(DRCT).to receive(:walk_to).with(satisfy { |id| [5678, 9012].include?(id) })
        athletics.outdoorsmanship_waiting(4)
      end
    end

    context 'when the outdoorsmanship room cannot be reached' do
      before do
        athletics.instance_variable_set(:@skip_magic, nil)
        athletics.instance_variable_set(:@outdoorsmanship_rooms, [5678])
        allow(DRCT).to receive(:walk_to).and_return(false)
      end

      it 'still trains outdoorsmanship where it stands' do
        expect(DRC).to receive(:wait_for_script_to_complete).with('outdoorsmanship', [4, "room=#{Room.current.id}", 'rock', ''])
        athletics.outdoorsmanship_waiting(4)
      end
    end

    context 'with no outdoorsmanship rooms configured' do
      before do
        athletics.instance_variable_set(:@skip_magic, nil)
        athletics.instance_variable_set(:@outdoorsmanship_rooms, [])
      end

      it 'does not walk to a room before starting outdoorsmanship' do
        expect(DRCT).not_to receive(:walk_to)
        athletics.outdoorsmanship_waiting(4)
      end
    end
  end

  describe '#done_training?' do
    let(:athletics) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@end_exp, 29)
      end
    end

    context 'when Athletics XP is below the target' do
      before { Harness::DRSkill._set_xp('Athletics', 15) }

      it 'returns false' do
        expect(athletics.done_training?).to be false
      end
    end

    context 'when Athletics XP meets the target' do
      before { Harness::DRSkill._set_xp('Athletics', 29) }

      it 'returns true' do
        expect(athletics.done_training?).to be true
      end
    end

    context 'when Athletics XP exceeds the target' do
      before { Harness::DRSkill._set_xp('Athletics', 34) }

      it 'returns true' do
        expect(athletics.done_training?).to be true
      end
    end
  end

  # ===========================================================================
  # #riverhaven_athletics specs
  #
  # Validates the Riverhaven climbing route: room visits, rank-gated
  # sections, and that it never falls back to crossing_athletics.
  # ===========================================================================
  describe '#riverhaven_athletics' do
    let(:athletics) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@end_exp, 29)
      end
    end

    before(:each) do
      allow(athletics).to receive(:move)
    end

    context 'at low rank (below 10)' do
      before do
        call_count = 0
        Harness::DRSkill._set_modrank('Athletics', 5)
        allow(athletics).to receive(:done_training?) { (call_count += 1) > 1 }
      end

      it 'walks the base route without the tree climb' do
        athletics.riverhaven_athletics

        expect(DRCT).to have_received(:walk_to).with(12821)
        expect(DRCT).to have_received(:walk_to).with(394)
        expect(DRCT).to have_received(:walk_to).with(602)
      end

      it 'skips the tree climb section' do
        athletics.riverhaven_athletics

        expect(DRCT).not_to have_received(:walk_to).with(51158)
        expect(DRCT).not_to have_received(:walk_to).with(491)
      end
    end

    context 'at rank 10 or above' do
      before do
        call_count = 0
        Harness::DRSkill._set_modrank('Athletics', 50)
        allow(athletics).to receive(:done_training?) { (call_count += 1) > 1 }
      end

      it 'includes the tree climb section' do
        athletics.riverhaven_athletics

        expect(DRCT).to have_received(:walk_to).with(51158)
        expect(DRCT).to have_received(:walk_to).with(491)
        expect(DRCT).to have_received(:walk_to).with(7839)
      end
    end

    context 'at rank 140 or above' do
      before do
        call_count = 0
        Harness::DRSkill._set_modrank('Athletics', 200)
        allow(athletics).to receive(:done_training?) { (call_count += 1) > 3 }
      end

      it 'includes the extended route' do
        athletics.riverhaven_athletics

        expect(DRCT).to have_received(:walk_to).with(11440)
        expect(DRCT).to have_received(:walk_to).with(7640)
      end
    end

    context 'at rank above 300' do
      before do
        call_count = 0
        Harness::DRSkill._set_modrank('Athletics', 400)
        allow(athletics).to receive(:done_training?) { (call_count += 1) > 1 }
        allow(athletics).to receive(:crossing_athletics)
      end

      it 'falls back to crossing_athletics for harder obstacles' do
        athletics.riverhaven_athletics

        expect(athletics).to have_received(:crossing_athletics)
      end

      it 'does not walk the Riverhaven route' do
        athletics.riverhaven_athletics

        expect(DRCT).not_to have_received(:walk_to).with(12821)
      end
    end
  end

  # Uses the real song ladder and rank table so the specs track data changes.
  describe 'climbing rope song' do
    let(:perform_data) { YAML.load_file(File.expand_path('../data/base-perform.yaml', __dir__)) }
    let(:song_list) { perform_data['perform_options'] }
    let(:climbing_song_ranks) { perform_data['climbing_song_ranks'] }
    let(:athletics) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@song_list, song_list)
        a.instance_variable_set(:@settings, OpenStruct.new(worn_instrument: 'zills'))
        a.instance_variable_set(:@climbs_without_progress, 0)
      end
    end

    before { Harness::DRSkill._reset }

    describe '#seed_climbing_song' do
      {
        0 => 'lament', 100 => 'lament', 101 => 'psalm', 250 => 'psalm', 251 => 'tarantella',
        350 => 'tarantella', 351 => 'rondo', 450 => 'rondo', 451 => 'concerto masterful', 1750 => 'concerto masterful'
      }.each do |rank, song|
        it "picks '#{song}' at Athletics rank #{rank}" do
          Harness::DRSkill._set_rank('Athletics', rank)
          athletics.seed_climbing_song(climbing_song_ranks)

          expect(UserVars.climbing_song).to eq(song)
        end
      end

      it 'only picks songs that are on the song ladder' do
        expect(climbing_song_ranks.values).to all(satisfy { |song| song_list.key?(song) })
      end

      it 'switches to rope difficulty adjustments when it picks a song' do
        athletics.seed_climbing_song(climbing_song_ranks)

        expect(UserVars.climbing_song_offset).to be true
        expect(UserVars.climbing_song_seed).to eq('lament')
      end

      it 'keeps a song adjusted within the same rank band and instrument' do
        Harness::DRSkill._set_rank('Athletics', 300)
        UserVars.climbing_song_seed = 'tarantella'
        UserVars.climbing_song_instrument = 'zills'
        UserVars.climbing_song = 'gavotte halt'
        athletics.seed_climbing_song(climbing_song_ranks)

        expect(UserVars.climbing_song).to eq('gavotte halt')
      end

      it 're-picks when the worn instrument changes' do
        Harness::DRSkill._set_rank('Athletics', 300)
        UserVars.climbing_song_seed = 'tarantella'
        UserVars.climbing_song_instrument = 'bells'
        UserVars.climbing_song = 'gavotte halt'
        athletics.seed_climbing_song(climbing_song_ranks)

        expect(UserVars.climbing_song).to eq('tarantella')
        expect(UserVars.climbing_song_instrument).to eq('zills')
      end

      it 're-picks when Athletics rank moves into a new band' do
        Harness::DRSkill._set_rank('Athletics', 351)
        UserVars.climbing_song_seed = 'tarantella'
        UserVars.climbing_song_instrument = 'zills'
        UserVars.climbing_song = 'gavotte halt'
        athletics.seed_climbing_song(climbing_song_ranks)

        expect(UserVars.climbing_song).to eq('rondo')
        expect(UserVars.climbing_song_seed).to eq('rondo')
      end

      it 're-picks a song stored before rank picking was tracked' do
        Harness::DRSkill._set_rank('Athletics', 500)
        UserVars.climbing_song = 'lament'
        athletics.seed_climbing_song(climbing_song_ranks)

        expect(UserVars.climbing_song).to eq('concerto masterful')
      end

      it 're-picks a stored song that is not on the song ladder' do
        UserVars.climbing_song_seed = 'lament'
        UserVars.climbing_song_instrument = 'zills'
        UserVars.climbing_song = 'lament halt '
        athletics.seed_climbing_song(climbing_song_ranks)

        expect(UserVars.climbing_song).to eq('lament')
      end

      it 're-picks after performance checksong clears the stored song' do
        UserVars.climbing_song_seed = nil
        UserVars.climbing_song = nil
        athletics.seed_climbing_song(climbing_song_ranks)

        expect(UserVars.climbing_song).to eq('lament')
      end
    end

    describe '#climbing_stalled?' do
      it 'alerts on the third climb in a row that teaches nothing' do
        UserVars.climbing_song = 'rondo'
        results = Array.new(3) { athletics.climbing_stalled?(0) }

        expect(results).to eq([false, false, true])
        expect(DRC).to have_received(:message).with(/no Athletics in 3 climbs while playing 'rondo'.*;performance checksong/).once
      end

      it 'starts counting again after a climb that teaches' do
        2.times { athletics.climbing_stalled?(0) }
        Harness::DRSkill._set_xp('Athletics', 1)
        athletics.climbing_stalled?(0)
        results = Array.new(2) { athletics.climbing_stalled?(1) }

        expect(results).to eq([false, false])
        expect(DRC).not_to have_received(:message)
      end
    end

    describe '#train_with_rope' do
      let(:athletics) do
        described_class.allocate.tap do |a|
          a.instance_variable_set(:@settings, OpenStruct.new(climbing_rope_adjective: 'climbing', worn_instrument: 'zills', safe_room: 1))
          a.instance_variable_set(:@end_exp, 29)
        end
      end
      let(:climb_commands) { [] }

      before do
        $test_data[:perform] = OpenStruct.new(perform_data)
        allow(DRCI).to receive(:exists?).and_return(true)
        allow(DRC).to receive(:play_song?).and_return(true)
        allow(DRC).to receive(:bput) do |command, *_matches|
          next "You're certain you can" unless command.start_with?('climb practice')

          climb_commands << command
          raise 'kept climbing past the stall limit' if climb_commands.size > 10

          Flags['climbing-finished'] = true
          learn_on_climb.call
          'Directing your attention toward your rope'
        end
      end

      context 'when climbs teach no Athletics' do
        let(:learn_on_climb) { -> {} }

        it 'stops after three climbs and alerts' do
          athletics.train_with_rope(true)

          expect(climb_commands.size).to eq(3)
          expect(DRC).to have_received(:message).with(/no Athletics in 3 climbs/)
          expect(DRC).to have_received(:bput).with('stop climb', any_args)
        end
      end

      context 'when the safe room cannot be reached' do
        let(:learn_on_climb) { -> { Harness::DRSkill._set_xp('Athletics', DRSkill.getxp('Athletics') + 10) } }

        before { allow(DRCT).to receive(:walk_to).and_return(false) }

        it 'trains with the rope where it stands, as before' do
          athletics.train_with_rope(false)

          expect(DRCT).to have_received(:walk_to).with(1)
          expect(climb_commands.size).to eq(3)
          expect(DRC).not_to have_received(:message)
        end
      end

      context 'when climbs teach Athletics' do
        let(:learn_on_climb) { -> { Harness::DRSkill._set_xp('Athletics', DRSkill.getxp('Athletics') + 10) } }

        it 'trains to the goal without alerting' do
          athletics.train_with_rope(true)

          expect(climb_commands.size).to eq(3)
          expect(DRC).not_to have_received(:message)
        end
      end
    end
  end

  # ===========================================================================
  # Training walks
  #
  # Each routine repeats walks until Athletics is trained. When a walk fails
  # (DRCT.walk_to returns false, e.g. the room can't be reached or the current
  # room can't be resolved), the script must stop instead of repeating walks
  # that go nowhere. These run the real script entry point (Athletics.new) with
  # the real room data, and Athletics XP that never rises unless a spec says so.
  # ===========================================================================
  describe 'training walks' do
    let(:walks) { [] }
    let(:stopped_message) { "Athletics: could not reach room #{walks.last}. Stopping athletics training." }

    before do
      $test_settings = OpenStruct.new(
        held_athletics_items: ['gloves'],
        athletics_outdoorsmanship_rooms: [],
        performance_pause: 0,
        hometown: 'Crossing'
      )
      $test_data[:athletics] = OpenStruct.new(YAML.load_file(File.expand_path('../data/base-athletics.yaml', __dir__)))
      $parsed_args = OpenStruct.new(skip_magic: true)

      # A routine left training in the wrong room can wait forever for a climb
      # that never started. Fail the example instead of hanging the suite.
      pauses = 0
      allow_any_instance_of(Athletics).to receive(:pause) do
        raise 'paused 100 times without finishing' if (pauses += 1) > 100
      end
    end

    # Walk number `at` fails; every walk before it succeeds. Any walk after the
    # failed one raises, so code that keeps looping fails the example instead
    # of hanging the suite.
    def fail_walk(at:)
      allow(DRCT).to receive(:walk_to) do |room|
        raise "walked to #{room} after the walk to #{walks.last} failed" if walks.size >= at

        walks << room
        walks.size < at
      end
    end

    # Every walk succeeds; Athletics is trained once the walk to `room` is done.
    def train_after_walk_to(room)
      allow(DRCT).to receive(:walk_to) do |target|
        raise 'walked 50 times without finishing' if walks.size >= 50

        walks << target
        Harness::DRSkill._set_xp('Athletics', 34) if target == room
        true
      end
    end

    shared_examples 'stops at the failed walk' do |expected_walks|
      it "walks #{expected_walks.join(', ')} and stops" do
        expect { Athletics.new }.not_to raise_error
        expect(walks).to eq(expected_walks)
      end

      it 'says which room it could not reach' do
        Athletics.new
        expect(DRC).to have_received(:message).with(stopped_message)
      end

      it 'stows the held athletics items after stopping' do
        commands = []
        allow(DRC).to receive(:bput) { |command, *_matches| commands << command }
        Athletics.new
        expect(commands.last).to eq('stow my gloves')
      end
    end

    context 'when swimming and the second room cannot be reached' do
      before do
        $test_settings.swimming_target = 'arthe_dale'
        fail_walk(at: 2)
      end

      it_behaves_like 'stops at the failed walk', [19_069, 19_071]
    end

    context 'when swimming at low rank in Crossing and the first room cannot be reached' do
      before do
        Harness::DRSkill._set_modrank('Athletics', 20)
        fail_walk(at: 1)
      end

      it_behaves_like 'stops at the failed walk', [19_069]
    end

    context 'when climbing the cliffs and the first room cannot be reached' do
      before do
        $test_settings.climbing_target = 'cliffs'
        fail_walk(at: 1)
      end

      it_behaves_like 'stops at the failed walk', [9525]
    end

    context 'when climbing the wyvern cliffs and a room partway round cannot be reached' do
      before do
        $parsed_args.wyvern = true
        fail_walk(at: 3)
      end

      it_behaves_like 'stops at the failed walk', [19_464, 9607, 11_126]
    end

    context 'when climbing undergondola above 540 and a room in the loop cannot be reached' do
      before do
        $parsed_args.undergondola = true
        Harness::DRSkill._set_modrank('Athletics', 600)
        fail_walk(at: 4)
      end

      it_behaves_like 'stops at the failed walk', [9607, 9515, 2245, 9607]
    end

    context 'when climbing xalas and a room on the second lap cannot be reached' do
      before do
        $parsed_args.xalas = true
        fail_walk(at: 4)
      end

      it_behaves_like 'stops at the failed walk', [6154, 12_838, 6154, 12_838]

      it 'trained outdoorsmanship once, between the laps' do
        Athletics.new
        expect(DRC).to have_received(:wait_for_script_to_complete).with('outdoorsmanship', any_args).once
      end
    end

    context 'when climbing in Riverhaven and a room on the route cannot be reached' do
      before do
        $test_settings.hometown = 'Riverhaven'
        Harness::DRSkill._set_modrank('Athletics', 5)
        fail_walk(at: 3)
      end

      it_behaves_like 'stops at the failed walk', [12_821, 13_755, 14_723]
    end

    context 'when climbing in Crossing and the first obstacle room cannot be reached' do
      before do
        Harness::DRSkill._set_modrank('Athletics', 100)
        fail_walk(at: 1)
      end

      it_behaves_like 'stops at the failed walk', [835]

      it 'does not try the climb in the wrong room' do
        Athletics.new
        expect(DRC).not_to have_received(:bput).with('climb embrasure', any_args)
      end
    end

    context 'when climbing in Shard and the first obstacle room cannot be reached' do
      before do
        $test_settings.hometown = 'Shard'
        Harness::DRSkill._set_modrank('Athletics', 100)
        fail_walk(at: 1)
      end

      it_behaves_like 'stops at the failed walk', [2544]
    end

    # Shard repeats climb_cliffs inside its own loop, so the stop has to end
    # both loops, not just climb_cliffs.
    context 'when Shard climbs the cliffs and the first room cannot be reached' do
      before do
        $test_settings.hometown = 'Shard'
        Harness::DRSkill._set_modrank('Athletics', 300)
        fail_walk(at: 1)
      end

      it_behaves_like 'stops at the failed walk', [9525]
    end

    context 'when swimming in Hibarnhvidar and the return to the bank cannot be reached' do
      before do
        $test_settings.hometown = 'Hibarnhvidar'
        fail_walk(at: 2)
      end

      it_behaves_like 'stops at the failed walk', [4155, 4155]
    end

    # Ratha repeats climb_practice inside its own loop.
    context 'when climbing in Ratha and the practice room cannot be reached' do
      before do
        $test_settings.hometown = 'Ratha'
        fail_walk(at: 1)
      end

      it_behaves_like 'stops at the failed walk', [5287]

      it 'does not hide or practice in the wrong room' do
        allow(DRC).to receive(:hide?).and_return(true)
        Athletics.new
        expect(DRC).not_to have_received(:hide?)
        expect(DRC).not_to have_received(:bput).with('climb practice rock gorge', any_args)
      end
    end

    context 'when every walk succeeds' do
      it 'swims each room once and finishes, without a stop message' do
        $test_settings.swimming_target = 'arthe_dale'
        train_after_walk_to(19_066)

        Athletics.new

        expect(walks).to eq([19_069, 19_071, 19_067, 19_066])
        expect(DRC).not_to have_received(:message)
      end

      it 'climbs the cliffs route once and finishes, without a stop message' do
        $test_settings.climbing_target = 'cliffs'
        train_after_walk_to(2900)

        Athletics.new

        expect(walks).to eq([9525, 9609, 9607, 2900])
        expect(DRC).not_to have_received(:message)
      end
    end

    context 'when walk_to reports false but the character is in the room' do
      before do
        $test_settings.swimming_target = 'arthe_dale'
        # lich-5 releases without elanthia-online/lich-5#1749 return false after
        # a one-step walk out of a room they couldn't identify, although the
        # step reached the target room.
        allow(DRCT).to receive(:walk_to) do |room|
          raise 'walked 50 times without finishing' if walks.size >= 50

          walks << room
          allow(Room).to receive(:current).and_return(OpenStruct.new(id: room))
          Harness::DRSkill._set_xp('Athletics', 34) if room == 19_066
          false
        end
      end

      it 'counts the walk as arrived and keeps training' do
        Athletics.new

        expect(walks).to eq([19_069, 19_071, 19_067, 19_066])
        expect(DRC).not_to have_received(:message)
      end
    end

    context 'when walk_to reports false and the character is in another room' do
      it 'stops at the failed walk' do
        $test_settings.swimming_target = 'arthe_dale'
        fail_walk(at: 1)
        allow(Room).to receive(:current).and_return(OpenStruct.new(id: 19_071))

        Athletics.new

        expect(walks).to eq([19_069])
        expect(DRC).to have_received(:message).with(stopped_message)
      end
    end

    context 'when the current room is unknown and walk_to reports false' do
      it 'stops at the failed walk' do
        $test_settings.swimming_target = 'arthe_dale'
        fail_walk(at: 1)
        allow(Room).to receive(:current).and_return(nil)

        expect { Athletics.new }.not_to raise_error
        expect(walks).to eq([19_069])
        expect(DRC).to have_received(:message).with(stopped_message)
      end
    end

    context 'when a room id comes from a data file as a string' do
      it 'compares it with the current room as a number' do
        $test_settings.climbing_target = 'silverwater_ladder'
        $test_data[:athletics].practice_options['silverwater_ladder']['id'] = '6119'
        allow(DRCT).to receive(:walk_to) do |room|
          raise "walked to #{room} again" unless walks.empty?

          walks << room
          false
        end
        allow(Room).to receive(:current).and_return(OpenStruct.new(id: 6119))
        Harness::DRSkill._set_xp('Athletics', 34)

        Athletics.new

        expect(walks).to eq(['6119'])
        expect(DRC).not_to have_received(:message)
      end
    end

    context 'when athletics is started again after a run stopped' do
      it 'tries the walk again and stops again, keeping nothing between runs' do
        $test_settings.swimming_target = 'arthe_dale'
        allow(DRCT).to receive(:walk_to) do |room|
          raise "walked to #{room} again within one run" if walks.size >= 2

          walks << room
          false
        end

        2.times { Athletics.new }

        expect(walks).to eq([19_069, 19_069])
        expect(DRC).to have_received(:message).with(stopped_message).twice
      end
    end
  end
end
