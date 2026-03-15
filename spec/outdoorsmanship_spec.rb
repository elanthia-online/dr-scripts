# frozen_string_literal: true

require 'ostruct'

load File.join(File.dirname(__FILE__), '..', 'test', 'test_harness.rb')
include Harness

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

module DRC
  class << self
    def bput(*_args); end
    def collect(*_args); end
    def forage?(*_args); end
    def wait_for_script_to_complete(*_args); end
    def message(_msg); end
  end
end unless defined?(DRC)

DRC.define_singleton_method(:collect) { |*_args| } unless DRC.respond_to?(:collect)
DRC.define_singleton_method(:forage?) { |*_args| } unless DRC.respond_to?(:forage?)

module DRCI
  class << self
    def in_hands?(_item); false; end
    def dispose_trash(*_args); end
  end
end unless defined?(DRCI)

DRCI.define_singleton_method(:dispose_trash) { |*_args| } unless DRCI.respond_to?(:dispose_trash)

module DRCA
  class << self
    def crafting_magic_routine(*_args); end
  end
end unless defined?(DRCA)

module DRCT
  class << self
    def walk_to(_room_id); end
  end
end unless defined?(DRCT)

Harness::DRSkill.define_singleton_method(:_xp_store) { @_xp_store ||= {} }
Harness::DRSkill.define_singleton_method(:_set_xp) { |skillname, val| _xp_store[skillname] = val }
Harness::DRSkill.define_singleton_method(:_reset_xp) { @_xp_store = {} }
Harness::DRSkill.define_singleton_method(:getxp) { |skillname| _xp_store[skillname] || 0 }

load_lic_class('outdoorsmanship.lic', 'Outdoorsmanship')

RSpec.describe Outdoorsmanship do
  before(:each) do
    reset_data
    Harness::DRSkill._reset_xp

    allow(DRC).to receive(:collect)
    allow(DRC).to receive(:forage?)
    allow(DRC).to receive(:bput)
    allow(DRCI).to receive(:in_hands?).and_return(false)
    allow(DRCI).to receive(:dispose_trash)
    allow(DRCA).to receive(:crafting_magic_routine)
  end

  describe '#train_outdoorsmanship' do
    let(:outdoorsmanship) do
      described_class.allocate.tap do |o|
        o.instance_variable_set(:@settings, OpenStruct.new(crafting_training_spells: []))
        o.instance_variable_set(:@training_spells, [])
        o.instance_variable_set(:@skill_name, 'Outdoorsmanship')
        o.instance_variable_set(:@end_exp, 34)
        o.instance_variable_set(:@targetxp, 3)
        o.instance_variable_set(:@forage_item, 'rock')
        o.instance_variable_set(:@skip_magic, true)
        o.instance_variable_set(:@worn_trashcan, nil)
        o.instance_variable_set(:@worn_trashcan_verb, nil)
      end
    end

    context 'when collecting' do
      before do
        outdoorsmanship.instance_variable_set(:@train_method, 'collect')
        Harness::DRSkill._set_xp('Outdoorsmanship', 0)
      end

      it 'terminates after targetxp collect attempts when XP stays low' do
        expect(DRC).to receive(:collect).with('rock').exactly(3).times
        outdoorsmanship.train_outdoorsmanship
      end

      it 'stops collecting early when XP reaches the target' do
        call_count = 0
        allow(DRC).to receive(:collect) do
          call_count += 1
          Harness::DRSkill._set_xp('Outdoorsmanship', 34) if call_count == 2
        end
        outdoorsmanship.train_outdoorsmanship
        expect(call_count).to eq(2)
      end
    end

    context 'when foraging' do
      before do
        outdoorsmanship.instance_variable_set(:@train_method, 'forage')
        Harness::DRSkill._set_xp('Outdoorsmanship', 0)
      end

      it 'terminates after targetxp forage attempts' do
        expect(DRC).to receive(:forage?).with('rock').exactly(3).times
        outdoorsmanship.train_outdoorsmanship
      end

      it 'disposes foraged items found in hands' do
        allow(DRCI).to receive(:in_hands?).with('rock').and_return(true)
        expect(DRCI).to receive(:dispose_trash).with('rock', nil, nil).exactly(3).times
        outdoorsmanship.train_outdoorsmanship
      end
    end
  end

  describe '#magic_cleanup' do
    let(:outdoorsmanship) do
      described_class.allocate.tap do |o|
        o.instance_variable_set(:@skip_magic, false)
        o.instance_variable_set(:@training_spells, ['some_spell'])
      end
    end

    context 'when skip_magic is enabled' do
      before do
        outdoorsmanship.instance_variable_set(:@skip_magic, true)
      end

      it 'skips releasing spell and mana' do
        expect(DRC).not_to receive(:bput)
        outdoorsmanship.magic_cleanup
      end
    end

    context 'when training_spells is empty' do
      before do
        outdoorsmanship.instance_variable_set(:@training_spells, [])
      end

      it 'skips releasing spell and mana' do
        expect(DRC).not_to receive(:bput)
        outdoorsmanship.magic_cleanup
      end
    end

    context 'when magic was used during training' do
      it 'releases active spell and harnessed mana' do
        expect(DRC).to receive(:bput).with('release spell', anything, anything)
        expect(DRC).to receive(:bput).with('release mana', anything, anything)
        outdoorsmanship.magic_cleanup
      end
    end
  end
end
