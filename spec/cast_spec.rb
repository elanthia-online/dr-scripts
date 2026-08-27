# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('cast.lic', 'Cast')

RSpec.describe Cast do
  # Athlya's profile: two small worn items and one large stored one. This shape
  # shows the difference between the two charge schemes.
  def three_cambrinth_items
    [
      { 'name' => 'cambrinth earcuff', 'cap' => 4, 'stored' => false },
      { 'name' => 'cambrinth anklet', 'cap' => 4, 'stored' => false },
      { 'name' => 'sea urchin', 'cap' => 48, 'stored' => true }
    ]
  end

  def build_instance(distribute: false, total_mana: 25, charge: '3', camb_items: nil)
    instance = described_class.allocate
    {
      settings: OpenStruct.new(cambrinth_distribute_charges: distribute),
      camb_items: camb_items || three_cambrinth_items,
      total_mana: total_mana,
      min_prep_mana: 1,
      charge: charge,
      runestone: nil,
      arcana_ranks: 500,
      spell_data: {},
      debug: false
    }.each { |k, v| instance.instance_variable_set(:"@#{k}", v) }
    instance
  end

  describe '#charge_plan without cambrinth_distribute_charges' do
    it 'splits the charges evenly and skips items too small for one' do
      # 25 mana, 3 charges: prep 7, then charges of 6, 6, 6.
      prep, cambrinth = build_instance(distribute: false, total_mana: 25).send(:charge_plan)
      expect(prep).to eq(7)
      expect(cambrinth).to eq([[], [], [6, 6, 6]])
    end

    it 'uses the small items only when a charge happens to fit' do
      # 16 mana, 3 charges: prep 4, then charges of 4, 4, 4.
      prep, cambrinth = build_instance(distribute: false, total_mana: 16).send(:charge_plan)
      expect(prep).to eq(4)
      expect(cambrinth).to eq([[4], [4], [4]])
    end

    it 'moves mana that fits in no item into the prep' do
      items = [{ 'name' => 'ring', 'cap' => 4, 'stored' => false }]
      prep, cambrinth = build_instance(distribute: false, total_mana: 40, camb_items: items).send(:charge_plan)
      expect(cambrinth.flatten.sum + prep).to eq(40)
    end
  end

  describe '#charge_plan with cambrinth_distribute_charges' do
    it 'asks DRCA to allocate the charges and uses the answer' do
      instance = build_instance(distribute: true, total_mana: 25)
      expect(DRCA).to receive(:allocate_cambrinth_charges)
        .with(18, three_cambrinth_items, 3)
        .and_return([[[4], [4], [10]], 0])
      prep, cambrinth = instance.send(:charge_plan)
      expect(prep).to eq(7)
      expect(cambrinth).to eq([[4], [4], [10]])
    end

    it 'moves the mana DRCA could not place into the prep' do
      instance = build_instance(distribute: true, total_mana: 25)
      allow(DRCA).to receive(:allocate_cambrinth_charges).and_return([[[4], [4], [8]], 2])
      prep, cambrinth = instance.send(:charge_plan)
      expect(prep).to eq(9)
      expect(cambrinth.flatten.sum + prep).to eq(25)
    end

    # The harness DRCA has no allocate_cambrinth_charges, exactly like an older
    # Lich, so this drives the real guard rather than a stub of it.
    it 'falls back to the built-in split when Lich has no allocator' do
      instance = build_instance(distribute: true, total_mana: 25)
      expect(DRCA).not_to respond_to(:allocate_cambrinth_charges)
      prep, cambrinth = instance.send(:charge_plan)
      expect(prep).to eq(7)
      expect(cambrinth).to eq([[], [], [6, 6, 6]])
    end
  end

  describe '#distribute_num_charges' do
    it 'puts the remainder in the first charge' do
      prep, charges = build_instance(total_mana: 60, charge: '4').send(:distribute_num_charges)
      expect(prep).to eq(12)
      expect(charges).to eq([12, 12, 12, 12])
    end

    it 'returns undistributed mana to the prep instead of dividing by zero' do
      instance = build_instance(total_mana: 60, charge: '0')
      instance.instance_variable_set(:@runestone, 'runestone')
      prep, charges = instance.send(:distribute_num_charges)
      expect(charges).to eq([])
      expect(prep).to eq(60)
    end
  end
end
