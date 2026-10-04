# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('shape.lic', 'Shape')

RSpec.describe Shape do
  # Instantiate without running initialize, setting only what prep reads.
  let(:shape) do
    instance = Shape.allocate
    {
      instruction: 'instructions', noun: 'bow', material: 'maple', chapter: 6,
      bag: 'backpack', bag_items: [], belt: nil,
      settings: OpenStruct.new(crafting_training_spells: [])
    }.each { |k, v| instance.instance_variable_set(:"@#{k}", v) }
    instance
  end

  # Models the hands: a get fills the first free hand (and does nothing if the
  # item is already held, or if both hands are full), a stow empties the hand
  # holding that item, and SWAP exchanges the hands.
  def model_hands(right: nil, left: nil)
    hands = { right: right, left: left }
    holding = ->(side, item) { !hands[side].nil? && hands[side].include?(item.to_s) }
    allow(DRC).to receive(:right_hand) { hands[:right] }
    allow(DRC).to receive(:left_hand) { hands[:left] }
    allow(DRC).to receive(:right_hand_noun) { hands[:right]&.split&.last }
    allow(DRCI).to receive(:in_left_hand?) { |item| holding.call(:left, item) }
    allow(DRCI).to receive(:in_right_hand?) { |item| holding.call(:right, item) }
    allow(DRCC).to receive(:get_crafting_item) do |item, *|
      next if holding.call(:right, item) || holding.call(:left, item)

      side = %i[right left].find { |s| hands[s].nil? }
      hands[side] = item if side
    end
    allow(DRCC).to receive(:stow_crafting_item) do |item, *|
      side = %i[right left].find { |s| item && holding.call(s, item) }
      hands[side] = nil if side
      true
    end
    allow(DRC).to receive(:bput) do |command, *|
      hands[:right], hands[:left] = hands[:left], hands[:right] if command == 'swap'
      'Roundtime'
    end
    hands
  end

  describe '#prep with instructions' do
    {
      'empty hands'                      => {},
      'the drawknife in your right hand' => { right: 'drawknife' },
      'the drawknife in your left hand'  => { left: 'drawknife' }
    }.each do |label, start_hands|
      it "ends with the drawknife and lumber in hand, starting with #{label}" do
        hands = model_hands(**start_hands)

        command = nil
        expect { command = shape.prep }.not_to raise_error

        expect(hands.values).to contain_exactly('drawknife', 'maple lumber')
        expect(hands[:left]).to eq('maple lumber')
        expect(command).to eq('scrape my lumber with my drawknife')
      end
    end
  end
end
