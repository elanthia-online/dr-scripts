# frozen_string_literal: true

require 'ostruct'
require 'yaml'

require_relative 'spec_helper'

load_lic_class('craft.lic', 'Craft')

RSpec.describe Craft do
  let(:craft) { described_class.allocate }
  let(:recipes) { YAML.load_file(File.expand_path('../data/base-recipes.yaml', __dir__), aliases: true)['crafting_recipes'] }
  let(:chest_unguent) { recipes.find { |recipe| recipe['name'] == 'some chest unguent' } }
  let(:blister_cream) { recipes.find { |recipe| recipe['name'] == 'some blister cream' } }
  # The hands remedy.lic leaves when it ends.
  let(:remedy_hands) { [nil, nil] }

  before do
    $left_hand = nil
    $right_hand = nil
    $test_data.crafting = { 'remedies' => { 'Crossing' => { 'catalyst' => 'coal nugget', 'stock-room' => 8774 } } }
    craft.instance_variable_set(:@hometown, 'Crossing')
    craft.instance_variable_set(:@bag, 'backpack')
    craft.instance_variable_set(:@belt, nil)
    craft.instance_variable_set(:@worn_trashcan, nil)
    craft.instance_variable_set(:@worn_trashcan_verb, nil)
    craft.instance_variable_set(:@training_room, 1234)
    craft.instance_variable_set(:@debug, nil)
    # Every herb is on hand and the catalyst is bought: brew goes straight to remedy.
    allow(craft).to receive(:check_alchemy_herbs).and_return({})
    allow(craft).to receive(:money_for_training?).and_return(true)
    allow(DRCC).to receive(:stow_crafting_item)
    allow(DRCT).to receive(:walk_to)
    allow(DRCI).to receive(:dispose_trash)
    allow(DRCI).to receive(:in_hands?) { |item| ReplayCommons.held?(item) }
    allow(DRC).to receive(:wait_for_script_to_complete) do |name, _args|
      $left_hand, $right_hand = remedy_hands if name == 'remedy'
    end
  end

  # remedy.lic gives no exit status; the product it leaves in hand is its
  # success signal.
  describe '#brew after remedy' do
    context 'when remedy leaves the product in hand' do
      # The product of 25:52559, "You get some plovik unguent from inside a
      # diamondique large mortar ...".
      let(:remedy_hands) { ['plovik unguent', nil] }

      # A guard that fires here would exit; not_to raise_error turns that
      # into a failure instead of a silent end of the whole run.
      it 'runs remedy with the arguments of today and throws the product away' do
        expect { craft.brew(chest_unguent, 4000, herb2: 'na') }.not_to raise_error

        expect(DRC).to have_received(:wait_for_script_to_complete)
          .with('remedy', ['remedies', 3, 'some chest unguent', 'plovik', 'na', 'coal nugget', 'mortar', 'unguent'])
        expect(DRCI).to have_received(:dispose_trash).with('unguent', nil, nil)
        expect(displayed_messages).not_to include(a_string_matching(/did not leave/))
      end

      it 'finds it in the right hand too' do
        remedy_hands.reverse!
        expect { craft.brew(chest_unguent, 4000, herb2: 'na') }.not_to raise_error
        expect(DRCI).to have_received(:dispose_trash).with('unguent', nil, nil)
      end
    end

    context 'when remedy leaves no product in hand' do
      it 'stops without disposing, so dispose_trash cannot get a stored remedy of that noun and throw it away' do
        expect { craft.brew(chest_unguent, 4000, herb2: 'na') }.to raise_error(SystemExit)

        expect(displayed_messages).to include('Craft: remedy did not leave some chest unguent (unguent) in hand. Stopping.')
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'stops when remedy leaves only its vessel and stirrer in hand' do
        remedy_hands.replace(['diamondique mortar', 'pestle'])
        expect { craft.brew(blister_cream, 2000) }.to raise_error(SystemExit)

        expect(DRC).to have_received(:wait_for_script_to_complete)
          .with('remedy', ['remedies', 2, 'some blister cream', 'red flower', 'nemoih', 'coal nugget', 'mortar', 'cream'])
        expect(displayed_messages).to include('Craft: remedy did not leave some blister cream (cream) in hand. Stopping.')
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'stops when another remedy kind is in hand' do
        remedy_hands.replace(['belradi elixir', nil])
        expect { craft.brew(chest_unguent, 4000, herb2: 'na') }.to raise_error(SystemExit)
        expect(DRCI).not_to have_received(:dispose_trash)
      end
    end

    it 'still returns before remedy when the recipe is missing' do
      craft.brew(nil, 4000)
      expect(DRC).not_to have_received(:wait_for_script_to_complete)
    end
  end
end
