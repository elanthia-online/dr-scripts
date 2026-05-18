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

# Minimal stub modules for game interaction
module DRC
  class << self
    def bput(*_args); 'I could not find what you were referring to.'; end

    def text2num(text)
      %w[zero one two three four five six seven eight nine ten].index(text) || text.to_i
    end
  end
end

module DRCT
  class << self
    def walk_to(*_args); end
    def buy_item(*_args); end
    def order_item(*_args); end
  end
end

module DRCI
  class << self
    def open_container?(*_args); true; end
    def stow_hands; end
    def put_away_item?(*_args); true; end
    def get_item?(*_args); true; end
    def count_items_in_container(*_args); 0; end
  end
end

module DRCM
  class << self
    def convert_to_copper(amount, denom)
      amount.to_i * case denom
                    when 'copper' then 1
                    when 'bronze' then 10
                    when 'silver' then 100
                    when 'gold' then 1000
                    when 'platinum' then 10_000
                    else 1
                    end
    end

    def ensure_copper_on_hand(*_args); end
    def deposit_coins(*_args); end
  end
end

$ORDINALS = %w[first second third fourth fifth sixth seventh eighth ninth tenth].freeze

load_lic_class('restock.lic', 'Restock')

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end
end

RSpec.describe Restock do
  # Build a Restock instance without calling initialize (avoids game I/O).
  def build_instance(**overrides)
    instance = Restock.allocate
    defaults = {
      debug: false,
      settings: OpenStruct.new(hometown: 'Crossing'),
      restock: {},
      hometown: 'Crossing',
      runestone_storage: 'backpack',
      keep_copper: 300
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  # Build a restock item hash with sensible defaults.
  def make_item(overrides = {})
    {
      'name'      => 'arrow',
      'quantity'  => 30,
      'size'      => 10,
      'price'     => 100,
      'stackable' => false,
      'room'      => 1234
    }.merge(overrides)
  end

  # ===========================================================================
  # #start_restock -- routing to restock_default vs restock_items
  # ===========================================================================
  describe '#start_restock' do
    context 'with items from multiple custom hometowns' do
      it 'sends default items to restock_default and groups custom items by hometown' do
        crossing_item = make_item('hometown' => 'Crossing', 'name' => 'arrow')
        shard_item = make_item('hometown' => 'Shard', 'name' => 'bolt')
        instance = build_instance(
          settings: OpenStruct.new(hometown: 'Riverhaven')
        )

        allow(instance).to receive(:parse_restockable_items).and_return([crossing_item, shard_item])

        default_calls = []
        allow(instance).to receive(:restock_default) do |items, town|
          default_calls << { town: town, items: items.map { |i| i['name'] } }
        end

        custom_calls = []
        allow(instance).to receive(:restock_items) do |items, town|
          custom_calls << { town: town, items: items.map { |i| i['name'] } }
        end

        instance.send(:start_restock)

        # Default hometown gets non-custom items via restock_default (empty here)
        expect(default_calls.length).to eq(1)
        expect(default_calls.first[:town]).to eq('Riverhaven')
        expect(default_calls.first[:items]).to be_empty

        # Each custom hometown called via restock_items exactly once
        expect(custom_calls.length).to eq(2)
        crossing = custom_calls.find { |c| c[:town] == 'Crossing' }
        expect(crossing[:items]).to eq(['arrow'])
        shard = custom_calls.find { |c| c[:town] == 'Shard' }
        expect(shard[:items]).to eq(['bolt'])
      end
    end

    context 'with no custom hometown items' do
      it 'only calls restock_default for the default hometown' do
        item = make_item
        instance = build_instance(
          settings: OpenStruct.new(hometown: 'Crossing')
        )

        allow(instance).to receive(:parse_restockable_items).and_return([item])

        default_calls = []
        allow(instance).to receive(:restock_default) do |items, town|
          default_calls << { town: town, count: items.length }
        end
        allow(instance).to receive(:restock_items)

        instance.send(:start_restock)

        expect(default_calls.length).to eq(1)
        expect(default_calls.first[:town]).to eq('Crossing')
        expect(default_calls.first[:count]).to eq(1)
        expect(instance).not_to have_received(:restock_items)
      end
    end
  end

  # ===========================================================================
  # #restock_items -- min_quantity, coin calc, buy quantity
  # ===========================================================================
  describe '#restock_items' do
    context 'min_quantity threshold' do
      it 'skips item when remaining is at or above min_quantity' do
        item = make_item('min_quantity' => 10, 'quantity' => 30)
        instance = build_instance

        allow(instance).to receive(:count_nonstackable_item).and_return(15)
        allow(DRCT).to receive(:buy_item)

        instance.send(:restock_items, [item], 'Crossing')

        # items_to_restock is empty so method returns early -- no purchase attempted
        expect(DRCT).not_to have_received(:buy_item)
      end

      it 'restocks when remaining drops below min_quantity' do
        item = make_item('min_quantity' => 10, 'quantity' => 30)
        instance = build_instance

        allow(instance).to receive(:count_nonstackable_item).and_return(5)
        allow(DRCI).to receive(:stow_hands)
        allow(DRCM).to receive(:ensure_copper_on_hand)
        allow(DRCM).to receive(:deposit_coins)
        allow(instance).to receive(:purchase_item)
        allow(instance).to receive(:handle_encumbrance)
        allow(instance).to receive(:stow_item)

        instance.send(:restock_items, [item], 'Crossing')

        # (30 - 5) / 10 = 2.5, ceil = 3
        expect(instance).to have_received(:purchase_item).exactly(3).times
      end

      it 'uses regular quantity check when min_quantity is not set' do
        item = make_item('quantity' => 30)
        instance = build_instance

        allow(instance).to receive(:count_nonstackable_item).and_return(20)
        allow(DRCI).to receive(:stow_hands)
        allow(DRCM).to receive(:ensure_copper_on_hand)
        allow(DRCM).to receive(:deposit_coins)
        allow(instance).to receive(:purchase_item)
        allow(instance).to receive(:handle_encumbrance)
        allow(instance).to receive(:stow_item)

        instance.send(:restock_items, [item], 'Crossing')

        # (30 - 20) / 10 = 1
        expect(instance).to have_received(:purchase_item).once
      end
    end

    context 'coin calculation' do
      it 'calculates bribe padding based on items needing restock, not total item list' do
        needed_item = make_item('name' => 'arrow', 'quantity' => 10, 'price' => 100, 'size' => 10)
        stocked_item = make_item('name' => 'bolt', 'quantity' => 10, 'price' => 200, 'size' => 10)
        instance = build_instance

        call_count = 0
        allow(instance).to receive(:count_nonstackable_item) do
          call_count += 1
          call_count == 1 ? 0 : 10 # first item needs restock, second doesn't
        end

        allow(DRCI).to receive(:stow_hands)
        allow(DRCM).to receive(:deposit_coins)
        allow(instance).to receive(:purchase_item)
        allow(instance).to receive(:handle_encumbrance)
        allow(instance).to receive(:stow_item)

        # 1 item needs restock: price(100) + bribe(2502 * 1) = 2602
        expected_coin = 100 + (2502 * 1)
        expect(DRCM).to receive(:ensure_copper_on_hand).with(expected_coin, anything, 'Crossing')

        instance.send(:restock_items, [needed_item, stocked_item], 'Crossing')
      end
    end

    context 'buy quantity calculation' do
      it 'rounds up when size does not divide evenly into quantity needed' do
        item = make_item('quantity' => 25, 'size' => 10, 'price' => 50)
        instance = build_instance

        allow(instance).to receive(:count_nonstackable_item).and_return(0)
        allow(DRCI).to receive(:stow_hands)
        allow(DRCM).to receive(:ensure_copper_on_hand)
        allow(DRCM).to receive(:deposit_coins)
        allow(instance).to receive(:purchase_item)
        allow(instance).to receive(:handle_encumbrance)
        allow(instance).to receive(:stow_item)

        instance.send(:restock_items, [item], 'Crossing')

        # (25 - 0) / 10.0 = 2.5, ceil = 3
        expect(instance).to have_received(:purchase_item).exactly(3).times
      end

      it 'does not round up when size divides evenly' do
        item = make_item('quantity' => 30, 'size' => 10, 'price' => 50)
        instance = build_instance

        allow(instance).to receive(:count_nonstackable_item).and_return(0)
        allow(DRCI).to receive(:stow_hands)
        allow(DRCM).to receive(:ensure_copper_on_hand)
        allow(DRCM).to receive(:deposit_coins)
        allow(instance).to receive(:purchase_item)
        allow(instance).to receive(:handle_encumbrance)
        allow(instance).to receive(:stow_item)

        instance.send(:restock_items, [item], 'Crossing')

        expect(instance).to have_received(:purchase_item).exactly(3).times
      end
    end

    context 'when no items need restocking' do
      it 'returns early without withdrawing coin or purchasing' do
        item = make_item('quantity' => 10)
        instance = build_instance

        allow(instance).to receive(:count_nonstackable_item).and_return(10)
        allow(DRCI).to receive(:stow_hands)
        allow(DRCM).to receive(:ensure_copper_on_hand)
        allow(DRCM).to receive(:deposit_coins)

        instance.send(:restock_items, [item], 'Crossing')

        expect(DRCI).not_to have_received(:stow_hands)
        expect(DRCM).not_to have_received(:ensure_copper_on_hand)
        expect(DRCM).not_to have_received(:deposit_coins)
      end
    end
  end

  # ===========================================================================
  # #purchase_item -- clerk vs buy flow (foot gun fix)
  # ===========================================================================
  describe '#purchase_item' do
    it 'uses ask-for flow when item has a clerk' do
      item = make_item('clerk' => 'shopkeeper', 'room' => 5678)
      instance = build_instance

      allow(DRCT).to receive(:walk_to)
      allow(DRCT).to receive(:buy_item)

      instance.send(:purchase_item, item)

      expect(DRCT).to have_received(:walk_to).with(5678)
      expect(DRCT).not_to have_received(:buy_item)
    end

    it 'uses standard buy_item when item has no clerk' do
      item = make_item('room' => 5678)
      instance = build_instance

      allow(DRCT).to receive(:buy_item)
      allow(DRCT).to receive(:walk_to)

      instance.send(:purchase_item, item)

      expect(DRCT).to have_received(:buy_item).with(5678, 'arrow')
      expect(DRCT).not_to have_received(:walk_to)
    end
  end

  # ===========================================================================
  # #stow_item -- container, runestone, and default stow
  # ===========================================================================
  describe '#stow_item' do
    it 'uses item container when specified' do
      item = make_item('container' => 'quiver')
      instance = build_instance

      allow(DRCI).to receive(:put_away_item?)

      instance.send(:stow_item, item)

      expect(DRCI).to have_received(:put_away_item?).with('arrow', 'quiver')
    end

    it 'uses runestone storage for runestones' do
      item = make_item('name' => 'runestone')
      instance = build_instance(runestone_storage: 'pouch')

      allow(DRCI).to receive(:put_away_item?)

      instance.send(:stow_item, item)

      expect(DRCI).to have_received(:put_away_item?).with('runestone', 'pouch')
    end

    it 'matches runestone case-insensitively' do
      item = make_item('name' => 'Runestone')
      instance = build_instance(runestone_storage: 'pouch')

      allow(DRCI).to receive(:put_away_item?)

      instance.send(:stow_item, item)

      expect(DRCI).to have_received(:put_away_item?).with('Runestone', 'pouch')
    end

    it 'falls back to stow_hands for other items' do
      item = make_item
      instance = build_instance

      allow(DRCI).to receive(:stow_hands)

      instance.send(:stow_item, item)

      expect(DRCI).to have_received(:stow_hands)
    end

    it 'prefers container over runestone storage when both apply' do
      item = make_item('name' => 'runestone', 'container' => 'satchel')
      instance = build_instance(runestone_storage: 'pouch')

      allow(DRCI).to receive(:put_away_item?)

      instance.send(:stow_item, item)

      # container takes priority
      expect(DRCI).to have_received(:put_away_item?).with('runestone', 'satchel')
    end
  end

  # ===========================================================================
  # #count_nonstackable_item -- countable_name and container discovery
  # ===========================================================================
  describe '#count_nonstackable_item' do
    it 'uses countable_name when present' do
      item = make_item('name' => 'gold pouch', 'countable_name' => 'pouch', 'container' => 'backpack')
      instance = build_instance

      allow(DRCI).to receive(:count_items_in_container).and_return(3)

      result = instance.send(:count_nonstackable_item, item)

      expect(DRCI).to have_received(:count_items_in_container).with('pouch', 'backpack')
      expect(result).to eq(3)
    end

    it 'falls back to name when countable_name is not set' do
      item = make_item('name' => 'arrow', 'container' => 'quiver')
      instance = build_instance

      allow(DRCI).to receive(:count_items_in_container).and_return(5)

      result = instance.send(:count_nonstackable_item, item)

      expect(DRCI).to have_received(:count_items_in_container).with('arrow', 'quiver')
      expect(result).to eq(5)
    end

    it 'discovers container via tap when not specified' do
      item = { 'name' => 'arrow', 'quantity' => 30, 'stackable' => false }
      instance = build_instance

      allow(DRC).to receive(:bput)
        .with("tap my arrow", 'inside your (.*).', 'I could not find')
        .and_return('inside your quiver.')
      allow(DRCI).to receive(:count_items_in_container).and_return(10)

      result = instance.send(:count_nonstackable_item, item)

      expect(DRCI).to have_received(:count_items_in_container).with('arrow', 'quiver')
      expect(result).to eq(10)
    end

    it 'returns 0 when tap finds nothing' do
      item = { 'name' => 'arrow', 'quantity' => 30, 'stackable' => false }
      instance = build_instance

      allow(DRC).to receive(:bput)
        .with("tap my arrow", 'inside your (.*).', 'I could not find')
        .and_return('I could not find what you were referring to.')
      allow(DRCI).to receive(:count_items_in_container)

      result = instance.send(:count_nonstackable_item, item)

      expect(result).to eq(0)
      expect(DRCI).not_to have_received(:count_items_in_container)
    end
  end

  # ===========================================================================
  # #parse_restockable_items -- data merging and validation
  # ===========================================================================
  describe '#parse_restockable_items' do
    let(:consumables) do
      {
        'arrow' => {
          'name'      => 'arrow',
          'size'      => 10,
          'price'     => 100,
          'room'      => 1234,
          'stackable' => false,
          'quantity'  => 20
        }
      }
    end

    it 'merges base-consumables data for known items' do
      restock_config = { 'arrow' => { 'quantity' => 30 } }
      instance = build_instance(restock: restock_config, hometown: 'Crossing')

      $test_data = OpenStruct.new(consumables: { 'Crossing' => consumables })

      result = instance.send(:parse_restockable_items)

      expect(result.length).to eq(1)
      item = result.first
      # User's quantity overrides base-consumables
      expect(item['quantity']).to eq(30)
      # Base-consumables fills in missing fields
      expect(item['name']).to eq('arrow')
      expect(item['size']).to eq(10)
      expect(item['price']).to eq(100)
    end

    it 'preserves all user overrides over base-consumables defaults' do
      restock_config = { 'arrow' => { 'quantity' => 50, 'price' => 200 } }
      instance = build_instance(restock: restock_config, hometown: 'Crossing')

      $test_data = OpenStruct.new(consumables: { 'Crossing' => consumables })

      result = instance.send(:parse_restockable_items)
      item = result.first

      expect(item['quantity']).to eq(50)
      expect(item['price']).to eq(200)
    end

    it 'accepts fully custom items with all required fields' do
      restock_config = {
        'custom_thing' => {
          'name'      => 'widget',
          'size'      => 1,
          'room'      => 9999,
          'price'     => 50,
          'stackable' => false,
          'quantity'  => 5
        }
      }
      instance = build_instance(restock: restock_config, hometown: 'Crossing')

      $test_data = OpenStruct.new(consumables: { 'Crossing' => {} })

      result = instance.send(:parse_restockable_items)

      expect(result.length).to eq(1)
      expect(result.first['name']).to eq('widget')
    end

    it 'rejects custom items missing required fields' do
      restock_config = {
        'broken_thing' => { 'name' => 'widget' }
        # missing size, room, price, stackable, quantity
      }
      instance = build_instance(restock: restock_config, hometown: 'Crossing')

      $test_data = OpenStruct.new(consumables: { 'Crossing' => {} })

      result = instance.send(:parse_restockable_items)

      expect(result).to be_empty
    end

    it 'skips base-consumables lookup when item specifies custom hometown' do
      restock_config = {
        'arrow' => {
          'hometown'  => 'Shard',
          'name'      => 'arrow',
          'size'      => 10,
          'room'      => 5678,
          'price'     => 150,
          'stackable' => false,
          'quantity'  => 20
        }
      }
      instance = build_instance(restock: restock_config, hometown: 'Crossing')

      $test_data = OpenStruct.new(consumables: { 'Crossing' => consumables })

      result = instance.send(:parse_restockable_items)

      expect(result.length).to eq(1)
      # Should use the user's custom values, not base-consumables
      expect(result.first['price']).to eq(150)
      expect(result.first['room']).to eq(5678)
    end
  end

  # ===========================================================================
  # #valid_item_data? -- required field validation
  # ===========================================================================
  describe '#valid_item_data?' do
    it 'returns true when all required fields are present' do
      instance = build_instance
      expect(instance.send(:valid_item_data?, make_item)).to be true
    end

    %w[name size room price stackable quantity].each do |field|
      it "returns false when '#{field}' is missing" do
        item = make_item
        item.delete(field)
        instance = build_instance
        expect(instance.send(:valid_item_data?, item)).to be false
      end
    end
  end

  # ===========================================================================
  # #assess_restock_needs -- extracted counting/filtering logic
  # ===========================================================================
  describe '#assess_restock_needs' do
    it 'returns items needing restock with buy_num and total coin' do
      item = make_item('quantity' => 30, 'size' => 10, 'price' => 100)
      instance = build_instance

      allow(instance).to receive(:count_nonstackable_item).and_return(5)

      items, coin = instance.send(:assess_restock_needs, [item])

      expect(items.length).to eq(1)
      # (30 - 5) / 10.0 = 2.5, ceil = 3
      expect(items.first['buy_num']).to eq(3)
      expect(coin).to eq(300)
    end

    it 'skips items at or above min_quantity' do
      item = make_item('min_quantity' => 10, 'quantity' => 30)
      instance = build_instance

      allow(instance).to receive(:count_nonstackable_item).and_return(15)

      items, coin = instance.send(:assess_restock_needs, [item])

      expect(items).to be_empty
      expect(coin).to eq(0)
    end

    it 'includes items below min_quantity' do
      item = make_item('min_quantity' => 10, 'quantity' => 30, 'size' => 10, 'price' => 100)
      instance = build_instance

      allow(instance).to receive(:count_nonstackable_item).and_return(5)

      items, coin = instance.send(:assess_restock_needs, [item])

      expect(items.length).to eq(1)
      # (30 - 5) / 10.0 = 2.5, ceil = 3
      expect(items.first['buy_num']).to eq(3)
      expect(coin).to eq(300)
    end

    it 'skips items already at target quantity when no min_quantity set' do
      item = make_item('quantity' => 10)
      instance = build_instance

      allow(instance).to receive(:count_nonstackable_item).and_return(10)

      items, coin = instance.send(:assess_restock_needs, [item])

      expect(items).to be_empty
      expect(coin).to eq(0)
    end

    it 'uses count_stackable_item for stackable items' do
      item = make_item('stackable' => true, 'quantity' => 30, 'size' => 10, 'price' => 50)
      instance = build_instance

      allow(instance).to receive(:count_stackable_item).and_return(10)

      items, coin = instance.send(:assess_restock_needs, [item])

      expect(items.length).to eq(1)
      expect(instance).to have_received(:count_stackable_item).with(item)
      expect(items.first['buy_num']).to eq(2)
      expect(coin).to eq(100)
    end

    it 'handles multiple items independently' do
      arrow = make_item('name' => 'arrow', 'quantity' => 20, 'size' => 10, 'price' => 100)
      bolt = make_item('name' => 'bolt', 'quantity' => 10, 'size' => 5, 'price' => 200)
      instance = build_instance

      call_count = 0
      allow(instance).to receive(:count_nonstackable_item) do
        call_count += 1
        call_count == 1 ? 0 : 0
      end

      items, coin = instance.send(:assess_restock_needs, [arrow, bolt])

      expect(items.length).to eq(2)
      # arrow: (20-0)/10 = 2 buys * 100 = 200
      # bolt: (10-0)/5 = 2 buys * 200 = 400
      expect(coin).to eq(600)
    end
  end

  # ===========================================================================
  # #purchase_item -- clerk, order_number, and standard buy flows
  # ===========================================================================
  describe '#purchase_item' do
    it 'uses ask-for flow when item has a clerk' do
      item = make_item('clerk' => 'shopkeeper', 'room' => 5678)
      instance = build_instance

      allow(DRCT).to receive(:walk_to)
      allow(DRCT).to receive(:buy_item)

      instance.send(:purchase_item, item)

      expect(DRCT).to have_received(:walk_to).with(5678)
      expect(DRCT).not_to have_received(:buy_item)
    end

    it 'uses DRCT.order_item when item has an order_number' do
      item = make_item('order_number' => 16, 'room' => 14753)
      instance = build_instance

      allow(DRCT).to receive(:order_item)
      allow(DRCT).to receive(:buy_item)

      instance.send(:purchase_item, item)

      expect(DRCT).to have_received(:order_item).with(14753, 16)
      expect(DRCT).not_to have_received(:buy_item)
    end

    it 'prefers clerk over order_number when both are present' do
      item = make_item('clerk' => 'shopkeeper', 'order_number' => 16, 'room' => 5678)
      instance = build_instance

      allow(DRCT).to receive(:walk_to)
      allow(DRCT).to receive(:order_item)

      instance.send(:purchase_item, item)

      expect(DRCT).to have_received(:walk_to).with(5678)
      expect(DRCT).not_to have_received(:order_item)
    end

    it 'uses standard buy_item when item has no clerk or order_number' do
      item = make_item('room' => 5678)
      instance = build_instance

      allow(DRCT).to receive(:buy_item)
      allow(DRCT).to receive(:walk_to)

      instance.send(:purchase_item, item)

      expect(DRCT).to have_received(:buy_item).with(5678, 'arrow')
      expect(DRCT).not_to have_received(:walk_to)
    end
  end

  # ===========================================================================
  # #collect_sigil_purchases -- sigil book scroll counting
  # ===========================================================================
  describe '#collect_sigil_purchases' do
    it 'returns empty array when no sigil_books config exists' do
      instance = build_instance(restock: {})

      result = instance.send(:collect_sigil_purchases)

      expect(result).to eq([])
    end

    it 'returns empty array when sigil_books is nil' do
      instance = build_instance(restock: { 'sigil_books' => nil })

      result = instance.send(:collect_sigil_purchases)

      expect(result).to eq([])
    end

    it 'calculates needed quantity and builds purchase hash' do
      restock_config = {
        'sigil_books' => {
          'platinum-hued book' => {
            'container' => 'satchel',
            'congruence' => {
              'quantity' => 20,
              'min_quantity' => 5,
              'room' => 14753,
              'order_number' => 3,
              'price' => 312
            }
          }
        }
      }
      instance = build_instance(restock: restock_config)

      allow(instance).to receive(:count_sigils_in_book)
        .with('platinum-hued book', 'congruence', 'satchel')
        .and_return(3)

      result = instance.send(:collect_sigil_purchases)

      expect(result.length).to eq(1)
      purchase = result.first
      expect(purchase['book']).to eq('platinum-hued book')
      expect(purchase['sigil_type']).to eq('congruence')
      expect(purchase['order_number']).to eq(3)
      expect(purchase['price']).to eq(312)
      expect(purchase['room']).to eq(14753)
      expect(purchase['needed']).to eq(17)
    end

    it 'skips sigil types at or above min_quantity' do
      restock_config = {
        'sigil_books' => {
          'platinum-hued book' => {
            'container' => 'satchel',
            'congruence' => {
              'quantity' => 20,
              'min_quantity' => 5,
              'room' => 14753,
              'order_number' => 3,
              'price' => 312
            }
          }
        }
      }
      instance = build_instance(restock: restock_config)

      allow(instance).to receive(:count_sigils_in_book).and_return(10)

      result = instance.send(:collect_sigil_purchases)

      expect(result).to be_empty
    end

    it 'skips when book is not found (nil count)' do
      restock_config = {
        'sigil_books' => {
          'missing book' => {
            'congruence' => {
              'quantity' => 20,
              'room' => 14753,
              'order_number' => 3,
              'price' => 312
            }
          }
        }
      }
      instance = build_instance(restock: restock_config)

      allow(instance).to receive(:count_sigils_in_book).and_return(nil)

      result = instance.send(:collect_sigil_purchases)

      expect(result).to be_empty
    end

    it 'skips when already at target quantity' do
      restock_config = {
        'sigil_books' => {
          'platinum-hued book' => {
            'congruence' => {
              'quantity' => 10,
              'room' => 14753,
              'order_number' => 3,
              'price' => 312
            }
          }
        }
      }
      instance = build_instance(restock: restock_config)

      allow(instance).to receive(:count_sigils_in_book).and_return(10)

      result = instance.send(:collect_sigil_purchases)

      expect(result).to be_empty
    end

    it 'handles multiple sigil types in one book' do
      restock_config = {
        'sigil_books' => {
          'platinum-hued book' => {
            'container' => 'satchel',
            'congruence' => {
              'quantity' => 20,
              'room' => 14753,
              'order_number' => 3,
              'price' => 312
            },
            'abolition' => {
              'quantity' => 10,
              'room' => 14753,
              'order_number' => 5,
              'price' => 250
            }
          }
        }
      }
      instance = build_instance(restock: restock_config)

      allow(instance).to receive(:count_sigils_in_book).and_return(0)

      result = instance.send(:collect_sigil_purchases)

      expect(result.length).to eq(2)
      types = result.map { |p| p['sigil_type'] }
      expect(types).to include('congruence')
      expect(types).to include('abolition')
    end
  end

  # ===========================================================================
  # #purchase_sigil_scrolls -- purchasing and stowing scrolls into books
  # ===========================================================================
  describe '#purchase_sigil_scrolls' do
    it 'orders from shop and stows scroll into book' do
      purchases = [{
        'book' => 'platinum-hued book',
        'sigil_type' => 'congruence',
        'order_number' => 3,
        'price' => 312,
        'room' => 14753,
        'needed' => 2
      }]
      instance = build_instance

      allow(DRCT).to receive(:order_item)
      allow(instance).to receive(:reget).and_return(nil)
      allow(DRCI).to receive(:put_away_item?).and_return(true)

      instance.send(:purchase_sigil_scrolls, purchases)

      expect(DRCT).to have_received(:order_item).with(14753, 3).exactly(2).times
      expect(DRCI).to have_received(:put_away_item?)
        .with('congruence sigil-scroll', 'platinum-hued book').exactly(2).times
    end

    it 'stops purchasing when put_away_item fails' do
      purchases = [{
        'book' => 'platinum-hued book',
        'sigil_type' => 'congruence',
        'order_number' => 3,
        'price' => 312,
        'room' => 14753,
        'needed' => 5
      }]
      instance = build_instance

      allow(DRCT).to receive(:order_item)
      allow(instance).to receive(:reget).and_return(nil)
      put_count = 0
      allow(DRCI).to receive(:put_away_item?) do
        put_count += 1
        put_count <= 2
      end
      allow(DRCI).to receive(:stow_hands)

      instance.send(:purchase_sigil_scrolls, purchases)

      # Stopped after 3rd order (2 succeed, 3rd fails)
      expect(DRCT).to have_received(:order_item).exactly(3).times
      expect(DRCI).to have_received(:stow_hands)
    end

    it 'does nothing when purchase list is empty' do
      instance = build_instance

      allow(DRCT).to receive(:order_item)

      instance.send(:purchase_sigil_scrolls, [])

      expect(DRCT).not_to have_received(:order_item)
    end
  end

  # ===========================================================================
  # #restock_default -- consolidated bank trip
  # ===========================================================================
  describe '#restock_default' do
    it 'combines regular item and sigil purchase costs in one withdrawal' do
      item = make_item('quantity' => 20, 'size' => 10, 'price' => 100)
      instance = build_instance

      allow(instance).to receive(:count_nonstackable_item).and_return(0)
      allow(instance).to receive(:collect_sigil_purchases).and_return([
        { 'needed' => 5, 'price' => 200, 'room' => 14753 }
      ])
      allow(DRCI).to receive(:stow_hands)
      allow(DRCM).to receive(:deposit_coins)
      allow(instance).to receive(:purchase_item)
      allow(instance).to receive(:handle_encumbrance)
      allow(instance).to receive(:stow_item)
      allow(instance).to receive(:purchase_sigil_scrolls)

      # regular: 2 buys * 100 = 200; bribe: 2502 * 1 = 2502
      # sigil: 5 * 200 = 1000; sigil bribe: 2502 * 1 = 2502
      # total: 200 + 2502 + 1000 + 2502 = 7204
      expected_coin = 200 + 2502 + 1000 + 2502
      expect(DRCM).to receive(:ensure_copper_on_hand).with(expected_coin, anything, 'Crossing')

      instance.send(:restock_default, [item], 'Crossing')
    end

    it 'returns early when nothing needs restocking and no sigil purchases' do
      item = make_item('quantity' => 10)
      instance = build_instance

      allow(instance).to receive(:count_nonstackable_item).and_return(10)
      allow(instance).to receive(:collect_sigil_purchases).and_return([])
      allow(DRCI).to receive(:stow_hands)
      allow(DRCM).to receive(:ensure_copper_on_hand)

      instance.send(:restock_default, [item], 'Crossing')

      expect(DRCI).not_to have_received(:stow_hands)
      expect(DRCM).not_to have_received(:ensure_copper_on_hand)
    end

    it 'proceeds when only sigil purchases are needed' do
      instance = build_instance

      allow(instance).to receive(:collect_sigil_purchases).and_return([
        { 'needed' => 3, 'price' => 100, 'room' => 14753 }
      ])
      allow(DRCI).to receive(:stow_hands)
      allow(DRCM).to receive(:ensure_copper_on_hand)
      allow(DRCM).to receive(:deposit_coins)
      allow(instance).to receive(:purchase_sigil_scrolls)

      # sigil: 3 * 100 = 300; bribe: 2502 * 1 room = 2502
      expected_coin = 300 + 2502
      expect(DRCM).to receive(:ensure_copper_on_hand).with(expected_coin, anything, 'Crossing')

      instance.send(:restock_default, [], 'Crossing')
    end

    it 'pads bribe per unique sigil room, not per purchase' do
      instance = build_instance

      allow(instance).to receive(:collect_sigil_purchases).and_return([
        { 'needed' => 2, 'price' => 100, 'room' => 14753 },
        { 'needed' => 3, 'price' => 200, 'room' => 14753 },
        { 'needed' => 1, 'price' => 50, 'room' => 9999 }
      ])
      allow(DRCI).to receive(:stow_hands)
      allow(DRCM).to receive(:deposit_coins)
      allow(instance).to receive(:purchase_sigil_scrolls)

      # sigil cost: 2*100 + 3*200 + 1*50 = 850
      # bribe: 2502 * 2 unique rooms = 5004
      expected_coin = 850 + 5004
      expect(DRCM).to receive(:ensure_copper_on_hand).with(expected_coin, anything, 'Crossing')

      instance.send(:restock_default, [], 'Crossing')
    end
  end

  # ===========================================================================
  # #parse_restockable_items -- sigil_books key filtering
  # ===========================================================================
  describe '#parse_restockable_items' do
    let(:consumables) do
      {
        'arrow' => {
          'name'      => 'arrow',
          'size'      => 10,
          'price'     => 100,
          'room'      => 1234,
          'stackable' => false,
          'quantity'  => 20
        }
      }
    end

    it 'merges base-consumables data for known items' do
      restock_config = { 'arrow' => { 'quantity' => 30 } }
      instance = build_instance(restock: restock_config, hometown: 'Crossing')

      $test_data = OpenStruct.new(consumables: { 'Crossing' => consumables })

      result = instance.send(:parse_restockable_items)

      expect(result.length).to eq(1)
      item = result.first
      expect(item['quantity']).to eq(30)
      expect(item['name']).to eq('arrow')
      expect(item['size']).to eq(10)
      expect(item['price']).to eq(100)
    end

    it 'preserves all user overrides over base-consumables defaults' do
      restock_config = { 'arrow' => { 'quantity' => 50, 'price' => 200 } }
      instance = build_instance(restock: restock_config, hometown: 'Crossing')

      $test_data = OpenStruct.new(consumables: { 'Crossing' => consumables })

      result = instance.send(:parse_restockable_items)
      item = result.first

      expect(item['quantity']).to eq(50)
      expect(item['price']).to eq(200)
    end

    it 'accepts fully custom items with all required fields' do
      restock_config = {
        'custom_thing' => {
          'name'      => 'widget',
          'size'      => 1,
          'room'      => 9999,
          'price'     => 50,
          'stackable' => false,
          'quantity'  => 5
        }
      }
      instance = build_instance(restock: restock_config, hometown: 'Crossing')

      $test_data = OpenStruct.new(consumables: { 'Crossing' => {} })

      result = instance.send(:parse_restockable_items)

      expect(result.length).to eq(1)
      expect(result.first['name']).to eq('widget')
    end

    it 'rejects custom items missing required fields' do
      restock_config = {
        'broken_thing' => { 'name' => 'widget' }
      }
      instance = build_instance(restock: restock_config, hometown: 'Crossing')

      $test_data = OpenStruct.new(consumables: { 'Crossing' => {} })

      result = instance.send(:parse_restockable_items)

      expect(result).to be_empty
    end

    it 'skips base-consumables lookup when item specifies custom hometown' do
      restock_config = {
        'arrow' => {
          'hometown'  => 'Shard',
          'name'      => 'arrow',
          'size'      => 10,
          'room'      => 5678,
          'price'     => 150,
          'stackable' => false,
          'quantity'  => 20
        }
      }
      instance = build_instance(restock: restock_config, hometown: 'Crossing')

      $test_data = OpenStruct.new(consumables: { 'Crossing' => consumables })

      result = instance.send(:parse_restockable_items)

      expect(result.length).to eq(1)
      expect(result.first['price']).to eq(150)
      expect(result.first['room']).to eq(5678)
    end

    it 'excludes the sigil_books key from regular item parsing' do
      restock_config = {
        'arrow' => { 'quantity' => 30 },
        'sigil_books' => {
          'platinum-hued book' => {
            'container' => 'satchel',
            'congruence' => { 'quantity' => 20, 'room' => 14753, 'order_number' => 3, 'price' => 312 }
          }
        }
      }
      instance = build_instance(restock: restock_config, hometown: 'Crossing')

      $test_data = OpenStruct.new(consumables: { 'Crossing' => consumables })

      result = instance.send(:parse_restockable_items)

      expect(result.length).to eq(1)
      expect(result.first['name']).to eq('arrow')
    end
  end

  # ===========================================================================
  # #valid_item_data? -- required field validation
  # ===========================================================================
  describe '#valid_item_data?' do
    it 'returns true when all required fields are present' do
      instance = build_instance
      expect(instance.send(:valid_item_data?, make_item)).to be true
    end

    %w[name size room price stackable quantity].each do |field|
      it "returns false when '#{field}' is missing" do
        item = make_item
        item.delete(field)
        instance = build_instance
        expect(instance.send(:valid_item_data?, item)).to be false
      end
    end
  end
end
