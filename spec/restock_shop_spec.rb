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
end
