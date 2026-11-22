# frozen_string_literal: true

require 'ostruct'
require 'time'
require 'tmpdir'
require 'yaml'

require_relative 'spec_helper'

# Minimal stub modules for game interaction
# Stub for script before_dying
def before_dying(&block)
  # No-op for testing
end

# Global ordinals used by workorders
$ORDINALS = %w[first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth twentieth].freeze

# Load WorkOrders class definition (without executing top-level code)
load_lic_class('workorders.lic', 'WorkOrders')

RSpec.describe WorkOrders do
  # More pauses than any example makes; past it the shared pause stub
  # raises, so a loop made only of pauses fails rather than hangs.
  let(:pause_limit) { 500 }
  # Allocate a bare instance without calling initialize
  let(:workorders) { described_class.allocate }
  # The real repair replies (data/base-crafting.yaml), shared with taskmaster.
  let(:repair_replies) { YAML.unsafe_load_file(File.expand_path('../data/base-crafting.yaml', __dir__))['repair_replies'] }

  before(:each) do
    allow(workorders).to receive(:get_data).and_call_original
    allow(workorders).to receive(:get_data).with('crafting').and_return({ 'repair_replies' => repair_replies })
    # World state this spec assumes (reset_data runs first, via spec_helper).
    $right_hand = nil
    $left_hand = nil
    DRRoom.npcs = []
    XMLData.room_title = ''

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

    # Stub methods that would exit or interact with game. A loop of
    # pauses with no way out raises rather than hangs.
    allow(workorders).to receive(:exit)
    allow(workorders).to receive(:fput)
    $hand_ids = {}
    pauses = 0
    allow(workorders).to receive(:pause) { raise "paused #{pauses - 1} times: a loop with no way out" if (pauses += 1) > pause_limit }
  end

  # get_tool as the game answers it where an example keeps no hands of its
  # own: the tool comes into the right hand with an id of its own, the last
  # one having gone to the repairer or been put away (repair_world keeps
  # both hands instead).
  #
  # @param name [String] the tool
  # @return [true]
  def got_into_right_hand(name)
    $right_hand = name
    $hand_ids[name] = "70#{$hand_ids.size}"
    true
  end

  # ===========================================================================
  # Constants - verify frozen pattern constants
  # ===========================================================================
  describe 'constants' do
    it 'defines GIVE_LOGBOOK_SUCCESS_PATTERNS as frozen array' do
      expect(described_class::GIVE_LOGBOOK_SUCCESS_PATTERNS).to be_frozen
      expect(described_class::GIVE_LOGBOOK_SUCCESS_PATTERNS).to include('^You hand')
    end

    it 'defines GIVE_LOGBOOK_RETRY_PATTERNS as frozen array' do
      expect(described_class::GIVE_LOGBOOK_RETRY_PATTERNS).to be_frozen
      expect(described_class::GIVE_LOGBOOK_RETRY_PATTERNS).to include("What is it you're trying to give")
    end

    it 'defines NPC_NOT_FOUND_PATTERN as frozen string' do
      expect(described_class::NPC_NOT_FOUND_PATTERN).to be_frozen
      expect(described_class::NPC_NOT_FOUND_PATTERN).to eq("^What is it you're trying to give")
    end

    it 'defines BUNDLE_SUCCESS_PATTERNS as frozen array' do
      expect(described_class::BUNDLE_SUCCESS_PATTERNS).to be_frozen
      expect(described_class::BUNDLE_SUCCESS_PATTERNS).to include('^You notate the')
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

    it 'defines LOGBOOK_ITEM_PATTERN with named capture' do
      pattern = described_class::LOGBOOK_ITEM_PATTERN
      match = 'This logbook is tracking a work order requiring you to craft a curved metal shovel from any material.'.match(pattern)
      expect(match).not_to be_nil
      expect(match[:item]).to eq('a curved metal shovel')
    end

    it 'captures fabric items when remaining count is on the same line' do
      line = 'This logbook is tracking a work order requiring you to craft a knitted napkin from any fabric.  You must bundle and deliver 1 more within the next 2 roisaen.'
      match = line.match(described_class::LOGBOOK_ITEM_PATTERN)
      expect(match).not_to be_nil
      expect(match[:item]).to eq('a knitted napkin')
      expect(line.match(described_class::LOGBOOK_REMAINING_PATTERN)[:remaining]).to eq('1')
    end

    it 'defines RESUME_LOGBOOK_PATTERNS as frozen array including LOGBOOK_ITEM_PATTERN' do
      expect(described_class::RESUME_LOGBOOK_PATTERNS).to be_frozen
      expect(described_class::RESUME_LOGBOOK_PATTERNS).to include(described_class::LOGBOOK_ITEM_PATTERN)
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
      expect(described_class::VERSION).to eq('1.0.3')
    end
  end

  # ===========================================================================
  # #find_npc - NPC location with proper verification
  # ===========================================================================
  describe '#find_npc' do
    let(:room_list) { [100, 101, 102] }

    context 'when NPC is in current room' do
      before { DRRoom.npcs = ['Jakke'] }

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
      before { DRRoom.npcs = [] }

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
      it 'does not claim success when work order is incomplete' do
        allow(DRCI).to receive(:get_item?).and_return(true)
        allow(DRC).to receive(:release_invisibility)
        allow(DRC).to receive(:bput).and_return("The work order isn't yet complete")
        allow(workorders).to receive(:logbook_remaining).and_return(1)
        expect(workorders).to receive(:stow_tool).with('logbook')
        expect(Lich::Messaging).to receive(:msg).with('bold', /still needs 1 more.*not turned in/)
        expect(Lich::Messaging).not_to receive(:msg).with('plain', 'WorkOrders: Work order completed and turned in')

        workorders.send(:complete_work_order, info)
      end
    end
  end

  # ===========================================================================
  # #logbook_remaining - read remaining item count from work order logbook
  # ===========================================================================
  describe '#logbook_remaining' do
    it 'returns 0 when work order appears complete' do
      expect(DRC).to receive(:bput).with('read my forging logbook', *described_class::READ_LOGBOOK_PATTERNS)
                                   .and_return('This work order appears to be complete.')
      expect(workorders.send(:logbook_remaining, 'forging')).to eq(0)
    end

    it 'returns remaining count from logbook text' do
      expect(DRC).to receive(:bput).with('read my forging logbook', *described_class::READ_LOGBOOK_PATTERNS)
                                   .and_return('You must bundle and deliver 1 more of the ordered item.')
      expect(workorders.send(:logbook_remaining, 'forging')).to eq(1)
    end

    it 'returns nil when response is unreadable' do
      expect(DRC).to receive(:bput).with('read my forging logbook', *described_class::READ_LOGBOOK_PATTERNS)
                                   .and_return('I could not find what you were referring to.')
      expect(workorders.send(:logbook_remaining, 'forging')).to be_nil
    end
  end

  # ===========================================================================
  # #resume_work_order - parse active order from logbook for continue
  # ===========================================================================
  describe '#resume_work_order' do
    let(:recipes) do
      [
        { 'name' => 'a curved metal shovel', 'noun' => 'shovel', 'type' => 'blacksmithing' },
        { 'name' => 'a metal razor', 'noun' => 'razor', 'type' => 'blacksmithing' }
      ]
    end

    before do
      allow(workorders).to receive(:stow_tool)
    end

    it 'returns recipe name and remaining count for an in-progress order' do
      expect(DRCI).to receive(:get_item?).with('forging logbook').and_return(true)
      # bput returns only the matched substring for the first matching pattern
      expect(DRC).to receive(:bput).with('read my forging logbook', *described_class::RESUME_LOGBOOK_PATTERNS)
                                   .and_return('This logbook is tracking a work order requiring you to craft a curved metal shovel from any')
      expect(workorders).to receive(:logbook_remaining).with('forging').and_return(2)
      expect(Lich::Messaging).to receive(:msg).with('plain', 'WorkOrders: Continuing work order for 2 a curved metal shovel')

      expect(workorders.send(:resume_work_order, 'forging', recipes)).to eq(['a curved metal shovel', 2])
    end

    it 'parses knitted fabric orders from the truncated bput match' do
      recipes = [{ 'name' => 'a knitted napkin', 'noun' => 'napkin', 'type' => 'tailoring', 'chapter' => 5 }]
      expect(DRCI).to receive(:get_item?).with('outfitting logbook').and_return(true)
      expect(DRC).to receive(:bput).with('read my outfitting logbook', *described_class::RESUME_LOGBOOK_PATTERNS)
                                   .and_return('This logbook is tracking a work order requiring you to craft a knitted napkin from any')
      expect(workorders).to receive(:logbook_remaining).with('outfitting').and_return(1)
      expect(Lich::Messaging).to receive(:msg).with('plain', 'WorkOrders: Continuing work order for 1 a knitted napkin')

      expect(workorders.send(:resume_work_order, 'outfitting', recipes)).to eq(['a knitted napkin', 1])
    end

    it 'returns quantity 0 when logbook order appears complete' do
      expect(DRCI).to receive(:get_item?).with('forging logbook').and_return(true)
      expect(DRC).to receive(:bput).with('read my forging logbook', *described_class::RESUME_LOGBOOK_PATTERNS)
                                   .and_return('This work order appears to be complete.')
      expect(Lich::Messaging).to receive(:msg).with('plain', 'WorkOrders: Logbook order complete - turning in')

      expect(workorders.send(:resume_work_order, 'forging', recipes)).to eq([nil, 0])
    end

    it 'exits when logbook has no in-progress work order' do
      expect(DRCI).to receive(:get_item?).with('forging logbook').and_return(true)
      expect(DRC).to receive(:bput).with('read my forging logbook', *described_class::RESUME_LOGBOOK_PATTERNS)
                                   .and_return('This logbook is not currently tracking a work order.')
      expect(Lich::Messaging).to receive(:msg).with('bold', 'WorkOrders: No in-progress work order in forging logbook')
      expect(workorders).to receive(:exit).and_raise(SystemExit)

      expect { workorders.send(:resume_work_order, 'forging', recipes) }.to raise_error(SystemExit)
    end

    it 'exits when logbook item does not match a recipe' do
      expect(DRCI).to receive(:get_item?).with('forging logbook').and_return(true)
      expect(DRC).to receive(:bput).with('read my forging logbook', *described_class::RESUME_LOGBOOK_PATTERNS)
                                   .and_return('This logbook is tracking a work order requiring you to craft a metal unknown widget from any')
      expect(Lich::Messaging).to receive(:msg).with('bold', "WorkOrders: Could not match logbook item 'a metal unknown widget' to a recipe")
      expect(workorders).to receive(:exit).and_raise(SystemExit)

      expect { workorders.send(:resume_work_order, 'forging', recipes) }.to raise_error(SystemExit)
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
  # Reply patterns only match the game's own line
  # ===========================================================================
  # DRC.bput is replaced by a model of lich-5's DRC.bput: String patterns
  # become case-insensitive regexes, the incoming lines are read in order, the
  # first line matching any pattern wins, and bput returns the matched text
  # (or '' when nothing matches). Another player's speech, ESP or whisper that
  # happens to contain a reply's words must not be taken for the reply.
  describe 'reply patterns and other players' do
    let(:bput_log) { [] }
    let(:reply_queues) { [] }
    let(:failure_text) { 'The work order requires items of a higher quality.' }

    before do
      allow(DRC).to receive(:bput) do |command, *patterns|
        bput_log << [command, patterns]
        model_bput(next_reply(command), patterns)
      end
      allow(DRCI).to receive(:dispose_trash)
      allow(DRCI).to receive(:stow_hands)
      allow(DRCI).to receive(:get_item?).and_return(true)
      allow(DRCI).to receive(:put_away_item?).and_return(true)
      allow(DRCI).to receive(:exists?).and_return(false)
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCC).to receive(:find_shaping_room)
      allow(DRCC).to receive(:find_sewing_room)
      allow(DRCM).to receive(:ensure_copper_on_hand)
      allow(DRCT).to receive(:order_item)
      allow(DRCT).to receive(:walk_to)
      allow(DRCT).to receive(:dispose)
      allow(DRC).to receive(:wait_for_script_to_complete)
      allow(Lich::Messaging).to receive(:msg)
    end

    def model_bput(lines, patterns)
      regexes = patterns.flatten.map { |item| item.is_a?(Regexp) ? item : /#{item}/i }
      lines.each do |line|
        regexes.each do |regex|
          match = line.match(regex)
          return match.to_a.first if match
        end
      end
      ''
    end

    # Queue the incoming lines for each call of a command starting with
    # `prefix`; the last call's lines repeat once the queue runs out.
    def reply(prefix, *calls)
      reply_queues << [prefix, calls]
    end

    def next_reply(command)
      entry = reply_queues.find { |prefix, _| command.start_with?(prefix) }
      return [] unless entry

      calls = entry[1]
      calls.size > 1 ? calls.shift : calls.first
    end

    def sent?(prefix)
      bput_log.any? { |command, _| command.start_with?(prefix) }
    end

    def patterns_for(prefix)
      bput_log.find { |command, _| command.start_with?(prefix) }&.last
    end

    def player_lines(text)
      [%([General][Mallory] "#{text}"), %(Mallory says, "#{text}"), %(Mallory whispers, "#{text}")]
    end

    describe '#bundle_item' do
      it 'still throws the item away on the game line' do
        reply('bundle', [failure_text])
        expect(DRCI).to receive(:dispose_trash).with('gloves', nil, nil)

        workorders.send(:bundle_item, 'gloves', 'engineering')
      end

      it 'keeps the item when another player says the failure text' do
        player_lines(failure_text).each do |line|
          reply_queues.clear
          reply('bundle', [line, 'You notate the gloves in the logbook then bundle it up for delivery.'])
          workorders.send(:bundle_item, 'gloves', 'engineering')
        end
        expect(DRCI).not_to have_received(:dispose_trash)
      end
    end

    describe '#remedy_items bundle' do
      let(:recipe) { { 'chapter' => 1, 'name' => 'blister cream', 'herb1' => 'jadice flower', 'herb2' => nil, 'container' => 'bowl', 'noun' => 'salve' } }
      let(:info) { { 'stock-room' => 100, 'logbook' => 'alchemy', 'catalyst' => 'coal' } }

      before do
        allow(workorders).to receive(:count_combine_rem)
        allow(workorders).to receive(:stow_tool)
        # remedy left the salve in hand, its success signal.
        allow(DRCI).to receive(:in_hands?).with('salve').and_return(true)
      end

      it 'still disposes and stops on the game line' do
        reply('bundle', [failure_text])
        expect { workorders.send(:remedy_items, info, {}, recipe, 1) }.not_to raise_error
        expect(DRCI).to have_received(:dispose_trash).with('salve', nil, nil)
      end

      it 'notates and stows the logbook when another player says the failure text or "you put"' do
        (player_lines(failure_text) + player_lines('you put it where?')).each do |line|
          reply_queues.clear
          reply('bundle', [line, 'You notate the salve in the logbook then bundle it up for delivery.'])
          expect { workorders.send(:remedy_items, info, {}, recipe, 1) }.not_to raise_error
        end
        expect(DRCI).not_to have_received(:dispose_trash).with('salve', any_args)
        expect(DRCI).to have_received(:put_away_item?).with('logbook').exactly(6).times
      end
    end

    # remedy.lic gives no exit status; the product it leaves in hand is its
    # success signal. Hand names are DRC's: the product
    # line 25:52559 ("You get some plovik unguent from inside a diamondique
    # large mortar ...") and the tools remedy holds while it crafts.
    describe '#remedy_items when remedy leaves no product in hand' do
      let(:recipes) { YAML.load_file(File.expand_path('../data/base-recipes.yaml', __dir__), aliases: true)['crafting_recipes'] }
      let(:chest_unguent) { recipes.find { |recipe| recipe['name'] == 'some chest unguent' } }
      let(:blister_cream) { recipes.find { |recipe| recipe['name'] == 'some blister cream' } }
      let(:info) { { 'stock-room' => 100, 'logbook' => 'alchemy', 'catalyst' => 'coal nugget' } }
      # CODE-DERIVED: no log has a bundle reply; this one only has to match
      # '^You notate' (workorders.lic:843).
      let(:notated) { ReplayGame.code('You notate the unguent in the logbook then bundle it up for delivery.', from: 'workorders.lic:843').text }
      let(:remedy_hands) { [] }

      before do
        allow(workorders).to receive(:count_combine_rem)
        allow(workorders).to receive(:stow_tool)
        allow(workorders).to receive(:exit).and_raise(SystemExit)
        allow(DRCI).to receive(:in_hands?) { |item| ReplayCommons.held?(item) }
        # Each remedy run leaves the next hands of remedy_hands.
        allow(DRC).to receive(:wait_for_script_to_complete) do |_name, _args|
          $left_hand, $right_hand = remedy_hands.shift
        end
        reply('bundle', [notated])
      end

      it 'bundles the product when remedy leaves it in hand, with the remedy arguments of today' do
        remedy_hands << ['plovik unguent', nil]
        # A guard that fires here would exit; not_to raise_error turns that
        # into a failure instead of a silent end of the whole run.
        expect { workorders.send(:remedy_items, info, {}, chest_unguent, 1) }.not_to raise_error

        expect(DRC).to have_received(:wait_for_script_to_complete)
          .with('remedy', ['remedies', 3, 'some chest unguent', 'plovik', 'na', 'coal nugget', 'mortar', 'unguent'])
        expect(sent?('bundle my unguent with logbook')).to be(true)
        expect(Lich::Messaging).not_to have_received(:msg).with('bold', /did not leave/)
      end

      it 'bundles the product from the right hand too, with a tool in the left' do
        remedy_hands << ['diamondique mortar', 'plovik unguent']
        expect { workorders.send(:remedy_items, info, {}, chest_unguent, 1) }.not_to raise_error

        expect(sent?('bundle my unguent with logbook')).to be(true)
        expect(Lich::Messaging).not_to have_received(:msg).with('bold', /did not leave/)
      end

      it 'stops before the logbook when remedy leaves only its tools in hand' do
        remedy_hands << %w[pestle diamondique\ mortar]
        expect { workorders.send(:remedy_items, info, {}, chest_unguent, 1) }.to raise_error(SystemExit)

        expect(Lich::Messaging).to have_received(:msg)
          .with('bold', 'WorkOrders: remedy did not leave some chest unguent (unguent) in hand. Stopping.')
        expect(DRCI).not_to have_received(:get_item?)
        expect(bput_log).to be_empty
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'stops when remedy leaves both hands empty' do
        remedy_hands << [nil, nil]
        expect { workorders.send(:remedy_items, info, {}, chest_unguent, 1) }.to raise_error(SystemExit)
        expect(bput_log).to be_empty
      end

      it 'checks the two-herb call (workorders.lic:833) the same way' do
        remedy_hands << [nil, nil]
        expect { workorders.send(:remedy_items, info, {}, blister_cream, 1) }.to raise_error(SystemExit)

        expect(DRC).to have_received(:wait_for_script_to_complete)
          .with('remedy', ['remedies', 2, 'some blister cream', 'red flower', 'nemoih', 'coal nugget', 'mortar', 'cream'])
        expect(Lich::Messaging).to have_received(:msg)
          .with('bold', 'WorkOrders: remedy did not leave some blister cream (cream) in hand. Stopping.')
      end

      it 'bundles the first remedy of a batch and stops when the second leaves nothing' do
        remedy_hands << ['plovik unguent', nil] << [nil, 'mixing stick'] << ['plovik unguent', nil]
        expect { workorders.send(:remedy_items, info, {}, chest_unguent, 3) }.to raise_error(SystemExit)

        expect(DRC).to have_received(:wait_for_script_to_complete).with('remedy', anything).twice
        expect(bput_log.map(&:first)).to eq(['bundle my unguent with logbook'])
        expect(DRCI).to have_received(:put_away_item?).with('logbook').once
      end

      it 'does not take a different remedy in hand for the product' do
        remedy_hands << ['belradi elixir', nil]
        expect { workorders.send(:remedy_items, info, {}, chest_unguent, 1) }.to raise_error(SystemExit)
      end
    end

    describe '#shape_items lumber count' do
      let(:materials_info) { { 'stock-name' => 'maple', 'stock-number' => 5, 'stock-volume' => 20 } }
      let(:recipe) { { 'chapter' => 1, 'name' => 'a wood bowl', 'noun' => 'bowl', 'volume' => 10 } }
      let(:info) { { 'stock-room' => 100, 'part-room' => 101 } }

      before { allow(workorders).to receive(:stow_tool) }

      it 'does not buy stock when another player says "I could not"' do
        player_lines('I could not believe it').each do |line|
          reply_queues.clear
          reply('count my maple lumber', [line, 'You count out 20 pieces of lumber remaining.'], ['You count out 20 pieces of lumber remaining.'])
          workorders.send(:shape_items, info, materials_info, recipe, 1)
        end
        expect(DRCT).not_to have_received(:order_item)
      end

      it 'buys stock when the real count is short even if another player names a big count' do
        reply('count my maple lumber', [player_lines('you count 99 of them').first, 'You count out 5 pieces of lumber remaining.'],
              ['You count out 25 pieces of lumber remaining.'])
        workorders.send(:shape_items, info, materials_info, recipe, 1)
        expect(DRCT).to have_received(:order_item).with(100, 5).once
      end

      it 'waits for the game reply to stow feet, not a player line' do
        workorders.instance_variable_set(:@retain_crafting_materials, true)
        reply('count my maple lumber', ['You count out 20 pieces of lumber remaining.'])
        workorders.send(:shape_items, info, materials_info, recipe, 1)
        patterns = patterns_for('stow feet')
        player_lines('what do you put there?').each { |line| expect(model_bput([line], patterns)).to eq('') }
        expect(model_bput(["Stow what?  Type 'STOW HELP' for details."], patterns)).to eq('Stow what')
        expect(model_bput(['You put your lumber in your backpack.'], patterns)).to eq('You put')
      end
    end

    describe '#tinker_items lumber count' do
      let(:materials_info) { { 'stock-name' => 'maple', 'stock-number' => 5, 'stock-volume' => 20 } }
      let(:recipe) { { 'chapter' => 1, 'name' => 'a wood clock', 'noun' => 'clock', 'volume' => 10 } }
      let(:info) { { 'stock-room' => 100, 'trash-room' => 200, 'logbook' => 'engineering' } }

      before do
        workorders.instance_variable_set(:@workorders_materials, {})
        allow(workorders).to receive(:bundle_item)
      end

      it 'buys only the first lot when another player says "I could not find"' do
        reply('count my maple lumber', [player_lines('I could not find it').last, 'You count out 20 pieces of lumber remaining.'],
              ['You count out 20 pieces of lumber remaining.'])
        workorders.send(:tinker_items, info, materials_info, recipe, 1)
        expect(DRCT).to have_received(:order_item).with(100, 5).once
      end
    end

    describe '#carve_items stock replies' do
      let(:materials_info) { { 'stock-name' => 'maple', 'stock-number' => 5, 'stock-volume' => 20 } }
      let(:info) { { 'stock-room' => 100, 'polish-room' => 102, 'polish-number' => 7, 'logbook' => 'engineering' } }

      before do
        allow(workorders).to receive(:stow_tool)
        allow(workorders).to receive(:bundle_item)
        allow(workorders).to receive(:checkleft)
        allow(workorders).to receive(:checkright)
        allow(DRCI).to receive(:get_item?).with('surface polish').and_return(false)
      end

      it 'goes to the shaping room when another player says "You are not strong"' do
        recipe = { 'chapter' => 1, 'name' => 'a stone bowl', 'noun' => 'bowl', 'volume' => 10, 'material' => 'stone' }
        reply('get maple', [player_lines('You are not strong enough for that').first, 'You get a maple rock.'])
        workorders.send(:carve_items, info, materials_info, recipe, 1)
        expect(DRCC).to have_received(:find_shaping_room)
      end

      it 'does not buy bone stock when another player says "I could not"' do
        recipe = { 'chapter' => 1, 'name' => 'a bone comb', 'noun' => 'comb', 'volume' => 10, 'material' => 'bone' }
        reply('count my maple stack', [player_lines('I could not')[1], 'You count out 20 pieces of bone remaining.'],
              ['You count out 20 pieces of bone remaining.'])
        workorders.send(:carve_items, info, materials_info, recipe, 1)
        expect(DRCT).not_to have_received(:order_item).with(100, 5)
      end

      it 'keeps the surface polish when another player names a low count' do
        recipe = { 'chapter' => 1, 'name' => 'a stone bowl', 'noun' => 'bowl', 'volume' => 10, 'material' => 'stone' }
        allow(DRCI).to receive(:get_item?).with('surface polish').and_return(true)
        reply('count my polish', [player_lines('The surface polish has 1 uses remaining')[1], 'The surface polish has 20 uses remaining.'])
        workorders.send(:carve_items, info, materials_info, recipe, 1)
        expect(DRCI).not_to have_received(:dispose_trash).with('polish', any_args)
        expect(DRCT).not_to have_received(:order_item).with(102, 7)
      end

      it 'still replaces the surface polish on a real low count' do
        recipe = { 'chapter' => 1, 'name' => 'a stone bowl', 'noun' => 'bowl', 'volume' => 10, 'material' => 'stone' }
        allow(DRCI).to receive(:get_item?).with('surface polish').and_return(true)
        reply('count my polish', ['The surface polish has 2 uses remaining.'])
        workorders.send(:carve_items, info, materials_info, recipe, 1)
        expect(DRCI).to have_received(:dispose_trash).with('polish', nil, nil)
        expect(DRCT).to have_received(:order_item).with(102, 7)
      end
    end

    describe '#count_combine_rem herb tap and count' do
      before do
        workorders.instance_variable_set(:@workorders_override_store, nil)
        allow(workorders).to receive(:stow_tool)
      end

      it 'does not buy herbs when another player says "you tap ... inside your" before the real tap' do
        reply('tap first flower', [player_lines('you tap it inside your pack').first, 'You tap some jadice flowers inside your backpack.'])
        reply('tap second flower', ['I could not find what you were referring to.'])
        reply('count first flower', ['You count out 25 pieces.'])
        workorders.send(:count_combine_rem, 100, 1, 'jadice flower', 11)
        expect(DRCT).not_to have_received(:order_item)
      end

      it 'does not buy herbs when another player names a low herb count' do
        reply('tap first flower', ['You tap some jadice flowers inside your backpack.'])
        reply('tap second flower', ['I could not find what you were referring to.'])
        reply('count first flower', [player_lines('You count out 1 pieces.')[1], 'You count out 25 pieces.'])
        workorders.send(:count_combine_rem, 100, 1, 'jadice flower', 11)
        expect(DRCT).not_to have_received(:order_item)
      end

      it 'still buys herbs on a real short count' do
        reply('tap first flower', ['You tap some jadice flowers inside your backpack.'])
        reply('tap second flower', ['I could not find what you were referring to.'])
        reply('count first flower', ['You count out 5 pieces.'])
        workorders.send(:count_combine_rem, 100, 1, 'jadice flower', 11)
        expect(DRCT).to have_received(:order_item).with(100, 11).once
      end
    end

    describe '#complete_work_order give reply' do
      let(:info) { { 'npc-rooms' => [100], 'npc_last_name' => 'Jakke', 'npc' => 'Jakke', 'logbook' => 'engineering' } }

      before do
        allow(workorders).to receive(:find_npc).and_return(true)
        allow(workorders).to receive(:stow_tool)
        allow(DRC).to receive(:release_invisibility)
      end

      it 'does not report a turn-in when another player says "you can"' do
        reply('give logbook', [player_lines('you can do it').first, "The work order isn't yet complete."])
        workorders.send(:complete_work_order, info)
        expect(Lich::Messaging).not_to have_received(:msg).with('plain', 'WorkOrders: Work order completed and turned in')
        expect(Lich::Messaging).to have_received(:msg).with('bold', /not turned in/)
      end
    end

    describe '#logbook_remaining' do
      let(:complete_line) do
        'This logbook is tracking a work order requiring you to craft a wood haircomb.  This work order appears to be complete.  ' \
          'Now give it to a crafting trainer within the next 96 roisaen to receive payment.'
      end
      let(:remaining_line) do
        'This logbook is tracking a work order requiring you to craft a wood haircomb from any material.  ' \
          'You must bundle and deliver 1 more within the next 101 roisaen.'
      end

      it 'still reads the count from the real logbook line' do
        reply('read my engineering logbook', [remaining_line])
        expect(workorders.send(:logbook_remaining, 'engineering')).to eq(1)
        reply_queues.clear
        reply('read my engineering logbook', [complete_line])
        expect(workorders.send(:logbook_remaining, 'engineering')).to eq(0)
      end

      it 'ignores a remaining count another player says' do
        player_lines('You must bundle and deliver 9 more').each do |line|
          reply_queues.clear
          reply('read my engineering logbook', [line, complete_line])
          expect(workorders.send(:logbook_remaining, 'engineering')).to eq(0)
        end
      end
    end

    describe '#forge_items_with_own_ingot deed packet' do
      let(:materials_info) { { 'stock-volume' => 50 } }
      let(:item) { { 'name' => 'short sword', 'volume' => 5, 'noun' => 'sword' } }
      let(:complete_line) { 'This logbook is tracking a work order requiring you to craft a short sword.  This work order appears to be complete.' }

      before do
        workorders.instance_variable_set(:@use_own_ingot_type, 'bronze')
        workorders.instance_variable_set(:@deed_own_ingot, true)
        workorders.instance_variable_set(:@deeds_room, 300)
        workorders.instance_variable_set(:@deeds_number, 4)
        reply('analyze my ingot', ['About 50 volume of metal.'])
        reply('read my forging logbook', [complete_line])
      end

      it 'does not buy a deed packet when another player says "I could not find what you were referring to"' do
        reply('look my deed packet', [player_lines('I could not find what you were referring to').first, 'You count 5 deed claim forms remaining.'])
        workorders.send(:forge_items_with_own_ingot, { 'logbook' => 'forging' }, materials_info, item, 1)
        expect(DRCT).not_to have_received(:order_item).with(300, 4)
      end

      it 'still buys a deed packet when there is none' do
        reply('look my deed packet', ['I could not find what you were referring to.'])
        workorders.send(:forge_items_with_own_ingot, { 'logbook' => 'forging' }, materials_info, item, 1)
        expect(DRCT).to have_received(:order_item).with(300, 4)
      end
    end

    describe '#sew_items and #knit_items existing stock' do
      let(:materials_info) { { 'stock-name' => 'burlap', 'stock-number' => 9 } }
      let(:info) { { 'stock-room' => 100 } }

      before { allow(workorders).to receive(:stow_tool) }

      it 'reads the real cloth count, not a count another player says' do
        recipe = { 'chapter' => 1, 'name' => 'a burlap sack', 'noun' => 'sack', 'volume' => 10 }
        reply('get burlap cloth', ['You get some burlap cloth from inside your backpack.'], ['What were you referring to?'])
        reply('count my burlap cloth', [player_lines('you count out 50 yards').first, 'You count out 10 yards of material there.'])
        expect(workorders).to receive(:order_fabric).with(100, 2, 9, 'burlap cloth')
        workorders.send(:sew_items, info, materials_info, recipe, 3)
      end

      it 'treats "What were you" as no cloth even if another player says "you get" first' do
        recipe = { 'chapter' => 1, 'name' => 'a burlap sack', 'noun' => 'sack', 'volume' => 10 }
        reply('get burlap cloth', [player_lines('did you get it?').first, 'What were you referring to?'])
        expect(workorders).to receive(:order_fabric).with(100, 3, 9, 'burlap cloth')
        workorders.send(:sew_items, info, materials_info, recipe, 3)
        expect(sent?('count my burlap cloth')).to be false
      end

      it 'treats "What were you" as no yarn even if another player says "you get" first' do
        recipe = { 'chapter' => 1, 'name' => 'a knitted napkin', 'noun' => 'napkin', 'volume' => 100 }
        reply('get yarn', [player_lines('did you get it?').last, 'What were you referring to?'])
        expect(workorders).to receive(:order_fabric).with(100, 1, 9, 'yarn')
        workorders.send(:knit_items, info, materials_info, recipe, 1)
        expect(sent?('count my yarn')).to be false
      end
    end
  end

  # ===========================================================================
  # #work_order_recipes - which base-recipes a work order may name
  # ===========================================================================
  # base-recipes.yaml holds remedies made from stand-alone instructions
  # (`instructions: true`, no chapter). remedy_items calls remedy.lic with the
  # 8-argument book form and the recipe's chapter, so a work order must never
  # pick one, even when a workorder_recipes pattern matches its name.
  describe '#work_order_recipes' do
    let(:recipes) { YAML.load_file(File.expand_path('../data/base-recipes.yaml', __dir__), aliases: true)['crafting_recipes'] }
    let(:instructions_names) { recipes.select { |recipe| recipe['instructions'] && recipe['type'] == 'remedies' }.map { |recipe| recipe['name'] } }
    let(:disciplines) { %w[blacksmithing weaponsmithing tailoring shaping carving remedies artificing tinkering] }

    before do
      workorders.instance_variable_set(:@recipe_overrides, {})
      workorders.instance_variable_set(:@carving_type, 'stone')
    end

    # The recipe names work_order_recipes picks with the given data and
    # workorder_recipes setting.
    #
    # @param discipline [String]
    # @param data [Array<Hash>] the crafting_recipes get_data hands back
    # @param overrides [Hash{String => Array<String>}] workorder_recipes
    # @return [Array<String>]
    def picked(discipline, data: recipes, overrides: {})
      $test_data.recipes = OpenStruct.new(crafting_recipes: data)
      workorders.instance_variable_set(:@recipe_overrides, overrides)
      workorders.send(:work_order_recipes, discipline).map { |recipe| recipe['name'] }
    end

    it 'reads the four instructions remedies from base-recipes.yaml, so these examples test something' do
      expect(instructions_names).to eq(['a clubmoss liniment', 'a woundwort curative', 'a marram salve', 'a flamestalk potion'])
    end

    it 'never picks an instructions remedy, whatever workorder_recipes pattern matches its name' do
      [['salve'], ['marram'], ['liniment', 'curative', 'potion'], ['a '], ['.']].each do |patterns|
        names = picked('remedies', overrides: { 'remedies' => patterns })
        expect(names & instructions_names).to eq([])
      end
    end

    it 'never picks a weapon made from instructions, whatever workorder_recipes pattern matches its name' do
      weapons = recipes.select { |recipe| recipe['instructions'] && recipe['type'] == 'weaponsmithing' }.map { |recipe| recipe['name'] }
      expect(weapons).to include('a metal sterak axe')
      [{}, { 'weaponsmithing' => ['.'] }, { 'weaponsmithing' => ['sterak', 'naginata'] }].each do |overrides|
        expect(picked('weaponsmithing', overrides: overrides) & weapons).to eq([]), overrides.inspect
      end
    end

    it 'still picks the book remedies a workorder_recipes pattern matches' do
      expect(picked('remedies', overrides: { 'remedies' => ['salve'] }))
        .to eq(recipes.select { |recipe| recipe['type'] == 'remedies' && recipe['chapter'] && recipe['name'] =~ /salve/i }.map { |recipe| recipe['name'] })
      expect(picked('remedies', overrides: { 'remedies' => ['salve'] })).to include('some itch salve', 'some wart salve')
    end

    it 'picks the work_order recipes of a discipline without workorder_recipes' do
      expect(picked('remedies')).to include('some blister cream')
      expect(picked('remedies')).not_to include('some wart salve')
    end

    # The selection workorders.lic:152-158 made inline at 03f11b54, before
    # this layer moved it into #work_order_recipes, copied verbatim with the
    # instance variables as parameters. It is the oracle the extracted code is
    # held to, on base-recipes.yaml as it was then (without the instructions
    # recipes).
    #
    # @param discipline [String]
    # @param recipe_overrides [Hash{String => Array<String>}] workorder_recipes
    # @param carving_type [String] carving_workorder_material_type
    # @return [Array<String>] the recipe names
    def picked_at_03f11b54(discipline, recipe_overrides, carving_type)
      crafting_recipes = recipes.reject { |recipe| recipe['instructions'] }
      selected = if recipe_overrides[discipline]
                   crafting_recipes.select { |recipe| recipe['type'] =~ /#{discipline}/i && recipe_overrides[discipline].find { |name| recipe['name'] =~ /#{name}/i } }
                 else
                   crafting_recipes.select { |recipe| recipe['work_order'] && recipe['type'] =~ /#{discipline}/i }
                 end
      selected = selected.select { |x| x['material'] == carving_type } if discipline == 'carving'
      selected.map { |recipe| recipe['name'] }
    end

    it 'picks for every discipline and pattern what workorders.lic picked before the instructions remedies were added' do
      overrides_tried = [{}, { 'remedies' => ['salve'] }, { 'remedies' => ['.'] }, disciplines.to_h { |discipline| [discipline, ['a ']] },
                         disciplines.to_h { |discipline| [discipline, ['.']] }]
      overrides_tried.each do |overrides|
        disciplines.each do |discipline|
          expect(picked(discipline, overrides: overrides)).to eq(picked_at_03f11b54(discipline, overrides, 'stone')), "#{discipline} #{overrides}"
        end
      end
    end

    it 'keeps a workorder_recipes pattern to its own discipline, though it matches names of others' do
      everything = { 'remedies' => ['.'] }
      expect(picked('remedies', overrides: everything)).to eq(recipes.select { |recipe| recipe['type'] == 'remedies' && !recipe['instructions'] }.map { |recipe| recipe['name'] })
      expect(picked('shaping', overrides: { 'shaping' => ['salve'] })).to be_empty
    end

    it 'keeps only the carving_workorder_material_type material for carving' do
      names = picked('carving', overrides: {})
      stone = recipes.select { |recipe| recipe['work_order'] && recipe['type'] =~ /carving/i && recipe['material'] == 'stone' }
      expect(names).to eq(stone.map { |recipe| recipe['name'] })
      expect(names).not_to be_empty
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
  # A second give bput gave up on may still go through, and its ticket then
  # comes into a hand late, during the next tool's GET. The ticket is never
  # the tool got: a bare GIVE of it would hand the repairer the ticket.
  describe '#got_tool' do
    let(:ticket) { OpenStruct.new(id: '7', noun: 'ticket', name: 'Rangu ticket') }
    let(:hammer) { OpenStruct.new(id: '8', noun: 'hammer', name: 'diagonal-peen hammer') }

    it 'takes the tool, not a ticket that came into a hand with it' do
      allow(workorders).to receive(:held_objects).and_return([ticket, hammer])

      expect(workorders.send(:got_tool, 'hammer', [])).to eq(hammer)
    end

    it 'takes the tool already held, not a ticket new in a hand' do
      allow(workorders).to receive(:held_objects).and_return([ticket, hammer])

      expect(workorders.send(:got_tool, 'hammer', ['8'])).to eq(hammer)
    end

    it 'takes nothing when only a ticket is new and no held object is the tool' do
      allow(workorders).to receive(:held_objects).and_return([ticket])

      expect(workorders.send(:got_tool, 'hammer', [])).to be_nil
    end
  end

  describe '#repair_items' do
    let(:info) do
      {
        'repair-room' => 200,
        'repair-npc'  => 'Rangu'
      }
    end
    let(:tools) { ['hammer', 'tongs'] }
    # More commands than any example here sends (bput_lines).
    let(:bput_limit) { 200 }

    before do
      workorders.instance_variable_set(:@settings, OpenStruct.new(workorders_repair_own_tools: false))
    end

    # What DRC.bput hands back: the text the first given pattern (a String
    # is /string/i) matches in the next line the game sends, '' if none
    # (once the lines run out, as on bput's timeout). More than bput_limit
    # commands raise, so a loop with no way out fails rather than hangs.
    def bput_lines(*lines)
      sent = 0
      allow(DRC).to receive(:bput) do |_command, *patterns|
        raise "sent #{bput_limit} commands: a loop with no way out" if (sent += 1) > bput_limit

        line = lines.shift.to_s
        hit = patterns.flatten.lazy.map { |pattern| line.match(pattern.is_a?(Regexp) ? pattern : /#{pattern}/i) }.find(&:itself)
        hit ? hit[0] : ''
      end
    end

    # The repairer's room, the bank and the hands, kept as the game keeps
    # them. GIVE <npc> hands over what the right hand holds, and is answered
    # only in the repairer's room ("What is it you're trying to give?"
    # elsewhere): a tool by its next line in answers (a ticket line takes the
    # tool and leaves the ticket in that hand); a ticket by ticket_reply,
    # or else by handing back the oldest tool taken. GET MY <NPC> TICKET puts
    # a stowed ticket in a free hand, the right one first, and is true when a
    # ticket is in a hand afterwards (lich-5 get_item? checks only the
    # noun). SWAP swaps the hands. Each item in a hand has an id. The bank
    # run of DRCM.ensure_copper_on_hand ends at the bank. PUT AWAY <name>
    # (DRCI.put_away_item?) puts away a held item the name fits as the game
    # takes it (the last word its noun, each other word a word of its name:
    # 'ticket' any ticket, 'clerk ticket' a clerk's), the right hand first;
    # a stowed <npc> ticket counts as carried again. Each command is
    # logged with the room it was sent in. look is the ticket look's line,
    # or its lines in turn (raising when they run out). A ticket held before
    # the run brings back back. Every command the world answers (each walk,
    # bank run, get_tool, stow_tool, GET, PUT AWAY, bput and pause) is a
    # step, and more than max_steps raise, as do more than max_gets GETs:
    # so a loop with no way out, whether it GETs or not, fails rather than
    # hangs. An example that stubs pause again bounds its own pauses. swap
    # false: SWAP moves nothing. stuck: names that will not be stowed.
    #
    # @return [Hash] :log ([room, command, line]), :tickets (stowed count)
    def repair_world(npc:, room:, answers: {}, tickets: 0, held: {}, look: '', ticket_reply: nil, withdraw: true, back: 'diagonal-peen hammer', max_gets: 40,
                     max_steps: 300, swap: true, stuck: [])
      world = { room: nil, tickets: tickets, taken: [], log: [], ids: 0, gets: 0, steps: 0 }
      step = -> { raise "no way out after #{max_steps} steps" if (world[:steps] += 1) > max_steps }
      $hand_ids = {}
      hold = lambda do |hand, name|
        hand == :right ? ($right_hand = name) : ($left_hand = name)
        $hand_ids[name] = (world[:ids] += 1).to_s if name
      end
      free = -> { [:right, :left].find { |hand| (hand == :right ? $right_hand : $left_hand).nil? } }
      ticket = "#{npc} ticket"
      held.each { |hand, name| hold.call(hand, name) }

      allow(DRCT).to receive(:walk_to) do |id|
        step.call
        world[:room] = id
      end
      allow(DRCM).to receive(:ensure_copper_on_hand) do
        step.call
        world[:room] = 'bank'
        withdraw
      end
      allow(workorders).to receive(:pause) { step.call }
      allow(workorders).to receive(:get_tool) do |name|
        step.call
        hold.call(free.call, name) if free.call
      end
      allow(workorders).to receive(:stow_tool) do |name|
        step.call
        hand = [:right, :left].find { |each| (each == :right ? $right_hand : $left_hand) == name } unless stuck.include?(name)
        hold.call(hand, nil) if hand
        !hand.nil?
      end
      allow(DRCI).to receive(:get_item?).with(ticket) do
        step.call
        raise "still collecting after #{max_gets} gets" if (world[:gets] += 1) > max_gets

        if world[:tickets].positive? && free.call
          hold.call(free.call, ticket)
          world[:tickets] -= 1
        end
        [$right_hand, $left_hand].any? { |name| name.to_s.end_with?(' ticket') }
      end
      fits = lambda do |name, held_name|
        *words, noun = name.split
        held_name.to_s.split.last == noun && words.all? { |word| held_name.match?(/\b#{Regexp.escape(word)}\b/i) }
      end
      allow(DRCI).to receive(:put_away_item?) do |name|
        step.call
        hand = [:right, :left].find { |each| fits.call(name, each == :right ? $right_hand : $left_hand) }
        next false unless hand

        world[:tickets] += 1 if (hand == :right ? $right_hand : $left_hand) == ticket
        hold.call(hand, nil)
        true
      end
      allow(DRC).to receive(:bput) do |command, *patterns|
        step.call
        line = case command
               when "give #{npc}"
                 if world[:room] != room then "What is it you're trying to give?"
                 elsif $right_hand == ticket
                   if ticket_reply then ticket_reply
                   else
                     tool = world[:taken].shift || back
                     hold.call(:right, tool)
                     "You hand #{npc} your ticket and are handed back a #{tool}."
                   end
                 elsif $right_hand
                   tool = $right_hand
                   (answers[tool] || []).shift.to_s.tap do |reply|
                     next unless reply.match?(/repair ticket/)

                     world[:taken] << tool
                     hold.call(:right, ticket)
                   end
                 else ''
                 end
               when 'look at my ticket' then look.is_a?(Array) ? (look.shift || raise('looked at the ticket again after the last look')) : look
               when 'swap'
                 next '' unless swap

                 # Each item keeps its id as it changes hands.
                 $right_hand, $left_hand = $left_hand, $right_hand
                 "You move #{$right_hand || 'nothing'} to your right hand."
               else ''
               end
        world[:log] << [world[:room], command, line]
        hit = patterns.flatten.lazy.map { |pattern| line.match(pattern.is_a?(Regexp) ? pattern : /#{pattern}/i) }.find(&:itself)
        hit ? hit[0] : ''
      end
      allow(Lich::Messaging).to receive(:msg)
      world
    end

    # Rangu's answers to a mortar (Hollow Eve 2026, log 6100:9659, 9661).
    let(:quote) { "Rangu looks over the mortar and says, \"That will cost 240 Kronars to repair.  Just give it to me again if you want, and I'll have it ready in 1 roisaen.\"" }
    let(:handed) { "You hand Rangu 240 Kronars and he gives you back a repair ticket.  Rangu says, \"I should be having that done for you in about 1 roisaen.\"" }

    it 'answers each reply through the data patterns: a quote is confirmed (its cost read), no wear is put away' do
      bput_lines(quote, handed, "Rangu shrugs and says, \"There isn't a scratch on that, and I'm not one to rob you.\"")
      allow(DRCI).to receive(:get_item?).with('Rangu ticket').and_return(false)
      allow(DRCI).to receive(:put_away_item?).and_return(true)
      allow(workorders).to receive(:get_tool) { |name| got_into_right_hand(name) }
      allow(workorders).to receive(:stow_tool)
      allow(Lich::Messaging).to receive(:msg)
      expect(workorders).to receive(:confirm_repair).with(info, 'hammer', 240).and_call_original

      workorders.send(:repair_items, info, tools)

      expect(workorders).to have_received(:stow_tool).with('tongs')
      expect(DRCI).to have_received(:put_away_item?).with('ticket').once
    end

    it 'waits for a ticket until its look says it is ready, 30 s at a time' do
      looks = ['Looking at the Rangu ticket you see it is for a steel hammer.',
               'Looking at the Rangu ticket you see it is for a steel hammer.  You recall that your hammer should be ready by now.']
      world = repair_world(npc: 'Rangu', room: 200, tickets: 1, look: looks, back: 'steel hammer')

      workorders.send(:repair_items, info, [])

      expect(workorders).to have_received(:pause).with(30).once
      expect(DRC).to have_received(:bput).with('look at my ticket', any_args).twice
      # Both looks are answered by a pattern, so neither waits out bput's timeout.
      expect(DRC).to have_received(:bput).with('look at my ticket', 'should be ready by now', 'Looking at the').twice
      expect(world[:log].last).to eq([200, 'give Rangu', 'You hand Rangu your ticket and are handed back a steel hammer.'])
    end

    # The shipped data/base-crafting.yaml, as lich-5's SCRIPT_DIR finds it:
    # its read is stubbed, so no example depends on the file system there.
    let(:shipped_path) { '/lich/scripts/data/base-crafting.yaml' }

    # The shipped file holds these replies, or (file:) is read as that
    # whole, or (raises:) its read raises that.
    def ship(replies = repair_replies, raises: nil, file: { 'repair_replies' => replies })
      stub_const('SCRIPT_DIR', '/lich/scripts')
      allow(YAML).to receive(:unsafe_load_file).and_call_original
      read = allow(YAML).to receive(:unsafe_load_file).with(shipped_path)
      raises ? read.and_raise(raises) : read.and_return(file)
    end

    it 'takes every reply from the shipped base-crafting.yaml, and says so once, when the data (a stale data/custom copy) has none' do
      allow(workorders).to receive(:get_data).with('crafting').and_return({ 'stock' => {} })
      ship
      bput_lines(quote, handed, "Rangu shrugs and says, \"There isn't a scratch on that, and I'm not one to rob you.\"")
      allow(DRCI).to receive(:get_item?).with('Rangu ticket').and_return(false)
      allow(DRCT).to receive(:walk_to)
      allow(workorders).to receive(:get_tool) { |name| got_into_right_hand(name) }
      allow(workorders).to receive(:stow_tool)
      allow(Lich::Messaging).to receive(:msg)
      expect(workorders).to receive(:confirm_repair).with(info, 'hammer', 240).and_call_original

      2.times { |run| workorders.send(:repair_items, info, run.zero? ? tools : []) }

      expect(DRCT).to have_received(:walk_to).with(200).twice
      expect(workorders).to have_received(:stow_tool).with('tongs').once
      expect(Lich::Messaging).to have_received(:msg).with('bold', 'WorkOrders: data/custom/base-crafting.yaml has no usable repair_replies quote, prompt, offered, declined, ticket, need_coin, ready, not_ready, ticket_handed, ticket_not_taken (a copy from before they were added?); using the shipped data/base-crafting.yaml\'s. Update that copy.').once
      expect(YAML).to have_received(:unsafe_load_file).with(shipped_path).once
    end

    # Unstubbed: the real shipped file, and a copy of it with a line that only
    # a permissive load reads (lich-5's get_data reads it so), as the file may
    # later gain. A safe load raises on the Date and hides every reply.
    { 'the shipped file' => '', 'the shipped file with a Date in it' => "added_on: 2026-11-21\n" }.each do |label, extra|
      it "reads every repair reply from #{label}, unstubbed" do
        allow(workorders).to receive(:get_data).with('crafting').and_return({ 'stock' => {} })
        allow(Lich::Messaging).to receive(:msg)
        root = Dir.mktmpdir
        FileUtils.mkdir_p(File.join(root, 'data'))
        File.write(File.join(root, 'data', 'base-crafting.yaml'), File.read(File.expand_path('../data/base-crafting.yaml', __dir__)) + extra)
        stub_const('SCRIPT_DIR', root)

        expect(workorders.send(:repair_replies)).to eq(repair_replies)
        expect(workorders.send(:repair_replies_known?)).to be(true)
      end
    end

    # A hand-edited copy whose repair_replies is a list, a pattern or a
    # number has no usable key: every reply comes from the shipped file,
    # rather than a TypeError (or NoMethodError) at the first lookup.
    [['quote', 'prompt'], 'quote', 5].each do |copy|
      it "takes every reply from the shipped base-crafting.yaml, and says so once, when the data's repair_replies is not a mapping (#{copy.inspect})" do
        allow(workorders).to receive(:get_data).with('crafting').and_return({ 'repair_replies' => copy })
        ship
        allow(Lich::Messaging).to receive(:msg)

        expect(workorders.send(:repair_replies)).to eq(repair_replies)
        expect(workorders.send(:repair_replies_known?)).to be(true)
        expect(Lich::Messaging).to have_received(:msg).with('bold', "WorkOrders: data/custom/base-crafting.yaml has no usable repair_replies quote, prompt, offered, declined, ticket, need_coin, ready, not_ready, ticket_handed, ticket_not_taken (a copy from before they were added?); using the shipped data/base-crafting.yaml's. Update that copy.").once
      end
    end

    it 'takes from the shipped file only the keys the copy lacks, keeping its own' do
      # A copy from the first version of repair_replies: no prompt and no
      # ticket replies; its quote, changed to match the cost alone, is kept.
      copy = repair_replies.except('prompt', 'ticket_handed', 'ticket_not_taken').merge('quote' => 'cost [\d,]+ \w+ to repair')
      allow(workorders).to receive(:get_data).with('crafting').and_return({ 'repair_replies' => copy })
      ship
      allow(Lich::Messaging).to receive(:msg)

      expect(workorders.send(:repair_replies)).to eq(copy.merge(repair_replies.slice('prompt', 'ticket_handed', 'ticket_not_taken')))
      expect(workorders.send(:repair_replies)['quote']).to eq('cost [\d,]+ \w+ to repair')
      expect(Lich::Messaging).to have_received(:msg).with('bold', /no usable repair_replies prompt, ticket_handed, ticket_not_taken \(/).once
    end

    it "confirms Fang Cove's prompt through the shipped prompt when the copy lacks it" do
      allow(workorders).to receive(:get_data).with('crafting').and_return({ 'repair_replies' => repair_replies.except('prompt') })
      ship
      bput_lines('Osmandikar says, "If you agree, give it to me again."')
      allow(DRCI).to receive(:get_item?).with('Rangu ticket').and_return(false)
      allow(DRCT).to receive(:walk_to)
      allow(workorders).to receive(:get_tool) { |name| got_into_right_hand(name) }
      allow(workorders).to receive(:stow_tool)
      allow(Lich::Messaging).to receive(:msg)
      expect(workorders).to receive(:confirm_repair).with(info, 'hammer', nil)

      workorders.send(:repair_items, info, ['hammer'])

      expect(workorders).not_to have_received(:stow_tool)
    end

    it 'takes the shipped value for a key of the wrong kind (declined one string, ticket a list, a broken pattern), rather than crashing' do
      copy = repair_replies.merge('declined' => 'scratch', 'ticket' => ['repair ticket'], 'need_coin' => 'more coin (')
      allow(workorders).to receive(:get_data).with('crafting').and_return({ 'repair_replies' => copy })
      ship
      bput_lines("Rangu shrugs and says, \"There isn't a scratch on that, and I'm not one to rob you.\"", quote, handed)
      allow(DRCI).to receive(:get_item?).with('Rangu ticket').and_return(false)
      allow(DRCI).to receive(:put_away_item?).and_return(true)
      allow(DRCT).to receive(:walk_to)
      allow(workorders).to receive(:get_tool) { |name| got_into_right_hand(name) }
      allow(workorders).to receive(:stow_tool)
      allow(Lich::Messaging).to receive(:msg)

      expect { workorders.send(:repair_items, info, %w[hammer tongs]) }.not_to raise_error

      expect(workorders).to have_received(:stow_tool).with('hammer').once
      expect(DRCI).to have_received(:put_away_item?).with('ticket').once
      expect(Lich::Messaging).to have_received(:msg).with('bold', /no usable repair_replies declined, ticket, need_coin \(/).once
    end

    it 'takes the shipped value for an empty list or an empty pattern (offered none, ready blank), and still waits on a ticket not ready' do
      # An empty offered would give with no pattern to answer it (bput waits
      # out its 15 s); an empty ready matches every look, so a ticket not
      # ready would be handed in at once.
      copy = repair_replies.merge('offered' => [], 'ready' => '')
      allow(workorders).to receive(:get_data).with('crafting').and_return({ 'repair_replies' => copy })
      ship
      looks = ['Looking at the Rangu ticket you see it is for a mortar.  You recall that your mortar should be ready any moment now.',
               'Looking at the Rangu ticket you see it is for a mortar.  You recall that your mortar should be ready by now.']
      world = repair_world(npc: 'Rangu', room: 200, answers: { 'mortar' => [quote, handed] }, look: looks)
      expect(workorders).to receive(:confirm_repair).with(info, 'mortar', 240).and_call_original

      workorders.send(:repair_items, info, ['mortar'])

      expect(workorders.send(:repair_replies).values_at('offered', 'ready')).to eq(repair_replies.values_at('offered', 'ready'))
      expect(workorders).to have_received(:pause).with(30).once
      expect(world[:log].last).to eq([200, 'give Rangu', 'You hand Rangu your ticket and are handed back a mortar.'])
      expect(Lich::Messaging).to have_received(:msg).with('bold', /no usable repair_replies offered, ready \(/).once
    end

    every_key = /none for quote, prompt, offered, .*ticket_not_taken; tools are not left for repair or collected\. Update dr-scripts\./
    [['the shipped file cannot be read', { raises: Errno::ENOENT }, every_key],
     ['the shipped file cannot be parsed', { raises: Psych::SyntaxError.new('base-crafting.yaml', 3, 1, 10, 'did not find expected key', 'while parsing a block mapping') }, every_key],
     ['the shipped file has no repair_replies block', { file: { 'stock' => {} } }, every_key],
     ['the shipped file is not a mapping', { file: [1, 2] }, every_key],
     ['the shipped file has declined as one string too', { file: :declined_string }, /none for declined; tools are not left/]].each do |title, shipped, warning|
      it "says so once and leaves no tool for repair when #{title}" do
        allow(workorders).to receive(:get_data).with('crafting').and_return({ 'stock' => {} })
        if shipped[:raises] then ship(raises: shipped[:raises])
        elsif shipped[:file] == :declined_string then ship(repair_replies.merge('declined' => 'scratch'))
        else ship(file: shipped[:file])
        end
        allow(DRCT).to receive(:walk_to)
        allow(DRC).to receive(:bput)
        allow(Lich::Messaging).to receive(:msg)

        2.times { workorders.send(:repair_items, info, tools) }

        expect(DRCT).not_to have_received(:walk_to)
        expect(DRC).not_to have_received(:bput)
        expect(Lich::Messaging).to have_received(:msg).with('bold', warning).once
      end
    end

    # What a town repairer answers a tool it will not take or that needs no
    # repair, as crossing-repair.lic:218 matches them: each is answered by a
    # data pattern (bput hands it back at once, not '' after its 15 s), and
    # the tool is put away with no second give.
    ["Osmandikar says, \"Lucky for you!  That isn't damaged!\"", 'Osmandikar says, "I don\'t work on those here."'].each do |line|
      it "puts the tool away at once on \"#{line[19, 30]}...\"" do
        returned = []
        allow(DRC).to receive(:bput) do |_command, *patterns|
          hit = patterns.flatten.lazy.map { |pattern| line.match(pattern.is_a?(Regexp) ? pattern : /#{pattern}/i) }.find(&:itself)
          (hit ? hit[0] : '').tap { |reply| returned << reply }
        end
        allow(DRCI).to receive(:get_item?).with('Rangu ticket').and_return(false)
        allow(DRCT).to receive(:walk_to)
        allow(workorders).to receive(:get_tool) { |name| got_into_right_hand(name) }
        allow(workorders).to receive(:stow_tool)
        allow(workorders).to receive(:confirm_repair)
        allow(Lich::Messaging).to receive(:msg)

        workorders.send(:repair_items, info, ['hammer'])

        expect(returned).to eq([line[/(Lucky for you!  That isn't damaged!|I don't work on those here)/]])
        expect(workorders).to have_received(:stow_tool).with('hammer').once
        expect(workorders).not_to have_received(:confirm_repair)
        # A tool declined (no wear) is put away quietly; a refusal says so.
        if line.include?('work on')
          expect(Lich::Messaging).to have_received(:msg).with('bold', "WorkOrders: Rangu did not take the hammer for repair (I don't work on those here); putting it away.").once
        else
          expect(Lich::Messaging).not_to have_received(:msg).with('bold', /did not take/)
        end
      end
    end

    it 'says so when a tool gets no answer at all, and puts it away' do
      bput_lines('')
      allow(DRCI).to receive(:get_item?).with('Rangu ticket').and_return(false)
      allow(DRCT).to receive(:walk_to)
      allow(workorders).to receive(:get_tool) { |name| got_into_right_hand(name) }
      allow(workorders).to receive(:stow_tool)
      allow(Lich::Messaging).to receive(:msg)

      workorders.send(:repair_items, info, ['hammer'])

      expect(workorders).to have_received(:stow_tool).with('hammer').once
      expect(Lich::Messaging).to have_received(:msg).with('bold', 'WorkOrders: Rangu did not take the hammer for repair (no answer); putting it away.').once
    end

    # DRC.bput matches each pattern as /pattern/i and hands back the text as
    # the game wrote it; the declined check matches the same way, so a reply
    # in another case than the data's pattern is still declined (quietly),
    # not taken for one it did not know.
    it 'declines a reply whose case differs from the data pattern, as bput matched it' do
      bput_lines("Rangu shrugs and says, \"There isn't a SCRATCH on that, and I'm not one to rob you.\"")
      allow(DRCI).to receive(:get_item?).with('Rangu ticket').and_return(false)
      allow(DRCT).to receive(:walk_to)
      allow(workorders).to receive(:get_tool) { |name| got_into_right_hand(name) }
      allow(workorders).to receive(:stow_tool)
      allow(Lich::Messaging).to receive(:msg)

      workorders.send(:repair_items, info, ['hammer'])

      expect(DRC).to have_received(:bput).with('give Rangu', any_args).once
      expect(workorders).to have_received(:stow_tool).with('hammer').once
      expect(Lich::Messaging).not_to have_received(:msg).with('bold', /did not take/)
    end

    # A data/custom copy may write a pattern in another case than the
    # game's line. bput matches it as /pattern/i and hands back the game's
    # own text, and each check made again on that text (repair_offered?,
    # confirm_repair's arms, the ticket look and the ticket hand-in) matches
    # the same way, so the reply still lands where it belongs: the tool is
    # left, paid for (after a bank run when short), and its ticket handed in.
    [['quote and prompt', { 'quote' => 'COST [\d,]+ \w+ TO REPAIR.*GIVE IT TO ME AGAIN', 'prompt' => 'GIVE IT TO ME AGAIN' }, %i[quote need_coin quote handed]],
     ['ticket', { 'ticket' => 'REPAIR TICKET' }, %i[quote handed]],
     ['need_coin', { 'need_coin' => 'MORE COIN' }, %i[quote need_coin quote handed]],
     ['ready', { 'ready' => 'SHOULD BE READY BY NOW' }, %i[quote handed]],
     ['ticket_handed', { 'ticket_handed' => ['^YOU HAND', 'TAKES YOUR TICKET'] }, %i[quote handed]]].each do |keys, copy, lines|
      it "leaves the tool and hands in its ticket when a data/custom copy writes #{keys} in upper case" do
        allow(workorders).to receive(:get_data).with('crafting').and_return({ 'repair_replies' => repair_replies.merge(copy) })
        answers = lines.map { |line| send(line) }
        world = repair_world(npc: 'Rangu', room: 200, look: rangu_ready, answers: { 'hammer' => answers.dup })

        workorders.send(:repair_items, info, ['hammer'])

        gives = world[:log].filter_map { |_room, command, line| line if command == 'give Rangu' }
        expect(gives).to eq(answers + ['You hand Rangu your ticket and are handed back a hammer.'])
        expect(DRCM).to have_received(:ensure_copper_on_hand).with(2400, anything, anything).exactly(lines.count(:need_coin)).times
        expect(workorders).not_to have_received(:pause).with(30)
        expect(Lich::Messaging).not_to have_received(:msg).with('bold', anything)
        expect([$right_hand, $left_hand, world[:tickets]]).to eq([nil, nil, 0])
      end
    end

    describe 'collecting the tickets' do
      let(:info) { { 'repair-room' => 8776, 'repair-npc' => 'clerk' } }
      let(:ready_look) { 'Looking at the clerk ticket you see it is for a diagonal-peen hammer.  You recall that your hammer should be ready by now.' }
      let(:waiting_look) { 'Looking at the clerk ticket you see it is for a diagonal-peen hammer.  You recall that your hammer should be ready any moment now.' }

      # Scripts the clerk (repair_world, at the clerk's room): turns tickets
      # carried; each look answers with look; a ticket given is answered
      # with give, or, when give hands back a tool, by handing back the
      # diagonal-peen hammer. More than turns GETs raise, and so do more
      # than repair_world's max_steps commands of any kind, so a loop with
      # no way out fails rather than hangs.
      def clerk(look:, give:, turns: 30)
        @world = repair_world(npc: 'clerk', room: 8776, tickets: turns, look: look, max_gets: turns,
                              ticket_reply: give.include?('handed back') ? nil : give)
      end

      # @return [Array<String>] the gives sent, in order
      def gives
        @world[:log].filter_map { |_room, command, _line| command if command.start_with?('give') }
      end

      ['', "What is it you're trying to give?"].each do |answer|
        it "puts away a ticket the clerk does not take (#{answer.empty? ? 'no answer' : answer}), says so once and collects no more" do
          clerk(look: ready_look, give: answer, turns: 5)

          workorders.send(:repair_items, info, [])

          expect(gives).to eq(['give clerk'])
          expect(DRCI).to have_received(:put_away_item?).with('clerk ticket').once
          taken = answer.empty? ? 'no answer' : 'What is it'
          expect(Lich::Messaging).to have_received(:msg).with('bold', "WorkOrders: clerk did not take the clerk ticket (#{taken}): another repairer's, perhaps, such as another society's clerk. Put it away; collecting no more tickets this run. Take it to the repairer who holds that tool, and hand in yourself any more clerk tickets you carry; until then later runs likely stop at it too.").once
          expect(Lich::Messaging).to have_received(:msg).with('plain', 'WorkOrders: Tool repair at NPC completed')
        end
      end

      it 'says so when a ticket the clerk does not take cannot be put away either' do
        clerk(look: ready_look, give: "What is it you're trying to give?", turns: 5)
        allow(DRCI).to receive(:put_away_item?).with('clerk ticket').and_return(false)

        workorders.send(:repair_items, info, [])

        expect(gives).to eq(['give clerk'])
        expect(Lich::Messaging).to have_received(:msg).with('bold', /\AWorkOrders: clerk did not take the clerk ticket \(What is it\): .*\. Could not put it away; collecting no more tickets this run\. Take it to the repairer who holds that tool,/).once
      end

      # A look that never matches ready or not_ready (bput hands back '' after
      # its 15 s each time) is told apart from one that says not ready: the
      # ticket was never shown as not ready, and the wait was longer.
      not_ready = "The clerk ticket is still not ready after 20 waits of 30 s. Put it away; collecting no more tickets this run. Hand it, and any more you carry, in yourself."
      unanswered = "The clerk ticket's look got no answer in 21 looks with 20 waits of 30 s between. Put it away; collecting no more tickets this run. Hand it, and any more you carry, in yourself."
      [['still not ready', [:waiting_look], not_ready],
       ['never answered', [''], unanswered],
       ['not ready once, then never answered', [:waiting_look, ''], not_ready]].each do |title, looks, message|
        it "puts away a ticket whose look is #{title} after 20 waits of 30 s, without handing it in, and says which" do
          clerk(look: '', give: 'You hand the clerk your ticket.', turns: 5)
          answers = looks.map { |look| look.is_a?(Symbol) ? send(look) : look }
          allow(DRC).to receive(:bput).with('look at my ticket', any_args) do |_command, *patterns|
            line = answers.size > 1 ? answers.shift : answers.first
            hit = patterns.lazy.map { |pattern| line.match(/#{pattern}/i) }.find(&:itself)
            hit ? hit[0] : ''
          end
          waits = 0
          allow(workorders).to receive(:pause) { |seconds| (waits += 1) > 25 ? raise("waited #{waits} times") : seconds }

          workorders.send(:repair_items, info, [])

          expect(workorders).to have_received(:pause).with(30).exactly(20).times
          expect(DRC).to have_received(:bput).with('look at my ticket', any_args).exactly(21).times
          expect(gives).to be_empty
          expect(DRCI).to have_received(:put_away_item?).with('clerk ticket').once
          expect(Lich::Messaging).to have_received(:msg).with('bold', "WorkOrders: #{message}").once
        end
      end

      it 'hands in at most 20 tickets in one run, putting the next one away' do
        clerk(look: ready_look, give: 'You hand the clerk your ticket and are handed back a diagonal-peen hammer.', turns: 30)

        workorders.send(:repair_items, info, [])

        expect(gives.size).to eq(20)
        expect(DRCI).to have_received(:put_away_item?).with('clerk ticket').once
        expect(Lich::Messaging).to have_received(:msg).with('bold', /\AWorkOrders: Handed in 20 clerk tickets already\. Put it away;/).once
      end

      # A bare GIVE hands over the right hand, whatever the GET did with the
      # ticket: the ticket goes there, alone, by its id first.
      it 'hands in the ticket, not what the right hand held when collection began (it lands in the left; SWAP moves it)' do
        clerk(look: ready_look, give: 'You hand the clerk your ticket and are handed back a diagonal-peen hammer.', turns: 2)
        @world[:tickets] = 1
        $right_hand = 'steel tongs'
        $hand_ids['steel tongs'] = '900'

        workorders.send(:repair_items, info, [])

        sent = @world[:log].map { |_room, command, line| [command, line] }
        expect(sent).to include(['swap', 'You move clerk ticket to your right hand.'])
        expect(sent).to include(['give clerk', 'You hand clerk your ticket and are handed back a diagonal-peen hammer.'])
        expect(Lich::Messaging).not_to have_received(:msg).with('bold', anything)
        expect(@world[:tickets]).to eq(0)
        # What was held went to the left hand with the SWAP, and is put away
        # with the hammer after the hand-in (stow_tool: the crafting bag or
        # belt), as main put both hands away after each give.
        expect(workorders).to have_received(:stow_tool).with('diagonal-peen hammer').ordered
        expect(workorders).to have_received(:stow_tool).with('steel tongs').ordered
        expect([$right_hand, $left_hand]).to eq([nil, nil])
      end

      # While a clerk ticket is held, GET MY CLERK TICKET answers "You are
      # already holding that." and brings no other (lich-5's get_item? is
      # true all the same): the one held is handed in.
      # A held item of the clerk's name that is no ticket (noun ledger) is not
      # taken for one.
      ['steel tongs', "clerk's ledger"].each do |other|
        it "hands in a clerk ticket already in hand, from either hand, with no GET for it (#{other} in the other)" do
          @world = repair_world(npc: 'clerk', room: 8776, tickets: 0, look: ready_look, held: { right: other, left: 'clerk ticket' })

          workorders.send(:repair_items, info, [])

          sent = @world[:log].map { |_room, command, line| [command, line] }
          expect(sent).to eq([['swap', 'You move clerk ticket to your right hand.'],
                              ['look at my ticket', ready_look],
                              ['give clerk', 'You hand clerk your ticket and are handed back a diagonal-peen hammer.']])
          expect(DRCI).to have_received(:get_item?).once
          expect(workorders).to have_received(:stow_tool).with(other)
          expect(Lich::Messaging).not_to have_received(:msg).with('bold', anything)
          expect([$right_hand, $left_hand, @world[:tickets]]).to eq([nil, nil, 0])
        end
      end

      it 'hands in a clerk ticket that shows in a hand only a moment after the GET, a ticket of another name held' do
        @world = repair_world(npc: 'clerk', room: 8776, tickets: 0, look: ready_look, held: { right: 'Rangu ticket' })
        late = nil
        gets = 0
        # The first GET is true at once on the Rangu ticket's noun; the clerk
        # ticket it brought shows three looks later. A later GET is true only
        # with a ticket still in hand, as lich-5's.
        allow(DRCI).to receive(:get_item?).with('clerk ticket') do
          raise 'still collecting after 3 gets' if (gets += 1) > 3

          late ||= 3
          late == :done ? [$right_hand, $left_hand].any? { |name| name.to_s.end_with?(' ticket') } : true
        end
        allow(workorders).to receive(:pause).with(0.1) do
          next unless late.is_a?(Integer) && (late -= 1).zero?

          late = :done
          $left_hand = 'clerk ticket'
          $hand_ids['clerk ticket'] = '77'
        end

        workorders.send(:repair_items, info, [])

        expect(@world[:log].map { |_room, command, line| [command, line] }).to include(['give clerk', 'You hand clerk your ticket and are handed back a diagonal-peen hammer.'])
        expect(Lich::Messaging).not_to have_received(:msg).with('bold', anything)
      end

      # Not the order a real stream gives (the hand tag comes ahead of the
      # reply text), but ticket_got must not take a tool for the ticket: the
      # hammer of the first hand-in shows in the right hand only after the
      # next GET has put the second ticket in the left.
      it 'takes only a clerk ticket new in a hand for the ticket, not the tool of the last hand-in shown late' do
        @world = repair_world(npc: 'clerk', room: 8776, tickets: 0, look: ready_look)
        carried = 2
        late = nil
        given = []
        ids = 0
        hold = lambda do |hand, name|
          hand == :right ? ($right_hand = name) : ($left_hand = name)
          $hand_ids[name] = "9#{ids += 1}" if name
        end
        allow(DRCI).to receive(:get_item?).with('clerk ticket') do
          raise 'still collecting after 4 gets' if (@world[:gets] += 1) > 4
          next false unless carried.positive?

          carried -= 1
          hold.call($right_hand || late ? :left : :right, 'clerk ticket')
          if late
            hold.call(:right, late)
            late = nil
          end
          true
        end
        allow(DRC).to receive(:bput).with('give clerk', any_args) do |_command, *patterns|
          given << $right_hand
          line = ''
          if $right_hand == 'clerk ticket'
            line = 'You hand the clerk your ticket and are handed back a diagonal-peen hammer.'
            if given.size == 1
              hold.call(:right, nil)
              late = 'diagonal-peen hammer'
            else
              hold.call(:right, 'diagonal-peen hammer')
            end
          end
          hit = patterns.flatten.lazy.map { |pattern| line.match(/#{pattern}/i) }.find(&:itself)
          hit ? hit[0] : ''
        end

        workorders.send(:repair_items, info, [])

        expect(given).to eq(['clerk ticket', 'clerk ticket'])
        # The second ticket, in the left hand, is moved to the right by SWAP.
        expect(@world[:log].map { |_room, command, _line| command }).to eq(['look at my ticket', 'swap', 'look at my ticket'])
        expect(Lich::Messaging).not_to have_received(:msg).with('bold', anything)
        expect([$right_hand, $left_hand, carried]).to eq([nil, nil, 0])
      end

      it 'puts the right hand away first when both hands are full, so the GET finds a free hand' do
        clerk(look: ready_look, give: 'You hand the clerk your ticket and are handed back a diagonal-peen hammer.', turns: 2)
        @world[:tickets] = 1
        $right_hand = 'steel tongs'
        $left_hand = 'leather gloves'

        workorders.send(:repair_items, info, [])

        expect(workorders).to have_received(:stow_tool).with('steel tongs')
        expect(gives).to eq(['give clerk'])
        expect(@world[:tickets]).to eq(0)
        expect(Lich::Messaging).not_to have_received(:msg).with('bold', anything)
      end

      it 'says so, and gets no ticket, when both hands are full and the right one will not go away' do
        @world = repair_world(npc: 'clerk', room: 8776, tickets: 1, look: ready_look, stuck: ['steel tongs'], held: { right: 'steel tongs', left: 'leather gloves' })

        workorders.send(:repair_items, info, [])

        expect(DRCI).not_to have_received(:get_item?)
        expect(gives).to be_empty
        expect(Lich::Messaging).to have_received(:msg).with('bold', 'WorkOrders: Both hands are full and the steel tongs would not go away; collecting no more clerk tickets this run. Hand in yourself any clerk tickets you carry.').once
      end

      # lich-5's get_item? is true on the Rangu ticket's noun, but no clerk
      # ticket is left: the GET brought nothing, which is the end of
      # collection, not a ticket to report or put away.
      it 'ends quietly, handing nothing in and putting nothing away, when a ticket of another name held makes the GET true but nothing new comes' do
        @world = repair_world(npc: 'clerk', room: 8776, tickets: 0, look: ready_look, held: { right: 'Rangu ticket' })

        workorders.send(:repair_items, info, [])

        expect(gives).to be_empty
        expect(DRCI).to have_received(:get_item?).once
        expect(workorders).to have_received(:pause).with(0.1).exactly(10).times
        expect(DRCI).not_to have_received(:put_away_item?)
        expect(Lich::Messaging).not_to have_received(:msg).with('bold', anything)
        expect(Lich::Messaging).to have_received(:msg).with('plain', 'WorkOrders: Tool repair at NPC completed')
        expect($right_hand).to eq('Rangu ticket')
      end

      it 'hands nothing in when the ticket cannot be moved to the right hand' do
        @world = repair_world(npc: 'clerk', room: 8776, tickets: 1, look: ready_look, held: { right: 'steel tongs' }, swap: false)

        workorders.send(:repair_items, info, [])

        expect(gives).to be_empty
        expect(Lich::Messaging).to have_received(:msg).with('bold', 'WorkOrders: Could not move the clerk ticket to your right hand. Put it away; collecting no more tickets this run. Hand it, and any more you carry, in yourself.').once
        expect([$right_hand, $left_hand, @world[:tickets]]).to eq(['steel tongs', nil, 1])
      end

      it 'hands in each ticket the clerk takes, stows the tool, and stops when none is left' do
        clerk(look: ready_look, give: 'You hand the clerk your ticket and are handed back a diagonal-peen hammer.', turns: 3)
        @world[:tickets] = 2

        workorders.send(:repair_items, info, [])

        expect(gives).to eq(['give clerk', 'give clerk'])
        expect(workorders).to have_received(:stow_tool).with('diagonal-peen hammer').twice
        expect(DRCI).not_to have_received(:put_away_item?)
        expect(Lich::Messaging).not_to have_received(:msg).with('bold', anything)
      end
    end

    let(:need_coin) { 'Rangu says, "You will need more coin if I am to be repairing that!"' }
    let(:rangu_ready) { 'Looking at the Rangu ticket you see it is for a hammer.  You recall that your hammer should be ready by now.' }

    it 'walks back to the repairer when a bank top-up fails, so the rest are offered, and the tickets handed in, there' do
      world = repair_world(npc: 'Rangu', room: 200, look: rangu_ready, withdraw: false,
                           answers: { 'hammer' => [quote, handed], 'tongs' => [quote, need_coin], 'shears' => [quote, handed] })

      workorders.send(:repair_items, info, %w[hammer tongs shears])

      gives = world[:log].select { |_room, command, _line| command == 'give Rangu' }
      expect(gives.map(&:first).uniq).to eq([200])
      expect(gives.map(&:last).grep(/handed back/)).to eq(['You hand Rangu your ticket and are handed back a hammer.', 'You hand Rangu your ticket and are handed back a shears.'])
      expect(Lich::Messaging).to have_received(:msg).with('bold', 'WorkOrders: Bank withdrawal failed; skipping tongs repair.')
      expect(Lich::Messaging).not_to have_received(:msg).with('bold', /did not take/)
      expect([$right_hand, $left_hand, world[:tickets]]).to eq([nil, nil, 0])
    end

    # After a bank run the tool is got again: a GET that fails gives nothing
    # more for it (a bare GIVE would hand over whatever the right hand held).
    it 'skips the tool, saying so, with no further give, when the GET after a bank top-up fails' do
      world = repair_world(npc: 'Rangu', room: 200, look: rangu_ready, answers: { 'hammer' => [quote, need_coin, quote, handed] })
      gets = 0
      allow(workorders).to receive(:get_tool).with('hammer') do
        next false if (gets += 1) > 1

        $right_hand = 'hammer'
        $hand_ids['hammer'] = '99'
        true
      end

      workorders.send(:repair_items, info, ['hammer'])

      # The quote and the short-of-coin answer, then nothing more.
      gives = world[:log].filter_map { |_room, command, line| line if command == 'give Rangu' }
      expect(gives).to eq([quote, need_coin])
      expect(Lich::Messaging).to have_received(:msg).with('bold', 'WorkOrders: Could not get the hammer back after the bank run; skipping its repair.').once
    end

    it 'gets the tool again into the right hand after a bank top-up and confirms its repair' do
      world = repair_world(npc: 'Rangu', room: 200, look: rangu_ready, answers: { 'hammer' => [quote, need_coin, quote, handed] })

      workorders.send(:repair_items, info, ['hammer'])

      gives = world[:log].filter_map { |room, command, line| [room, line] if command == 'give Rangu' }
      expect(gives).to eq([[200, quote], [200, need_coin], [200, quote], [200, handed], [200, 'You hand Rangu your ticket and are handed back a hammer.']])
      expect(Lich::Messaging).not_to have_received(:msg).with('bold', anything)
    end

    # confirm_repair's put-away of the new ticket failed: it is still in the
    # right hand when collection begins, and is handed in, not stopped at.
    it 'hands in the repair ticket confirm_repair could not put away, with no GET for it' do
      world = repair_world(npc: 'Rangu', room: 200, look: rangu_ready, answers: { 'hammer' => [quote, handed] })
      allow(DRCI).to receive(:put_away_item?).with('ticket').and_return(false)

      workorders.send(:repair_items, info, ['hammer'])

      gives = world[:log].filter_map { |_room, command, line| line if command == 'give Rangu' }
      expect(gives).to eq([quote, handed, 'You hand Rangu your ticket and are handed back a hammer.'])
      expect(DRCI).to have_received(:get_item?).once
      expect(Lich::Messaging).to have_received(:msg).with('bold', 'WorkOrders: Failed to stow repair ticket').once
      expect(Lich::Messaging).not_to have_received(:msg).with('bold', /did not take|Could not/)
      expect([$right_hand, $left_hand, world[:tickets]]).to eq([nil, nil, 0])
    end

    it 'skips a tool it cannot get, saying so, with no give for it' do
      world = repair_world(npc: 'Rangu', room: 200, look: rangu_ready, answers: { 'tongs' => [quote, handed] })
      allow(workorders).to receive(:get_tool).with('hammer').and_return(false)

      workorders.send(:repair_items, info, %w[hammer tongs])

      gives = world[:log].filter_map { |_room, command, line| line if command == 'give Rangu' }
      expect(gives).to eq([quote, handed, 'You hand Rangu your ticket and are handed back a tongs.'])
      expect(Lich::Messaging).to have_received(:msg).with('bold', 'WorkOrders: Could not get the hammer to leave for repair; skipping it.').once
      expect(Lich::Messaging).not_to have_received(:msg).with('bold', /did not take/)
      expect(workorders).not_to have_received(:stow_tool).with('hammer')
    end

    # A bare GIVE hands over the right hand: a tool the GET put in the left
    # (something held already) is moved to the right by its id first, so
    # the repairer is never handed, quoted for and paid for what was held.
    it 'gives the tool, not what the right hand held when repair began (the tool lands in the left; SWAP moves it)' do
      world = repair_world(npc: 'Rangu', room: 200, look: rangu_ready, held: { right: 'steel broadsword' }, answers: { 'hammer' => [quote, handed] })

      workorders.send(:repair_items, info, ['hammer'])

      sent = world[:log].map { |_room, command, line| [command, line] }
      expect(sent.first(3)).to eq([['swap', 'You move hammer to your right hand.'], ['give Rangu', quote], ['give Rangu', handed]])
      expect(sent.last).to eq(['give Rangu', 'You hand Rangu your ticket and are handed back a hammer.'])
      expect(Lich::Messaging).not_to have_received(:msg).with('bold', anything)
      expect(world[:tickets]).to eq(0)
    end

    it 'gives the next tool, not the last one, after a confirming give that got no answer left that one in the right hand' do
      world = repair_world(npc: 'Rangu', room: 200, look: rangu_ready, answers: { 'hammer' => [quote, ''], 'tongs' => [quote, handed] })

      workorders.send(:repair_items, info, %w[hammer tongs])

      gives = world[:log].filter_map { |_room, command, line| line if command == 'give Rangu' }
      expect(gives).to eq([quote, '', quote, handed, 'You hand Rangu your ticket and are handed back a tongs.'])
      expect(Lich::Messaging).to have_received(:msg).with('bold', 'WorkOrders: Unexpected response finalizing hammer repair; skipping.').once
      expect(Lich::Messaging).not_to have_received(:msg).with('bold', /did not take|right hand/)
    end

    it 'gives a tool already in the right hand when the GET finds it held, by its GameObj noun' do
      world = repair_world(npc: 'Rangu', room: 200, look: rangu_ready, held: { right: 'diagonal-peen hammer' }, answers: { 'diagonal-peen hammer' => [quote, handed] })
      # "You are already holding that.": get_crafting_item is true, and
      # nothing new comes into a hand.
      allow(workorders).to receive(:get_tool).and_return(true)

      workorders.send(:repair_items, info, ['hammer'])

      gives = world[:log].filter_map { |_room, command, line| line if command == 'give Rangu' }
      expect(gives).to eq([quote, handed, 'You hand Rangu your ticket and are handed back a diagonal-peen hammer.'])
      expect(Lich::Messaging).not_to have_received(:msg).with('bold', anything)
    end

    it 'says so, gives nothing, and puts the tool away when it cannot be got into the right hand' do
      world = repair_world(npc: 'Rangu', room: 200, look: rangu_ready, held: { right: 'steel broadsword' }, swap: false, answers: { 'hammer' => [quote, handed] })

      workorders.send(:repair_items, info, ['hammer'])

      expect(world[:log].map { |_room, command, _line| command }).not_to include('give Rangu')
      expect(Lich::Messaging).to have_received(:msg).with('bold', 'WorkOrders: Could not get the hammer into your right hand to leave for repair (a bare give hands over the right hand); putting it away.').once
      expect(workorders).to have_received(:stow_tool).with('hammer').once
      expect([$right_hand, $left_hand]).to eq(['steel broadsword', nil])
    end

    it 'says so, gives nothing, and puts the tool away when the GET brought nothing new and both hands hold one of its noun' do
      world = repair_world(npc: 'Rangu', room: 200, look: rangu_ready, held: { right: 'diagonal-peen hammer', left: 'ball-peen hammer' })
      allow(workorders).to receive(:get_tool).and_return(true)

      workorders.send(:repair_items, info, ['hammer'])

      expect(world[:log].map { |_room, command, _line| command }).not_to include('give Rangu')
      expect(Lich::Messaging).to have_received(:msg).with('bold', /\AWorkOrders: Could not get the hammer into your right hand/).once
    end

    it "tells a named repairer's ticket not taken to be handed in by hand, not to be another society's" do
      world = repair_world(npc: 'Rangu', room: 200, tickets: 1, look: rangu_ready, ticket_reply: '')

      workorders.send(:repair_items, info, [])

      expect(world[:log].count { |_room, command, _line| command == 'give Rangu' }).to eq(1)
      expect(Lich::Messaging).to have_received(:msg).with('bold', 'WorkOrders: Rangu did not take the Rangu ticket (no answer). Put it away; collecting no more tickets this run. Hand it, and any more Rangu tickets you carry, in yourself.').once
      expect(world[:tickets]).to eq(1)
    end

    it 'confirms a quote pattern from data/custom that matches the cost alone, and still puts a refused tool away' do
      cost_only = repair_replies.merge('quote' => 'cost [\d,]+ \w+ to repair', 'offered' => ['cost [\d,]+ \w+ to repair', "There isn't a scratch on that", 'give it to me again'])
      allow(workorders).to receive(:get_data).with('crafting').and_return({ 'repair_replies' => cost_only })
      bput_lines('Rangu says, "That will cost 240 Kronars to repair."', "Rangu says, \"There isn't a scratch on that, and I'm not one to rob you.\"")
      allow(DRCI).to receive(:get_item?).with('Rangu ticket').and_return(false)
      allow(DRCT).to receive(:walk_to)
      allow(workorders).to receive(:get_tool) { |name| got_into_right_hand(name) }
      allow(workorders).to receive(:stow_tool)
      allow(Lich::Messaging).to receive(:msg)
      expect(workorders).to receive(:confirm_repair).with(info, 'hammer', 240)

      workorders.send(:repair_items, info, %w[hammer tongs])

      expect(workorders).to have_received(:stow_tool).with('tongs').once
      expect(workorders).not_to have_received(:stow_tool).with('hammer')
    end

    it "confirms Fang Cove's wording of the prompt (\"If you agree, give it to me again\")" do
      bput_lines('Osmandikar says, "If you agree, give it to me again."')
      allow(DRCI).to receive(:get_item?).with('Rangu ticket').and_return(false)
      allow(DRCT).to receive(:walk_to)
      allow(workorders).to receive(:get_tool) { |name| got_into_right_hand(name) }
      allow(workorders).to receive(:stow_tool)
      allow(Lich::Messaging).to receive(:msg)
      expect(workorders).to receive(:confirm_repair).with(info, 'hammer', nil)

      workorders.send(:repair_items, info, ['hammer'])
    end

    it 'confirms a quote by the data prompt, not by a word of its own: a prompt reworded in the data is still confirmed' do
      reworded = repair_replies.merge('quote'   => 'cost [\d,]+ \w+ to repair.*bring it back',
                                      'prompt'  => 'Bring it back',
                                      'offered' => ['cost [\d,]+ \w+ to repair.*bring it back', 'Bring it back', "There isn't a scratch on that"])
      allow(workorders).to receive(:get_data).with('crafting').and_return({ 'repair_replies' => reworded })
      bput_lines('Rangu looks over the hammer and says, "That will cost 240 Kronars to repair.  Bring it back if you want."')
      allow(DRCI).to receive(:get_item?).with('Rangu ticket').and_return(false)
      allow(DRCT).to receive(:walk_to)
      allow(workorders).to receive(:get_tool) { |name| got_into_right_hand(name) }
      allow(workorders).to receive(:stow_tool)
      allow(Lich::Messaging).to receive(:msg)
      expect(workorders).to receive(:confirm_repair).with(info, 'hammer', 240)

      workorders.send(:repair_items, info, ['hammer'])

      expect(workorders).not_to have_received(:stow_tool)
    end

    context 'when tool needs no repair' do
      it 'stows tool when repair not needed' do
        allow(DRC).to receive(:bput).and_return("There isn't a scratch on that")
        allow(DRCI).to receive(:get_item?).with('Rangu ticket').and_return(false)

        expect(workorders).to receive(:get_tool).with('hammer') { |name| got_into_right_hand(name) }
        expect(workorders).to receive(:get_tool).with('tongs') { |name| got_into_right_hand(name) }
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

        expect(workorders).to receive(:get_tool).with('hammer') { |name| got_into_right_hand(name) }
        expect(workorders).to receive(:get_tool).with('tongs') { |name| got_into_right_hand(name) }

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

        expect(workorders).to receive(:get_tool).with('hammer') { |name| got_into_right_hand(name) }
        expect(workorders).to receive(:get_tool).with('tongs') { |name| got_into_right_hand(name) }
        # First tool triggers 'give' branch with stow failure, second tool gets 'repair ticket' (no 'give'),
        # an answer to the first give no data pattern knows: put away, saying so.
        allow(Lich::Messaging).to receive(:msg)
        expect(Lich::Messaging).to receive(:msg).with('bold', 'WorkOrders: Failed to stow repair ticket').once
        expect(Lich::Messaging).to receive(:msg).with('bold', 'WorkOrders: Rangu did not take the tongs for repair (repair ticket); putting it away.').once
        expect(Lich::Messaging).to receive(:msg).with('plain', 'WorkOrders: Tool repair at NPC completed')

        workorders.send(:repair_items, info, tools)
      end
    end

    context 'when the clerk refuses the item outright' do
      # The else branch must stow the tool; otherwise it is left in hand and
      # the next iteration double-grabs or the trailing ticket loop misbehaves.
      it 'stows a tool that gets no quote and no no-need response' do
        allow(DRC).to receive(:bput).and_return("I don't repair those here")
        allow(DRCI).to receive(:get_item?).with('Rangu ticket').and_return(false)

        expect(workorders).to receive(:get_tool).with('hammer') { |name| got_into_right_hand(name) }
        expect(workorders).to receive(:get_tool).with('tongs') { |name| got_into_right_hand(name) }
        expect(workorders).to receive(:stow_tool).with('hammer')
        expect(workorders).to receive(:stow_tool).with('tongs')

        workorders.send(:repair_items, info, tools)
      end
    end
  end

  # ===========================================================================
  # #confirm_repair - two-give handshake, incl. the re-quote after a bank run
  # ===========================================================================
  describe '#confirm_repair' do
    let(:info) do
      {
        'repair-room' => 200,
        'repair-npc'  => 'Rangu'
      }
    end

    before do
      allow(workorders).to receive(:get_tool)
      allow(workorders).to receive(:stow_tool)
      allow(DRCT).to receive(:walk_to)
    end

    context 'when the clerk finalizes on the first give' do
      it 'stows the ticket' do
        allow(DRC).to receive(:bput).and_return('You hand a clerk 190 Dokoras and he gives you back a repair ticket.')

        expect(DRCI).to receive(:put_away_item?).with('ticket').and_return(true)

        workorders.send(:confirm_repair, info, 'cauldron', 190)
      end
    end

    context 'when short on coin and the clerk re-quotes after the bank run' do
      # Regression: previously the post-withdrawal re-quote matched neither
      # 'repair ticket' nor 'more coin', so bput timed out and the tool was
      # skipped (workorders hung). The re-quote must now be consumed and the
      # repair finalized on the following give.
      it 'consumes the re-quote and finalizes the repair' do
        responses = [
          'A clerk shakes his head and says, "You will need more coin before I\'ll repair that."',
          'A clerk looks over the cauldron and says, "That will cost 190 Dokoras to repair.  Just give it to me again if you want, and I\'ll have it ready in 1 roisaen."',
          'You hand a clerk 190 Dokoras and he gives you back a repair ticket.'
        ]
        call = 0
        allow(DRC).to receive(:bput) do |cmd, *_patterns|
          next 'default' unless cmd.include?('give Rangu')

          resp = responses[call]
          call += 1
          resp
        end

        expect(DRCM).to receive(:ensure_copper_on_hand).with(1900, anything, anything).and_return(true)
        expect(workorders).to receive(:get_tool).with('cauldron').and_return(true)
        expect(workorders).to receive(:tool_to_right_hand?).with('cauldron', anything).and_return(true)
        expect(DRCI).to receive(:put_away_item?).with('ticket').and_return(true)

        workorders.send(:confirm_repair, info, 'cauldron', 190)

        expect(call).to eq(3)
      end
    end

    context 'when the clerk repeatedly refuses for lack of coin' do
      it 'gives up without finalizing a ticket' do
        allow(DRC).to receive(:bput).and_return('A clerk shakes his head and says, "You will need more coin before I\'ll repair that."')
        allow(DRCM).to receive(:ensure_copper_on_hand).and_return(true)

        expect(DRCI).not_to receive(:put_away_item?).with('ticket')
        expect(workorders).to receive(:stow_tool).with('cauldron').at_least(:once)

        workorders.send(:confirm_repair, info, 'cauldron', 190)
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
  # #enchanting_items - the small spheres a fount order needs
  # ===========================================================================
  # Founts are made from small spheres. With the part listed as plain
  # "sphere", any other sphere in the crafting bag (here a keepsake) was
  # counted as a part, so the order bought one sphere too few and enchant
  # stopped on the last fount ("Could not get a small sphere").
  describe '#enchanting_items fount parts' do
    let(:recipe) do
      YAML.load_file(File.expand_path('../data/base-recipes.yaml', __dir__), aliases: true)['crafting_recipes']
          .find { |r| r['name'] == 'common material greater fount' }
    end
    let(:recipe_parts) { YAML.unsafe_load_file(File.expand_path('../data/base-crafting.yaml', __dir__))['recipe_parts'] }
    let(:info) { { 'tool-room' => 19_036, 'fount' => 1, 'stock-room' => 14_753, 'logbook' => 'enchanting' } }
    # RUMMAGE /C sphere, with one small sphere left over and the keepsake
    let(:rummage) do
      'You rummage through a stormy grey rucksack looking for something similar to "sphere" and see ' \
        'a pine small sphere and a fragile blown-glass sphere cradled within a twisted rencate frame.'
    end

    before do
      workorders.instance_variable_set(:@bag, 'rucksack')
      workorders.instance_variable_set(:@hometown, 'Crossing')
      workorders.instance_variable_set(:@recipe_parts, recipe_parts)
      # As lich-5's DRCI.count_items_in_container counts: ' <item>' then a non-word character.
      allow(DRCI).to receive(:count_items_in_container) { |item, _bag| rummage.scan(/ #{item}\W/).size }
      allow(workorders).to receive(:stow_tool)
      allow(workorders).to receive(:bundle_item)
      allow(DRC).to receive(:bput).and_return('This work order appears to be complete.')
    end

    it 'lists the part by the noun enchant gets' do
      expect(recipe['noun']).to eq('small sphere')
      expect(recipe['part']).to eq(['small sphere'])
    end

    it 'counts only the small sphere and buys the other four' do
      expect(DRCT).to receive(:buy_item).with(recipe_parts['sphere']['Crossing']['part-room'], 'sphere').exactly(4).times
      workorders.send(:enchanting_items, info, nil, recipe, 5)
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
        # First give per tool returns the clerk's cost quote (matches
        # the repair_replies quote and contains a price so repair_cost_copper works);
        # confirm_repair's give -- the only one passing 'repair ticket' as a
        # pattern -- returns 'repair ticket' so the repair finalizes and the
        # ticket is stowed.
        allow(DRC).to receive(:bput) do |_cmd, *patterns|
          patterns.include?('repair ticket') ? 'repair ticket' : 'cost 4,447 Kronars to repair.  Just give it to me again'
        end
        allow(DRCI).to receive(:get_item?).and_return(false)
        allow(workorders).to receive(:get_tool) { |name| got_into_right_hand(name) }
        allow(Lich::Messaging).to receive(:msg)

        expect(DRCI).to receive(:put_away_item?).with('ticket').and_return(true).twice

        workorders.send(:repair_items, { 'repair-room' => 100, 'repair-npc' => 'Rangu' }, %w[hammer tongs])
      end
    end

    describe 'repair insufficient-funds recovery' do
      describe '#repair_cost_copper' do
        it 'parses the copper amount out of a repair quote' do
          expect(workorders.send(:repair_cost_copper, 'cost 4,447 Kronars to repair')).to eq(4447)
        end

        it 'returns nil when the quote has no number' do
          expect(workorders.send(:repair_cost_copper, 'Just give it to me again')).to be_nil
        end
      end

      describe '#confirm_repair' do
        let(:info) { { 'repair-npc' => 'Rangu', 'repair-room' => 100 } }

        before { allow(Lich::Messaging).to receive(:msg) }

        it 'stows the ticket once the clerk accepts the repair' do
          allow(DRC).to receive(:bput).and_return('repair ticket')
          expect(DRCI).to receive(:put_away_item?).with('ticket').and_return(true)
          workorders.send(:confirm_repair, info, 'hammer', 4447)
        end

        it 'withdraws 10x the quoted cost, walks back, and retries when short on coin' do
          allow(DRC).to receive(:bput).and_return('more coin', 'repair ticket')
          allow(workorders).to receive(:stow_tool)
          allow(workorders).to receive(:get_tool)
          allow(DRCT).to receive(:walk_to)
          allow(DRCI).to receive(:put_away_item?).and_return(true)
          expect(DRCM).to receive(:ensure_copper_on_hand).with(44_470, anything, 'Crossing').and_return(true)
          workorders.send(:confirm_repair, info, 'hammer', 4447)
        end

        it 'skips without withdrawing when the cost could not be read' do
          allow(DRC).to receive(:bput).and_return('more coin')
          allow(workorders).to receive(:stow_tool)
          expect(DRCM).not_to receive(:ensure_copper_on_hand)
          workorders.send(:confirm_repair, info, 'hammer', nil)
        end
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
  # #forge_items - blacksmithing workflow
  # ===========================================================================
  describe '#forge_items' do
    let(:info) do
      {
        'stock-room' => 100,
        'trash-room' => 200,
        'logbook'    => 'forging'
      }
    end
    let(:materials_info) do
      {
        'stock-name'   => 'bronze',
        'stock-number' => 11,
        'stock-volume' => 10
      }
    end
    let(:item) { { 'name' => 'short sword' } }
    let(:recipe) do
      {
        'name'   => 'short sword',
        'volume' => 5,
        'noun'   => 'sword'
      }
    end

    before do
      workorders.instance_variable_set(:@settings, OpenStruct.new)
      workorders.instance_variable_set(:@hometown, 'Crossing')
      workorders.instance_variable_set(:@bag, 'backpack')
      workorders.instance_variable_set(:@belt, 'toolbelt')
      workorders.instance_variable_set(:@worn_trashcan, nil)
      workorders.instance_variable_set(:@worn_trashcan_verb, nil)
      workorders.instance_variable_set(:@cash_on_hand, 5000)

      allow(workorders).to receive(:find_recipe).and_return([recipe])
      allow(DRCM).to receive(:ensure_copper_on_hand)
      # order_item returns nil when the purchase fails
      allow(DRCT).to receive(:order_item).and_return('takes some coins from you')
      allow(DRCT).to receive(:dispose)
      allow(DRC).to receive(:wait_for_script_to_complete)
      allow(workorders).to receive(:bundle_item)
      # need one more -> craft once -> complete on next check (+ final status read)
      allow(workorders).to receive(:logbook_remaining).and_return(1, 0, 0)
    end

    it 'stows ingot to crafting_container using DRCC.stow_crafting_item' do
      expect(DRCC).to receive(:stow_crafting_item).with('bronze ingot', 'backpack', 'toolbelt')
      workorders.send(:forge_items, info, materials_info, item, 1)
    end

    it 'orders ingot from correct stock room' do
      allow(DRCC).to receive(:stow_crafting_item)
      expect(DRCT).to receive(:order_item).with(100, 11)
      workorders.send(:forge_items, info, materials_info, item, 1)
    end

    it 'disposes leftover ingot when remaining volume is positive' do
      allow(DRCC).to receive(:stow_crafting_item)
      expect(DRCT).to receive(:dispose).with('bronze ingot', 200, nil, nil)
      workorders.send(:forge_items, info, materials_info, item, 1)
    end

    it 'calls smith script with correct material and item name' do
      allow(DRCC).to receive(:stow_crafting_item)
      expect(DRC).to receive(:wait_for_script_to_complete).with('smith', ['bronze', 'short sword'])
      workorders.send(:forge_items, info, materials_info, item, 1)
    end

    it 'crafts an extra item when logbook still needs one more after quantity' do
      allow(DRCC).to receive(:stow_crafting_item)
      # asked for 2; after two crafts still need 1; third craft completes
      allow(workorders).to receive(:logbook_remaining).and_return(2, 1, 1, 0, 0)
      expect(DRC).to receive(:wait_for_script_to_complete).with('smith', ['bronze', 'short sword']).exactly(3).times
      workorders.send(:forge_items, info, materials_info, item, 2)
    end

    # Stock ingots of 50 volume and up are sold at the town's bulk materials
    # shop under their own numbers. Ordered at the stock shop, immense
    # bronze's number 1 bought Crossing's tiny coal nugget instead.
    context 'with a bulk ingot as metal_type' do
      let(:crafting) { YAML.load_file(File.expand_path('../data/base-crafting.yaml', __dir__), aliases: true) }
      let(:info) { crafting['blacksmithing']['Crossing'].merge('logbook' => 'forging') }
      let(:materials_info) { crafting['stock']['bronze50'] }

      before { allow(DRCC).to receive(:stow_crafting_item) }

      it 'reads the rooms and the ingot these examples rely on from the data' do
        expect(info.values_at('stock-room', 'bingots-room')).to eq([8775, 17118])
        expect(materials_info.values_at('stock-number', 'stock-volume', 'stock-value')).to eq([1, 50, 6250])
      end

      it 'orders it at the bulk materials shop' do
        expect(DRCT).to receive(:order_item).with(17118, 1)
        workorders.send(:forge_items, info, materials_info, item, 1)
      end

      it 'carries enough copper to buy one, priced in the town currency' do
        # crafting_cost: 6250 for the ingot plus 1000 for consumables, in Kronars
        expect(DRCC).to receive(:crafting_cost).with(recipe, 'Crossing', nil, 1, materials_info).and_return(7250)
        # once up front, over the 5000 floor, and again before ordering it
        expect(DRCM).to receive(:ensure_copper_on_hand).with(7250, anything, 'Crossing').twice
        workorders.send(:forge_items, info, materials_info, item, 1)
      end

      # 3 greatswords of 18 volume need 54, two immense ingots. Funding only
      # up front left about 1000 after the first, so Bulk Materials refused
      # the second order and smith ran with no ingot. (smith tops up to just
      # 3000 when it's handed the ingot, so it doesn't make up the difference.)
      context 'when the order needs a second one' do
        let(:recipe) do
          YAML.load_file(File.expand_path('../data/base-recipes.yaml', __dir__), aliases: true)['crafting_recipes']
              .find { |r| r['name'] == 'a metal greatsword' }
        end
        let(:item) { { 'name' => recipe['name'] } }

        it 'pays for each ingot' do
          expect(recipe['volume']).to eq(18)
          on_hand = 0
          refused = 0
          allow(DRCC).to receive(:crafting_cost).and_return(7250)
          allow(DRCM).to receive(:ensure_copper_on_hand) { |copper, *| on_hand = [on_hand, copper].max }
          allow(DRCT).to receive(:order_item) do
            if on_hand < materials_info['stock-value']
              refused += 1
              nil # "you don't have enough coins"
            else
              on_hand -= materials_info['stock-value']
              'takes some coins from you'
            end
          end
          allow(workorders).to receive(:logbook_remaining).and_return(3, 2, 1, 0, 0)

          workorders.send(:forge_items, info, materials_info, item, 3)

          expect(refused).to eq(0)
          expect(DRCT).to have_received(:order_item).with(17118, 1).twice
          expect(DRC).to have_received(:wait_for_script_to_complete).exactly(3).times
        end
      end

      it 'stops without buying in a town with no bulk materials shop' do
        ratha = crafting['blacksmithing']['Ratha'].merge('logbook' => 'forging')
        workorders.instance_variable_set(:@hometown, 'Ratha')
        expect(ratha['bingots-room']).to be_nil
        expect(DRCT).not_to receive(:order_item)
        expect(DRC).not_to receive(:wait_for_script_to_complete)
        expect(Lich::Messaging).to receive(:msg).with('bold', 'WorkOrders: bronze ingots of 50 volume are sold at a bulk materials shop, and Ratha has none. Set workorders_materials metal_type to a smaller ingot.')
        expect(workorders).to receive(:exit).and_raise(SystemExit)

        expect { workorders.send(:forge_items, ratha, materials_info, item, 1) }.to raise_error(SystemExit)
      end
    end

    it 'still carries the default 5000 copper for a huge bronze ingot' do
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCC).to receive(:crafting_cost).and_return(1562)
      expect(DRCM).to receive(:ensure_copper_on_hand).with(5000, anything, 'Crossing')
      workorders.send(:forge_items, info, materials_info, item, 1)
    end

    # smith leaves about 3000, so topping up to the 5000 floor before every
    # small ingot would send each reorder to the bank.
    it 'tops up to one ingot, not the floor, before each ingot' do
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCC).to receive(:crafting_cost).and_return(1562)
      # 3 items of 5 volume from 10-volume ingots: two ingots
      allow(workorders).to receive(:logbook_remaining).and_return(3, 2, 1, 0, 0)

      workorders.send(:forge_items, info, materials_info, item, 3)

      expect(DRCT).to have_received(:order_item).twice
      expect(DRCM).to have_received(:ensure_copper_on_hand).with(5000, anything, 'Crossing').once
      expect(DRCM).to have_received(:ensure_copper_on_hand).with(1562, anything, 'Crossing').twice
    end

    it 'stops the order instead of forging when an ingot cannot be bought' do
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCT).to receive(:order_item).and_return(nil)
      allow(workorders).to receive(:logbook_remaining).and_return(1, 1)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'WorkOrders: Could not buy a bronze ingot, so not forging the rest of this order.')
      expect(Lich::Messaging).to receive(:msg).with('bold', 'WorkOrders: Forging finished but logbook still needs 1 more')

      workorders.send(:forge_items, info, materials_info, item, 1)

      expect(DRCC).not_to have_received(:stow_crafting_item)
      expect(DRC).not_to have_received(:wait_for_script_to_complete)
      expect(DRCT).not_to have_received(:dispose)
    end

    # forge_items buys one ingot of metal_type at a time. An order for an item
    # bigger than that ingot used to buy one on every attempt, fail each with
    # "You need a larger ingot to forge this item.", and waste them all: with
    # the default bronze (a 5-volume huge bronze ingot), a metal cane (8) or a
    # metal club (6) burned about eight ingots per order.
    context 'when the order needs more metal than one ingot holds' do
      let(:item) { { 'name' => 'a metal cane' } }
      let(:recipe) { { 'name' => 'a metal cane', 'volume' => 8, 'noun' => 'cane' } }
      let(:materials_info) { { 'stock-name' => 'bronze', 'stock-number' => 11, 'stock-volume' => 5 } }

      it 'stops without buying an ingot or forging' do
        expect(DRCT).not_to receive(:order_item)
        expect(DRCM).not_to receive(:ensure_copper_on_hand)
        expect(DRC).not_to receive(:wait_for_script_to_complete)
        expect(Lich::Messaging).to receive(:msg).with('bold', 'WorkOrders: a metal cane needs 8 volume of metal, more than one bronze ingot holds (5). Not buying ingots for it: list only items that fit in workorder_recipes, or set workorders_materials metal_type to a larger ingot.')

        expect(workorders).to receive(:exit).and_raise(SystemExit)
        expect { workorders.send(:forge_items, info, materials_info, item, 4) }.to raise_error(SystemExit)
      end
    end

    it 'forges an item exactly as big as the ingot' do
      allow(DRCC).to receive(:stow_crafting_item)
      allow(workorders).to receive(:find_recipe).and_return([recipe.merge('volume' => 10)])
      # exit is stubbed as a no-op above, so this is what fails if the guard stops it
      expect(workorders).not_to receive(:exit)
      expect(DRC).to receive(:wait_for_script_to_complete).with('smith', ['bronze', 'short sword'])
      workorders.send(:forge_items, info, materials_info, item, 1)
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
        'npc-rooms'     => [100],
        'npc_last_name' => 'Jakke',
        'npc'           => 'Jakke',
        'logbook'       => 'engineering'
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
