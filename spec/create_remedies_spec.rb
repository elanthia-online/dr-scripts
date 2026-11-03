# frozen_string_literal: true

require 'ostruct'
require 'yaml'

require_relative 'spec_helper'

load_lic_class('create_remedies.lic', 'CreateRemedies')

RSpec.describe CreateRemedies do
  let(:create_remedies) { described_class.allocate }
  let(:recipes) { YAML.load_file(File.expand_path('../data/base-recipes.yaml', __dir__), aliases: true)['crafting_recipes'] }
  let(:ingredients) { YAML.load_file(File.expand_path('../data/base-ingredients.yaml', __dir__))['ingredients'] }
  # CODE-DERIVED: no log has a herb tap reply; bput hands back the text the
  # "You tap" pattern matched (create_remedies.lic:36-48).
  let(:tapped) { ReplayGame.code('You tap', from: 'create_remedies.lic:45').text }
  # The hands remedy.lic leaves when it ends.
  let(:remedy_hands) { [nil, nil] }
  let(:messages) { [] }
  # [script name, first two arguments] of each script run, in order.
  let(:scripts_run) { [] }

  before do
    $left_hand = nil
    $right_hand = nil
    $test_data.recipes = OpenStruct.new(crafting_recipes: recipes)
    $test_data.ingredients = OpenStruct.new(ingredients: ingredients)
    allow(DRC).to receive(:bput).and_return(tapped)
    allow(DRC).to receive(:message) { |text| messages << text }
    allow(DRCI).to receive(:in_hands?) { |item| ReplayCommons.held?(item) }
    allow(DRC).to receive(:wait_for_script_to_complete) do |name, args|
      scripts_run << [name, args.first(2)]
      $left_hand, $right_hand = remedy_hands if name == 'remedy'
    end
  end

  # Runs create_remedies as `;create_remedies <target>` (or
  # `;create_remedies <target> tools`), with the herbs on hand.
  #
  # @param target [String] the recipe name to search
  # @param tools [Boolean] whether to pass the tools option
  # @return [void]
  def run(target, tools: false)
    $parsed_args = { target: target }
    $parsed_args[:tools] = 'tools' if tools
    create_remedies.send(:initialize)
  end

  # remedy.lic gives no exit status; the product it leaves in hand is its
  # success signal.
  describe 'after remedy' do
    context 'when remedy leaves the product in hand' do
      # The product of 26:20289, "You get some hulnik unguent from inside a
      # diamondique large mortar ...".
      let(:remedy_hands) { [nil, 'hulnik unguent'] }

      # A guard that fires here would exit; not_to raise_error turns that
      # into a failure instead of a silent end of the whole run.
      it 'runs remedy with the arguments of today and ends without a stop' do
        expect { run('back unguent') }.not_to raise_error

        expect(DRC).to have_received(:wait_for_script_to_complete)
          .with('remedy', ['remedies', 3, 'some back unguent', 'hulnik', 'na', 'coal nugget', 'mortar', 'unguent'])
        expect(messages).to be_empty
      end

      it 'finds the product in the left hand too, with a tool in the right' do
        remedy_hands.replace(['hulnik unguent', 'pestle'])
        expect { run('back unguent') }.not_to raise_error
        expect(messages).to be_empty
      end

      it 'gets the tools before remedy and stores them after it with `tools`' do
        expect { run('back unguent', tools: true) }.not_to raise_error

        expect(scripts_run).to eq([['clerk-tools', %w[alchemy get]], ['remedy', ['remedies', 3]], ['clerk-tools', %w[alchemy store]]])
        expect(messages).to be_empty
      end
    end

    context 'when remedy leaves no product in hand' do
      it 'says so and stops' do
        expect { run('back unguent') }.to raise_error(SystemExit)
        expect(messages).to eq(['CreateRemedies: remedy did not leave some back unguent (unguent) in hand. Stopping.'])
      end

      it 'checks the two-herb call (create_remedies.lic:56), with the swapped flower herb, the same way' do
        remedy_hands.replace(['diamondique mortar', 'pestle'])
        expect { run('blister cream') }.to raise_error(SystemExit)

        expect(DRC).to have_received(:wait_for_script_to_complete)
          .with('remedy', ['remedies', 2, 'some blister cream', 'dried flower', 'nemoih', 'coal nugget', 'mortar', 'cream'])
        expect(messages).to eq(['CreateRemedies: remedy did not leave some blister cream (cream) in hand. Stopping.'])
      end

      # get_store_tools names `debug`, which is Lich's global there (lich-5
      # 480bdee3 lib/global_defs.rb:446-454, modelled in the harness), so the
      # store runs today whatever remedy left; the stop keeps it.
      it 'still stores the tools before it stops with `tools`' do
        expect { run('back unguent', tools: true) }.to raise_error(SystemExit)

        expect(scripts_run).to eq([['clerk-tools', %w[alchemy get]], ['remedy', ['remedies', 3]], ['clerk-tools', %w[alchemy store]]])
        expect(messages).to eq(['CreateRemedies: remedy did not leave some back unguent (unguent) in hand. Stopping.'])
      end
    end
  end

  # An instructions recipe names herb1 as the prepared herb, "dried clubmoss",
  # because the raw herb answers to the same noun: `put shining clubmoss in
  # greenhouse` (25:16300) -> "You put your clubmoss ..." (25:16301), and
  # `put woundwort ...` (26:29225) put away the marsh woundwort just foraged
  # (26:29210, 26:29226). So the tap asks for the prepared herb by that name,
  # and with none on hand alchemy.lic forages and prepares the raw herb.
  describe 'the herb a recipe is tapped, foraged and prepared by' do
    # [script name, all arguments] of each script run.
    let(:runs) { [] }
    # The game's reply to a tap of nothing on hand (25:13762, to
    # `tap sack in rugu`).
    let(:not_found) { ReplayGame.log('25:13762').text }

    before do
      allow(DRC).to receive(:wait_for_script_to_complete) { |name, args| runs << [name, args] }
    end

    it 'taps the prepared herb of an instructions recipe by its full name, not by the noun the raw herb shares' do
      expect { run('liniment') }.to raise_error(SystemExit)

      expect(DRC).to have_received(:bput).with('tap first dried clubmoss', 'You tap', 'What were', 'I could not')
      expect(runs.map(&:first)).to eq(['remedy'])
    end

    {
      'liniment'   => 'shining clubmoss',
      'curative'   => 'marsh woundwort',
      'marram'     => 'marram grass',
      'flamestalk' => 'ashen flamestalk'
    }.each do |target, raw_herb|
      it "forages and prepares #{raw_herb} for `#{target}` when no prepared herb is on hand" do
        allow(DRC).to receive(:bput).and_return(not_found)
        expect { run(target) }.to raise_error(SystemExit)

        expect(runs.first(2)).to eq([['alchemy', [raw_herb, 'forage', 25]], ['alchemy', [raw_herb, 'prepare']]])
      end
    end

    it 'still forages and prepares a book recipe herb as the recipe names it' do
      allow(DRC).to receive(:bput).and_return(not_found)
      expect { run('back unguent') }.to raise_error(SystemExit)

      expect(runs).to eq([['alchemy', ['hulnik', 'forage', 25]], ['alchemy', %w[hulnik prepare]],
                          ['remedy', ['remedies', 3, 'some back unguent', 'hulnik', 'na', 'coal nugget', 'mortar', 'unguent']]])
    end

    it 'passes every herb of every book recipe to alchemy.lic unchanged, as none is a prepared output' do
      book_herbs = recipes.reject { |recipe| recipe['instructions'] }.flat_map { |recipe| recipe.values_at('herb1', 'herb2', 'herb3') }.compact.uniq
      expect(book_herbs).to include('nemoih', 'red flower', 'blue flower')
      expect(book_herbs.reject { |herb| create_remedies.forage_name(herb) == herb }).to be_empty
    end

    it 'gives alchemy.lic the raw herb whose prepared output each instructions herb1 is' do
      herbs = recipes.select { |recipe| recipe['instructions'] }.map { |recipe| recipe['herb1'] }
      expect(herbs.map { |herb| create_remedies.forage_name(herb) }).to eq(['shining clubmoss', 'marsh woundwort', 'marram grass', 'ashen flamestalk'])
    end
  end

  # base-recipes.yaml now ends its remedies with four made from stand-alone
  # instructions. create_remedies.lic:31 takes the first
  # recipe whose name matches the target, so they must come after every
  # recipe a target found before.
  describe 'the recipe a target finds' do
    # [script name, all arguments] of each script run.
    let(:runs) { [] }
    let(:before_data) { recipes.reject { |recipe| recipe['instructions'] } }

    before do
      allow(DRC).to receive(:wait_for_script_to_complete) { |name, args| runs << [name, args] }
    end

    # The scripts create_remedies runs for a target, and how it ended.
    #
    # @param target [String]
    # @param data [Array<Hash>] the crafting_recipes get_data hands back
    # @return [Array] [[script, arguments]..., the error class or :finished]
    def outcome(target, data)
      $test_data.recipes = OpenStruct.new(crafting_recipes: data)
      runs.clear
      ending = begin
        run(target)
        :finished
      rescue SystemExit, StandardError => e
        e.class
      end
      runs.dup << ending
    end

    # The herbs are on hand and remedy leaves nothing in hand, so the only
    # script is remedy and the run ends in the no-product stop.
    it 'still sends `salve` and `potion` to the first book recipe of that name, with the 8-argument call' do
      expect(outcome('salve', recipes))
        .to eq([['remedy', ['remedies', 2, 'some itch salve', 'dried flower', 'jadice', 'coal nugget', 'mortar', 'salve']], SystemExit])
      expect(outcome('potion', recipes))
        .to eq([['remedy', ['remedies', 2, 'some hangover potion', 'crushed flower', 'ojhenik', 'coal nugget', 'bowl', 'potion']], SystemExit])
    end

    it 'runs the same scripts with the same arguments as before for every full name and every word of every recipe name' do
      targets = (before_data.map { |recipe| recipe['name'] } + before_data.flat_map { |recipe| recipe['name'].scan(/\w+/) }).uniq
      expect(targets.size).to be > 1000
      changed = targets.reject { |target| outcome(target, recipes) == outcome(target, before_data) }
      expect(changed).to be_empty
    end
  end
end
