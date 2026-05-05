# frozen_string_literal: true

require 'ostruct'

load File.join(File.dirname(__FILE__), '..', 'test', 'test_harness.rb')
include Harness

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

# Minimal module stubs for modules not provided by the test harness
module DRC
  class << self
    def bput(*_args)
      ''
    end

    def wait_for_script_to_complete(*_args); end

    def fix_standing; end

    def log_window(_msg, _window = nil); end
  end
end unless defined?(DRC)

module DRCH
  class << self
    def check_health
      OpenStruct.new(wounds: {}, poisoned: false, diseased: false, score: 0, dead: false)
    end

    def perceive_health_other(_target)
      OpenStruct.new(wounds: {}, parasites: {}, poisoned: false, diseased: false, score: 0, dead: false)
    end
  end
end unless defined?(DRCH)

module Lich
  module Messaging
    def self.msg(_style, _message); end
  end

  module Util
    def self.issue_command(*_args)
      []
    end
  end
end unless defined?(Lich)

# Provide start_script and DRSpells.known_spells if not already defined
def start_script(*_args); end unless defined?(start_script)

Harness::DRSpells.define_singleton_method(:known_spells) { @_known_spells || {} } unless Harness::DRSpells.respond_to?(:known_spells)
Harness::DRSpells.define_singleton_method(:_set_known_spells) { |val| @_known_spells = val }

load_lic_class('healer.lic', 'Healer')

# Helper to build a Healer instance bypassing startup validations.
# Tests that exercise validation do so explicitly.
#
# @param settings [Hash] overrides merged into default test settings
# @param friends [Array<String>] friend list for the healer
# @param unity [Boolean] whether Unity link is available (default true)
# @return [Healer] configured instance
def build_healer(settings: {}, friends: [], unity: true)
  test_settings = OpenStruct.new({
    friends: friends,
    healer_waggle_set: 'healme',
    cambrinth: 'cambrinth ring',
    waggle_sets: nil
  }.merge(settings))
  $test_settings = test_settings

  # Stub startup validations so we can construct without game commands
  allow_any_instance_of(Healer).to receive(:validate_link_unity)
  allow_any_instance_of(Healer).to receive(:validate_healing_spells).and_return(false)
  allow_any_instance_of(Healer).to receive(:validate_vh_spell).and_return(false)

  healer = Healer.new
  healer.instance_variable_set(:@unity_available, unity)
  healer
end

# Builds a HealthResult-like object with sensible defaults
def health_result(overrides = {})
  defaults = { wounds: {}, parasites: {}, poisoned: false, diseased: false, score: 0, dead: false }
  OpenStruct.new(defaults.merge(overrides))
end

# Builds a Wound-like object
def wound(body_part:, severity: 1, is_internal: false)
  OpenStruct.new(body_part: body_part, severity: severity, is_internal: is_internal)
end

# ============================================================
# SPECS
# ============================================================

