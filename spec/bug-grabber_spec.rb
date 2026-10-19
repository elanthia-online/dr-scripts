# frozen_string_literal: true

require_relative 'spec_helper'

# bug-grabber.lic has no class: all of its work is one top-level `loop do`.
# These examples run the whole real script, evaluated into a fresh module per
# example so its top-level defs (bug?, walk_to_or_stop) never land on Object
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
  let(:circuit_size) { 31 }
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

  # Every walk succeeds. Raises StopRun on walk number `stop_at`.
  def succeed_walks(stop_at:)
    allow(DRCT).to receive(:walk_to) do |room|
      raise stop_run if walks.size + 1 >= stop_at

      walks << room
      DRRoom.room_objs = room == @bug_room ? [@bug] : []
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

    it_behaves_like 'stops at the failed walk', [10_506, 10_507, 10_676], 10_676

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

  context 'when walk_to reports false and the character is in another room' do
    before do
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: 10_507))
      fail_walk(at: 1)
    end

    it_behaves_like 'stops at the failed walk', [10_506], 10_506
  end
end
