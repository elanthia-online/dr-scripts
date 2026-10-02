# frozen_string_literal: true

require 'ostruct'
require_relative 'spec_helper'

load_lic_class('mooniefill.lic', 'MoonieFill')

RSpec.describe MoonieFill do
  before(:each) do
    reset_data
    allow(DRC).to receive(:wait_for_script_to_complete)
    allow(DRC).to receive(:bput)
    allow(DRC).to receive(:message)
    allow(DRCMM).to receive(:get_telescope?).and_return(true)
    allow(DRCMM).to receive(:store_telescope?).and_return(true)
  end

  let(:settings) do
    OpenStruct.new(
      telescope_name: 'mahogany telescope',
      telescope_storage: { 'container' => 'rucksack' }
    )
  end

  let(:instance) do
    described_class.allocate.tap do |m|
      m.instance_variable_set(:@magic, %w[Ox Wolf])
      m.instance_variable_set(:@lore, %w[Raven Dolphin])
      m.instance_variable_set(:@survival, %w[Sun Ram])
      m.instance_variable_set(:@offense, %w[Boar Panther])
      m.instance_variable_set(:@defense, %w[Lion Centaur])
      m.instance_variable_set(:@pools, %w[Survival Magic Lore Defense Offense])
      m.instance_variable_set(:@settings, settings)
    end
  end

  describe '#fill_pools' do
    it 'messages when a pool is already completely understood' do
      allow(DRC).to receive(:bput).with('predict state Survival', any_args).and_return('complete understanding')
      allow(DRC).to receive(:bput).with(/predict state (Magic|Lore|Defense|Offense)/, any_args).and_return('complete understanding')

      expect(DRC).to receive(:message).with('Survival is full!')
      instance.fill_pools
    end

    it 'calls observe when a pool is not completely understood' do
      allow(DRC).to receive(:bput).with('predict state Survival', any_args).and_return('weak understanding')
      allow(DRC).to receive(:bput).with(/predict state (Magic|Lore|Defense|Offense)/, any_args).and_return('complete understanding')

      expect(instance).to receive(:observe).with('Survival')
      instance.fill_pools
    end
  end

  describe '#observe' do
    it 'exits if telescope cannot be retrieved' do
      allow(DRCMM).to receive(:get_telescope?).with('mahogany telescope', { 'container' => 'rucksack' }).and_return(false)
      expect(DRC).to receive(:message).with('Could not get telescope. Exiting.')
      expect { instance.observe('Survival') }.to raise_error(SystemExit)
    end

    it 'stows the telescope after observing constellations' do
      allow(instance).to receive(:waitfor)
      allow(instance).to receive(:check_pool)
      expect(DRCMM).to receive(:store_telescope?).with('mahogany telescope', { 'container' => 'rucksack' }).and_return(true)
      instance.observe('Survival')
    end
  end

  describe 'before_dying teardown' do
    it 'registers a before_dying block that stows the telescope' do
      $test_settings = settings
      captured_block = nil
      main_obj = TOPLEVEL_BINDING.eval('self')
      allow(main_obj).to receive(:before_dying) { |&block| captured_block = block }
      allow(MoonieFill).to receive(:new)

      load lic_path('mooniefill.lic')

      expect(captured_block).not_to be_nil
      expect(DRCMM).to receive(:store_telescope?).with('mahogany telescope', { 'container' => 'rucksack' })
      captured_block.call
    end
  end
end
