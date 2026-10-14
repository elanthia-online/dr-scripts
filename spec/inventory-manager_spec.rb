# frozen_string_literal: true

require_relative 'spec_helper'

load_lic_class('inventory-manager.lic', 'InventoryManager')

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

    it 'falls back to plain text when the regex does not compile, and reports why' do
      errors = []
      matcher = described_class.search_matcher('/gem(/') { |error| errors << error }

      expect(errors.length).to eq(1)
      expect(errors.first).to be_a(RegexpError)
      expect(matcher.call('a /gem(/ token')).to be(true)
      expect(matcher.call('a gem')).to be(false)
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
      expect(messages).to be_empty

      search('/in container/', nested: true)
      expect(messages).to include("Found 2 matches on Alpha\n")
    end

    it 'reports only characters with a match and never the version row' do
      search('/sack|2\.00/')

      expect(messages).to eq(['Checking Beta:', 'Match 1): a sack of rocks (vault)', "Found 1 match on Beta\n"])
    end

    it 'warns and searches literally when the regex is invalid' do
      search('/pouch(/')

      expect(messages.first).to match(%r{\Ainventory-manager: /pouch\(/ is not a valid regex .*plain text\.\z})
      expect(messages.grep(/^Match/)).to be_empty
    end

    it 'falls back to the parsed term when variable has no matching argument' do
      $script_vars = nil
      manager.search_for_item('red', false)

      expect(messages).to include('Match 1): a red gem pouch (character)')
    end
  end
end
