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

# Define stub modules only if not already defined
module DRC
  class << self
    def bput(*_args); end
    def left_hand; end
    def right_hand; end
    def message(_msg); end
    def wait_for_script_to_complete(*_args); end
    def fix_standing; end
    def release_invisibility; end

    def get_noun(item)
      item.to_s.split.last
    end
  end
end unless defined?(DRC)

module DRCI
  class << self
    def open_container?(*_args); end
    def get_box_list_in_container(_container); end
    def get_item?(*_args); end
    def get_item_if_not_held?(_item); end
    def put_away_item?(*_args); end
    def stow_hand(_hand); end
    def stow_hands; end
    def stow_item?(_item); end
    def in_hands?(_item); end
    def in_left_hand?(_item); end
    def in_right_hand?(_item); end
    def dispose_trash(*_args); end
    def count_lockpick_container(_container); end
    def get_item_list(*_args); end
    def lower_item?(_item); end
    def remove_item?(_item); end
    def wear_item?(_item); end
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
    def refill_lockpick_container(*_args); end
  end
end unless defined?(DRCT)

module DRCM
  class << self
    def ensure_copper_on_hand(*_args); end
  end
end unless defined?(DRCM)

module Lich
  module Messaging
    class << self
      def msg(*_args); end
    end
  end
end unless defined?(Lich::Messaging)

class EquipmentManager
  def empty_hands; end
  def remove_gear_by; end
  def wear_items(_items); end
  def wear_equipment_set?(_set_name); end
end unless defined?(EquipmentManager)

def sitting?
  false
end

def stunned?
  false
end

load_lic_class('pick.lic', 'Pick')

