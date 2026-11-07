# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('tarantula.lic', 'Tarantula')

# Tarantula#initialize waits tarantula_startup_delay before its first game
# command. At login, autostarted scripts start together and tap their own items
# at once, and DRC.bput takes the first matching line, even another script's
# reply. On 2026-11-08 tarantula's "I could not find what you were referring
# to." was taken by play.lic, which then exited with its zills worn.
RSpec.describe Tarantula do
  let(:events) { [] }
  let(:settings) do
    OpenStruct.new(
      tarantula: {},
      tarantula_startup_delay: 15,
      tarantula_noun: 'biomechanical tarantula',
      tarantula_excluded_skills: [],
      tarantula_skip_alternate: false,
      tarantula_no_use_scripts: [],
      tarantula_debug: false
    )
  end

  before do
    allow_any_instance_of(described_class).to receive(:get_settings).and_return(settings)
    allow_any_instance_of(described_class).to receive(:pause) { |_obj, seconds| events << [:pause, seconds] }
    allow_any_instance_of(described_class).to receive(:passive_loop) { events << [:passive_loop] }
    allow(DRCI).to receive(:exists?) { |noun| events << [:exists?, noun] && false }
    allow(DRC).to receive(:message)
    allow(DRC).to receive(:bput) do |command, *|
      events << [:bput, command]
      # Stub text shaped to check_last's /knowledge of (.*) techniques/ pattern.
      'It draws on your knowledge of Armor techniques.'
    end
  end

  context 'when the tarantula is missing' do
    it 'waits the startup delay before tapping, then exits' do
      expect { described_class.new }.to raise_error(SystemExit)
      expect(events).to eq([[:pause, 15], [:exists?, 'biomechanical tarantula']])
    end

    it 'still checks first thing when the delay is 0' do
      settings.tarantula_startup_delay = 0
      expect { described_class.new }.to raise_error(SystemExit)
      expect(events).to eq([[:pause, 0], [:exists?, 'biomechanical tarantula']])
    end
  end

  context 'when the tarantula is there' do
    before { allow(DRCI).to receive(:exists?) { |noun| events << [:exists?, noun] && true } }

    it 'waits once, before the tap and the STUDY, then starts the loop' do
      described_class.new
      expect(events).to eq([
                             [:pause, 15],
                             [:exists?, 'biomechanical tarantula'],
                             [:bput, 'study biomechanical tarantula'],
                             [:passive_loop]
                           ])
    end

    it 'skips the STUDY when the last skillset is remembered, still waiting first' do
      UserVars.tarantula_last_skillset = 'Armor'
      described_class.new
      expect(events).to eq([[:pause, 15], [:exists?, 'biomechanical tarantula'], [:passive_loop]])
    end
  end
end
