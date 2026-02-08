# frozen_string_literal: true

require 'ostruct'
require 'time'

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

  def self.release_invisibility; end

  def self.wait_for_script_to_complete(*_args); end

  def self.fix_standing; end
end

module DRCC
  def self.stow_crafting_item(*_args)
    true
  end

  def self.get_crafting_item(*_args); end

  def self.find_shaping_room(*_args); end

  def self.find_sewing_room(*_args); end

  def self.find_enchanting_room(*_args); end

  def self.find_empty_crucible(*_args); end

  def self.check_for_existing_sigil?(*_args)
    true
  end

  def self.order_enchant(*_args); end

  def self.fount(*_args); end

  def self.repair_own_tools(*_args); end
end

module DRCI
  def self.stow_hands; end

  def self.dispose_trash(*_args); end

  def self.get_item(*_args); end

  def self.get_item?(*_args)
    true
  end

  def self.get_item_if_not_held?(*_args)
    true
  end

  def self.put_away_item?(*_args)
    true
  end

  def self.untie_item?(*_args)
    true
  end

  def self.count_items_in_container(*_args)
    0
  end

  def self.exists?(*_args)
    false
  end
end

module DRCT
  def self.walk_to(*_args); end

  def self.order_item(*_args); end

  def self.buy_item(*_args); end

  def self.dispose(*_args); end
end

module DRCM
  def self.ensure_copper_on_hand(*_args); end
end

module DRSkill
  def self.getxp(*_args)
    0
  end
end

module DRRoom
  def self.npcs
    $room_npcs || []
  end
end

class Room
  def self.current
    OpenStruct.new(id: $room_id || 1)
  end
end

module XMLData
  def self.room_title
    $room_title || ''
  end
end

module Flags
  def self.add(*_args); end
  def self.delete(*_args); end
end

module Lich
  module Messaging
    def self.msg(*_args); end
  end

  module Util
    def self.issue_command(*_args)
      []
    end
  end
end

# Stub for script before_dying
def before_dying(&block)
  # No-op for testing
end

# Global ordinals used by workorders
$ORDINALS = %w[first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth twentieth].freeze

# Load WorkOrders class definition (without executing top-level code)
load_lic_class('workorders.lic', 'WorkOrders')

RSpec.configure do |config|
  config.before(:each) do
    reset_data if defined?(reset_data)
    $right_hand = nil
    $left_hand = nil
    $room_npcs = []
    $room_id = 1
    $room_title = ''
  end
end

