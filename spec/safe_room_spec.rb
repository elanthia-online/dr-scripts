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

# Stub modules
module DRC
  class << self
    def bput(*_args); end
    def left_hand; end
    def right_hand; end
    def message(_msg); end
    def wait_for_script_to_complete(*_args); end
    def fix_standing; end
    def release_invisibility; end
    def beep; end
  end
end unless defined?(DRC)

module DRCI
  class << self
    def exists?(*_args); end
    def stow_hands; end
    def count_items_in_container(*_args); end
  end
end unless defined?(DRCI)

module DRCH
  class << self
    def check_health; end
  end
end unless defined?(DRCH)

module DRCT
  class << self
    def walk_to(_room_id); end
    def sort_destinations(_ids); end
  end
end unless defined?(DRCT)

module DRCM
  class << self
    def ensure_copper_on_hand(*_args); end
    def wealth(*_args); 0; end
    def minimize_coins(_amount); []; end
  end
end unless defined?(DRCM)

class CharacterValidator
  def initialize(*_args); end
  def in_game?(_name); false; end
end unless defined?(CharacterValidator)

class UserVars
  def self.safe_room_debug
    false
  end
end unless defined?(UserVars)

# Lich runtime stubs
$bleeding = false
$started_scripts = []
$stopped_scripts = []

def bleeding?
  $bleeding || false
end

def checkname
  'Testchar'
end

def start_script(name, *args)
  $started_scripts << [name, *args]
end

def stop_script(name)
  $stopped_scripts << name
end

load_lic_class('safe-room.lic', 'SafeRoom')

