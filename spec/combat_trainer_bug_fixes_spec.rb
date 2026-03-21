# frozen_string_literal: true

require 'ostruct'

# Load test harness which provides mock game objects
load File.join(File.dirname(__FILE__), '..', 'test', 'test_harness.rb')
include Harness

# Extract and eval a class from a .lic file without executing top-level code
def load_lic_class(filename, class_name)
  return if Object.const_defined?(class_name)

  filepath = File.join(File.dirname(__FILE__), '..', filename)
  lines = File.readlines(filepath)

  start_idx = lines.index { |l| l =~ /^class\s+#{class_name}\b/ }
  raise "Could not find 'class #{class_name}' in #{filename}" unless start_idx

  end_idx = nil
  (start_idx + 1...lines.size).each do |i|
    if lines[i] =~ /^end\s*$/
      end_idx = i
      break
    end
  end
  raise "Could not find matching end for 'class #{class_name}' in #{filename}" unless end_idx

  class_source = lines[start_idx..end_idx].join
  eval(class_source, TOPLEVEL_BINDING, filepath, start_idx + 1)
end

# Stub modules needed by the extracted classes
module DRC
  class << self
    def bput(*_args)
      'Roundtime'
    end

    def message(*_args); end
  end
end

$ORDINALS = %w[first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth twentieth].freeze

$debug_mode_ct = false

load_lic_class('combat-trainer.lic', 'SetupProcess')
load_lic_class('combat-trainer.lic', 'ManipulateProcess')

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end
end

# ===========================================================================
# SetupProcess#last_stance -- nil guard for Flags['last-stance']
# ===========================================================================
RSpec.describe SetupProcess do
  def build_setup_process
    SetupProcess.allocate
  end

  describe '#last_stance' do
    context 'when Flags[last-stance] has not fired yet (nil)' do
      it 'returns zeroed stance hash instead of raising NoMethodError' do
        Flags['last-stance'] = nil
        instance = build_setup_process

        result = instance.send(:last_stance)

        expect(result).to eq({ 'EVASION' => 0, 'PARRY' => 0, 'SHIELD' => 0, 'SPARE' => 0 })
      end
    end

    context 'when Flags[last-stance] has a valid stance string' do
      it 'parses the percentages correctly' do
        Flags['last-stance'] = ['80% pointed stance 60% pointed stance 40% pointed stance 20']
        instance = build_setup_process

        result = instance.send(:last_stance)

        expect(result).to eq({ 'EVASION' => 80, 'PARRY' => 60, 'SHIELD' => 40, 'SPARE' => 20 })
      end
    end

    context 'when Flags[last-stance] has all zeros' do
      it 'returns all zeros' do
        Flags['last-stance'] = ['0% pointed stance 0% pointed stance 0% pointed stance 0']
        instance = build_setup_process

        result = instance.send(:last_stance)

        expect(result).to eq({ 'EVASION' => 0, 'PARRY' => 0, 'SHIELD' => 0, 'SPARE' => 0 })
      end
    end
  end
end

# ===========================================================================
# ManipulateProcess#manipulate -- ordinal targeting for duplicate NPCs
# ===========================================================================
RSpec.describe ManipulateProcess do
  def build_manipulate_process(**overrides)
    instance = ManipulateProcess.allocate
    defaults = {
      threshold: 5,
      manip_to_train: false,
      last_manip: Time.now - 200,
      filtered_npcs: []
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  def build_game_state(**attrs)
    defaults = {
      npcs: [],
      danger: false,
      construct_mode?: false
    }
    state = double('GameState', defaults.merge(attrs))
    allow(state).to receive(:construct?).and_return(false)
    allow(state).to receive(:construct)
    state
  end

  describe '#manipulate' do
    before(:each) do
      allow(DRC).to receive(:bput).and_return('You attempt to empathically manipulate')
    end

    context 'when all NPCs have different nouns' do
      it 'uses "first" ordinal for each NPC' do
        game_state = build_game_state
        instance = build_manipulate_process(
          threshold: 3,
          filtered_npcs: %w[rat kobold goblin]
        )

        instance.send(:manipulate, game_state)

        expect(DRC).to have_received(:bput).with(/manipulate friendship first rat/, anything, anything, anything, anything, anything, anything)
        expect(DRC).to have_received(:bput).with(/manipulate friendship first kobold/, anything, anything, anything, anything, anything, anything)
        expect(DRC).to have_received(:bput).with(/manipulate friendship first goblin/, anything, anything, anything, anything, anything, anything)
      end
    end

    context 'when multiple NPCs share the same noun' do
      it 'uses incrementing ordinals for duplicate nouns' do
        game_state = build_game_state
        instance = build_manipulate_process(
          threshold: 3,
          filtered_npcs: %w[rat rat rat]
        )

        instance.send(:manipulate, game_state)

        expect(DRC).to have_received(:bput).with(/manipulate friendship first rat/, anything, anything, anything, anything, anything, anything)
        expect(DRC).to have_received(:bput).with(/manipulate friendship second rat/, anything, anything, anything, anything, anything, anything)
        expect(DRC).to have_received(:bput).with(/manipulate friendship third rat/, anything, anything, anything, anything, anything, anything)
      end
    end

    context 'when mixed duplicate and unique NPCs are present' do
      it 'tracks ordinals independently per noun' do
        game_state = build_game_state
        instance = build_manipulate_process(
          threshold: 4,
          filtered_npcs: %w[rat kobold rat kobold]
        )

        instance.send(:manipulate, game_state)

        expect(DRC).to have_received(:bput).with(/manipulate friendship first rat/, anything, anything, anything, anything, anything, anything)
        expect(DRC).to have_received(:bput).with(/manipulate friendship first kobold/, anything, anything, anything, anything, anything, anything)
        expect(DRC).to have_received(:bput).with(/manipulate friendship second rat/, anything, anything, anything, anything, anything, anything)
        expect(DRC).to have_received(:bput).with(/manipulate friendship second kobold/, anything, anything, anything, anything, anything, anything)
      end
    end

    context 'when an NPC is a construct' do
      it 'skips constructs and does not increment ordinal for that noun' do
        game_state = build_game_state
        allow(game_state).to receive(:construct?).with('golem').and_return(true)
        allow(game_state).to receive(:construct?).with('rat').and_return(false)

        instance = build_manipulate_process(
          threshold: 2,
          filtered_npcs: %w[golem rat]
        )

        instance.send(:manipulate, game_state)

        expect(DRC).not_to have_received(:bput).with(/manipulate friendship .* golem/, anything, anything, anything, anything, anything, anything)
        expect(DRC).to have_received(:bput).with(/manipulate friendship first rat/, anything, anything, anything, anything, anything, anything)
      end
    end

    context 'when threshold limits the number of manipulations' do
      it 'stops after reaching the threshold' do
        game_state = build_game_state
        instance = build_manipulate_process(
          threshold: 2,
          filtered_npcs: %w[rat rat rat]
        )

        instance.send(:manipulate, game_state)

        expect(DRC).to have_received(:bput).with(/manipulate friendship first rat/, anything, anything, anything, anything, anything, anything)
        expect(DRC).to have_received(:bput).with(/manipulate friendship second rat/, anything, anything, anything, anything, anything, anything)
        expect(DRC).not_to have_received(:bput).with(/manipulate friendship third rat/, anything, anything, anything, anything, anything, anything)
      end
    end
  end
end
