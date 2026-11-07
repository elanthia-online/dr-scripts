# frozen_string_literal: true

require 'yaml'
require_relative 'spec_helper'

# Load the Smith class (the trailing Smith.new is not executed; load_lic_class
# extracts only the class body).
load_lic_class('smith.lic', 'Smith')

# The shipped data smith reads, loaded once. Specs use the real stock
# catalogue, part shops, town data and recipes. The rooms and numbers smith
# sends in Shard are pinned as literals, so a renamed, emptied or changed
# Shard entry fails here; other towns are checked only where a spec names
# them (Ratha's missing bulk shop).
module SmithSpecData
  # @return [Hash] data/base-crafting.yaml
  def self.crafting
    @crafting ||= YAML.unsafe_load_file(File.expand_path('../data/base-crafting.yaml', __dir__))
  end

  # @return [Array<Hash>] every recipe in data/base-recipes.yaml
  def self.recipes
    @recipes ||= YAML.unsafe_load_file(File.expand_path('../data/base-recipes.yaml', __dir__))['crafting_recipes']
  end

  # @return [Array<Hash>] the blacksmithing, weaponsmithing and armorsmithing recipes
  def self.smithing_recipes
    @smithing_recipes ||= recipes.select { |recipe| recipe['type'] =~ Smith::SMITHING_TYPES }
  end

  # @param name [String] exact recipe name
  # @return [Hash] a fresh copy, as lich-5's get_data hands out
  def self.recipe(name)
    Marshal.load(Marshal.dump(smithing_recipes.find { |recipe| recipe['name'] == name }))
  end
end

