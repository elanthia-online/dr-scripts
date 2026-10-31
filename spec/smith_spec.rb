# frozen_string_literal: true

require 'yaml'
require_relative 'spec_helper'

# Load the Smith class (the trailing Smith.new is not executed; load_lic_class
# extracts only the class body).
load_lic_class('smith.lic', 'Smith')

RSpec.describe Smith do
  # Where smith sends the character before forge.lic runs. With
  # use_private_forge, forge.lic walks to and rents the private forge on every
  # run (the logs show forge reading the notice seconds after smith did), so
  # smith leaves that to it and only finds a public anvil otherwise.
  describe '#smith workplace' do
    let(:settings) { OpenStruct.new }
    let(:discipline) { { 'stock-volume' => 100, 'finisher-room' => 1, 'finisher-number' => 2 } }
    let(:recipe) { { 'volume' => 5, 'type' => 'weaponsmithing', 'chapter' => 1, 'name' => 'a dagger', 'noun' => 'dagger' } }

    def build(use_private_forge:)
      instance = Smith.allocate
      instance.instance_variable_set(:@hometown, 'Shard')
      instance.instance_variable_set(:@settings, settings)
      instance.instance_variable_set(:@use_private_forge, use_private_forge)
      instance.instance_variable_set(:@discipline, discipline)
      allow(instance).to receive(:buy_parts).and_return(true)
      allow(DRCC).to receive(:find_anvil)
      allow(DRCC).to receive(:go_to_private_forge)
      allow(DRC).to receive(:bput)
      instance
    end

    def run_smith(instance, stay: false)
      instance.smith(OpenStruct.new(material: 'bronze', here: stay ? 'here' : nil), recipe)
    end

    it 'leaves the private forge walk and rental to forge.lic' do
      instance = build(use_private_forge: true)

      run_smith(instance)

      expect(DRCC).not_to have_received(:go_to_private_forge)
      expect(DRCC).not_to have_received(:find_anvil)
      expect(DRC).not_to have_received(:bput).with('read notice', any_args)
    end

    it 'finds a public anvil when use_private_forge is off' do
      instance = build(use_private_forge: false)

      run_smith(instance)

      expect(DRCC).to have_received(:find_anvil).with('Shard')
    end

    it "stays put with 'here'" do
      instance = build(use_private_forge: false)

      run_smith(instance, stay: true)

      expect(DRCC).not_to have_received(:find_anvil)
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
    let(:discipline) { { 'stock-volume' => 100, 'finisher-room' => 1, 'finisher-number' => 2, 'trash-room' => 9, 'bingots-room' => 17_119 } }
    let(:recipe) { { 'volume' => 11, 'type' => 'weaponsmithing', 'chapter' => 5, 'name' => 'a metal morning star', 'noun' => 'star', 'part' => ['haft'] } }
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
      instance.instance_variable_set(:@discipline, discipline)
      $test_data[:crafting] = { 'stock' => { 'steel50' => { 'stock-volume' => 50, 'stock-number' => 13, 'stock-name' => 'steel' } } }
      allow(instance).to receive(:buy_parts).and_return(true)
      allow(instance).to receive(:buy_ingot).and_return(true)
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

    def run_smith(instance)
      instance.smith(OpenStruct.new(material: 'steel', buy: 'buy', stamp: 'stamp', temper: 'temper', balance: 'balance'), recipe)
    end

    it 'stamps, enhances and reports the leftover ingot when every forge run finishes the item' do
      instance = build_with_forge_outcomes('steel morning star', 'steel morning star', 'steel morning star')

      run_smith(instance)

      expect(forge_runs.map(&:first)).to eq(%w[weaponsmithing temper balance])
      expect(instance).to have_received(:stamp_item).with('star')
      expect(Lich::Messaging).to have_received(:msg).with('plain', /About 39 volumes of steel ingot are left over/)
    end

    it 'keeps the leftover of a bought ingot instead of trashing it' do
      instance = build_with_forge_outcomes('steel morning star', 'steel morning star', 'steel morning star')

      run_smith(instance)

      expect(DRCT).not_to have_received(:dispose)
    end

    it 'never trashes parts: forge.lic uses them up, and a leftover is kept for the next run' do
      instance = build_with_forge_outcomes('steel morning star', 'steel morning star', 'steel morning star')

      run_smith(instance)

      expect(DRCT).not_to have_received(:dispose).with('haft', anything)
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

    it "tells every forge run to skip restocking and stay in the room with 'here'" do
      instance = build_with_forge_outcomes('steel morning star', 'steel morning star', 'steel morning star')

      instance.smith(OpenStruct.new(material: 'steel', temper: 'temper', balance: 'balance', here: 'here'), recipe)

      expect(forge_runs).to all(include('skip', 'here'))
      expect(forge_runs.size).to eq(3)
    end

    it 'passes neither skip nor here without it' do
      instance = build_with_forge_outcomes('steel morning star', 'steel morning star', 'steel morning star')

      run_smith(instance)

      expect(forge_runs.flatten).not_to include('skip', 'here', nil)
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

  # smith used to buy every part on every run and trash parts at the end.
  # Across 193 such disposals in Saelia's and Kurtus' logs, 187 found nothing
  # (forge.lic had used the part) and the other 4 trashed a usable part: a
  # spare from an earlier failed run, or a hilt from a pack that wasn't the
  # crafting container. Now a part already in the crafting container is used.
  describe '#buy_parts' do
    let(:crafting_data) do
      {
        'recipe_parts' => {
          'short cord'    => { 'Shard' => { 'part-room' => 4436, 'part-number' => nil } },
          'small padding' => { 'Shard' => { 'part-room' => 4436, 'part-number' => 7 } },
          'haft'          => { 'Shard' => { 'part-room' => 4436, 'part-number' => nil } }
        }
      }
    end

    before do
      $test_data[:crafting] = crafting_data
      allow(DRCT).to receive(:buy_item)
      allow(DRCT).to receive(:order_item)
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCI).to receive(:in_hands?).and_return(true)
    end

    def build_carrying(*bag_items)
      instance = Smith.allocate
      instance.instance_variable_set(:@hometown, 'Shard')
      instance.instance_variable_set(:@bag, 'duffel bag')
      allow(DRCI).to receive(:get_item_list).with('duffel bag').and_return(bag_items)
      instance
    end

    it 'buys every part when the crafting container holds none' do
      instance = build_carrying('steel ingot', 'flask of oil')

      instance.buy_parts(['short cord', 'haft'])

      expect(DRCT).to have_received(:buy_item).with(4436, 'short cord')
      expect(DRCT).to have_received(:buy_item).with(4436, 'haft')
    end

    it 'uses a part already in the crafting container, matched by adjective and noun like the game' do
      instance = build_carrying('short leather cord', 'simple oak haft')

      instance.buy_parts(['short cord', 'haft'])

      expect(DRCT).not_to have_received(:buy_item)
    end

    it 'does not take a long cord for a short cord' do
      instance = build_carrying('long leather cord')

      instance.buy_parts(['short cord'])

      expect(DRCT).to have_received(:buy_item).with(4436, 'short cord')
    end

    it 'buys only the shortfall when a recipe needs the same part twice' do
      instance = build_carrying('small cloth padding')

      instance.buy_parts(['small padding', 'small padding'])

      expect(DRCT).to have_received(:order_item).with(4436, 7).once
    end

    it 'does not take a crafted short-hafted halberd for a haft, or a bone-hilted dagger for a hilt' do
      instance = build_carrying('steel short-hafted halberd', 'bone-hilted dagger')

      instance.buy_parts(%w[haft])

      expect(DRCT).to have_received(:buy_item).with(4436, 'haft')
    end

    it 'buys everything when the container cannot be listed (get_item_list returns nil)' do
      instance = build_carrying
      allow(DRCI).to receive(:get_item_list).and_return(nil)

      instance.buy_parts(['small padding', 'small padding'])

      expect(DRCT).to have_received(:order_item).with(4436, 7).twice
    end

    it 'buys everything when the container is empty' do
      instance = build_carrying

      instance.buy_parts(['small padding', 'small padding'])

      expect(DRCT).to have_received(:order_item).with(4436, 7).twice
    end
  end

  # 'buy' used to compare the recipe against the town's stock-volume (5 in
  # every town) and order the workorders_materials metal, whatever metal was
  # typed: all three ';smith ... buy' runs in the logs (steel morning star,
  # tyrium awl pike) were refused. smith now picks the smallest ingot of the
  # typed metal that holds the recipe, from the real stock catalogue.
  describe "'buy'" do
    let(:stock) { YAML.unsafe_load_file(File.expand_path('../data/base-crafting.yaml', __dir__))['stock'] }
    let(:settings) { OpenStruct.new(workorders_materials: { 'metal_type' => 'bronze' }) }
    let(:discipline) { { 'stock-room' => 4434, 'bingots-room' => 17_119, 'finisher-room' => 1, 'finisher-number' => 2, 'trash-room' => 9611 } }
    let(:morning_star) { { 'volume' => 11, 'type' => 'weaponsmithing', 'chapter' => 5, 'name' => 'a metal morning star', 'noun' => 'star', 'part' => ['haft'] } }

    before do
      $test_data[:crafting] = { 'stock' => stock }
      allow(Lich::Messaging).to receive(:msg)
      allow(DRCT).to receive(:order_item)
      allow(DRCC).to receive(:find_anvil)
      allow(DRCC).to receive(:crafting_cost).and_return(6_200)
      allow(DRCM).to receive(:ensure_copper_on_hand).and_return(true)
    end

    def build
      instance = Smith.allocate
      instance.instance_variable_set(:@hometown, 'Shard')
      instance.instance_variable_set(:@settings, settings)
      instance.instance_variable_set(:@use_private_forge, false)
      instance.instance_variable_set(:@bag, 'duffel bag')
      instance.instance_variable_set(:@discipline, discipline)
      instance
    end

    def smith_with_buy(instance, material: 'steel', recipe: morning_star, here: nil)
      instance.smith(OpenStruct.new(material: material, buy: 'buy', here: here), recipe)
    end

    describe '#ingot_to_buy' do
      it 'picks the smallest ingot of the typed metal that holds the recipe' do
        expect(build.ingot_to_buy('steel', 11)).to include('stock-name' => 'steel', 'stock-volume' => 50)
      end

      it 'takes an ingot whose volume equals the recipe volume' do
        expect(build.ingot_to_buy('steel', 10)).to include('stock-volume' => 10)
      end

      it 'refuses, naming the largest size, when no ingot is large enough' do
        expect(build.ingot_to_buy('steel', 250)).to be_nil
        expect(Lich::Messaging).to have_received(:msg).with('bold', /largest steel ingot sold holds 200 volume; this recipe needs 250/)
      end

      it "refuses a metal the shop doesn't sell" do
        expect(build.ingot_to_buy('tyrium', 15)).to be_nil
        expect(Lich::Messaging).to have_received(:msg).with('bold', /tyrium ingots aren't sold here/)
      end

      it 'offers only the stock shop sizes in a town without a bulk shop' do
        instance = build
        instance.instance_variable_set(:@discipline, discipline.except('bingots-room'))

        expect(instance.ingot_to_buy('steel', 10)).to include('stock-volume' => 10)
        expect(instance.ingot_to_buy('steel', 11)).to be_nil
        expect(instance.ingot_to_buy('iron', 11)).to be_nil
      end
    end

    # Shard, 2025-05-24: the Supply Stand (stock-room 4434) sold 'a massive
    # steel ingot' as order 9; the Bulk Materials shop (bingots-room 17119)
    # sold 'an immense steel ingot' as order 13.
    it 'orders a bulk-size ingot of the typed metal from the bulk shop, not the workorders_materials metal' do
      instance = build
      allow(instance).to receive(:buy_parts).and_return(true)
      allow(DRCI).to receive(:in_hands?).with('steel ingot').and_return(true)
      allow(DRC).to receive(:wait_for_script_to_complete)

      smith_with_buy(instance)

      expect(DRCT).to have_received(:order_item).with(17_119, 13)
      expect(DRCT).not_to have_received(:order_item).with(anything, 11)
    end

    it 'orders a small ingot from the stock shop' do
      instance = build
      allow(instance).to receive(:buy_parts).and_return(true)
      allow(DRCI).to receive(:in_hands?).and_return(true)
      allow(DRC).to receive(:wait_for_script_to_complete)

      smith_with_buy(instance, recipe: morning_star.merge('volume' => 10))

      expect(DRCT).to have_received(:order_item).with(4434, 9)
    end

    it 'refuses to buy when an ingot of that metal is already carried, since forge would use that one' do
      instance = build
      allow(instance).to receive(:buy_parts)
      allow(DRCI).to receive(:exists?).with('steel ingot').and_return(true)

      smith_with_buy(instance)

      expect(instance).not_to have_received(:buy_parts)
      expect(DRCT).not_to have_received(:order_item)
      expect(Lich::Messaging).to have_received(:msg).with('bold', /already carry a steel ingot/)
    end

    it "comes back to the starting room after buying with 'here'" do
      instance = build
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: 51_058))
      allow(DRCI).to receive(:in_hands?).and_return(true)
      allow(DRCT).to receive(:walk_to)
      allow(DRC).to receive(:wait_for_script_to_complete)

      smith_with_buy(instance, here: 'here')

      expect(DRCT).to have_received(:order_item).ordered
      expect(DRCT).to have_received(:walk_to).with(51_058).ordered
    end

    it "refuses 'buy' with 'here' when the current room is unknown" do
      instance = build
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: nil))

      smith_with_buy(instance, here: 'here')

      expect(DRCT).not_to have_received(:order_item)
      expect(Lich::Messaging).to have_received(:msg).with('bold', /needs a known room to come back to/)
    end

    it 'gets enough coin for the ingot and the parts before buying' do
      instance = build
      allow(instance).to receive(:buy_parts).and_return(true)
      allow(DRCI).to receive(:in_hands?).and_return(true)
      allow(DRC).to receive(:wait_for_script_to_complete)

      smith_with_buy(instance)

      expect(DRCC).to have_received(:crafting_cost).with(morning_star, 'Shard', ['haft'], 1, hash_including('stock-number' => 13))
      expect(DRCM).to have_received(:ensure_copper_on_hand).with(6_200, settings, 'Shard')
    end

    it 'buys nothing when no ingot fits' do
      instance = build
      allow(instance).to receive(:buy_parts)

      smith_with_buy(instance, recipe: morning_star.merge('volume' => 250))

      expect(instance).not_to have_received(:buy_parts)
      expect(DRCT).not_to have_received(:order_item)
    end

    it 'stops before forging when the ingot purchase fails' do
      instance = build
      allow(instance).to receive(:buy_parts).and_return(true)
      allow(DRCI).to receive(:in_hands?).and_return(false)
      allow(DRC).to receive(:wait_for_script_to_complete)

      smith_with_buy(instance)

      expect(DRC).not_to have_received(:wait_for_script_to_complete).with('forge', anything)
      expect(Lich::Messaging).to have_received(:msg).with('bold', /Could not buy a steel ingot/)
    end

    it 'stops before buying the ingot when a part purchase fails' do
      $test_data[:crafting]['recipe_parts'] = { 'haft' => { 'Shard' => { 'part-room' => 4436, 'part-number' => nil } } }
      instance = build
      allow(DRCI).to receive(:get_item_list).and_return([])
      allow(DRCT).to receive(:buy_item)
      allow(DRCI).to receive(:in_hands?).and_return(false)
      allow(DRC).to receive(:wait_for_script_to_complete)

      smith_with_buy(instance)

      expect(DRCT).not_to have_received(:order_item)
      expect(DRC).not_to have_received(:wait_for_script_to_complete).with('forge', anything)
      expect(Lich::Messaging).to have_received(:msg).with('bold', /Could not buy a haft/)
    end
  end
end
