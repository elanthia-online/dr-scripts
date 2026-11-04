# frozen_string_literal: true

require_relative 'spec_helper'

load_lic_class('newbie-gear.lic', 'NewbieGear')

RSpec.describe NewbieGear do
  let(:gear) { NewbieGear.allocate.tap { |instance| instance.instance_variable_set(:@bag, 'duffel bag') } }
  let(:scripts) { [] }
  let(:sent) { [] }
  # noun, volumes, chapter, recipe name, small padding, large padding, material
  let(:shirt) { ['shirt', 34, 4, 'quilted cloth shirt', 0, 2, 'heavy burlap'] }
  # noun, volumes, chapter, recipe name, material
  let(:backpack) { ['backpack', 5, 3, 'backpack', 'heavy linen'] }

  before do
    allow(DRC).to receive(:wait_for_script_to_complete) do |name, args = []|
      scripts << [name, args]
      # weave-cloth leaves its count in SessionVars (weave-cloth.lic STOCK_RESULT)
      SessionVars['weave_cloth_stock'] = { 'fiber' => args.first, 'yards' => args.last.to_i } if name == 'weave-cloth'
    end
    allow(gear).to receive(:fput) { |command| sent << command }
    allow(gear).to receive(:echo)
    allow(gear).to receive(:move)
    allow(DRC).to receive(:bput).and_return('')
  end

  describe '#restock_burlap' do
    it 'has weave-cloth stock the yards every item needs, before sewing' do
      gear.restock_burlap('locker', [shirt, shirt])

      expect(scripts.first).to eq(['weave-cloth', ['burlap', '68']])
    end

    it 'sews nothing, and says why, when weave-cloth comes up short' do
      allow(DRC).to receive(:wait_for_script_to_complete) do |name, args = []|
        scripts << [name, args]
        SessionVars['weave_cloth_stock'] = { 'fiber' => 'burlap', 'yards' => 16 } if name == 'weave-cloth'
      end
      expect(Lich::Messaging).to receive(:msg).with('bold', 'newbie-gear: weave-cloth has 16 of the 34 yards of burlap cloth needed; not sewing the burlap items.')

      gear.restock_burlap('locker', [shirt])

      expect(scripts.map(&:first)).to eq(['weave-cloth'])
      expect(sent).to be_empty
    end

    it 'does not spin, combine or count cloth itself' do
      gear.restock_burlap('locker', [shirt])

      expect(scripts.map(&:first)).not_to include('spin')
      expect(sent).not_to include('combine cloth')
      expect(DRC).not_to have_received(:bput).with(/cloth/, any_args)
    end

    it 'takes the finished item from the crafting container, where sew stows it' do
      gear.restock_burlap('locker', [shirt])

      expect(sent).to include('get my shirt from my duffel bag')
      expect(sent.grep(/from back/)).to be_empty
    end
  end

  describe '#restock_linen' do
    it 'has weave-cloth stock the linen, then takes the item from the crafting container' do
      gear.restock_linen('locker', [backpack])

      expect(scripts.first).to eq(['weave-cloth', ['linen', '5']])
      expect(sent).to include('get my backpack from my duffel bag')
    end
  end

  # weave-cloth leaves its count where both callers read it; the scripts are
  # separate files, so this pins them to one key.
  describe 'the stock result shared with weave-cloth' do
    before { load_lic_class('weave-cloth.lic', 'WeaveCloth') }

    %w[newbie-gear.lic restock-shop.lic].each do |caller|
      it "#{caller} reads the key weave-cloth writes" do
        expect(File.read(lic_path(caller))).to include("SessionVars['#{WeaveCloth::STOCK_RESULT}']")
      end
    end
  end
end
