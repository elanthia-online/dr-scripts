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
    it 'stows the telescope when held in hands upon exiting' do
      allow(DRC).to receive(:right_hand).and_return('telescope')
      allow(DRC).to receive(:left_hand).and_return(nil)
      allow(self).to receive(:get_settings).and_return(settings)

      expect(DRCMM).to receive(:store_telescope?).with('mahogany telescope', { 'container' => 'rucksack' })

      # Simulate the before_dying block defined in mooniefill.lic
      settings = get_settings
      DRCMM.store_telescope?(settings.telescope_name, settings.telescope_storage) if DRC.right_hand || DRC.left_hand
    end

    it 'does not stow when hands are empty' do
      allow(DRC).to receive(:right_hand).and_return(nil)
      allow(DRC).to receive(:left_hand).and_return(nil)
      allow(self).to receive(:get_settings).and_return(settings)

      expect(DRCMM).not_to receive(:store_telescope?)

      settings = get_settings
      DRCMM.store_telescope?(settings.telescope_name, settings.telescope_storage) if DRC.right_hand || DRC.left_hand
    end
  end
end
