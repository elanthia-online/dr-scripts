# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('tinker.lic', 'Tinker')

RSpec.describe Tinker do
  let(:tools) { ['drawknife', 'clamps', 'shaper', 'carving knife', 'rasp'] }

  before do
    $test_settings = OpenStruct.new(
      hometown: 'Crossing', crafting_container: 'backpack', crafting_items_in_container: [],
      tinkering_tools: tools, workorders_materials: {}, crafting_training_spells: []
    )
    $test_data.crafting = { 'shaping' => { 'Crossing' => { 'tool-room' => 1, 'stain-number' => 2, 'glue-number' => 3 } } }
    $test_data.recipes = OpenStruct.new(crafting_recipes: [])

    # Tools and materials are already in hand, so swap_tool and check_hand pass.
    allow(DRCI).to receive(:in_hands?).and_return(true)
    allow(DRCI).to receive(:in_left_hand?).and_return(true)
    allow(DRCC).to receive(:get_crafting_item)
    allow(DRCC).to receive(:find_recipe2)
  end

  # Run initialize on a bare instance, capturing the first command handed to
  # work instead of running the crafting loop.
  def start(args)
    $parsed_args = args
    tinker = Tinker.allocate
    allow(tinker).to receive(:echo) # tinker calls a bare echo, which Lich allows
    allow(tinker).to receive(:work) { |command| @command = command }
    tinker.send(:initialize)
    tinker
  end

  describe 'the instructions form' do
    it 'studies the instructions, then starts on the lumber' do
      start(instructions: 'instructions', material: 'maple', noun: 'crossbow')

      expect(DRCC).to have_received(:get_crafting_item).with('crossbow instructions', 'backpack', [], nil)
      expect(DRCC).to have_received(:get_crafting_item).with('maple lumber', 'backpack', [], nil)
      expect(@command).to eq('scrape my lumber with my drawknife')
    end

    it 'does not look in a recipe book or take the chapter 8 clamp path' do
      start(instructions: 'instructions', material: 'maple', noun: 'crossbow')

      expect(DRCC).not_to have_received(:find_recipe2)
      expect(@command).not_to include('clamp')
    end
  end

  # The stubs above say every tool is already in hand. This models the hands
  # themselves: a get fills the first free hand (and fails if both are full),
  # a stow empties the hand holding that item, and SWAP exchanges the hands.
  describe 'the instructions form, starting from different hands' do
    def model_hands(right: nil, left: nil)
      hands = { right: right, left: left }
      holding = ->(side, item) { !hands[side].nil? && hands[side].include?(item.to_s) }
      allow(DRC).to receive(:right_hand) { hands[:right] }
      allow(DRC).to receive(:left_hand) { hands[:left] }
      allow(DRCI).to receive(:in_hands?) { |item| holding.call(:right, item) || holding.call(:left, item) }
      allow(DRCI).to receive(:in_left_hand?) { |item| holding.call(:left, item) }
      allow(DRCI).to receive(:in_right_hand?) { |item| holding.call(:right, item) }
      allow(DRCC).to receive(:get_crafting_item) do |item, *|
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

    {
      'empty hands'                      => {},
      'the drawknife in your right hand' => { right: 'drawknife' },
      'the drawknife in your left hand'  => { left: 'drawknife' }
    }.each do |label, start_hands|
      it "ends with the drawknife and lumber in hand, starting with #{label}" do
        hands = model_hands(**start_hands)

        expect { start(instructions: 'instructions', material: 'maple', noun: 'crossbow') }.not_to raise_error

        expect(hands.values).to contain_exactly('drawknife', 'maple lumber')
        expect(hands[:left]).to eq('maple lumber')
        expect(@command).to eq('scrape my lumber with my drawknife')
      end
    end
  end

  describe 'crossbow enhancements' do
    it 'maps the enhancement name to its recipe' do
      tinker = start(recipe_name: 'lighten', noun: 'crossbow')

      expect(tinker.instance_variable_get(:@recipe_name)).to eq('crossbow lightening')
    end

    it 'still finds the recipe and starts with the clamps' do
      start(recipe_name: 'laminate', noun: 'crossbow')

      expect(DRCC).to have_received(:find_recipe2).with(8, 'crossbow lamination')
      expect(@command).to eq('push my crossbow with my clamp')
    end
  end
end
