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

# Stub game-interaction modules. Behaviour is set per-example with allow().
module DRC
  def self.bput(*_args); end

  def self.right_hand; end

  def self.left_hand; end
end

module DRCC
  def self.get_crafting_item(*_args); end

  def self.stow_crafting_item(*_args); end
end

load_lic_class('clean-lumber.lic', 'CleanLumber')

RSpec.describe CleanLumber do
  # ensure_wood_saw depends only on @bag / @bag_items / @belt, so a bare
  # allocated instance with those injected isolates the saw-selection logic.
  let(:cleaner) { CleanLumber.allocate }

  before(:each) do
    cleaner.instance_variable_set(:@bag, 'backpack')
    cleaner.instance_variable_set(:@bag_items, [])
    cleaner.instance_variable_set(:@belt, nil)

    allow(DRCC).to receive(:get_crafting_item)
    allow(DRCC).to receive(:stow_crafting_item)
    allow(DRC).to receive(:bput).and_return('You get')
    allow(DRC).to receive(:left_hand).and_return(nil)
    allow(cleaner).to receive(:echo)
    allow(cleaner).to receive(:exit)
  end

  def with_saw_in_right_hand(item)
    allow(DRC).to receive(:right_hand).and_return(item)
  end

  # Issue #3167: the original guard compared get_crafting_item's String result
  # to a Regexp (always true), so the wood-saw check never ran and a bone saw
  # could be used to cut lumber.
  describe '#ensure_wood_saw' do
    context 'when a wood-cutting saw is already in hand' do
      ['a wood saw', 'a woodcutting saw', 'a woodbutt saw'].each do |saw|
        it "accepts #{saw.inspect} without swapping" do
          with_saw_in_right_hand(saw)
          cleaner.ensure_wood_saw
          expect(DRCC).not_to have_received(:stow_crafting_item)
          expect(DRC).not_to have_received(:bput)
        end
      end

      it 'accepts a wood saw held in the off-hand' do
        allow(DRC).to receive(:right_hand).and_return(nil)
        allow(DRC).to receive(:left_hand).and_return('a woodcutting saw')
        cleaner.ensure_wood_saw
        expect(DRC).not_to have_received(:bput)
      end
    end

    context 'when a bone saw is grabbed instead of a wood saw' do
      before(:each) { with_saw_in_right_hand('a bone saw') }

      it 'stows the bone saw and fetches a wood saw by name' do
        cleaner.ensure_wood_saw
        expect(DRCC).to have_received(:stow_crafting_item).with('saw', 'backpack', nil)
        expect(DRC).to have_received(:bput).with('get wood saw from my backpack', 'You get', 'What were')
      end

      it 'exits when no wood saw can be found' do
        allow(DRC).to receive(:bput).and_return('What were')
        cleaner.ensure_wood_saw
        expect(cleaner).to have_received(:echo)
        expect(cleaner).to have_received(:exit)
      end
    end

    context 'when no saw ends up in either hand' do
      before(:each) do
        allow(DRC).to receive(:right_hand).and_return(nil)
        allow(DRC).to receive(:left_hand).and_return(nil)
      end

      it 'does not try to stow nothing, and fetches a wood saw' do
        cleaner.ensure_wood_saw
        expect(DRCC).not_to have_received(:stow_crafting_item)
        expect(DRC).to have_received(:bput).with('get wood saw from my backpack', 'You get', 'What were')
      end
    end
  end
end
