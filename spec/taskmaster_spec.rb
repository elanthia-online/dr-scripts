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
    tm
  end

  # Game responses keyed by the command that produces them.
  def game(responses)
    allow(DRC).to receive(:bput) do |command, *_matchers|
      responses.find { |prefix, _| command.start_with?(prefix) }&.last || ''
    end
    allow(DRC).to receive(:message)
  end

  # Task journal and instruction lines as the game prints them (2025 Hollow Eve logs).
  let(:task_line) do
    'Zasele wanted you to craft a coil of reinforced cloth rope and indicated that 5 would suffice.  ' \
      'So far, you have returned 0 to her.  Crafting instructions were provided for this item.'
  end
  let(:read_line) { '   (1) finished fabric cloth (4 yards)' }

  describe 'after reading the instructions' do
    it 'puts a newly accepted task\'s instructions in the crafting bag by name' do
      tm = build
      game('ask zasele for task' => 'You may accept by typing ACCEPT TASK', 'task' => task_line, 'read my rope instructions' => read_line,
           'accept task' => 'You can check your progress with the TASK verb')
      expect(DRCC).to receive(:stow_crafting_item).with('rope instructions', 'duffel bag', nil).ordered
      expect(DRCI).to receive(:stow_hands).ordered

      expect(tm.get_task).to eq(['rope', 5, 4, 'cloth', 'burlap'])
    end

    it 'puts resumed instructions in the crafting bag by name' do
      tm = build
      game('task' => task_line, 'read my rope instructions' => read_line)
      expect(DRCC).to receive(:stow_crafting_item).with('rope instructions', 'duffel bag', nil).ordered
      allow(DRCI).to receive(:stow_hands)

      tm.finish
    end

    # After a crash a character can log back in holding a tool and an unfinished
    # item; those still go to default stow, as before, but only once the
    # instructions are in the crafting bag.
    it 'still stows anything else in hand on resume, after the instructions are bagged' do
      tm = build
      game('task' => task_line, 'read my rope instructions' => read_line)
      expect(DRCC).to receive(:stow_crafting_item).with('rope instructions', 'duffel bag', nil).ordered
      expect(DRCI).to receive(:stow_hands).ordered

      tm.finish
    end

    it 'uses the task item noun, so leather straps instructions are named correctly' do
      tm = build
      game('task'                        => 'Zasele wanted you to craft some wide leather straps and indicated that 6 would suffice.  So far, you have returned 2 to her.',
           'read my straps instructions' => '   (1) refined leather material (5 yards)')
      expect(DRCC).to receive(:stow_crafting_item).with('straps instructions', 'duffel bag', nil)
      allow(DRCI).to receive(:stow_hands)

      tm.finish
    end
  end
end
