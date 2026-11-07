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
  # The clubmoss liniment's pair is its first run with a "You get ... from
  # inside" product line (25:12100, 25:12133); its first completion, 25:11251,
  # was taken out with `get my liniment from my large mortar` (25:11287).
  logged_products = {
    'aevaes tonic'       => { done: '26:28901', taken: '26:28919', recipe: 'some eye tonic' },
    'aloe unguent'       => { done: '26:27321', taken: '26:27353', recipe: 'some skin unguent' },
    'belradi elixir'     => { done: '26:6742', taken: '26:6794', recipe: 'a general elixir' },
    'blocil poultices'   => { done: '25:71713', taken: '25:71751', recipe: 'some limb poultices' },
    'cebi poultices'     => { done: '26:27977', taken: '26:28010', recipe: 'some skin poultices' },
    'clubmoss liniment'  => { done: '25:12100', taken: '25:12133', recipe: 'a clubmoss liniment' },
    'dioica poultices'   => { done: '25:65062', taken: '25:65093', recipe: 'some general poultices' },
    'eghmok tonic'       => { done: '26:26500', taken: '26:26529', recipe: 'some head tonic' },
    'genich poultices'   => { done: '25:53345', taken: '25:53387', recipe: 'some body poultices' },
    'georin unguent'     => { done: '25:51774', taken: '25:51803', recipe: 'some neck unguent' },
    'hulnik unguent'     => { done: '26:20260', taken: '26:20289', recipe: 'some back unguent' },
    'ithor tonic'        => { done: '25:72503', taken: '25:72534', recipe: 'some chest tonic' },
    'jadice unguent'     => { done: '26:24161', taken: '26:24196', recipe: 'some limb unguent' },
    'junliar tonic'      => { done: '25:57993', taken: '25:58022', recipe: 'some back tonic' },
    'lujeakave tonic'    => { done: '26:19470', taken: '26:19507', recipe: 'some skin tonic' },
    'marram salve'       => { done: '25:91361', taken: '25:91394', recipe: 'a marram salve' },
    'muljin tonic'       => { done: '25:86673', taken: '25:86712', recipe: 'some abdominal tonic' },
    'nemoih unguent'     => { done: '25:50548', taken: '25:50586', recipe: 'some head unguent' },
    'nilos unguent'      => { done: '26:23411', taken: '26:23443', recipe: 'some abdominal unguent' },
    'nuloe elixir'       => { done: '25:64239', taken: '25:64268', recipe: 'a limb elixir' },
    'ojhenik elixir'     => { done: '26:22699', taken: '26:22729', recipe: 'a body elixir' },
    'plovik unguent'     => { done: '25:52526', taken: '25:52559', recipe: 'some chest unguent' },
    'qun poultices'      => { done: '25:99598', taken: '25:99631', recipe: 'some face poultices' },
    'riolur tonic'       => { done: '26:18394', taken: '26:18423', recipe: 'some neck tonic' },
    'sufil unguent'      => { done: '26:12373', taken: '26:12428', recipe: 'some eye unguent' },
    'woundwort curative' => { done: '26:39378', taken: '26:39410', recipe: 'a woundwort curative' },
    'yelith tonic'       => { done: '26:25234', taken: '26:25288', recipe: 'some limb tonic' }
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

  it 'gives every one of the 68 remedies recipes a noun of one word' do
    expect(recipes.size).to eq(68)
    expect(recipes.reject { |recipe| recipe['noun'].to_s.match?(/\A[a-z]+\z/) }).to be_empty
  end

  logged_products.each do |product, cites|
    context "#{product}, made in the logs (#{cites[:done]}, #{cites[:taken]})" do
      it 'is named the same by the completion line and the product line' do
        expect(completed_product(cites[:done])).to eq(product)
        expect(taken_product(cites[:taken])).to eq(product)
      end

      # herb1 is the herb word (nemoih) or, for an instructions recipe, the
      # prepared herb (dried clubmoss), whose last word is the herb word.
      it "is made by exactly one one-herb recipe, #{cites[:recipe]}: its herb1's herb word starts the product's first word and its noun is the last" do
        herb_word, noun = product.split
        makers = recipes.select { |recipe| recipe['herb2'].nil? && herb_word.start_with?(recipe['herb1'].split.last) && recipe['noun'] == noun }
        expect(makers.map { |recipe| recipe['name'] }).to eq([cites[:recipe]])
      end

      it 'is found by that recipe noun as DRCI.in_hands? would, whatever article or shortening the hand name has' do
        noun = recipes.find { |recipe| recipe['name'] == cites[:recipe] }['noun']
        hand_names = [product, "some #{product}", "a #{product}", drc_hand_name("some #{product}")]
        expect(hand_names.reject { |name| ReplayCommons.matches?(name, noun) }).to be_empty
      end
    end
  end

  it 'proves 27 recipes from the logs' do
    expect(log_proven.uniq.size).to eq(27)
    expect(log_proven - recipes.map { |recipe| recipe['name'] }).to be_empty
  end

  it 'gives each of the 41 recipes no log shows a noun equal to the last word of its name' do
    unlogged = recipes.reject { |recipe| log_proven.include?(recipe['name']) }
    expect(unlogged.size).to eq(41)
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

# The four remedies made from stand-alone instructions.
# They are data only: remedy.lic's instructions form
# (`;remedy instructions <herb> <catalyst> <container> <noun>`) is what
# makes them, and no reader of base-recipes.yaml may find them where it found
# a book recipe before.
RSpec.describe 'data/base-recipes.yaml instructions remedies' do
  all_recipes = YAML.load_file(File.expand_path('../data/base-recipes.yaml', __dir__), aliases: true)['crafting_recipes']
  # The weaponsmithing instructions recipes (smith.lic) are not remedies.
  instructions = all_recipes.select { |recipe| recipe['instructions'] && recipe['type'] == 'remedies' }
  remedies = all_recipes.select { |recipe| recipe['type'] == 'remedies' }
  # base-recipes.yaml as it was before this data: the instructions recipes
  # are the only entries it adds.
  before = all_recipes.reject { |recipe| recipe['instructions'] }
  ingredients = YAML.load_file(File.expand_path('../data/base-ingredients.yaml', __dir__))['ingredients']

  # The raw herbs the game names with the same noun as the prepared herb:
  # "You put your clubmoss ..." (25:16301) answered `put shining clubmoss in
  # greenhouse` (25:16300); "You put your woundwort ..." (26:29226) answered
  # `put woundwort in applewood basket` (26:29225) with the marsh woundwort
  # just foraged (26:29210) in hand.
  raw_herb_lines = {
    'shining clubmoss' => ['25:16301', 'You put your clubmoss in your glass greenhouse.'],
    'marsh woundwort'  => ['26:29226', 'You put your woundwort in your applewood basket.']
  }

  # What each instructions recipe rests on in the logs. herb: the prepared
  # herb as the game hands it over; liquid: the binder the game asked for in
  # a run of that recipe; vessel: the product line, naming what it was made in.
  evidence = {
    'a clubmoss liniment'  => { herb: '25:10843', liquid: '25:10873', vessel: '25:12133' },
    'a woundwort curative' => { herb: '26:31070', liquid: '26:38957', vessel: '26:39410' },
    'a marram salve'       => { herb: '26:64281', liquid: '25:90979', vessel: '25:91394' }
  }

  # The prepared herb a "You get some <herb> from ..." line names.
  #
  # @param cite [String] "<log>:<line>"
  # @return [String, nil]
  def held_herb(cite)
    ReplayGame.log(cite).text[/\AYou get some (.+?) from /, 1]
  end

  # The binder a "You need another splash of <liquid> ..." line asks for.
  #
  # @param cite [String] "<log>:<line>"
  # @return [String, nil]
  def needed_liquid(cite)
    ReplayGame.log(cite).text[/\AYou need another splash of (\w+) to continue crafting an unfinished /, 1]
  end

  it 'adds exactly the four instructions remedies, all of type remedies' do
    expect(instructions.map { |recipe| recipe['name'] }).to eq(['a clubmoss liniment', 'a woundwort curative', 'a marram salve', 'a flamestalk potion'])
    expect(instructions.map { |recipe| recipe['type'] }.uniq).to eq(['remedies'])
  end

  it 'gives each no chapter, no work order, one volume, one herb, a mortar or a bowl and water or alcohol' do
    shapes = instructions.map { |recipe| recipe.values_at('chapter', 'work_order', 'volume', 'herb2') }
    expect(shapes.uniq).to eq([[nil, false, 1, nil]])
    expect(instructions.map { |recipe| recipe['container'] } - %w[mortar bowl]).to be_empty
    expect(instructions.map { |recipe| recipe['liquid'] } - %w[water alcohol]).to be_empty
  end

  it 'puts them after every book remedy, so a first-match name search reaches the book recipes first' do
    last_book_remedy = all_recipes.rindex { |recipe| recipe['type'] == 'remedies' && !recipe['instructions'] }
    expect(instructions.map { |recipe| all_recipes.index(recipe) }).to all(be > last_book_remedy)
  end

  it 'leaves every other remedies recipe with an Integer chapter, except the three-herb alyssum tea' do
    unchaptered = remedies.reject { |recipe| recipe['instructions'] || recipe['chapter'].is_a?(Integer) }
    expect(unchaptered.map { |recipe| recipe['name'] }).to eq(['some alyssum tea'])
    expect(unchaptered.first['herb3']).not_to be_nil
  end

  raw_herb_lines.each do |raw_name, (cite, text)|
    it "keeps herb1 off #{raw_name}, which the game names by the prepared herb's noun (#{cite})" do
      expect(ReplayGame.log(cite).text).to eq(text)
      noun = raw_name.split.last
      herb1 = instructions.find { |recipe| recipe['herb1'].split.last == noun }['herb1']
      expect(herb1).not_to eq(noun)
      expect(ReplayCommons.matches?(raw_name, herb1)).to be(false)
    end
  end

  it 'reads the woundwort put away at 26:29226 as the marsh woundwort just foraged (26:29210)' do
    expect(ReplayGame.log('26:29210').text).to eq('You manage to find some marsh woundwort.')
  end

  instructions.each do |recipe|
    context recipe['name'] do
      # create_remedies forages and prepares herb1 as the raw herb whose
      # output it is; alchemy.lic:35 finds that ingredient by
      # `name =~ /<target>/i`.
      it "is the prepared output of exactly one base-ingredients herb, which alchemy.lic finds by name" do
        raw = ingredients.select { |ingredient| ingredient['output'].to_s.strip == recipe['herb1'] }
        expect(raw.size).to eq(1)
        expect(ingredients.find { |ingredient| ingredient['name'] =~ /#{raw.first['name']}/i }).to equal(raw.first)
      end

      # ReplayCommons.matches? models the DRCI short_regex match
      # DRCI.in_hands? uses.
      it 'does not name the raw herb it is foraged as, which the bare herb word does' do
        raw_name = ingredients.find { |ingredient| ingredient['output'].to_s.strip == recipe['herb1'] }['name']
        expect(ReplayCommons.matches?(raw_name, recipe['herb1'])).to be(false)
        expect(ReplayCommons.matches?(raw_name, recipe['herb1'].split.last)).to be(true)
      end

      it 'has its noun as the last word of its name, the product word DRCI.in_hands? checks' do
        expect(recipe['noun']).to eq(recipe['name'].split.last)
      end
    end
  end

  evidence.each do |name, cites|
    context "#{name}, made in the logs" do
      let(:recipe) { instructions.find { |entry| entry['name'] == name } }

      it "takes herb1 as the prepared herb the game hands over (#{cites[:herb]}), as DRCI.in_hands? matches it" do
        herb = held_herb(cites[:herb])
        expect(herb).to eq(recipe['herb1'])
        expect(ReplayCommons.matches?(herb, recipe['herb1'])).to be(true)
      end

      it "names the binder the game asked for (#{cites[:liquid]})" do
        expect(needed_liquid(cites[:liquid])).to eq(recipe['liquid'])
      end

      it "asks for the vessel the product came out of (#{cites[:vessel]}): a mortar, or a bowl, which a cauldron answers" do
        vessel = ReplayGame.log(cites[:vessel]).text[/ from inside an? (?:\w+ )*?(mortar|cauldron|bowl) /, 1]
        expect(vessel == 'mortar' ? 'mortar' : 'bowl').to eq(recipe['container'])
      end
    end
  end

  context 'a flamestalk potion, never made in the logs' do
    let(:recipe) { instructions.find { |entry| entry['name'] == 'a flamestalk potion' } }

    it 'takes herb1 as the crushed flamestalk the game hands over (26:103936)' do
      expect(held_herb('26:103936')).to eq(recipe['herb1'])
      expect(ReplayCommons.matches?(held_herb('26:103936'), recipe['herb1'])).to be(true)
    end

    it 'names the potion the way the game does (25:23437, another player rubbing one on)' do
      expect(ReplayGame.log('25:23437').text).to include("flamestalk #{recipe['noun']}")
    end

    # CODE-DERIVED: another crafting script seen in the logs binds flamestalk
    # with water and mixes potions in a cauldron; no log shows a run.
    it 'pins the bowl and the water binder' do
      expect(recipe.values_at('container', 'liquid')).to eq(%w[bowl water])
    end
  end

  # Each reader of base-recipes.yaml, by its own lookup, must find what it
  # found before the instructions recipes were added. "Before" is the file
  # without them.
  describe 'every existing lookup finds the same recipe as before' do
    old_names = before.map { |recipe| recipe['name'] }.uniq

    it 'gives every literal name pattern a .lic reads recipes by the same first match (craft.lic:166-519 and the rest)' do
      patterns = Dir[File.expand_path('../*.lic', __dir__)].flat_map do |path|
        File.read(path).scan(%r{\['name'\] =~ /([^/#]+)/}).flatten
      end
      expect(patterns).to include('some blister cream', 'a radiant trinket', 'some vigor poultices')
      changed = patterns.uniq.reject { |pattern| all_recipes.find { |recipe| recipe['name'] =~ /#{pattern}/ }.equal?(before.find { |recipe| recipe['name'] =~ /#{pattern}/ }) }
      expect(changed).to be_empty
    end

    it 'gives every old recipe name the same first case-sensitive match (craft.lic, full-name searches)' do
      changed = old_names.reject { |name| all_recipes.find { |recipe| recipe['name'] =~ /#{name}/ }.equal?(before.find { |recipe| recipe['name'] =~ /#{name}/ }) }
      expect(changed).to be_empty
    end

    it 'gives every old recipe name the same escaped first match tinker.lic:169 uses' do
      changed = old_names.reject do |name|
        pattern = /#{Regexp.escape(name)}/i
        all_recipes.find { |recipe| recipe['name'].to_s =~ pattern }.equal?(before.find { |recipe| recipe['name'].to_s =~ pattern })
      end
      expect(changed).to be_empty
    end

    # DRCC.recipe_lookup (lich-5 common-crafting.rb:365-386) selects every
    # name matching /<item>/i, so restock-shop.lic, smith.lic and trade.lic
    # must see the same candidates; restock-shop.lic:83 selects the same way
    # and validate.lic:950 asks whether any name matches.
    it 'gives every old recipe name the same set of matches DRCC.recipe_lookup chooses from' do
      changed = old_names.reject { |name| all_recipes.select { |recipe| recipe['name'] =~ /#{name}/i } == before.select { |recipe| recipe['name'] =~ /#{name}/i } }
      expect(changed).to be_empty
    end

    # Weaponsmithing also gains the instructions weapons smith.lic makes;
    # spec/smith_spec.rb covers how smith and restock-shop look them up.
    it 'leaves every selection by a type other than remedies and weaponsmithing untouched (trade.lic:2068/2187, workorders.lic)' do
      other_types = before.map { |recipe| recipe['type'] }.uniq - %w[remedies weaponsmithing]
      changed = other_types.reject { |type| all_recipes.select { |recipe| recipe['type'] == type } == before.select { |recipe| recipe['type'] == type } }
      expect(changed).to be_empty
    end

    it 'adds none of them to the work_order recipes workorders.lic asks the NPC for by default' do
      expect(all_recipes.select { |recipe| recipe['work_order'] }).to eq(before.select { |recipe| recipe['work_order'] })
    end
  end
end
