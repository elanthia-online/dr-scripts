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
end

RSpec.describe InventoryManagerGui do
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
