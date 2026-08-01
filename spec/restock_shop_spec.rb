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
  end
end
