# frozen_string_literal: true

require_relative 'spec_helper'

# Load the Smith class (the trailing Smith.new is not executed; load_lic_class
# extracts only the class body).
load_lic_class('smith.lic', 'Smith')

RSpec.describe Smith do
  let(:instance) { Smith.allocate }

  before do
    $test_data[:crafting] = {
      'blacksmithing' => {
        'Shard'      => { 'private_forge' => 51_058 },
        'Crossing'   => { 'private_forge' => 16_936 },
        'Riverhaven' => {} # no private forge
      }
    }
  end

  # The dr-scripts harness stubs a DRCC without the new private-forge helpers,
  # so these exercise smith's local fallbacks (the path on an older lich-5).
  describe 'gated private-forge settings helpers (local fallback)' do
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
    it 'delegates to DRCC.private_forge_cost when lich-5 provides it' do
      allow(DRCC).to receive(:respond_to?).and_call_original
      allow(DRCC).to receive(:respond_to?).with(:private_forge_cost).and_return(true)
      allow(DRCC).to receive(:private_forge_cost).and_return(99_999)
      expect(instance.private_forge_cost(OpenStruct.new)).to eq(99_999)
    end
  end

  describe '#go_to_private_forge (local fallback)' do
    it 'returns false and does not spend when the town has no private forge' do
      expect(DRCM).not_to receive(:ensure_copper_on_hand)
      expect(instance.go_to_private_forge('Riverhaven', OpenStruct.new)).to be false
    end

    it 'ensures funds at the configured cost, walks, and returns true on arrival' do
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: 51_058))
      expect(DRCM).to receive(:ensure_copper_on_hand).with(50_000, anything, 'Shard').and_return(true)
      expect(DRCT).to receive(:walk_to).with(51_058)
      expect(instance.go_to_private_forge('Shard', OpenStruct.new)).to be true
    end
  end
end
