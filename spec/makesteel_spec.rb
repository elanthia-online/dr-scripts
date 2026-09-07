# frozen_string_literal: true

require_relative 'spec_helper'

# Load the MakeSteel class (the trailing MakeSteel.new is not executed;
# load_lic_class extracts only the class body).
load_lic_class('makesteel.lic', 'MakeSteel')

RSpec.describe MakeSteel do
  # Build a bare instance and inject the ivars the methods under test read,
  # rather than driving the full #initialize workflow.
  def build(hometown:, use_private_forge:, private_forge:)
    instance = MakeSteel.allocate
    instance.instance_variable_set(:@hometown, hometown)
    instance.instance_variable_set(:@use_private_forge, use_private_forge)
    instance.instance_variable_set(:@private_forge, private_forge)
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
    it 'walks to the private forge before locating a crucible when enabled' do
      instance = build(hometown: 'Shard', use_private_forge: true, private_forge: 51_058)
      expect(DRCT).to receive(:walk_to).with(51_058).ordered
      expect(DRCC).to receive(:find_empty_crucible).with('Shard').ordered
      instance.find_crucible
    end

    it 'does not walk to a private forge when disabled' do
      instance = build(hometown: 'Riverhaven', use_private_forge: false, private_forge: nil)
      expect(DRCT).not_to receive(:walk_to)
      expect(DRCC).to receive(:find_empty_crucible).with('Riverhaven')
      instance.find_crucible
    end
  end
end