RSpec.describe Healer do
  before(:each) do
    reset_data
    DRStats.health = 100
    DRStats.guild = 'Empath'
    Harness::DRSpells._set_active_spells({})
    Harness::DRSpells._set_known_spells({})
    allow(DRC).to receive(:bput).and_return('')
    allow(DRC).to receive(:fix_standing)
    allow(DRC).to receive(:log_window)
    allow(DRCH).to receive(:check_health).and_return(health_result)
    allow(Lich::Messaging).to receive(:msg)
  end

  # ============================================================
  # Queue Management (Single Responsibility)
  # ============================================================

  describe 'queue management' do
    describe '#add_patient' do
      it 'adds a patient to the queue with initial state' do
        healer = build_healer(friends: ['Tenuk'])
        healer.add_patient('Tenuk')

        patient = healer.patients[:tenuk]
        expect(patient).not_to be_nil
        expect(patient[:name]).to eq('Tenuk')
        expect(patient[:touched]).to be false
        expect(patient[:vh_attempted]).to be false
        expect(patient[:body_part]).to be_nil
      end

      it 'does not duplicate patients already in the queue' do
        healer = build_healer(friends: ['Tenuk'])
        healer.add_patient('Tenuk')
        healer.add_patient('Tenuk')

        expect(healer.patients.size).to eq(1)
      end

      it 'normalizes patient names to lowercase symbol keys' do
        healer = build_healer
        healer.add_patient('Tenuk')

        expect(healer.patients).to have_key(:tenuk)
      end
    end

    describe '#remove_patient' do
      it 'removes a patient from the queue' do
        healer = build_healer
        healer.add_patient('Tenuk')
        healer.send(:remove_patient, 'Tenuk', reason: :healed)

        expect(healer.patients).to be_empty
      end

      it 'cleans up spell slot when removing the patient who owns it' do
        healer = build_healer
        healer.add_patient('Tenuk')
        healer.claim_spell_slot('Tenuk', :poison)

        healer.send(:remove_patient, 'Tenuk', reason: :left_room)

        expect(healer.instance_variable_get(:@spell_task)).to be_nil
      end

      it 'removes queued spell tasks for the removed patient' do
        healer = build_healer
        healer.add_patient('Tenuk')
        healer.add_patient('Navesi')

        healer.claim_spell_slot('Tenuk', :poison)
        healer.claim_spell_slot('Navesi', :vitality) # queued

        healer.send(:remove_patient, 'Navesi', reason: :left_room)

        queue = healer.instance_variable_get(:@spell_queue)
        expect(queue).to be_empty
      end
    end

    describe '#patient_ready?' do
      it 'returns true for a patient that has not been touched' do
        healer = build_healer
        healer.add_patient('Tenuk')

        expect(healer.patient_ready?('Tenuk')).to be true
      end

      it 'returns false for a recently touched patient within cooldown' do
        healer = build_healer
        healer.add_patient('Tenuk')
        healer.send(:update_patient, 'Tenuk', touched: true, timer: Time.now)

        expect(healer.patient_ready?('Tenuk')).to be false
      end

      it 'returns true for a touched patient after cooldown expires' do
        healer = build_healer
        healer.add_patient('Tenuk')
        healer.send(:update_patient, 'Tenuk', touched: true, timer: Time.now - Healer::COOLDOWN_SECONDS - 1)

        expect(healer.patient_ready?('Tenuk')).to be true
      end
    end
  end

  # ============================================================
  # Spell Slot Mutex (Single Responsibility for resource management)
  # ============================================================

  describe 'spell slot mutex' do
    describe '#claim_spell_slot' do
      it 'claims a free spell slot for a patient' do
        healer = build_healer
        healer.add_patient('Tenuk')

        result = healer.claim_spell_slot('Tenuk', :poison)

        expect(result).to be true
        task = healer.instance_variable_get(:@spell_task)
        expect(task[:patient]).to eq('Tenuk')
        expect(task[:type]).to eq(:poison)
        expect(task[:phase]).to eq(:start)
      end

      it 'returns true when the same patient already owns the slot for the same type' do
        healer = build_healer
        healer.add_patient('Tenuk')
        healer.claim_spell_slot('Tenuk', :poison)

        result = healer.claim_spell_slot('Tenuk', :poison)

        expect(result).to be true
      end

      it 'queues a different patient when the slot is occupied' do
        healer = build_healer
        healer.add_patient('Tenuk')
        healer.add_patient('Navesi')

        healer.claim_spell_slot('Tenuk', :poison)
        result = healer.claim_spell_slot('Navesi', :disease)

        expect(result).to be false
        queue = healer.instance_variable_get(:@spell_queue)
        expect(queue.size).to eq(1)
        expect(queue.first[:patient]).to eq('Navesi')
      end

      it 'does not duplicate entries in the spell queue' do
        healer = build_healer
        healer.add_patient('Tenuk')
        healer.add_patient('Navesi')

        healer.claim_spell_slot('Tenuk', :poison)
        healer.claim_spell_slot('Navesi', :vitality)
        healer.claim_spell_slot('Navesi', :vitality)

        queue = healer.instance_variable_get(:@spell_queue)
        expect(queue.size).to eq(1)
      end
    end

    describe '#release_spell_slot' do
      it 'clears the current spell task' do
        healer = build_healer
        healer.add_patient('Tenuk')
        healer.claim_spell_slot('Tenuk', :poison)

        healer.send(:release_spell_slot)

        expect(healer.instance_variable_get(:@spell_task)).to be_nil
      end

      it 'auto-pops the next queued task on release' do
        healer = build_healer
        healer.add_patient('Tenuk')
        healer.add_patient('Navesi')

        healer.claim_spell_slot('Tenuk', :poison)
        healer.claim_spell_slot('Navesi', :vitality)

        healer.send(:release_spell_slot)

        task = healer.instance_variable_get(:@spell_task)
        expect(task[:patient]).to eq('Navesi')
        expect(task[:type]).to eq(:vitality)
        expect(task[:phase]).to eq(:start)
      end

      it 'skips queued tasks for patients who have left' do
        healer = build_healer
        healer.add_patient('Tenuk')
        healer.add_patient('Navesi')
        healer.add_patient('Emeshest')

        healer.claim_spell_slot('Tenuk', :poison)
        healer.claim_spell_slot('Navesi', :vitality)
        healer.claim_spell_slot('Emeshest', :disease)

        # Navesi leaves before her turn
        healer.patients.delete(:navesi)

        healer.send(:release_spell_slot)

        task = healer.instance_variable_get(:@spell_task)
        expect(task[:patient]).to eq('Emeshest')
      end
    end

    describe '#clear_spell_slot' do
      it 'manually clears the spell slot and queue' do
        healer = build_healer
        healer.add_patient('Tenuk')
        healer.add_patient('Navesi')

        healer.claim_spell_slot('Tenuk', :poison)
        healer.claim_spell_slot('Navesi', :vitality)

        healer.clear_spell_slot

        expect(healer.instance_variable_get(:@spell_task)).to be_nil
        expect(healer.instance_variable_get(:@spell_queue)).to be_empty
      end
    end
  end

  # ============================================================
  # Dead Patient Detection
  # ============================================================

  describe 'dead patient detection' do
    it 'transfers wounds from dead patient without blocking' do
      healer = build_healer(friends: ['Tenuk'])
      healer.add_patient('Tenuk')
      DRRoom.pcs = ['Tenuk']

      dead_with_wounds = health_result(
        dead: true,
        score: 9,
        wounds: { 2 => [wound(body_part: 'right leg', severity: 2)] }
      )
      allow(DRCH).to receive(:perceive_health_other).with('Tenuk').and_return(dead_with_wounds)

      healer.send(:heal_patient, healer.get_patient('Tenuk'))

      # Patient stays in queue -- non-blocking, will continue next cycle
      expect(healer.patients).to have_key(:tenuk)
      expect(healer.get_patient('Tenuk')[:touched]).to be true
    end

    it 'whispers and removes dead patient when wounds are clear' do
      healer = build_healer(friends: ['Tenuk'])
      healer.add_patient('Tenuk')
      DRRoom.pcs = ['Tenuk']

      dead_clear = health_result(dead: true, score: 0)
      allow(DRCH).to receive(:perceive_health_other).with('Tenuk').and_return(dead_clear)

      expect(DRC).to receive(:bput)
        .with("whisper Tenuk You're dead -- get a cleric!", anything, anything, anything)

      healer.send(:heal_patient, healer.get_patient('Tenuk'))

      expect(healer.patients).to be_empty
    end

    it 'does not use Unity link for dead patients' do
      healer = build_healer(friends: ['Tenuk'])
      healer.add_patient('Tenuk')
      DRRoom.pcs = ['Tenuk']

      dead_clear = health_result(dead: true, score: 0)
      allow(DRCH).to receive(:perceive_health_other).with('Tenuk').and_return(dead_clear)

      expect(DRC).not_to receive(:bput)
        .with(a_string_matching(/link.*unity/), *Healer::LINK_RESPONSES)

      healer.send(:heal_patient, healer.get_patient('Tenuk'))
    end

    it 'does not attempt vitality transfer on a dead patient' do
      healer = build_healer(friends: ['Tenuk'])
      healer.add_patient('Tenuk')
      DRRoom.pcs = ['Tenuk']

      dead_health = health_result(dead: true, score: 0)
      allow(DRCH).to receive(:perceive_health_other).with('Tenuk').and_return(dead_health)

      healer.send(:heal_patient, healer.get_patient('Tenuk'))

      expect(healer.instance_variable_get(:@spell_task)).to be_nil
    end
  end

  # ============================================================
  # Unity Link Availability (Graceful Degradation)
  # ============================================================

  describe 'validate_link_unity' do
    it 'sets @unity_available to true when UNITY appears in link output' do
      $test_settings = OpenStruct.new(friends: [], healer_waggle_set: 'healme', cambrinth: nil, waggle_sets: nil)

      allow_any_instance_of(Healer).to receive(:validate_healing_spells).and_return(false)
      allow_any_instance_of(Healer).to receive(:validate_vh_spell).and_return(false)

      link_output = ['<output>LINK options: TOUCH UNITY</output>']
      allow(Lich::Util).to receive(:issue_command).and_return(link_output)

      healer = Healer.new

      expect(healer.instance_variable_get(:@unity_available)).to be true
    end

    it 'sets @unity_available to false when UNITY is absent from link output' do
      $test_settings = OpenStruct.new(friends: [], healer_waggle_set: 'healme', cambrinth: nil, waggle_sets: nil)

      allow_any_instance_of(Healer).to receive(:validate_healing_spells).and_return(false)
      allow_any_instance_of(Healer).to receive(:validate_vh_spell).and_return(false)

      link_output = ['<output>LINK options: TOUCH</output>']
      allow(Lich::Util).to receive(:issue_command).and_return(link_output)

      healer = Healer.new

      expect(healer.instance_variable_get(:@unity_available)).to be false
    end

    it 'does not message when Unity is not available' do
      $test_settings = OpenStruct.new(friends: [], healer_waggle_set: 'healme', cambrinth: nil, waggle_sets: nil)

      allow_any_instance_of(Healer).to receive(:validate_healing_spells).and_return(false)
      allow_any_instance_of(Healer).to receive(:validate_vh_spell).and_return(false)

      link_output = ['<output>LINK options: TOUCH</output>']
      allow(Lich::Util).to receive(:issue_command).and_return(link_output)

      expect(Lich::Messaging).not_to receive(:msg).with('bold', /Unity/)

      Healer.new
    end
  end

  # ============================================================
  # Living Patient Unity Link Gating
  # ============================================================

  describe 'living patient healing with Unity gating' do
    it 'attempts Unity link when @unity_available is true and patient has healable wounds' do
      healer = build_healer(friends: ['Tenuk'], unity: true)
      healer.add_patient('Tenuk')
      DRRoom.pcs = ['Tenuk']

      living_wounded = health_result(
        score: 9,
        wounds: { 2 => [wound(body_part: 'chest', severity: 2)] }
      )
      allow(DRCH).to receive(:perceive_health_other).with('Tenuk').and_return(living_wounded)

      expect(DRC).to receive(:bput)
        .with('link Tenuk unity', *Healer::LINK_RESPONSES)
        .and_return('You feel a connection')

      healer.send(:heal_patient, healer.get_patient('Tenuk'))
    end

    it 'skips Unity link when @unity_available is false' do
      healer = build_healer(friends: ['Tenuk'], unity: false)
      healer.add_patient('Tenuk')
      DRRoom.pcs = ['Tenuk']

      living_wounded = health_result(
        score: 9,
        wounds: { 2 => [wound(body_part: 'chest', severity: 2)] }
      )
      allow(DRCH).to receive(:perceive_health_other).with('Tenuk').and_return(living_wounded)

      expect(DRC).not_to receive(:bput)
        .with(a_string_matching(/link.*unity/i), *Healer::LINK_RESPONSES)

      healer.send(:heal_patient, healer.get_patient('Tenuk'))
    end

    it 'still queues poison patients when Unity is unavailable' do
      healer = build_healer(friends: ['Tenuk'], unity: false)
      healer.add_patient('Tenuk')
      DRRoom.pcs = ['Tenuk']

      poisoned_patient = health_result(poisoned: true, score: 0)
      allow(DRCH).to receive(:perceive_health_other).with('Tenuk').and_return(poisoned_patient)

      healer.send(:heal_patient, healer.get_patient('Tenuk'))

      task = healer.instance_variable_get(:@spell_task)
      expect(task).not_to be_nil
      expect(task[:type]).to eq(:poison)
    end

    it 'still queues diseased patients when Unity is unavailable' do
      healer = build_healer(friends: ['Tenuk'], unity: false)
      healer.add_patient('Tenuk')
      DRRoom.pcs = ['Tenuk']

      diseased_patient = health_result(diseased: true, score: 0)
      allow(DRCH).to receive(:perceive_health_other).with('Tenuk').and_return(diseased_patient)

      healer.send(:heal_patient, healer.get_patient('Tenuk'))

      expect(healer.get_patient('Tenuk')[:touched]).to be true
    end
  end

  # ============================================================
  # Wound Healing Body Part Selection (Open-Closed: new parts can be added)
  # ============================================================

  # HealthResult.wounds is keyed by severity (integer), not body part.
  # These tests use severity-keyed hashes to match production DRCH output.
  describe '#has_healable_wounds?' do
    let(:healer) { build_healer }

    shared_examples 'detects healable wounds' do |body_part|
      it "recognizes wounds on #{body_part}" do
        health = health_result(
          wounds: { 2 => [wound(body_part: body_part, severity: 2)] }
        )
        expect(healer.send(:has_healable_wounds?, health)).to be true
      end
    end

    %w[chest abdomen back head neck].each do |part|
      include_examples 'detects healable wounds', part
    end

    ['left arm', 'right arm', 'left eye', 'right eye'].each do |part|
      include_examples 'detects healable wounds', part
    end

    it 'returns false when patient only has hand wounds' do
      health = health_result(
        wounds: { 3 => [wound(body_part: 'right hand', severity: 3)] }
      )
      expect(healer.send(:has_healable_wounds?, health)).to be false
    end

    it 'returns false when patient only has leg wounds' do
      health = health_result(
        wounds: { 2 => [wound(body_part: 'left leg', severity: 2)] }
      )
      expect(healer.send(:has_healable_wounds?, health)).to be false
    end

    it 'returns false when patient has no wounds' do
      health = health_result(wounds: {})
      expect(healer.send(:has_healable_wounds?, health)).to be false
    end

    it 'finds healable wounds among mixed severity keys' do
      health = health_result(
        wounds: {
          1 => [wound(body_part: 'left leg', severity: 1)],
          3 => [wound(body_part: 'chest', severity: 3)]
        }
      )
      expect(healer.send(:has_healable_wounds?, health)).to be true
    end

    it 'returns false when all healable-location wounds have severity 0' do
      health = health_result(
        wounds: { 0 => [wound(body_part: 'chest', severity: 0)] }
      )
      expect(healer.send(:has_healable_wounds?, health)).to be false
    end
  end

  # ============================================================
  # Body Part Rotation (available_heal_locations)
  # ============================================================

  describe '#available_heal_locations' do
    let(:healer) { build_healer }

    it 'returns all heal locations when healer has no wounds' do
      allow(DRCH).to receive(:check_health).and_return(health_result(wounds: {}))

      result = healer.send(:available_heal_locations)
      expect(result).to eq(Healer::HEAL_LOCATIONS)
    end

    it 'excludes wounded body parts from available locations' do
      wounded_health = health_result(
        wounds: { 2 => [wound(body_part: 'left arm', severity: 2)] },
        score: 4
      )
      allow(DRCH).to receive(:check_health).and_return(wounded_health)

      result = healer.send(:available_heal_locations)
      expect(result).not_to include('left arm')
      expect(result).to include('right arm', 'head', 'chest')
    end

    it 'excludes multiple wounded parts across severity levels' do
      wounded_health = health_result(
        wounds: {
          2 => [wound(body_part: 'left arm', severity: 2)],
          3 => [wound(body_part: 'chest', severity: 3)]
        },
        score: 13
      )
      allow(DRCH).to receive(:check_health).and_return(wounded_health)

      result = healer.send(:available_heal_locations)
      expect(result).not_to include('left arm')
      expect(result).not_to include('chest')
      expect(result).to include('right arm', 'head', 'abdomen', 'back')
    end

    it 'returns empty when all heal locations are wounded' do
      all_wounded = Healer::HEAL_LOCATIONS.map.with_index do |part, i|
        wound(body_part: part, severity: (i % 3) + 1)
      end
      wounds_by_severity = all_wounded.group_by(&:severity)
      wounded_health = health_result(wounds: wounds_by_severity, score: 99)
      allow(DRCH).to receive(:check_health).and_return(wounded_health)

      result = healer.send(:available_heal_locations)
      expect(result).to be_empty
    end
  end

  # ============================================================
  # Line Processing / Trigger Patterns (Open-Closed: new triggers addable)
  # ============================================================

  describe 'trigger pattern matching' do
    let(:healer) { build_healer(friends: %w[Tenuk Navesi Emeshest]) }

    shared_examples 'queues a friend' do |description, line, expected_name|
      it "queues #{expected_name} from #{description}" do
        healer.send(:queue_from_line, line)
        expect(healer.patients).to have_key(expected_name.downcase.to_sym)
      end
    end

    shared_examples 'ignores a non-friend' do |description, line|
      it "ignores non-friend from #{description}" do
        healer.send(:queue_from_line, line)
        expect(healer.patients).to be_empty
      end
    end

    include_examples 'queues a friend',
                     'whisper heal', 'Tenuk whispers, "heal"', 'Tenuk'

    include_examples 'queues a friend',
                     'titled whisper heal', 'Dark Summoner Tenuk whispers, "heal"', 'Tenuk'

    include_examples 'queues a friend',
                     'lean on', 'Navesi leans on you', 'Navesi'

    include_examples 'queues a friend',
                     'offer', 'Emeshest offers you something', 'Emeshest'

    include_examples 'queues a friend',
                     'gesture', 'Tenuk gestures.', 'Tenuk'

    include_examples 'queues a friend',
                     'moongate arrival',
                     'As your eyes slowly recover, you notice a dazed-looking Navesi',
                     'Navesi'

    include_examples 'queues a friend',
                     'regular arrival', 'Tenuk just arrived.', 'Tenuk'

    include_examples 'ignores a non-friend',
                     'non-friend whisper', 'Stranger whispers, "heal"'

    include_examples 'ignores a non-friend',
                     'non-friend lean', 'Stranger leans on you'
  end

  # ============================================================
  # Parasite Tending (Single Responsibility)
  # ============================================================

  describe '#handle_parasites' do
    it 'tends each parasite found on the patient' do
      healer = build_healer
      parasites = {
        1 => [
          wound(body_part: 'right leg'),
          wound(body_part: 'left arm')
        ]
      }
      health = health_result(parasites: parasites)

      healer.send(:handle_parasites, 'Tenuk', health)

      messages = []
      messages << $sent_messages.pop until $sent_messages.empty?
      expect(messages).to include('tend Tenuk right leg')
      expect(messages).to include('tend Tenuk left arm')
    end

    it 'does nothing when patient has no parasites' do
      healer = build_healer
      health = health_result(parasites: {})

      healer.send(:handle_parasites, 'Tenuk', health)

      expect($sent_messages).to be_empty
    end
  end

  # ============================================================
  # VH Spell Slot State Machine (Liskov: all spell types share slot interface)
  # ============================================================

  describe 'vitality healing state machine' do
    it 'skips vit transfer when own vitality is below the safety floor' do
      healer = build_healer
      healer.add_patient('Tenuk')
      DRStats.health = 55 # Below SELF_VIT_FLOOR of 60

      healer.claim_spell_slot('Tenuk', :vitality)
      healer.send(:process_vitality_slot)

      # Should release slot and mark vh_attempted
      expect(healer.instance_variable_get(:@spell_task)).to be_nil
      expect(healer.get_patient('Tenuk')[:vh_attempted]).to be true
    end

    it 'preps VH and transitions to prepping phase from start' do
      healer = build_healer
      healer.add_patient('Tenuk')
      healer.instance_variable_set(:@vh_available, true)
      healer.instance_variable_set(:@vh_spell, { name: 'Vitality Healing', mana: 5, cambrinth: [], prep_time: 3 })
      DRStats.health = 100

      healer.claim_spell_slot('Tenuk', :vitality)
      healer.send(:process_vitality_slot)

      task = healer.instance_variable_get(:@spell_task)
      expect(task[:phase]).to eq(:prepping)
      expect(task[:prep_start]).not_to be_nil
    end

    it 're-preps VH for another round when patient still needs vitality' do
      healer = build_healer
      healer.add_patient('Tenuk')
      healer.instance_variable_set(:@vh_available, true)
      healer.instance_variable_set(:@vh_spell, { name: 'Vitality Healing', mana: 5, cambrinth: [], prep_time: 3 })

      healer.claim_spell_slot('Tenuk', :vitality)

      task = healer.instance_variable_get(:@spell_task)
      task[:phase] = :recovering
      task[:timer] = Time.now

      DRStats.health = 95

      low_vit = health_result(vitality: 50)
      allow(DRCH).to receive(:perceive_health_other).with('Tenuk').and_return(low_vit)

      healer.send(:process_vitality_slot)

      task = healer.instance_variable_get(:@spell_task)
      expect(task[:phase]).to eq(:prepping)
    end

    it 'releases slot when patient vitality is adequate after recovery' do
      healer = build_healer
      healer.add_patient('Tenuk')

      healer.claim_spell_slot('Tenuk', :vitality)

      task = healer.instance_variable_get(:@spell_task)
      task[:phase] = :recovering
      task[:timer] = Time.now
      DRStats.health = 95

      adequate_vit = health_result(vitality: 90)
      allow(DRCH).to receive(:perceive_health_other).with('Tenuk').and_return(adequate_vit)

      healer.send(:process_vitality_slot)

      expect(healer.instance_variable_get(:@spell_task)).to be_nil
      expect(healer.get_patient('Tenuk')[:vh_attempted]).to be true
    end

    it 'waits in recovering phase when health is between floor and stable threshold' do
      healer = build_healer
      healer.add_patient('Tenuk')

      healer.claim_spell_slot('Tenuk', :vitality)

      task = healer.instance_variable_get(:@spell_task)
      task[:phase] = :recovering
      task[:timer] = Time.now
      DRStats.health = 75

      healer.send(:process_vitality_slot)

      task = healer.instance_variable_get(:@spell_task)
      expect(task[:phase]).to eq(:recovering)
    end
  end

  # ============================================================
  # Affliction Spell Slot (Liskov: same interface as VH)
  # ============================================================

  describe 'affliction spell slot processing' do
    it 'transfers poison and transitions to cure_self phase' do
      healer = build_healer
      healer.add_patient('Tenuk')

      allow(DRC).to receive(:bput)
        .with("transfer Tenuk quick poison", anything, anything)
        .and_return('You reluctantly touch')

      healer.claim_spell_slot('Tenuk', :poison)
      healer.send(:process_affliction_slot)

      task = healer.instance_variable_get(:@spell_task)
      expect(task[:phase]).to eq(:cure_self)
      expect(healer.get_patient('Tenuk')[:touched]).to be true
    end

    it 'removes patient when transfer returns not-found' do
      healer = build_healer
      healer.add_patient('Tenuk')

      allow(DRC).to receive(:bput)
        .with("transfer Tenuk quick poison", anything, anything)
        .and_return('What do you want to get')

      healer.claim_spell_slot('Tenuk', :poison)
      healer.send(:process_affliction_slot)

      expect(healer.patients).to be_empty
    end

    it 'releases slot when cure spell is already active' do
      healer = build_healer
      healer.add_patient('Tenuk')

      Harness::DRSpells._set_active_spells('Flush Poisons' => true)

      healer.claim_spell_slot('Tenuk', :poison)
      task = healer.instance_variable_get(:@spell_task)
      task[:phase] = :cure_self

      healer.send(:process_affliction_slot)

      expect(healer.instance_variable_get(:@spell_task)).to be_nil
    end
  end

  # ============================================================
  # Health Check / Self-Healing (Dependency Inversion: relies on DRCH interface)
  # ============================================================

  describe '#ready_to_heal_wounds?' do
    let(:healer) { build_healer }

    it 'returns true when healer is fully healthy' do
      allow(DRCH).to receive(:check_health).and_return(health_result)
      DRStats.health = 100

      expect(healer.ready_to_heal_wounds?).to be true
    end

    it 'returns false when healer has wounds' do
      wounded = health_result(
        wounds: { 2 => [wound(body_part: 'chest', severity: 2)] },
        score: 4
      )
      allow(DRCH).to receive(:check_health).and_return(wounded)
      DRStats.health = 100

      # Clear cached result
      healer.instance_variable_set(:@last_health_check, nil)
      expect(healer.ready_to_heal_wounds?).to be false
    end

    it 'returns false when healer vitality is below 70%' do
      allow(DRCH).to receive(:check_health).and_return(health_result)
      DRStats.health = 65

      healer.instance_variable_set(:@last_health_check, nil)
      expect(healer.ready_to_heal_wounds?).to be false
    end

    it 'returns false when healer is poisoned' do
      poisoned = health_result(poisoned: true)
      allow(DRCH).to receive(:check_health).and_return(poisoned)
      DRStats.health = 100

      healer.instance_variable_set(:@last_health_check, nil)
      expect(healer.ready_to_heal_wounds?).to be false
    end

    it 'throttles health checks to once per 10 seconds' do
      allow(DRCH).to receive(:check_health).and_return(health_result)
      DRStats.health = 100

      healer.ready_to_heal_wounds?
      expect(DRCH).to have_received(:check_health).once

      # Second call within 10s should use cached result
      healer.ready_to_heal_wounds?
      expect(DRCH).to have_received(:check_health).once
    end
  end

  # ============================================================
  # Spell Slot Timeout (Interface Segregation: timeout applies to all slot types)
  # ============================================================

  describe 'spell slot timeout' do
    it 'releases the spell slot when timeout is exceeded' do
      healer = build_healer
      healer.add_patient('Tenuk')
      DRRoom.pcs = ['Tenuk']

      healer.claim_spell_slot('Tenuk', :poison)

      # Simulate timeout by backdating the timer
      task = healer.instance_variable_get(:@spell_task)
      task[:timer] = Time.now - Healer::SPELL_SLOT_TIMEOUT - 1

      healer.send(:process_spell_slot)

      expect(healer.instance_variable_get(:@spell_task)).to be_nil
    end
  end

  # ============================================================
  # Patient Left Room During Processing
  # ============================================================

  describe 'patient leaves room' do
    it 'removes patient from queue when they leave during heal_patient' do
      healer = build_healer(friends: ['Tenuk'])
      healer.add_patient('Tenuk')
      DRRoom.pcs = [] # Tenuk left

      healer.send(:heal_patient, healer.get_patient('Tenuk'))

      expect(healer.patients).to be_empty
    end

    it 'releases spell slot when patient leaves during spell processing' do
      healer = build_healer
      healer.add_patient('Tenuk')

      healer.claim_spell_slot('Tenuk', :poison)
      DRRoom.pcs = [] # Tenuk left

      healer.send(:process_spell_slot)

      expect(healer.patients).to be_empty
      expect(healer.instance_variable_get(:@spell_task)).to be_nil
    end
  end

  # ============================================================
  # VH Waggle Validation
  # ============================================================

  describe '#validate_vh_spell' do
    it 'enables vitality healing when vh waggle_set is configured' do
      settings = {
        waggle_sets: {
          'vh' => {
            'Vitality Healing' => { 'mana' => 5, 'cambrinth' => [5], 'prep_time' => 3 }
          }
        }
      }
      $test_settings = OpenStruct.new(settings.merge(friends: [], healer_waggle_set: 'healme', cambrinth: nil))

      allow_any_instance_of(Healer).to receive(:validate_link_unity)
      allow_any_instance_of(Healer).to receive(:validate_healing_spells).and_return(false)

      healer = Healer.new

      expect(healer.instance_variable_get(:@vh_available)).to be true
      vh_spell = healer.instance_variable_get(:@vh_spell)
      expect(vh_spell[:name]).to eq('Vitality Healing')
      expect(vh_spell[:mana]).to eq(5)
    end

    it 'disables vitality healing when vh waggle_set is missing' do
      healer = build_healer

      # validate_vh_spell was stubbed to return false in build_healer
      expect(healer.instance_variable_get(:@vh_available)).to be false
    end
  end
end
