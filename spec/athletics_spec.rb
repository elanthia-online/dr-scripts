# frozen_string_literal: true

require 'ostruct'
require 'yaml'

require_relative 'spec_helper'

load_lic_class('athletics.lic', 'Athletics')

RSpec.describe Athletics do
  before(:each) do
    reset_data
    Harness::DRSkill._reset_xp
    Harness::DRSkill._reset_modrank

    allow(DRC).to receive(:wait_for_script_to_complete)
    allow(DRC).to receive(:bput)
    allow(DRC).to receive(:message)
    allow(DRCT).to receive(:walk_to)
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
end
