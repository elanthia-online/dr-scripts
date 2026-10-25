# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('remedy.lic', 'Remedy')

RSpec.describe Remedy do
  def build_instance(alchemy_tools)
    instance = described_class.allocate
    instance.instance_variable_set(:@settings, OpenStruct.new(alchemy_tools: alchemy_tools))
    instance.instance_variable_set(:@recipe_name, 'some eye wash')
    instance
  end

  describe '#resolve_container' do
    # base-recipes.yaml asks for either "mortar" or "bowl".
    let(:mortar_only) { ['rustic mortar', 'rustic pestle', 'mesh sieve'] }
    let(:with_bowl) { ['rustic mortar', 'rustic pestle', 'mesh sieve', 'ceramic bowl'] }
    let(:with_cauldron) { ['rustic mortar', 'rustic pestle', 'iron cauldron'] }

    it 'matches a recipe container against the tool that holds that word' do
      expect(build_instance(mortar_only).send(:resolve_container, 'mortar')).to eq('rustic mortar')
    end

    it 'accepts a cauldron for a recipe that asks for a bowl' do
      expect(build_instance(with_cauldron).send(:resolve_container, 'bowl')).to eq('iron cauldron')
    end

    it 'prefers a bowl for a recipe that asks for a bowl' do
      expect(build_instance(with_bowl).send(:resolve_container, 'bowl')).to eq('ceramic bowl')
    end

    # Before this, an unlisted container returned nil and the script sent the
    # malformed command "get my " with no item name.
    it 'stops when no tool matches a bowl' do
      messages = []
      allow(DRC).to receive(:message) { |text| messages << text }
      expect { build_instance(mortar_only).send(:resolve_container, 'bowl') }.to raise_error(SystemExit)
      expect(messages.first).to include('some eye wash', 'bowl', 'alchemy_tools')
      expect(messages.last).to include('Add your bowl to alchemy_tools')
    end

    it 'stops when no tool matches a mortar' do
      allow(DRC).to receive(:message)
      expect { build_instance(['ceramic bowl']).send(:resolve_container, 'mortar') }.to raise_error(SystemExit)
    end

    it 'stops when alchemy_tools is empty or unset' do
      allow(DRC).to receive(:message)
      [[], nil].each do |tools|
        %w[mortar bowl].each do |requested|
          expect { build_instance(tools).send(:resolve_container, requested) }.to raise_error(SystemExit)
        end
      end
    end

    it 'never returns nil for any container a recipe can ask for' do
      allow(DRC).to receive(:message)
      [mortar_only, with_bowl, with_cauldron, []].each do |tools|
        %w[mortar bowl].each do |requested|
          instance = build_instance(tools)
          begin
            expect(instance.send(:resolve_container, requested)).not_to be_nil
          rescue SystemExit
            # Stopping is the other acceptable answer. A nil is not.
          end
        end
      end
    end
  end

  # remedy.lic picks its next crafting step from Flags set by the game's
  # "You need another ..." style lines and from the lines its bputs return.
  # These specs run the real script against a small model of the game:
  #
  # - every incoming line goes through the registered Flags matchers the way
  #   lich-5 DRParser.check_events does (raw line, first matching regex per key);
  # - DRC.bput reads the same lines with tags stripped, String patterns become
  #   /x/i, and the first line matching any pattern ends the window and bput
  #   returns the matched text.
  #
  # Each step must come from the game's own line, not from the same words in
  # another player's speech, whisper or ESP. Only the script's own patterns are
  # known for these game lines; the rest of their wording is assumed.
  describe 'reading the game, not other players' do
    let(:remedy) { described_class.allocate }
    let(:replies) { Hash.new { |hash, command| hash[command] = [] } }
    let(:commands) { [] }
    let(:fputs) { [] }
    let(:put_aways) { [] }
    let(:first_crush) { 'crush my jadice flower with my rustic pestle' }
    let(:next_crush) { 'crush my cream with my rustic pestle' }
    let(:finished) { 'Applying the final touches, you complete working on some blister cream.' }

    # Player-written lines as Flags see them (raw XML) and as bput sees them.
    def player_xml(text)
      [%(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
       %(<preset id='speech'>Mallory says</preset>, "#{text}"),
       %(<pushStream id="whispers"/><preset id="whisper">Mallory whispers,</preset> "#{text}")]
    end

    def player_text(text)
      [%([General][Mallory] "#{text}"), %(Mallory says, "#{text}"), %(Mallory whispers, "#{text}")]
    end

    # ;remedy remedies 2 "blister cream" "jadice flower" "nilos grass" nemoih mortar cream
    def start_remedy(water_container: nil, herb_in_bag: false, craft: false)
      $test_settings = OpenStruct.new(
        crafting_container: 'satchel', crafting_items_in_container: [], alchemy_belt: nil,
        crafting_training_spells: [], hometown: 'Crossing', mark_crafted_goods: false, cube_armor_piece: nil,
        alchemy_tools: ['rustic mortar', 'rustic pestle', 'mesh sieve'], herb_container: nil,
        water_container: water_container, alcohol_container: nil, master_crafting_book: 'remedy book'
      )
      $test_data.crafting = { 'remedies' => { 'Crossing' => {} } }
      $parsed_args = OpenStruct.new(book_type: 'remedies', chapter: '2', recipe_name: 'blister cream',
                                    herb1: 'jadice flower', herb2: 'nilos grass', catalyst: 'nemoih',
                                    container: 'mortar', noun: 'cream')
      allow(DRCI).to receive(:exists?).and_return(herb_in_bag)
      allow(DRCI).to receive(:put_away_item?) { |*args| put_aways << args }
      allow(remedy).to receive(:buy_item)
      allow(remedy).to receive(:create_item) unless craft
      allow(remedy).to receive(:fput) { |message| fputs << message }
      allow(DRC).to receive(:bput) { |command, *patterns| game_bput(command, patterns) }
      remedy.send(:initialize)
    end

    # lich-5 DRParser.check_events over one raw server line.
    def deliver(line)
      Flags.matchers.each do |key, regexes|
        regexes.each do |regex|
          if (match = line.match(regex))
            Flags[key] = match
            break
          end
        end
      end
    end

    def game_bput(command, patterns)
      commands << command
      raise "sent #{command.inspect} too often" if commands.count(command) > 10

      regexes = patterns.flatten.map { |item| item.is_a?(Regexp) ? item : /#{item}/i }
      (replies[command].shift || []).each do |raw|
        deliver(raw)
        text = raw.gsub(/<[^>]+>/, '')
        regexes.each do |regex|
          match = text.match(regex)
          return match.to_a.first if match
        end
      end
      ''
    end

    def work_until_finished
      replies[first_crush] << [finished]
      expect { remedy.send(:work, first_crush) }.to raise_error(SystemExit)
    end

    # Flag key, a game line that sets it, and the command its step sends.
    [['remedy-water', 'You need another splash of water to continue.', 'put water in my rustic mortar'],
     ['remedy-alcohol', 'You need another splash of alcohol to continue.', 'put alcohol in my rustic mortar'],
     ['remedy-catalyst', 'You need another catalyst material to continue.', 'put my nemoih in my rustic mortar'],
     ['remedy-herb', 'You need another prepared herb to continue.', 'put my nilos grass in my rustic mortar'],
     ['remedy-turn', 'Clumps of material stick to the sides of the mortar.', 'turn my rustic mortar'],
     ['remedy-turn', 'Once finished you notice clumps of material stuck to the sides.', 'turn my rustic mortar'],
     ['remedy-smell', 'The mixture begins to transition colors.', 'smell my cream'],
     ['remedy-smell', 'Perhaps you should smell the mixture.', 'smell my cream'],
     ['remedy-sieve', 'Upon completion you see some particulate clouding up the mixture.', 'push my cream with my sieve'],
     ['remedy-sieve', 'The mixture should be strained with a sieve.', 'push my cream with my sieve']].each do |key, line, step|
      it "#{key}: takes the step for the game's line '#{line}'" do
        [line, "<pushBold/>#{line}", "The mixture settles.  #{line}"].each do |real|
          start_remedy
          deliver(real)
          work_until_finished
          expect(commands).to include(step), "no #{step.inspect} for #{real.inspect}"
          commands.clear
        end
      end

      it "#{key}: ignores '#{line}' in another player's ESP, speech or whisper" do
        player_xml(line).each do |spoof|
          start_remedy
          deliver(spoof)
          work_until_finished
          expect(commands).to eq([first_crush]), "acted on #{spoof.inspect}"
          commands.clear
        end
      end
    end

    describe 'the count of a water container' do
      it 'refills a container the game says is not there, whatever a player says' do
        ['', *player_text('There are five parts left of the water.')].each do |spoof|
          fputs.clear
          replies['count water in my flask'] << [spoof, 'I could not find what you were referring to.'].reject(&:empty?)
          replies['count water in my flask'] << ['There are five parts left of the water.']
          start_remedy(water_container: 'flask')
          expect(fputs).to include('rub my flask'), "no refill after #{spoof.inspect}"
          expect(remedy.instance_variable_get(:@water_verb)).to eq('pour')
        end
      end

      it 'uses a container the game counts, whatever a player says' do
        ['', *player_text('I could not find what you were referring to.')].each do |spoof|
          fputs.clear
          replies['count water in my flask'] << [spoof, 'There are five parts left of the water.'].reject(&:empty?)
          start_remedy(water_container: 'flask')
          expect(fputs).not_to include('rub my flask'), "refilled after #{spoof.inspect}"
          expect(remedy.instance_variable_get(:@water_verb)).to eq('pour')
        end
      end
    end

    describe 'gathering the herb' do
      def craft_with_herb_replies(combine:, first_count: nil)
        replies['count my jadice flower'] << ['You count out 25 pieces of jadice flower.']
        replies['combine my jadice flower'] << combine
        replies['count my first jadice flower'] << first_count if first_count
        replies['count my second jadice flower'] << ['You count out 40 pieces of jadice flower.']
        replies['put jadice flower in my rustic mortar'] << ['You put some jadice flower in your rustic mortar.']
        replies[first_crush] << [finished]
        expect { start_remedy(herb_in_bag: true, craft: true) }.to raise_error(SystemExit)
      end

      it "checks the stacks only when the game says the stack is too large, not a player's line" do
        craft_with_herb_replies(combine: ['That stack is too large to add to.'])
        expect(commands).to include('count my first jadice flower')

        player_text('too large to add').each do |spoof|
          commands.clear
          craft_with_herb_replies(combine: [spoof, 'You combine the jadice flower.'])
          expect(commands).not_to include('count my first jadice flower'), "counted stacks after #{spoof.inspect}"
        end
      end

      it "puts away a stack only when the game counts 75 pieces, not a player's line" do
        craft_with_herb_replies(combine: ['That stack is too large to add to.'], first_count: ['You count out 75 pieces of jadice flower.'])
        expect(put_aways).to include(['second jadice flower'])

        player_text('You count out 75 pieces').each do |spoof|
          put_aways.clear
          craft_with_herb_replies(combine: ['That stack is too large to add to.'], first_count: [spoof, 'You count out 30 pieces of jadice flower.'])
          expect(put_aways).not_to include(['second jadice flower']), "put a stack away after #{spoof.inspect}"
        end
      end

      it "tilts the mortar only when the game says it is not empty, not a player's line" do
        replies['put jadice flower in my rustic mortar'] << ['Your rustic mortar already has something in it.']
        replies['put jadice flower in my rustic mortar'] << ['You put some jadice flower in your rustic mortar.']
        replies['count my jadice flower'] << ['You count out 25 pieces of jadice flower.']
        replies[first_crush] << [finished]
        expect { start_remedy(craft: true) }.to raise_error(SystemExit)
        expect(commands).to include('tilt my rustic mortar')

        player_text('already has something').each do |spoof|
          commands.clear
          replies['put jadice flower in my rustic mortar'] << [spoof, 'You put some jadice flower in your rustic mortar.']
          replies['count my jadice flower'] << ['You count out 25 pieces of jadice flower.']
          replies[first_crush] << [finished]
          expect { start_remedy(craft: true) }.to raise_error(SystemExit)
          expect(commands).not_to include('tilt my rustic mortar'), "tilted after #{spoof.inspect}"
        end
      end
    end

    describe 'the crafting reply' do
      ['Applying the final touches', 'Interesting thought really... but no.', "you just can't mix",
       'Try as you might', 'That craftable requires more pieces of that plant to begin'].each do |phrase|
        it "keeps crafting when a player says '#{phrase}'" do
          player_text(phrase).each do |spoof|
            start_remedy
            replies[first_crush] << [spoof, 'Roundtime: 3 sec.']
            replies[next_crush] << [finished]
            expect { remedy.send(:work, first_crush) }.to raise_error(SystemExit)
            expect(commands).to eq([first_crush, next_crush]), "stopped after #{spoof.inspect}"
            commands.clear
          end
        end
      end

      it 'finishes on the game line even after a player says Roundtime:' do
        player_text('Roundtime: 3 sec.').each do |spoof|
          start_remedy
          replies[first_crush] << [spoof, finished]
          replies[next_crush] << [finished]
          expect { remedy.send(:work, first_crush) }.to raise_error(SystemExit)
          expect(commands).to eq([first_crush]), "kept crafting after #{spoof.inspect}"
          commands.clear
        end
      end

      it 'keeps crafting on the bracketed roundtime line' do
        start_remedy
        replies[first_crush] << ['[Roundtime: 3 sec]']
        replies[next_crush] << [finished]
        expect { remedy.send(:work, first_crush) }.to raise_error(SystemExit)
        expect(commands).to eq([first_crush, next_crush])
      end
    end

    describe 'adding water' do
      let(:refused) { 'You cannot find a way to add that as an ingredient.' }

      def add_water_with(reply)
        start_remedy
        deliver('You need another splash of water to continue.')
        replies['put water in my rustic mortar'] << reply
        work_until_finished
      end

      it 'falls back to the water itself only when the game refuses the container' do
        add_water_with([refused])
        expect(put_aways).to include(['water', 'rustic mortar'])

        player_text(refused).each do |spoof|
          put_aways.clear
          add_water_with([spoof, 'Roundtime: 2 sec.'])
          expect(put_aways).not_to include(['water', 'rustic mortar']), "fell back after #{spoof.inspect}"
        end
      end

      it 'still falls back when a player says Roundtime before the refusal' do
        player_text('Roundtime: 2 sec.').each do |spoof|
          put_aways.clear
          add_water_with([spoof, refused])
          expect(put_aways).to include(['water', 'rustic mortar']), "no fallback after #{spoof.inspect}"
        end
      end
    end
  end

  describe '#work' do
    let(:instance) { build_instance(['rustic mortar', 'rustic pestle', 'mesh sieve']) }

    before do
      allow(instance).to receive(:waitrt?)
      allow(DRCA).to receive(:crafting_magic_routine)
    end

    it 'finishes when not enough pieces of the plant to begin' do
      expect(DRC).to receive(:bput).with(
        'crush my some eye wash with my rustic pestle',
        '^Applying the final touches',
        /^[^"]*?Interesting thought really... but no./i,
        /^[^"]*?you just can't mix/i,
        /^[^"]*?Try as you might/i,
        /^[^"]*?That craftable requires more pieces of that plant to begin/i,
        /^[^"]*?Roundtime:/i
      ).and_return('That craftable requires more pieces of that plant to begin')
      expect(instance).to receive(:finish).and_raise(SystemExit)

      instance.instance_variable_set(:@container, 'rustic mortar')
      instance.instance_variable_set(:@noun, 'some eye wash')
      instance.instance_variable_set(:@pestle, 'rustic pestle')
      instance.instance_variable_set(:@verb, 'crush')
      expect { instance.send(:work, 'crush my some eye wash with my rustic pestle') }.to raise_error(SystemExit)
    end
  end
end
