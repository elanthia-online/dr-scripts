# frozen_string_literal: true

require 'ostruct'

# Load the shared test harness (Flags, DRStats, DRRoom, GameObj, fput, pause, ...).
load File.join(File.dirname(__FILE__), '..', 'test', 'test_harness.rb')
include Harness

# Extract and eval the SellLoot class from sell-loot.lic without running the
# top-level code (before_dying block and SellLoot.new) at the bottom of the file.
#
# @param filename [String] path to the .lic file relative to the repo root
# @param class_name [String] the class to extract
# @return [void]
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

# The commons layer (DRC/DRCT/DRCI/DRCM) is not loadable in specs, so provide
# minimal stub modules with safe defaults. Individual tests override specific
# methods with `allow(...).to receive(...)`.
module DRC
  class << self
    def bput(*_args); ''; end
    def get_gems(*_args); []; end
    def get_town_name(name); name; end
    def release_invisibility; end
    def left_hand; nil; end
    def right_hand; nil; end
    def message(*_args); end
  end
end

module DRCT
  class << self
    def walk_to(*_args); true; end
  end
end

module DRCI
  class << self
    def exists?(*_args); false; end
    def get_item_list(*_args); []; end
    def count_items_in_container(*_args); 0; end
    def put_away_item?(*_args); true; end
    def wear_item?(*_args); true; end
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

    def check_wealth(*_args); 0; end
    def deposit_coins(*_args); end
  end
end

# The .lic instantiates EquipmentManager and calls empty_hands during init.
class EquipmentManager
  def empty_hands; end
end

load_lic_class('sell-loot.lic', 'SellLoot')

RSpec.configure do |config|
  config.before(:each) do
    reset_data
    $CURRENCIES = %w[kronars lirums dokoras]
    $HOMETOWN_REGEX = /Crossing|Riverhaven/i
  end
end

