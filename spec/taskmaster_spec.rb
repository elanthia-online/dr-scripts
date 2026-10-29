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

  describe '#resume_task' do
    # Plays a resume: the journal says how many are owed, the bag holds some
    # finished items and maybe instructions with a number of uses left. Returns
    # what happened.
    def resume(owed:, target: owed, banked: 0, uses: nil, foreign: false)
      tm = build
      bag_items = banked
      given = 0
      events = []
      allow(tm).to receive(:tool_pickup)
      allow(tm).to receive(:sort_sack) { events << :sack }
      allow(tm).to receive(:fput)
      allow(tm).to receive(:zasele) { |item, count, *_| events << [:make, item, count] }
      allow(tm).to receive(:complete_task) { |item, count| events << [:complete, item, count] }
      allow(tm).to receive(:get_instructions) { events << :asked_for_instructions }
      allow(DRCC).to receive(:stow_crafting_item) { |name, *_| events << [:stowed, name] }
      allow(DRCI).to receive(:exists?).and_return(false)
      allow(DRCI).to receive(:get_item?) do |name, _bag|
        if name.end_with?('instructions')
          !uses.nil?
        elsif bag_items.positive?
          bag_items -= 1
          true
        else
          false
        end
      end
      allow(DRC).to receive(:bput) do |command, *_matchers|
        case command
        when 'task'
          journal('a coil of reinforced cloth rope', target, target - owed)
        when /^give my rope/
          given += 1
          left = owed - given
          left.zero? ? 'Seamstress Zasele hands you a woven sack.' : "Zasele holds up her fingers indicating #{left} more #{left == 1 ? 'is' : 'are'} needed."
        when /^read my rope instructions/
          if foreign
            'You can\'t read the ink printed on the rope instructions.  They were written by or for someone else.'
          else
            "These instructions appear to be very fragile and will wear out quickly when studied.  They have only #{uses} uses remaining.\n#{rope_materials}"
          end
        else
          ''
        end
      end
      # read_instructions' material read is answered by the same stub; make it
      # return the material line.
      allow(DRC).to receive(:bput).with('read my rope instructions', TaskMaster::INSTRUCTION_MATERIALS).and_return(rope_materials)
      expect { tm.resume_task }.to raise_error(SystemExit)
      events
    end

    it 'hands in finished items from the bag before making any' do
      events = resume(owed: 5, banked: 2, uses: 4)
      expect(events).to include([:make, 'rope', 3], [:complete, 'rope', 3])
    end

    it 'finishes the task from the bag alone when enough are banked, buying nothing' do
      events = resume(owed: 3, banked: 3, uses: 4)
      expect(events).to eq([:sack])
    end

    it 'keeps the carried instructions when they have a use for every item owed' do
      events = resume(owed: 3, uses: 4)
      expect(events).not_to include(:asked_for_instructions)
      expect(events).to include([:make, 'rope', 3])
    end

    it 'asks for instructions when none are carried' do
      expect(resume(owed: 3, uses: nil)).to include(:asked_for_instructions)
    end

    it 'asks for instructions, after putting the old set away, when they have too few uses' do
      events = resume(owed: 3, uses: 2)
      expect(events.index([:stowed, 'rope instructions'])).to be < events.index(:asked_for_instructions)
    end

    it 'asks for instructions when the carried set is someone else\'s' do
      expect(resume(owed: 2, uses: 9, foreign: true)).to include(:asked_for_instructions)
    end

    it 'counts the items still owed after the banked ones are in' do
      events = resume(owed: 6, target: 8, banked: 1, uses: 6)
      expect(events).to include([:make, 'rope', 5])
    end

    it 'puts back an item the taskmaster will not take and stops handing in' do
      tm = build
      allow(tm).to receive(:find_npc)
      allow(DRCI).to receive(:get_item?).and_return(true)
      allow(DRC).to receive(:bput).and_return('Zasele shakes her head.')
      expect(DRCC).to receive(:stow_crafting_item).with('rope', 'duffel bag', nil)
      expect(tm.turn_in_banked('rope', 4)).to eq(4)
    end
  end
end
