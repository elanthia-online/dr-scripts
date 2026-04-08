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

      it 'returns false when wound score is at or below threshold' do
        instance = build_instance(health_threshold: 10)
        # severity 1, 1 wound = 1^2 * 1 = 1 <= 10
        allow(DRCH).to receive(:check_health).and_return({
          'wounds'   => { 1 => ['right arm'] },
          'poisoned' => false
        })
        expect(instance.send(:need_healing?)).to be false
      end

      it 'calculates score as severity squared times wound count' do
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
  end

  # ---------------------------------------------------------------------------
  # use_pc_empath?
  # ---------------------------------------------------------------------------

  describe '#use_pc_empath?' do
    let(:empath) { { 'name' => 'Healer', 'id' => 123 } }

    context 'when empath has no id' do
      it 'returns false' do
        instance = build_instance
        expect(instance.send(:use_pc_empath?, { 'name' => 'Healer' })).to be false
      end
    end

    context 'when empath has no name' do
      it 'returns false' do
        instance = build_instance
        expect(instance.send(:use_pc_empath?, { 'id' => 123 })).to be false
      end
    end

    context 'when empath is not in room and no plant is present' do
      it 'returns false' do
        instance = build_instance
        DRRoom.pcs = []
        DRRoom.room_objs = []
        expect(instance.send(:use_pc_empath?, empath)).to be false
      end
    end

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

    context 'when empath is present and character needs healing' do
      before do
        DRRoom.pcs = ['Healer']
        DRRoom.room_objs = []
      end

      it 'whispers heal to the empath' do
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

      it 'breaks wait loop early when healing is no longer needed' do
        instance = build_instance
        call_count = 0
        allow(instance).to receive(:need_healing?) do
          call_count += 1
          call_count <= 1 # true for guard check, false in loop
        end

        instance.send(:use_pc_empath?, empath)

        # Guard (call 1: true) + loop (call 2: false, breaks) + final return (call 3: false)
        expect(call_count).to eq(3)
      end

      it 'uses custom done_healing_matches when configured' do
        instance = build_instance
        custom_empath = empath.merge('done_healing_matches' => ['Custom done message'])
        allow(instance).to receive(:need_healing?).and_return(true, true, false)

        # Simulate the empath responding with the custom message
        Flags.add('doneheal', 'Custom done message')
        Flags['doneheal'] = ['Custom done message']

        instance.send(:use_pc_empath?, custom_empath)

        sent = drain_sent_messages
        expect(sent).to include('whisper Healer heal')
      end
    end

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

    context 'with an already-capitalized empath name' do
      it 'matches the empath in DRRoom.pcs' do
        instance = build_instance
        DRRoom.pcs = ['Healer']
        empath = { 'name' => 'Healer', 'id' => 123 }

        allow(instance).to receive(:use_pc_empath?).and_return(true)
        allow(instance).to receive(:tip)
        allow(DRCM).to receive(:ensure_copper_on_hand)

        result = instance.send(:use_pc_empaths?, [empath], settings)
        expect(result).to be true
      end
    end

    context 'with a lowercase empath name' do
      it 'capitalizes the name and matches in DRRoom.pcs' do
        instance = build_instance
        DRRoom.pcs = ['Healer']
        empath = { 'name' => 'healer', 'id' => 123 }

        allow(instance).to receive(:use_pc_empath?).and_return(true)
        allow(instance).to receive(:tip)
        allow(DRCM).to receive(:ensure_copper_on_hand)

        result = instance.send(:use_pc_empaths?, [empath], settings)
        expect(result).to be true
      end
    end

    context 'when empath name does not match and is not in game' do
      it 'returns false' do
        instance = build_instance
        DRRoom.pcs = ['Otherperson']
        empath = { 'name' => 'Healer', 'id' => 123 }
        validator = instance.instance_variable_get(:@validator)
        allow(validator).to receive(:in_game?).with('Healer').and_return(false)

        result = instance.send(:use_pc_empaths?, [empath], settings)
        expect(result).to be false
      end
    end

    context 'when empath name is EV (case-insensitive)' do
      it 'matches regardless of DRRoom.pcs content' do
        instance = build_instance
        DRRoom.pcs = []
        empath = { 'name' => 'EV', 'id' => 456 }

        allow(instance).to receive(:use_pc_empath?).and_return(true)
        allow(instance).to receive(:tip)
        allow(DRCM).to receive(:ensure_copper_on_hand)

        result = instance.send(:use_pc_empaths?, [empath], settings)
        expect(result).to be true
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
  end

  # ---------------------------------------------------------------------------
  # stop_idle_activities
  # ---------------------------------------------------------------------------

  describe '#stop_idle_activities' do
    it 'stops performance when it was started by safe-room' do
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

    it 'stops tome when it was started by safe-room' do
      instance = build_instance(stop_tome_after_heal: true)
      $running_scripts = ['tome']

      instance.send(:stop_idle_activities)

      expect($stopped_scripts).to include('tome')
    end

    it 'does not stop tome when it was not started by safe-room' do
      instance = build_instance(stop_tome_after_heal: false)
      $running_scripts = ['tome']

      instance.send(:stop_idle_activities)

      expect($stopped_scripts).not_to include('tome')
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
  end
end