RSpec.describe Pick do
  # Shared test state
  let(:messages) { [] }
  let(:disposed_items) { [] }
  let(:refill_data) { {} }
  let(:copper_data) { {} }

  before(:each) do
    reset_data

    # Setup DRC stubs
    allow(DRC).to receive(:bput).and_return('Roundtime')
    allow(DRC).to receive(:left_hand).and_return(nil)
    allow(DRC).to receive(:right_hand).and_return(nil)
    allow(DRC).to receive(:message) { |msg| messages << msg }
    allow(DRC).to receive(:wait_for_script_to_complete)
    allow(DRC).to receive(:fix_standing)
    allow(DRC).to receive(:release_invisibility)
    allow(DRC).to receive(:get_noun) { |item| item.to_s.split.last }

    # Setup DRCI stubs
    allow(DRCI).to receive(:open_container?).and_return(true)
    allow(DRCI).to receive(:get_box_list_in_container).and_return([])
    allow(DRCI).to receive(:get_item?).and_return(true)
    allow(DRCI).to receive(:get_item_if_not_held?).and_return(true)
    allow(DRCI).to receive(:put_away_item?).and_return(true)
    allow(DRCI).to receive(:stow_hand).and_return(true)
    allow(DRCI).to receive(:stow_hands).and_return(true)
    allow(DRCI).to receive(:stow_item?).and_return(true)
    allow(DRCI).to receive(:in_hands?).and_return(true)
    allow(DRCI).to receive(:in_left_hand?).and_return(false)
    allow(DRCI).to receive(:in_right_hand?).and_return(false)
    allow(DRCI).to receive(:dispose_trash) { |item, *_| disposed_items << item }
    allow(DRCI).to receive(:count_lockpick_container).and_return(0)
    allow(DRCI).to receive(:get_item_list).and_return([])
    allow(DRCI).to receive(:lower_item?).and_return(true)
    allow(DRCI).to receive(:remove_item?).and_return(true)
    allow(DRCI).to receive(:wear_item?).and_return(true)

    # Setup DRCH stubs
    allow(DRCH).to receive(:check_health).and_return({
      'bleeders' => [], 'poisoned' => false,
                                                       'diseased' => false, 'score' => 0
    })

    # Setup DRCT stubs
    allow(DRCT).to receive(:walk_to).and_return(true)
    allow(DRCT).to receive(:refill_lockpick_container) do |type, town, container, count|
      refill_data[:type] = type
      refill_data[:town] = town
      refill_data[:container] = container
      refill_data[:count] = count
    end

    # Setup DRCM stubs
    allow(DRCM).to receive(:ensure_copper_on_hand) do |amount, _settings, town|
      copper_data[:amount] = amount
      copper_data[:town] = town
    end

    # Setup Lich::Messaging stub
    allow(Lich::Messaging).to receive(:msg)
  end

  # Helper: create a bare Pick instance without running initialize
  def build_instance(**overrides)
    instance = Pick.allocate
    # Set default ivars
    instance.instance_variable_set(:@settings, OpenStruct.new(
                                                 use_lockpick_ring: true,
                                                 lockpick_container: 'ring',
                                                 pick: {},
                                                 worn_trashcan: 'bucket',
                                                 worn_trashcan_verb: 'put',
                                                 gem_pouch_adjective: 'small',
                                                 gem_pouch_noun: 'pouch',
                                                 lootables: ['gem', 'coin'],
                                                 loot_specials: [],
                                                 fill_pouch_with_box: true,
                                                 saferoom_health_threshold: 50,
                                                 refill_town: 'Crossing',
                                                 hometown: 'Crossing',
                                                 lockpick_type: 'standard',
                                                 waggle_sets: {}
                                               ))
    instance.instance_variable_set(:@debug, false)
    instance.instance_variable_set(:@sources, ['backpack'])
    instance.instance_variable_set(:@use_lockpick_ring, true)
    instance.instance_variable_set(:@lockpick_container, 'ring')
    instance.instance_variable_set(:@worn_trashcan, 'bucket')
    instance.instance_variable_set(:@worn_trashcan_verb, 'put')
    instance.instance_variable_set(:@too_hard_container, 'sack')
    instance.instance_variable_set(:@blacklist_container, nil)
    instance.instance_variable_set(:@component_container, 'pouch')
    instance.instance_variable_set(:@max_identify_attempts, 5)
    instance.instance_variable_set(:@max_disarm_attempts, 5)
    instance.instance_variable_set(:@disarm_quick_threshold, 0)
    instance.instance_variable_set(:@disarm_normal_threshold, 2)
    instance.instance_variable_set(:@disarm_careful_threshold, 5)
    instance.instance_variable_set(:@disarm_too_hard_threshold, 10)
    instance.instance_variable_set(:@pick_quick_threshold, 2)
    instance.instance_variable_set(:@pick_normal_threshold, 4)
    instance.instance_variable_set(:@pick_careful_threshold, 7)
    instance.instance_variable_set(:@assumed_difficulty, nil)
    instance.instance_variable_set(:@trap_blacklist, [])
    instance.instance_variable_set(:@trap_greylist, [])
    instance.instance_variable_set(:@harvest_traps, false)
    instance.instance_variable_set(:@trash_empty_boxes, false)
    instance.instance_variable_set(:@dismantle_type, 'careful')
    instance.instance_variable_set(:@loot_nouns, ['gem', 'coin'])
    instance.instance_variable_set(:@trash_nouns, ['rock', 'pebble'])
    instance.instance_variable_set(:@trap_parts, ['wire', 'spring'])
    instance.instance_variable_set(:@picking_room_id, 1)
    instance.instance_variable_set(:@tend_own_wounds, false)
    instance.instance_variable_set(:@equipment_manager, EquipmentManager.new)

    # Data from picking.yaml
    instance.instance_variable_set(:@disarm_identify_messages, [
                                     'You have a completely trivial trap here',
                                     'You have an easy trap here',
                                     'You have a simple trap here'
                                   ])
    instance.instance_variable_set(:@disarm_identify_failed, ['not make head or tails'])
    instance.instance_variable_set(:@disarm_succeeded, ['You successfully disarm'])
    instance.instance_variable_set(:@disarm_retry, ['You are unable to make any progress'])
    instance.instance_variable_set(:@trap_sprung_matches, ['You hear a sudden click'])
    instance.instance_variable_set(:@disarm_lost_box_matches, ["You'll need to have the item"])
    instance.instance_variable_set(:@pick_identify_messages, ['easy lock', 'difficult lock'])
    instance.instance_variable_set(:@pick_retry, ['unable to make progress'])
    instance.instance_variable_set(:@all_trap_messages, { 'flame' => 'a flame trap' })
    instance.instance_variable_set(:@disarmed_trap_messages, { 'flame' => 'disarmed flame' })

    overrides.each { |k, v| instance.instance_variable_set(:"@#{k}", v) }
    instance
  end

  # ---------------------------------------------------------------------------
  # Default Settings
  # ---------------------------------------------------------------------------

  describe 'default settings' do
    it 'defaults max_identify_attempts to 5' do
      instance = build_instance
      expect(instance.instance_variable_get(:@max_identify_attempts)).to eq(5)
    end

    it 'defaults max_disarm_attempts to 5' do
      instance = build_instance
      expect(instance.instance_variable_get(:@max_disarm_attempts)).to eq(5)
    end
  end

  # ---------------------------------------------------------------------------
  # holding_box?
  # ---------------------------------------------------------------------------

  describe '#holding_box?' do
    it 'returns true when box is in hands' do
      instance = build_instance
      allow(DRCI).to receive(:in_hands?).with('strongbox').and_return(true)
      box = { 'noun' => 'strongbox' }
      expect(instance.send(:holding_box?, box)).to be true
    end

    it 'returns false when box is not in hands' do
      instance = build_instance
      allow(DRCI).to receive(:in_hands?).with('strongbox').and_return(false)
      box = { 'noun' => 'strongbox' }
      expect(instance.send(:holding_box?, box)).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # handle_trap_too_hard_or_blacklisted
  # ---------------------------------------------------------------------------

  describe '#handle_trap_too_hard_or_blacklisted' do
    it 'stows box in container when put succeeds' do
      instance = build_instance
      allow(DRCI).to receive(:put_away_item?).and_return(true)
      box = { 'noun' => 'strongbox' }

      instance.send(:handle_trap_too_hard_or_blacklisted, box, 'sack')

      expect(disposed_items).to be_empty
    end

    it 'disposes box when put fails' do
      instance = build_instance
      allow(DRCI).to receive(:put_away_item?).and_return(false)
      box = { 'noun' => 'strongbox' }

      instance.send(:handle_trap_too_hard_or_blacklisted, box, 'sack')

      expect(disposed_items).to include('strongbox')
      expect(messages.last).to include('Throwing away box')
    end

    it 'disposes box when no container set' do
      instance = build_instance
      box = { 'noun' => 'strongbox' }

      instance.send(:handle_trap_too_hard_or_blacklisted, box, nil)

      expect(disposed_items).to include('strongbox')
    end
  end

  # ---------------------------------------------------------------------------
  # dismantle (loop conversion test)
  # ---------------------------------------------------------------------------

  describe '#dismantle' do
    it 'retries on repeat request up to max attempts' do
      instance = build_instance
      box = { 'noun' => 'strongbox' }
      call_count = 0

      allow(DRC).to receive(:bput) do |*_args|
        call_count += 1
        'repeat this request in the next 15 seconds'
      end

      instance.send(:dismantle, box)

      expect(call_count).to eq(5)
      expect(disposed_items).to include('strongbox')
      expect(messages.last).to include('Failed to dismantle')
    end

    it 'succeeds on Roundtime response' do
      instance = build_instance
      box = { 'noun' => 'strongbox' }

      allow(DRC).to receive(:bput).and_return('Roundtime')

      instance.send(:dismantle, box)

      expect(disposed_items).to be_empty
    end

    it 'disposes box when cannot dismantle' do
      instance = build_instance
      box = { 'noun' => 'strongbox' }

      allow(DRC).to receive(:bput).and_return('You can not dismantle that')

      instance.send(:dismantle, box)

      expect(disposed_items).to include('strongbox')
    end
  end

  # ---------------------------------------------------------------------------
  # analyze_and_harvest (loop conversion test)
  # ---------------------------------------------------------------------------

  describe '#analyze_and_harvest' do
    it 'retries analyze on failure up to max attempts' do
      instance = build_instance
      box = { 'noun' => 'strongbox' }
      call_count = 0

      allow(DRC).to receive(:bput) do |*_args|
        call_count += 1
        'You are unable to determine a proper method'
      end

      instance.send(:analyze_and_harvest, box)

      expect(call_count).to eq(5)
      expect(messages.last).to include('Failed to analyze trap')
    end

    it 'proceeds to harvest on successful analyze' do
      instance = build_instance
      box = { 'noun' => 'strongbox' }
      analyze_called = false
      harvest_called = false

      allow(DRC).to receive(:bput) do |cmd, *_args|
        if cmd.include?('analyze')
          analyze_called = true
          'Roundtime'
        elsif cmd.include?('harvest')
          harvest_called = true
          'completely unsuitable for harvesting'
        end
      end

      instance.send(:analyze_and_harvest, box)

      expect(analyze_called).to be true
      expect(harvest_called).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # harvest (loop conversion test)
  # ---------------------------------------------------------------------------

  describe '#harvest' do
    it 'retries on fumble up to max attempts' do
      instance = build_instance
      box = { 'noun' => 'strongbox' }
      call_count = 0

      allow(DRC).to receive(:bput) do |*_args|
        call_count += 1
        'You fumble around with the trap apparatus'
      end

      instance.send(:harvest, box)

      expect(call_count).to eq(5)
      expect(messages.last).to include('Failed to harvest trap')
    end
  end

  # ---------------------------------------------------------------------------
  # loot (loop conversion test)
  # ---------------------------------------------------------------------------

  describe '#loot' do
    it 'exits loop when max loot rounds exceeded' do
      instance = build_instance
      loot_round = 0

      allow(DRC).to receive(:bput).and_return('That is already open')
      allow(DRCI).to receive(:get_item_list) do
        loot_round += 1
        ['some stuff']
      end

      instance.send(:loot, 'strongbox')

      expect(loot_round).to eq(10)
      expect(messages.last).to include('Exceeded max loot rounds')
    end

    it 'exits loop when no more stuff' do
      instance = build_instance
      call_count = 0

      allow(DRC).to receive(:bput).and_return('That is already open')
      allow(DRCI).to receive(:get_item_list) do
        call_count += 1
        call_count == 1 ? ['a gem'] : []
      end

      instance.send(:loot, 'strongbox')

      expect(call_count).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # loot_item (nil safety tests)
  # ---------------------------------------------------------------------------

  describe '#loot_item' do
    it 'skips fragments' do
      instance = build_instance
      expect(DRC).not_to receive(:bput)
      instance.send(:loot_item, 'fragment', 'strongbox')
    end

    it 'skips stuff' do
      instance = build_instance
      expect(DRC).not_to receive(:bput)
      instance.send(:loot_item, 'stuff', 'strongbox')
    end

    it 'handles coins correctly' do
      instance = build_instance
      allow(DRC).to receive(:bput).and_return('You pick up 5 gold kronars')

      result = instance.send(:loot_item, 'kronars', 'strongbox')

      expect(result).to be_nil
    end

    it 'handles failed get with message' do
      instance = build_instance
      allow(DRC).to receive(:bput).and_return('What were you referring')

      instance.send(:loot_item, 'gem', 'strongbox')

      expect(messages.last).to include('Could not get gem')
    end

    it 'handles nil item_long gracefully' do
      instance = build_instance
      allow(DRC).to receive(:bput).and_return('Some unexpected response')

      # Should not crash
      instance.send(:loot_item, 'gem', 'strongbox')
    end

    it 'disposes unrecognized items with message' do
      instance = build_instance(loot_nouns: [], trash_nouns: [])
      allow(DRC).to receive(:bput).and_return('You get a weird rock from inside')

      instance.send(:loot_item, 'rock', 'strongbox')

      expect(messages.last).to include('Unrecognized item')
      expect(disposed_items).to include('rock')
    end
  end

  # ---------------------------------------------------------------------------
  # refill_ring (@refill_town bug fix test)
  # ---------------------------------------------------------------------------

  describe '#refill_ring' do
    it 'uses settings.refill_town when available' do
      settings = OpenStruct.new(
        refill_town: 'Riverhaven',
        hometown: 'Crossing',
        lockpick_type: 'standard',
        skip_lockpick_ring_refill: false
      )
      instance = build_instance(settings: settings, use_lockpick_ring: true)
      instance.instance_variable_set(:@lockpick_costs, { 'standard' => 100 })
      allow(DRCI).to receive(:count_lockpick_container).and_return(20)

      instance.send(:refill_ring)

      expect(copper_data[:town]).to eq('Riverhaven')
      expect(refill_data[:town]).to eq('Riverhaven')
    end

    it 'falls back to hometown when refill_town not set' do
      settings = OpenStruct.new(
        refill_town: nil,
        fang_cove_override_town: nil,
        hometown: 'Crossing',
        lockpick_type: 'standard',
        skip_lockpick_ring_refill: false
      )
      instance = build_instance(settings: settings, use_lockpick_ring: true)
      instance.instance_variable_set(:@lockpick_costs, { 'standard' => 100 })
      allow(DRCI).to receive(:count_lockpick_container).and_return(20)

      instance.send(:refill_ring)

      expect(copper_data[:town]).to eq('Crossing')
      expect(refill_data[:town]).to eq('Crossing')
    end

    it 'skips refill when not using lockpick ring' do
      instance = build_instance(use_lockpick_ring: false)

      instance.send(:refill_ring)

      expect(refill_data).to be_empty
    end

    it 'skips refill when lockpick count is low' do
      instance = build_instance(use_lockpick_ring: true)
      allow(DRCI).to receive(:count_lockpick_container).and_return(5)

      instance.send(:refill_ring)

      expect(refill_data).to be_empty
    end

    it 'shows message for unknown lockpick type' do
      settings = OpenStruct.new(
        refill_town: 'Crossing',
        hometown: 'Crossing',
        lockpick_type: 'unknown_type',
        skip_lockpick_ring_refill: false
      )
      instance = build_instance(settings: settings, use_lockpick_ring: true)
      instance.instance_variable_set(:@lockpick_costs, { 'standard' => 100 })
      allow(DRCI).to receive(:count_lockpick_container).and_return(20)

      instance.send(:refill_ring)

      expect(messages.last).to include('Unknown lockpick type')
      expect(refill_data).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # stop_khris (hash iteration fix test)
  # ---------------------------------------------------------------------------

  describe '#stop_khris' do
    it 'iterates over hash keys correctly' do
      instance = build_instance
      spells = { 'focus' => { 'abbrev' => 'foc' }, 'vanish' => { 'abbrev' => 'van' } }
      commands = []

      allow(DRC).to receive(:bput) do |cmd, *_args|
        commands << cmd
        'You attempt to relax'
      end

      instance.send(:stop_khris, spells)

      expect(commands).to include('khri stop focus')
      expect(commands).to include('khri stop vanish')
      expect(commands.length).to eq(2)
    end
  end

  # ---------------------------------------------------------------------------
  # release_spells (hash iteration fix test)
  # ---------------------------------------------------------------------------

  describe '#release_spells' do
    it 'iterates over hash values and uses abbrev' do
      instance = build_instance
      spells = {
        'Protection from Evil' => { 'abbrev' => 'pfe' },
        'Bless'                => { 'abbrev' => 'bless' }
      }
      commands = []

      allow(DRC).to receive(:bput) do |cmd, *_args|
        commands << cmd
        'You release'
      end

      instance.send(:release_spells, spells)

      expect(commands).to include('release pfe')
      expect(commands).to include('release bless')
    end

    it 'skips spells without abbrev' do
      instance = build_instance
      spells = {
        'Protection from Evil' => { 'abbrev' => 'pfe' },
        'Some Other Spell'     => {}
      }
      commands = []

      allow(DRC).to receive(:bput) do |cmd, *_args|
        commands << cmd
        'You release'
      end

      instance.send(:release_spells, spells)

      expect(commands).to eq(['release pfe'])
    end
  end

  # ---------------------------------------------------------------------------
  # handle_trap_sprung
  # ---------------------------------------------------------------------------

  describe '#handle_trap_sprung' do
    it 'displays trap type when provided' do
      instance = build_instance

      instance.send(:handle_trap_sprung, 'flame')

      expect(messages).to include('Pick: **SPRUNG TRAP**')
      expect(messages).to include('Pick:   TRAP TYPE: flame')
    end

    it 'does not display trap type when nil' do
      instance = build_instance

      instance.send(:handle_trap_sprung, nil)

      expect(messages).to include('Pick: **SPRUNG TRAP**')
      trap_type_messages = messages.select { |m| m.include?('TRAP TYPE') }
      expect(trap_type_messages).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # dispose_empty_box
  # ---------------------------------------------------------------------------

  describe '#dispose_empty_box' do
    it 'trashes box when trash_empty_boxes is true' do
      instance = build_instance(trash_empty_boxes: true)
      box = { 'noun' => 'strongbox' }

      instance.send(:dispose_empty_box, box)

      expect(disposed_items).to include('strongbox')
    end

    it 'dismantles box when trash_empty_boxes is false' do
      instance = build_instance(trash_empty_boxes: false)
      box = { 'noun' => 'strongbox' }

      allow(DRC).to receive(:bput).and_return('Roundtime')

      instance.send(:dispose_empty_box, box)

      expect(disposed_items).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # swap_out_full_gempouch
  # ---------------------------------------------------------------------------

  describe '#swap_out_full_gempouch' do
    it 'shows message when spare_gem_pouch_container not set' do
      settings = OpenStruct.new(
        spare_gem_pouch_container: nil,
        gem_pouch_adjective: 'small',
        gem_pouch_noun: 'pouch'
      )
      instance = build_instance(settings: settings)

      instance.send(:swap_out_full_gempouch)

      expect(messages.last).to include('spare_gem_pouch_container not set')
    end
  end

  # ---------------------------------------------------------------------------
  # Identification failure behavior (proceed vs dispose)
  # ---------------------------------------------------------------------------

  describe 'identification failure behavior' do
    before(:each) do
      # Mock Flags module methods used by attempt_open flow
      allow(Flags).to receive(:reset)
      allow(Flags).to receive(:[]).and_return(nil)
    end

    it 'proceeds with careful disarm when trap identification fails' do
      instance = build_instance
      instance.instance_variable_get(:@disarm_careful_threshold)

      identify_count = 0
      in_hands_count = 0

      allow(DRCI).to receive(:in_hands?) do
        in_hands_count += 1
        # Return true for first 6 calls (entering loops and identify attempts), then false
        in_hands_count <= 6
      end

      allow(DRC).to receive(:bput) do |cmd, *_args|
        if cmd.include?('disarm') && cmd.include?('identify')
          identify_count += 1
          'not make head or tails'
        else
          'Roundtime'
        end
      end

      instance.send(:attempt_open, 'strongbox')

      expect(identify_count).to eq(5)
      expect(messages).to include('Pick: Failed to identify trap after 5 attempts. Proceeding with careful disarm.')
    end

    it 'proceeds with careful pick when lock identification fails' do
      instance = build_instance

      identify_count = 0
      in_hands_count = 0

      allow(DRCI).to receive(:in_hands?) do
        in_hands_count += 1
        # Return true for loops, then false after lock identify fails
        in_hands_count <= 8
      end

      allow(DRC).to receive(:bput) do |cmd, *_args|
        if cmd.include?('disarm') && cmd.include?('identify')
          # Trap identify succeeds (no trap)
          'disarmed flame'
        elsif cmd.include?('pick') && cmd.include?('ident')
          identify_count += 1
          'unable to make progress'
        else
          'Roundtime'
        end
      end

      instance.send(:attempt_open, 'strongbox')

      expect(identify_count).to eq(5)
      expect(messages).to include('Pick: Failed to identify lock after 5 attempts. Proceeding with careful pick.')
    end

    it 'disposes box when disarm attempts fail' do
      instance = build_instance

      disarm_count = 0

      allow(DRCI).to receive(:in_hands?).and_return(true)

      allow(DRC).to receive(:bput) do |cmd, *_args|
        if cmd.include?('disarm') && cmd.include?('identify')
          # Return a successful identify with difficulty 5 (careful)
          'You have a simple trap here'
        elsif cmd.include?('disarm') && !cmd.include?('identify')
          disarm_count += 1
          'You are unable to make any progress'
        else
          'Roundtime'
        end
      end

      instance.send(:attempt_open, 'strongbox')

      expect(disarm_count).to eq(5)
      expect(messages).to include('Pick: Failed to disarm trap after 5 attempts. Stowing box.')
    end

    it 'disposes box when pick attempts fail' do
      instance = build_instance

      pick_count = 0

      allow(DRCI).to receive(:in_hands?).and_return(true)

      allow(DRC).to receive(:bput) do |cmd, *_args|
        if cmd.include?('disarm')
          # Trap already disarmed
          'disarmed flame'
        elsif cmd.include?('pick') && cmd.include?('ident')
          # Lock identify succeeds with difficulty
          'easy lock'
        elsif cmd.include?('pick') && !cmd.include?('ident')
          pick_count += 1
          'You are unable to make any progress towards opening the lock'
        else
          'Roundtime'
        end
      end

      instance.send(:attempt_open, 'strongbox')

      expect(pick_count).to eq(5)
      expect(messages).to include('Pick: Failed to pick lock after 5 attempts. Stowing box.')
    end
  end

  # ---------------------------------------------------------------------------
  # Messaging prefix tests
  # ---------------------------------------------------------------------------

  describe 'messaging' do
    it 'uses Pick: prefix in failure messages' do
      instance = build_instance
      allow(DRCI).to receive(:put_away_item?).and_return(false)
      box = { 'noun' => 'strongbox' }

      instance.send(:handle_trap_too_hard_or_blacklisted, box, 'sack')

      expect(messages.last).to start_with('Pick:')
    end

    it 'uses Pick: prefix in refill_ring unknown type message' do
      settings = OpenStruct.new(
        refill_town: 'Crossing',
        hometown: 'Crossing',
        lockpick_type: 'unknown',
        skip_lockpick_ring_refill: false
      )
      instance = build_instance(settings: settings, use_lockpick_ring: true)
      instance.instance_variable_set(:@lockpick_costs, {})
      allow(DRCI).to receive(:count_lockpick_container).and_return(20)

      instance.send(:refill_ring)

      expect(messages.last).to start_with('Pick:')
    end
  end
end
