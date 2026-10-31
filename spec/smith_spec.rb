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

  # forge.lic leaves the finished item in hand (its default 'hold' finish) and
  # stows both hands on every failure, so smith reads the outcome from the
  # hands. A failed run must not be followed by stamping, enhancement runs or
  # disposal: on 2024-06-12 smith trashed an unused short cord after forge.lic
  # exited with an error, and on 2025-05-24 it started a temper run on an item
  # that was never made.
  describe '#smith after forge.lic exits' do
    let(:settings) { OpenStruct.new }
    let(:discipline) { { 'stock-volume' => 100, 'finisher-room' => 1, 'finisher-number' => 2, 'trash-room' => 9 } }
    let(:recipe) { { 'volume' => 11, 'type' => 'weaponsmithing', 'chapter' => 5, 'name' => 'a metal morning star', 'noun' => 'star' } }
    let(:forge_runs) { [] }

    before do
      allow(Lich::Messaging).to receive(:msg)
      allow(DRCC).to receive(:find_anvil)
    end

    # Builds a smith whose forge.lic runs end with the given hand contents,
    # one entry per run (main item first, then each enhancement).
    def build_with_forge_outcomes(*held_after_each_run)
      instance = Smith.allocate
      instance.instance_variable_set(:@hometown, 'Shard')
      instance.instance_variable_set(:@settings, settings)
      instance.instance_variable_set(:@use_private_forge, false)
      instance.instance_variable_set(:@materials_info, { 'stock-volume' => 50, 'stock-name' => 'steel' })
      allow(instance).to receive(:buy_parts)
      allow(instance).to receive(:buy_ingot)
      allow(instance).to receive(:stamp_item)
      allow(DRCT).to receive(:dispose)
      outcomes = held_after_each_run.dup
      allow(DRC).to receive(:wait_for_script_to_complete) do |name, args|
        next unless name == 'forge'

        forge_runs << args
        $right_hand = outcomes.shift
      end
      instance
    end

    def run_smith(instance, parts: ['haft'], buy: true, stamp: true, temper: 'temper', balance: 'balance')
      instance.smith('steel', discipline, recipe, parts, buy, stamp, temper, nil, balance, nil, nil, nil)
    end

    it 'stamps, enhances and disposes when every forge run finishes the item' do
      instance = build_with_forge_outcomes('steel morning star', 'steel morning star', 'steel morning star')

      run_smith(instance)

      expect(forge_runs.map(&:first)).to eq(%w[weaponsmithing temper balance])
      expect(instance).to have_received(:stamp_item).with('star')
      expect(DRCT).to have_received(:dispose).with('steel ingot', 9)
      expect(DRCT).to have_received(:dispose).with('haft', 9)
    end

    it 'stops after a failed main run: no stamp, no enhancement runs, nothing trashed' do
      instance = build_with_forge_outcomes(nil)

      run_smith(instance)

      expect(forge_runs.size).to eq(1)
      expect(instance).not_to have_received(:stamp_item)
      expect(DRCT).not_to have_received(:dispose)
      expect(Lich::Messaging).to have_received(:msg).with('bold', /did not finish the star/)
    end

    it 'treats an unfinished item left in hand as a failed run' do
      instance = build_with_forge_outcomes('unfinished steel morning star')

      run_smith(instance)

      expect(forge_runs.size).to eq(1)
      expect(DRCT).not_to have_received(:dispose)
    end

    it "does not take forge's own hammer for a hammer it failed to make" do
      settings.forging_tools = ['forging hammer', 'clockwork tongs']
      recipe.merge!('name' => 'a metal ball-peen hammer', 'noun' => 'hammer')
      instance = build_with_forge_outcomes('polished forging hammer')

      run_smith(instance)

      expect(forge_runs.size).to eq(1)
      expect(instance).not_to have_received(:stamp_item)
    end

    it 'does not take an unrelated held item for the finished one' do
      instance = build_with_forge_outcomes('steel starfish')

      run_smith(instance)

      expect(forge_runs.size).to eq(1)
    end

    it 'stops the remaining enhancements and disposal when an enhancement run fails' do
      instance = build_with_forge_outcomes('steel morning star', nil)

      run_smith(instance)

      expect(forge_runs.map(&:first)).to eq(%w[weaponsmithing temper])
      expect(instance).to have_received(:stamp_item)
      expect(DRCT).not_to have_received(:dispose)
    end

    it 'finds the finished item in the left hand too' do
      instance = build_with_forge_outcomes(nil)
      allow(DRC).to receive(:wait_for_script_to_complete) do |name, args|
        next unless name == 'forge'

        forge_runs << args
        $left_hand = 'steel morning star'
      end

      run_smith(instance)

      expect(forge_runs.size).to eq(3)
    end
  end
end
