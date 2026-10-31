# frozen_string_literal: true

require_relative 'spec_helper'

# Load the Smith class (the trailing Smith.new is not executed; load_lic_class
# extracts only the class body).
load_lic_class('smith.lic', 'Smith')

RSpec.describe Smith do
  # The private-forge step of #smith: DRCC (lich-5 #1560) walks to and rents
  # the forge; without it smith uses the public anvil.
  describe '#smith private-forge routing' do
    let(:settings) { OpenStruct.new }
    let(:discipline) { { 'stock-volume' => 100, 'finisher-room' => 1, 'finisher-number' => 2 } }
    let(:recipe) { { 'volume' => 5, 'type' => 'weaponsmithing', 'chapter' => 1, 'name' => 'a dagger', 'noun' => 'dagger' } }

    def build(use_private_forge:)
      instance = Smith.allocate
      instance.instance_variable_set(:@hometown, 'Shard')
      instance.instance_variable_set(:@settings, settings)
      instance.instance_variable_set(:@use_private_forge, use_private_forge)
      allow(instance).to receive(:buy_parts)
      allow(instance).to receive(:check_and_renew_forge_rental)
      allow(instance).to receive(:dispose_parts)
      allow(DRCC).to receive(:find_anvil)
      allow(DRCC).to receive(:go_to_private_forge).and_return(true)
      instance
    end

    def run_smith(instance, stay: false)
      instance.smith('bronze', discipline, recipe, [], nil, nil, nil, nil, nil, nil, nil, stay)
    end

    it 'walks to the private forge through DRCC, then checks the rental' do
      instance = build(use_private_forge: true)

      run_smith(instance)

      expect(DRCC).to have_received(:go_to_private_forge).with('Shard', settings).ordered
      expect(instance).to have_received(:check_and_renew_forge_rental).ordered
      expect(DRCC).not_to have_received(:find_anvil)
    end

    it "skips the private forge walk and rental check with 'here'" do
      allow(Lich::Messaging).to receive(:msg)
      instance = build(use_private_forge: true)

      run_smith(instance, stay: true)

      expect(DRCC).not_to have_received(:go_to_private_forge)
      expect(instance).not_to have_received(:check_and_renew_forge_rental)
      expect(DRCC).not_to have_received(:find_anvil)
    end

    it 'finds a public anvil when use_private_forge is off' do
      instance = build(use_private_forge: false)

      run_smith(instance)

      expect(DRCC).not_to have_received(:go_to_private_forge)
      expect(DRCC).to have_received(:find_anvil).with('Shard')
    end
  end
end
