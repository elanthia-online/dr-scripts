# frozen_string_literal: true

require_relative 'spec_helper'

# bug-grabber.lic has no class: all of its work is one top-level `loop do`.
# These examples run the whole real script, evaluated into a fresh module per
# example so its top-level defs (room_bug, walk_to_or_stop) never land on Object
# and nothing carries over from one example to the next.
#
# The loop never ends on its own, so every example ends it: a clean stop is the
# script's own `exit` (SystemExit), and the success paths raise StopRun from
# the walk_to or pause stub once the behaviour under test has happened. Any
# other walk or pause past a fixed limit raises, so a script that keeps looping
# fails the example instead of hanging the suite.
RSpec.describe 'bug-grabber.lic' do
  let(:path) { lic_path('bug-grabber.lic') }
  let(:source) { File.read(path) }
  let(:script) { Module.new.tap { |mod| mod.extend(mod) } }
  let(:stop_run) { Class.new(StandardError) }

  let(:shrine_room) { 10_506 }
  let(:circuit_size) { 18 }

  # Lowest Depths corridors that, in the current public DR mapdb, have no uid
  # and the same title, description and exits as a lower-numbered room, mapped
  # to the room Lich takes them for. Standing in the key room, Room.current is
  # the value room, so walk_to to the key room can never return true.
  let(:look_alikes) do
    { 10_676 => 10_508, 10_665 => 10_509, 10_670 => 10_510, 10_673 => 10_507, 10_675 => 10_520,
      10_668 => 10_557, 10_669 => 10_493, 10_666 => 10_557, 10_667 => 10_576, 14_466 => 10_576,
      10_671 => 10_576, 13_231 => 10_620, 10_678 => 10_497 }
  end
  let(:walks) { [] }
  let(:commands) { [] }

  def run_script
    lines = source.lines
    prime_lic_coverage(path, lines.size)
    LIC_EVAL_RANGES[path] << (0...lines.size)
    script.module_eval(source, path, 1)
  end

  # A bug sits in `bug_room` until it is picked up. `get` puts it in the right
  # hand and clears the room; every other command is only recorded (the hand
  # is left as it was, so no game reply is assumed).
  def put_bug_in(bug_room, bug: 'a black beetle', held: 'beetle')
    @bug_room = bug_room
    @bug = bug
    allow(script).to receive(:fput) do |command|
      commands << command
      if command.start_with?('get')
        $right_hand = held
        @bug_room = nil
        DRRoom.room_objs = []
      end
    end
  end

  # Walk number `at` fails (the character stays where it was); every walk
  # before it succeeds. Any walk after the failed one raises.
  def fail_walk(at:)
    allow(DRCT).to receive(:walk_to) do |room|
      raise "walked to #{room} after the walk to #{walks.last} failed" if walks.size >= at

      walks << room
      arrived = walks.size < at
      DRRoom.room_objs = arrived && room == @bug_room ? [@bug] : []
      arrived
    end
  end

  # Every walk succeeds. Raises StopRun on walk number `stop_at`. `scenery`
  # is in every room, listed ahead of the bug.
  def succeed_walks(stop_at:, scenery: [])
    allow(DRCT).to receive(:walk_to) do |room|
      raise stop_run if walks.size + 1 >= stop_at

      walks << room
      DRRoom.room_objs = scenery + (room == @bug_room ? [@bug] : [])
      true
    end
  end

  before do
    put_bug_in(nil)
    allow(DRC).to receive(:message)
    pauses = 0
    allow(script).to receive(:pause) do
      raise 'paused 20 times without finishing' if (pauses += 1) > 20
    end
  end

  shared_examples 'stops at the failed walk' do |expected_walks, room|
    it "walks #{expected_walks.join(', ')} and exits" do
      expect { run_script }.to raise_error(SystemExit)
      expect(walks).to eq(expected_walks)
    end

    it 'says which room it could not reach' do
      expect { run_script }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with("bug-grabber: could not reach room #{room}. Stopping.")
    end
  end

  context 'when a room on the circuit cannot be reached' do
    before { fail_walk(at: 3) }

    it_behaves_like 'stops at the failed walk', [10_506, 10_507, 10_508], 10_508

    it 'sends nothing to the game' do
      expect { run_script }.to raise_error(SystemExit)
      expect(commands).to be_empty
    end
  end

  context 'when the first room cannot be reached from a room that cannot be resolved' do
    before do
      allow(Room).to receive(:current).and_return(nil)
      fail_walk(at: 1)
    end

    it_behaves_like 'stops at the failed walk', [10_506], 10_506

    it 'sends nothing to the game' do
      expect { run_script }.to raise_error(SystemExit)
      expect(commands).to be_empty
    end
  end

  context 'when the shrine cannot be reached with a bug in hand' do
    before do
      put_bug_in(10_507)
      fail_walk(at: 3)
    end

    it_behaves_like 'stops at the failed walk', [10_506, 10_507, 10_506], 10_506

    it 'picks the bug up but does not try to put it on the shrine or stow it' do
      expect { run_script }.to raise_error(SystemExit)
      expect(commands.size).to eq(1)
      expect(commands.first).to start_with('get')
    end

    it 'says the bug is still in hand' do
      expect { run_script }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('bug-grabber: the beetle is still in your hands.')
    end
  end

  context 'when a wing is picked up and the next circuit cannot be reached' do
    before do
      put_bug_in(10_507, bug: 'a green dragonfly', held: 'dragonfly wing')
      fail_walk(at: 3)
    end

    it 'drops the wing without walking to the shrine, then stops at the next failed walk' do
      expect { run_script }.to raise_error(SystemExit)
      expect(commands.last).to eq('drop wing')
      expect(walks).to eq([10_506, 10_507, 10_506])
      expect(DRC).to have_received(:message).with('bug-grabber: could not reach room 10506. Stopping.')
      expect(DRC).not_to have_received(:message).with(/still in your hands/)
    end
  end

  context 'when every walk succeeds' do
    it 'takes the bug to the shrine, puts it there and stows what is left in hand' do
      put_bug_in(10_507)
      succeed_walks(stop_at: 4)

      # Round the circuit to the bug, then the shrine; walk 4 starts the next
      # circuit and ends the run.
      expect { run_script }.to raise_error(stop_run)
      expect(walks).to eq([10_506, 10_507, shrine_room])
      expect(commands.drop(1)).to eq(['put beetle on shrine', 'stow beetle'])
      expect(DRC).not_to have_received(:message)
    end

    it 'walks the whole circuit and waits when nothing has spawned' do
      succeed_walks(stop_at: 100)
      allow(script).to receive(:pause).and_raise(stop_run)

      expect { run_script }.to raise_error(stop_run)
      expect(walks.size).to eq(circuit_size)
      expect(walks.uniq.size).to eq(circuit_size)
      expect(DRC).not_to have_received(:message)
    end

    # In the current mapdb 10667 can't be reached from any other circuit room,
    # and 10672 is now a booth with no mapped way back to the circuit. The
    # look-alike corridors can be reached, but walk_to never reports arriving
    # in one. Any of them would stop every run.
    it 'walks neither 10672 nor any look-alike corridor' do
      succeed_walks(stop_at: 100)
      allow(script).to receive(:pause).and_raise(stop_run)

      expect { run_script }.to raise_error(stop_run)
      expect(walks).not_to include(10_672, *look_alikes.keys)
    end
  end

  # walk_to returns room_num == Room.current.id, so it is only as good as
  # Lich's idea of where the character is.
  context 'when Room.current is the room Lich takes each room for' do
    before do
      allow(DRCT).to receive(:walk_to) do |room|
        raise 'walked a whole circuit and more' if walks.size >= circuit_size

        walks << room
        here = look_alikes.fetch(room, room)
        allow(Room).to receive(:current).and_return(OpenStruct.new(id: here))
        here == room
      end
      allow(script).to receive(:pause).and_raise(stop_run)
    end

    it 'walks the whole circuit without stopping' do
      expect { run_script }.to raise_error(stop_run)
      expect(walks.size).to eq(circuit_size)
      expect(DRC).not_to have_received(:message)
    end
  end

  # Some lich-5 releases return false after a one-step walk out of a room they
  # couldn't identify, although the step reached the target room.
  context 'when walk_to reports false but the character is in the room' do
    before do
      allow(DRCT).to receive(:walk_to) do |room|
        raise 'walked a whole circuit and more' if walks.size >= circuit_size

        walks << room
        allow(Room).to receive(:current).and_return(OpenStruct.new(id: room))
        false
      end
      allow(script).to receive(:pause).and_raise(stop_run)
    end

    it 'counts each walk as arrived and walks the whole circuit' do
      expect { run_script }.to raise_error(stop_run)
      expect(walks.size).to eq(circuit_size)
      expect(DRC).not_to have_received(:message)
    end
  end

  # The noun in `get the <noun>` has to come from the room object that was
  # found, not from Regexp.last_match: the match happens inside a method, so
  # the loop's own last match is nil, or the wing match from an earlier pickup.
  context 'when picking a bug up' do
    def get_commands
      commands.grep(/\Aget/)
    end

    it 'names the bug it found' do
      put_bug_in(10_507, bug: 'a black beetle')
      succeed_walks(stop_at: 4)

      expect { run_script }.to raise_error(stop_run)
      expect(get_commands).to eq(['get the beetle'])
    end

    it 'names the bug, not the first thing in the room' do
      put_bug_in(10_507, bug: 'a red-spotted locust')
      succeed_walks(stop_at: 4, scenery: ['a wooden bench', 'a scrap of parchment'])

      expect { run_script }.to raise_error(stop_run)
      expect(get_commands).to eq(['get the locust'])
    end

    it 'names each bug when there are several, including after a wing was dropped' do
      @in_room = ['a green dragonfly', 'a large brown moth', 'a black beetle']
      held = { 'dragonfly' => 'dragonfly wing', 'moth' => 'moth', 'beetle' => 'beetle' }
      allow(script).to receive(:fput) do |command|
        commands << command
        next unless (noun = command[/\Aget the (\w+)\z/, 1])

        $right_hand = held.fetch(noun)
        @in_room.reject! { |obj| obj.end_with?(noun) }
        DRRoom.room_objs = @in_room.dup
      end
      # Only the bug room has anything in it; the shrine is empty.
      allow(DRCT).to receive(:walk_to) do |room|
        raise stop_run if walks.size >= 4

        walks << room
        DRRoom.room_objs = room == 10_507 ? @in_room.dup : []
        true
      end

      expect { run_script }.to raise_error(stop_run)
      expect(get_commands).to eq(['get the dragonfly', 'get the moth'])
      expect(commands).to include('drop wing', 'put moth on shrine')
    end

    it 'takes the bug noun even when it is written in capitals' do
      put_bug_in(10_507, bug: 'a glowing FIREFLY')
      succeed_walks(stop_at: 4)

      expect { run_script }.to raise_error(stop_run)
      expect(get_commands).to eq(['get the FIREFLY'])
    end

    it 'sends no get when nothing in the room is a bug' do
      succeed_walks(stop_at: 100, scenery: ['a wooden bench', 'a dead goblin'])
      allow(script).to receive(:pause).and_raise(stop_run)

      expect { run_script }.to raise_error(stop_run)
      expect(get_commands).to be_empty
    end
  end

  context 'when walk_to reports false and the character is in another room' do
    before do
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: 10_507))
      fail_walk(at: 1)
    end

    it_behaves_like 'stops at the failed walk', [10_506], 10_506
  end
end
