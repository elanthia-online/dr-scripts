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

# Minimal stub modules for game interaction. bput is overridden per-example via
# allow(); list_to_array and get_noun mirror the real DRC helpers (themselves
# covered in lich-5 common_spec) so find_contracts' filtering is exercised end
# to end.
module DRC
  def self.bput(*_args); end

  def self.list_to_array(text)
    return [] if text.nil?

    text.strip.split(/,\s*|\s+and\s+/).map(&:strip).reject(&:empty?)
  end

  def self.get_noun(long_name)
    return nil if long_name.nil?

    long_name.strip.scan(/[a-z\-']+$/i).first
  end
end

# fput is a top-level game command; record calls so the reopen path is testable.
$fput_calls = []
def fput(*args)
  $fput_calls << args.first
end

load_lic_class('trade.lic', 'Trade')

RSpec.describe Trade do
  # find_contracts takes only a container noun; no instance state is needed,
  # so a bare allocated instance keeps the parse/filter logic isolated.
  let(:trade) { Trade.allocate }

  before(:each) { $fput_calls = [] }

  # Issue #4201: the container is rummaged and each entry kept only if it is
  # actually a contract. The bug was a substring match (item.include?('contract'))
  # that also matched a "contract case", so the fix matches on the item noun.
  describe '#find_contracts' do
    def stub_look(*items)
      sentence = items.join(', ')
      allow(DRC).to receive(:bput).and_return("you see #{sentence}.")
    end

    it 'keeps a real contract and rejects a contract case in the same container' do
      stub_look('a Trading contract', 'a contract case', 'some silver coins')
      expect(trade.find_contracts('backpack')).to eq(['a Trading contract'])
    end

    it 'rejects a contract case even when it is the only item (the exact #4201 bug)' do
      stub_look('a contract case')
      expect(trade.find_contracts('backpack')).to eq([])
    end

    it 'returns every contract when several are present' do
      stub_look('a Trading contract', 'a Trading contract', 'a contract case')
      expect(trade.find_contracts('backpack')).to eq(['a Trading contract', 'a Trading contract'])
    end

    it 'returns an empty array when no contracts are present' do
      stub_look('a contract case', 'a leather duffel bag', 'some grass')
      expect(trade.find_contracts('backpack')).to eq([])
    end

    it 'does not match a plural "contracts" noun (only a single contract counts)' do
      stub_look('a bundle of contracts', 'a Trading contract')
      expect(trade.find_contracts('backpack')).to eq(['a Trading contract'])
    end

    it 'reopens a closed container and retries before parsing' do
      responses = ['That is closed', 'you see a Trading contract.']
      allow(DRC).to receive(:bput) { responses.shift }
      expect(trade.find_contracts('contract case')).to eq(['a Trading contract'])
      expect($fput_calls).to include('open my contract case')
    end
  end
end
