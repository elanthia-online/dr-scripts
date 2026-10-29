# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')

RSpec.describe TaskMaster do
  let(:stackmap) do
    { 'leather' => ['rat', 16667], 'cloth' => ['burlap', 16667], 'stack' => ['deer', 8864], 'ingot' => ['bronze', 8775],
      'stone' => ['alabaster', 8864], 'yarn' => ['wool', 16667], 'lumber' => ['balsa', 8864] }
  end

  # A bare instance: initialize runs the whole script, so each example injects
  # only the state the method under test reads.
  def build
    tm = described_class.allocate
    tm.instance_variable_set(:@settings, OpenStruct.new)
    tm.instance_variable_set(:@bag, 'duffel bag')
    tm.instance_variable_set(:@npc, 'zasele')
    tm.instance_variable_set(:@rooms, [16_145])
    tm.instance_variable_set(:@stackmap, stackmap)
    allow(tm).to receive(:find_npc)
    allow(DRCI).to receive(:stow_hands)
    allow(DRC).to receive(:message)
    tm
  end

  # Game responses keyed by the command that produces them.
  def game(responses)
    allow(DRC).to receive(:bput) do |command, *_matchers|
      responses.find { |prefix, _| command.start_with?(prefix) }&.last || ''
    end
  end

  # Task journal entry as the game prints it (2025 Hollow Eve logs).
  def journal(item, target, returned)
    "Zasele wanted you to craft #{item} and indicated that #{target} would suffice.  " \
      "So far, you have returned #{returned} to her.  Crafting instructions were provided for this item."
  end

  let(:rope_materials) { '   (1) finished fabric cloth (4 yards)' }

  describe '#finish (resuming a task already in progress)' do
    it 'plans only the items still owed' do
      tm = build
      game('task' => journal('a coil of reinforced cloth rope', 5, 4), 'read my rope instructions' => rope_materials)
      expect(tm.finish).to eq(['rope', 1, 4, 'cloth', 'burlap'])
    end

    it 'plans the full count when nothing has been returned yet' do
      tm = build
      game('task' => journal('some reinforced cloth netting', 8, 0), 'read my netting instructions' => '   (1) finished fabric cloth (10 yards)')
      expect(tm.finish).to eq(['netting', 8, 10, 'cloth', 'burlap'])
    end

    it 'never plans a negative count' do
      tm = build
      game('task' => journal('some wide leather straps', 5, 7), 'read my straps instructions' => '   (1) refined leather material (5 yards)')
      expect(tm.finish[1]).to eq(0)
    end

    it 'treats a journal entry without a returned count as nothing returned' do
      tm = build
      game('task'                        => 'Zasele wanted you to craft a knitted outfit and indicated that 6 would suffice.',
           'read my outfit instructions' => '   (1) refined fabric yarn (12 yards)')
      expect(tm.finish).to eq(['outfit', 6, 12, 'yarn', 'wool'])
    end

    it 'stops with a message when not on a task, instead of reading garbage' do
      tm = build
      game('task' => 'You are not currently on a task.')
      expect { tm.finish }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with(/not on a task with zasele/)
    end

    it 'maps bone, metal and wood instructions to the stock the script buys' do
      tm = build
      game('task' => journal('a bone bowl', 3, 1), 'read my bowl instructions' => '   (1) bone stack (6 volumes)')
      expect(tm.finish).to eq(['bowl', 2, 6, 'stack', 'deer'])
    end

    it 'reads stone instructions as one boulder per item' do
      tm = build
      # No stone instructions in the logs at hand; this line is shaped to the
      # script's existing stone pattern, which this change leaves as it was.
      game('task' => journal('a stone idol', 2, 0), 'read my idol instructions' => '   (1) carved stone material (boulder)')
      expect(tm.finish).to eq(['idol', 2, 'boulder', 'stone', 'alabaster'])
    end
  end

  describe '#get_task (a newly accepted task)' do
    it 'parses the task and instructions the same way as a resume' do
      tm = build
      game('ask zasele for task' => 'You may accept by typing ACCEPT TASK', 'accept task' => 'You can check your progress with the TASK verb',
           'task' => journal('a coil of reinforced cloth rope', 5, 0), 'read my rope instructions' => rope_materials)
      expect(tm.get_task).to eq(['rope', 5, 4, 'cloth', 'burlap'])
    end
  end
end