RSpec.describe Smith do
  let(:settings) { OpenStruct.new(hometown: 'Shard', crafting_container: 'duffel bag') }
  let(:shard) { SmithSpecData.crafting['blacksmithing']['Shard'] }
  # volume 11, one haft
  let(:morning_star) { SmithSpecData.recipe('a metal morning star') }
  let(:forge_runs) { [] }
  let(:bag_items) { %w[stamp oil] }
  let(:belt) { { 'name' => 'forging belt', 'items' => %w[hammer tongs] } }

  before do
    $test_data[:crafting] = Marshal.load(Marshal.dump(SmithSpecData.crafting))
    allow(Lich::Messaging).to receive(:msg)
    allow(DRCC).to receive(:find_anvil)
    allow(DRCC).to receive(:check_consumables)
    allow(DRCM).to receive(:ensure_copper_on_hand).and_return(true)
    allow(DRCT).to receive(:dispose)
  end

  # A Smith set up the way initialize leaves it, in Shard, without running
  # initialize itself.
  #
  # @param use_private_forge [Boolean]
  # @return [Smith]
  def build_smith(use_private_forge: false)
    instance = Smith.allocate
    instance.instance_variable_set(:@settings, settings)
    instance.instance_variable_set(:@hometown, 'Shard')
    instance.instance_variable_set(:@discipline, shard)
    instance.instance_variable_set(:@bag, 'duffel bag')
    # Distinct values, so a spec can tell bag_items from the belt.
    instance.instance_variable_set(:@bag_items, bag_items)
    instance.instance_variable_set(:@belt, belt)
    instance.instance_variable_set(:@use_private_forge, use_private_forge)
    instance
  end

  # Parsed arguments as parse_args returns them (absent flags are nil).
  #
  # @param flags [Hash] e.g. buy: 'buy', temper: 'temper'
  # @return [OpenStruct]
  def smith_args(material: 'steel', **flags)
    OpenStruct.new(material: material, item_name: 'metal morning star', **flags)
  end

  # Make forge.lic runs end with these hand contents, one per run (the item
  # first, then each enhancement), and record each run's arguments.
  #
  # @param held_after_each_run [Array<String, nil>] right-hand item, nil = empty
  # @return [void]
  def forge_runs_end_holding(*held_after_each_run)
    outcomes = held_after_each_run.dup
    allow(DRC).to receive(:wait_for_script_to_complete) do |name, args|
      next unless name == 'forge'

      forge_runs << args
      $right_hand = outcomes.shift
    end
  end

  # Skip the shopping step: parts are already carried.
  #
  # @param instance [Smith]
  # @return [void]
  def parts_already_carried(instance)
    allow(instance).to receive(:buy_parts).and_return(true)
  end

  shared_examples 'a run that stops before forging' do
    it 'never starts forge.lic' do
      expect(forge_runs).to be_empty
    end
  end

  describe 'the shipped part shops' do
    it 'sell every part of every smithing recipe, and the reinforce part, in Shard' do
      parts = SmithSpecData.smithing_recipes.flat_map { |recipe| recipe['part'] || [] }.uniq + [Smith::REINFORCE_PART]

      expect(parts.reject { |part| SmithSpecData.crafting.dig('recipe_parts', part, 'Shard') }).to be_empty
    end
  end

  describe 'ARG_DEFINITIONS' do
    let(:item_name_pattern) { Smith::ARG_DEFINITIONS.first.find { |arg| arg[:name] == 'item_name' }[:regex] }

    it 'requires only the metal and the recipe name' do
      required = Smith::ARG_DEFINITIONS.first.reject { |arg| arg[:optional] }.map { |arg| arg[:name] }

      expect(required).to eq(%w[material item_name])
    end

    it 'accepts every smithing recipe name in base-recipes.yaml' do
      rejected = SmithSpecData.smithing_recipes.map { |recipe| recipe['name'] }.grep_v(item_name_pattern)

      expect(rejected).to be_empty
    end

    it 'rejects the punctuation the old [A-z] range let through' do
      %w[metal_pike metal^pike [pike] pike`].each do |typed|
        expect(typed).not_to match(item_name_pattern)
      end
    end
  end

  describe '#initialize' do
    let(:instance) { Smith.allocate }

    before do
      $parsed_args = { material: 'steel', item_name: 'metal morning star' }
      $test_settings = settings
      $test_data[:recipes] = OpenStruct.new(crafting_recipes: SmithSpecData.recipes)
      allow(DRCC).to receive(:recipe_lookup).and_return(morning_star)
      allow(instance).to receive(:smith)
    end

    it 'looks a book recipe name up among the smithing book recipes only and makes it' do
      instance.send(:initialize)

      expect(DRCC).to have_received(:recipe_lookup) do |candidates, typed|
        expect(typed).to eq('metal morning star')
        expect(candidates).to eq(SmithSpecData.smithing_recipes.reject { |recipe| recipe['instructions'] })
      end
      expect(instance).to have_received(:smith).with(having_attributes(material: 'steel'), morning_star)
    end

    it 'stops quietly when no recipe matches (recipe_lookup says why)' do
      allow(DRCC).to receive(:recipe_lookup).and_return(nil)

      instance.send(:initialize)

      expect(instance).not_to have_received(:smith)
    end

    it 'exits before the recipe lookup when use_private_forge is on in a town without one' do
      settings.use_private_forge = true
      settings.hometown = 'Riverhaven'

      expect { instance.send(:initialize) }.to raise_error(SystemExit)
      expect(DRCC).not_to have_received(:recipe_lookup)
      expect(Lich::Messaging).to have_received(:msg).with('bold', /'Riverhaven' has no private forge/)
      expect(Lich::Messaging).to have_received(:msg).with('bold', /Towns with private forges: .*Shard/)
      expect(Lich::Messaging).to have_received(:msg).with('bold', /set use_private_forge: false/)
    end
  end

  # With use_private_forge, forge.lic walks to and rents the private forge on
  # every run: in the logs it read the notice seconds after smith had. smith
  # leaves that to forge.lic and only finds a public anvil.
  # DRCC.recipe_lookup matches /<typed>/i and shows a pick-one menu (no
  # timeout) when several names match and none equals the typed text.
  describe '#find_recipe' do
    let(:candidates) { [] }

    before do
      $test_data[:recipes] = OpenStruct.new(crafting_recipes: SmithSpecData.recipes)
      allow(DRCC).to receive(:recipe_lookup) { |recipes, _typed| candidates.replace(recipes) }
    end

    def matches_for(typed)
      Smith.allocate.send(:find_recipe, typed)
      candidates.select { |recipe| recipe['name'] =~ /#{typed}/i }.map { |recipe| recipe['name'] }
    end

    it 'finds the book recipe alone for a bare noun an instructions weapon shares (no menu)' do
      expect(matches_for('glaive')).to eq(['a metal glaive'])
      expect(matches_for('iltesh')).to eq(['a metal iltesh'])
      expect(matches_for('kudalata')).to eq(['a metal kudalata'])
      expect(matches_for('recade')).to eq(['a metal recade'])
    end

    it 'finds the instructions weapon by a name no book recipe matches' do
      expect(matches_for('short-hafted glaive')).to eq(['a metal short-hafted glaive'])
      expect(matches_for('serrated iltesh')).to eq(['a metal serrated iltesh'])
      expect(matches_for('imperial spear')).to eq(['a metal Imperial spear'])
      expect(matches_for('sterak axe')).to eq(['a metal sterak axe'])
    end

    it 'still offers both naginatas for the bare noun, as both are instructions weapons' do
      expect(matches_for('naginata')).to eq(['a metal long-handled naginata', 'a metal serrated naginata'])
    end

    it 'offers the same book recipes as before for a noun book recipes already shared (spear)' do
      expect(matches_for('spear')).to eq(SmithSpecData.smithing_recipes.reject { |recipe| recipe['instructions'] }.map { |recipe| recipe['name'] }.grep(/spear/i))
    end
  end

  describe 'getting to a workplace' do
    before do
      forge_runs_end_holding('steel morning star')
      allow(DRCC).to receive(:go_to_private_forge)
      allow(DRC).to receive(:bput)
    end

    it 'finds a public anvil when use_private_forge is off' do
      instance = build_smith
      parts_already_carried(instance)

      instance.smith(smith_args, morning_star)

      expect(DRCC).to have_received(:find_anvil).with('Shard')
    end

    it 'leaves the private forge walk and the rental to forge.lic' do
      instance = build_smith(use_private_forge: true)
      parts_already_carried(instance)

      instance.smith(smith_args, morning_star)

      expect(DRCC).not_to have_received(:find_anvil)
      expect(DRCC).not_to have_received(:go_to_private_forge)
      # Without skip/here, forge.lic does the walk and the rental itself.
      expect(forge_runs.size).to eq(1)
      expect(forge_runs.first).not_to include('skip', 'here')
    end

    it "stays in the room with 'here' and every part in the bag: no anvil search, no walking, no buying, no coin" do
      instance = build_smith
      allow(instance).to receive(:buy_parts)
      allow(DRCI).to receive(:get_item_list).with('duffel bag').and_return(['wooden haft', 'flask of oil'])
      allow(DRCT).to receive(:walk_to)
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: 51_058))

      instance.smith(smith_args(here: 'here'), morning_star)

      expect(DRCC).not_to have_received(:find_anvil)
      expect(DRCT).not_to have_received(:walk_to)
      expect(instance).not_to have_received(:buy_parts)
      expect(DRCM).not_to have_received(:ensure_copper_on_hand)
      expect(forge_runs.size).to eq(1)
    end

    it "doesn't list the bag with 'here' for a recipe without parts" do
      allow(DRCI).to receive(:get_item_list)

      build_smith.smith(smith_args(here: 'here'), morning_star.except('part'))

      expect(DRCI).not_to have_received(:get_item_list)
      expect(forge_runs.size).to eq(1)
    end

    it "tells every forge run to skip restocking and stay put with 'here'" do
      forge_runs_end_holding('steel morning star', 'steel morning star')
      allow(DRCI).to receive(:get_item_list).with('duffel bag').and_return(['wooden haft'])

      build_smith.smith(smith_args(here: 'here', temper: 'temper'), morning_star)

      expect(forge_runs.size).to eq(2)
      expect(forge_runs).to all(include('skip', 'here'))
    end

    it 'passes neither skip nor here (nor a stray nil) without it' do
      instance = build_smith
      parts_already_carried(instance)

      instance.smith(smith_args, morning_star)

      expect(forge_runs.flatten).not_to include('skip', 'here', nil)
    end

    it 'restocks oil from the town finisher, then buffs, then forges' do
      instance = build_smith
      parts_already_carried(instance)
      calls = []
      allow(DRCC).to receive(:check_consumables) { |*args| calls << [:oil, *args] }
      allow(DRC).to receive(:wait_for_script_to_complete) do |name, _args|
        calls << [name]
        $right_hand = 'steel morning star'
      end

      instance.smith(smith_args, morning_star)

      expect(calls).to eq([[:oil, 'oil', 4436, 6, 'duffel bag', bag_items, belt], ['buff'], ['forge']])
    end
  end

  # Kurtus, 2026-08-28, in the Shard private forge (51058): forge.lic stopped
  # on "You need another finished long wooden pole"; the pole was bought by
  # hand at 4436 and the spear resumed. 'here' now buys a missing part and
  # walks back before forging.
  describe "'here' with a part missing from the bag" do
    let(:instance) { build_smith }
    # A room that is not the town's private forge (Shard's is 51058).
    let(:start_room) { 8_775 }
    let(:events) { [] }

    before do
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: start_room))
      allow(DRCT).to receive(:walk_to) { |room| events << [:walk, room] }.and_return(true)
      allow(DRCT).to receive(:buy_item) { |room, part| events << [:buy, room, part] }
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCI).to receive(:get_item_list).with('duffel bag').and_return(['flask of oil'])
      allow(DRC).to receive(:wait_for_script_to_complete) do |name, args|
        next unless name == 'forge'

        events << [:forge]
        forge_runs << args
        $right_hand = 'steel morning star'
      end
    end

    context 'when the purchase works' do
      before do
        allow(DRCI).to receive(:in_hands?).and_return(true)
        instance.smith(smith_args(here: 'here'), morning_star)
      end

      it 'carries the parts budget, buys the part, walks back, then forges there' do
        expect(DRCM).to have_received(:ensure_copper_on_hand).with(Smith::PARTS_COPPER, settings, 'Shard')
        expect(events).to eq([[:buy, 4436, 'haft'], [:walk, start_room], [:forge]])
        expect(forge_runs.first).to include('skip', 'here')
      end

      it 'still looks for no public anvil' do
        expect(DRCC).not_to have_received(:find_anvil)
      end
    end

    context 'when the purchase fails' do
      before do
        allow(DRCI).to receive(:in_hands?).and_return(false)
        instance.smith(smith_args(here: 'here'), morning_star)
      end

      include_examples 'a run that stops before forging'

      it "walks back to the room 'here' started in and says what failed" do
        expect(DRCT).to have_received(:walk_to).with(start_room)
        expect(Lich::Messaging).to have_received(:msg).with('bold', /Could not buy a haft/)
      end
    end

    context 'when the room is unknown' do
      before do
        allow(Room).to receive(:current).and_return(OpenStruct.new(id: nil))
        instance.smith(smith_args(here: 'here'), morning_star)
      end

      include_examples 'a run that stops before forging'

      it 'buys nothing, fetches no coin, and says why' do
        expect(DRCT).not_to have_received(:buy_item)
        expect(DRCM).not_to have_received(:ensure_copper_on_hand)
        expect(Lich::Messaging).to have_received(:msg).with('bold', /needs a known room to come back to/)
      end
    end

    it 'buys the part and the ingot on one trip with buy' do
      allow(DRCI).to receive(:in_hands?).and_return(true)
      allow(DRCI).to receive(:exists?).and_return(false)
      allow(DRCT).to receive(:order_item) { |room, number| events << [:order, room, number] }
      allow(DRCC).to receive(:crafting_cost).and_return(6_200)

      instance.smith(smith_args(buy: 'buy', here: 'here'), morning_star)

      expect(events).to eq([[:buy, 4436, 'haft'], [:order, 17_119, 13], [:walk, start_room], [:forge]])
    end

    it 'still fetches the ingot and walks back with buy when every part is in the bag' do
      allow(DRCI).to receive(:get_item_list).with('duffel bag').and_return(['wooden haft'])
      allow(DRCI).to receive(:in_hands?).and_return(true)
      allow(DRCI).to receive(:exists?).and_return(false)
      allow(DRCT).to receive(:order_item) { |room, number| events << [:order, room, number] }
      allow(DRCC).to receive(:crafting_cost).and_return(6_200)

      instance.smith(smith_args(buy: 'buy', here: 'here'), morning_star)

      expect(events).to eq([[:order, 17_119, 13], [:walk, start_room], [:forge]])
    end

    it 'buys the leather strip reinforce needs' do
      allow(DRCI).to receive(:get_item_list).with('duffel bag').and_return(['wooden haft'])
      allow(DRCI).to receive(:in_hands?).and_return(true)

      instance.smith(smith_args(here: 'here', reinforce: 'reinforce'), morning_star)

      strip_shop = SmithSpecData.crafting.dig('recipe_parts', 'leather strip', 'Shard', 'part-room')
      # The item run, then the reinforce run.
      expect(events).to eq([[:buy, strip_shop, 'leather strip'], [:walk, start_room], [:forge], [:forge]])
    end

    # forge.lic gets each part with DRCI.get_item?(part), from anywhere.
    context 'when the part is carried outside the crafting container' do
      before { allow(DRCI).to receive(:exists?).with('haft').and_return(true) }

      it 'counts it as carried: no coin, no shopping, no walking, and it forges' do
        instance.smith(smith_args(here: 'here'), morning_star)

        expect(DRCM).not_to have_received(:ensure_copper_on_hand)
        expect(events).to eq([[:forge]])
      end

      it 'does the same when the crafting container cannot be listed' do
        allow(DRCI).to receive(:get_item_list).with('duffel bag').and_return(nil)

        instance.smith(smith_args(here: 'here'), morning_star)

        expect(events).to eq([[:forge]])
      end

      it 'buys by the container count when the recipe needs that part twice (a tap cannot count)' do
        allow(DRCI).to receive(:in_hands?).and_return(true)

        instance.smith(smith_args(here: 'here'), morning_star.merge('part' => %w[haft haft]))

        expect(events.count { |event| event.first == :buy }).to eq(2)
      end
    end

    # mrhoribu, #7979: a brigandine hauberk needs a large padding and two
    # small paddings. With one of each in the bag, 'tap my small padding'
    # finds the bagged one, so the tap can't stand for the second.
    it 'buys the second of a doubled part when the bag holds one' do
      hauberk = SmithSpecData.recipe('a brigandine hauberk')
      expect(hauberk['part']).to eq(['large padding', 'small padding', 'small padding'])
      allow(DRCI).to receive(:get_item_list).with('duffel bag').and_return(['large padding', 'small padding'])
      allow(DRCI).to receive(:exists?).with('small padding').and_return(true)
      allow(DRCI).to receive(:in_hands?).and_return(true)
      allow(DRCT).to receive(:order_item) { |room, number| events << [:order, room, number] }

      instance.smith(smith_args(here: 'here'), hauberk)

      # Shard's leather shop sells small padding as order 11 (base-crafting recipe_parts).
      expect(events).to eq([[:order, 10_939, 11], [:walk, start_room], [:forge]])
    end

    # Kurtus, 2026-08-28: go2 walked back into the Shard private forge
    # through the guarded archway ("The sentry nods and allows you to pass.").
    context "when 'here' started in the town's private forge" do
      before do
        allow(Room).to receive(:current).and_return(OpenStruct.new(id: 51_058))
        allow(DRCI).to receive(:in_hands?).and_return(true)
        allow(DRCC).to receive(:go_to_private_forge) { events << [:private_forge] }.and_return(true)
      end

      it 'goes back in through DRCC.go_to_private_forge, which tries the door and carries the rental cost' do
        instance.smith(smith_args(here: 'here'), morning_star)

        expect(DRCC).to have_received(:go_to_private_forge).with('Shard', settings)
        expect(events).to eq([[:buy, 4436, 'haft'], [:private_forge], [:forge]])
      end

      it 'stops when that does not get back in' do
        allow(DRCC).to receive(:go_to_private_forge).and_return(false)

        instance.smith(smith_args(here: 'here'), morning_star)

        expect(forge_runs).to be_empty
        expect(Lich::Messaging).to have_received(:msg).with('bold', /Could not get back to room 51058 after shopping/)
      end
    end

    context 'when the walk back does not get there' do
      before do
        allow(DRCI).to receive(:in_hands?).and_return(true)
        allow(DRCT).to receive(:walk_to) { |room| events << [:walk, room] }.and_return(false)
        instance.smith(smith_args(here: 'here'), morning_star)
      end

      include_examples 'a run that stops before forging'

      it 'says so instead of forging where the walk ended' do
        expect(Lich::Messaging).to have_received(:msg).with('bold', /Could not get back to room 8775 after shopping/)
      end
    end
  end

  # Weaponsmithing recipes made from loose instructions (base-recipes.yaml
  # instructions: true). Kurtus, 2026-08-28: ';forge instructions telothian
  # spear' got "some Imperial spear instructions" ("You get some Imperial
  # spear instructions from inside your traveler's pack."), and 'tap my
  # spear' read "You tap an unfinished telothian Imperial spear inside your
  # traveler's pack."; the tap replies below follow that form.
  describe 'a recipe made from instructions' do
    let(:instance) { build_smith }
    let(:spear) { SmithSpecData.recipe('a metal Imperial spear') }
    let(:long_naginata) { SmithSpecData.recipe('a metal long-handled naginata') }

    before do
      $test_data[:recipes] = OpenStruct.new(crafting_recipes: SmithSpecData.recipes)
      allow(DRCT).to receive(:buy_item)
      allow(DRCT).to receive(:walk_to).and_return(true)
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCI).to receive(:in_hands?).and_return(true)
      allow(DRCI).to receive(:get_item_list).with('duffel bag').and_return([])
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: 51_058))
    end

    def carrying_instructions(tap_reply)
      allow(DRCI).to receive(:tap).with('spear instructions').and_return(tap_reply)
      allow(DRCI).to receive(:tap).with('naginata instructions').and_return(tap_reply)
    end

    context 'when the instructions are carried' do
      before do
        carrying_instructions("You tap some Imperial spear instructions inside your traveler's pack.")
        forge_runs_end_holding('telothian Imperial spear', 'telothian Imperial spear')
        instance.smith(smith_args(material: 'telothian', here: 'here', temper: 'temper'), spear)
      end

      it "runs forge.lic's instructions form, then tempers, staying put" do
        expect(forge_runs).to eq([%w[instructions telothian spear skip here], %w[temper spear skip here]])
      end

      it 'buys the long pole the instructions list and comes back first' do
        expect(DRCT).to have_received(:buy_item).with(4436, 'long pole').ordered
        expect(DRCT).to have_received(:walk_to).with(51_058).ordered
      end
    end

    it 'passes no chapter or recipe name to forge.lic without here' do
      carrying_instructions("You tap some Imperial spear instructions inside your traveler's pack.")
      forge_runs_end_holding('telothian Imperial spear')

      instance.smith(smith_args(material: 'telothian'), spear)

      expect(forge_runs).to eq([%w[instructions telothian spear]])
    end

    context 'when no instructions of that noun are carried' do
      before do
        carrying_instructions('What were you referring to?')
        forge_runs_end_holding('telothian Imperial spear')
        instance.smith(smith_args(material: 'telothian', here: 'here'), spear)
      end

      include_examples 'a run that stops before forging'

      it 'buys nothing, fetches no coin, and names the instructions forge needs' do
        expect(DRCT).not_to have_received(:buy_item)
        expect(DRCM).not_to have_received(:ensure_copper_on_hand)
        expect(Lich::Messaging).to have_received(:msg).with('bold', /You don't carry any spear instructions, which forge needs to make a metal Imperial spear/)
      end
    end

    context "when 'my naginata instructions' is the other naginata" do
      before do
        carrying_instructions('You tap some Serrated naginata instructions inside your duffel bag.')
        forge_runs_end_holding('steel naginata')
        instance.smith(smith_args(here: 'here'), long_naginata)
      end

      include_examples 'a run that stops before forging'

      it 'buys nothing and names the set forge would study' do
        expect(DRCT).not_to have_received(:buy_item)
        expect(Lich::Messaging).to have_received(:msg).with('bold', /is another kind \(You tap some Serrated naginata instructions/)
      end
    end

    it "accepts an instructions set whose name adds words around the recipe's (metal ... instructions)" do
      carrying_instructions('You tap some metal long-handled naginata instructions inside your duffel bag.')

      expect(instance.instructions_carried?(long_naginata)).to be true
    end

    # DRCC may get the one matching set in the crafting container by id
    # instead of by the name smith tapped.
    context 'when the noun is shared and the crafting container holds the other kind' do
      before do
        carrying_instructions('You tap some metal long-handled naginata instructions inside your traveler\'s pack.')
        allow(DRCI).to receive(:get_item_list).with('duffel bag').and_return(['some Serrated naginata instructions', 'long pole'])
        forge_runs_end_holding('steel naginata')
        instance.smith(smith_args(here: 'here'), long_naginata)
      end

      include_examples 'a run that stops before forging'

      it 'buys nothing and names the set in the container' do
        expect(DRCT).not_to have_received(:buy_item)
        expect(Lich::Messaging).to have_received(:msg).with('bold', /Your duffel bag also holds some Serrated naginata instructions/)
      end
    end

    it 'accepts a shared noun when the crafting container holds only sets of the right kind' do
      carrying_instructions('You tap some metal long-handled naginata instructions inside your duffel bag.')
      allow(DRCI).to receive(:get_item_list).with('duffel bag').and_return(['some metal long-handled naginata instructions'])

      expect(instance.instructions_carried?(long_naginata)).to be true
    end

    it 'does not list the container for a noun no other instructions recipe uses' do
      carrying_instructions("You tap some Imperial spear instructions inside your traveler's pack.")
      allow(DRCI).to receive(:get_item_list)

      expect(instance.instructions_carried?(spear)).to be true
      expect(DRCI).not_to have_received(:get_item_list)
    end

    it 'treats an empty tap reply as no instructions carried' do
      carrying_instructions(nil)

      expect(instance.instructions_carried?(spear)).to be false
      expect(Lich::Messaging).to have_received(:msg).with('bold', /You don't carry any spear instructions/)
    end

    it 'never taps for a book recipe' do
      allow(DRCI).to receive(:tap)
      forge_runs_end_holding('steel morning star')
      parts_already_carried(instance)

      instance.smith(smith_args, morning_star)

      expect(DRCI).not_to have_received(:tap)
      expect(forge_runs.first.first(3)).to eq(['weaponsmithing', 5, 'a metal morning star'])
    end
  end

  describe 'the shipped instructions recipes' do
    let(:instruction_recipes) { SmithSpecData.smithing_recipes.select { |recipe| recipe['instructions'] } }

    it 'are the 19 weapons of the Special Instructions list' do
      expect(instruction_recipes.size).to eq(19)
      expect(instruction_recipes.map { |recipe| recipe['type'] }.uniq).to eq(['weaponsmithing'])
    end

    it 'have no chapter, are never work orders, and give a noun and a volume' do
      instruction_recipes.each do |recipe|
        expect(recipe).to include('chapter' => nil, 'work_order' => false)
        expect(recipe['noun']).to match(/\A[\w-]+\z/)
        expect(recipe['volume']).to be_a(Integer).and be_positive
      end
    end

    # instructions_carried? reads the recipe name, less the article and
    # "metal", in the tapped set's name; forge.lic gets "<noun> instructions".
    it 'name the weapon by words that end in the noun forge.lic uses' do
      instruction_recipes.each do |recipe|
        kind = recipe['name'].sub(/\Aa metal /, '')
        expect(kind).to end_with(recipe['noun'])
      end
    end

    # recipe_lookup takes the typed name as a pattern; one match means no menu.
    it 'are each found alone by their name without the article' do
      instruction_recipes.each do |recipe|
        typed = recipe['name'].sub(/\Aa metal /, '')
        expect(SmithSpecData.smithing_recipes.count { |other| other['name'] =~ /#{typed}/i }).to eq(1), typed
      end
    end

    it 'keep the volumes and parts the instructions list (Imperial spear, sterak axe)' do
      expect(SmithSpecData.recipe('a metal Imperial spear')).to include('noun' => 'spear', 'volume' => 13, 'part' => ['long pole'])
      expect(SmithSpecData.recipe('a metal sterak axe')).to include('noun' => 'axe', 'volume' => 9, 'part' => ['haft'])
    end
  end

  # forge.lic leaves the finished item in hand (its default 'hold' finish) and
  # its cleanup_and_exit stows both hands, so smith reads the outcome from the
  # hands. On 2024-06-12 smith trashed an unused short cord after forge.lic
  # exited with an error; on 2025-05-24 it started a temper run on an item
  # that was never made.
  describe 'after each forge.lic run' do
    let(:instance) { build_smith }

    before do
      parts_already_carried(instance)
      allow(instance).to receive(:buy_ingot).and_return(true)
      allow(instance).to receive(:stamp_item)
    end

    def make_star_with_everything
      instance.smith(smith_args(buy: 'buy', stamp: 'stamp', temper: 'temper', balance: 'balance'), morning_star)
    end

    it 'stamps, runs each enhancement and reports the leftover ingot when every run finishes the item' do
      forge_runs_end_holding('steel morning star', 'steel morning star', 'steel morning star')

      make_star_with_everything

      expect(forge_runs.map(&:first)).to eq(%w[weaponsmithing temper balance])
      expect(instance).to have_received(:stamp_item).with('star')
      expect(Lich::Messaging).to have_received(:msg).with('plain', /About 39 volumes of steel ingot are left over in your duffel bag/)
    end

    it 'stamps after the item run and before the first enhancement run' do
      events = []
      allow(instance).to receive(:stamp_item) { events << :stamp }
      allow(DRC).to receive(:wait_for_script_to_complete) do |name, args|
        next unless name == 'forge'

        events << args.first
        $right_hand = 'steel morning star'
      end

      make_star_with_everything

      expect(events).to eq(['weaponsmithing', :stamp, 'temper', 'balance'])
    end

    it 'runs enhancements in ENHANCEMENTS order whatever order they were typed' do
      forge_runs_end_holding(*['steel morning star'] * 6)

      instance.smith(smith_args(reinforce: 'reinforce', temper: 'temper', lighten: 'lighten', hone: 'hone', balance: 'balance'), morning_star)

      expect(forge_runs.drop(1).map(&:first)).to eq(%w[temper hone balance lighten reinforce])
    end

    context 'when the item run fails' do
      before do
        forge_runs_end_holding(nil)
        make_star_with_everything
      end

      it 'stops after that run, without stamping or reporting a leftover' do
        expect(forge_runs.size).to eq(1)
        expect(instance).not_to have_received(:stamp_item)
        expect(Lich::Messaging).not_to have_received(:msg).with('plain', /left over/)
      end

      it 'says why it stopped' do
        expect(Lich::Messaging).to have_received(:msg).with('bold', /forge did not finish the star/)
      end
    end

    it 'stops the remaining enhancements and the cleanup when an enhancement run fails' do
      forge_runs_end_holding('steel morning star', nil)

      make_star_with_everything

      expect(forge_runs.map(&:first)).to eq(%w[weaponsmithing temper])
    end

    # Regression guards: smith no longer trashes parts (forge.lic uses them)
    # or a bulk ingot's leftover (it's kept). Its old trash step threw parts
    # away even after a failed run.
    describe 'the removed trash step' do
      it 'stays removed after a finished run' do
        forge_runs_end_holding('steel morning star', 'steel morning star', 'steel morning star')

        make_star_with_everything

        expect(DRCT).not_to have_received(:dispose)
      end

      it 'stays removed after a failed run' do
        forge_runs_end_holding(nil)

        make_star_with_everything

        expect(DRCT).not_to have_received(:dispose)
      end
    end
  end

  describe '#finished_item_in_hand?' do
    let(:instance) { build_smith }

    it 'sees the finished item in either hand' do
      $left_hand = 'steel morning star'

      expect(instance.finished_item_in_hand?('star')).to be true
    end

    it 'does not count an unfinished item' do
      $right_hand = 'unfinished steel morning star'

      expect(instance.finished_item_in_hand?('star')).to be false
    end

    it 'does not count an item whose noun only starts the same' do
      $right_hand = 'steel starfish'

      expect(instance.finished_item_in_hand?('star')).to be false
    end

    # forge.lic can exit holding its own tool, e.g. its hammer while making a
    # ball-peen hammer, when DRCC's missing-tool check stops it.
    it "does not count one of the character's forging_tools" do
      settings.forging_tools = ['forging hammer', 'clockwork tongs']
      $right_hand = 'polished forging hammer'

      expect(instance.finished_item_in_hand?('hammer')).to be false
    end

    it 'still counts a made hammer that is not one of the forging_tools' do
      settings.forging_tools = ['forging hammer', 'clockwork tongs']
      $right_hand = 'steel ball-peen hammer'

      expect(instance.finished_item_in_hand?('hammer')).to be true
    end

    it "matches a noun with an apostrophe (hhr'tami)" do
      $right_hand = "agonite hhr'tami"

      expect(instance.finished_item_in_hand?("hhr'tami")).to be true
    end

    it 'is false with empty hands' do
      expect(instance.finished_item_in_hand?('star')).to be false
    end
  end

  describe '#forge_finished?' do
    let(:instance) { build_smith }

    it 'says forge did not finish when the hands hold no finished item' do
      forge_runs_end_holding(nil)

      expect(instance.forge_finished?('star', ['weaponsmithing'])).to be false
      expect(Lich::Messaging).to have_received(:msg).with('bold', /forge did not finish the star/)
    end

    # The made item and the owned tool share a name, so smith can't tell
    # whether forge finished it. It stops, and says that instead.
    it 'names the clash when the recipe makes a tool listed in forging_tools' do
      settings.forging_tools = ['ball-peen hammer', 'tongs']
      forge_runs_end_holding('steel ball-peen hammer')

      expect(instance.forge_finished?('hammer', ['blacksmithing'])).to be false
      expect(Lich::Messaging).to have_received(:msg).with('bold', /steel ball-peen hammer in hand is named like one of your forging_tools/)
      expect(Lich::Messaging).not_to have_received(:msg).with('bold', /did not finish/)
    end
  end

  describe '#parts_for' do
    it "adds a leather strip for reinforce without changing the recipe's part list" do
      parts = build_smith.parts_for(morning_star, smith_args(reinforce: 'reinforce'))

      expect(parts).to eq(['haft', 'leather strip'])
      expect(morning_star['part']).to eq(['haft'])
    end

    it 'is empty for a recipe without parts' do
      expect(build_smith.parts_for(morning_star.except('part'), smith_args)).to eq([])
    end
  end

  # smith used to buy every part on every run and trash parts at the end.
  # Across 193 such disposals in Saelia's and Kurtus' logs, 187 found nothing
  # (forge.lic had used the part) and the other 4 trashed a usable part: a
  # spare from an earlier failed run, or a hilt from a pack that wasn't the
  # crafting container. Bag items below are the names the logs show.
  describe '#buy_parts' do
    let(:instance) { build_smith }

    before do
      allow(DRCT).to receive(:buy_item)
      allow(DRCT).to receive(:order_item)
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCI).to receive(:in_hands?).and_return(true)
    end

    def carrying(*bag_items)
      allow(DRCI).to receive(:get_item_list).with('duffel bag').and_return(bag_items)
    end

    it 'buys every part when the crafting container holds none' do
      carrying('steel ingot', 'flask of oil')

      expect(instance.buy_parts(['short cord', 'haft'])).to be true
      # Shard sells both parts in room 4436 (base-crafting recipe_parts).
      expect(DRCT).to have_received(:buy_item).with(4436, 'short cord')
      expect(DRCT).to have_received(:buy_item).with(4436, 'haft')
    end

    it "orders a part the town's shop sells by number (Shard long cord: 'order 17' in Kurtus' logs)" do
      carrying

      instance.buy_parts(['long cord'])

      expect(DRCT).to have_received(:order_item).with(10_939, 17)
      expect(DRCT).not_to have_received(:buy_item)
    end

    it 'uses parts already in the crafting container, matched by adjective and noun as the game does' do
      carrying('short leather cord', 'simple oak haft', 'long oak pole')

      instance.buy_parts(['short cord', 'haft', 'long pole'])

      expect(DRCT).not_to have_received(:buy_item)
      expect(DRCT).not_to have_received(:order_item)
    end

    it 'does not take a long cord for a short cord' do
      carrying('long leather cord')

      instance.buy_parts(['short cord'])

      expect(DRCT).to have_received(:buy_item).with(anything, 'short cord')
    end

    it 'does not take a crafted short-hafted halberd for a haft, or a bone-hilted dagger for a hilt' do
      carrying('steel short-hafted halberd', 'bone-hilted dagger')

      instance.buy_parts(%w[haft hilt])

      expect(DRCT).to have_received(:buy_item).with(anything, 'haft')
      expect(DRCT).to have_received(:buy_item).with(anything, 'hilt')
    end

    # forge.lic asks for "another finished wooden hilt", so an unfinished
    # piece left in the bag is not a part it can use.
    it 'does not count an unfinished part as one already carried' do
      carrying('unfinished wooden hilt')

      instance.buy_parts(%w[hilt])

      expect(DRCT).to have_received(:buy_item).with(anything, 'hilt')
    end

    it 'buys only the shortfall when a recipe needs the same part twice' do
      carrying('simple oak haft')

      instance.buy_parts(%w[haft haft])

      expect(DRCT).to have_received(:buy_item).with(anything, 'haft').once
    end

    it 'buys everything when the container is empty' do
      carrying

      instance.buy_parts(%w[haft haft])

      expect(DRCT).to have_received(:buy_item).with(anything, 'haft').twice
    end

    it 'buys everything when the container cannot be listed (get_item_list returns nil)' do
      allow(DRCI).to receive(:get_item_list).and_return(nil)

      instance.buy_parts(%w[haft haft])

      expect(DRCT).to have_received(:buy_item).with(anything, 'haft').twice
    end

    it 'empties its hands first, then stows each part it bought' do
      allow(DRCI).to receive(:stow_hands)
      carrying

      instance.buy_parts(['haft'])

      expect(DRCI).to have_received(:stow_hands).ordered
      expect(DRCC).to have_received(:stow_crafting_item).with('haft', 'duffel bag', belt).ordered
    end

    it 'reports failure and stops buying when a purchase leaves nothing in hand' do
      carrying
      allow(DRCI).to receive(:in_hands?).with('short cord').and_return(false)

      expect(instance.buy_parts(['short cord', 'haft'])).to be false
      expect(DRCT).not_to have_received(:buy_item).with(anything, 'haft')
      expect(Lich::Messaging).to have_received(:msg).with('bold', /Could not buy a short cord/)
    end
  end

  # 'buy' used to compare the recipe against the town's stock-volume (5 in
  # every town) and order the workorders_materials metal whatever metal was
  # typed: all three ';smith ... buy' runs in the logs (steel morning star,
  # tyrium awl pike) were refused.
  describe "'buy'" do
    let(:instance) { build_smith }

    describe '#ingot_to_buy' do
      it 'picks the smallest ingot of the typed metal that holds the recipe' do
        expect(instance.ingot_to_buy('steel', 11)).to include('stock-name' => 'steel', 'stock-volume' => 50)
      end

      it 'takes an ingot whose volume equals the recipe volume' do
        expect(instance.ingot_to_buy('steel', 10)).to include('stock-name' => 'steel', 'stock-volume' => 10)
      end

      it 'picks the smallest fit even when the catalogue lists sizes out of order' do
        stock = $test_data[:crafting]['stock']
        $test_data[:crafting]['stock'] = stock.to_a.reverse.to_h

        expect(instance.ingot_to_buy('steel', 11)).to include('stock-volume' => 50)
      end

      it 'refuses, naming the largest size and what to do, when no ingot is large enough' do
        expect(instance.ingot_to_buy('steel', 250)).to be_nil
        expect(Lich::Messaging).to have_received(:msg).with('bold', /largest steel ingot sold holds 200 volume; this recipe needs 250/)
        expect(Lich::Messaging).to have_received(:msg).with('bold', /Combine ingots by smelting/)
      end

      it "refuses a metal the shops don't sell" do
        expect(instance.ingot_to_buy('tyrium', 15)).to be_nil
        expect(Lich::Messaging).to have_received(:msg).with('bold', /tyrium ingots aren't sold here/)
      end

      it 'offers only the stock shop sizes in a town without a bulk shop (Ratha)' do
        instance.instance_variable_set(:@discipline, SmithSpecData.crafting['blacksmithing']['Ratha'])

        expect(instance.ingot_to_buy('steel', 10)).to include('stock-volume' => 10)
        expect(instance.ingot_to_buy('steel', 11)).to be_nil
        expect(instance.ingot_to_buy('iron', 11)).to be_nil
      end
    end

    context 'when the ingot fits' do
      before do
        parts_already_carried(instance)
        allow(DRCT).to receive(:order_item)
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCC).to receive(:crafting_cost).and_return(6_200)
        allow(DRCI).to receive(:in_hands?).and_return(true)
        forge_runs_end_holding('steel morning star')
      end

      # Shard, 2025-05-24: the Supply Stand (stock-room) sold 'a massive steel
      # ingot' as order 9; Bulk Materials (bingots-room) sold 'an immense steel
      # ingot' as order 13.
      it 'orders a bulk-size ingot of the typed metal from the bulk shop, not the workorders_materials metal, then forges' do
        settings.workorders_materials = { 'metal_type' => 'bronze' }

        instance.smith(smith_args(buy: 'buy'), morning_star)

        expect(DRCT).to have_received(:order_item).with(17_119, 13)
        expect(DRCT).not_to have_received(:order_item).with(anything, 11)
        expect(forge_runs.size).to eq(1)
      end

      it 'orders a small ingot from the stock shop' do
        instance.smith(smith_args(buy: 'buy'), morning_star.merge('volume' => 10))

        expect(DRCT).to have_received(:order_item).with(4434, 9)
      end

      it "comes back to the starting room after shopping with 'here'" do
        allow(Room).to receive(:current).and_return(OpenStruct.new(id: 51_058))
        allow(DRCT).to receive(:walk_to).and_return(true)

        instance.smith(smith_args(buy: 'buy', here: 'here'), morning_star)

        expect(DRCT).to have_received(:order_item).ordered
        expect(DRCT).to have_received(:walk_to).with(51_058).ordered
        expect(forge_runs.size).to eq(1)
      end

      it 'puts the bought ingot in the crafting container and empties its hands' do
        allow(DRCI).to receive(:stow_hands)

        instance.buy_ingot({ 'stock-name' => 'steel', 'stock-number' => 13, 'stock-volume' => 50 })

        expect(DRCC).to have_received(:stow_crafting_item).with('ingot', 'duffel bag', belt).ordered
        expect(DRCI).to have_received(:stow_hands).ordered
      end

      it 'carries enough coin for the ingot and the parts' do
        instance.smith(smith_args(buy: 'buy'), morning_star)

        expect(DRCC).to have_received(:crafting_cost).with(morning_star, 'Shard', ['haft'], 1, hash_including('stock-number' => 13))
        expect(DRCM).to have_received(:ensure_copper_on_hand).with(6_200, settings, 'Shard')
      end

      it 'carries at least the parts budget when the ingot is cheap' do
        allow(DRCC).to receive(:crafting_cost).and_return(900)

        instance.smith(smith_args(buy: 'buy'), morning_star)

        expect(DRCM).to have_received(:ensure_copper_on_hand).with(Smith::PARTS_COPPER, settings, 'Shard')
      end
    end

    context 'when an ingot of that metal is already carried' do
      before do
        allow(instance).to receive(:buy_parts)
        allow(DRCT).to receive(:order_item)
        allow(DRCI).to receive(:exists?).with('steel ingot').and_return(true)
        forge_runs_end_holding('steel morning star')
        instance.smith(smith_args(buy: 'buy'), morning_star)
      end

      include_examples 'a run that stops before forging'

      it 'buys nothing, since forge.lic would take the carried ingot first' do
        expect(instance).not_to have_received(:buy_parts)
        expect(DRCT).not_to have_received(:order_item)
        expect(Lich::Messaging).to have_received(:msg).with('bold', /already carry a steel ingot/)
      end

      # The leftover of an earlier bought ingot is already in the container,
      # so the refusal points at running without 'buy'.
      it 'says a leftover counts and that running without buy forges from it' do
        expect(Lich::Messaging).to have_received(:msg).with('bold', /leftover from an earlier run counts.*without 'buy' to forge from it/)
      end
    end

    # craft.lic's train_forging runs `smith bronze <item> buy` unattended on
    # every Forging cycle, for recipes of volume 1-4 cut from a 5-volume
    # stock-shop ingot. A kept remainder would make the carried-ingot check
    # refuse every cycle after the first.
    context 'when craft.lic buys a small bronze ingot on two Forging cycles in a row' do
      let(:cup) { SmithSpecData.recipe('a shallow metal cup') }
      let(:carried) { [] }

      before do
        allow(DRCI).to receive(:exists?) { |item| carried.include?(item) }
        allow(DRCI).to receive(:in_hands?).and_return(true)
        allow(DRCI).to receive(:get_item_list).and_return([])
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCC).to receive(:crafting_cost).and_return(200)
        allow(DRCT).to receive(:order_item) { carried << 'bronze ingot' }
        allow(DRCT).to receive(:dispose) { |item, *| carried.delete(item) }
        forge_runs_end_holding('bronze cup', 'bronze cup')
        2.times { build_smith.smith(smith_args(material: 'bronze', buy: 'buy'), cup) }
      end

      it 'buys and forges on both cycles' do
        expect(DRCT).to have_received(:order_item).with(4434, 11).twice
        expect(forge_runs.size).to eq(2)
        expect(Lich::Messaging).not_to have_received(:msg).with('bold', /already carry/)
      end

      it 'disposes of each 4-volume remainder at the trash room' do
        expect(DRCT).to have_received(:dispose).with('bronze ingot', 9611, nil, nil).twice
      end
    end

    context "when 'buy' and 'here' are used in an unknown room" do
      before do
        allow(DRCT).to receive(:order_item)
        allow(Room).to receive(:current).and_return(OpenStruct.new(id: nil))
        forge_runs_end_holding('steel morning star')
        instance.smith(smith_args(buy: 'buy', here: 'here'), morning_star)
      end

      include_examples 'a run that stops before forging'

      it 'buys nothing and says why' do
        expect(DRCT).not_to have_received(:order_item)
        expect(Lich::Messaging).to have_received(:msg).with('bold', /needs a known room to come back to/)
      end
    end

    context 'when no ingot is large enough' do
      before do
        allow(instance).to receive(:buy_parts)
        allow(DRCT).to receive(:order_item)
        forge_runs_end_holding('steel morning star')
        instance.smith(smith_args(buy: 'buy'), morning_star.merge('volume' => 250))
      end

      include_examples 'a run that stops before forging'

      it 'buys nothing and fetches no coin' do
        expect(instance).not_to have_received(:buy_parts)
        expect(DRCT).not_to have_received(:order_item)
        expect(DRCM).not_to have_received(:ensure_copper_on_hand)
      end
    end

    context 'when the ingot purchase fails' do
      before do
        parts_already_carried(instance)
        allow(DRCT).to receive(:order_item)
        allow(DRCI).to receive(:in_hands?).and_return(false)
        forge_runs_end_holding('steel morning star')
        instance.smith(smith_args(buy: 'buy'), morning_star)
      end

      include_examples 'a run that stops before forging'

      it 'says which purchase failed' do
        expect(Lich::Messaging).to have_received(:msg).with('bold', /Could not buy a steel ingot/)
      end
    end

    context "when the ingot purchase fails with 'here'" do
      before do
        allow(DRCT).to receive(:order_item)
        allow(DRCT).to receive(:walk_to)
        allow(DRCI).to receive(:in_hands?).and_return(false)
        allow(Room).to receive(:current).and_return(OpenStruct.new(id: 51_058))
        forge_runs_end_holding('steel morning star')
        instance.smith(smith_args(buy: 'buy', here: 'here'), morning_star)
      end

      include_examples 'a run that stops before forging'

      it "walks back to the room 'here' started in" do
        expect(DRCT).to have_received(:walk_to).with(51_058)
      end
    end

    context 'when a part purchase fails' do
      before do
        allow(DRCI).to receive(:get_item_list).and_return([])
        allow(DRCT).to receive(:buy_item)
        allow(DRCT).to receive(:order_item)
        allow(DRCI).to receive(:in_hands?).and_return(false)
        forge_runs_end_holding('steel morning star')
        instance.smith(smith_args(buy: 'buy'), morning_star)
      end

      include_examples 'a run that stops before forging'

      it 'does not go on to buy the ingot' do
        expect(DRCT).not_to have_received(:order_item)
      end
    end
  end

  describe '#fund_run' do
    let(:instance) { build_smith }

    before { allow(DRCC).to receive(:crafting_cost).and_return(6_200) }

    it 'carries the parts budget when not buying an ingot' do
      instance.fund_run(morning_star, ['haft'], nil, true)

      expect(DRCM).to have_received(:ensure_copper_on_hand).with(Smith::PARTS_COPPER, settings, 'Shard')
    end

    it 'fetches nothing with no part or ingot to buy' do
      instance.fund_run(morning_star, ['haft'], nil, false)

      expect(DRCM).not_to have_received(:ensure_copper_on_hand)
    end

    it 'still pays for a bought ingot when no part is bought' do
      instance.fund_run(morning_star, ['haft'], { 'stock-number' => 13 }, false)

      expect(DRCM).to have_received(:ensure_copper_on_hand).with(6_200, settings, 'Shard')
    end
  end

  describe '#stamp_item' do
    before do
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRC).to receive(:bput)
    end

    it 'marks the item with the stamp and puts the stamp away' do
      build_smith.stamp_item('star')

      expect(DRCC).to have_received(:get_crafting_item).with('stamp', 'duffel bag', bag_items, belt).ordered
      expect(DRC).to have_received(:bput).with('mark my star with my stamp', 'carefully hammer the stamp', "already a maker's mark", any_args).ordered
      expect(DRCC).to have_received(:stow_crafting_item).with('stamp', 'duffel bag', belt).ordered
    end
  end

  describe '#handle_leftover' do
    it "keeps a bulk ingot's leftover and says how much is in the crafting container" do
      build_smith.handle_leftover(morning_star, { 'stock-name' => 'steel', 'stock-volume' => 50 })

      expect(Lich::Messaging).to have_received(:msg).with('plain', 'smith: About 39 volumes of steel ingot are left over in your duffel bag.')
      expect(DRCT).not_to have_received(:dispose)
    end

    it "disposes of a stock-shop ingot's remainder at the town's trash room" do
      settings.worn_trashcan = 'leather bucket'
      settings.worn_trashcan_verb = 'tip'

      build_smith.handle_leftover(morning_star.merge('volume' => 4), { 'stock-name' => 'bronze', 'stock-volume' => 5 })

      expect(DRCT).to have_received(:dispose).with('bronze ingot', 9611, 'leather bucket', 'tip')
      expect(Lich::Messaging).not_to have_received(:msg)
    end

    # DRCI.dispose_trash returns false when the drop fails and nil when it
    # can't get the item. A remainder still carried makes every later 'buy'
    # refuse, so smith says why.
    context 'when the disposal fails' do
      let(:bronze) { { 'stock-name' => 'bronze', 'stock-volume' => 5 } }

      it 'says the next buy will refuse while the remainder is still carried' do
        allow(DRCT).to receive(:dispose).and_return(false)
        allow(DRCI).to receive(:exists?).with('bronze ingot').and_return(true)

        build_smith.handle_leftover(morning_star.merge('volume' => 4), bronze)

        expect(Lich::Messaging).to have_received(:msg).with('bold', "smith: Could not dispose of the leftover bronze ingot, so the next 'buy' of bronze will refuse. Run smith without 'buy' to forge from it, or get rid of it by hand.")
      end

      it 'stays quiet when no remainder is left behind' do
        allow(DRCT).to receive(:dispose).and_return(nil)
        allow(DRCI).to receive(:exists?).with('bronze ingot').and_return(false)

        build_smith.handle_leftover(morning_star.merge('volume' => 4), bronze)

        expect(Lich::Messaging).not_to have_received(:msg)
      end
    end

    it "doesn't look for the remainder again after a disposal that worked" do
      allow(DRCT).to receive(:dispose).and_return(true)
      allow(DRCI).to receive(:exists?)

      build_smith.handle_leftover(morning_star.merge('volume' => 4), { 'stock-name' => 'bronze', 'stock-volume' => 5 })

      expect(DRCI).not_to have_received(:exists?)
    end

    it 'does nothing when the ingot was exactly the recipe volume' do
      build_smith.handle_leftover(morning_star.merge('volume' => 10), { 'stock-name' => 'steel', 'stock-volume' => 10 })

      expect(Lich::Messaging).not_to have_received(:msg)
      expect(DRCT).not_to have_received(:dispose)
    end
  end
end
