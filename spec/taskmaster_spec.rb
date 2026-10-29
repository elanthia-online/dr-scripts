# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')

RSpec.describe TaskMaster do
  def build(settings = {})
    tm = described_class.allocate
    tm.instance_variable_set(:@settings, OpenStruct.new(settings))
    tm.instance_variable_set(:@cooldown_poll, tm.cooldown_poll_seconds)
    tm.instance_variable_set(:@npc, 'zasele')
    tm.instance_variable_set(:@boost, false)
    allow(tm).to receive(:find_npc)
    allow(DRC).to receive(:message)
    tm
  end

  describe '#cooldown_poll_seconds' do
    it 'defaults to 15 seconds' do
      expect(build.cooldown_poll_seconds).to eq(15)
    end

    it 'reads task_cooldown_poll' do
      expect(build(task_cooldown_poll: 5).cooldown_poll_seconds).to eq(5)
    end

    it 'never polls faster than every 3 seconds' do
      expect(build(task_cooldown_poll: 0).cooldown_poll_seconds).to eq(3)
      expect(build(task_cooldown_poll: -10).cooldown_poll_seconds).to eq(3)
    end
  end

  describe '#get_task while the taskmaster makes you wait' do
    # Waits once, then stops the recursion so only the pause is observed.
    def first_pause(tm, reply)
      allow(DRC).to receive(:bput).and_return(reply)
      pauses = []
      allow(tm).to receive(:pause) do |seconds|
        pauses << seconds
        raise StopIteration
      end
      expect { tm.get_task }.to raise_error(StopIteration)
      pauses.first
    end

    it 'waits the configured interval on a cooldown' do
      tm = build(task_cooldown_poll: 5)
      expect(first_pause(tm, 'Seamstress Zasele says, "I am sorry, you must wait before I can give you a task."')).to eq(5)
    end

    it 'waits the configured interval after a recent cancel' do
      tm = build(task_cooldown_poll: 6)
      expect(first_pause(tm, 'Seamstress Zasele is utterly ignoring you.')).to eq(6)
    end
  end
end
