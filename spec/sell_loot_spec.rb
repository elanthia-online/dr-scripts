# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

# The commons layer (DRC/DRCT/DRCI/DRCM) is not loadable in specs, so provide
# minimal stub modules with safe defaults. Individual tests override specific
# methods with `allow(...).to receive(...)`.
# The .lic instantiates EquipmentManager and calls empty_hands during init.
class EquipmentManager
  def empty_hands; end
end

load_lic_class('sell-loot.lic', 'SellLoot')

RSpec.describe SellLoot do
  # World state this spec assumes (reset_data runs first, via spec_helper).
  before(:each) do
    $CURRENCIES = %w[kronars lirums dokoras]
    $HOMETOWN_REGEX = /Crossing|Riverhaven/i

    # Default navigation to succeed so shop-visit flows proceed. Examples that
    # assert on walk_to override this; stubbing here (rather than relying on the
    # module base) keeps the flow deterministic when other specs are co-loaded.
    allow(DRCT).to receive(:walk_to).and_return(true)
  end

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
      'pawnshop'     => { 'id' => 500, 'name' => 'Cormyn' },
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
      sell_loot_runestones: false,
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

    it 'fails when runestone selling is on but no container is configured' do
      instance = build_instance(
        settings: make_settings(sell_loot_runestones: true, sell_loot_runestones_container: nil)
      )
      expect(instance.validate_settings).to be false
    end

    it 'fails when runestone container is an empty array or non-String/Array type' do
      expect(build_instance(settings: make_settings(sell_loot_runestones: true, sell_loot_runestones_container: [])).validate_settings).to be false
      expect(build_instance(settings: make_settings(sell_loot_runestones: true, sell_loot_runestones_container: { 'a' => 1 })).validate_settings).to be false
    end

    it 'passes validation but skips runestones when container matches runestone_storage exactly' do
      %w[Zillinen\ Pouch zillinen\ pouch].each do |c|
        instance = build_instance(
          settings: make_settings(
            sell_loot_runestones: true,
            sell_loot_runestones_container: c,
            runestone_storage: 'zillinen pouch'
          )
        )
        messages = []
        allow(DRC).to receive(:message) { |m| messages << m }
        expect(instance.validate_settings).to be true
        expect(instance.instance_variable_get(:@skip_runestones)).to be true
        expect(messages.any? { |m| m.include?('WARNING') && m.include?('skipping runestone sales') }).to be true
      end
    end

    it 'passes validation but skips runestones when container matches runestone_storage by bare-noun ambiguity' do
      ['pouch', '  pouch  '].each do |c|
        instance = build_instance(
          settings: make_settings(
            sell_loot_runestones: true,
            sell_loot_runestones_container: c,
            runestone_storage: 'zillinen pouch'
          )
        )
        messages = []
        allow(DRC).to receive(:message) { |m| messages << m }
        expect(instance.validate_settings).to be true
        expect(instance.instance_variable_get(:@skip_runestones)).to be true
        expect(messages.any? { |m| m.include?('WARNING') && m.include?('skipping runestone sales') }).to be true
      end

      instance = build_instance(
        settings: make_settings(
          sell_loot_runestones: true,
          sell_loot_runestones_container: 'zillinen pouch',
          runestone_storage: 'pouch'
        )
      )
      messages = []
      allow(DRC).to receive(:message) { |m| messages << m }
      expect(instance.validate_settings).to be true
      expect(instance.instance_variable_get(:@skip_runestones)).to be true
      expect(messages.any? { |m| m.include?('WARNING') && m.include?('skipping runestone sales') }).to be true
    end

    it 'passes validation and does not skip runestones when distinct containers share a noun' do
      instance = build_instance(
        settings: make_settings(
          sell_loot_runestones: true,
          sell_loot_runestones_container: 'leather pouch',
          runestone_storage: 'silk pouch'
        )
      )
      messages = []
      allow(DRC).to receive(:message) { |m| messages << m }
      expect(instance.validate_settings).to be true
      expect(instance.instance_variable_get(:@skip_runestones)).to be_falsey
      expect(messages.none? { |m| m.include?('WARNING') }).to be true
    end

    it 'passes validation and does not skip runestones when container differs from runestone_storage' do
      instance = build_instance(
        settings: make_settings(
          sell_loot_runestones: true,
          sell_loot_runestones_container: 'haversack',
          runestone_storage: 'zillinen pouch'
        )
      )
      expect(instance.validate_settings).to be true
      expect(instance.instance_variable_get(:@skip_runestones)).to be_falsey
    end

    it 'warns per-container and does not skip all runestones when only one of multiple containers collides' do
      instance = build_instance(
        settings: make_settings(
          sell_loot_runestones: true,
          sell_loot_runestones_container: ['haversack', 'zillinen pouch'],
          runestone_storage: 'zillinen pouch'
        )
      )
      messages = []
      allow(DRC).to receive(:message) { |m| messages << m }
      expect(instance.validate_settings).to be true
      expect(instance.instance_variable_get(:@skip_runestones)).to be_falsey
      expect(messages.any? { |m| m.include?('WARNING') && m.include?("sell_loot_runestones_container 'zillinen pouch' matches runestone_storage") }).to be true
      expect(messages.none? { |m| m.include?('haversack') }).to be true
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

    context 'when trader selling is on' do
      def trader_settings(full, spare)
        make_settings(sell_loot_trader: true, sell_loot_trader_room: 5000,
                      full_pouch_container: full, spare_gem_pouch_container: spare)
      end

      it 'fails when full and spare pouches share a container' do
        instance = build_instance(settings: trader_settings('haversack', ' Haversack'))
        expect(instance.validate_settings).to be false
      end

      it 'passes when they are different containers' do
        instance = build_instance(settings: trader_settings('pack', 'sack'))
        expect(instance.validate_settings).to be true
      end

      it 'passes when no spares container is set' do
        instance = build_instance(settings: trader_settings('pack', nil))
        expect(instance.validate_settings).to be true
      end

      it 'passes with a list of trader rooms' do
        settings = trader_settings('pack', 'sack')
        settings.sell_loot_trader_room = [5000, '6000']
        expect(build_instance(settings: settings).validate_settings).to be true
      end

      it 'fails when any trader room is not a room number' do
        settings = trader_settings('pack', 'sack')
        settings.sell_loot_trader_room = [5000, 'kiosk row']
        messages = []
        allow(DRC).to receive(:message) { |m| messages << m }
        expect(build_instance(settings: settings).validate_settings).to be false
        expect(messages.join).to include('list of room numbers')
      end

      it 'fails when the trader room list is empty' do
        settings = trader_settings('pack', 'sack')
        settings.sell_loot_trader_room = []
        expect(build_instance(settings: settings).validate_settings).to be false
      end
    end

    it 'allows a shared container when trader selling is off' do
      instance = build_instance(
        settings: make_settings(full_pouch_container: 'haversack', spare_gem_pouch_container: 'haversack')
      )
      expect(instance.validate_settings).to be true
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
  # #wait_for_clerk  (failover + retry across multiple gem-shop NPCs)
  # =========================================================================
  describe '#wait_for_clerk' do
    it 'returns a single named clerk immediately without checking the room' do
      expect(DRRoom).not_to receive(:npcs)
      expect(build_instance.wait_for_clerk('Grishna')).to eq('Grishna')
    end

    it 'returns whichever configured candidate is present in the room' do
      DRRoom.npcs = ['attendant']
      expect(build_instance.wait_for_clerk(%w[Wickett attendant])).to eq('attendant')
    end

    it 'gives up and returns nil after exhausting all attempts when none appear' do
      DRRoom.npcs = ['some shopper']
      expect(build_instance.wait_for_clerk(%w[Wickett attendant])).to be_nil
    end

    it 'returns nil immediately without waiting when the clerk list is nil or empty' do
      instance = build_instance
      expect(instance).not_to receive(:pause)
      expect(instance.wait_for_clerk(nil)).to be_nil
      expect(instance.wait_for_clerk([])).to be_nil
    end

    it 'emits a verbose give-up message naming who and where it tried' do
      DRRoom.npcs = []
      messages = []
      allow(DRC).to receive(:message) { |m| messages << m }
      build_instance.wait_for_clerk(%w[Wickett attendant])
      give_up = messages.find { |m| m.include?('gave up') }
      expect(give_up).to include('Wickett and attendant')
      expect(give_up).to include('gem-shop')
    end

    it 'retries CLERK_MAX_ATTEMPTS times, pausing between each, before giving up' do
      DRRoom.npcs = []
      # pause is a no-op in the harness; count how many times it is asked to wait.
      pauses = 0
      allow_any_instance_of(SellLoot).to receive(:pause) { pauses += 1 }
      build_instance.wait_for_clerk(%w[Wickett attendant])
      # One fewer pause than attempts: the final attempt gives up instead of waiting.
      expect(pauses).to eq(SellLoot::CLERK_MAX_ATTEMPTS - 1)
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

    it 'checks only safe runestone containers, filtering out colliding ones' do
      instance = build_instance(
        settings: make_settings(
          sell_loot_runestones: true,
          sell_loot_runestones_container: ['haversack', 'zillinen pouch'],
          runestone_storage: 'zillinen pouch'
        )
      )
      checked = []
      allow(instance).to receive(:has_runestones_to_sell?) { |c| checked << c; false }
      instance.has_loot_to_sell?
      expect(checked).to eq(['haversack'])
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

    it 'skips selling but still closes the pouch when no clerk is present' do
      instance = build_instance(hometown: make_hometown('gemshop' => { 'id' => 200, 'name' => %w[Wickett attendant] }))
      DRRoom.npcs = []
      stub_bput('open my soft pouch' => 'You open your')
      allow(DRC).to receive(:get_gems).and_return(%w[ruby])
      commands = capture_commands { instance.sell_gems('soft pouch') }
      expect(commands.none? { |c| c.start_with?('sell my') }).to be true
      expect(commands).to include('close my soft pouch')
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

    it 'does not sell when no configured clerk is present' do
      instance = build_instance(hometown: make_hometown('gemshop' => { 'id' => 200, 'name' => %w[Wickett attendant] }))
      DRRoom.npcs = []
      allow(DRCI).to receive(:get_item_list).and_return(['small iron bar'])
      commands = capture_commands { instance.sell_metals_and_stones('sack') }
      expect(commands.none? { |c| c.start_with?('sell my') }).to be true
    end
  end

  # =========================================================================
  # #sell_runestones  (and detection/action parity)
  # =========================================================================
  describe '#sell_runestones' do
    it 'sells matching runestones by recognized mineral material and noun, dropping descriptive adjectives' do
      allow(DRCI).to receive(:get_item_list).and_return(['smooth quartz runestone', 'flawed calavarite runestone', 'a runestone', 'burden runestone'])
      commands = capture_commands { build_instance.sell_runestones('sack') }
      expect(commands).to include('get my quartz runestone from my sack', 'sell my quartz runestone to Cormyn')
      expect(commands).to include('get my calavarite runestone from my sack', 'sell my calavarite runestone to Cormyn')
      expect(commands.none? { |c| c.include?('burden') }).to be true
      expect(commands.none? { |c| c.end_with?('my runestone from my sack') }).to be true
    end

    it 'filters out runestones configured in sell_loot_ignored_runestones' do
      settings = make_settings(sell_loot_ignored_runestones: %w[quartz elbaite])
      instance = build_instance(settings: settings)
      allow(DRCI).to receive(:get_item_list).and_return(['smooth quartz runestone', 'elbaite runestone', 'flawed calavarite runestone'])
      commands = capture_commands { instance.sell_runestones('sack') }
      expect(commands).to include('get my calavarite runestone from my sack', 'sell my calavarite runestone to Cormyn')
      expect(commands.none? { |c| c.include?('quartz') }).to be true
      expect(commands.none? { |c| c.include?('elbaite') }).to be true
    end

    it 'automatically protects runestones configured for waggle spells' do
      settings = make_settings(
        sell_loot_runestones: true,
        waggle_sets: {
          'default' => {
            'Refresh' => { 'runestone_name' => 'quartz runestone' }
          }
        }
      )
      instance = build_instance(settings: settings)
      allow(DRCI).to receive(:get_item_list).and_return(['quartz runestone', 'topaz runestone'])
      commands = capture_commands { instance.sell_runestones('sack') }
      expect(commands).to include('get my topaz runestone from my sack', 'sell my topaz runestone to Cormyn')
      expect(commands.none? { |c| c.include?('quartz') }).to be true
    end

    it 'automatically protects runestones configured in buff_spells and offensive_spells' do
      settings = make_settings(
        sell_loot_runestones: true,
        buff_spells: { 'Bless' => { 'runestone_name' => 'elbaite runestone' } },
        offensive_spells: [{ 'runestone_name' => 'rhodonite runestone' }]
      )
      instance = build_instance(settings: settings)
      expect(instance.configured_cast_runestone_materials).to contain_exactly('elbaite', 'rhodonite')
    end

    it 'automatically protects runestones configured via short-form restock without explicit name' do
      $test_data.consumables = { 'Crossing' => { 'Refresh' => { 'name' => 'quartz runestone' } } }
      settings = make_settings(
        sell_loot_runestones: true,
        restock: { 'Refresh' => { 'quantity' => 2 } }
      )
      instance = build_instance(settings: settings)
      allow(DRCI).to receive(:get_item_list).and_return(['quartz runestone', 'topaz runestone'])
      commands = capture_commands { instance.sell_runestones('sack') }
      expect(commands).to include('get my topaz runestone from my sack', 'sell my topaz runestone to Cormyn')
      expect(commands.none? { |c| c.include?('quartz') }).to be true
      expect(instance.configured_cast_runestone_materials).to include('quartz')
    end

    it 'skips runestone materials entirely if a marked runestone of that material is present in the container' do
      allow(DRCI).to receive(:get_item_list).and_return([
                                                          'sunstone runestone marked with a symbol for Compost',
                                                          'sunstone runestone',
                                                          'calavarite runestone'
                                                        ])
      commands = capture_commands { build_instance.sell_runestones('sack') }
      expect(commands).to include('get my calavarite runestone from my sack', 'sell my calavarite runestone to Cormyn')
      expect(commands.none? { |c| c.include?('sunstone') }).to be true
    end

    it 'sells only excess runestones when keep_count is configured' do
      settings = make_settings(sell_loot_runestones_keep_count: 1)
      instance = build_instance(settings: settings)
      allow(DRCI).to receive(:get_item_list).and_return(['quartz runestone', 'quartz runestone', 'quartz runestone'])
      commands = capture_commands { instance.sell_runestones('sack') }
      expect(commands.count { |c| c.start_with?('sell my quartz runestone') }).to eq(2)
    end

    it 'does not sell bare runestones without a recognized mineral material' do
      allow(DRCI).to receive(:get_item_list).and_return(['elbaite runestone', 'runestone'])
      instance = build_instance(settings: make_settings(sell_loot_ignored_runestones: %w[elbaite]))
      commands = capture_commands { instance.sell_runestones('sack') }
      expect(commands).to be_empty
    end

    it 'does not treat crafting adjectives on artificed runestones as sellable mineral materials' do
      allow(DRCI).to receive(:get_item_list).and_return(['burden runestone', 'manifest force runestone'])
      commands = capture_commands { build_instance.sell_runestones('sack') }
      expect(commands).to be_empty
    end

    it 'anchors ignore-regex terms with word boundaries to avoid prefix/suffix false matches' do
      settings = make_settings(sell_loot_ignored_runestones: %w[quartz topaz])
      instance = build_instance(settings: settings)
      allow(DRCI).to receive(:get_item_list).and_return(['quartzite runestone', 'xtopaz runestone', 'calavarite runestone'])
      commands = capture_commands { instance.sell_runestones('sack') }
      expect(commands).to include('get my calavarite runestone from my sack', 'sell my calavarite runestone to Cormyn')
    end

    it 'correctly handles mineral names with apostrophes' do
      allow(DRCI).to receive(:get_item_list).and_return(["glossy iheaneu'a runestone"])
      commands = capture_commands { build_instance.sell_runestones('sack') }
      expect(commands).to include("get my iheaneu'a runestone from my sack", "sell my iheaneu'a runestone to Cormyn")
    end

    it 'handles sell_loot_ignored_runestones provided as a bare string without error' do
      settings = make_settings(sell_loot_ignored_runestones: 'quartz')
      instance = build_instance(settings: settings)
      allow(DRCI).to receive(:get_item_list).and_return(['quartz runestone', 'topaz runestone'])
      commands = capture_commands { instance.sell_runestones('sack') }
      expect(commands).to include('get my topaz runestone from my sack', 'sell my topaz runestone to Cormyn')
      expect(commands.none? { |c| c.include?('quartz') }).to be true
    end

    it 'walks to the pawnshop when sellable runestones are present' do
      allow(DRCI).to receive(:get_item_list).and_return(['smooth quartz runestone'])
      expect(DRCT).to receive(:walk_to).with(500).and_return(true)
      build_instance.sell_runestones('sack')
    end

    it 'does not walk to the pawnshop when nothing is sellable' do
      allow(DRCI).to receive(:get_item_list).and_return(['a worthless rock'])
      expect(DRCT).not_to receive(:walk_to)
      build_instance.sell_runestones('sack')
    end

    it 'does not walk or sell and notifies user when the hometown has no pawnshop configured' do
      instance = build_instance(hometown: make_hometown('pawnshop' => nil), character_hometown: 'Fang Cove')
      allow(DRCI).to receive(:get_item_list).and_return(['smooth quartz runestone'])
      messages = []
      allow(DRC).to receive(:message) { |m| messages << m }
      expect(DRCT).not_to receive(:walk_to)
      commands = capture_commands { instance.sell_runestones('sack') }
      expect(commands).to be_empty
      expect(messages).to include('No pawnshop configured for Fang Cove; skipping runestone sales.')
    end

    [
      ['a mixed bag',    ['smooth quartz runestone', 'a rock'], true],
      ['only junk',      ['a rock', 'a stick'],                  false],
      ['empty',          [],                                     false],
      ['bare runestone', ['a runestone'],                        false],
      ['valid mineral',  ['flawed calavarite runestone'],        true]
    ].each do |label, contents, expected|
      it "detection and selling agree for #{label}" do
        allow(DRCI).to receive(:get_item_list).and_return(contents)
        detected = build_instance.has_runestones_to_sell?('sack')
        commands = capture_commands { build_instance.sell_runestones('sack') }
        sold = commands.any? { |c| c.start_with?('sell my') }
        expect(detected).to eq(expected)
        expect(sold).to eq(expected)
      end
    end

    it 'does not raise or walk when the container cannot be read (nil list)' do
      allow(DRCI).to receive(:get_item_list).and_return(nil)
      expect(DRCT).not_to receive(:walk_to)
      expect { build_instance.sell_runestones('sack') }.not_to raise_error
    end

    it 'does not sell when no configured clerk is present' do
      instance = build_instance(hometown: make_hometown('pawnshop' => { 'id' => 500, 'name' => %w[Wickett attendant] }))
      DRRoom.npcs = []
      allow(DRCI).to receive(:get_item_list).and_return(['quartz runestone'])
      commands = capture_commands { instance.sell_runestones('sack') }
      expect(commands.none? { |c| c.start_with?('sell my') }).to be true
    end

    it 'does not sell when container collides with runestone_storage' do
      instance = build_instance(settings: make_settings(runestone_storage: 'zillinen pouch'))
      allow(DRCI).to receive(:get_item_list).and_return(['quartz runestone'])
      commands = capture_commands { instance.sell_runestones('zillinen pouch') }
      expect(commands).to be_empty
    end
  end

  # =========================================================================
  # #container_collides?
  # =========================================================================
  describe '#container_collides?' do
    let(:instance) { build_instance }

    it 'detects exact match case-insensitively and with normalized whitespace' do
      expect(instance.container_collides?('zillinen pouch', 'zillinen pouch')).to be true
      expect(instance.container_collides?('Zillinen Pouch', 'zillinen pouch')).to be true
      expect(instance.container_collides?('  zillinen   pouch  ', 'zillinen pouch')).to be true
    end

    it 'detects bare-noun ambiguity when either container is a single word' do
      expect(instance.container_collides?('pouch', 'zillinen pouch')).to be true
      expect(instance.container_collides?('zillinen pouch', 'pouch')).to be true
      expect(instance.container_collides?('pouch', 'pouch')).to be true
    end

    it 'detects prefix-abbreviated adjectives and additional adjectives on matching containers' do
      expect(instance.container_collides?('zill pouch', 'zillinen pouch')).to be true
      expect(instance.container_collides?('zillinen pouch', 'zill pouch')).to be true
      expect(instance.container_collides?('small zillinen pouch', 'zillinen pouch')).to be true
      expect(instance.container_collides?('zillinen pouch', 'small zillinen pouch')).to be true
    end

    it 'allows distinct multi-word containers sharing a noun' do
      expect(instance.container_collides?('leather pouch', 'silk pouch')).to be false
      expect(instance.container_collides?('small leather pouch', 'zillinen pouch')).to be false
    end

    it 'returns false for containers with different nouns' do
      expect(instance.container_collides?('haversack', 'zillinen pouch')).to be false
      expect(instance.container_collides?('backpack', 'satchel')).to be false
    end

    it 'returns false when either argument is nil or empty' do
      expect(instance.container_collides?(nil, 'zillinen pouch')).to be false
      expect(instance.container_collides?('haversack', nil)).to be false
      expect(instance.container_collides?('', 'zillinen pouch')).to be false
      expect(instance.container_collides?('haversack', '   ')).to be false
    end
  end

  # =========================================================================
  # #safe_runestone_containers
  # =========================================================================
  describe '#safe_runestone_containers' do
    it 'filters out colliding containers while preserving safe ones' do
      instance = build_instance(
        settings: make_settings(
          sell_loot_runestones_container: ['haversack', 'zillinen pouch', 'leather pouch'],
          runestone_storage: 'zillinen pouch'
        )
      )
      expect(instance.safe_runestone_containers).to eq(['haversack', 'leather pouch'])
    end

    it 'returns empty array when all configured containers collide' do
      instance = build_instance(
        settings: make_settings(
          sell_loot_runestones_container: 'zillinen pouch',
          runestone_storage: 'zillinen pouch'
        )
      )
      expect(instance.safe_runestone_containers).to eq([])
    end

    it 'returns empty array when container setting is nil or invalid' do
      expect(build_instance(settings: make_settings(sell_loot_runestones_container: nil)).safe_runestone_containers).to eq([])
      expect(build_instance(settings: make_settings(sell_loot_runestones_container: {})).safe_runestone_containers).to eq([])
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

    it 'does not ask for pouches when no configured clerk is present' do
      instance = build_instance(
        spare_gem_pouch_target: 5,
        hometown: make_hometown('gemshop' => { 'id' => 200, 'name' => %w[Wickett attendant] })
      )
      allow(DRCI).to receive(:count_items_in_container).and_return(0)
      DRRoom.npcs = []
      commands = capture_commands { instance.check_spare_pouch('sack', 'soft') }
      expect(commands.none? { |c| c.start_with?('ask') }).to be true
    end

    it 'names the town in use, not the profile hometown, when it has no gemshop' do
      instance = build_instance(character_hometown: 'Riverhaven', hometown: make_hometown('gemshop' => nil),
                                settings: make_settings(hometown: 'Crossing'))
      allow(DRCI).to receive(:count_items_in_container).and_return(0)
      expect(DRC).to receive(:message).with(a_string_including('no gemshop is mapped for Riverhaven'))
      instance.check_spare_pouch('sack', 'soft')
    end
  end

  # =========================================================================
  # #exchange_coins
  # =========================================================================
  describe '#exchange_coins' do
    it 'exchanges every non-local currency into the local one' do
      # exchange_coins bputs now, so capture_commands -- which collects fput --
      # no longer sees the command.
      commands = []
      allow(DRC).to receive(:bput) do |command, *_patterns|
        commands << command
        ''
      end
      build_instance(hometown: make_hometown, local_currency: 'kronars').exchange_coins
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
  # #exchange_all
  # =========================================================================
  describe '#exchange_all' do
    let(:jar_refusal) do
      'One of the guards barks out, "No, sir.  I\'m afraid you\'ll have to work with values ' \
        'no greater than %<cap>s platinum at a time."'
    end
    let(:changer_refusal) do
      'The money-changer shakes his head, "I\'d really rather not handle transactions ' \
        'larger than a thousand platinum."'
    end
    let(:messages) { [] }

    before { allow(DRC).to receive(:message) { |text| messages << text } }

    # Stand in for a money-changer. The cap is on the coin handed over, so
    # `exchange all` is refused while the purse is over it, and an explicit
    # amount is refused when it is over it. The fee varies by bank, so the
    # success line quotes whatever fee the example asks for.
    #
    # @param purse [Integer] platinum dokoras on hand
    # @param cap [Integer] most platinum the changer takes at once
    # @param refusal [String] refusal line; %<cap>s is filled in with cap
    # @param done [String] success line
    # @param refuse_amounts [Boolean] refuse every explicit amount
    # @return [Array<String>] the commands sent, filled in as the example runs
    def simulate_changer(purse:, refusal:, cap: 1000, done: 'After figuring a 5% fee, the money-changer hands you your coins.',
                         refuse_amounts: false)
      commands = []
      refused = format(refusal, cap: cap.to_s.reverse.scan(/\d{1,3}/).join(',').reverse)
      reply = lambda do |command|
        case command
        when /^exchange all /
          if purse.zero?
            "You don't have any dokoras."
          elsif purse > cap
            refused
          else
            purse = 0
            done
          end
        when /^exchange (\d+) platinum /
          amount = Regexp.last_match(1).to_i
          next refused if refuse_amounts || amount > cap

          purse -= amount
          done
        end
      end
      # Like DRC.bput: the first pattern that matches wins, '' on no match.
      allow(DRC).to receive(:bput) do |command, *patterns|
        commands << command
        line = reply.call(command).to_s
        patterns.lazy.map { |pattern| line[pattern] }.find(&:itself).to_s
      end
      commands
    end

    def chunks(commands)
      commands.grep(/^exchange \d+ platinum/)
    end

    it 'chunks past a money-changer that spells the cap out, then exchanges the rest' do
      commands = simulate_changer(purse: 2500, refusal: changer_refusal)
      build_instance.exchange_all('dokoras', 'kronars')

      expect(commands).to eq([
                               'exchange all dokoras for kronars',
                               'exchange 1000 platinum dokoras to kronars',
                               'exchange all dokoras for kronars',
                               'exchange 1000 platinum dokoras to kronars',
                               'exchange all dokoras for kronars'
                             ])
      expect(messages).to be_empty
    end

    it 'reads a comma-grouped cap out of the jar-bank wording' do
      commands = simulate_changer(purse: 2500, refusal: jar_refusal,
                                  done: 'After collecting a 1% fee, the clerk reaches into a jar.')
      build_instance.exchange_all('dokoras', 'kronars')

      expect(chunks(commands)).to eq(['exchange 1000 platinum dokoras to kronars'] * 2)
      expect(messages).to be_empty
    end

    it 'chunks by whatever cap the changer quotes' do
      commands = simulate_changer(purse: 1200, cap: 500, refusal: jar_refusal,
                                  done: 'After figuring a 10% fee, the money-changer hands you your coins.')
      build_instance.exchange_all('dokoras', 'kronars')

      expect(chunks(commands)).to eq(['exchange 500 platinum dokoras to kronars'] * 2)
      expect(commands.last).to eq('exchange all dokoras for kronars')
      expect(messages).to be_empty
    end

    it 'stops with a message after one refused chunk instead of looping on it' do
      commands = simulate_changer(purse: 2500, refusal: changer_refusal, refuse_amounts: true)
      build_instance.exchange_all('dokoras', 'kronars')

      expect(chunks(commands).size).to eq(1)
      expect(messages.size).to eq(1)
      expect(messages.first).to include('would not take 1000 platinum dokoras')
    end

    it 'gives up with a message after 12 passes rather than spinning' do
      commands = simulate_changer(purse: 13_000, refusal: changer_refusal)
      build_instance.exchange_all('dokoras', 'kronars')

      expect(chunks(commands).size).to eq(12)
      expect(messages.size).to eq(1)
      expect(messages.first).to include('after 12 exchange passes')
    end

    it 'fully exchanges exactly 12 passes worth without the give-up message' do
      commands = simulate_changer(purse: 12_000, refusal: changer_refusal)
      build_instance.exchange_all('dokoras', 'kronars')

      expect(chunks(commands).size).to eq(11)
      expect(commands.last).to eq('exchange all dokoras for kronars')
      expect(messages).to be_empty
    end

    # A stub returning '' looks the same to exchange_all as a matched
    # refusal, but the real bput only gets to '' by waiting out its timeout.
    # So check that a pattern actually matches the changer's reply.
    it 'recognizes the under-minimum refusal instead of timing out on it' do
      line = 'The money-changer says crossly, "A transaction that small isn\'t worth my time.  ' \
             'The minimum is one bronze or ten coppers."'
      sent = []
      allow(DRC).to receive(:bput) do |command, *patterns|
        matched = patterns.lazy.map { |pattern| line[pattern] }.find(&:itself)
        sent << [command, matched]
        matched.to_s
      end
      build_instance.exchange_all('lirums', 'kronars')

      expect(sent.map(&:first)).to eq(['exchange all lirums for kronars'])
      expect(sent.first.last).not_to be_nil
      expect(messages).to be_empty
    end

    # Seen in game on a holiday. An unmatched chunk reads as a refusal, so
    # this would stop after one chunk and tell the user to exchange by hand.
    it 'treats the holiday no-fee exchange as done' do
      holiday = 'You hand your money to the money-changer.  He whispers, "Enjoy the holiday, friend!  ' \
                'There\'s no fee this time!"  He hands you 7 copper Dokoras.'
      commands = simulate_changer(purse: 1500, refusal: changer_refusal, done: holiday)
      build_instance.exchange_all('dokoras', 'kronars')

      expect(commands).to eq(['exchange all dokoras for kronars',
                              'exchange 1000 platinum dokoras to kronars',
                              'exchange all dokoras for kronars'])
      expect(messages).to be_empty
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
  # Extracted helpers (PR2 DRY refactor) -- shared by detection and selling
  # =========================================================================
  describe '#open_gem_pouch?' do
    it 'is true when the pouch opens or is already open' do
      stub_bput('open my soft pouch' => 'That is already open')
      expect(build_instance.open_gem_pouch?('soft pouch')).to be true
    end

    it 'is false when the pouch is tied off' do
      stub_bput('open my soft pouch' => 'has been tied off')
      expect(build_instance.open_gem_pouch?('soft pouch')).to be false
    end

    it 'is false when the container cannot be found' do
      stub_bput('open my soft pouch' => 'What were you referring to')
      expect(build_instance.open_gem_pouch?('soft pouch')).to be false
    end
  end

  describe '#sellable_metal_and_stone_items' do
    before { $test_data.items = items_data }

    it 'reduces matching descriptions to the "material noun" phrase the shop buys' do
      allow(DRCI).to receive(:get_item_list).and_return(['small iron bar', 'large yellow gold nugget', 'a rock'])
      expect(build_instance.sellable_metal_and_stone_items('sack')).to eq(['iron bar', 'yellow gold nugget'])
    end

    it 'returns an empty array (not nil) when the container is unreadable' do
      allow(DRCI).to receive(:get_item_list).and_return(nil)
      expect(build_instance.sellable_metal_and_stone_items('sack')).to eq([])
    end

    it 'drops items whose material is on the ignore list' do
      instance = build_instance(settings: make_settings(sell_loot_ignored_metals_and_stones: %w[iron]))
      allow(DRCI).to receive(:get_item_list).and_return(['small iron bar', 'small jade nugget'])
      expect(instance.sellable_metal_and_stone_items('sack')).to eq(['jade nugget'])
    end

    it 'does not crash when material or ignore config contains regex metacharacters' do
      # Unbalanced paren/bracket would raise RegexpError if interpolated raw.
      $test_data.items = { 'metal_types' => ['iron', 'weird(metal'], 'stone_types' => [] }
      instance = build_instance(settings: make_settings(sell_loot_ignored_metals_and_stones: ['bad[stone']))
      allow(DRCI).to receive(:get_item_list).and_return(['small iron bar'])

      result = nil
      expect { result = instance.sellable_metal_and_stone_items('sack') }.not_to raise_error
      expect(result).to eq(['iron bar'])
    end
  end

  describe '#walk_to_gemshop' do
    it 'walks to the configured gemshop and reports success' do
      expect(DRCT).to receive(:walk_to).with(200).and_return(true)
      expect(build_instance.walk_to_gemshop).to be true
    end

    it 'does not walk and returns false when the town has no gemshop' do
      instance = build_instance(hometown: make_hometown('gemshop' => nil))
      expect(DRCT).not_to receive(:walk_to)
      expect(instance.walk_to_gemshop).to be false
    end
  end

  # =========================================================================
  # #coins_to_bank?
  # =========================================================================
  describe '#coins_to_bank?' do
    it 'is true when local currency exceeds the keep-on-hand amount' do
      allow(DRCM).to receive(:get_total_wealth).and_return('kronars' => 500, 'lirums' => 0, 'dokoras' => 0)
      expect(build_instance(local_currency: 'kronars').coins_to_bank?(300)).to be true
    end

    it 'is false when local currency is at or below the keep-on-hand amount' do
      allow(DRCM).to receive(:get_total_wealth).and_return('kronars' => 300, 'lirums' => 0, 'dokoras' => 0)
      expect(build_instance(local_currency: 'kronars').coins_to_bank?(300)).to be false
    end

    it 'is true when only foreign currency is on hand (something to exchange)' do
      allow(DRCM).to receive(:get_total_wealth).and_return('kronars' => 0, 'lirums' => 250, 'dokoras' => 0)
      expect(build_instance(local_currency: 'kronars').coins_to_bank?(300)).to be true
    end

    it 'matches the local currency case-insensitively' do
      allow(DRCM).to receive(:get_total_wealth).and_return('kronars' => 0, 'lirums' => 1000, 'dokoras' => 0)
      # Muspar'i stores its currency as "Lirums"; the wealth hash keys are lower.
      expect(build_instance(local_currency: 'Lirums').coins_to_bank?(300)).to be true
    end

    it 'is false when nothing is on hand' do
      expect(build_instance(local_currency: 'kronars').coins_to_bank?(300)).to be false
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

    it 'never moves when there is neither loot to sell nor excess coins to bank' do
      $test_settings = make_settings
      $test_data.town = { 'Crossing' => make_hometown }
      $test_data.items = items_data
      allow(DRC).to receive(:get_town_name).and_return('Crossing')
      allow_any_instance_of(SellLoot).to receive(:has_loot_to_sell?).and_return(false)
      # DRCM.get_total_wealth defaults to all zeros.
      expect(DRCT).not_to receive(:walk_to)
      expect(DRCM).not_to receive(:deposit_coins)
      expect_any_instance_of(SellLoot).not_to receive(:sell_gems)
      SellLoot.new
    end

    it 'restocks spare gem pouches even when there is no loot to sell' do
      # Regression: pouch restocking used to live inside the has_loot_to_sell?
      # branch, so a run with nothing to sell silently let the spare pouches run
      # dry. Restocking must be checked on its own, independent of selling.
      $test_settings = make_settings(spare_gem_pouch_container: 'sack')
      $test_data.town = { 'Crossing' => make_hometown }
      $test_data.items = items_data
      allow(DRC).to receive(:get_town_name).and_return('Crossing')
      allow_any_instance_of(SellLoot).to receive(:has_loot_to_sell?).and_return(false)
      expect_any_instance_of(SellLoot).to receive(:check_spare_pouch).with('sack', 'soft')
      SellLoot.new
    end

    it 'does not restock when a spare container is set but the gem pouch adjective is unset' do
      # validate_settings only guarantees gem_pouch_adjective when sell_loot_pouch
      # is on; a nil adjective would ask the clerk for " pouch" and count
      # " gem pouch" -- malformed commands -- so restocking must be skipped.
      $test_settings = make_settings(spare_gem_pouch_container: 'sack', gem_pouch_adjective: nil)
      $test_data.town = { 'Crossing' => make_hometown }
      $test_data.items = items_data
      allow(DRC).to receive(:get_town_name).and_return('Crossing')
      allow_any_instance_of(SellLoot).to receive(:has_loot_to_sell?).and_return(false)
      expect_any_instance_of(SellLoot).not_to receive(:check_spare_pouch)
      SellLoot.new
    end

    context 'when spare-pouch restocking is half-configured' do
      let(:messages) { [] }

      before do
        $test_data.town = { 'Crossing' => make_hometown }
        $test_data.items = items_data
        allow(DRC).to receive(:get_town_name).and_return('Crossing')
        allow(DRC).to receive(:message) { |text| messages << text }
        allow_any_instance_of(SellLoot).to receive(:has_loot_to_sell?).and_return(false)
      end

      it 'says restocking is off when a spare container is set without an adjective' do
        $test_settings = make_settings(spare_gem_pouch_container: 'sack', gem_pouch_adjective: nil)
        SellLoot.new
        expect(messages).to include(a_string_including('restocking is off'))
      end

      it 'stays quiet for an adjective without a spare container' do
        # sell_loot_pouch users set the adjective and may not restock at all.
        $test_settings = make_settings(spare_gem_pouch_container: nil)
        SellLoot.new
        expect(messages.grep(/restocking is off/)).to be_empty
      end
    end

    it 'still exchanges and deposits excess coins even when there is no loot to sell' do
      # Regression: the old preflight bailed the whole run on no loot, stranding
      # coins already on hand instead of banking them.
      $test_settings = make_settings
      $test_data.town = { 'Crossing' => make_hometown }
      $test_data.items = items_data
      allow(DRC).to receive(:get_town_name).and_return('Crossing')
      allow_any_instance_of(SellLoot).to receive(:has_loot_to_sell?).and_return(false)
      allow(DRCM).to receive(:get_total_wealth).and_return('kronars' => 5000, 'lirums' => 0, 'dokoras' => 0)
      expect(DRCM).to receive(:deposit_coins)
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

  # =========================================================================
  # Trader kiosks
  # =========================================================================
  describe 'trader kiosks' do
    let(:sold_line) { 'a tidy pile of 90 platinum Kronars rises from its surface, which you quickly pocket.' }
    let(:messages) { [] }

    before do
      allow(DRC).to receive(:message) { |text| messages << text }
      $right_hand = 'soft gem pouch'
    end

    after { $right_hand = nil }

    # Each entry in +sales+ is how the next offer goes: :empty or :partial sell,
    # :too_cheap refuses the pouch, :dry refuses for funds.
    def kiosk_room(sales, open_reply: 'The soft gem pouch has been tied off.', rummage_reply: '')
      commands = []
      sales = sales.dup
      quoted = false
      reply = lambda do |command|
        case command
        when /^open my / then open_reply
        when /^rummage my / then rummage_reply
        when /^give /
          if quoted
            quoted = false
            Flags["sell-loot-returned-#{sales.shift}"] = true
            sold_line
          elsif sales.first == :too_cheap
            sales.shift
            'The assessed value of this asset is within range of empty-null.'
          elsif sales.first == :dry
            sales.shift
            'Acquisition cannot proceed without additional allocation.'
          else
            quoted = true
            'The kiosk will purchase the pouch for 90 platinum Kronars based on the markup of 55%.'
          end
        end
      end
      # Like DRC.bput: the first pattern that matches wins, '' on no match.
      allow(DRC).to receive(:bput) do |command, *patterns|
        commands << command
        line = reply.call(command).to_s
        patterns.lazy.map { |pattern| line[pattern.is_a?(Regexp) ? pattern : /#{Regexp.escape(pattern)}/i] }
                .find(&:itself).to_s
      end
      commands
    end

    describe '#trader_rooms_from' do
      def rooms(setting)
        build_instance.trader_rooms_from(setting)
      end

      it 'takes one room id, as a number or a string' do
        expect(rooms(5000)).to eq([5000])
        expect(rooms('5000')).to eq([5000])
      end

      it 'takes a list, keeping its order' do
        expect(rooms([6000, 5000, '7000'])).to eq([6000, 5000, 7000])
      end

      it 'takes a comma- or space-separated string' do
        expect(rooms('6000, 5000 7000')).to eq([6000, 5000, 7000])
      end

      it 'drops a repeated room' do
        expect(rooms([5000, 6000, 5000])).to eq([5000, 6000])
      end

      it 'is empty when unset, empty, or holding anything that is not a room id' do
        expect(rooms(nil)).to eq([])
        expect(rooms([])).to eq([])
        expect(rooms('')).to eq([])
        expect(rooms([5000, 'kiosk row'])).to eq([])
        expect(rooms(0)).to eq([])
      end
    end

    describe '#sell_at_trader_room' do
      let(:walked) { [] }
      let(:stored_calls) { [] }

      # +kiosks+ maps each room to the kiosks ranked_trader_objects finds there.
      def trader_run(rooms:, kiosks:, stored: 0, worn: false, bundle: false, reachable: rooms)
        instance = build_instance(
          settings: make_settings(sell_loot_bundle: bundle),
          sell_loot_trader: true, trader_rooms: rooms,
          found_stored_pouches: stored, sell_worn_at_kiosk: worn, found_bundle: bundle
        )
        allow(DRCT).to receive(:walk_to) do |room|
          walked << room
          reachable.include?(room)
        end
        allow(DRC).to receive(:release_invisibility)
        allow(instance).to receive(:ranked_trader_objects) { kiosks.fetch(walked.last, []).dup }
        instance
      end

      # A sale that drains every kiosk in the room leaves +targets+ empty, as
      # sell_held_item does when the kiosks refuse for funds.
      def drain(targets)
        targets.clear
      end

      it 'sells in the first room that has a kiosk at or above the minimum, and stops there' do
        instance = trader_run(rooms: [5000, 6000, 7000], kiosks: { 6000 => ['kiosk'], 7000 => ['kiosk'] }, stored: 4)
        allow(instance).to receive(:sell_stored_pouches) { |_targets, limit| stored_calls << [walked.last, limit] }

        instance.sell_at_trader_room

        expect(walked).to eq([5000, 6000])
        expect(stored_calls).to eq([[6000, 4]])
        expect(messages).to include('***STATUS*** No kiosk to sell to in trader room 5000.')
      end

      it 'moves on to the next room when the kiosks run dry with pouches left' do
        instance = trader_run(rooms: [5000, 6000], kiosks: { 5000 => ['kiosk'], 6000 => ['kiosk'] }, stored: 5)
        allow(instance).to receive(:sell_stored_pouches) do |targets, limit|
          stored_calls << [walked.last, limit]
          drain(targets) if walked.last == 5000
        end
        allow(instance).to receive(:stored_pouch_count).and_return(3)

        instance.sell_at_trader_room

        expect(walked).to eq([5000, 6000])
        expect(stored_calls).to eq([[5000, 5], [6000, 3]])
        expect(messages).to include('***STATUS*** The kiosks in room 5000 are out of reserves.')
      end

      it 'stays put when the kiosks run dry but nothing is left to sell' do
        instance = trader_run(rooms: [5000, 6000], kiosks: { 5000 => ['kiosk'], 6000 => ['kiosk'] }, stored: 2)
        allow(instance).to receive(:sell_stored_pouches) { |targets, _limit| drain(targets) }
        allow(instance).to receive(:stored_pouch_count).and_return(0)

        instance.sell_at_trader_room

        expect(walked).to eq([5000])
      end

      it 'stays put when kiosks are left standing, since they refused what is left for itself' do
        instance = trader_run(rooms: [5000, 6000], kiosks: { 5000 => ['kiosk'], 6000 => ['kiosk'] },
                              worn: true, bundle: true)
        allow(instance).to receive(:sell_worn_pouch).and_return(false)
        allow(instance).to receive(:sell_bundle_to_trader).and_return(false)

        expect(instance.sell_at_trader_room).to eq(pouch: false, bundle: false)
        expect(walked).to eq([5000])
      end

      it 'offers the working pouch and bundle again in the next room after the first runs dry' do
        instance = trader_run(rooms: [5000, 6000], kiosks: { 5000 => ['kiosk'], 6000 => ['kiosk'] },
                              worn: true, bundle: true)
        worn_rooms = []
        bundle_rooms = []
        allow(instance).to receive(:sell_worn_pouch) do |targets|
          worn_rooms << walked.last
          next true unless walked.last == 5000

          drain(targets)
          false
        end
        allow(instance).to receive(:sell_bundle_to_trader) do |_targets|
          bundle_rooms << walked.last
          true
        end

        expect(instance.sell_at_trader_room).to eq(pouch: true, bundle: true)
        expect(worn_rooms).to eq([5000, 6000])
        expect(bundle_rooms).to eq([6000]) # not offered to room 5000's drained kiosks
      end

      it 'does not offer the working pouch to kiosks the stored pouches already drained' do
        instance = trader_run(rooms: [5000, 6000], kiosks: { 5000 => ['kiosk'], 6000 => ['kiosk'] },
                              stored: 3, worn: true)
        allow(instance).to receive(:sell_stored_pouches) { |targets, _limit| drain(targets) if walked.last == 5000 }
        allow(instance).to receive(:stored_pouch_count).and_return(1)
        worn_rooms = []
        allow(instance).to receive(:sell_worn_pouch) do |_targets|
          worn_rooms << walked.last
          true
        end

        expect(instance.sell_at_trader_room).to eq(pouch: true, bundle: false)
        expect(worn_rooms).to eq([6000])
      end

      it 'skips a room it cannot reach' do
        instance = trader_run(rooms: [5000, 6000], kiosks: { 5000 => ['kiosk'], 6000 => ['kiosk'] }, stored: 1,
                              reachable: [6000])
        allow(instance).to receive(:sell_stored_pouches) { |_targets, limit| stored_calls << [walked.last, limit] }

        instance.sell_at_trader_room

        expect(stored_calls).to eq([[6000, 1]])
        expect(messages).to include('***STATUS*** Could not reach trader room 5000.')
      end

      it 'falls back to the shops when no room has a kiosk to sell to' do
        instance = trader_run(rooms: [5000, 6000], kiosks: {}, worn: true, bundle: true)
        expect(instance).not_to receive(:sell_worn_pouch)
        expect(instance).not_to receive(:sell_bundle_to_trader)

        expect(instance.sell_at_trader_room).to eq(pouch: false, bundle: false)
        expect(walked).to eq([5000, 6000])
        expect(messages.last).to eq('***STATUS*** No kiosk to sell to in any trader room -- falling back to the shops.')
      end
    end

    describe '#confirm_sale' do
      def confirm(handback)
        allow(DRC).to receive(:bput) do
          handback.each { |flag| Flags["sell-loot-returned-#{flag}"] = true }
          sold_line
        end
        build_instance.confirm_sale('kiosk', 'soft pouch', 'give kiosk')
      end

      it 'is a full sale when the pouch comes back empty' do
        expect(confirm([:empty])).to eq(:sold)
      end

      it 'is a partial sale when the pouch comes back lighter' do
        expect(confirm([:partial])).to eq(:sold_partial)
      end

      it 'keeps the pouch when no handback line arrives' do
        expect(confirm([])).to eq(:sold_partial)
        expect(messages.last).to include('could not tell')
      end

      it "ignores an earlier pouch's handback (a partial sale after a full one)" do
        Flags['sell-loot-returned-empty'] = true
        expect(confirm([:partial])).to eq(:sold_partial)
      end

      it "ignores an earlier pouch's handback when this one is late" do
        Flags['sell-loot-returned-empty'] = true
        expect(confirm([])).to eq(:sold_partial)
      end

      it 'treats both handbacks at once as partial, so any doubt keeps the pouch' do
        expect(confirm(%i[empty partial])).to eq(:sold_partial)
      end
    end

    describe '#sell_stored_pouches' do
      let(:fetched) { [] }

      before do
        allow(DRCI).to receive(:get_item?) { |item, _container| fetched << item }
        allow(DRCI).to receive(:dispose_trash).and_return(true)
      end

      def seller(spare: nil)
        build_instance(full_pouch_container: 'pack',
                       settings: make_settings(spare_gem_pouch_container: spare))
      end

      it 'keeps a part-full pouch that follows a fully sold one' do
        kiosk_room(%i[empty partial])
        expect(DRCI).to receive(:dispose_trash).with('soft pouch', anything, anything).once.and_return(true)
        expect(DRCI).to receive(:put_away_item?).with('soft pouch', 'pack').once.and_return(true)

        expect(seller.sell_stored_pouches(['kiosk'], 3)).to eq(2)
        expect(fetched.size).to eq(2) # the partial drained the only kiosk
      end

      it 'steps past a refused pouch instead of stopping the run' do
        kiosk_room(%i[too_cheap empty empty])
        seller.sell_stored_pouches(['kiosk'], 3)

        # Put back at the front, so the next fetch is the second.
        expect(fetched).to eq(['first soft pouch', 'second soft pouch', 'second soft pouch'])
      end

      it 'stops once every kiosk is out of funds' do
        kiosk_room(%i[dry])
        expect(DRCI).to receive(:put_away_item?).with('soft pouch', 'pack').and_return(true)

        seller.sell_stored_pouches(['kiosk'], 3)
        expect(fetched.size).to eq(1)
      end

      it 'never ties an untied pouch, and puts it back as found' do
        commands = kiosk_room([], open_reply: 'You open your soft gem pouch.',
                                  rummage_reply: 'You rummage through a soft gem pouch and see a ruby.')
        expect(DRCI).to receive(:put_away_item?).with('soft pouch', 'pack').twice.and_return(true)

        seller.sell_stored_pouches(['kiosk'], 2)
        expect(commands.grep(/^(tie|give) /)).to be_empty
        expect(fetched).to eq(['first soft pouch', 'second soft pouch'])
        expect(messages).to include(a_string_including('Left 2 untied pouch(es)'))
      end

      it 'moves an empty untied pouch to the spares container' do
        kiosk_room([], open_reply: 'You open your soft gem pouch.',
                       rummage_reply: 'You rummage through a soft gem pouch but there is nothing in there.')
        expect(DRCI).to receive(:put_away_item?).with('soft pouch', 'sack').and_return(true)

        seller(spare: 'sack').sell_stored_pouches(['kiosk'], 1)
      end

      context 'without positive evidence that the pouch is empty' do
        before do
          expect(DRCI).not_to receive(:dispose_trash)
          expect(DRCI).to receive(:put_away_item?).with('soft pouch', 'pack').and_return(true)
        end

        it 'keeps a pouch whose OPEN got no reply' do
          kiosk_room([], open_reply: '')
          seller.sell_stored_pouches(['kiosk'], 1)
          expect(messages).to include(a_string_including('could not be read as a gem pouch'))
          expect(messages.grep(/untied/)).to be_empty
        end

        it 'keeps a pouch whose RUMMAGE got no recognised reply' do
          kiosk_room([], open_reply: 'You open your soft gem pouch.')
          seller.sell_stored_pouches(['kiosk'], 1)
        end

        it 'keeps the pouch, and carries on, when reading it raises' do
          allow(DRC).to receive(:bput) do |command, *_patterns|
            raise NoMethodError, "undefined method 'strip' for nil" if command.start_with?('rummage')

            command.start_with?('open') ? 'You open' : ''
          end
          expect { seller.sell_stored_pouches(['kiosk'], 1) }.not_to raise_error
          expect(messages).to include(a_string_including('could not be read as a gem pouch'))
          expect(messages.grep(/untied/)).to be_empty
        end

        it 'leaves a same-adjective pouch that is not a gem pouch unopened' do
          $right_hand = 'soft silk pouch'
          commands = kiosk_room([])
          seller.sell_stored_pouches(['kiosk'], 1)
          expect(commands.grep(/^open /)).to be_empty
          expect(messages).to include(a_string_including('could not be read as a gem pouch'))
          expect(messages.grep(/untied/)).to be_empty
        end
      end
    end

    describe '#stored_pouch_count' do
      def counter(tie)
        build_instance(full_pouch_container: 'pack', settings: make_settings(tie_gem_pouches: tie))
      end

      it 'skips stored pouches when tie_gem_pouches is off, since none can be tied' do
        expect(DRCI).not_to receive(:count_items_in_container)
        expect(counter(false).stored_pouch_count).to eq(0)
      end

      it 'counts them when tie_gem_pouches is on' do
        allow(DRCI).to receive(:count_items_in_container).with('soft gem pouch', 'pack').and_return(3)
        expect(counter(true).stored_pouch_count).to eq(3)
      end
    end
  end
end
