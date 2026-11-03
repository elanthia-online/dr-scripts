# frozen_string_literal: true

require 'yaml'

require_relative 'spec_helper'

# workorders.lic, craft.lic and create_remedies.lic stop when remedy.lic
# leaves no product in hand, read as DRCI.in_hands?(recipe['noun']). A noun
# that missed the real product would stop a run that succeeds today, so this
# spec proves, for every `type: remedies` recipe of data/base-recipes.yaml,
# that its noun finds the product the game hands over:
#
# - from the real completion line ("Applying the final touches, you complete
#   working on ...") and product line ("You get ... from inside ...") of every
#   recipe the 2026-10-25/26 logs show being made;
# - otherwise, from the noun being the last word of the recipe name.
#
# DRCI.in_hands? matches the hand's name with DRC::Item short_regex, a word
# prefix for one word (lich-5 480bdee3 common-items.rb:935-937, :978-998;
# common.rb:629-631, :644-656), modelled by ReplayCommons.matches?. DRC's
# hand name keeps the first and the last word of the game's name
# (fix_dr_bullshit, common.rb:842-857).
RSpec.describe 'data/base-recipes.yaml remedies: the product noun the callers check' do
  recipes = YAML.load_file(File.expand_path('../data/base-recipes.yaml', __dir__), aliases: true)['crafting_recipes']
                .select { |recipe| recipe['type'] == 'remedies' }

  # Every remedy product the logs show, with the first completion line and
  # product line that name it, and the one base-recipes recipe that makes it.
  logged_products = {
    'aevaes tonic'     => { done: '26:28901', taken: '26:28919', recipe: 'some eye tonic' },
    'aloe unguent'     => { done: '26:27321', taken: '26:27353', recipe: 'some skin unguent' },
    'belradi elixir'   => { done: '26:6742', taken: '26:6794', recipe: 'a general elixir' },
    'blocil poultices' => { done: '25:71713', taken: '25:71751', recipe: 'some limb poultices' },
    'cebi poultices'   => { done: '26:27977', taken: '26:28010', recipe: 'some skin poultices' },
    'dioica poultices' => { done: '25:65062', taken: '25:65093', recipe: 'some general poultices' },
    'eghmok tonic'     => { done: '26:26500', taken: '26:26529', recipe: 'some head tonic' },
    'genich poultices' => { done: '25:53345', taken: '25:53387', recipe: 'some body poultices' },
    'georin unguent'   => { done: '25:51774', taken: '25:51803', recipe: 'some neck unguent' },
    'hulnik unguent'   => { done: '26:20260', taken: '26:20289', recipe: 'some back unguent' },
    'ithor tonic'      => { done: '25:72503', taken: '25:72534', recipe: 'some chest tonic' },
    'jadice unguent'   => { done: '26:24161', taken: '26:24196', recipe: 'some limb unguent' },
    'junliar tonic'    => { done: '25:57993', taken: '25:58022', recipe: 'some back tonic' },
    'lujeakave tonic'  => { done: '26:19470', taken: '26:19507', recipe: 'some skin tonic' },
    'muljin tonic'     => { done: '25:86673', taken: '25:86712', recipe: 'some abdominal tonic' },
    'nemoih unguent'   => { done: '25:50548', taken: '25:50586', recipe: 'some head unguent' },
    'nilos unguent'    => { done: '26:23411', taken: '26:23443', recipe: 'some abdominal unguent' },
    'nuloe elixir'     => { done: '25:64239', taken: '25:64268', recipe: 'a limb elixir' },
    'ojhenik elixir'   => { done: '26:22699', taken: '26:22729', recipe: 'a body elixir' },
    'plovik unguent'   => { done: '25:52526', taken: '25:52559', recipe: 'some chest unguent' },
    'qun poultices'    => { done: '25:99598', taken: '25:99631', recipe: 'some face poultices' },
    'riolur tonic'     => { done: '26:18394', taken: '26:18423', recipe: 'some neck tonic' },
    'sufil unguent'    => { done: '26:12373', taken: '26:12428', recipe: 'some eye unguent' },
    'yelith tonic'     => { done: '26:25234', taken: '26:25288', recipe: 'some limb tonic' }
  }
  log_proven = logged_products.values.map { |product| product[:recipe] }

  # The product a completion line names, without its article.
  #
  # @param cite [String] "<log>:<line>"
  # @return [String, nil]
  def completed_product(cite)
    ReplayGame.log(cite).text[/\AApplying the final touches, you complete working on (?:a|an|some) (.+)\.\z/, 1]
  end

  # The product a product line names, without its article.
  #
  # @param cite [String] "<log>:<line>"
  # @return [String, nil]
  def taken_product(cite)
    ReplayGame.log(cite).text[/\AYou get (?:a|an|some) (.+?) from inside /, 1]
  end

  # The hand name DRC.left_hand / DRC.right_hand gives for a game name: its
  # first and last word when it has three or more (fix_dr_bullshit,
  # common.rb:842-851).
  #
  # @param name [String]
  # @return [String]
  def drc_hand_name(name)
    words = name.split
    words.size <= 2 ? name : "#{words.first} #{words.last}"
  end

  it 'gives every one of the 64 remedies recipes a noun of one word' do
    expect(recipes.size).to eq(64)
    expect(recipes.reject { |recipe| recipe['noun'].to_s.match?(/\A[a-z]+\z/) }).to be_empty
  end

  logged_products.each do |product, cites|
    context "#{product}, made in the logs (#{cites[:done]}, #{cites[:taken]})" do
      it 'is named the same by the completion line and the product line' do
        expect(completed_product(cites[:done])).to eq(product)
        expect(taken_product(cites[:taken])).to eq(product)
      end

      it "is made by exactly one one-herb recipe, #{cites[:recipe]}: its herb1 starts the product's first word and its noun is the last" do
        herb_word, noun = product.split
        makers = recipes.select { |recipe| recipe['herb2'].nil? && herb_word.start_with?(recipe['herb1']) && recipe['noun'] == noun }
        expect(makers.map { |recipe| recipe['name'] }).to eq([cites[:recipe]])
      end

      it 'is found by that recipe noun as DRCI.in_hands? would, whatever article or shortening the hand name has' do
        noun = recipes.find { |recipe| recipe['name'] == cites[:recipe] }['noun']
        hand_names = [product, "some #{product}", "a #{product}", drc_hand_name("some #{product}")]
        expect(hand_names.reject { |name| ReplayCommons.matches?(name, noun) }).to be_empty
      end
    end
  end

  it 'proves 24 recipes from the logs' do
    expect(log_proven.uniq.size).to eq(24)
    expect(log_proven - recipes.map { |recipe| recipe['name'] }).to be_empty
  end

  it 'gives each of the 40 recipes no log shows a noun equal to the last word of its name' do
    unlogged = recipes.reject { |recipe| log_proven.include?(recipe['name']) }
    expect(unlogged.size).to eq(40)
    expect(unlogged.reject { |recipe| recipe['noun'] == recipe['name'].split.last }.map { |recipe| recipe['name'] }).to be_empty
  end

  it 'leaves no recipe unproven, so no caller guard needs to fail open' do
    proven = recipes.select { |recipe| log_proven.include?(recipe['name']) || recipe['noun'] == recipe['name'].split.last }
    expect(proven.size).to eq(recipes.size)
  end

  context 'when the noun is not the product' do
    it 'does not find the vessel or the stirrer remedy holds while it crafts' do
      # The vessel names of the product lines (25:50586, 25:58022), shortened
      # as DRC gives them, and the stirrers remedy names (Remedy::Tools::DEFAULT_PESTLE,
      # Remedy::Tools::MIXING_STICK).
      held = [drc_hand_name('diamondique large mortar carved with delicate flowers'), drc_hand_name('heavy cauldron with twisted Dwarven iron handles'), 'pestle', 'mixing stick']
      found = recipes.map { |recipe| recipe['noun'] }.uniq.select { |noun| held.any? { |name| ReplayCommons.matches?(name, noun) } }
      expect(found).to be_empty
    end

    it 'does not find another remedy kind left in hand' do
      expect(ReplayCommons.matches?(taken_product('26:6794'), 'tonic')).to be(false)
      expect(ReplayCommons.matches?(taken_product('25:58022'), 'elixir')).to be(false)
    end
  end
end
