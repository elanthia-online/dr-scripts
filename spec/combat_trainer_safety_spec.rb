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

# Stub modules
module DRC
  class << self
    def bput(*_args)
      'Roundtime'
    end

    def message(*_args); end
    def fix_standing; end

    def wait_for_script_to_complete(*_args); end
  end
end

module DRCH
  class << self
    def has_tendable_bleeders?
      false
    end
  end
end

module DRCA
  class << self
    def activate_khri?(*_args)
      true
    end
  end
end

# Extend harness DRSpells with known_spells and active_spells
class DRSpells
  @@_known_spells = {}

  def self.known_spells
    @@_known_spells
  end

  def self._set_known_spells(val)
    @@_known_spells = val
  end

  def self.active_spells
    {}
  end
end

$HUNTING_BUDDY = nil
$COMBAT_TRAINER = nil
$debug_mode_ct = false

load_lic_class('combat-trainer.lic', 'SafetyProcess')

RSpec.configure do |config|
  config.before(:each) do
    reset_data
    DRSpells._set_known_spells({})
    $HUNTING_BUDDY = double('HuntingBuddy', stop_hunting: nil)
    $COMBAT_TRAINER = double('CombatTrainer', stop: nil)
  end
end

RSpec.describe SafetyProcess do
  def build_safety_process(**overrides)
    instance = SafetyProcess.allocate
    defaults = {
      equipment_manager: double('EquipmentManager'),
      health_threshold: 20,
      stop_on_bleeding: true,
      safety_untendable_threshold: 3,
      safety_exit_on_bleeding: false,
      safety_concentration_minimum: nil,
      safety_escape_health_threshold: nil,
      untendable_counter: 0
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  def build_game_state(**attrs)
    defaults = {
      danger: false,
      retreating?: false
    }
    state = double('GameState', defaults.merge(attrs))
    allow(state).to receive(:danger=)
    state
  end

  # Stub the rest of execute that runs after the safety branches
  def stub_post_safety(instance)
    allow(instance).to receive(:check_item_recovery)
    allow(instance).to receive(:tend_lodged)
    allow(instance).to receive(:tend_parasite)
    allow(instance).to receive(:active_mitigation)
    allow(instance).to receive(:in_danger?).and_return(false)
    allow(instance).to receive(:keep_away)
    allow(instance).to receive(:bleeding?).and_return(false)
    allow(instance).to receive(:stunned?).and_return(false)
    DRStats.health = 100
    DRStats.concentration = 100
    allow(DRCA).to receive(:activate_khri?).and_return(true)
  end

  describe '#execute' do
    describe 'safety_untendable_threshold' do
      it 'stops hunt at default threshold of 3' do
        instance = build_safety_process(untendable_counter: 3)
        stub_post_safety(instance)
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).to have_received(:stop_hunting)
        expect($COMBAT_TRAINER).to have_received(:stop)
      end

      it 'does not stop hunt below default threshold' do
        instance = build_safety_process(untendable_counter: 2)
        stub_post_safety(instance)
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
      end

      it 'stops hunt at custom threshold of 1' do
        instance = build_safety_process(safety_untendable_threshold: 1, untendable_counter: 1)
        stub_post_safety(instance)
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).to have_received(:stop_hunting)
      end

      it 'requires stop_on_bleeding to be true' do
        instance = build_safety_process(untendable_counter: 3, stop_on_bleeding: false)
        stub_post_safety(instance)
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
      end
    end

    describe 'safety_concentration_minimum' do
      it 'stops hunt when concentration drops below minimum' do
        instance = build_safety_process(safety_concentration_minimum: 10)
        stub_post_safety(instance)
        DRStats.concentration = 5
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).to have_received(:stop_hunting)
      end

      it 'does not stop hunt when concentration is above minimum' do
        instance = build_safety_process(safety_concentration_minimum: 10)
        stub_post_safety(instance)
        DRStats.concentration = 50
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
      end

      it 'is disabled when nil' do
        DRStats.concentration = 0
        instance = build_safety_process(safety_concentration_minimum: nil)
        stub_post_safety(instance)
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
      end
    end

    describe 'safety_escape_health_threshold (Thief Vanish)' do
      before(:each) do
        DRStats.guild = 'Thief'
        DRSpells._set_known_spells({ 'Vanish' => true })
      end

      it 'activates Vanish and stops hunt when health is below threshold' do
        instance = build_safety_process(safety_escape_health_threshold: 90)
        stub_post_safety(instance)
        DRStats.health = 85
        game_state = build_game_state

        instance.execute(game_state)

        expect(DRCA).to have_received(:activate_khri?).with(false, "Vanish")
        expect($HUNTING_BUDDY).to have_received(:stop_hunting)
      end

      it 'activates Vanish when bleeding' do
        DRStats.health = 100
        instance = build_safety_process(safety_escape_health_threshold: 90)
        stub_post_safety(instance)
        allow(instance).to receive(:bleeding?).and_return(true)
        game_state = build_game_state

        instance.execute(game_state)

        expect(DRCA).to have_received(:activate_khri?).with(false, "Vanish")
      end

      it 'does not fire for non-Thieves' do
        instance = build_safety_process(safety_escape_health_threshold: 90)
        stub_post_safety(instance)
        DRStats.guild = 'Ranger'
        DRStats.health = 50
        game_state = build_game_state

        instance.execute(game_state)

        expect(DRCA).not_to have_received(:activate_khri?)
      end

      it 'does not fire if Thief does not know Vanish' do
        instance = build_safety_process(safety_escape_health_threshold: 90)
        stub_post_safety(instance)
        DRSpells._set_known_spells({})
        DRStats.health = 50
        game_state = build_game_state

        instance.execute(game_state)

        expect(DRCA).not_to have_received(:activate_khri?)
      end

      it 'is disabled when nil' do
        instance = build_safety_process(safety_escape_health_threshold: nil)
        stub_post_safety(instance)
        DRStats.health = 10
        game_state = build_game_state

        instance.execute(game_state)

        expect(DRCA).not_to have_received(:activate_khri?)
      end
    end

    describe 'safety_exit_on_bleeding' do
      it 'stops hunt when bleeding and setting is true' do
        instance = build_safety_process(safety_exit_on_bleeding: true)
        stub_post_safety(instance)
        allow(instance).to receive(:bleeding?).and_return(true)
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).to have_received(:stop_hunting)
      end

      it 'stops hunt when stunned with low health' do
        instance = build_safety_process(safety_exit_on_bleeding: true)
        stub_post_safety(instance)
        DRStats.health = 70
        allow(instance).to receive(:stunned?).and_return(true)
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).to have_received(:stop_hunting)
      end

      it 'does not stop hunt when stunned with high health' do
        instance = build_safety_process(safety_exit_on_bleeding: true)
        stub_post_safety(instance)
        DRStats.health = 95
        allow(instance).to receive(:stunned?).and_return(true)
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
      end

      it 'does not fire when setting is false' do
        instance = build_safety_process(safety_exit_on_bleeding: false)
        stub_post_safety(instance)
        allow(instance).to receive(:bleeding?).and_return(true)
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
      end
    end
  end
end