RSpec.describe SellLoot do
  # -- fixtures ---------------------------------------------------------------

  # Build a fully-shaped hometown hash with every shop the script may query.
  #
  # @param overrides [Hash] shop keys to replace or remove (set to nil to drop)
  # @return [Hash] hometown data as returned by get_data('town')[name]
  def make_hometown(overrides = {})
    {
      'currency'     => 'kronars',
      'exchange'     => { 'id' => 100 },
      'gemshop'      => { 'id' => 200, 'name' => 'Grishna' },
      'tannery'      => { 'id' => 300 },
      'locksmithing' => { 'id' => 400, 'name' => 'Locke' }
    }.merge(overrides)
  end

  # Build the settings OpenStruct the script reads. All selling is off by
  # default so each test opts in only to the feature under test.
  #
  # @param overrides [Hash] settings keys to set
  # @return [OpenStruct] settings object
  def make_settings(overrides = {})
    OpenStruct.new({
      hometown: 'Crossing',
      sell_loot_pouch: false,
      sell_loot_metals_and_stones: false,
      sell_loot_bundle: false,
      sell_loot_traps: false,
      gem_pouch_adjective: 'soft',
      gem_pouch_noun: 'pouch'
    }.merge(overrides))
  end

  # The metal/stone material catalog get_data('items') returns.
  #
  # @return [Hash] items data with metal_types and stone_types
  def items_data
    {
      'metal_types' => %w[iron gold] + ['yellow gold'],
      'stone_types' => %w[jade onyx]
    }
  end

  # Instantiate SellLoot without running its god-initialize, then set only the
  # instance variables the method under test needs.
  #
  # @param ivars [Hash{Symbol=>Object}] instance variables to assign
  # @return [SellLoot] an uninitialized instance ready for unit testing
  def build_instance(**ivars)
    instance = SellLoot.allocate
    defaults = {
      settings: make_settings,
      hometown: make_hometown,
      spare_gem_pouch_target: 5,
      sort_auto_head: false,
      autoloot_container: nil,
      autoloot_metals: nil,
      local_currency: 'kronars',
      character_hometown: 'Crossing'
    }
    defaults.merge(ivars).each { |k, v| instance.instance_variable_set(:"@#{k}", v) }
    instance
  end

  # Stub DRC.bput to answer based on the command text. Exact-match keys win;
  # otherwise the first key that is a substring of the command is used.
  #
  # @param responses [Hash{String=>String}] command text => game line to return
  # @return [void]
  def stub_bput(responses)
    allow(DRC).to receive(:bput) do |command, *_patterns|
      if responses.key?(command)
        responses[command]
      else
        pair = responses.find { |key, _| command.include?(key) }
        pair ? pair.last : ''
      end
    end
  end

  # Collect the game commands the script sends via fput during a block.
  #
  # @yield the code that should emit commands
  # @return [Array<String>] commands sent, in order
  def capture_commands
    yield
    commands = []
    commands << sent_messages.pop until sent_messages.empty?
    commands
  end

  # =========================================================================
  # #validate_settings
  # =========================================================================
  describe '#validate_settings' do
    it 'passes when nothing is enabled' do
      instance = build_instance(settings: make_settings)
      expect(instance.validate_settings).to be true
    end

    it 'fails when pouch selling is on but the gem pouch nouns are missing' do
      instance = build_instance(
        settings: make_settings(sell_loot_pouch: true, gem_pouch_adjective: nil, gem_pouch_noun: nil)
      )
      expect(instance.validate_settings).to be false
    end

    it 'fails when metals selling is on but no container is configured' do
      instance = build_instance(
        settings: make_settings(sell_loot_metals_and_stones: true, sell_loot_metals_and_stones_container: nil)
      )
      expect(instance.validate_settings).to be false
    end

    it 'fails when trap selling is on but there is no pick config at all' do
      instance = build_instance(settings: make_settings(sell_loot_traps: true, pick: nil))
      expect(instance.validate_settings).to be false
    end

    it 'passes when trap selling falls back to the top-level component_container' do
      instance = build_instance(
        settings: make_settings(sell_loot_traps: true, pick: {}, component_container: 'thigh sheath')
      )
      expect(instance.validate_settings).to be true
    end

    it 'reports every problem at once rather than short-circuiting on the first' do
      instance = build_instance(
        settings: make_settings(
          sell_loot_pouch: true, gem_pouch_adjective: nil, gem_pouch_noun: nil,
          sell_loot_metals_and_stones: true, sell_loot_metals_and_stones_container: nil
        )
      )
      messages = []
      allow(DRC).to receive(:message) { |m| messages << m }
      instance.validate_settings
      expect(messages.count { |m| m.include?('ERROR') }).to eq(2)
    end
  end

  # =========================================================================
  # #which_clerk
  # =========================================================================
  describe '#which_clerk' do
    it 'returns the name directly when configured as a string' do
      expect(build_instance.which_clerk('Grishna')).to eq('Grishna')
    end

    it 'picks the clerk that is actually present in the room' do
      DRRoom.npcs = ['Grishna']
      expect(build_instance.which_clerk(%w[Absent Grishna])).to eq('Grishna')
    end

    it 'returns nil when no configured clerk is present (sharp corner)' do
      DRRoom.npcs = ['Someone Else']
      # SHARP CORNER: a nil clerk yields malformed "sell my gem to " commands
      # downstream. This locks the current behavior so a future fix is deliberate.
      expect(build_instance.which_clerk(%w[Grishna Absent])).to be_nil
    end
  end

  # =========================================================================
  # #has_gems_to_sell?
  # =========================================================================
  describe '#has_gems_to_sell?' do
    it 'is true when the pouch opens and contains gems' do
      stub_bput('open my soft pouch' => 'You open your')
      allow(DRC).to receive(:get_gems).and_return(%w[ruby emerald])
      expect(build_instance.has_gems_to_sell?('soft pouch')).to be true
    end

    it 'is false when the pouch opens but is empty' do
      stub_bput('open my soft pouch' => 'You open your')
      allow(DRC).to receive(:get_gems).and_return([])
      expect(build_instance.has_gems_to_sell?('soft pouch')).to be false
    end

    it 'is false and warns when the pouch is tied off' do
      stub_bput('open my soft pouch' => 'has been tied off')
      expect(DRC).to receive(:message).with(/Unable to open/)
      expect(build_instance.has_gems_to_sell?('soft pouch')).to be false
    end

    it 'never raises when the commons layer blows up' do
      allow(DRC).to receive(:bput).and_raise(StandardError, 'stream desync')
      expect { build_instance.has_gems_to_sell?('soft pouch') }.not_to raise_error
      expect(build_instance.has_gems_to_sell?('soft pouch')).to be false
    end

    it 'leaves the pouch open (documents a known footgun)' do
      # KNOWN FOOTGUN: the read-only detection path opens the pouch and does not
      # close it, ignoring sell_loot_skip_pouch_close. Pinned intentionally.
      stub_bput('open my soft pouch' => 'You open your')
      allow(DRC).to receive(:get_gems).and_return([])
      commands = capture_commands { build_instance.has_gems_to_sell?('soft pouch') }
      expect(commands).not_to include('close my soft pouch')
    end
  end

  # =========================================================================
  # #has_metals_to_sell?
  # =========================================================================
  describe '#has_metals_to_sell?' do
    before { $test_data.items = items_data }

    it 'is true when a sellable nugget or bar is present' do
      allow(DRCI).to receive(:get_item_list).and_return(['small iron bar', 'a worthless rock'])
      expect(build_instance.has_metals_to_sell?('sack')).to be true
    end

    it 'is false when the container is empty' do
      allow(DRCI).to receive(:get_item_list).and_return([])
      expect(build_instance.has_metals_to_sell?('sack')).to be false
    end

    it 'is false and does not raise when the container cannot be read (nil list)' do
      # get_item_list is documented to return nil on rummage failure.
      allow(DRCI).to receive(:get_item_list).and_return(nil)
      expect { build_instance.has_metals_to_sell?('sack') }.not_to raise_error
      expect(build_instance.has_metals_to_sell?('sack')).to be false
    end

    it 'is false when the only materials present are on the ignore list' do
      instance = build_instance(
        settings: make_settings(sell_loot_ignored_metals_and_stones: %w[iron])
      )
      allow(DRCI).to receive(:get_item_list).and_return(['small iron bar'])
      expect(instance.has_metals_to_sell?('sack')).to be false
    end

    it 'matches multi-word materials such as yellow gold' do
      allow(DRCI).to receive(:get_item_list).and_return(['large yellow gold nugget'])
      expect(build_instance.has_metals_to_sell?('sack')).to be true
    end
  end

  # =========================================================================
  # #has_bundle_to_sell? and #has_traps_to_sell?
  # =========================================================================
  describe '#has_bundle_to_sell?' do
    it 'delegates to DRCI.exists?' do
      allow(DRCI).to receive(:exists?).with('bundle').and_return(true)
      expect(build_instance.has_bundle_to_sell?).to be true
    end

    it 'never raises when the check blows up' do
      allow(DRCI).to receive(:exists?).and_raise(StandardError)
      expect(build_instance.has_bundle_to_sell?).to be false
    end
  end

  describe '#has_traps_to_sell?' do
    it 'is false for non-thieves without touching the game' do
      DRStats.guild = 'Empath'
      expect(DRC).not_to receive(:bput)
      expect(build_instance.has_traps_to_sell?('sheath')).to be false
    end

    it 'is true for a thief whose container holds something' do
      DRStats.guild = 'Thief'
      stub_bput('look in my sheath' => 'you see')
      expect(build_instance.has_traps_to_sell?('sheath')).to be true
    end

    it 'is false for a thief whose container is empty' do
      DRStats.guild = 'Thief'
      stub_bput('look in my sheath' => 'There is nothing in there')
      expect(build_instance.has_traps_to_sell?('sheath')).to be false
    end
  end

  # =========================================================================
  # #has_loot_to_sell?  (aggregation across every loot source)
  # =========================================================================
  describe '#has_loot_to_sell?' do
    it 'is false when every selling feature is disabled' do
      expect(build_instance(settings: make_settings).has_loot_to_sell?).to be false
    end

    it 'is true if gems are present even when other sources are empty' do
      instance = build_instance(settings: make_settings(sell_loot_pouch: true))
      allow(instance).to receive(:has_gems_to_sell?).and_return(true)
      expect(instance.has_loot_to_sell?).to be true
    end

    it 'checks every configured metals container, including the autoloot bag' do
      $test_data.items = items_data
      instance = build_instance(
        settings: make_settings(
          sell_loot_metals_and_stones: true,
          sell_loot_metals_and_stones_container: %w[sack backpack]
        ),
        autoloot_container: 'loot sack',
        autoloot_metals: true
      )
      checked = []
      allow(instance).to receive(:has_metals_to_sell?) { |c| checked << c; false }
      instance.has_loot_to_sell?
      expect(checked).to contain_exactly('sack', 'backpack', 'loot sack')
    end
  end

  # =========================================================================
  # #sell_gems
  # =========================================================================
  describe '#sell_gems' do
    it 'sells each gem to the gemshop clerk after walking there' do
      stub_bput('open my soft pouch' => 'You open your')
      allow(DRC).to receive(:get_gems).and_return(%w[ruby emerald])
      expect(DRCT).to receive(:walk_to).with(200).and_return(true)

      commands = capture_commands { build_instance.sell_gems('soft pouch') }

      expect(commands).to include('get my ruby from my soft pouch', 'sell my ruby to Grishna')
      expect(commands).to include('get my emerald from my soft pouch', 'sell my emerald to Grishna')
    end

    it 'closes the pouch when empty unless configured to skip closing' do
      stub_bput('open my soft pouch' => 'You open your')
      allow(DRC).to receive(:get_gems).and_return([])
      commands = capture_commands { build_instance.sell_gems('soft pouch') }
      expect(commands).to include('close my soft pouch')
    end

    it 'honors sell_loot_skip_pouch_close' do
      instance = build_instance(settings: make_settings(sell_loot_skip_pouch_close: true))
      stub_bput('open my soft pouch' => 'You open your')
      allow(DRC).to receive(:get_gems).and_return([])
      commands = capture_commands { instance.sell_gems('soft pouch') }
      expect(commands).not_to include('close my soft pouch')
    end

    it 'does not walk anywhere when the pouch is tied off' do
      stub_bput('open my soft pouch' => 'has been tied off')
      expect(DRCT).not_to receive(:walk_to)
      build_instance.sell_gems('soft pouch')
    end
  end

  # =========================================================================
  # #sell_metals_and_stones  (and detection/action parity)
  # =========================================================================
  describe '#sell_metals_and_stones' do
    before { $test_data.items = items_data }

    it 'sells matching items by material and noun, dropping the size word' do
      allow(DRCI).to receive(:get_item_list).and_return(['small iron bar', 'large yellow gold nugget'])
      commands = capture_commands { build_instance.sell_metals_and_stones('sack') }
      expect(commands).to include('get my iron bar from my sack', 'sell my iron bar to Grishna')
      expect(commands).to include('get my yellow gold nugget from my sack', 'sell my yellow gold nugget to Grishna')
    end

    it 'does not walk to the gemshop when nothing is sellable' do
      allow(DRCI).to receive(:get_item_list).and_return(['a worthless rock'])
      expect(DRCT).not_to receive(:walk_to)
      build_instance.sell_metals_and_stones('sack')
    end

    # Detection and action must agree: if has_metals_to_sell? says yes, selling
    # must actually issue sell commands, and vice versa. This guards the DRY
    # refactor planned for the follow-up PR.
    [
      ['a mixed bag', ['small iron bar', 'a rock'],        true],
      ['only junk',   ['a rock', 'a stick'],               false],
      ['empty',       [],                                  false],
      ['multi-word',  ['large yellow gold nugget'],        true]
    ].each do |label, contents, expected|
      it "detection and selling agree for #{label}" do
        allow(DRCI).to receive(:get_item_list).and_return(contents)
        detected = build_instance.has_metals_to_sell?('sack')
        commands = capture_commands { build_instance.sell_metals_and_stones('sack') }
        sold = commands.any? { |c| c.start_with?('sell my') }
        expect(detected).to eq(expected)
        expect(sold).to eq(expected)
      end
    end

    it 'does not raise or walk when the container cannot be read (nil list)' do
      # Regression: get_item_list is documented to return nil on rummage
      # failure, and container state can change between the preflight check and
      # this call, so the sell path must guard nil the same way detection does.
      allow(DRCI).to receive(:get_item_list).and_return(nil)
      expect(DRCT).not_to receive(:walk_to)
      expect { build_instance.sell_metals_and_stones('sack') }.not_to raise_error
    end
  end

  # =========================================================================
  # #sell_bundle  (including the nil-hand cleanup bugfix)
  # =========================================================================
  describe '#sell_bundle' do
    it 'does nothing when the bundle holds no skins' do
      stub_bput('count my bundle' => 'You flip through your bundle and find 0 skins in it')
      expect(DRCT).not_to receive(:walk_to)
      build_instance.sell_bundle
    end

    it 'walks to the tannery and sells when skins are present' do
      stub_bput(
        'count my bundle'  => 'You flip through your bundle and find 5 skins in it',
        'remove my bundle' => 'You remove',
        'sell my bundle'   => 'takes the bundle'
      )
      expect(DRCT).to receive(:walk_to).with(300).and_return(true)
      build_instance.sell_bundle
    end

    it 'does not crash cleaning up empty hands after selling (nil-hand bugfix)' do
      stub_bput(
        'count my bundle'  => 'You flip through your bundle and find 5 skins in it',
        'remove my bundle' => 'You remove',
        'sell my bundle'   => 'takes the bundle'
      )
      allow(DRC).to receive(:left_hand).and_return(nil)
      allow(DRC).to receive(:right_hand).and_return(nil)
      expect(DRCI).not_to receive(:put_away_item?)
      expect { build_instance.sell_bundle }.not_to raise_error
    end

    it 'stows the leftover rope left in hand after selling' do
      stub_bput(
        'count my bundle'  => 'You flip through your bundle and find 5 skins in it',
        'remove my bundle' => 'You remove',
        'sell my bundle'   => 'takes the bundle'
      )
      allow(DRC).to receive(:left_hand).and_return('coil of rope')
      allow(DRC).to receive(:right_hand).and_return(nil)
      expect(DRCI).to receive(:put_away_item?).with('rope')
      build_instance.sell_bundle
    end

    it 'wears the bundle back when it was handed back unsold' do
      stub_bput(
        'count my bundle'  => 'You flip through your bundle and find 5 skins in it',
        'remove my bundle' => 'You remove',
        'sell my bundle'   => "I don't think I can give you anything for that worthless thing"
      )
      allow(DRC).to receive(:left_hand).and_return('leather bundle')
      allow(DRC).to receive(:right_hand).and_return(nil)
      allow(DRCI).to receive(:wear_item?).and_return(true)
      expect(DRCI).to receive(:wear_item?).with('bundle')
      build_instance.sell_bundle
    end
  end

  # =========================================================================
  # #check_spare_pouch
  # =========================================================================
  describe '#check_spare_pouch' do
    it 'buys exactly enough pouches to reach the target' do
      allow(DRCI).to receive(:count_items_in_container).and_return(2)
      allow(DRRoom).to receive(:npcs).and_return(['Grishna'])
      instance = build_instance(spare_gem_pouch_target: 5)

      commands = capture_commands { instance.check_spare_pouch('sack', 'soft') }

      expect(commands.count { |c| c == 'ask Grishna for soft pouch' }).to eq(3)
      expect(commands.count { |c| c == 'put my pouch in my sack' }).to eq(3)
    end

    it 'does not travel when already stocked at or above target' do
      allow(DRCI).to receive(:count_items_in_container).and_return(5)
      expect(DRCT).not_to receive(:walk_to)
      build_instance(spare_gem_pouch_target: 5).check_spare_pouch('sack', 'soft')
    end

    it 'counts by the full "adjective gem pouch" phrase, not the shorthand' do
      # Regression: the clerk hands back "a soft gem pouch"; counting by the
      # "soft pouch" shorthand matched differently and mis-restocked.
      expect(DRCI).to receive(:count_items_in_container).with('soft gem pouch', 'sack').and_return(5)
      build_instance(spare_gem_pouch_target: 5).check_spare_pouch('sack', 'soft')
    end
  end

  # =========================================================================
  # #exchange_coins
  # =========================================================================
  describe '#exchange_coins' do
    it 'exchanges every non-local currency into the local one' do
      commands = capture_commands { build_instance(hometown: make_hometown, local_currency: 'kronars').exchange_coins }
      expect(commands).to include('exchange all lirums for kronars', 'exchange all dokoras for kronars')
      expect(commands).not_to include('exchange all kronars for kronars')
    end

    it 'does nothing when the town has no exchange' do
      instance = build_instance(hometown: make_hometown('exchange' => nil))
      expect(DRCT).not_to receive(:walk_to)
      instance.exchange_coins
    end
  end

  # =========================================================================
  # #give_money_to_bankbot
  # =========================================================================
  describe '#give_money_to_bankbot' do
    it 'does not deposit when the balance is at or below the keep amount' do
      allow(DRCM).to receive(:check_wealth).and_return(100)
      expect(DRCT).not_to receive(:walk_to)
      build_instance.give_money_to_bankbot('kronars', 100)
    end

    it 'coerces a string keep amount before subtracting' do
      allow(DRCM).to receive(:check_wealth).and_return(500)
      allow(DRRoom).to receive(:pcs).and_return([])
      # keep is a string here; without to_i this raises. It should just walk and
      # bail because the bankbot is not in the room.
      expect { build_instance(bankbot_name: 'Teller', bankbot_room_id: 9).give_money_to_bankbot('kronars', '200') }
        .not_to raise_error
    end

    it 'bails without tipping when the bankbot is not in the room' do
      allow(DRCM).to receive(:check_wealth).and_return(5000)
      allow(DRRoom).to receive(:pcs).and_return(['Someone'])
      expect(DRC).not_to receive(:bput)
      build_instance(bankbot_name: 'Teller', bankbot_room_id: 9).give_money_to_bankbot('kronars', 0)
    end

    it 'stops after an outstanding-offer response without waiting on flags' do
      allow(DRCM).to receive(:check_wealth).and_return(5000)
      allow(DRRoom).to receive(:pcs).and_return(['Teller'])
      stub_bput('tip Teller' => 'You already have a tip offer outstanding')
      # If it fell through to the flag wait loop, pause is a no-op and this would
      # hang; returning early proves the branch is handled.
      expect { build_instance(bankbot_name: 'Teller', bankbot_room_id: 9).give_money_to_bankbot('kronars', 0) }
        .not_to raise_error
    end
  end

  # =========================================================================
  # #sell_traps
  # =========================================================================
  describe '#sell_traps' do
    it 'does nothing for non-thieves' do
      DRStats.guild = 'Empath'
      expect(DRC).not_to receive(:bput)
      build_instance.sell_traps('sheath')
    end

    it 'sells the component container to the locksmith on success' do
      DRStats.guild = 'Thief'
      DRRoom.pcs = []
      stub_bput(
        'look in my sheath' => 'you see',
        'remove my sheath'  => 'You remove',
        'give my sheath'    => 'hands it back to you along with some coins',
        'wear my sheath'    => 'You attach'
      )
      expect(DRCT).to receive(:walk_to).with(400).and_return(true)
      expect { build_instance.sell_traps('sheath') }.not_to raise_error
    end

    it 'stops when the container is empty' do
      DRStats.guild = 'Thief'
      stub_bput('look in my sheath' => 'There is nothing in there')
      expect(DRCT).not_to receive(:walk_to)
      build_instance.sell_traps('sheath')
    end
  end

  # =========================================================================
  # .new orchestration -- the PR1 pre-flight guarantee and guards
  # =========================================================================
  describe 'orchestration' do
    before do
      allow_any_instance_of(EquipmentManager).to receive(:empty_hands)
      allow(DRCM).to receive(:convert_to_copper).and_return(300)
    end

    it 'exits with an error and never moves when town data is missing' do
      $test_settings = make_settings(hometown: 'Nowhere')
      $test_data.town = {}
      allow(DRC).to receive(:get_town_name).and_return('Nowhere')
      expect(DRC).to receive(:message).with(/no town data found/)
      expect(DRCT).not_to receive(:walk_to)
      SellLoot.new
    end

    it 'never moves when the pre-flight finds no loot' do
      $test_settings = make_settings
      $test_data.town = { 'Crossing' => make_hometown }
      $test_data.items = items_data
      allow(DRC).to receive(:get_town_name).and_return('Crossing')
      allow_any_instance_of(SellLoot).to receive(:has_loot_to_sell?).and_return(false)
      expect(DRCT).not_to receive(:walk_to)
      expect_any_instance_of(SellLoot).not_to receive(:sell_gems)
      SellLoot.new
    end

    it 'skips depositing entirely when banking is skipped and no bankbot is set' do
      $test_settings = make_settings(sell_loot_skip_bank: true, bankbot_enabled: false)
      $test_data.town = { 'Crossing' => make_hometown }
      $test_data.items = items_data
      allow(DRC).to receive(:get_town_name).and_return('Crossing')
      allow_any_instance_of(SellLoot).to receive(:has_loot_to_sell?).and_return(true)
      expect(DRCM).not_to receive(:deposit_coins)
      SellLoot.new
    end
  end
end
