# frozen_string_literal: true

require_relative 'spec_helper'

# Load the MakeSteel class (the trailing MakeSteel.new is not executed;
# load_lic_class extracts only the class body).
load_lic_class('makesteel.lic', 'MakeSteel')

RSpec.describe MakeSteel do
  # Build a bare instance and inject the ivars the methods under test read,
  # rather than driving the full #initialize workflow.
  def build(hometown: 'Shard', use_private_forge: false, private_forge: nil, settings: OpenStruct.new)
    instance = MakeSteel.allocate
    instance.instance_variable_set(:@hometown, hometown)
    instance.instance_variable_set(:@use_private_forge, use_private_forge)
    instance.instance_variable_set(:@private_forge, private_forge)
    instance.instance_variable_set(:@settings, settings)
    instance
  end

  before do
    $test_data[:crafting] = {
      'blacksmithing' => {
        'Shard'      => { 'private_forge' => 51_058 },
        'Crossing'   => { 'private_forge' => 16_936 },
        'Riverhaven' => {} # no private forge
      }
    }
  end

  # The dr-scripts test harness stubs a DRCC without the new private-forge
  # helpers, so these exercise the local fallbacks that run on an older lich-5.
  describe 'gated private-forge settings helpers (local fallback)' do
    let(:instance) { build }

    it 'crafting_hometown prefers force_crafting_town, else hometown' do
      expect(instance.crafting_hometown(OpenStruct.new(force_crafting_town: 'Shard', hometown: 'Crossing'))).to eq('Shard')
      expect(instance.crafting_hometown(OpenStruct.new(hometown: 'Crossing'))).to eq('Crossing')
    end

    it 'use_private_forge? honors use_private_forge and the legacy forge_use_private_forge' do
      expect(instance.use_private_forge?(OpenStruct.new(use_private_forge: true))).to be true
      expect(instance.use_private_forge?(OpenStruct.new(forge_use_private_forge: true))).to be true
      expect(instance.use_private_forge?(OpenStruct.new)).to be false
    end

    it 'private_forge_cost uses the setting, else defaults to 50_000' do
      expect(instance.private_forge_cost(OpenStruct.new(forge_private_forge_cost: 12_345))).to eq(12_345)
      expect(instance.private_forge_cost(OpenStruct.new)).to eq(50_000)
    end

    it 'private_forge_room returns the room id or nil' do
      expect(instance.private_forge_room('Shard')).to eq(51_058)
      expect(instance.private_forge_room('Riverhaven')).to be_nil
    end

    it 'towns_with_private_forge lists only towns with a forge' do
      expect(instance.towns_with_private_forge).to contain_exactly('Shard', 'Crossing')
    end
  end

  describe 'DRCC delegation gate' do
    it 'delegates to DRCC.use_private_forge? when lich-5 provides it' do
      instance = build
      allow(DRCC).to receive(:respond_to?).and_call_original
      allow(DRCC).to receive(:respond_to?).with(:use_private_forge?).and_return(true)
      allow(DRCC).to receive(:use_private_forge?).and_return(:from_drcc)
      expect(instance.use_private_forge?(OpenStruct.new)).to eq(:from_drcc)
    end
  end

  describe '#validate_private_forge' do
    it 'does nothing when use_private_forge is disabled' do
      instance = build(hometown: 'Riverhaven', use_private_forge: false, private_forge: nil)
      expect { instance.validate_private_forge }.not_to raise_error
    end

    it 'does nothing when the hometown has a private forge' do
      instance = build(hometown: 'Shard', use_private_forge: true, private_forge: 51_058)
      expect { instance.validate_private_forge }.not_to raise_error
    end

    it 'exits when enabled but the hometown has no private forge' do
      instance = build(hometown: 'Riverhaven', use_private_forge: true, private_forge: nil)
      expect { instance.validate_private_forge }.to raise_error(SystemExit)
    end

    it 'lists only blacksmithing towns that have a private forge' do
      allow(Lich::Messaging).to receive(:msg)
      instance = build(hometown: 'Riverhaven', use_private_forge: true, private_forge: nil)
      expect { instance.validate_private_forge }.to raise_error(SystemExit)
      expect(Lich::Messaging).to have_received(:msg)
        .with('bold', /Towns with private forges: (Shard, Crossing|Crossing, Shard)/)
    end
  end

  describe '#find_crucible' do
    it 'navigates to the private forge, then finds a crucible, when enabled' do
      instance = build(hometown: 'Shard', use_private_forge: true, private_forge: 51_058)
      expect(instance).to receive(:go_to_private_forge).with('Shard', instance.instance_variable_get(:@settings)).ordered
      expect(DRCC).to receive(:find_empty_crucible).with('Shard').ordered
      instance.find_crucible
    end

    it 'does not navigate to a private forge when disabled' do
      instance = build(hometown: 'Riverhaven', use_private_forge: false, private_forge: nil)
      expect(instance).not_to receive(:go_to_private_forge)
      expect(DRCC).to receive(:find_empty_crucible).with('Riverhaven')
      instance.find_crucible
    end
  end

  describe '#go_to_private_forge (local fallback)' do
    it 'returns false and does not spend when the town has no private forge' do
      instance = build
      expect(DRCM).not_to receive(:ensure_copper_on_hand)
      expect(instance.go_to_private_forge('Riverhaven', OpenStruct.new)).to be false
    end

    it 'ensures funds, walks, and returns true on arrival' do
      instance = build
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: 51_058))
      expect(DRCM).to receive(:ensure_copper_on_hand).with(50_000, anything, 'Shard').and_return(true)
      expect(DRCT).to receive(:walk_to).with(51_058)
      expect(instance.go_to_private_forge('Shard', OpenStruct.new)).to be true
    end
  end
end
