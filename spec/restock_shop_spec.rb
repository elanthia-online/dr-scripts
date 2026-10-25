# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('restock-shop.lic', 'ShopRestock')

RSpec.describe ShopRestock do
  # Build a ShopRestock without running initialize (which does game I/O).
  def build_instance(**overrides)
    instance = ShopRestock.allocate
    overrides.each { |k, v| instance.instance_variable_set(:"@#{k}", v) }
    instance
  end

  # lich-5 DRC.bput matching: Strings compile to /x/i, each line is tried
  # against every pattern in order, and the first match's text is returned.
  def model_bput(lines, patterns)
    regexes = patterns.flatten.map { |item| item.is_a?(Regexp) ? item : /#{item}/i }
    lines.each do |line|
      regexes.each do |regex|
        match = line.match(regex)
        return match.to_a.first if match
      end
    end
    ''
  end

  # Other players' ESP, say and whisper lines as they reach bput (stripped text).
  # Defined on the group too, so examples can be generated per shape.
  def self.player_lines(text)
    {
      'ESP'     => %([General][Mallory] "#{text}"),
      'say'     => %(Mallory says, "#{text}"),
      'whisper' => %(Mallory whispers, "#{text}")
    }
  end

  def player_lines(text)
    self.class.player_lines(text)
  end

  # Route DRC.bput through model_bput. `replies` maps a command to a queue of
  # line lists, one list per call (what arrives while that bput waits).
  # Returns the list of [command, patterns] bput was called with.
  def stub_bput(replies)
    calls = []
    allow(DRC).to receive(:bput) do |command, *patterns|
      calls << [command, patterns]
      model_bput(Array(replies[command]&.shift), patterns)
    end
    calls
  end

  describe '#already_stocked?' do
    let(:instance) { build_instance }

    it 'matches when every full_name word appears in a listing, even with the material wedged between words' do
      item = { 'full_name' => 'weighted pickaxe' }
      raw = ['a weighted steel pickaxe for 12 platinum Kronars']
      expect(instance.send(:already_stocked?, item, raw)).to be true
    end

    it 'matches when the material is prepended' do
      item = { 'full_name' => 'wide shovel' }
      raw = ['a steel wide shovel for 12 platinum Kronars']
      expect(instance.send(:already_stocked?, item, raw)).to be true
    end

    it 'does not match a different item that only shares some words' do
      item = { 'full_name' => 'serrated wood saw' }
      raw = ['a serrated bone saw for 12 platinum Kronars']
      expect(instance.send(:already_stocked?, item, raw)).to be false
    end

    it 'returns false for an empty surface' do
      expect(instance.send(:already_stocked?, { 'full_name' => 'wide shovel' }, [])).to be false
    end
  end

  describe '#check_surfaces' do
    let(:item) { { 'surface' => 'rack', 'full_name' => 'weighted pickaxe', 'recipe' => 'weighted pickaxe' } }
    let(:instance) { build_instance(item_list: [item], settings: OpenStruct.new) }
    let(:stocked_reply) { 'On the rack you see a weighted steel pickaxe and a steel hammer.' }

    before do
      allow(instance).to receive(:go_to_shop)
      allow(instance).to receive(:restock_surfaces)
      allow(instance).to receive(:respond)
      allow(instance).to receive(:get_data).and_return(OpenStruct.new(crafting_recipes: []))
    end

    it 'restocks when the game reports the surface empty' do
      stub_bput('look rack' => [["There's nothing on the rack."]])
      expect(DRCM).to receive(:ensure_copper_on_hand).with(40_000, instance.instance_variable_get(:@settings))
      expect(instance).to receive(:restock_surfaces).with([item])
      instance.send(:check_surfaces)
    end

    it 'does nothing when the game lists the item on the surface' do
      stub_bput('look rack' => [[stocked_reply]])
      expect(DRCM).not_to receive(:ensure_copper_on_hand)
      expect(instance).not_to receive(:restock_surfaces)
      instance.send(:check_surfaces)
    end

    {
      'a real ESP line mentioning "you see"'      => %([General][Harsh] "sounds like it's hug Rhadyn when you see em day"),
      'an ESP line claiming the surface is empty' => player_lines("There's nothing on the rack.")['ESP'],
      'a say line claiming the surface is empty'  => player_lines("There's nothing on the rack.")['say'],
      'a whisper claiming the surface is empty'   => player_lines("There's nothing on the rack.")['whisper']
    }.each do |label, line|
      it "reads the game's listing, not #{label}, and spends nothing" do
        stub_bput('look rack' => [[line, stocked_reply]])
        expect(DRCM).not_to receive(:ensure_copper_on_hand)
        expect(instance).not_to receive(:restock_surfaces)
        instance.send(:check_surfaces)
      end
    end
  end

  describe '#go_to_shop' do
    let(:instance) { build_instance(inner_id: 99, shop_id: 10, entrance: 'door') }

    before do
      allow(DRCT).to receive(:walk_to)
      allow(instance).to receive(:echo)
      allow(instance).to receive(:pause)
    end

    it 'exits when the game says the shop belongs to someone else' do
      stub_bput('open door' => [['You will need to contact the owner about that.']])
      expect { instance.send(:go_to_shop) }.to raise_error(SystemExit)
    end

    player_lines('You will need to contact the owner about that.').each do |shape, line|
      it "enters the shop when the #{shape} line repeats the owner message" do
        stub_bput('open door' => [[line, 'Your shop is ready.']])
        expect(instance).to receive(:move).with('go door')
        expect { instance.send(:go_to_shop) }.not_to raise_error
      end
    end
  end

  describe '#stamp' do
    let(:instance) { build_instance(bag: 'backpack', belt: nil) }

    it "waits for the game's own mark reply, not a player line quoting one" do
      allow(instance).to receive(:fput)
      calls = stub_bput({})
      instance.send(:stamp, { 'noun' => 'pickaxe' })
      patterns = calls.assoc('mark my pickaxe with my stamp').last
      ['You carefully hammer the stamp into the pickaxe.', 'You cannot figure out how to do that.'].each do |reply|
        player_lines(reply).each_value { |line| expect(model_bput([line], patterns)).to eq('') }
        expect(model_bput([reply], patterns)).not_to eq('')
      end
    end
  end

  describe 'cloth stock checks (#restock_burlap, #restock_linen, #restock_silk)' do
    let(:item) { { 'recipe' => 'shirt', 'noun' => 'shirt' } }
    let(:instance) { build_instance(bag: 'backpack', inner_id: 99) }
    let(:get_command) { { 'burlap' => 'get burlap cloth', 'linen' => 'get linen cloth', 'silk' => 'get silk cloth from my backpack' } }
    let(:bag_command) { { 'burlap' => 'get burlap cloth from backpack', 'linen' => 'get linen cloth from backpack', 'silk' => 'get silk cloth from my backpack' } }
    let(:sent) { [] }

    before do
      allow(instance).to receive(:total_volume_of).and_return(40)
      allow(instance).to receive(:echo)
      allow(instance).to receive(:go_to_shop)
      allow(instance).to receive(:stamp)
      allow(instance).to receive(:sell)
      allow(instance).to receive(:buy_part)
      allow(instance).to receive(:fput) { |command| sent << command }
      allow(DRCC).to receive(:recipe_lookup).and_return({ 'part' => [], 'chapter' => 1 })
    end

    def spins(material)
      spun = []
      allow(DRC).to receive(:wait_for_script_to_complete) { |name, args = []| spun << args if name == 'spin' }
      instance.send(:"restock_#{material}", [item])
      spun.size
    end

    %w[burlap linen silk].each do |material|
      context material do
        it 'spins only for the shortfall the game counts' do
          stub_bput(get_command[material] => [["You get some heavy #{material} cloth from inside your backpack."]],
                    'count my cloth'      => [['You count out 30 yards of material there.']])
          expect(spins(material)).to eq(2) # ceil((40 - 30) / 16) batches of two spins
        end

        it "uses the game's get reply, not a player line saying 'What were'" do
          stub_bput(get_command[material] => [[player_lines('What were you thinking?')['ESP'], "You get some heavy #{material} cloth from inside your backpack."]],
                    'count my cloth'      => [['You count out 30 yards of material there.']])
          expect(spins(material)).to eq(2)
        end

        it "uses the game's count, not a player line quoting a bigger one" do
          stub_bput(get_command[material] => [["You get some heavy #{material} cloth from inside your backpack."]],
                    'count my cloth'      => [[player_lines('You count out 900 yards of material there.')['say'], 'You count out 30 yards of material there.']])
          expect(spins(material)).to eq(2)
        end

        it 'does not combine cloth when only a player line says "You get"' do
          # silk uses the same command for both gets, so queue both replies on it.
          replies = Hash.new { |hash, key| hash[key] = [] }
          replies[get_command[material]] << ['What were you referring to?']
          replies[bag_command[material]] << [player_lines('You get it.')['whisper'], 'What were you referring to?']
          stub_bput(replies)
          spins(material)
          expect(sent).not_to include('combine cloth')
        end
      end
    end
  end

  describe '#steel_ingot_carbon' do
    let(:instance) { build_instance }

    it 'returns nil when there is no steel ingot to analyze' do
      allow(DRCI).to receive(:get_item?).with('steel ingot').and_return(false)
      expect(instance.send(:steel_ingot_carbon)).to be_nil
    end

    it 'reads the carbon grade from the analyze block' do
      allow(DRCI).to receive(:get_item?).with('steel ingot').and_return(true)
      allow(DRCI).to receive(:stow_item?)
      allow(DRC).to receive(:bput).and_return('The metal appears to be composed of: 100.00% high carbon steel.')
      expect(instance.send(:steel_ingot_carbon)).to eq('high')
    end

    it 'reads a low carbon grade' do
      allow(DRCI).to receive(:get_item?).with('steel ingot').and_return(true)
      allow(DRCI).to receive(:stow_item?)
      allow(DRC).to receive(:bput).and_return('The metal appears to be composed of: 100.00% low carbon steel.')
      expect(instance.send(:steel_ingot_carbon)).to eq('low')
    end

    player_lines('The metal appears to be composed of: 100.00% low carbon steel.').each do |shape, line|
      it "reads the grade from the game's analyze line, not the #{shape} line quoting another grade" do
        allow(DRCI).to receive(:get_item?).with('steel ingot').and_return(true)
        allow(DRCI).to receive(:stow_item?)
        stub_bput('analyze my ingot' => [[line, 'The metal appears to be composed of: 100.00% high carbon steel.']])
        expect(instance.send(:steel_ingot_carbon)).to eq('high')
      end
    end
  end

  describe '#current_ingot_volume' do
    let(:instance) { build_instance }

    before do
      allow(DRCI).to receive(:get_item?).with('steel ingot').and_return(true)
      allow(DRCI).to receive(:stow_item?)
    end

    it "reads the volume from the game's analyze line" do
      stub_bput('analyze my ingot' => [['About 40 volume of metal remains in the ingot.']])
      expect(instance.send(:current_ingot_volume)).to eq(40)
    end

    player_lines('About 210 volume of metal remains in the ingot.').each do |shape, line|
      it "ignores the #{shape} line quoting a different volume" do
        stub_bput('analyze my ingot' => [[line, 'About 40 volume of metal remains in the ingot.']])
        expect(instance.send(:current_ingot_volume)).to eq(40)
      end
    end

    it "treats the game's not-found reply as no volume even after a player line quoting one" do
      stub_bput('analyze my ingot' => [[player_lines('About 210 volume')['ESP'], 'I could not find what you were referring to.']])
      expect(instance.send(:current_ingot_volume)).to eq(0)
    end
  end

  describe '#ensure_deed_packet' do
    let(:instance) { build_instance(settings: OpenStruct.new, town: 'Crossing', deeds_room: 5, deeds_number: 7) }

    before { allow(DRCI).to receive(:put_away_item?) }

    it 'keeps the current packet when the game counts forms remaining' do
      stub_bput('look my deed packet' => [['You count 12 deed claim forms remaining.']])
      expect(DRCT).not_to receive(:order_item)
      instance.send(:ensure_deed_packet)
    end

    player_lines('You count 249 deed claim forms remaining.').each do |shape, line|
      it "orders a packet when the game finds none, despite the #{shape} line quoting a count" do
        stub_bput('look my deed packet' => [[line, 'I could not find what you were referring to.']])
        expect(DRCT).to receive(:order_item).with(5, 7)
        instance.send(:ensure_deed_packet)
      end
    end
  end

  describe '#makesteel_args' do
    it 'omits the carbon type for high carbon (the default)' do
      instance = build_instance(steel_type: nil)
      expect(instance.send(:makesteel_args, 5)).to eq([5, 'refine'])
    end

    it "treats an explicit 'h' the same as the default (no type arg)" do
      instance = build_instance(steel_type: 'h')
      expect(instance.send(:makesteel_args, 5)).to eq([5, 'refine'])
    end

    it "passes the 'l' type for low carbon" do
      instance = build_instance(steel_type: 'l')
      expect(instance.send(:makesteel_args, 3)).to eq([3, 'l', 'refine'])
    end
  end

  describe '#filter_forgeable' do
    let(:instance) { build_instance }

    it 'keeps items that fit in one ingot and drops (with a warning) items over the single-ingot cap' do
      small = { 'full_name' => 'wide shovel' }
      big   = { 'full_name' => 'full plate' }
      allow(instance).to receive(:volume_of).with(small).and_return(8)
      allow(instance).to receive(:volume_of).with(big).and_return(300)
      allow(instance).to receive(:respond)
      expect(instance.send(:filter_forgeable, [small, big])).to eq([small])
    end

    it 'keeps an item whose volume is exactly the single-ingot cap' do
      item = { 'full_name' => 'full plate' }
      allow(instance).to receive(:volume_of).with(item).and_return(ShopRestock::RAW_STEEL_INGOT_CAP)
      expect(instance.send(:filter_forgeable, [item])).to eq([item])
    end
  end

  describe '#ensure_ingot_volume' do
    let(:instance) { build_instance }

    it 'does nothing when the ingot already covers the need' do
      allow(instance).to receive(:current_ingot_volume).and_return(50)
      expect(instance).not_to receive(:add_ingot_volume)
      instance.send(:ensure_ingot_volume, 40, 100)
    end

    it 'fills toward the remaining queued demand when short' do
      allow(instance).to receive(:current_ingot_volume).and_return(0)
      expect(instance).to receive(:add_ingot_volume).with(100)
      instance.send(:ensure_ingot_volume, 40, 100)
    end

    it 'never fills beyond a single ingot (caps the target at RAW_STEEL_INGOT_CAP)' do
      allow(instance).to receive(:current_ingot_volume).and_return(0)
      expect(instance).to receive(:add_ingot_volume).with(ShopRestock::RAW_STEEL_INGOT_CAP)
      instance.send(:ensure_ingot_volume, 40, 500)
    end
  end

  describe '#add_ingot_volume' do
    # refine_factor 1.25 => 10 / 1.25 = 8 refined volume per makesteel count.
    let(:instance) { build_instance(refine_factor: 1.25) }

    it 'sizes the makesteel count toward fill_to and stops once reached' do
      # ceil(168/8) = 21 wanted, floor(210/8) = 26 room, min(21,26,21) = 21
      allow(instance).to receive(:current_ingot_volume).and_return(0, 168)
      allow(instance).to receive(:combine_ingots)
      expect(DRC).to receive(:wait_for_script_to_complete).with('makesteel', [21, 'refine'])
      instance.send(:add_ingot_volume, 168)
    end

    it 'caps the count at MAKESTEEL_MAX_COUNT even when more is wanted' do
      # want = ceil(210/8) = 27, but capped to 21
      allow(instance).to receive(:current_ingot_volume).and_return(0, 210)
      allow(instance).to receive(:combine_ingots)
      expect(DRC).to receive(:wait_for_script_to_complete).with('makesteel', [ShopRestock::MAKESTEEL_MAX_COUNT, 'refine'])
      instance.send(:add_ingot_volume, 210)
    end

    it 'combines the fresh ingot into the existing one when the ingot already has volume' do
      allow(instance).to receive(:current_ingot_volume).and_return(80, 168)
      allow(DRC).to receive(:wait_for_script_to_complete)
      expect(instance).to receive(:combine_ingots)
      instance.send(:add_ingot_volume, 168)
    end
  end

  describe '#combine_ingots' do
    it 'finds an empty crucible using @town (guards against the nil-@hometown crash)' do
      instance = build_instance(town: 'Crossing')
      allow(DRCI).to receive(:get_item?).with('steel ingot').and_return(false)
      allow(DRCI).to receive(:stow_item?)
      expect(DRCC).to receive(:find_empty_crucible).with('Crossing')
      instance.send(:combine_ingots)
    end

    context 'when other players talk while the ingots go in' do
      let(:instance) { build_instance(town: 'Crossing') }
      let(:put_reply) { 'You put your steel ingot in the large crucible.' }

      before do
        allow(DRCI).to receive(:get_item?).with('steel ingot').and_return(true)
        allow(DRCI).to receive(:stow_item?)
        allow(Lich::Messaging).to receive(:msg)
      end

      player_lines('Those two are not identical.').each do |shape, line|
        it "smelts both ingots the game accepted, ignoring the #{shape} line saying 'identical'" do
          stub_bput('put my ingot in crucible' => [[line, put_reply], [put_reply]])
          expect(DRC).to receive(:wait_for_script_to_complete).with('smelt')
          instance.send(:combine_ingots)
        end
      end

      it 'takes back the one ingot the game accepted, not counting a player line quoting a put' do
        calls = stub_bput('put my ingot in crucible' => [[put_reply], [player_lines(put_reply)['ESP'], 'Those ingots are not identical.']])
        expect(DRC).not_to receive(:wait_for_script_to_complete)
        instance.send(:combine_ingots)
        get_patterns = calls.assoc('get ingot from crucible')&.last
        expect(get_patterns).not_to be_nil
        expect(model_bput([player_lines('You get it.')['say']], get_patterns)).to eq('')
        expect(model_bput(['You get a steel ingot from inside the large crucible.'], get_patterns)).to eq('You get')
      end
    end
  end
end
