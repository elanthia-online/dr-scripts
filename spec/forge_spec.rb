# frozen_string_literal: true

require 'ostruct'
require 'time'

# Load test harness which provides mock game objects
load File.join(File.dirname(__FILE__), '..', 'test', 'test_harness.rb')
include Harness

# Helper to create a Flags stub for tests that need it
# Use stub_const to avoid conflicts with other specs (e.g., workorders_spec.rb)
def stub_flags_class
  stub_const('Flags', Class.new do
    @flags = {}

    class << self
      def []=(key, value)
        @flags ||= {}
        @flags[key] = value
      end

      def [](key)
        @flags ||= {}
        @flags[key]
      end

      def reset(key)
        @flags ||= {}
        @flags[key] = false
      end

      def add(key, *_matchers)
        @flags ||= {}
        @flags[key] = false
      end

      def delete(key)
        @flags ||= {}
        @flags.delete(key)
      end

      def _reset_all
        @flags = {}
      end
    end
  end)
end

# Extract and eval a class from a .lic file without executing top-level code
def load_lic_class(filename, class_name)
  return if Object.const_defined?(class_name)

  filepath = File.join(File.dirname(__FILE__), '..', filename)
  lines = File.readlines(filepath)

  start_idx = lines.index { |l| l =~ /^class\s+#{class_name}\b/ }
  raise "Could not find 'class #{class_name}' in #{filename}" unless start_idx

  # Find the matching 'end' at column 0 (same level as class definition)
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

# Minimal stub modules for game interaction
module DRC
  def self.right_hand
    $right_hand
  end

  def self.left_hand
    $left_hand
  end

  def self.bput(*_args)
    'Roundtime'
  end

  def self.message(*_args); end

  def self.wait_for_script_to_complete(*_args); end
end

module DRCC
  def self.stow_crafting_item(*_args)
    true
  end

  def self.get_crafting_item(*_args); end

  def self.get_adjust_tongs?(*_args)
    true
  end

  def self.find_grindstone(*_args); end

  def self.check_consumables(*_args); end

  def self.find_recipe2(*_args); end

  def self.logbook_item(*_args); end
end

module DRCI
  def self.in_hands?(*_args)
    false
  end

  def self.in_left_hand?(*_args)
    false
  end

  def self.in_right_hand?(*_args)
    false
  end

  def self.get_item?(*_args)
    true
  end

  def self.put_away_item?(*_args)
    true
  end

  def self.dispose_trash(*_args); end
end

module DRCA
  def self.crafting_magic_routine(*_args); end
end

module DRSkill
  def self.getrank(*_args)
    100
  end
end

# Lich messaging mock
module Lich
  module Messaging
    def self.msg(*_args); end
  end
end

# Load the Forge class
load_lic_class('forge.lic', 'Forge')

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end
end

RSpec.describe Forge do
  describe 'class constants' do
    it 'defines RENTAL_EXPIRE_PATTERN with named capture' do
      pattern = Forge::RENTAL_EXPIRE_PATTERN
      expect(pattern).to be_a(Regexp)
      match = 'It will expire Sun Dec 28 23:39:15 ET 2025.'.match(pattern)
      expect(match).not_to be_nil
      expect(match[:expire_time]).to eq('Sun Dec 28 23:39:15 ET 2025')
    end

    it 'defines RENTAL_NOT_FOUND_PATTERNS as frozen array' do
      expect(Forge::RENTAL_NOT_FOUND_PATTERNS).to be_frozen
      expect(Forge::RENTAL_NOT_FOUND_PATTERNS).to include('I could not find')
      expect(Forge::RENTAL_NOT_FOUND_PATTERNS).to include('What were you referring to')
    end

    it 'defines RENTAL_RENEW_SUCCESS_PATTERNS as frozen array' do
      expect(Forge::RENTAL_RENEW_SUCCESS_PATTERNS).to be_frozen
      expect(Forge::RENTAL_RENEW_SUCCESS_PATTERNS).to include('You mark the notice')
      expect(Forge::RENTAL_RENEW_SUCCESS_PATTERNS).to include('renewed your rental')
    end

    it 'defines RENTAL_RENEW_FAILURE_PATTERNS as frozen array' do
      expect(Forge::RENTAL_RENEW_FAILURE_PATTERNS).to be_frozen
      expect(Forge::RENTAL_RENEW_FAILURE_PATTERNS).to include("You don't have enough")
    end

    it 'defines TONGS_ERROR_PATTERNS as frozen array' do
      expect(Forge::TONGS_ERROR_PATTERNS).to be_frozen
      expect(Forge::TONGS_ERROR_PATTERNS).to include('You must be holding some metal tongs')
    end

    it 'defines FUEL_NEEDED_PATTERNS as frozen array' do
      expect(Forge::FUEL_NEEDED_PATTERNS).to be_frozen
      expect(Forge::FUEL_NEEDED_PATTERNS).to include('needs more fuel')
      expect(Forge::FUEL_NEEDED_PATTERNS).to include('Almost all of the coal has been consumed')
    end

    it 'defines BELLOWS_NEEDED_PATTERNS as frozen array' do
      expect(Forge::BELLOWS_NEEDED_PATTERNS).to be_frozen
      expect(Forge::BELLOWS_NEEDED_PATTERNS).to include('fire dims and produces less heat')
    end

    it 'defines TONGS_TURN_PATTERNS as frozen array' do
      expect(Forge::TONGS_TURN_PATTERNS).to be_frozen
      expect(Forge::TONGS_TURN_PATTERNS.length).to eq(6)
      expect(Forge::TONGS_TURN_PATTERNS).to include('straightening along the horn of the anvil')
    end

    it 'defines COOLING_PATTERNS as frozen array' do
      expect(Forge::COOLING_PATTERNS).to be_frozen
      expect(Forge::COOLING_PATTERNS).to include('in the slack tub')
      expect(Forge::COOLING_PATTERNS).to include('The metal is ready to be cooled')
    end

    it 'defines POUND_PATTERNS as frozen array' do
      expect(Forge::POUND_PATTERNS).to be_frozen
      expect(Forge::POUND_PATTERNS.length).to eq(6)
      expect(Forge::POUND_PATTERNS).to include('must be pounded free')
    end

    it 'defines GRINDSTONE_PATTERNS as frozen array' do
      expect(Forge::GRINDSTONE_PATTERNS).to be_frozen
      expect(Forge::GRINDSTONE_PATTERNS).to include('ready for grinding away of the excess metal')
      expect(Forge::GRINDSTONE_PATTERNS).to include('The armor is ready to be lightened')
    end

    it 'defines PLIERS_PATTERNS as frozen array' do
      expect(Forge::PLIERS_PATTERNS).to be_frozen
      expect(Forge::PLIERS_PATTERNS).to include('Some pliers are now required')
      expect(Forge::PLIERS_PATTERNS).to include('using pliers')
    end

    it 'defines OIL_PATTERNS as frozen array' do
      expect(Forge::OIL_PATTERNS).to be_frozen
      expect(Forge::OIL_PATTERNS).to include('in need of some oil to preserve')
      expect(Forge::OIL_PATTERNS).to include('metal will quickly rust')
    end

    it 'defines SPIN_SUCCESS_PATTERNS as frozen array' do
      expect(Forge::SPIN_SUCCESS_PATTERNS).to be_frozen
      expect(Forge::SPIN_SUCCESS_PATTERNS).to include('keeping it spinning fast')
    end

    it 'defines SPIN_FAILURE_PATTERNS as frozen array' do
      expect(Forge::SPIN_FAILURE_PATTERNS).to be_frozen
      expect(Forge::SPIN_FAILURE_PATTERNS).to include('not spinning fast enough')
    end

    it 'defines ASSEMBLE_SUCCESS_PATTERNS as frozen array' do
      expect(Forge::ASSEMBLE_SUCCESS_PATTERNS).to be_frozen
      expect(Forge::ASSEMBLE_SUCCESS_PATTERNS).to include('affix it securely in place')
    end

    it 'defines STAMP_PATTERNS as frozen array' do
      expect(Forge::STAMP_PATTERNS).to be_frozen
      expect(Forge::STAMP_PATTERNS).to include('carefully hammer the stamp')
    end

    it 'defines SWAP_PATTERNS as frozen array' do
      expect(Forge::SWAP_PATTERNS).to be_frozen
      expect(Forge::SWAP_PATTERNS).to include('You move')
    end

    it 'defines string constants for single patterns' do
      expect(Forge::TEMPER_START_PATTERN).to eq('You glance down at the hot coals of the forge')
      expect(Forge::TEMPER_CONTINUE_PATTERN).to eq('ensure even heating in the forge')
      expect(Forge::WIRE_BRUSH_PATTERN).to eq('The grinding has left many nicks and burs')
      expect(Forge::HANDLE_ASSEMBLY_PATTERN).to eq('now needs the handle assembled and pounded into place')
      expect(Forge::INGREDIENTS_PATTERN).to eq('Ingredients can be added')
      expect(Forge::INGOT_TOO_SMALL_PATTERN).to eq('You need a larger volume of metal')
      expect(Forge::ITEM_NOT_FOUND_PATTERN).to eq('I could not find what you were referring to')
      expect(Forge::OIL_EMPTY_PATTERN).to eq('Pour what')
      expect(Forge::FINAL_TOUCHES_PATTERN).to eq('Applying the final touches')
      expect(Forge::ROUNDTIME_PATTERN).to eq('Roundtime')
      expect(Forge::GRINDSTONE_SLOW_PATTERN).to eq('not spinning fast enough')
      expect(Forge::GET_SUCCESS_PATTERN).to eq('You get')
      expect(Forge::GET_FAILURE_PATTERN).to eq('What were you referring to?')
      expect(Forge::PUT_SUCCESS_PATTERN).to eq('You put')
      expect(Forge::ASSEMBLE_NOT_REQUIRED_PATTERN).to eq('is not required to continue crafting')
      expect(Forge::SPIN_MISSING_PATTERN).to eq('Turn what')
      expect(Forge::ANVIL_HAS_ITEM_PATTERN).to eq('anvil you see')
      expect(Forge::ANVIL_EMPTY_PATTERN).to eq('clean and ready')
      expect(Forge::FORGE_HAS_ITEM_PATTERN).to eq('forge you see')
      expect(Forge::FORGE_EMPTY_PATTERN).to eq('There is nothing')
    end
  end

  describe 'private methods' do
    let(:forge_instance) { Forge.allocate }

    before do
      forge_instance.instance_variable_set(:@debug, false)
      forge_instance.instance_variable_set(:@bag, 'backpack')
      forge_instance.instance_variable_set(:@forging_belt, nil)
      forge_instance.instance_variable_set(:@item, 'sword')
      forge_instance.instance_variable_set(:@hammer, 'forging hammer')
      forge_instance.instance_variable_set(:@adjustable_tongs, false)
      forge_instance.instance_variable_set(:@stamp, false)
      forge_instance.instance_variable_set(:@finish, 'hold')
      forge_instance.instance_variable_set(:@metal, 'steel')
      forge_instance.instance_variable_set(:@bag_items, [])
      forge_instance.instance_variable_set(:@hometown, 'Crossing')
      forge_instance.instance_variable_set(:@next_spin, Time.now - 100)
      forge_instance.instance_variable_set(:@info, { 'finisher-room' => 1, 'finisher-number' => 1 })
    end

    describe '#resolve_recipe_name' do
      it 'converts hone to metal weapon honing' do
        result = forge_instance.send(:resolve_recipe_name, 'hone')
        expect(result).to eq('metal weapon honing')
      end

      it 'converts balance to metal weapon balancing' do
        result = forge_instance.send(:resolve_recipe_name, 'balance')
        expect(result).to eq('metal weapon balancing')
      end

      it 'converts lighten to metal armor lightening' do
        result = forge_instance.send(:resolve_recipe_name, 'lighten')
        expect(result).to eq('metal armor lightening')
      end

      it 'converts reinforce to metal armor reinforcing' do
        result = forge_instance.send(:resolve_recipe_name, 'reinforce')
        expect(result).to eq('metal armor reinforcing')
      end

      it 'returns other recipe names unchanged' do
        result = forge_instance.send(:resolve_recipe_name, 'short sword')
        expect(result).to eq('short sword')
      end

      it 'returns nil for nil input' do
        result = forge_instance.send(:resolve_recipe_name, nil)
        expect(result).to be_nil
      end
    end

    describe '#debug_log' do
      it 'calls Lich::Messaging.msg when debug is true' do
        forge_instance.instance_variable_set(:@debug, true)
        expect(Lich::Messaging).to receive(:msg).with('plain', 'Forge: test message')
        forge_instance.send(:debug_log, 'test message')
      end

      it 'does not call Lich::Messaging.msg when debug is false' do
        forge_instance.instance_variable_set(:@debug, false)
        expect(Lich::Messaging).not_to receive(:msg)
        forge_instance.send(:debug_log, 'test message')
      end
    end

    describe '#error_log' do
      it 'calls Lich::Messaging.msg with bold styling' do
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: error message')
        forge_instance.send(:error_log, 'error message')
      end
    end

    describe '#check_rental_status' do
      before { stub_flags_class }

      it 'returns early when notice not found' do
        allow(DRC).to receive(:bput).and_return('I could not find')
        expect(forge_instance.send(:check_rental_status)).to be_nil
      end

      it 'parses expiration time with named capture' do
        expire_str = 'It will expire Sun Dec 28 23:39:15 ET 2025.'
        allow(DRC).to receive(:bput).and_return(expire_str)
        # Should not raise an error
        expect { forge_instance.send(:check_rental_status) }.not_to raise_error
      end

      it 'calls renew_forge_rental when minutes remaining < 10' do
        # Create a mock that simulates low rental time
        # The method parses the expiration string and calculates minutes remaining
        allow(DRC).to receive(:bput).and_return('It will expire Sun Dec 28 23:39:15 ET 2025.')
        # Stub Time.now to make the rental appear to expire soon
        allow(Time).to receive(:now).and_return(Time.parse('Sun Dec 28 23:35:00 -0500 2025'))
        allow(Time).to receive(:parse).and_call_original
        allow(forge_instance).to receive(:renew_forge_rental)
        forge_instance.send(:check_rental_status)
        expect(forge_instance).to have_received(:renew_forge_rental)
      end

      it 'logs warning when minutes remaining between 10 and 20' do
        # Create a mock that simulates moderate rental time (15 min remaining)
        allow(DRC).to receive(:bput).and_return('It will expire Sun Dec 28 23:39:15 ET 2025.')
        # Stub Time.now to make rental have ~15 minutes
        allow(Time).to receive(:now).and_return(Time.parse('Sun Dec 28 23:24:00 -0500 2025'))
        allow(Time).to receive(:parse).and_call_original
        allow(Lich::Messaging).to receive(:msg)
        forge_instance.send(:check_rental_status)
        expect(Lich::Messaging).to have_received(:msg).with('bold', /Forge: Rental has \d+ minutes remaining/)
      end

      it 'handles ArgumentError from time parsing' do
        forge_instance.instance_variable_set(:@debug, true)
        allow(DRC).to receive(:bput).and_return('It will expire invalid time format.')
        expect(Lich::Messaging).to receive(:msg).with('plain', /Could not parse rental time/)
        forge_instance.send(:check_rental_status)
      end
    end

    describe '#renew_forge_rental' do
      before do
        stub_flags_class
        Flags.add('forge-rental-warning', 'test')
        Flags['forge-rental-warning'] = true
      end

      it 'resets the forge-rental-warning flag' do
        allow(DRC).to receive(:bput).and_return('You mark the notice')
        forge_instance.send(:renew_forge_rental)
        expect(Flags['forge-rental-warning']).to eq(false)
      end

      it 'logs success message on renewal' do
        allow(DRC).to receive(:bput).and_return('You mark the notice')
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: FORGE RENTAL EXPIRING - AUTO-RENEWING')
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: RENTAL RENEWED')
        forge_instance.send(:renew_forge_rental)
      end

      it 'logs error when insufficient funds' do
        allow(DRC).to receive(:bput).and_return("You don't have enough")
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: FORGE RENTAL EXPIRING - AUTO-RENEWING')
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: INSUFFICIENT FUNDS TO RENEW RENTAL')
        forge_instance.send(:renew_forge_rental)
      end

      it 'logs error when notice not found' do
        allow(DRC).to receive(:bput).and_return('I could not find')
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: FORGE RENTAL EXPIRING - AUTO-RENEWING')
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: COULD NOT FIND NOTICE - CHECK LOCATION')
        forge_instance.send(:renew_forge_rental)
      end
    end

    describe '#find_item' do
      it 'sets up for enhancement when item in hands' do
        allow(DRCI).to receive(:in_hands?).with('sword').and_return(true)
        forge_instance.send(:find_item)
        expect(forge_instance.instance_variable_get(:@recipe_name)).to eq('metal weapon balancing')
        expect(forge_instance.instance_variable_get(:@command)).to eq('analyze my sword')
      end

      it 'sets up for anvil work when item on anvil' do
        allow(DRCI).to receive(:in_hands?).and_return(false)
        allow(DRC).to receive(:bput).with('look on anvil', anything, anything).and_return('anvil you see')
        forge_instance.send(:find_item)
        expect(forge_instance.instance_variable_get(:@recipe_name)).to eq('metal thing')
        expect(forge_instance.instance_variable_get(:@location)).to eq('on anvil')
      end

      it 'sets up for temper when item on forge' do
        allow(DRCI).to receive(:in_hands?).and_return(false)
        allow(DRC).to receive(:bput).with('look on anvil', anything, anything).and_return('clean and ready')
        allow(DRC).to receive(:bput).with('look on forge', anything, anything).and_return('forge you see')
        forge_instance.send(:find_item)
        expect(forge_instance.instance_variable_get(:@recipe_name)).to eq('temper')
        expect(forge_instance.instance_variable_get(:@home_tool)).to eq('tongs')
        expect(forge_instance.instance_variable_get(:@location)).to eq('on forge')
      end

      it 'exits with error when item not found' do
        allow(DRCI).to receive(:in_hands?).and_return(false)
        allow(DRC).to receive(:bput).with('look on anvil', anything, anything).and_return('clean and ready')
        allow(DRC).to receive(:bput).with('look on forge', anything, anything).and_return('There is nothing')
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: sword not found on anvil, forge, or in hands. Exiting.')
        expect { forge_instance.send(:find_item) }.to raise_error(SystemExit)
      end
    end

    describe '#restow_ingot' do
      before do
        stub_flags_class
        Flags.add('ingot-restow', /pattern/)
        Flags['ingot-restow'] = ['full match', 'pouch.']
      end

      it 'returns early if temp_bag matches @bag' do
        forge_instance.instance_variable_set(:@bag, 'pouch')
        $right_hand = 'hammer'
        expect(DRCI).not_to receive(:get_item?)
        forge_instance.send(:restow_ingot)
      end

      it 'moves ingot from temp_bag to main bag' do
        forge_instance.instance_variable_set(:@bag, 'backpack')
        $right_hand = 'hammer'
        expect(DRCI).to receive(:get_item?).with('steel ingot', 'pouch').and_return(true)
        expect(DRCI).to receive(:put_away_item?).with('steel ingot', 'backpack').and_return(true)
        allow(DRCC).to receive(:stow_crafting_item)
        allow(forge_instance).to receive(:swap_tool)
        forge_instance.send(:restow_ingot)
      end

      it 'logs error when put_away fails' do
        forge_instance.instance_variable_set(:@bag, 'backpack')
        $right_hand = nil
        expect(DRCI).to receive(:get_item?).with('steel ingot', 'pouch').and_return(true)
        expect(DRCI).to receive(:put_away_item?).with('steel ingot', 'backpack').and_return(false)
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: Failed to stow steel ingot in backpack.')
        forge_instance.send(:restow_ingot)
      end
    end

    describe '#handle_fuel_needed' do
      it 'uses tongs when adjustable_tongs is true' do
        forge_instance.instance_variable_set(:@adjustable_tongs, true)
        expect(forge_instance).to receive(:swap_tool).with('shovel')
        forge_instance.send(:handle_fuel_needed)
        expect(forge_instance.instance_variable_get(:@command)).to eq('push fuel with my tongs')
      end

      it 'uses shovel when adjustable_tongs is false' do
        forge_instance.instance_variable_set(:@adjustable_tongs, false)
        expect(forge_instance).to receive(:swap_tool).with('shovel')
        forge_instance.send(:handle_fuel_needed)
        expect(forge_instance.instance_variable_get(:@command)).to eq('push fuel with my shovel')
      end
    end

    describe '#handle_pounding' do
      it 'puts item on anvil if in hands' do
        allow(DRCI).to receive(:in_hands?).with('sword').and_return(true)
        expect(DRC).to receive(:bput).with('put my sword on anvil', 'You put')
        expect(forge_instance).to receive(:swap_tool).with('forging hammer')
        expect(forge_instance).to receive(:swap_tool).with('tongs')
        forge_instance.send(:handle_pounding)
        expect(forge_instance.instance_variable_get(:@command)).to eq('pound sword on anvil with my forging hammer')
      end

      it 'skips put if item not in hands' do
        allow(DRCI).to receive(:in_hands?).with('sword').and_return(false)
        expect(DRC).not_to receive(:bput).with('put my sword on anvil', anything)
        expect(forge_instance).to receive(:swap_tool).with('forging hammer')
        expect(forge_instance).to receive(:swap_tool).with('tongs')
        forge_instance.send(:handle_pounding)
      end
    end

    describe '#handle_grindstone' do
      it 'gets item from anvil when not in left hand' do
        forge_instance.instance_variable_set(:@resume, false)
        allow(DRCI).to receive(:in_left_hand?).and_return(false)
        allow(DRCI).to receive(:in_hands?).and_return(false)
        expect(DRC).to receive(:bput).with('get sword from anvil', 'You get', 'What were you referring to?').and_return('You get')
        expect(forge_instance).to receive(:check_hand).with('sword')
        forge_instance.send(:handle_grindstone)
        expect(forge_instance.instance_variable_get(:@command)).to eq('push grindstone with my sword')
      end

      it 'logs error when get fails' do
        allow(DRCI).to receive(:in_left_hand?).and_return(false)
        allow(DRCI).to receive(:in_hands?).and_return(false)
        expect(DRC).to receive(:bput).and_return('What were you referring to?')
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: Failed to get sword from anvil for grindstone work.')
        expect(forge_instance).to receive(:check_hand).with('sword')
        forge_instance.send(:handle_grindstone)
      end

      it 'sets home_tool to wire brush when resuming' do
        forge_instance.instance_variable_set(:@resume, true)
        allow(DRCI).to receive(:in_left_hand?).and_return(true)
        forge_instance.send(:handle_grindstone)
        expect(forge_instance.instance_variable_get(:@home_tool)).to eq('wire brush')
      end
    end

    describe '#handle_pliers' do
      it 'gets item from anvil when not in left hand' do
        allow(DRCI).to receive(:in_left_hand?).and_return(false)
        allow(DRCI).to receive(:in_hands?).and_return(false)
        expect(DRC).to receive(:bput).with('get sword from anvil', 'You get', 'What were you referring to?').and_return('You get')
        expect(forge_instance).to receive(:check_hand).with('sword')
        expect(forge_instance).to receive(:swap_tool).with('pliers')
        forge_instance.send(:handle_pliers)
        expect(forge_instance.instance_variable_get(:@command)).to eq('pull my sword with my pliers')
      end
    end

    describe '#handle_oiling' do
      before do
        forge_instance.instance_variable_set(:@location, 'on anvil')
        forge_instance.instance_variable_set(:@home_tool, 'hammer')
      end

      it 'gets item when not in left hand' do
        allow(DRCI).to receive(:in_left_hand?).and_return(false)
        expect(DRCC).to receive(:stow_crafting_item)
        expect(DRC).to receive(:bput).with('get sword on anvil', 'You get', 'What were you referring to?').and_return('You get')
        expect(forge_instance).to receive(:check_hand).with('sword')
        expect(forge_instance).to receive(:swap_tool).with('oil', true)
        forge_instance.send(:handle_oiling)
        expect(forge_instance.instance_variable_get(:@command)).to eq('pour my oil on my sword')
      end

      it 'always gets item when home_tool is tongs (temper)' do
        forge_instance.instance_variable_set(:@home_tool, 'tongs')
        forge_instance.instance_variable_set(:@location, 'on forge')
        # When home_tool is tongs, it always enters the get block
        # After getting item, it should be in left hand
        allow(DRCI).to receive(:in_left_hand?).with('sword').and_return(true) # Item is in left hand after get
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRC).to receive(:bput).with('get sword on forge', anything, anything).and_return('You get')
        allow(forge_instance).to receive(:swap_tool)
        forge_instance.send(:handle_oiling)
        expect(forge_instance.instance_variable_get(:@command)).to eq('pour my oil on my sword')
        expect(forge_instance).to have_received(:swap_tool).with('oil', true)
      end
    end

    describe '#handle_handle_assembly' do
      it 'gets item, assembles, puts back, and sets up pounding' do
        expect(DRC).to receive(:bput).with('get sword from anvil', 'You get', 'What were you referring to?').and_return('You get')
        expect(forge_instance).to receive(:check_hand).with('sword')
        expect(forge_instance).to receive(:assemble_part)
        expect(DRC).to receive(:bput).with('put my sword on anvil', 'You put')
        expect(forge_instance).to receive(:swap_tool).with('forging hammer')
        expect(forge_instance).to receive(:swap_tool).with('tongs')
        forge_instance.send(:handle_handle_assembly)
        expect(forge_instance.instance_variable_get(:@command)).to eq('pound sword on anvil with my forging hammer')
      end
    end

    describe '#handle_roundtime' do
      before do
        stub_flags_class
        Flags.add('work-done', 'pattern')
        forge_instance.instance_variable_set(:@home_tool, 'forging hammer')
        forge_instance.instance_variable_set(:@home_command, 'pound sword on anvil with my forging hammer')
      end

      it 'calls finish when work-done flag is set' do
        Flags['work-done'] = true
        expect(forge_instance).to receive(:waitrt?)
        expect(forge_instance).to receive(:finish)
        expect(forge_instance).to receive(:swap_tool).with('forging hammer')
        forge_instance.send(:handle_roundtime)
      end

      it 'swaps to home tool and sets home command' do
        Flags['work-done'] = false
        expect(forge_instance).to receive(:waitrt?)
        expect(forge_instance).to receive(:swap_tool).with('forging hammer')
        forge_instance.send(:handle_roundtime)
        expect(forge_instance.instance_variable_get(:@command)).to eq('pound sword on anvil with my forging hammer')
      end

      it 'adjusts tongs when home_tool is hammer' do
        Flags['work-done'] = false
        forge_instance.instance_variable_set(:@home_tool, 'forging hammer')
        forge_instance.instance_variable_set(:@hammer, 'forging hammer')
        expect(forge_instance).to receive(:waitrt?)
        expect(forge_instance).to receive(:swap_tool)
        expect(DRCC).to receive(:get_adjust_tongs?).with('tongs', 'backpack', [], nil, false)
        forge_instance.send(:handle_roundtime)
      end
    end

    describe '#assemble_part' do
      before do
        stub_flags_class
        Flags.add('forge-assembly', 'pattern')
      end

      it 'does nothing when flag is not set' do
        Flags['forge-assembly'] = false
        expect(DRCI).not_to receive(:get_item?)
        forge_instance.send(:assemble_part)
      end

      it 'gets part and assembles when flag is set' do
        Flags['forge-assembly'] = ['full match', 'leather', 'cord']
        $right_hand = 'tongs'
        allow(DRCI).to receive(:get_item?).with('leather cord').and_return(true)
        expect(DRC).to receive(:bput).with('assemble my sword with my leather cord', *Forge::ASSEMBLE_SUCCESS_PATTERNS, Forge::ASSEMBLE_NOT_REQUIRED_PATTERN).and_return('affix it securely in place')
        expect(forge_instance).to receive(:swap_tool).with('tongs')
        forge_instance.send(:assemble_part)
      end

      it 'stows part when not required' do
        Flags['forge-assembly'] = ['full match', 'leather', 'strips']
        $right_hand = nil
        allow(DRCI).to receive(:get_item?).with('leather strips').and_return(true)
        expect(DRC).to receive(:bput).and_return('is not required to continue crafting')
        expect(DRCI).to receive(:put_away_item?).with('leather strips', 'backpack')
        forge_instance.send(:assemble_part)
      end

      it 'exits with error when part not found' do
        Flags['forge-assembly'] = ['full match', 'wooden', 'hilt']
        $right_hand = nil
        allow(DRCI).to receive(:get_item?).with('wooden hilt').and_return(false)
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: Missing wooden hilt. Cannot continue assembly. Exiting.')
        expect(forge_instance).to receive(:magic_cleanup)
        expect { forge_instance.send(:assemble_part) }.to raise_error(SystemExit)
      end
    end

    describe '#spin_grindstone' do
      it 'returns immediately if next_spin is in the future' do
        forge_instance.instance_variable_set(:@next_spin, Time.now + 100)
        expect(DRC).not_to receive(:bput)
        forge_instance.send(:spin_grindstone)
      end

      it 'spins and sets next_spin on success' do
        forge_instance.instance_variable_set(:@next_spin, Time.now - 100)
        expect(DRC).to receive(:bput).with('turn grind', *Forge::SPIN_SUCCESS_PATTERNS, *Forge::SPIN_FAILURE_PATTERNS, Forge::SPIN_MISSING_PATTERN).and_return('keeping it spinning fast')
        forge_instance.send(:spin_grindstone)
        expect(forge_instance.instance_variable_get(:@next_spin)).to be > Time.now
      end

      it 'finds grindstone when Turn what returned' do
        forge_instance.instance_variable_set(:@next_spin, Time.now - 100)
        expect(DRC).to receive(:bput).and_return('Turn what', 'keeping it spinning fast')
        expect(DRCC).to receive(:find_grindstone).with('Crossing')
        forge_instance.send(:spin_grindstone)
      end
    end

    describe '#swap_tool' do
      it 'uses adjustable tongs when switching to tongs' do
        forge_instance.instance_variable_set(:@adjustable_tongs, true)
        expect(DRCC).to receive(:get_adjust_tongs?).with('tongs', 'backpack', [], nil, true)
        forge_instance.send(:swap_tool, 'tongs')
      end

      it 'uses adjustable tongs when switching to shovel' do
        forge_instance.instance_variable_set(:@adjustable_tongs, true)
        expect(DRCC).to receive(:get_adjust_tongs?).with('shovel', 'backpack', [], nil, true)
        forge_instance.send(:swap_tool, 'shovel')
      end

      it 'gets tongs directly when not adjustable' do
        forge_instance.instance_variable_set(:@adjustable_tongs, false)
        allow(DRCI).to receive(:in_hands?).with('tongs').and_return(false)
        expect(DRCC).to receive(:get_crafting_item).with('tongs', 'backpack', [], nil)
        forge_instance.send(:swap_tool, 'tongs')
      end

      it 'stows right hand and gets new tool for non-tongs' do
        forge_instance.instance_variable_set(:@adjustable_tongs, false)
        $right_hand = 'hammer'
        allow(DRCI).to receive(:in_hands?).with('bellows').and_return(false)
        expect(DRCC).to receive(:stow_crafting_item).with('hammer', 'backpack', nil)
        expect(DRCC).to receive(:get_crafting_item).with('bellows', 'backpack', [], nil, false)
        forge_instance.send(:swap_tool, 'bellows')
      end

      it 'does nothing if already holding the tool' do
        forge_instance.instance_variable_set(:@adjustable_tongs, false)
        allow(DRCI).to receive(:in_hands?).with('hammer').and_return(true)
        expect(DRCC).not_to receive(:get_crafting_item)
        expect(DRCC).not_to receive(:stow_crafting_item)
        forge_instance.send(:swap_tool, 'hammer')
      end
    end

    describe '#check_hand' do
      it 'swaps hands when item in right hand' do
        allow(DRCI).to receive(:in_right_hand?).with('sword').and_return(true)
        expect(DRC).to receive(:bput).with('swap', 'You move', 'You have nothing')
        forge_instance.send(:check_hand, 'sword')
      end

      it 'exits with error when item not in either hand' do
        allow(DRCI).to receive(:in_right_hand?).with('sword').and_return(false)
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: MISSING sword. Please find it and restart.')
        expect(forge_instance).to receive(:magic_cleanup)
        expect { forge_instance.send(:check_hand, 'sword') }.to raise_error(SystemExit)
      end
    end

    describe '#finish' do
      before do
        $right_hand = 'hammer'
        allow(DRCC).to receive(:stow_crafting_item)
        allow(forge_instance).to receive(:magic_cleanup)
      end

      it 'logs item to engineering logbook when finish is log' do
        forge_instance.instance_variable_set(:@finish, 'log')
        expect(DRCC).to receive(:logbook_item).with('engineering', 'sword', 'backpack')
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: sword logged to engineering logbook.')
        expect { forge_instance.send(:finish) }.to raise_error(SystemExit)
      end

      it 'stows item when finish is stow' do
        forge_instance.instance_variable_set(:@finish, 'stow')
        expect(DRCC).to receive(:stow_crafting_item).with('sword', 'backpack', nil).and_return(true)
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: sword stowed in backpack.')
        expect { forge_instance.send(:finish) }.to raise_error(SystemExit)
      end

      it 'logs failure when stow fails' do
        forge_instance.instance_variable_set(:@finish, 'stow')
        expect(DRCC).to receive(:stow_crafting_item).with('sword', 'backpack', nil).and_return(false)
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: Failed to stow sword. Item may still be in hand.')
        expect { forge_instance.send(:finish) }.to raise_error(SystemExit)
      end

      it 'disposes item when finish is trash' do
        forge_instance.instance_variable_set(:@finish, 'trash')
        expect(DRCI).to receive(:dispose_trash).with('sword')
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: sword disposed.')
        expect { forge_instance.send(:finish) }.to raise_error(SystemExit)
      end

      it 'holds item in hand when finish is hold' do
        forge_instance.instance_variable_set(:@finish, 'hold')
        expect(Lich::Messaging).to receive(:msg).with('bold', 'Forge: sword complete. Holding in hand.')
        expect { forge_instance.send(:finish) }.to raise_error(SystemExit)
      end

      it 'stamps item when @stamp is true' do
        forge_instance.instance_variable_set(:@stamp, true)
        forge_instance.instance_variable_set(:@finish, 'hold')
        expect(forge_instance).to receive(:swap_tool).with('stamp')
        expect(DRC).to receive(:bput).with('mark my sword with my stamp', *Forge::STAMP_PATTERNS)
        expect(DRCC).to receive(:stow_crafting_item).with('stamp', 'backpack', nil)
        expect { forge_instance.send(:finish) }.to raise_error(SystemExit)
      end
    end

    describe '#magic_cleanup' do
      it 'releases spell, mana, and symbiosis' do
        expect(DRC).to receive(:bput).with('release spell', 'You let your concentration lapse', "You aren't preparing a spell")
        expect(DRC).to receive(:bput).with('release mana', 'You release all', "You aren't harnessing any mana")
        expect(DRC).to receive(:bput).with('release symb', "But you haven't", 'You release', 'Repeat this command')
        forge_instance.send(:magic_cleanup)
      end
    end

    describe '#set_defaults' do
      it 'sets up for temper recipe' do
        forge_instance.instance_variable_set(:@recipe_name, 'temper')
        expect(forge_instance).to receive(:swap_tool).with('tongs')
        allow(DRCI).to receive(:in_left_hand?).and_return(true)
        forge_instance.send(:set_defaults)
        expect(forge_instance.instance_variable_get(:@home_tool)).to eq('tongs')
        expect(forge_instance.instance_variable_get(:@stamp)).to eq(false)
        expect(forge_instance.instance_variable_get(:@location)).to eq('on forge')
      end

      it 'sets up for metal weapon honing recipe' do
        forge_instance.instance_variable_set(:@recipe_name, 'metal weapon honing')
        forge_instance.instance_variable_set(:@resume, true)
        allow(DRCI).to receive(:in_left_hand?).and_return(true)
        forge_instance.send(:set_defaults)
        expect(forge_instance.instance_variable_get(:@home_tool)).to eq('wire brush')
        expect(forge_instance.instance_variable_get(:@chapter)).to eq(10)
        expect(forge_instance.instance_variable_get(:@book_type)).to eq('weaponsmithing')
      end

      it 'sets up for metal armor lightening recipe' do
        forge_instance.instance_variable_set(:@recipe_name, 'metal armor lightening')
        allow(DRCI).to receive(:in_left_hand?).and_return(true)
        forge_instance.send(:set_defaults)
        expect(forge_instance.instance_variable_get(:@home_tool)).to eq('pliers')
        expect(forge_instance.instance_variable_get(:@chapter)).to eq(5)
        expect(forge_instance.instance_variable_get(:@book_type)).to eq('armorsmithing')
      end

      it 'sets up for regular forging recipe' do
        forge_instance.instance_variable_set(:@recipe_name, 'short sword')
        forge_instance.send(:set_defaults)
        expect(forge_instance.instance_variable_get(:@home_tool)).to eq('forging hammer')
        expect(forge_instance.instance_variable_get(:@location)).to eq('on anvil')
      end
    end
  end
end