RSpec.describe WorkOrders do
  # Allocate a bare instance without calling initialize
  let(:workorders) { described_class.allocate }

  before(:each) do
    workorders.instance_variable_set(:@settings, OpenStruct.new(
                                                   crafting_container: 'backpack',
                                                   crafting_items_in_container: [],
                                                   hometown: 'Crossing',
                                                   default_container: 'backpack',
                                                   workorder_min_items: 1,
                                                   workorder_max_items: 10
                                                 ))
    workorders.instance_variable_set(:@bag, 'backpack')
    workorders.instance_variable_set(:@bag_items, [])
    workorders.instance_variable_set(:@belt, nil)
    workorders.instance_variable_set(:@hometown, 'Crossing')
    workorders.instance_variable_set(:@worn_trashcan, nil)
    workorders.instance_variable_set(:@worn_trashcan_verb, nil)
    workorders.instance_variable_set(:@min_items, 1)
    workorders.instance_variable_set(:@max_items, 10)
    workorders.instance_variable_set(:@retain_crafting_materials, false)

    # Stub methods that would exit or interact with game
    allow(workorders).to receive(:exit)
    allow(workorders).to receive(:fput)
    allow(workorders).to receive(:pause)
  end

  # ===========================================================================
  # Constants - verify frozen pattern constants
  # ===========================================================================
  describe 'constants' do
    it 'defines GIVE_LOGBOOK_SUCCESS_PATTERNS as frozen array' do
      expect(described_class::GIVE_LOGBOOK_SUCCESS_PATTERNS).to be_frozen
      expect(described_class::GIVE_LOGBOOK_SUCCESS_PATTERNS).to include('You hand')
    end

    it 'defines GIVE_LOGBOOK_RETRY_PATTERNS as frozen array' do
      expect(described_class::GIVE_LOGBOOK_RETRY_PATTERNS).to be_frozen
      expect(described_class::GIVE_LOGBOOK_RETRY_PATTERNS).to include("What is it you're trying to give")
    end

    it 'defines NPC_NOT_FOUND_PATTERN as frozen string' do
      expect(described_class::NPC_NOT_FOUND_PATTERN).to be_frozen
      expect(described_class::NPC_NOT_FOUND_PATTERN).to eq("What is it you're trying to give")
    end

    it 'defines REPAIR_GIVE_PATTERNS as frozen array' do
      expect(described_class::REPAIR_GIVE_PATTERNS).to be_frozen
      expect(described_class::REPAIR_GIVE_PATTERNS.length).to eq(6)
    end

    it 'defines REPAIR_NO_NEED_PATTERNS as frozen array' do
      expect(described_class::REPAIR_NO_NEED_PATTERNS).to be_frozen
      expect(described_class::REPAIR_NO_NEED_PATTERNS.length).to eq(3)
    end

    it 'defines BUNDLE_SUCCESS_PATTERNS as frozen array' do
      expect(described_class::BUNDLE_SUCCESS_PATTERNS).to be_frozen
      expect(described_class::BUNDLE_SUCCESS_PATTERNS).to include('You notate the')
    end

    it 'defines BUNDLE_FAILURE_PATTERN as frozen regex' do
      expect(described_class::BUNDLE_FAILURE_PATTERN).to be_frozen
      expect(described_class::BUNDLE_FAILURE_PATTERN).to match('requires items of')
    end

    it 'defines WORK_ORDER_REQUEST_PATTERNS as frozen array' do
      expect(described_class::WORK_ORDER_REQUEST_PATTERNS).to be_frozen
      expect(described_class::WORK_ORDER_REQUEST_PATTERNS.length).to eq(5)
    end

    it 'defines WORK_ORDER_ITEM_PATTERN with named captures' do
      pattern = described_class::WORK_ORDER_ITEM_PATTERN
      match = 'order for leather gloves. I need 3 '.match(pattern)
      expect(match).not_to be_nil
      expect(match[:item]).to eq('leather gloves')
      expect(match[:quantity]).to eq('3')
    end

    it 'defines WORK_ORDER_STACKS_PATTERN with named captures' do
      pattern = described_class::WORK_ORDER_STACKS_PATTERN
      match = 'order for healing salve. I need 2 stacks (5 uses each) of fine quality'.match(pattern)
      expect(match).not_to be_nil
      expect(match[:item]).to eq('healing salve')
      expect(match[:quantity]).to eq('2')
    end

    it 'defines LOGBOOK_REMAINING_PATTERN with named capture' do
      pattern = described_class::LOGBOOK_REMAINING_PATTERN
      match = 'You must bundle and deliver 3 more'.match(pattern)
      expect(match).not_to be_nil
      expect(match[:remaining]).to eq('3')
    end

    it 'defines COUNT_PATTERN with named capture' do
      pattern = described_class::COUNT_PATTERN
      match = '42'.match(pattern)
      expect(match).not_to be_nil
      expect(match[:count]).to eq('42')
    end

    it 'defines POLISH_COUNT_PATTERN with named capture' do
      pattern = described_class::POLISH_COUNT_PATTERN
      match = 'The surface polish has 15 uses remaining'.match(pattern)
      expect(match).not_to be_nil
      expect(match[:count]).to eq('15')
    end

    it 'defines TAP_HERB_PATTERN with named capture' do
      pattern = described_class::TAP_HERB_PATTERN
      match = 'You tap a jadice flower inside your'.match(pattern)
      expect(match).not_to be_nil
      expect(match[:item]).to eq('a jadice flower')
    end

    it 'defines HERB_COUNT_PATTERN with named capture' do
      pattern = described_class::HERB_COUNT_PATTERN
      match = 'You count out 25 pieces.'.match(pattern)
      expect(match).not_to be_nil
      expect(match[:count]).to eq('25')
    end

    it 'defines REMEDY_COUNT_PATTERN with named capture' do
      pattern = described_class::REMEDY_COUNT_PATTERN
      match = 'You count out 5 uses remaining.'.match(pattern)
      expect(match).not_to be_nil
      expect(match[:count]).to eq('5')
    end

    it 'defines MATERIAL_NOUNS as frozen array' do
      expect(described_class::MATERIAL_NOUNS).to be_frozen
      expect(described_class::MATERIAL_NOUNS).to eq(%w[deed pebble stone rock rock boulder])
    end

    it 'defines READ_LOGBOOK_PATTERNS as frozen array' do
      expect(described_class::READ_LOGBOOK_PATTERNS).to be_frozen
      expect(described_class::READ_LOGBOOK_PATTERNS.length).to eq(2)
    end

    it 'defines VERSION as frozen string' do
      expect(described_class::VERSION).to be_frozen
      expect(described_class::VERSION).to eq('1.0.0')
    end
  end

  # ===========================================================================
  # #find_npc - NPC location with proper verification
  # ===========================================================================
  describe '#find_npc' do
    let(:room_list) { [100, 101, 102] }

    context 'when NPC is in current room' do
      before { $room_npcs = ['Jakke'] }

      it 'returns true without walking' do
        expect(DRCT).not_to receive(:walk_to)
        result = workorders.send(:find_npc, room_list, 'Jakke')
        expect(result).to be true
      end
    end

    context 'when NPC is in second room' do
      it 'walks to rooms until NPC is found' do
        call_count = 0
        allow(DRRoom).to receive(:npcs) do
          call_count += 1
          call_count >= 2 ? ['Jakke'] : []
        end

        expect(DRCT).to receive(:walk_to).with(100).once
        result = workorders.send(:find_npc, room_list, 'Jakke')
        expect(result).to be true
      end
    end

    context 'when NPC is not in any room' do
      before { $room_npcs = [] }

      it 'walks to all rooms and returns false' do
        expect(DRCT).to receive(:walk_to).exactly(3).times
        result = workorders.send(:find_npc, room_list, 'Jakke')
        expect(result).to be false
      end
    end

    context 'when NPC is in last room' do
      it 'walks to all rooms and returns true' do
        call_count = 0
        allow(DRRoom).to receive(:npcs) do
          call_count += 1
          call_count >= 4 ? ['Jakke'] : []
        end

        expect(DRCT).to receive(:walk_to).exactly(3).times
        result = workorders.send(:find_npc, room_list, 'Jakke')
        expect(result).to be true
      end
    end
  end

  # ===========================================================================
  # #complete_work_order - handles NPC walking away
  # ===========================================================================
  describe '#complete_work_order' do
    let(:info) do
      {
        'npc-rooms'     => [100, 101],
        'npc_last_name' => 'Jakke',
        'npc'           => 'Jakke',
        'logbook'       => 'engineering'
      }
    end

    before do
      allow(workorders).to receive(:find_npc).and_return(true)
      allow(workorders).to receive(:stow_tool)
    end

    context 'when give succeeds on first try' do
      it 'gives logbook and stows it' do
        expect(DRCI).to receive(:get_item?).with('engineering logbook').and_return(true)
        expect(DRC).to receive(:release_invisibility).once
        expect(DRC).to receive(:bput).with('give logbook to Jakke', any_args).and_return('You hand')
        expect(workorders).to receive(:stow_tool).with('logbook')
        expect(Lich::Messaging).to receive(:msg).with('plain', 'WorkOrders: Work order completed and turned in')

        workorders.send(:complete_work_order, info)
      end
    end

    context 'when NPC walks away (bug fix scenario)' do
      it 'retries finding NPC and giving again' do
        call_count = 0
        allow(DRCI).to receive(:get_item?).and_return(true)
        allow(DRC).to receive(:bput) do |cmd, *_patterns|
          if cmd.include?('give logbook')
            call_count += 1
            call_count == 1 ? "What is it you're trying to give" : 'You hand'
          else
            'You get'
          end
        end
        allow(DRC).to receive(:release_invisibility)

        expect(workorders).to receive(:find_npc).twice.and_return(true)
        expect(workorders).to receive(:stow_tool).with('logbook')

        workorders.send(:complete_work_order, info)
      end
    end

    context 'when NPC cannot be found' do
      it 'logs error and returns without crashing' do
        allow(workorders).to receive(:find_npc).and_return(false)
        expect(Lich::Messaging).to receive(:msg).with('bold', /Could not find NPC/)
        expect(workorders).not_to receive(:stow_tool)

        workorders.send(:complete_work_order, info)
      end
    end

    context 'when logbook cannot be retrieved' do
      it 'logs error and returns' do
        allow(workorders).to receive(:find_npc).and_return(true)
        allow(DRCI).to receive(:get_item?).with('engineering logbook').and_return(false)
        expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to get.*logbook for turn-in/)
        expect(DRC).not_to receive(:bput)

        workorders.send(:complete_work_order, info)
      end
    end

    context 'when work order is expired' do
      it 'handles expired work order response' do
        allow(DRCI).to receive(:get_item?).and_return(true)
        allow(DRC).to receive(:release_invisibility)
        allow(DRC).to receive(:bput).and_return('Apparently the work order time limit has expired')
        expect(workorders).to receive(:stow_tool).with('logbook')

        workorders.send(:complete_work_order, info)
      end
    end

    context 'when work order is not complete' do
      it 'handles incomplete work order response' do
        allow(DRCI).to receive(:get_item?).and_return(true)
        allow(DRC).to receive(:release_invisibility)
        allow(DRC).to receive(:bput).and_return("The work order isn't yet complete")
        expect(workorders).to receive(:stow_tool).with('logbook')

        workorders.send(:complete_work_order, info)
      end
    end
  end

  # ===========================================================================
  # #bundle_item - pattern matching for success/failure
  # ===========================================================================
  describe '#bundle_item' do
    before do
      allow(DRC).to receive(:bput).and_return('You notate the')
    end

    context 'when bundling succeeds' do
      it 'gets logbook and bundles item' do
        expect(DRCI).to receive(:get_item?).with('engineering logbook').and_return(true)
        expect(DRC).to receive(:bput).with('bundle my gloves with my logbook', *described_class::BUNDLE_SUCCESS_PATTERNS).and_return('You notate the')
        expect(DRCI).to receive(:stow_hands)
        expect(DRCI).not_to receive(:dispose_trash)

        workorders.send(:bundle_item, 'gloves', 'engineering')
      end
    end

    context 'when item quality is too low' do
      it 'disposes the item and logs message' do
        expect(DRCI).to receive(:get_item?).with('engineering logbook').and_return(true)
        expect(DRC).to receive(:bput).with('bundle my gloves with my logbook', any_args).and_return('The work order requires items of a higher quality')
        expect(Lich::Messaging).to receive(:msg).with('bold', /Bundle failed/)
        expect(DRCI).to receive(:dispose_trash).with('gloves', nil, nil)
        expect(DRCI).to receive(:stow_hands)

        workorders.send(:bundle_item, 'gloves', 'engineering')
      end
    end

    context 'when item is damaged enchanted' do
      it 'disposes the item and logs message' do
        expect(DRCI).to receive(:get_item?).with('engineering logbook').and_return(true)
        expect(DRC).to receive(:bput).with('bundle my sphere with my logbook', any_args).and_return('Only undamaged enchanted items may be used with workorders.')
        expect(Lich::Messaging).to receive(:msg).with('bold', /Bundle failed/)
        expect(DRCI).to receive(:dispose_trash).with('sphere', nil, nil)
        expect(DRCI).to receive(:stow_hands)

        workorders.send(:bundle_item, 'sphere', 'engineering')
      end
    end

    context 'when noun is small sphere (fount)' do
      it 'converts noun to fount' do
        expect(DRCI).to receive(:get_item?).with('enchanting logbook').and_return(true)
        expect(DRC).to receive(:bput).with('bundle my fount with my logbook', any_args).and_return('You notate the')
        expect(DRCI).to receive(:stow_hands)

        workorders.send(:bundle_item, 'small sphere', 'enchanting')
      end
    end

    context 'when logbook cannot be retrieved' do
      it 'returns false and logs error' do
        expect(DRCI).to receive(:get_item?).with('engineering logbook').and_return(false)
        expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to get.*logbook for bundling/)
        expect(DRC).not_to receive(:bput)

        result = workorders.send(:bundle_item, 'gloves', 'engineering')
        expect(result).to be false
      end
    end

    context 'when work order has expired' do
      it 'stows hands without disposing' do
        expect(DRCI).to receive(:get_item?).with('outfitting logbook').and_return(true)
        expect(DRC).to receive(:bput).and_return('This work order has expired')
        expect(DRCI).not_to receive(:dispose_trash)
        expect(DRCI).to receive(:stow_hands)

        workorders.send(:bundle_item, 'shirt', 'outfitting')
      end
    end

    context "when that's not going to work" do
      it 'stows hands without disposing' do
        expect(DRCI).to receive(:get_item?).with('blacksmithing logbook').and_return(true)
        expect(DRC).to receive(:bput).and_return("That's not going to work")
        expect(DRCI).not_to receive(:dispose_trash)
        expect(DRCI).to receive(:stow_hands)

        workorders.send(:bundle_item, 'ingot', 'blacksmithing')
      end
    end
  end

  # ===========================================================================
  # #find_recipe - pure calculation method
  # ===========================================================================
  describe '#find_recipe' do
    let(:materials_info) { { 'stock-volume' => 100 } }

    context 'with recipe volume that divides evenly' do
      let(:recipe) { { 'volume' => 25 } }

      it 'returns correct items per stock' do
        result = workorders.send(:find_recipe, materials_info, recipe, 4)
        _recipe, items_per_stock, spare_stock, scrap = result

        expect(items_per_stock).to eq(4)
        expect(spare_stock).to be_nil
        expect(scrap).to be_nil
      end
    end

    context 'with recipe volume that leaves remainder' do
      let(:recipe) { { 'volume' => 30 } }

      it 'calculates spare stock correctly' do
        result = workorders.send(:find_recipe, materials_info, recipe, 3)
        _recipe, items_per_stock, spare_stock, scrap = result

        expect(items_per_stock).to eq(3)
        expect(spare_stock).to eq(10) # 100 % 30 = 10
        expect(scrap).to be_truthy
      end
    end

    context 'when quantity causes scrap' do
      let(:recipe) { { 'volume' => 25 } }

      it 'detects scrap from quantity mismatch' do
        result = workorders.send(:find_recipe, materials_info, recipe, 5)
        _recipe, items_per_stock, _spare_stock, scrap = result

        expect(items_per_stock).to eq(4)
        expect(scrap).to be_truthy # 5 % 4 = 1
      end
    end

    context 'with large recipe volume' do
      let(:recipe) { { 'volume' => 150 } }

      it 'returns zero items per stock' do
        result = workorders.send(:find_recipe, materials_info, recipe, 1)
        _recipe, items_per_stock, spare_stock, scrap = result

        expect(items_per_stock).to eq(0)
        expect(spare_stock).to eq(100) # 100 % 150 = 100
        expect(scrap).to be_truthy
      end
    end
  end

  # ===========================================================================
  # #get_tool / #stow_tool - delegates to DRCC
  # ===========================================================================
  describe '#get_tool' do
    it 'delegates to DRCC.get_crafting_item with correct args' do
      expect(DRCC).to receive(:get_crafting_item).with('scissors', 'backpack', [], nil, true)
      workorders.send(:get_tool, 'scissors')
    end

    it 'uses configured belt when set' do
      workorders.instance_variable_set(:@belt, 'toolbelt')
      expect(DRCC).to receive(:get_crafting_item).with('hammer', 'backpack', [], 'toolbelt', true)
      workorders.send(:get_tool, 'hammer')
    end
  end

  describe '#stow_tool' do
    it 'delegates to DRCC.stow_crafting_item with correct args' do
      expect(DRCC).to receive(:stow_crafting_item).with('scissors', 'backpack', nil)
      workorders.send(:stow_tool, 'scissors')
    end

    it 'uses configured belt when set' do
      workorders.instance_variable_set(:@belt, 'toolbelt')
      expect(DRCC).to receive(:stow_crafting_item).with('hammer', 'backpack', 'toolbelt')
      workorders.send(:stow_tool, 'hammer')
    end
  end

  # ===========================================================================
  # #repair_items - tool repair workflow
  # ===========================================================================
  describe '#repair_items' do
    let(:info) do
      {
        'repair-room' => 200,
        'repair-npc'  => 'Rangu'
      }
    end
    let(:tools) { ['hammer', 'tongs'] }

    before do
      workorders.instance_variable_set(:@settings, OpenStruct.new(workorders_repair_own_tools: false))
    end

    context 'when tool needs no repair' do
      it 'stows tool when repair not needed' do
        allow(DRC).to receive(:bput).and_return("There isn't a scratch on that")
        allow(DRCI).to receive(:get_item?).with('Rangu ticket').and_return(false)

        expect(workorders).to receive(:get_tool).with('hammer')
        expect(workorders).to receive(:get_tool).with('tongs')
        expect(workorders).to receive(:stow_tool).with('hammer')
        expect(workorders).to receive(:stow_tool).with('tongs')
        expect(Lich::Messaging).to receive(:msg).with('plain', 'WorkOrders: Tool repair at NPC completed')

        workorders.send(:repair_items, info, tools)
      end
    end

    context 'when tool needs repair' do
      it 'gives tool twice and stows ticket' do
        call_count = 0
        allow(DRC).to receive(:bput) do |cmd, *_patterns|
          if cmd.include?('give Rangu')
            call_count += 1
            call_count == 1 ? 'Just give it to me again' : 'repair ticket'
          else
            'default'
          end
        end
        allow(DRCI).to receive(:get_item?).with('Rangu ticket').and_return(false)
        allow(DRCI).to receive(:put_away_item?).and_return(true)

        expect(workorders).to receive(:get_tool).with('hammer')
        expect(workorders).to receive(:get_tool).with('tongs')

        workorders.send(:repair_items, info, tools)
      end
    end

    context 'when using own tools for repair' do
      before do
        workorders.instance_variable_set(:@settings, OpenStruct.new(workorders_repair_own_tools: true))
        workorders.instance_variable_set(:@hometown, 'Crossing')
        workorders.instance_variable_set(:@bag, 'backpack')
        workorders.instance_variable_set(:@bag_items, 'backpack')
        workorders.instance_variable_set(:@belt, 'toolbelt')

        mock_room = double('Room', id: 100)
        stub_const('Room', double('RoomClass', current: mock_room))
        allow(DRCM).to receive(:ensure_copper_on_hand)
        allow(DRCT).to receive(:walk_to)
        allow_any_instance_of(described_class).to receive(:get_data).and_return({ 'blacksmithing' => { 'Crossing' => {} } })
      end

      it 'uses DRCC.repair_own_tools' do
        expect(DRCC).to receive(:repair_own_tools)
        expect(Lich::Messaging).to receive(:msg).with('plain', 'WorkOrders: Tool repair using own materials completed')

        workorders.send(:repair_items, info, tools)
      end
    end

    context 'when ticket stow fails' do
      it 'logs failure message' do
        allow(DRC).to receive(:bput).and_return('Just give it to me again', 'repair ticket')
        allow(DRCI).to receive(:get_item?).with('Rangu ticket').and_return(false)
        allow(DRCI).to receive(:put_away_item?).with('ticket').and_return(false)

        expect(workorders).to receive(:get_tool).with('hammer')
        expect(workorders).to receive(:get_tool).with('tongs')
        # First tool triggers 'give' branch with stow failure, second tool gets 'repair ticket' (no 'give')
        expect(Lich::Messaging).to receive(:msg).with('bold', 'WorkOrders: Failed to stow repair ticket').once
        expect(Lich::Messaging).to receive(:msg).with('plain', 'WorkOrders: Tool repair at NPC completed')

        workorders.send(:repair_items, info, tools)
      end
    end
  end

  # ===========================================================================
  # #buy_parts / #order_parts - nil-safe iteration
  # ===========================================================================
  describe '#buy_parts' do
    context 'when parts is nil' do
      it 'does not crash' do
        expect { workorders.send(:buy_parts, nil, 100) }.not_to raise_error
      end
    end

    context 'when parts is empty' do
      it 'does not call buy_item' do
        expect(DRCT).not_to receive(:buy_item)
        workorders.send(:buy_parts, [], 100)
      end
    end

    context 'when parts has items' do
      it 'buys and stows each part' do
        expect(DRCT).to receive(:buy_item).with(100, 'clasp')
        expect(workorders).to receive(:stow_tool).with('clasp')
        workorders.send(:buy_parts, ['clasp'], 100)
      end
    end

    context 'when parts has multiple items' do
      it 'buys and stows each part' do
        expect(DRCT).to receive(:buy_item).with(100, 'clasp')
        expect(DRCT).to receive(:buy_item).with(100, 'rivet')
        expect(workorders).to receive(:stow_tool).with('clasp')
        expect(workorders).to receive(:stow_tool).with('rivet')
        workorders.send(:buy_parts, %w[clasp rivet], 100)
      end
    end
  end

  describe '#order_parts' do
    before do
      workorders.instance_variable_set(:@recipe_parts, {
                                         'clasp' => {
                                           'Crossing' => { 'part-room' => 100, 'part-number' => 5 }
                                         },
                                         'rivet' => {
                                           'Crossing' => { 'part-room' => 101 }
                                         }
                                       })
    end

    context 'when parts is nil' do
      it 'does not crash' do
        expect { workorders.send(:order_parts, nil, 2) }.not_to raise_error
      end
    end

    context 'when part has part-number' do
      it 'orders from room with number' do
        expect(DRCT).to receive(:order_item).with(100, 5).twice
        expect(workorders).to receive(:stow_tool).with('clasp').twice
        workorders.send(:order_parts, ['clasp'], 2)
      end
    end

    context 'when part does not have part-number' do
      it 'buys from room instead' do
        expect(DRCT).to receive(:buy_item).with(101, 'rivet').twice
        expect(workorders).to receive(:stow_tool).with('rivet').twice
        workorders.send(:order_parts, ['rivet'], 2)
      end
    end
  end

  # ===========================================================================
  # #gather_process_herb - messaging update
  # ===========================================================================
  describe '#gather_process_herb' do
    it 'logs message with WorkOrders prefix' do
      expect(Lich::Messaging).to receive(:msg).with('plain', 'WorkOrders: Gathering herb: jadice flower')
      expect(DRC).to receive(:wait_for_script_to_complete).with('alchemy', ['jadice flower', 'forage', 25])
      expect(DRC).to receive(:wait_for_script_to_complete).with('alchemy', ['jadice flower', 'prepare'])

      workorders.send(:gather_process_herb, 'jadice flower', 25)
    end
  end

  # ===========================================================================
  # #ingot_volume / #deed_ingot_volume - volume parsing
  # ===========================================================================
  describe '#ingot_volume' do
    it 'parses volume from analyze result' do
      allow(DRC).to receive(:bput).with('analyze my ingot', 'About \d+ volume').and_return('About 50 volume')
      expect(workorders.send(:ingot_volume)).to eq(50)
    end
  end

  describe '#deed_ingot_volume' do
    it 'parses volume from deed read result' do
      allow(DRC).to receive(:bput).with('read my deed', 'Volume:\s*\d+').and_return('Volume: 75')
      expect(workorders.send(:deed_ingot_volume)).to eq(75)
    end
  end

  # ===========================================================================
  # #go_door - workshop navigation
  # ===========================================================================
  describe '#go_door' do
    it 'opens and goes through door' do
      expect(workorders).to receive(:fput).with('open door')
      expect(DRC).to receive(:fix_standing)
      expect(workorders).to receive(:fput).with('go door')

      workorders.send(:go_door)
    end
  end

  # ===========================================================================
  # Pattern matching tests for named captures
  # ===========================================================================
  describe 'pattern matching' do
    describe 'WORK_ORDER_ITEM_PATTERN' do
      it 'captures item name with spaces' do
        result = 'order for leather gloves. I need 5 '
        match = result.match(described_class::WORK_ORDER_ITEM_PATTERN)
        expect(match[:item]).to eq('leather gloves')
        expect(match[:quantity]).to eq('5')
      end

      it 'captures single word items' do
        result = 'order for gloves. I need 3 '
        match = result.match(described_class::WORK_ORDER_ITEM_PATTERN)
        expect(match[:item]).to eq('gloves')
        expect(match[:quantity]).to eq('3')
      end

      it 'captures item with many words' do
        result = 'order for leather knee high boots. I need 2 '
        match = result.match(described_class::WORK_ORDER_ITEM_PATTERN)
        expect(match[:item]).to eq('leather knee high boots')
        expect(match[:quantity]).to eq('2')
      end
    end

    describe 'WORK_ORDER_STACKS_PATTERN' do
      it 'captures remedy work orders' do
        result = 'order for healing salve. I need 3 stacks (5 uses each) of masterful quality'
        match = result.match(described_class::WORK_ORDER_STACKS_PATTERN)
        expect(match[:item]).to eq('healing salve')
        expect(match[:quantity]).to eq('3')
      end
    end

    describe 'LOGBOOK_REMAINING_PATTERN' do
      it 'captures remaining count' do
        result = 'You must bundle and deliver 7 more items'
        match = result.match(described_class::LOGBOOK_REMAINING_PATTERN)
        expect(match[:remaining]).to eq('7')
      end

      it 'captures single remaining' do
        result = 'You must bundle and deliver 1 more'
        match = result.match(described_class::LOGBOOK_REMAINING_PATTERN)
        expect(match[:remaining]).to eq('1')
      end
    end

    describe 'TAP_HERB_PATTERN' do
      it 'captures full herb name including adjectives' do
        result = 'You tap a dried jadice flower inside your backpack'
        match = result.match(described_class::TAP_HERB_PATTERN)
        expect(match[:item]).to eq('a dried jadice flower')
      end

      it 'captures simple herb' do
        result = 'You tap some jadice inside your haversack'
        match = result.match(described_class::TAP_HERB_PATTERN)
        expect(match[:item]).to eq('some jadice')
      end
    end

    describe 'POLISH_COUNT_PATTERN' do
      it 'captures polish count' do
        result = 'The surface polish has 12 uses remaining'
        match = result.match(described_class::POLISH_COUNT_PATTERN)
        expect(match[:count]).to eq('12')
      end

      it 'captures single digit count' do
        result = 'The surface polish has 3 uses remaining'
        match = result.match(described_class::POLISH_COUNT_PATTERN)
        expect(match[:count]).to eq('3')
      end
    end

    describe 'HERB_COUNT_PATTERN' do
      it 'captures herb piece count' do
        result = 'You count out 50 pieces.'
        match = result.match(described_class::HERB_COUNT_PATTERN)
        expect(match[:count]).to eq('50')
      end
    end

    describe 'REMEDY_COUNT_PATTERN' do
      it 'captures remedy use count' do
        result = 'You count out 5 uses remaining.'
        match = result.match(described_class::REMEDY_COUNT_PATTERN)
        expect(match[:count]).to eq('5')
      end
    end

    describe 'BUNDLE_FAILURE_PATTERN' do
      it 'matches quality failure' do
        expect(described_class::BUNDLE_FAILURE_PATTERN).to match('The work order requires items of a higher quality')
      end

      it 'matches enchanted item failure' do
        expect(described_class::BUNDLE_FAILURE_PATTERN).to match('Only undamaged enchanted items may be used')
      end

      it 'does not match success' do
        expect(described_class::BUNDLE_FAILURE_PATTERN).not_to match('You notate the')
      end
    end

    describe 'REPAIR_NO_NEED_PATTERNS' do
      it 'matches no scratch response' do
        result = "There isn't a scratch on that tool"
        expect(described_class::REPAIR_NO_NEED_PATTERNS.any? { |p| p.match?(result) }).to be true
      end

      it 'matches will not repair' do
        result = 'I will not repair that'
        expect(described_class::REPAIR_NO_NEED_PATTERNS.any? { |p| p.match?(result) }).to be true
      end

      it 'matches limited use item' do
        result = 'They only have so many uses'
        expect(described_class::REPAIR_NO_NEED_PATTERNS.any? { |p| p.match?(result) }).to be true
      end
    end
  end

  # ===========================================================================
  # DRCI predicate conversion tests
  # ===========================================================================
  describe 'DRCI predicate conversions' do
    describe 'get_item? usage' do
      it 'uses DRCI.get_item? for logbook retrieval in bundle_item' do
        expect(DRCI).to receive(:get_item?).with('engineering logbook').and_return(true)
        allow(DRC).to receive(:bput).and_return('You notate the')
        allow(DRCI).to receive(:stow_hands)

        workorders.send(:bundle_item, 'gloves', 'engineering')
      end

      it 'uses DRCI.get_item? for logbook in complete_work_order' do
        allow(workorders).to receive(:find_npc).and_return(true)
        allow(workorders).to receive(:stow_tool)
        allow(DRC).to receive(:release_invisibility)
        allow(DRC).to receive(:bput).and_return('You hand')

        expect(DRCI).to receive(:get_item?).with('blacksmithing logbook').and_return(true)

        info = { 'npc-rooms' => [100], 'npc_last_name' => 'Rangu', 'npc' => 'Rangu', 'logbook' => 'blacksmithing' }
        workorders.send(:complete_work_order, info)
      end
    end

    describe 'put_away_item? usage' do
      it 'uses DRCI.put_away_item? for ticket in repair_items' do
        workorders.instance_variable_set(:@settings, OpenStruct.new(workorders_repair_own_tools: false))
        # Return 'Just give it to me again' for every first give per tool
        allow(DRC).to receive(:bput) do |cmd, *_patterns|
          cmd.include?('give') ? 'Just give it to me again' : 'repair ticket'
        end
        allow(DRCI).to receive(:get_item?).and_return(false)
        allow(workorders).to receive(:get_tool)
        allow(Lich::Messaging).to receive(:msg)

        expect(DRCI).to receive(:put_away_item?).with('ticket').and_return(true).twice

        workorders.send(:repair_items, { 'repair-room' => 100, 'repair-npc' => 'Rangu' }, %w[hammer tongs])
      end
    end

    describe 'untie_item? usage in request_work_order' do
      it 'uses DRCI.untie_item? when items are bundled' do
        workorders.instance_variable_set(:@min_items, 1)
        workorders.instance_variable_set(:@max_items, 10)

        call_count = 0
        allow(workorders).to receive(:find_npc).and_return(true)
        allow(workorders).to receive(:stow_tool)
        allow(DRC).to receive(:bput) do |_cmd, *_patterns|
          call_count += 1
          if call_count == 1
            'You realize you have items bundled with the logbook'
          else
            'order for gloves. I need 3 '
          end
        end
        allow(DRCI).to receive(:get_item?).and_return(true)
        allow(DRCI).to receive(:dispose_trash)
        $left_hand = 'logbook'

        expect(DRCI).to receive(:untie_item?).with('logbook').and_return(true)

        recipes = [{ 'name' => 'gloves' }]
        workorders.send(:request_work_order, recipes, [100], 'Jakke', 'Jakke', 'tailoring', 'outfitting', 'challenging')
      end
    end
  end

  # ===========================================================================
  # Error messaging tests
  # ===========================================================================
  describe 'error messaging' do
    it 'uses WorkOrders: prefix for all error messages' do
      allow(workorders).to receive(:find_npc).and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', /^WorkOrders:/)

      workorders.send(:complete_work_order, {
                        'npc-rooms' => [100],
                        'npc_last_name' => 'Jakke',
                        'npc' => 'Jakke',
                        'logbook' => 'engineering'
                      })
    end

    it 'uses WorkOrders: prefix for bundle failure' do
      allow(DRCI).to receive(:get_item?).and_return(true)
      allow(DRC).to receive(:bput).and_return('The work order requires items of a higher quality')
      allow(DRCI).to receive(:dispose_trash)
      allow(DRCI).to receive(:stow_hands)

      expect(Lich::Messaging).to receive(:msg).with('bold', /^WorkOrders:.*Bundle failed/)

      workorders.send(:bundle_item, 'gloves', 'engineering')
    end
  end
end
