# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')

RSpec.describe TaskMaster do
  # A bare instance: initialize runs the whole script, so each example injects
  # only the state the method under test reads.
  def build
    tm = described_class.allocate
    tm.instance_variable_set(:@settings, OpenStruct.new)
    tm.instance_variable_set(:@bag, 'duffel bag')
    tm.instance_variable_set(:@npc, 'zasele')
    tm.instance_variable_set(:@rooms, [16_145])
    allow(tm).to receive(:sort_sack)
    allow(tm).to receive(:fput)
    allow(DRC).to receive(:message)
    tm
  end

  describe '#complete_task' do
    # Turn-in responses as the game prints them (2025 Hollow Eve logs).
    let(:more_needed) { 'Zasele holds up her fingers indicating 1 more is needed.' }
    let(:done) { 'Seamstress Zasele hands you a woven sack.' }
    let(:missed) { "What is it you're trying to give?" }

    # Plays the given give responses in order and tracks what is in hand: a
    # successful give empties the hand, a missed one leaves the item there.
    def turn_in(tm, responses)
      holding = false
      gets = 0
      allow(tm).to receive(:find_npc)
      allow(DRCI).to receive(:in_hands?) { holding }
      allow(DRCI).to receive(:get_item?) do
        gets += 1
        holding = true
      end
      allow(DRC).to receive(:bput) do |command, *_matchers|
        next '' unless command.start_with?('give my rope to zasele')

        response = responses.shift
        holding = false unless response == missed
        response
      end
      tm.complete_task('rope', 2)
      gets
    end

    it 'fetches one item per accepted give' do
      tm = build
      expect(turn_in(tm, [more_needed, done])).to eq(2)
      expect(tm).to have_received(:sort_sack).with('rope')
    end

    it 'gives the item still in hand when the taskmaster wandered off, instead of fetching another' do
      tm = build
      expect(turn_in(tm, [more_needed, missed, done])).to eq(2)
      expect(tm).to have_received(:find_npc).exactly(3).times
      expect(tm).to have_received(:sort_sack).with('rope')
    end

    it 'stops after repeated misses rather than looping forever' do
      tm = build
      expect { turn_in(tm, Array.new(10, missed)) }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with(/after 5 tries/)
      expect(tm).not_to have_received(:sort_sack)
    end

    it 'resets the miss count after a give lands' do
      tm = build
      responses = [missed, missed, missed, missed, more_needed, missed, missed, missed, missed, done]
      expect { turn_in(tm, responses) }.not_to raise_error
      expect(tm).to have_received(:sort_sack)
    end

    it 'exits when the bag runs out of items, as before' do
      tm = build
      allow(tm).to receive(:find_npc)
      allow(DRCI).to receive(:in_hands?).and_return(false)
      allow(DRCI).to receive(:get_item?).and_return(false)
      expect { tm.complete_task('rope', 2) }.to raise_error(SystemExit)
    end
  end
end
