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
    def bput(*_args)
      'default'
    end

    def message(*_args); end
  end
end

module DRCT
  class << self
    def walk_to(*_args); end
  end
end

module DRCA
  class << self
    def check_elemental_charge
      0
    end
  end
end

module DRCS
  class << self
    def summon_admittance; end
  end
end

load_lic_class('charge-elemental-charge.lic', 'ChargeElementalCharge')

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end
end

RSpec.describe ChargeElementalCharge do
  def build_instance(**overrides)
    instance = described_class.allocate
    defaults = {
      settings: OpenStruct.new(
        elemental_charge_minimum_level: 6,
        elemental_charge_room: 1234
      ),
      ec_minimum_level: 6,
      charging_room: 1234
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  describe '#done_charging?' do
    it 'returns false when charge is below minimum level' do
      instance = build_instance(ec_minimum_level: 6)
      allow(DRCA).to receive(:check_elemental_charge).and_return(3)

      expect(instance.done_charging?).to be false
    end

    it 'returns true when charge meets minimum level' do
      instance = build_instance(ec_minimum_level: 6)
      allow(DRCA).to receive(:check_elemental_charge).and_return(6)

      expect(instance.done_charging?).to be true
    end

    it 'returns true when charge exceeds minimum level' do
      instance = build_instance(ec_minimum_level: 6)
      allow(DRCA).to receive(:check_elemental_charge).and_return(11)

      expect(instance.done_charging?).to be true
    end
  end

  describe '#charge_elemental_charge' do
    it 'calls DRCS.summon_admittance until done charging' do
      instance = build_instance
      call_count = 0
      allow(DRCA).to receive(:check_elemental_charge) { (call_count += 1) >= 3 ? 6 : 2 }
      allow(DRCS).to receive(:summon_admittance)

      instance.charge_elemental_charge

      expect(DRCS).to have_received(:summon_admittance).exactly(2).times
    end

    it 'does not call summon_admittance when already charged' do
      instance = build_instance
      allow(DRCA).to receive(:check_elemental_charge).and_return(8)
      allow(DRCS).to receive(:summon_admittance)

      instance.charge_elemental_charge

      expect(DRCS).not_to have_received(:summon_admittance)
    end
  end

  describe 'class naming' do
    it 'does not collide with the Summoning class from summoning.lic' do
      expect(described_class.name).to eq('ChargeElementalCharge')
      expect(described_class.name).not_to eq('Summoning')
    end
  end

  describe 'nil room guard' do
    it 'returns early with a message when charging_room is not set' do
      allow(DRC).to receive(:message)
      allow(DRCT).to receive(:walk_to)
      allow(self).to receive(:get_settings).and_return(
        OpenStruct.new(elemental_charge_minimum_level: nil, elemental_charge_room: nil)
      )

      described_class.new

      expect(DRC).to have_received(:message).with(/elemental_charge_room is not set/)
      expect(DRCT).not_to have_received(:walk_to)
    end
  end
end
