# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

# smash-pumpkins.lic is class-less: the whole script is top-level code. These
# specs run the real file from top to bottom in a fresh object, with the
# commons calls stubbed, and record every walk and game command in order.
#
# The script walks between the vat room, the room where it breaks pumpkins, the
# bank and its exit room. When DRCT.walk_to returns false (the room can't be
# reached or the current room can't be resolved), it must stop instead of
# grabbing the vat, breaking pumpkins or stowing loot in the wrong room.
RSpec.describe 'smash-pumpkins.lic' do
  vat_room = 10_570
  break_room = 10_569
  bank_room = 10_358
  exit_room = 10_341

  # Every walk and game command, in order: [:walk, room] or [:bput, command].
  let(:events) { [] }

  def walks
    events.select { |kind, _| kind == :walk }.map(&:last)
  end

  def commands
    events.select { |kind, _| kind == :bput }.map(&:last)
  end

  # Replies for 'grab vat', one per grab, then 'roundtime' for the rest.
  let(:grab_replies) { [] }
  # Full grab-break-stow cycles before the character starts bleeding, which
  # ends the loop and sends the script to its exit room.
  let(:cycles) { 1 }
  let(:teardown) { [] }

  before do
    $test_settings = OpenStruct.new(pumpkin_junk: ['rind'])
    Harness::DRStats.health = 100
    allow(DRC).to receive(:message)

    grabs = 0
    finished = 0
    allow(DRC).to receive(:bput) do |command, *_matches|
      raise "sent #{command.inspect} after the walk to #{walks.last} failed" if @walk_failed
      raise 'sent 50 commands without finishing' if commands.size >= 50

      events << [:bput, command]
      case command
      when 'grab vat'
        reply = grab_replies[grabs] || 'roundtime'
        grabs += 1
        $right_hand = 'pumpkin' if reply == 'roundtime'
        reply
      when 'withdraw 3 platinum'
        'The clerk counts out'
      when 'break my pumpkin'
        $right_hand = 'rind'
        'wipe off pumpkin residue'
      when 'put rind in bucket'
        $right_hand = nil
        $bleeding = true if (finished += 1) >= cycles
        'You drop'
      else
        raise "unexpected command #{command.inspect}"
      end
    end
  end

  # Walk number `at` fails and every walk before it succeeds. `room` is what
  # Room.current reports after the failed walk. Any walk or command after the
  # failed walk raises, so a script that keeps going fails the example instead
  # of hanging the suite.
  def fail_walk(at:, room: nil)
    allow(DRCT).to receive(:walk_to) do |target|
      raise "walked to #{target} after the walk to #{walks.last} failed" if @walk_failed

      events << [:walk, target]
      @walk_failed = walks.size >= at
      !@walk_failed
    end
    allow(Room).to receive(:current).and_return(room)
  end

  def succeed_walks
    allow(DRCT).to receive(:walk_to) do |target|
      raise 'walked 50 times without finishing' if walks.size >= 50

      events << [:walk, target]
      true
    end
  end

  # Runs the real script. Its before_dying block is captured into `teardown`.
  def run_script
    path = lic_path('smash-pumpkins.lic')
    captured = teardown
    context = Object.new
    context.define_singleton_method(:before_dying) { |&block| captured << block }
    context.instance_eval(File.read(path), path, 1)
  end

  def stopped_message(room)
    "smash-pumpkins: could not reach room #{room}. Stopping."
  end

  shared_examples 'stops at the failed walk' do |expected_events|
    it 'stops the script there, sending nothing after the failed walk' do
      expect { run_script }.to raise_error(SystemExit)
      expect(events).to eq(expected_events)
    end

    it 'says which room it could not reach' do
      expect { run_script }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with(stopped_message(expected_events.last.last))
    end

    it 'leaves the pumpkin-leeches flag to the before_dying cleanup' do
      expect { run_script }.to raise_error(SystemExit)
      expect(teardown.size).to eq(1)
      expect(Flags.flags).to have_key('pumpkin-leeches')
      teardown.each(&:call)
      expect(Flags.flags).not_to have_key('pumpkin-leeches')
    end
  end

  context 'when the walk to the vat cannot be completed at the start' do
    before { fail_walk(at: 1) }

    it_behaves_like 'stops at the failed walk', [[:walk, vat_room]]
  end

  context 'when the walk to the room for breaking pumpkins fails' do
    before { fail_walk(at: 2) }

    it_behaves_like 'stops at the failed walk',
                    [[:walk, vat_room], [:bput, 'grab vat'], [:walk, break_room]]
  end

  context 'when the walk back to the vat with the loot fails' do
    before { fail_walk(at: 3) }

    it_behaves_like 'stops at the failed walk',
                    [[:walk, vat_room], [:bput, 'grab vat'], [:walk, break_room],
                     [:bput, 'break my pumpkin'], [:walk, vat_room]]
  end

  context 'when the walk back to the vat fails on the second cycle' do
    let(:cycles) { 2 }

    before { fail_walk(at: 5) }

    it_behaves_like 'stops at the failed walk',
                    [[:walk, vat_room], [:bput, 'grab vat'], [:walk, break_room],
                     [:bput, 'break my pumpkin'], [:walk, vat_room], [:bput, 'put rind in bucket'],
                     [:bput, 'grab vat'], [:walk, break_room], [:bput, 'break my pumpkin'],
                     [:walk, vat_room]]
  end

  context 'when out of coins and the walk to the bank fails' do
    let(:grab_replies) { ['when you have enough coins'] }

    before { fail_walk(at: 2) }

    it_behaves_like 'stops at the failed walk',
                    [[:walk, vat_room], [:bput, 'grab vat'], [:walk, bank_room]]
  end

  context 'when out of coins and the walk from the bank back to the vat fails' do
    let(:grab_replies) { ['when you have enough coins'] }

    before { fail_walk(at: 3) }

    it_behaves_like 'stops at the failed walk',
                    [[:walk, vat_room], [:bput, 'grab vat'], [:walk, bank_room],
                     [:bput, 'withdraw 3 platinum'], [:walk, vat_room]]
  end

  context 'when too injured to grab the vat and the walk out fails' do
    let(:grab_replies) { ['You are too injured'] }

    before { fail_walk(at: 2) }

    it_behaves_like 'stops at the failed walk',
                    [[:walk, vat_room], [:bput, 'grab vat'], [:walk, exit_room]]
  end

  context 'when the walk out after training fails' do
    before { fail_walk(at: 4) }

    it_behaves_like 'stops at the failed walk',
                    [[:walk, vat_room], [:bput, 'grab vat'], [:walk, break_room],
                     [:bput, 'break my pumpkin'], [:walk, vat_room], [:bput, 'put rind in bucket'],
                     [:walk, exit_room]]
  end

  context 'when the current room cannot be resolved after a failed walk' do
    before { fail_walk(at: 1, room: OpenStruct.new(id: nil)) }

    it_behaves_like 'stops at the failed walk', [[:walk, vat_room]]
  end

  context 'when a walk fails while already standing in a different known room' do
    before { fail_walk(at: 2, room: OpenStruct.new(id: vat_room)) }

    it_behaves_like 'stops at the failed walk',
                    [[:walk, vat_room], [:bput, 'grab vat'], [:walk, break_room]]
  end

  context 'when every walk succeeds' do
    before { succeed_walks }

    it 'grabs, breaks and stows one pumpkin, then walks out, as before' do
      expect { run_script }.not_to raise_error
      expect(events).to eq(
        [[:walk, vat_room], [:bput, 'grab vat'], [:walk, break_room],
         [:bput, 'break my pumpkin'], [:walk, vat_room], [:bput, 'put rind in bucket'],
         [:walk, exit_room]]
      )
      expect(DRC).not_to have_received(:message)
    end

    it 'fetches coins from the bank and goes back to the vat, as before' do
      grab_replies << 'when you have enough coins'
      run_script
      expect(events.first(6)).to eq(
        [[:walk, vat_room], [:bput, 'grab vat'], [:walk, bank_room],
         [:bput, 'withdraw 3 platinum'], [:walk, vat_room], [:bput, 'grab vat']]
      )
    end

    it 'walks out and exits when too injured, as before' do
      grab_replies << 'You are too injured'
      expect { run_script }.to raise_error(SystemExit)
      expect(events).to eq([[:walk, vat_room], [:bput, 'grab vat'], [:walk, exit_room]])
      expect(DRC).not_to have_received(:message)
    end
  end

  # lich-5 releases without elanthia-online/lich-5#1749 can return false after
  # a one-step walk out of a room they couldn't identify, even when that step
  # reached the target. Being in the target room counts as arrived.
  context 'when walk_to returns false but the character is in the target room' do
    before do
      allow(DRCT).to receive(:walk_to) do |target|
        raise 'walked 50 times without finishing' if walks.size >= 50

        events << [:walk, target]
        false
      end
      allow(Room).to receive(:current) { OpenStruct.new(id: walks.last) }
    end

    it 'carries on as if the walk succeeded' do
      expect { run_script }.not_to raise_error
      expect(walks).to eq([vat_room, break_room, vat_room, exit_room])
      expect(commands).to eq(['grab vat', 'break my pumpkin', 'put rind in bucket'])
      expect(DRC).not_to have_received(:message)
    end
  end

  it 'registers its before_dying cleanup before the first walk' do
    allow(DRCT).to receive(:walk_to) do
      expect(teardown.size).to eq(1)
      @walk_failed = true
      false
    end
    allow(Room).to receive(:current).and_return(nil)
    expect { run_script }.to raise_error(SystemExit)
  end
end