RSpec.describe SafeRoom do
  before(:each) do
    reset_data
    $bleeding = false
    $started_scripts = []
    $stopped_scripts = []
    allow(DRC).to receive(:bput).and_return('Roundtime')
    allow(DRC).to receive(:left_hand).and_return(nil)
    allow(DRC).to receive(:right_hand).and_return(nil)
    allow(DRC).to receive(:release_invisibility)
    allow(DRC).to receive(:fix_standing)
    allow(DRC).to receive(:beep)
    allow(DRCH).to receive(:check_health).and_return({ 'wounds' => {}, 'poisoned' => false })
    allow(DRCT).to receive(:walk_to)
    allow(DRCT).to receive(:sort_destinations) { |ids| ids }
  end

  def build_instance(**overrides)
    instance = SafeRoom.allocate
    defaults = {
      health_threshold: 0,
      performance_while_healing: false,
      stop_performance_after_heal: false,
      tome_while_healing: false,
      stop_tome_after_heal: false,
      plant_adjectives: [],
      plant_nouns: [],
      adjectives_regex: Regexp.union([]),
      noun_regex: Regexp.union([]),
      plant_regex: /(?!)/,
      validator: CharacterValidator.new
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  def drain_sent_messages
    messages = []
    messages << $sent_messages.pop until $sent_messages.empty?
    messages
  end

  # ---------------------------------------------------------------------------
  # need_healing?
  # ---------------------------------------------------------------------------

  describe '#need_healing?' do
    context 'when character has no wounds and is not bleeding' do
      it 'returns false' do
        instance = build_instance
        expect(instance.send(:need_healing?)).to be false
      end
    end

    context 'when character is bleeding' do
      it 'returns true regardless of wounds' do
        instance = build_instance
        $bleeding = true
        expect(instance.send(:need_healing?)).to be true
      end

      it 'short-circuits before wound scoring even when also poisoned and wounded' do
        instance = build_instance
        $bleeding = true
        allow(DRCH).to receive(:check_health).and_return({
          'wounds'   => { 3 => ['right arm', 'left leg'] },
          'poisoned' => true
        })
        # Should return true from the bleeding check, never reaching wound scoring
        expect(instance.send(:need_healing?)).to be true
      end
    end

    context 'when character is poisoned' do
      it 'returns true when Devour is not active' do
        instance = build_instance
        allow(DRCH).to receive(:check_health).and_return({ 'wounds' => {}, 'poisoned' => true })
        expect(instance.send(:need_healing?)).to be true
      end

      it 'returns false when Devour is active and no wounds present' do
        instance = build_instance
        allow(DRCH).to receive(:check_health).and_return({ 'wounds' => {}, 'poisoned' => true })
        DRSpells._set_active_spells({ 'Devour' => true })
        expect(instance.send(:need_healing?)).to be false
      end

      it 'falls through to wound scoring when Devour is active but wounds exist' do
        instance = build_instance(health_threshold: 0)
        allow(DRCH).to receive(:check_health).and_return({
          'wounds'   => { 2 => ['right arm'] },
          'poisoned' => true
        })
        DRSpells._set_active_spells({ 'Devour' => true })
        # Poison ignored (Devour active), falls to wound scoring: 4 > 0
        expect(instance.send(:need_healing?)).to be true
      end
    end

    context 'when character has wounds' do
      it 'returns true when wound score exceeds threshold' do
        instance = build_instance(health_threshold: 3)
        # severity 2, 1 wound = 2^2 * 1 = 4 > 3
        allow(DRCH).to receive(:check_health).and_return({
          'wounds'   => { 2 => ['right arm'] },
          'poisoned' => false
        })
        expect(instance.send(:need_healing?)).to be true
      end

      it 'returns false when wound score is below threshold' do
        instance = build_instance(health_threshold: 10)
        # severity 1, 1 wound = 1^2 * 1 = 1 < 10
        allow(DRCH).to receive(:check_health).and_return({
          'wounds'   => { 1 => ['right arm'] },
          'poisoned' => false
        })
        expect(instance.send(:need_healing?)).to be false
      end

      it 'returns false when wound score exactly equals threshold (boundary: > not >=)' do
        instance = build_instance(health_threshold: 4)
        # severity 2, 1 wound = 2^2 * 1 = 4, threshold 4, 4 > 4 is false
        allow(DRCH).to receive(:check_health).and_return({
          'wounds'   => { 2 => ['right arm'] },
          'poisoned' => false
        })
        expect(instance.send(:need_healing?)).to be false
      end

      it 'accumulates score across multiple wound severities' do
        instance = build_instance(health_threshold: 18)
        # severity 3 with 2 wounds = 9 * 2 = 18
        # severity 1 with 1 wound  = 1 * 1 = 1
        # total = 19 > 18
        allow(DRCH).to receive(:check_health).and_return({
          'wounds'   => { 3 => ['right arm', 'left leg'], 1 => ['head'] },
          'poisoned' => false
        })
        expect(instance.send(:need_healing?)).to be true
      end
    end

    context 'when health data is malformed' do
      it 'raises NoMethodError when wounds hash is nil' do
        instance = build_instance
        allow(DRCH).to receive(:check_health).and_return({ 'wounds' => nil, 'poisoned' => false })
        expect { instance.send(:need_healing?) }.to raise_error(NoMethodError)
      end

      it 'raises when health_threshold is nil and wounds exist' do
        instance = build_instance(health_threshold: nil)
        allow(DRCH).to receive(:check_health).and_return({
          'wounds'   => { 1 => ['head'] },
          'poisoned' => false
        })
        expect { instance.send(:need_healing?) }.to raise_error(ArgumentError)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # use_pc_empath?
  # ---------------------------------------------------------------------------

  describe '#use_pc_empath?' do
    let(:empath) { { 'name' => 'Healer', 'id' => 123 } }

    # -- guard clauses -------------------------------------------------------

    context 'guard clauses' do
      it 'returns false when empath has no id' do
        instance = build_instance
        expect(instance.send(:use_pc_empath?, { 'name' => 'Healer' })).to be false
      end

      it 'returns false when empath has no name' do
        instance = build_instance
        expect(instance.send(:use_pc_empath?, { 'id' => 123 })).to be false
      end

      it 'proceeds when empath id is 0 (0 is truthy in Ruby)' do
        instance = build_instance
        DRRoom.pcs = ['Healer']
        DRRoom.room_objs = []
        allow(instance).to receive(:need_healing?).and_return(false)

        result = instance.send(:use_pc_empath?, { 'name' => 'Healer', 'id' => 0 })
        expect(result).to be true
      end

      it 'proceeds when empath name is empty string (truthy but degenerate)' do
        instance = build_instance
        DRRoom.pcs = ['']
        DRRoom.room_objs = []
        allow(instance).to receive(:need_healing?).and_return(false)

        result = instance.send(:use_pc_empath?, { 'name' => '', 'id' => 123 })
        expect(result).to be true
      end
    end

    # -- empath not present --------------------------------------------------

    context 'when empath is not in room and no plant is present' do
      it 'returns false' do
        instance = build_instance
        DRRoom.pcs = []
        DRRoom.room_objs = []
        expect(instance.send(:use_pc_empath?, empath)).to be false
      end
    end

    # -- empath present, healthy character -----------------------------------

    context 'when empath is present and character does not need healing' do
      it 'returns true without requesting healing' do
        instance = build_instance
        DRRoom.pcs = ['Healer']
        DRRoom.room_objs = []
        allow(instance).to receive(:need_healing?).and_return(false)

        result = instance.send(:use_pc_empath?, empath)

        expect(result).to be true
        expect(drain_sent_messages).not_to include(a_string_matching(/whisper/))
      end
    end

    # -- empath present, character needs healing -----------------------------

    context 'when empath is present and character needs healing' do
      before do
        DRRoom.pcs = ['Healer']
        DRRoom.room_objs = []
      end

      it 'whispers heal and listens to the empath' do
        instance = build_instance
        allow(instance).to receive(:need_healing?).and_return(true, false, false)

        instance.send(:use_pc_empath?, empath)

        sent = drain_sent_messages
        expect(sent).to include('whisper Healer heal')
        expect(sent).to include('listen to Healer')
      end

      it 'uses custom start_heal_action when configured' do
        instance = build_instance
        custom_empath = empath.merge('start_heal_action' => 'say heal me please')
        allow(instance).to receive(:need_healing?).and_return(true, false, false)

        instance.send(:use_pc_empath?, custom_empath)

        sent = drain_sent_messages
        expect(sent).to include('say heal me please')
        expect(sent).not_to include(a_string_matching(/whisper/))
      end

      it 'uses custom done_healing_matches when configured' do
        instance = build_instance
        custom_empath = empath.merge('done_healing_matches' => ['Custom done message'])
        allow(instance).to receive(:need_healing?).and_return(true, false, false)

        instance.send(:use_pc_empath?, custom_empath)

        sent = drain_sent_messages
        expect(sent).to include('whisper Healer heal')
      end

      it 'uses default matchers when done_healing_matches is a non-Array truthy value' do
        instance = build_instance
        custom_empath = empath.merge('done_healing_matches' => 'not an array')
        allow(instance).to receive(:need_healing?).and_return(true, false, false)

        # Should not crash -- falls to else branch with defaults
        expect { instance.send(:use_pc_empath?, custom_empath) }.not_to raise_error
      end

      it 'runs full 24-iteration loop when done_healing_matches is empty array' do
        instance = build_instance
        custom_empath = empath.merge('done_healing_matches' => [])
        allow(instance).to receive(:need_healing?).and_return(true)

        pause_count = 0
        allow(instance).to receive(:pause) { pause_count += 1 }

        instance.send(:use_pc_empath?, custom_empath)

        # Empty array means no matchers -> flag can never fire -> full loop
        expect(pause_count).to eq(24)
      end

      it 'breaks wait loop early when healing is no longer needed' do
        instance = build_instance
        call_count = 0
        allow(instance).to receive(:need_healing?) do
          call_count += 1
          call_count <= 1 # true for guard check, false in loop
        end

        instance.send(:use_pc_empath?, empath)

        # Guard (1: true) + loop (2: false, breaks) + final return (3: false)
        expect(call_count).to eq(3)
      end

      it 'exits after 1 pause when doneheal fires on first iteration' do
        instance = build_instance
        allow(instance).to receive(:need_healing?).and_return(true)

        pause_count = 0
        allow(instance).to receive(:pause) do
          pause_count += 1
          # Simulate the empath responding during the first pause
          Flags['doneheal'] = true
        end

        instance.send(:use_pc_empath?, empath)

        expect(pause_count).to eq(1)
      end

      it 'returns false when all 24 iterations exhausted and still needs healing' do
        instance = build_instance
        allow(instance).to receive(:need_healing?).and_return(true)

        pause_count = 0
        allow(instance).to receive(:pause) { pause_count += 1 }

        result = instance.send(:use_pc_empath?, empath)

        expect(pause_count).to eq(24)
        expect(result).to be false
      end

      it 'returns false when healing regresses after loop exit' do
        instance = build_instance
        # Guard: true -> Loop: false (breaks) -> Final: true (!true = false)
        allow(instance).to receive(:need_healing?).and_return(true, false, true)

        result = instance.send(:use_pc_empath?, empath)

        expect(result).to be false
      end
    end

    # -- name comparison fix (empath['name'] not empath hash) ----------------

    context 'when empath is in the room and a healing plant is present' do
      it 'uses the PC empath branch instead of the plant branch' do
        instance = build_instance(
          plant_adjectives: ["vela'tohr"],
          plant_nouns: ['bloom'],
          adjectives_regex: /vela'tohr/,
          noun_regex: /bloom/,
          plant_regex: /vela'tohr bloom/
        )
        DRRoom.pcs = ['Healer']
        DRRoom.room_objs = ["a vela'tohr bloom"]
        allow(instance).to receive(:need_healing?).and_return(false)

        result = instance.send(:use_pc_empath?, empath)

        expect(result).to be true
        sent = drain_sent_messages
        expect(sent).not_to include(a_string_matching(/touch/))
      end
    end

    # -- plant path ----------------------------------------------------------

    context 'plant path' do
      let(:plant_instance) do
        build_instance(
          plant_adjectives: ["vela'tohr"],
          plant_nouns: ['bloom'],
          adjectives_regex: /vela'tohr/,
          noun_regex: /bloom/,
          plant_regex: /vela'tohr bloom/
        )
      end
      let(:absent_empath) { { 'name' => 'Absent', 'id' => 123 } }

      before do
        DRRoom.pcs = []
        DRRoom.room_objs = ["a vela'tohr bloom"]
      end

      it 'exits both loops when need_healing? returns false (prevents infinite re-touch)' do
        call_count = 0
        allow(plant_instance).to receive(:need_healing?) do
          call_count += 1
          call_count <= 2 # true for first 2 calls, false after
        end

        result = plant_instance.send(:use_pc_empath?, absent_empath)

        # Must terminate -- without the outer break, this would loop infinitely
        # touching the same plant over and over
        expect(result).to be true
        expect(call_count).to be < 10
      end

      it 'runs full 120-iteration inner loop when need_healing? stays true and doneheal never fires' do
        call_count = 0
        allow(plant_instance).to receive(:need_healing?) do
          call_count += 1
          # true for 120 inner loop calls, then false to break outer while
          call_count <= 120
        end

        pause_count = 0
        allow(plant_instance).to receive(:pause) { pause_count += 1 }

        result = plant_instance.send(:use_pc_empath?, absent_empath)

        # Inner loop ran all 120 iterations before need_healing? broke it
        expect(pause_count).to eq(120)
        # Method returned (outer loop exited via break unless need_healing?)
        expect(result).to be true
      end
    end
  end

  # ---------------------------------------------------------------------------
  # use_pc_empaths?
  # ---------------------------------------------------------------------------

  describe '#use_pc_empaths?' do
    let(:settings) do
      OpenStruct.new(
        safe_room_tip_threshold: nil,
        safe_room_tip_amount: nil,
        hometown: 'Crossing'
      )
    end

    context 'with an empty empath list' do
      it 'returns false' do
        instance = build_instance
        expect(instance.send(:use_pc_empaths?, [], settings)).to be false
      end
    end

    # -- name matching -------------------------------------------------------

    context 'name matching' do
      before do
        allow(DRCM).to receive(:ensure_copper_on_hand)
      end

      it 'matches already-capitalized name in DRRoom.pcs' do
        instance = build_instance
        DRRoom.pcs = ['Healer']
        empath = { 'name' => 'Healer', 'id' => 123 }
        allow(instance).to receive(:use_pc_empath?).and_return(true)
        allow(instance).to receive(:tip)

        expect(instance.send(:use_pc_empaths?, [empath], settings)).to be true
      end

      it 'capitalizes lowercase name and matches' do
        instance = build_instance
        DRRoom.pcs = ['Healer']
        empath = { 'name' => 'healer', 'id' => 123 }
        allow(instance).to receive(:use_pc_empath?).and_return(true)
        allow(instance).to receive(:tip)

        expect(instance.send(:use_pc_empaths?, [empath], settings)).to be true
      end

      it 'capitalizes all-caps name to proper case' do
        instance = build_instance
        DRRoom.pcs = ['Healer']
        empath = { 'name' => 'HEALER', 'id' => 123 }
        allow(instance).to receive(:use_pc_empath?).and_return(true)
        allow(instance).to receive(:tip)

        # 'HEALER'.capitalize -> 'Healer'
        expect(instance.send(:use_pc_empaths?, [empath], settings)).to be true
      end

      it 'does not mutate the original empath name in the hash' do
        instance = build_instance
        DRRoom.pcs = ['Healer']
        empath = { 'name' => 'healer', 'id' => 123 }
        allow(instance).to receive(:use_pc_empath?).and_return(true)
        allow(instance).to receive(:tip)

        instance.send(:use_pc_empaths?, [empath], settings)

        # capitalize (not capitalize!) should leave the original unchanged
        expect(empath['name']).to eq('healer')
      end

      it 'matches EV name case-insensitively (upcase check)' do
        instance = build_instance
        DRRoom.pcs = []
        empath = { 'name' => 'EV', 'id' => 456 }
        allow(instance).to receive(:use_pc_empath?).and_return(true)
        allow(instance).to receive(:tip)

        expect(instance.send(:use_pc_empaths?, [empath], settings)).to be true
      end

      it 'matches lowercase ev via upcase comparison' do
        instance = build_instance
        DRRoom.pcs = []
        empath = { 'name' => 'ev', 'id' => 456 }
        allow(instance).to receive(:use_pc_empath?).and_return(true)
        allow(instance).to receive(:tip)

        expect(instance.send(:use_pc_empaths?, [empath], settings)).to be true
      end
    end

    # -- empath not found ----------------------------------------------------

    context 'when empath is not in room or in game' do
      it 'returns false' do
        instance = build_instance
        DRRoom.pcs = ['Otherperson']
        empath = { 'name' => 'Healer', 'id' => 123 }
        validator = instance.instance_variable_get(:@validator)
        allow(validator).to receive(:in_game?).with('Healer').and_return(false)

        expect(instance.send(:use_pc_empaths?, [empath], settings)).to be false
      end

      it 'proceeds via in_game? when empath is not in current room' do
        instance = build_instance
        DRRoom.pcs = ['Otherperson']
        empath = { 'name' => 'Healer', 'id' => 123 }
        validator = instance.instance_variable_get(:@validator)
        allow(validator).to receive(:in_game?).with('Healer').and_return(true)
        allow(instance).to receive(:use_pc_empath?).and_return(true)
        allow(instance).to receive(:tip)
        allow(DRCM).to receive(:ensure_copper_on_hand)

        expect(instance.send(:use_pc_empaths?, [empath], settings)).to be true
      end
    end

    # -- multiple empaths ----------------------------------------------------

    context 'with multiple empaths' do
      before do
        allow(DRCM).to receive(:ensure_copper_on_hand)
      end

      it 'tries second empath when first is not in room or game' do
        instance = build_instance
        DRRoom.pcs = ['Second']
        validator = instance.instance_variable_get(:@validator)
        allow(validator).to receive(:in_game?).and_return(false)

        first = { 'name' => 'First', 'id' => 100 }
        second = { 'name' => 'Second', 'id' => 200 }
        allow(instance).to receive(:use_pc_empath?).and_return(true)
        allow(instance).to receive(:tip)

        result = instance.send(:use_pc_empaths?, [first, second], settings)
        expect(result).to be true
      end

      it 'tries second empath when first use_pc_empath? returns false' do
        instance = build_instance
        DRRoom.pcs = %w[First Second]
        validator = instance.instance_variable_get(:@validator)
        allow(validator).to receive(:in_game?).and_return(false)

        first = { 'name' => 'First', 'id' => 100 }
        second = { 'name' => 'Second', 'id' => 200 }

        call_count = 0
        allow(instance).to receive(:use_pc_empath?) do
          call_count += 1
          call_count > 1 # first fails, second succeeds
        end
        allow(instance).to receive(:tip)

        result = instance.send(:use_pc_empaths?, [first, second], settings)
        expect(result).to be true
        expect(call_count).to eq(2)
      end

      it 'returns false when all empaths fail' do
        instance = build_instance
        DRRoom.pcs = %w[First Second]
        validator = instance.instance_variable_get(:@validator)
        allow(validator).to receive(:in_game?).and_return(false)

        first = { 'name' => 'First', 'id' => 100 }
        second = { 'name' => 'Second', 'id' => 200 }
        allow(instance).to receive(:use_pc_empath?).and_return(false)

        expect(instance.send(:use_pc_empaths?, [first, second], settings)).to be false
      end
    end
  end

  # ---------------------------------------------------------------------------
  # start_idle_activities
  # ---------------------------------------------------------------------------

  describe '#start_idle_activities' do
    it 'starts performance when configured and not already running' do
      instance = build_instance(performance_while_healing: true)
      $running_scripts = []

      instance.send(:start_idle_activities)

      expect($started_scripts.map(&:first)).to include('performance')
      expect(instance.instance_variable_get(:@stop_performance_after_heal)).to be true
    end

    it 'does not start performance when already running' do
      instance = build_instance(performance_while_healing: true)
      $running_scripts = ['performance']

      instance.send(:start_idle_activities)

      expect($started_scripts.map(&:first)).not_to include('performance')
    end

    it 'does not start performance when play script is running' do
      instance = build_instance(performance_while_healing: true)
      $running_scripts = ['play']

      instance.send(:start_idle_activities)

      expect($started_scripts.map(&:first)).not_to include('performance')
    end

    it 'starts tome when configured and not already running' do
      instance = build_instance(tome_while_healing: true)
      $running_scripts = []

      instance.send(:start_idle_activities)

      expect($started_scripts.map(&:first)).to include('tome')
      expect(instance.instance_variable_get(:@stop_tome_after_heal)).to be true
    end

    it 'does not start scripts when not configured' do
      instance = build_instance
      $running_scripts = []

      instance.send(:start_idle_activities)

      expect($started_scripts).to be_empty
    end

    it 'starts both performance and tome when both configured' do
      instance = build_instance(performance_while_healing: true, tome_while_healing: true)
      $running_scripts = []

      instance.send(:start_idle_activities)

      names = $started_scripts.map(&:first)
      expect(names).to include('performance')
      expect(names).to include('tome')
    end

    it 'is idempotent when called twice (does not double-start running scripts)' do
      instance = build_instance(performance_while_healing: true, tome_while_healing: true)
      $running_scripts = []

      instance.send(:start_idle_activities)
      # Simulate that scripts are now running
      $running_scripts = %w[performance tome]
      instance.send(:start_idle_activities)

      # Should only have been started once each
      perf_starts = $started_scripts.count { |s| s.first == 'performance' }
      tome_starts = $started_scripts.count { |s| s.first == 'tome' }
      expect(perf_starts).to eq(1)
      expect(tome_starts).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # stop_idle_activities
  # ---------------------------------------------------------------------------

  describe '#stop_idle_activities' do
    it 'stops performance when it was started by safe-room and is running' do
      instance = build_instance(stop_performance_after_heal: true)
      $running_scripts = ['performance']

      instance.send(:stop_idle_activities)

      expect($stopped_scripts).to include('performance')
    end

    it 'does not stop performance when it was not started by safe-room' do
      instance = build_instance(stop_performance_after_heal: false)
      $running_scripts = ['performance']

      instance.send(:stop_idle_activities)

      expect($stopped_scripts).not_to include('performance')
    end

    it 'does not call stop_script when flagged but script is not running' do
      instance = build_instance(stop_performance_after_heal: true, stop_tome_after_heal: true)
      $running_scripts = []

      instance.send(:stop_idle_activities)

      expect($stopped_scripts).to be_empty
    end

    it 'stops both when both are flagged and running' do
      instance = build_instance(stop_performance_after_heal: true, stop_tome_after_heal: true)
      $running_scripts = %w[performance tome]

      instance.send(:stop_idle_activities)

      expect($stopped_scripts).to include('performance')
      expect($stopped_scripts).to include('tome')
    end

    it 'stops tome when it was started by safe-room and is running' do
      instance = build_instance(stop_tome_after_heal: true)
      $running_scripts = ['tome']

      instance.send(:stop_idle_activities)

      expect($stopped_scripts).to include('tome')
    end
  end

  # ---------------------------------------------------------------------------
  # give_and_take
  # ---------------------------------------------------------------------------

  describe '#give_and_take' do
    it 'returns nil when room_id is nil' do
      instance = build_instance
      expect(instance.send(:give_and_take, nil, ['gem'], ['sword'])).to be_nil
    end

    it 'returns nil when both give and take items are nil' do
      instance = build_instance
      expect(instance.send(:give_and_take, 123, nil, nil)).to be_nil
    end

    it 'handles nil give_items without crashing' do
      instance = build_instance
      DRRoom.room_objs = []
      expect { instance.send(:give_and_take, 123, nil, ['sword']) }.not_to raise_error
    end

    it 'handles nil take_items without crashing' do
      instance = build_instance
      expect { instance.send(:give_and_take, 123, ['gem'], nil) }.not_to raise_error
    end

    it 'handles empty array give_items without crashing' do
      instance = build_instance
      DRRoom.room_objs = []
      expect { instance.send(:give_and_take, 123, [], ['sword']) }.not_to raise_error
    end

    it 'handles empty array take_items without crashing' do
      instance = build_instance
      expect { instance.send(:give_and_take, 123, ['gem'], []) }.not_to raise_error
    end

    it 'walks to room even when both item lists are empty arrays' do
      instance = build_instance
      expect(DRCT).to receive(:walk_to).with(123)

      instance.send(:give_and_take, 123, [], [])
    end

    it 'only runs take when give_items is nil' do
      instance = build_instance
      DRRoom.room_objs = ['a sword']
      allow(DRC).to receive(:right_hand).and_return(nil)
      allow(DRC).to receive(:left_hand).and_return(nil)

      instance.send(:give_and_take, 123, nil, ['sword'])

      sent = drain_sent_messages
      expect(sent).to include('stow sword')
      expect(sent).not_to include(a_string_matching(/get my/))
    end
  end

  # ---------------------------------------------------------------------------
  # tip
  # ---------------------------------------------------------------------------

  describe '#tip' do
    it 'does not tip when wealth exactly equals threshold (boundary: > not >=)' do
      instance = build_instance
      allow(DRCM).to receive(:wealth).with('Crossing').and_return(100)
      allow(DRCM).to receive(:minimize_coins).and_return([50])

      instance.send(:tip, 100, 50, 'Healer', 'Crossing')

      sent = drain_sent_messages
      expect(sent).not_to include(a_string_matching(/give/))
    end

    it 'tips each denomination from minimize_coins' do
      instance = build_instance
      allow(DRCM).to receive(:wealth).with('Crossing').and_return(200)
      allow(DRCM).to receive(:minimize_coins).with(50).and_return([30, 20])

      instance.send(:tip, 100, 50, 'Healer', 'Crossing')

      sent = drain_sent_messages
      expect(sent).to include('give Healer 30')
      expect(sent).to include('give Healer 20')
    end

    it 'does not tip when tip_amount is nil' do
      instance = build_instance
      allow(DRCM).to receive(:wealth).with('Crossing').and_return(200)

      instance.send(:tip, 100, nil, 'Healer', 'Crossing')

      sent = drain_sent_messages
      expect(sent).not_to include(a_string_matching(/give/))
    end

    it 'does not tip when empath is nil' do
      instance = build_instance
      allow(DRCM).to receive(:wealth).with('Crossing').and_return(200)

      instance.send(:tip, 100, 50, nil, 'Crossing')

      sent = drain_sent_messages
      expect(sent).not_to include(a_string_matching(/give/))
    end
  end

  # ---------------------------------------------------------------------------
  # stow?
  # ---------------------------------------------------------------------------

  describe '#stow?' do
    it 'returns true without stowing when no room objects match' do
      instance = build_instance
      DRRoom.room_objs = ['a chair', 'a table']

      result = instance.send(:stow?, 'sword')

      expect(result).to be true
      expect(drain_sent_messages).to be_empty
    end

    it 'drops item and returns false when item is stuck in hand after stow' do
      instance = build_instance
      DRRoom.room_objs = ['a sword']
      allow(DRC).to receive(:right_hand).and_return('sword')
      allow(DRC).to receive(:left_hand).and_return(nil)

      result = instance.send(:stow?, 'sword')

      expect(result).to be false
      sent = drain_sent_messages
      expect(sent).to include('stow sword')
      expect(sent).to include('drop sword')
    end

    it 'matches substrings in room objects (documents regex footgun)' do
      instance = build_instance
      # 'ring' regex matches 'string' in 'a shimmering string of beads'
      DRRoom.room_objs = ['a shimmering string of beads']
      allow(DRC).to receive(:right_hand).and_return(nil)
      allow(DRC).to receive(:left_hand).and_return(nil)

      instance.send(:stow?, 'ring')

      sent = drain_sent_messages
      # BUG: /ring/ matches 'string', causing a false stow attempt
      expect(sent).to include('stow ring')
    end
  end

  # ---------------------------------------------------------------------------
  # take
  # ---------------------------------------------------------------------------

  describe '#take' do
    it 'stops processing remaining items when first stow? fails' do
      instance = build_instance
      DRRoom.room_objs = ['a sword', 'a shield']
      allow(DRC).to receive(:right_hand).and_return('sword')
      allow(DRC).to receive(:left_hand).and_return(nil)

      instance.send(:take, %w[sword shield])

      sent = drain_sent_messages
      # sword stow fails (stuck in hand) -> break, never tries shield
      expect(sent).to include('stow sword')
      expect(sent).not_to include('stow shield')
    end
  end

  # ---------------------------------------------------------------------------
  # give
  # ---------------------------------------------------------------------------

  describe '#give' do
    it 'handles empty items array without iterating' do
      instance = build_instance
      expect(DRC).not_to receive(:bput)

      instance.send(:give, [])
    end

    it 'breaks loop on unexpected bput response' do
      instance = build_instance
      allow(DRC).to receive(:bput).and_return('Something unexpected')

      instance.send(:give, ['gem'])

      sent = drain_sent_messages
      # Should not drop -- unknown response triggers else -> break
      expect(sent).not_to include(a_string_matching(/drop/))
    end
  end
end
