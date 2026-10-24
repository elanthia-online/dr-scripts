# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

# Minimal module stubs for modules not provided by the test harness
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

# Builds a scar-like object (cosmetic; scar? => true)
def scar(body_part:, severity: 1)
  OpenStruct.new(body_part: body_part, severity: severity, :scar? => true)
end

# ============================================================
# SPECS
# ============================================================

RSpec.describe Healer do
  before(:each) do
    reset_data
    $dead = false
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
        .with("whisper Tenuk You're dead -- get a cleric!", *Healer::WHISPER_RESPONSES)

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
  # Whisper Responses
  # ============================================================

  describe 'WHISPER_RESPONSES' do
    # Regression: the game replies "Whisper what to who?" when the target isn't a
    # valid recipient (e.g. the patient left between our room check and the whisper).
    # If no pattern matches it, DRC.bput blocks for its full timeout and spams
    # "No match found" before returning. See complete_healing / dead-patient whispers.
    it 'matches the "Whisper what to who?" failure so bput does not block on timeout' do
      expect(Healer::WHISPER_RESPONSES.any? { |p| p.match?('Whisper what to who?') }).to be true
    end

    it 'still matches a successful whisper' do
      expect(Healer::WHISPER_RESPONSES.any? { |p| p.match?('You whisper to Tenuk, "Done!"') }).to be true
    end

    it 'passes the whisper responses to bput when completing healing' do
      healer = build_healer(friends: ['Tenuk'])
      healer.add_patient('Tenuk')

      expect(DRC).to receive(:bput)
        .with('whisper Tenuk Done!', *Healer::WHISPER_RESPONSES)

      healer.send(:complete_healing, 'Tenuk')

      expect(healer.patients).to be_empty
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

    it 'does not exclude a part that only has a scar' do
      scarred = health_result(
        wounds: { 1 => [scar(body_part: 'left arm', severity: 1)] },
        score: 1
      )
      allow(DRCH).to receive(:check_health).and_return(scarred)

      result = healer.send(:available_heal_locations)
      expect(result).to include('left arm')
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

    it 'waits in recovering phase when health is between floor and resume threshold' do
      healer = build_healer
      healer.add_patient('Tenuk')

      healer.claim_spell_slot('Tenuk', :vitality)

      task = healer.instance_variable_get(:@spell_task)
      task[:phase] = :recovering
      task[:timer] = Time.now
      DRStats.health = 70 # between SELF_VIT_FLOOR (60) and VIT_RESUME_THRESHOLD (75)

      healer.send(:process_vitality_slot)

      task = healer.instance_variable_get(:@spell_task)
      expect(task[:phase]).to eq(:recovering)
    end

    it 'stacks multiple vit-transfer streams when own vitality is high' do
      healer = build_healer
      healer.add_patient('Tenuk')
      healer.instance_variable_set(:@vh_available, true)
      healer.instance_variable_set(:@vh_spell, { name: 'Vitality Healing', mana: 5, cambrinth: [], prep_time: 0 })
      DRStats.health = 100 # full headroom -> MAX_VIT_STACKS

      healer.claim_spell_slot('Tenuk', :vitality)
      task = healer.instance_variable_get(:@spell_task)
      task[:phase] = :prepping
      task[:prep_start] = Time.now - 5

      transfers = 0
      allow(DRC).to receive(:bput) do |cmd, *_|
        transfers += 1 if cmd == 'transfer Tenuk vit quick'
        ''
      end

      healer.send(:process_vitality_slot)

      expect(transfers).to eq(Healer::MAX_VIT_STACKS)
      expect(healer.instance_variable_get(:@spell_task)[:phase]).to eq(:awaiting_drain)
    end

    it 'uses a single vit-transfer stream when headroom is thin' do
      healer = build_healer
      healer.add_patient('Tenuk')
      healer.instance_variable_set(:@vh_available, true)
      healer.instance_variable_set(:@vh_spell, { name: 'Vitality Healing', mana: 5, cambrinth: [], prep_time: 0 })
      healer.instance_variable_set(:@self_vit_floor, 60)
      DRStats.health = 65 # just above the 60% floor -> thin headroom -> only 1 stream

      healer.claim_spell_slot('Tenuk', :vitality)
      task = healer.instance_variable_get(:@spell_task)
      task[:phase] = :prepping
      task[:prep_start] = Time.now - 5

      transfers = 0
      allow(DRC).to receive(:bput) do |cmd, *_|
        transfers += 1 if cmd == 'transfer Tenuk vit quick'
        ''
      end

      healer.send(:process_vitality_slot)

      expect(transfers).to eq(1)
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

    it 'stays ready when healer only has cosmetic scars' do
      scarred = health_result(
        wounds: { 2 => [scar(body_part: 'left arm', severity: 2)] },
        score: 4
      )
      allow(DRCH).to receive(:check_health).and_return(scarred)
      DRStats.health = 100

      healer.instance_variable_set(:@last_health_check, nil)
      expect(healer.ready_to_heal_wounds?).to be true
    end

    it 'stays ready when healer only has trivial severity-1 abrasions' do
      abraded = health_result(
        wounds: { 1 => [wound(body_part: 'left arm', severity: 1)] },
        score: 1
      )
      allow(DRCH).to receive(:check_health).and_return(abraded)
      DRStats.health = 100

      healer.instance_variable_set(:@last_health_check, nil)
      expect(healer.ready_to_heal_wounds?).to be true
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
  # Unity Recovery Tracking (skip Unity while it is still recovering)
  # ============================================================

  describe 'Unity recovery tracking' do
    let(:healer) { build_healer(friends: %w[Tenuk Navesi], unity: true) }
    let(:commands) { [] }
    let(:recovered_line) do
      'You sense that your system has fully recovered from your recent manifestation of the unity link.'
    end

    def wounded
      health_result(score: 9, wounds: { 2 => [wound(body_part: 'chest', severity: 2)] })
    end

    # Records every command; answers the Unity link with +link_reply+.
    def stub_game(link_reply)
      allow(DRC).to receive(:bput) do |cmd, *_|
        commands << cmd
        case cmd
        when /^link \w+ unity$/ then link_reply
        when /^redirect/ then 'You are now redirecting'
        when /^transfer/ then 'You feel the transfer beginning'
        else ''
        end
      end
      allow(healer).to receive(:heal_self)
    end

    def heal_new_patient(name)
      healer.add_patient(name)
      healer.send(:update_patient, name, needs_teach: false)
      DRRoom.pcs = [name]
      allow(DRCH).to receive(:perceive_health_other).with(name).and_return(wounded)
      healer.send(:heal_patient, healer.get_patient(name))
    end

    before do
      allow(DRCH).to receive(:check_health).and_return(health_result(wounds: {}))
    end

    # Lich's parser sets the flag when the game sends the recovery line.
    def announce_recovery
      Flags[Healer::UNITY_RECOVERED_FLAG] = recovered_line.match(Healer::UNITY_RECOVERED_PATTERN)
    end

    it 'registers a flag that matches the game line, XML and all' do
      healer
      matchers = Flags.matchers[Healer::UNITY_RECOVERED_FLAG]
      expect(matchers.any? { |m| m.match?("<pushBold/>#{recovered_line}<popBold/>") }).to be true
    end

    it 'assumes Unity is ready at startup' do
      expect(healer.send(:unity_ready?)).to be true
    end

    it 'does not try Unity again right after a successful Unity' do
      stub_game('Stretching your senses')
      heal_new_patient('Tenuk')
      commands.clear

      heal_new_patient('Navesi')

      expect(commands).to eq(['redirect all to left arm', 'transfer Navesi quick all'])
    end

    # A strain at startup means a recovery period we did not see start is running.
    it 'does not try Unity again after a strain' do
      stub_game('You strain')
      heal_new_patient('Tenuk')
      commands.clear

      heal_new_patient('Navesi')

      expect(commands).to eq(['redirect all to left arm', 'transfer Navesi quick all'])
    end

    it 'leaves the recovery state alone when the patient cannot be found' do
      stub_game('could not find')
      heal_new_patient('Tenuk')

      expect(healer.send(:unity_ready?)).to be true
    end

    it 'tries Unity again once the game announces recovery' do
      stub_game('Stretching your senses')
      heal_new_patient('Tenuk')
      commands.clear

      announce_recovery
      heal_new_patient('Navesi')

      expect(commands.first).to eq('link Navesi unity')
    end

    # Regression (race): the recovery line can arrive right behind a strain
    # (adjacent lines in logs), and Lich sets the flag before bput hands the
    # strain back. The strain must not re-arm a recovery that has already ended.
    it 'stays ready when the recovery line lands right behind a strain' do
      stub_game('You strain')
      allow(DRC).to receive(:bput).with('link Tenuk unity', any_args) do
        announce_recovery
        'You strain'
      end

      heal_new_patient('Tenuk')

      expect(healer.send(:unity_ready?)).to be true
    end

    # The flag is reset just before each link, so an old recovery line can't
    # cancel a strain.
    it 'still re-arms on a strain when the last recovery line came before the link was sent' do
      healer # register the flag first; Healer.new resets it
      announce_recovery
      stub_game('You strain')

      heal_new_patient('Tenuk')

      expect(healer.send(:unity_ready?)).to be false
    end

    # A success always starts a fresh period, even if an old period's recovery
    # line arrived while the link was in flight.
    it 'still starts a recovery period after a success, whatever arrived meanwhile' do
      stub_game('Stretching your senses')
      allow(DRC).to receive(:bput).with('link Tenuk unity', any_args) do
        announce_recovery
        'Stretching your senses'
      end

      heal_new_patient('Tenuk')

      expect(healer.send(:unity_ready?)).to be false
    end

    context 'when the recovery announcement is missed' do
      it 'stays recovering just short of the fallback' do
        healer.instance_variable_set(:@unity_recovering_since, Time.now - (Healer::UNITY_RECOVERY_FALLBACK_SECONDS - 1))
        expect(healer.send(:unity_ready?)).to be false
      end

      it 'assumes recovery at the fallback' do
        healer.instance_variable_set(:@unity_recovering_since, Time.now - Healer::UNITY_RECOVERY_FALLBACK_SECONDS)
        expect(healer.send(:unity_ready?)).to be true
      end
    end

    it 'never tracks recovery when Unity is unavailable' do
      healer.instance_variable_set(:@unity_available, false)
      stub_game('Stretching your senses')
      heal_new_patient('Tenuk')

      expect(commands).not_to include('link Tenuk unity')
      expect(healer.instance_variable_get(:@unity_recovering_since)).to be_nil
    end
  end

  # ============================================================
  # Unity Takes Wounds Instantly (no follow-up transfer)
  # ============================================================

  describe 'wound handling after a Unity link' do
    let(:healer) { build_healer(friends: ['Tenuk'], unity: true) }
    let(:chest_wounds) do
      health_result(score: 9, wounds: { 2 => [wound(body_part: 'chest', severity: 2)] })
    end
    let(:commands) { [] }

    # Records every command and answers the Unity link with +link_reply+.
    def stub_game(link_reply)
      allow(DRC).to receive(:bput) do |cmd, *_|
        commands << cmd
        case cmd
        when /^link \w+ unity$/ then link_reply
        when /^redirect/ then 'You are now redirecting'
        when /^transfer/ then 'You feel the transfer beginning'
        else ''
        end
      end
      allow(healer).to receive(:heal_self)
    end

    before do
      healer.add_patient('Tenuk')
      healer.send(:update_patient, 'Tenuk', needs_teach: false)
      # A readiness result cached earlier this cycle, from before Unity moved wounds onto us
      healer.instance_variable_set(:@last_health_check, Time.now)
      DRRoom.pcs = ['Tenuk']
      allow(DRCH).to receive(:check_health).and_return(health_result(wounds: {}))
      allow(DRCH).to receive(:perceive_health_other).with('Tenuk').and_return(chest_wounds)
    end

    context 'when the Unity link succeeds' do
      before do
        stub_game('Stretching your senses')
        healer.send(:heal_patient, healer.get_patient('Tenuk'))
      end

      # Regression: every successful Unity link was followed by a transfer that
      # always answered "Tenuk is not wounded in that location."
      it 'does not send a follow-up transfer or redirect' do
        expect(commands).to eq(['link Tenuk unity'])
      end

      it 'starts the cooldown and keeps the patient queued for a re-perceive' do
        expect(healer.patients).to have_key(:tenuk)
        expect(healer.get_patient('Tenuk')[:touched]).to be true
        expect(healer.patient_ready?('Tenuk')).to be false
      end

      it 'heals self, since the wounds are now ours' do
        expect(healer).to have_received(:heal_self)
      end

      it 'invalidates the cached readiness check' do
        expect(healer.instance_variable_get(:@last_health_check)).to be_nil
      end
    end

    context 'on the next cycle, when wounds remain after a Unity link' do
      before do
        stub_game('Stretching your senses')
        healer.send(:heal_patient, healer.get_patient('Tenuk'))
        healer.send(:update_patient, 'Tenuk', timer: Time.now - Healer::COOLDOWN_SECONDS)
        commands.clear
        healer.send(:heal_patient, healer.get_patient('Tenuk'))
      end

      # Regression: a lingering unity_linked flag made later transfers skip the
      # redirect, so wounds went wherever the last redirect happened to point.
      it 'redirects to an unwounded part before transferring' do
        expect(commands).to eq(['redirect all to left arm', 'transfer Tenuk quick all'])
      end
    end

    context 'when Unity is still recovering' do
      before do
        stub_game('You strain')
        healer.send(:heal_patient, healer.get_patient('Tenuk'))
      end

      it 'falls back to redirect and transfer' do
        expect(commands).to eq(['link Tenuk unity', 'redirect all to left arm', 'transfer Tenuk quick all'])
      end
    end

    context 'when the Unity link succeeds on a poisoned patient' do
      before do
        poisoned = health_result(score: 9, poisoned: true, wounds: { 2 => [wound(body_part: 'chest', severity: 2)] })
        allow(DRCH).to receive(:perceive_health_other).with('Tenuk').and_return(poisoned)
        stub_game('Stretching your senses')
        healer.send(:heal_patient, healer.get_patient('Tenuk'))
      end

      it 'still claims the spell slot for the poison' do
        expect(healer.instance_variable_get(:@spell_task)).to include(patient: 'Tenuk', type: :poison)
      end

      # Unity moved the wounds onto us even though the poison branch returns early,
      # so the next cycle must re-check our own health instead of reusing a stale "ready".
      it 'invalidates the cached readiness check' do
        expect(healer.instance_variable_get(:@last_health_check)).to be_nil
      end
    end
  end

  # ============================================================
  # Wound Transfer (redirect, then transfer)
  # ============================================================

  describe '#transfer_wounds' do
    it 'redirects to an unwounded body part before transferring' do
      healer = build_healer
      healer.add_patient('Tenuk')

      allow(DRCH).to receive(:check_health).and_return(health_result(wounds: {}))
      allow(DRC).to receive(:bput)
        .with(/redirect all to/, anything, anything)
        .and_return('You are now redirecting')
      allow(DRC).to receive(:bput)
        .with("transfer Tenuk quick all", *Healer::WOUND_TRANSFER_RESPONSES)
        .and_return('You touch')
      allow(healer).to receive(:heal_self)

      healer.send(:transfer_wounds, 'Tenuk', 5)

      expect(DRC).to have_received(:bput).with(/redirect all to/, anything, anything)
    end

    it 'heals self and returns when no unwounded parts are available' do
      healer = build_healer
      healer.add_patient('Tenuk')

      all_wounded = Healer::HEAL_LOCATIONS.map { |part| wound(body_part: part, severity: 2) }
      wounded_health = health_result(wounds: { 2 => all_wounded }, score: 99)
      allow(DRCH).to receive(:check_health).and_return(wounded_health)
      allow(healer).to receive(:heal_self)

      healer.send(:transfer_wounds, 'Tenuk', 5)

      expect(healer).to have_received(:heal_self)
      expect(DRC).not_to have_received(:bput).with(/transfer Tenuk/, any_args)
    end
  end

  # ============================================================
  # Wound Transfer Responses (match the line after the touch)
  # ============================================================

  describe 'WOUND_TRANSFER_RESPONSES' do
    # Verbatim game lines seen after "transfer <patient> quick all".
    started = 'You feel the transfer beginning as a cold stillness settles in the center of your being ' \
              'and you steel yourself for the impending explosion of pain.'
    active = 'You are already have an active transfer with Evro for that body part.'
    nothing = 'Tenuk is not wounded in that location.'
    no_link = 'You have no empathic link with Mahtra and cannot transfer his wounds.'
    not_found = 'What do you want to get?'

    def matching_patterns(line)
      Healer::WOUND_TRANSFER_RESPONSES.select { |pattern| pattern.match?(line) }
    end

    # Regression: the touch echo arrives before every outcome. Matching it made
    # bput report success before the "no empathic link" line was even read.
    it 'does not match the touch echo that precedes every outcome' do
      expect(matching_patterns('You touch Mahtra.')).to be_empty
    end

    it 'classifies a started transfer' do
      expect(matching_patterns(started)).to eq([Healer::WOUND_TRANSFER_STARTED_PATTERN])
    end

    it 'classifies an already-active transfer as started' do
      expect(matching_patterns(active)).to eq([Healer::WOUND_TRANSFER_STARTED_PATTERN])
    end

    it 'classifies a patient with nothing left to take' do
      expect(matching_patterns(nothing)).to eq([Healer::WOUND_TRANSFER_NOTHING_PATTERN])
    end

    it 'classifies a lapsed empathic link' do
      expect(matching_patterns(no_link)).to eq([Healer::WOUND_TRANSFER_NO_LINK_PATTERN])
    end

    it 'classifies a patient who is gone' do
      expect(matching_patterns(not_found)).to eq([Healer::TRANSFER_NOT_FOUND_PATTERN])
    end

    it 'leaves the shared spell-slot transfer responses unchanged' do
      expect(Healer::TRANSFER_RESPONSES).to eq([Healer::TRANSFER_SUCCESS_PATTERN, Healer::TRANSFER_NOT_FOUND_PATTERN])
    end
  end

  describe '#transfer_wounds outcome handling' do
    let(:healer) { build_healer }
    let(:stale_timer) { Time.now - 60 }

    before do
      healer.add_patient('Mahtra')
      healer.send(:update_patient, 'Mahtra', touched: true, timer: stale_timer)
      allow(DRCH).to receive(:check_health).and_return(health_result(wounds: {}))
      allow(DRC).to receive(:bput)
        .with(/redirect all to/, *Healer::REDIRECT_RESPONSES)
        .and_return('You are now redirecting')
      allow(healer).to receive(:heal_self)
    end

    def transfer_returns(response)
      allow(DRC).to receive(:bput)
        .with('transfer Mahtra quick all', *Healer::WOUND_TRANSFER_RESPONSES)
        .and_return(response)
      healer.send(:transfer_wounds, 'Mahtra', 5)
    end

    context 'when the empathic link has lapsed' do
      before { transfer_returns('You have no empathic link with') }

      it 'keeps the patient queued' do
        expect(healer.patients).to have_key(:mahtra)
      end

      it 'does not restart the cooldown, so the next cycle re-touches immediately' do
        expect(healer.get_patient('Mahtra')[:timer]).to eq(stale_timer)
        expect(healer.patient_ready?('Mahtra')).to be true
      end

      it 'does not heal self, since no wounds were taken' do
        expect(healer).not_to have_received(:heal_self)
      end
    end

    context 'when the patient was never touched before the link lapsed' do
      it 'leaves them ready for the next cycle' do
        healer.send(:update_patient, 'Mahtra', touched: false, timer: Time.now)
        transfer_returns('You have no empathic link with')

        expect(healer.patient_ready?('Mahtra')).to be true
      end
    end

    context 'when the transfer starts' do
      before { transfer_returns('You feel the transfer beginning') }

      it 'starts the cooldown and heals self' do
        expect(healer.get_patient('Mahtra')[:timer]).to be > stale_timer
        expect(healer.patient_ready?('Mahtra')).to be false
        expect(healer).to have_received(:heal_self)
      end
    end

    context 'when a transfer is already active for that body part' do
      before { transfer_returns('already have an active transfer with') }

      it 'treats it as started' do
        expect(healer.patient_ready?('Mahtra')).to be false
        expect(healer).to have_received(:heal_self)
      end
    end

    context 'when the patient has nothing left to take' do
      before { transfer_returns('is not wounded in that location') }

      it 'starts the cooldown so the next cycle re-perceives' do
        expect(healer.patient_ready?('Mahtra')).to be false
      end
    end

    context 'when the patient is gone' do
      before { transfer_returns('What do you want to get') }

      it 'removes the patient' do
        expect(healer.patients).to be_empty
      end
    end

    context 'when bput times out with no match' do
      before { transfer_returns('') }

      it 'falls back to the normal cooldown rather than retrying immediately' do
        expect(healer.patient_ready?('Mahtra')).to be false
      end
    end
  end

  # ============================================================
  # Passive Healing Timeout (skips timeout when Regenerate is active)
  # ============================================================

  describe '#wait_for_passive_healing' do
    it 'falls back to healme when timeout expires and Regenerate is not active' do
      healer = build_healer
      healer.instance_variable_set(:@passive_healing_available, true)

      wounded = health_result(score: 5, wounds: { 2 => [wound(body_part: 'chest', severity: 2)] })
      allow(DRCH).to receive(:check_health).and_return(wounded)
      allow(healer).to receive(:pause)
      Harness::DRSpells._set_active_spells({})

      expect(DRC).to receive(:wait_for_script_to_complete).with('healme')

      healer.send(:wait_for_passive_healing)
    end

    it 'does not fall back to healme when Regenerate is active' do
      healer = build_healer
      healer.instance_variable_set(:@passive_healing_available, true)

      call_count = 0
      allow(DRCH).to receive(:check_health) do
        call_count += 1
        if call_count <= (Healer::PASSIVE_HEAL_MAX_WAIT / Healer::PASSIVE_HEAL_POLL_INTERVAL) + 2
          health_result(score: 5, wounds: { 2 => [wound(body_part: 'chest', severity: 2)] })
        else
          health_result(score: 0, wounds: {})
        end
      end
      allow(healer).to receive(:pause)
      Harness::DRSpells._set_active_spells('Regenerate' => true)

      expect(DRC).not_to receive(:wait_for_script_to_complete).with('healme')

      healer.send(:wait_for_passive_healing)
    end
  end

  # ============================================================
  # Emergency Fall Resets Patients
  # ============================================================

  describe '#check_emergency_fall' do
    it 'resets all patients to untouched when emergency fall triggers' do
      healer = build_healer
      healer.add_patient('Tenuk')
      healer.add_patient('Navesi')
      healer.send(:update_patient, 'Tenuk', touched: true)
      healer.send(:update_patient, 'Navesi', touched: true)

      DRStats.health = 25 # Below EMERGENCY_VIT_THRESHOLD of 30

      healer.send(:check_emergency_fall)

      expect(healer.get_patient('Tenuk')[:touched]).to be false
      expect(healer.get_patient('Navesi')[:touched]).to be false
    end
  end

  # ============================================================
  # Self-Death Handling (idle while a ghost, resume on resurrection)
  # ============================================================

  describe 'self-death handling' do
    it 'idles instead of processing when the healer is dead' do
      healer = build_healer
      healer.add_patient('Tenuk')
      DRRoom.pcs = ['Tenuk']
      $dead = true

      expect(DRC).not_to receive(:fix_standing)

      healer.send(:process_queue)

      expect(healer.instance_variable_get(:@self_dead)).to be true
    end

    it 'skips self-VH prep spam while dead' do
      healer = build_healer
      healer.instance_variable_set(:@vh_available, true)
      healer.instance_variable_set(:@vh_spell, { name: 'Vitality Healing', mana: 5, cambrinth: [], prep_time: 3 })
      DRStats.health = 0
      $dead = true

      $sent_messages = []
      healer.send(:heal_self)

      expect($sent_messages).to be_empty
    end

    it 'clears self_dead and resumes after resurrection' do
      healer = build_healer
      healer.instance_variable_set(:@self_dead, true)
      $dead = false

      healer.send(:process_queue)

      expect(healer.instance_variable_get(:@self_dead)).to be false
    end
  end

  # ============================================================
  # Passive Heal Detection (recognizes Regenerate)
  # ============================================================

  describe '#validate_healing_spells' do
    it 'treats Regenerate as passive healing' do
      healer = build_healer
      allow(healer).to receive(:validate_healing_spells).and_call_original
      Harness::DRSpells._set_known_spells('Regenerate' => true)

      expect(healer.send(:validate_healing_spells)).to be true
    end

    it 'treats Heal + Adaptive Curing as passive healing' do
      healer = build_healer
      allow(healer).to receive(:validate_healing_spells).and_call_original
      Harness::DRSpells._set_known_spells('Heal' => true, 'Adaptive Curing' => true)

      expect(healer.send(:validate_healing_spells)).to be true
    end

    it 'falls back to healme without Regenerate or Heal + Adaptive Curing' do
      healer = build_healer
      allow(healer).to receive(:validate_healing_spells).and_call_original
      Harness::DRSpells._set_known_spells('Heal' => true)

      expect(healer.send(:validate_healing_spells)).to be false
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
