# frozen_string_literal: true

require_relative 'spec_helper'

load_lic_class('inventory-manager.lic', 'InventoryManager')
load_lic_class('inventory-manager.lic', 'InventoryManagerGui')

RSpec.describe InventoryManager do
  describe '.search_matcher' do
    def matches(query, *lines)
      matcher = described_class.search_matcher(query)
      lines.select { |line| matcher.call(line) }
    end

    it 'does a case-insensitive substring match on a plain term' do
      expect(matches('Pouch', 'a red POUCH', 'a red sack')).to eq(['a red POUCH'])
    end

    it 'treats regex characters in a plain term literally' do
      expect(matches('gem|pouch', 'a gem pouch', 'a gem|pouch tag')).to eq(['a gem|pouch tag'])
      expect(matches('a.b', 'axb', 'a.b')).to eq(['a.b'])
    end

    it 'treats a term wrapped in slashes as a regex' do
      expect(matches('/gem|pouch/', 'a gem', 'a pouch', 'a sack')).to eq(['a gem', 'a pouch'])
    end

    it 'matches a regex case-insensitively' do
      expect(matches('/^a RED/', 'a red pouch', 'not a red pouch')).to eq(['a red pouch'])
    end

    it 'ignores whitespace around the slashes' do
      expect(matches('  /sack$/  ', 'a sack', 'a sack of rocks')).to eq(['a sack'])
    end

    it 'treats a term with only one slash as plain text' do
      expect(matches('/gem', 'a /gem', 'a gem')).to eq(['a /gem'])
      expect(matches('gem/', 'gem/', 'gem')).to eq(['gem/'])
    end

    it 'treats an empty pair of slashes as plain text rather than a match-everything regex' do
      expect(matches('//', 'a gem', 'http://x')).to eq(['http://x'])
    end

    it 'falls back to the text between the slashes when the regex does not compile, and reports why' do
      errors = []
      matcher = described_class.search_matcher('/gem(/') { |error| errors << error }

      expect(errors.length).to eq(1)
      expect(errors.first).to be_a(RegexpError)
      expect(matcher.call('a gem( token')).to be(true)
      expect(matcher.call('a gem')).to be(false)
    end

    context 'with a runaway pattern' do
      # The backreference defeats Ruby's backtracking memoization, so this
      # pattern is exponential on a long run of a's that cannot match.
      let(:runaway) { '/^(a+)+\\1$/' }
      let(:slow_line) { "#{'a' * 30}!" }

      before { stub_const('InventoryManager::SEARCH_REGEX_TIMEOUT', 0.01) }

      it 'matches normally until it times out' do
        expect(described_class.search_matcher(runaway).call('aaaa')).to be(true)
      end

      it 'treats the timed-out line as a non-match and reports it once' do
        errors = []
        matcher = described_class.search_matcher(runaway) { |error| errors << error }

        expect(matcher.call(slow_line)).to be(false)
        expect(matcher.call(slow_line)).to be(false)
        expect(errors.map(&:class)).to eq([Regexp::TimeoutError])
      end

      it 'stops matching for the rest of the search, so one runaway costs one timeout' do
        matcher = described_class.search_matcher(runaway)
        matcher.call(slow_line)

        expect(matcher.call('aaaa')).to be(false)
      end
    end

    it 'does not yield for a valid regex or a plain term' do
      expect { |probe| described_class.search_matcher('/gem/', &probe) }.not_to yield_control
      expect { |probe| described_class.search_matcher('gem(', &probe) }.not_to yield_control
    end

    it 'tolerates nil text such as a row with no container' do
      expect(described_class.search_matcher('/gem/').call(nil)).to be(false)
      expect(described_class.search_matcher('gem').call(nil)).to be(false)
    end
  end

  describe '#search_for_item' do
    let(:manager) do
      described_class.allocate.tap do |m|
        m.instance_variable_set(:@version_string, :version)
        m.instance_variable_set(:@item_data, item_data)
      end
    end
    let(:item_data) do
      {
        version: ['2.00'],
        Alpha: ['a gem pouch (in container a backpack) (character)',
                'a red gem pouch (in container a backpack) (character)'],
        Beta: ['a sack of rocks (vault)']
      }
    end
    let(:messages) { [] }

    before do
      allow(DRC).to receive(:message) { |text| messages << text }
    end

    after { $script_vars = nil }

    # parse_args hands the script the term downcased; variable keeps it as typed.
    def search(typed, nested: false)
      $script_vars = ["search #{typed}", 'search', typed]
      manager.search_for_item(typed.downcase, nested)
    end

    it 'keeps uppercase escapes that parse_args would have downcased' do
      search('/\Aa \S+ gem/')

      expect(messages).to eq(['Checking Alpha:', 'Match 1): a red gem pouch (character)', "Found 1 match on Alpha\n"])
    end

    it 'searches nesting text only when nest is requested' do
      search('/in container/')
      expect(messages).to eq(['No matches for /in container/.'])

      search('/in container/', nested: true)
      expect(messages).to include("Found 2 matches on Alpha\n")
    end

    it 'reports only characters with a match and never the version row' do
      search('/sack|2\.00/')

      expect(messages).to eq(['Checking Beta:', 'Match 1): a sack of rocks (vault)', "Found 1 match on Beta\n"])
    end

    it 'warns and searches the text between the slashes when the regex is invalid' do
      search('/pouch(/')

      expect(messages.first).to match(%r{\Ainventory-manager: /pouch\(/ is not a valid regex .*between the slashes instead\.\z})
      expect(messages.last).to eq('No matches for /pouch(/.')
    end

    it 'says so when nothing matches anywhere, instead of printing nothing' do
      search('/pouch$/')

      expect(messages).to eq(['No matches for /pouch$/.'])
    end

    it 'warns that results are incomplete when the pattern times out' do
      stub_const('InventoryManager::SEARCH_REGEX_TIMEOUT', 0.01)
      item_data[:Beta] = ["#{'a' * 30}! (vault)"]
      search('/^(a+)+\\1$/')

      expect(messages).to eq(['inventory-manager: /^(a+)+\\1$/ took too long to match and was stopped, so these results are incomplete.',
                              'No matches for /^(a+)+\\1$/.'])
    end

    it 'falls back to the parsed term when variable has no matching argument' do
      $script_vars = nil
      manager.search_for_item('red', false)

      expect(messages).to include('Match 1): a red gem pouch (character)')
    end
  end

  describe '#add_vault_standard' do
    let(:manager) do
      described_class.allocate.tap do |m|
        m.instance_variable_set(:@active_character, :Alpha)
        m.instance_variable_set(:@item_data, { Alpha: ['a sack of rocks (vault)'] })
        m.instance_variable_set(:@inventory_ignores, [])
        m.instance_variable_set(:@vault_surfaces, [])
      end
    end
    let(:messages) { [] }
    let(:rent_due) { "You can't access your vault at this time.  Rent is due." }

    before do
      allow(DRC).to receive(:message) { |text| messages << text }
      allow(manager).to receive(:save_item_data)
    end

    it 'waits for the rent refusal too, so it is not retried as a timeout' do
      sent = nil
      allow(Lich::Util).to receive(:issue_command) do |_command, start_pattern, **|
        sent = start_pattern
        [rent_due]
      end

      expect { manager.add_vault_standard }.to raise_error(SystemExit)
      expect(Lich::Util).to have_received(:issue_command).once
      expect(rent_due).to match(sent)
      expect('Vault Inventory:').to match(sent)
    end

    it 'exits with the rent note and saves nothing' do
      allow(manager).to receive(:capture_command).and_return([rent_due])

      expect { manager.add_vault_standard }.to raise_error(SystemExit)
      expect(messages).to eq(['Pay yer rent, ya slob!'])
      expect(manager).not_to have_received(:save_item_data)
    end

    it 'spots the refusal when the line carries XML' do
      allow(manager).to receive(:capture_command).and_return(["<pushBold/>#{rent_due}<popBold/>"])

      expect { manager.add_vault_standard }.to raise_error(SystemExit)
      expect(messages).to eq(['Pay yer rent, ya slob!'])
    end

    it 'restarts sorter before exiting' do
      $running_scripts << 'sorter'
      allow(manager).to receive(:stop_script) { $running_scripts.delete('sorter') }
      allow(manager).to receive(:capture_command).and_return([rent_due])

      expect { manager.add_vault_standard }.to raise_error(SystemExit)
      expect($started_scripts).to eq([['sorter']])
    end

    it 'saves a normal listing' do
      allow(manager).to receive(:capture_command)
        .and_return(['Vault Inventory:', '  a steel box'].map(&:dup))

      manager.add_vault_standard

      expect(messages).to be_empty
      expect(manager).to have_received(:save_item_data).with('vault')
      # The header line is not indented, so it is never taken for an item.
      expect(manager.instance_variable_get(:@item_data)[:Alpha]).to eq(['a steel box (in vault) (vault)'])
    end

    it 'does not treat an item named like the refusal as one' do
      allow(manager).to receive(:capture_command)
        .and_return(['Vault Inventory:', "  a note reading \"#{rent_due}\""].map(&:dup))

      manager.add_vault_standard

      expect(manager).to have_received(:save_item_data).with('vault')
    end
  end

  describe 'saving where each vault item is' do
    let(:surfaces) { ['a brass hook', 'a steel wire rack', 'a small shelf', 'a top drawer', 'a middle drawer', 'a bottom drawer', 'a large shelf'] }
    let(:ignores) { ['[', 'Roundtime', 'Vault Inventory', 'The last note'] }
    let(:manager) do
      described_class.allocate.tap do |m|
        m.instance_variable_set(:@active_character, :Ecth)
        m.instance_variable_set(:@item_data, { Ecth: ['an old row (vault)', 'a family row (Family)', 'a worn pack (worn) (character)'] })
        m.instance_variable_set(:@inventory_ignores, ignores)
        m.instance_variable_set(:@vault_surfaces, surfaces)
      end
    end

    before do
      allow(DRC).to receive(:message)
      allow(manager).to receive(:save_item_data)
    end

    def saved_after(command_result, &scan)
      allow(manager).to receive(:capture_command).and_return(command_result.map(&:dup))
      scan.call
      manager.instance_variable_get(:@item_data)[:Ecth]
    end

    context 'with VAULT STANDARD output as the game sends it' do
      # Lines from Ecth's 2026-11-07 vault, XML links and number padding included.
      let(:listing) do
        [
          'Vault Inventory:',
          '     (1)  some <a exist="12575660" noun="stones">waermodi stones</a>',
          '     (243) a <a exist="12575501" noun="bag">pristine white canvas duffel bag slung with a wide leather strap</a>',
          '          (244) a <a exist="12575524" noun="belt">flame red weapons belt with a Warrior Mage Guild crest buckle</a>',
          '          (9)  a <a exist="12575523" noun="backsheath">grey sharkskin backsheath</a>',
          '     a <a exist="12575479" noun="shelf">large shelf</a>',
          '     a <a exist="12575476" noun="drawer">top drawer</a>',
          '     a <a exist="12575473" noun="hook">brass hook</a>',
          '     (288) a <a exist="12575470" noun="sack">sea-green sack embroidered with seashells and starfish</a>',
          '          (289) a <a exist="12575472" noun="towel">forest green towel embroidered with a golden dragon</a>',
          'The last note indicates that your vault contains 579 items -- but as hurried as it was written, you can\'t be certain the number is absolutely accurate.',
          'Roundtime: 5 sec.'
        ]
      end

      it 'tags loose items in vault and contained items with their container too' do
        expect(saved_after(listing) { manager.add_vault_standard }).to eq(
          [
            'a family row (Family)',
            'a worn pack (worn) (character)',
            'some waermodi stones (in vault) (vault)',
            'a pristine white canvas duffel bag slung with a wide leather strap (in vault) (vault)',
            'a flame red weapons belt with a Warrior Mage Guild crest buckle (in container - a pristine white canvas duffel bag slung with a wide leather strap) (in vault) (vault)',
            'a grey sharkskin backsheath (in container - a pristine white canvas duffel bag slung with a wide leather strap) (in vault) (vault)',
            'a sea-green sack embroidered with seashells and starfish (in vault) (vault)',
            'a forest green towel embroidered with a golden dragon (in container - a sea-green sack embroidered with seashells and starfish) (in vault) (vault)'
          ]
        )
      end

      it 'drops empty furniture even when it is not in inventory_manager_vault_surfaces' do
        manager.instance_variable_set(:@vault_surfaces, [])

        saved = saved_after(listing) { manager.add_vault_standard }

        expect(saved.grep(/shelf|drawer|hook/)).to be_empty
      end

      it 'skips the header and footer even with no ignores configured' do
        manager.instance_variable_set(:@inventory_ignores, [])

        saved = saved_after(listing) { manager.add_vault_standard }

        expect(saved.grep(/Vault Inventory|last note|Roundtime/)).to be_empty
        expect(saved.length).to eq(8)
      end

      it 'restarts sorter once saved' do
        $running_scripts << 'sorter'
        allow(manager).to receive(:stop_script) { $running_scripts.delete('sorter') }

        saved_after(listing) { manager.add_vault_standard }

        expect($started_scripts).to eq([['sorter']])
        expect(manager).to have_received(:save_item_data).with('vault').once
      end
    end

    context 'with items on vault furniture' do
      let(:listing) do
        [
          'Vault Inventory:',
          '     (1)  a steel nodachi',
          '     a large shelf',
          '          (2)  a windsteel mask',
          '          (3)  a burlap sack',
          '               (4)  a forest green towel',
          '     a top drawer',
          '          (5)  some sewing needles',
          '     a brass hook',
          '     (6)  a leather sling'
        ]
      end

      it 'says which piece of furniture holds each one, and how' do
        saved = saved_after(listing) { manager.add_vault_standard }

        expect(saved.grep(/\(vault\)\z/)).to eq(
          [
            'a steel nodachi (in vault) (vault)',
            'a windsteel mask (on a large shelf) (vault)',
            'a burlap sack (on a large shelf) (vault)',
            'a forest green towel (in container - a burlap sack) (on a large shelf) (vault)',
            'some sewing needles (in a top drawer) (vault)',
            'a leather sling (in vault) (vault)'
          ]
        )
      end
    end

    context 'with deep or unusual nesting' do
      let(:listing) do
        [
          'Vault Inventory:',
          '     (1)  a backpack',
          '          (2)  a pouch',
          '               (3)  a box',
          '                    (4)  a gem',
          '          (5)  Toothy\'s lucky charm',
          '          (6)  a rope',
          '     (7)  a sword'
        ]
      end

      it 'files every item under its real parent, however deep' do
        saved = saved_after(listing) { manager.add_vault_standard }

        expect(saved.grep(/\(vault\)\z/)).to eq(
          [
            'a backpack (in vault) (vault)',
            'a pouch (in container - a backpack) (in vault) (vault)',
            'a box (nested container - a pouch (in container - a backpack)) (in vault) (vault)',
            'a gem (nested container - a box (nested container - a pouch (in container - a backpack))) (in vault) (vault)',
            'Toothy\'s lucky charm (in container - a backpack) (in vault) (vault)',
            'a rope (in container - a backpack) (in vault) (vault)',
            'a sword (in vault) (vault)'
          ]
        )
      end

      it 'keeps an ignored container as the parent of what is inside it' do
        manager.instance_variable_set(:@inventory_ignores, ['a pouch'])

        saved = saved_after(listing) { manager.add_vault_standard }

        expect(saved).not_to include(a_string_starting_with('a pouch '))
        expect(saved).to include('a box (nested container - a pouch (in container - a backpack)) (in vault) (vault)')
      end
    end

    context 'with the vault book, which numbers nothing' do
      let(:listing) do
        [
          'Vault Inventory:',
          '    a sea-green sack embroidered with seashells and starfish',
          '      a forest green towel embroidered with a golden dragon',
          '    a brass hook',
          '    a large shelf',
          '      a windsteel mask',
          '    a deep emerald silk haversack adorned with an onyx crescent',
          '      a sleek ice-veined leather thigh quiver wrapped in silversteel mesh'
        ]
      end

      before do
        allow(DRCI).to receive(:get_item_if_not_held?).and_return(true)
        allow(DRCI).to receive(:stow_item?).and_return(true)
      end

      it 'finds the furniture by name and tags every item' do
        allow(manager).to receive(:fput)

        saved = saved_after(listing) { manager.add_vault_book }

        expect(saved.grep(/\(vault\)\z/)).to eq(
          [
            'a sea-green sack embroidered with seashells and starfish (in vault) (vault)',
            'a forest green towel embroidered with a golden dragon (in container - a sea-green sack embroidered with seashells and starfish) (in vault) (vault)',
            'a windsteel mask (on a large shelf) (vault)',
            'a deep emerald silk haversack adorned with an onyx crescent (in vault) (vault)',
            'a sleek ice-veined leather thigh quiver wrapped in silversteel mesh (in container - a deep emerald silk haversack adorned with an onyx crescent) (in vault) (vault)'
          ]
        )
      end
    end

    it 'tags the family vault the same way' do
      saved = saved_after(['Vault Inventory:', '     (1)  a coil of rope', '          (2)  a hook']) { manager.add_vault_family }

      expect(saved).to include('a coil of rope (in vault) (Family)', 'a hook (in container - a coil of rope) (in vault) (Family)')
      expect(saved).not_to include('a family row (Family)')
      expect(saved).to include('an old row (vault)')
    end

    it 'tags rummaged items as loose in the vault and skips the furniture' do
      line = 'You rummage through a secure vault and see a steel hhr\'ata, a brass hook, a large shelf and a translucent blown-glass inkpot.'

      saved = saved_after([line]) { manager.add_vault_regular_inv }

      expect(saved.grep(/\(vault\)\z/)).to eq(
        ["a steel hhr'ata (in vault) (vault)", 'a translucent blown-glass inkpot (in vault) (vault)']
      )
    end

    it 'gives storage box rows no vault spot' do
      saved = saved_after(['Storage Box Inventory:', '    a crate', '      a lid']) { manager.send(:check_inventory, 'read my storage book', /Storage/, 'caravan_box') }

      # The parent's own tag is not asserted: outside Lich, String#to_s does not
      # dup, so the old parser's container label picks it up here only.
      expect(saved.last(2)).to match([eq('a crate (caravan_box)'), start_with('a lid (in container - a crate')])
      expect(saved.grep(/in vault/)).to be_empty
    end

    it 'shows the spot but not the container chain in a plain search' do
      row = 'a forest green towel (in container - a sea-green sack) (on a large shelf) (vault)'

      expect(manager.strip_nesting(row)).to eq('a forest green towel (on a large shelf) (vault)')
      expect(manager.strip_nesting('a windsteel mask (on a large shelf) (vault)')).to eq('a windsteel mask (on a large shelf) (vault)')
    end
  end
end

RSpec.describe InventoryManagerGui do
  describe '.parse_row' do
    it 'reads the spot of a loose vault item' do
      row = described_class.parse_row('Ecth', 'a sea-green sack (in vault) (vault)')

      expect(row.to_h.slice(:source, :name, :container, :location)).to eq(source: 'vault', name: 'a sea-green sack', container: nil, location: 'in vault')
    end

    it 'files an item sitting on furniture under that furniture' do
      row = described_class.parse_row('Ecth', 'a windsteel mask (on a large shelf) (vault)')

      expect(row.to_h.slice(:name, :container, :nested, :location)).to eq(name: 'a windsteel mask', container: 'a large shelf', nested: false, location: 'on a large shelf')
    end

    it 'keeps the real container of something in a bag on a shelf' do
      row = described_class.parse_row('Ecth', 'a towel (nested container - a pouch (in container - a sack)) (in a top drawer) (Family)')

      expect(row.to_h.slice(:source, :name, :container, :nested, :location)).to eq(source: 'Family', name: 'a towel', container: 'a pouch', nested: true, location: 'in a top drawer')
    end

    it 'reads rows saved before spots existed as it always did' do
      row = described_class.parse_row('Ecth', 'a towel (in container - a sea-green sack) (vault)')

      expect(row.to_h.slice(:name, :container, :location)).to eq(name: 'a towel', container: 'a sea-green sack', location: nil)
    end

    it 'looks for a spot only on vault rows' do
      row = described_class.parse_row('Ecth', 'a rock (in a pinch) (character)')

      expect(row.to_h.slice(:name, :location)).to eq(name: 'a rock (in a pinch)', location: nil)
    end
  end

  describe '#detail_for' do
    let(:gui) { described_class.allocate }

    it 'names the shelf once for an item sitting on it' do
      row = described_class.parse_row('Ecth', 'a windsteel mask (on a large shelf) (vault)')

      expect(gui.detail_for(row, false)).to eq('on a large shelf')
    end

    it 'names the container and then the spot' do
      row = described_class.parse_row('Ecth', 'a towel (in container - a sack) (in vault) (vault)')

      expect(gui.detail_for(row, false)).to eq('in a sack, in vault')
      expect(gui.detail_for(row, true)).to eq('in vault')
    end
  end

  describe '#refill' do
    # Stands in for Gtk::TreeStore: append_row only needs append to hand back
    # something it can index, so each appended row is a plain hash.
    let(:store) do
      Class.new do
        attr_reader :rows

        def initialize
          @rows = []
        end

        def clear
          @rows.clear
        end

        def append(_parent)
          {}.tap { |iter| @rows << iter }
        end
      end.new
    end
    let(:status) { Struct.new(:text).new }
    let(:row) { described_class::Row }
    let(:rows) do
      [
        row.new('Alpha', 'character', 'a red gem pouch', 'a backpack', false, false, nil, ''),
        row.new('Alpha', 'character', 'a backpack', nil, false, true, nil, ''),
        row.new('Beta', 'vault', 'a Blue sack', nil, false, false, nil, '')
      ]
    end
    let(:gui) { described_class.allocate.tap { |g| g.instance_variable_set(:@rows, rows) } }

    def items_for(query)
      gui.refill(store, status, query: query, character: nil, nest: false)
      store.rows.select { |iter| iter[described_class::COL_KIND] == 'item' }.map { |iter| iter[described_class::COL_LABEL] }
    end

    it 'shows every item for an empty query' do
      expect(items_for('  ')).to contain_exactly('a red gem pouch', 'a backpack', 'a Blue sack')
    end

    it 'anchors a regex to the item name, not the stored row' do
      expect(items_for('/sack$/')).to eq(['a Blue sack'])
    end

    it 'also matches a regex against the container' do
      expect(items_for('/^a back/')).to contain_exactly('a red gem pouch', 'a backpack')
    end

    it 'keeps a half-typed pattern as a substring search without raising' do
      expect(items_for('/gem(')).to be_empty
      expect(status.text).to eq('0 matches for "/gem("')
    end

    it 'flags a runaway pattern in the status line' do
      stub_const('InventoryManager::SEARCH_REGEX_TIMEOUT', 0.01)
      rows << row.new('Beta', 'vault', "#{'a' * 30}!", nil, false, false, nil, '')

      items_for('/^(a+)+\\1$/')

      expect(status.text).to end_with('(pattern took too long, results incomplete)')
    end
  end
end
