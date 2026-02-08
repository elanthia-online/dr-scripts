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
  let(:workorders) { WorkOrders.allocate }

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
      expect(WorkOrders::GIVE_LOGBOOK_SUCCESS_PATTERNS).to be_frozen
      expect(WorkOrders::GIVE_LOGBOOK_SUCCESS_PATTERNS).to include('You hand')
    end

    it 'defines GIVE_LOGBOOK_RETRY_PATTERNS as frozen array' do
      expect(WorkOrders::GIVE_LOGBOOK_RETRY_PATTERNS).to be_frozen
      expect(WorkOrders::GIVE_LOGBOOK_RETRY_PATTERNS).to include("What is it you're trying to give")
    end

    it 'defines NPC_NOT_FOUND_PATTERN as frozen string' do
      expect(WorkOrders::NPC_NOT_FOUND_PATTERN).to be_frozen
      expect(WorkOrders::NPC_NOT_FOUND_PATTERN).to eq("What is it you're trying to give")
    end

    it 'defines REPAIR_GIVE_PATTERNS as frozen array' do
      expect(WorkOrders::REPAIR_GIVE_PATTERNS).to be_frozen
      expect(WorkOrders::REPAIR_GIVE_PATTERNS.length).to eq(6)
    end

    it 'defines BUNDLE_SUCCESS_PATTERNS as frozen array' do
      expect(WorkOrders::BUNDLE_SUCCESS_PATTERNS).to be_frozen
      expect(WorkOrders::BUNDLE_SUCCESS_PATTERNS).to include('You notate the')
    end

    it 'defines BUNDLE_FAILURE_PATTERN as frozen regex' do
      expect(WorkOrders::BUNDLE_FAILURE_PATTERN).to be_frozen
      expect(WorkOrders::BUNDLE_FAILURE_PATTERN).to match('requires items of')
    end

    it 'defines WORK_ORDER_ITEM_PATTERN with named captures' do
      pattern = WorkOrders::WORK_ORDER_ITEM_PATTERN
      match = 'order for leather gloves. I need 3 '.match(pattern)
      expect(match).not_to be_nil
      expect(match[:item]).to eq('leather gloves')
      expect(match[:quantity]).to eq('3')
    end

    it 'defines WORK_ORDER_STACKS_PATTERN with named captures' do
      pattern = WorkOrders::WORK_ORDER_STACKS_PATTERN
      match = 'order for healing salve. I need 2 stacks (5 uses each) of fine quality'.match(pattern)
      expect(match).not_to be_nil
      expect(match[:item]).to eq('healing salve')
      expect(match[:quantity]).to eq('2')
    end

    it 'defines LOGBOOK_REMAINING_PATTERN with named capture' do
      pattern = WorkOrders::LOGBOOK_REMAINING_PATTERN
      match = 'You must bundle and deliver 3 more'.match(pattern)
      expect(match).not_to be_nil
      expect(match[:remaining]).to eq('3')
    end

    it 'defines POLISH_COUNT_PATTERN with named capture' do
      pattern = WorkOrders::POLISH_COUNT_PATTERN
      match = 'The surface polish has 15 uses remaining'.match(pattern)
      expect(match).not_to be_nil
      expect(match[:count]).to eq('15')
    end

    it 'defines TAP_HERB_PATTERN with named capture' do
      pattern = WorkOrders::TAP_HERB_PATTERN
      match = 'You tap a jadice flower inside your'.match(pattern)
      expect(match).not_to be_nil
      expect(match[:item]).to eq('a jadice flower')
    end

    it 'defines HERB_COUNT_PATTERN with named capture' do
      pattern = WorkOrders::HERB_COUNT_PATTERN
      match = 'You count out 25 pieces.'.match(pattern)
      expect(match).not_to be_nil
      expect(match[:count]).to eq('25')
    end

    it 'defines REMEDY_COUNT_PATTERN with named capture' do
      pattern = WorkOrders::REMEDY_COUNT_PATTERN
      match = 'You count out 5 uses remaining.'.match(pattern)
      expect(match).not_to be_nil
      expect(match[:count]).to eq('5')
    end

    it 'defines MATERIAL_NOUNS as frozen array' do
      expect(WorkOrders::MATERIAL_NOUNS).to be_frozen
      expect(WorkOrders::MATERIAL_NOUNS).to eq(%w[deed pebble stone rock rock boulder])
    end

    it 'defines READ_LOGBOOK_PATTERNS as frozen array' do
      expect(WorkOrders::READ_LOGBOOK_PATTERNS).to be_frozen
      expect(WorkOrders::READ_LOGBOOK_PATTERNS.length).to eq(2)
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
        expect(DRC).to receive(:bput).with('give log to Jakke', any_args).and_return('You hand')
        expect(workorders).to receive(:stow_tool).with('logbook')

        workorders.send(:complete_work_order, info)
      end
    end

    context 'when NPC walks away (bug fix scenario)' do
      it 'retries finding NPC and giving again' do
        call_count = 0
        allow(DRCI).to receive(:get_item?).and_return(true)
        allow(DRC).to receive(:bput) do |cmd, *_patterns|
          if cmd.include?('give log')
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
        expect(DRC).to receive(:bput).with('bundle my gloves with my logbook', *WorkOrders::BUNDLE_SUCCESS_PATTERNS).and_return('You notate the')
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
  end

  # ===========================================================================
  # #get_tool / #stow_tool - delegates to DRCC
  # ===========================================================================
  describe '#get_tool' do
    it 'delegates to DRCC.get_crafting_item with correct args' do
      expect(DRCC).to receive(:get_crafting_item).with('scissors', 'backpack', [], nil, true)
      workorders.send(:get_tool, 'scissors')
    end
  end

  describe '#stow_tool' do
    it 'delegates to DRCC.stow_crafting_item with correct args' do
      expect(DRCC).to receive(:stow_crafting_item).with('scissors', 'backpack', nil)
      workorders.send(:stow_tool, 'scissors')
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
        # Mock sequence: give hammer (no scratch), give tongs (no scratch), get ticket (none)
        allow(DRC).to receive(:bput) do |cmd, *_patterns|
          if cmd.include?('give')
            "There isn't a scratch on that"
          elsif cmd.include?('get my')
            'What were'
          else
            ''
          end
        end
        expect(workorders).to receive(:get_tool).with('hammer')
        expect(workorders).to receive(:get_tool).with('tongs')
        expect(workorders).to receive(:stow_tool).with('hammer')
        expect(workorders).to receive(:stow_tool).with('tongs')

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
  end

  describe '#order_parts' do
    before do
      workorders.instance_variable_set(:@recipe_parts, {
        'clasp' => {
          'Crossing' => { 'part-room' => 100, 'part-number' => 5 }
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
  # Pattern matching tests for named captures
  # ===========================================================================
  describe 'pattern matching' do
    describe 'WORK_ORDER_ITEM_PATTERN' do
      it 'captures item name with spaces' do
        result = 'order for leather gloves. I need 5 '
        match = result.match(WorkOrders::WORK_ORDER_ITEM_PATTERN)
        expect(match[:item]).to eq('leather gloves')
        expect(match[:quantity]).to eq('5')
      end

      it 'captures single word items' do
        result = 'order for gloves. I need 3 '
        match = result.match(WorkOrders::WORK_ORDER_ITEM_PATTERN)
        expect(match[:item]).to eq('gloves')
        expect(match[:quantity]).to eq('3')
      end
    end

    describe 'LOGBOOK_REMAINING_PATTERN' do
      it 'captures remaining count' do
        result = 'You must bundle and deliver 7 more items'
        match = result.match(WorkOrders::LOGBOOK_REMAINING_PATTERN)
        expect(match[:remaining]).to eq('7')
      end
    end

    describe 'TAP_HERB_PATTERN' do
      it 'captures full herb name including adjectives' do
        result = 'You tap a dried jadice flower inside your backpack'
        match = result.match(WorkOrders::TAP_HERB_PATTERN)
        expect(match[:item]).to eq('a dried jadice flower')
      end
    end
  end
end
