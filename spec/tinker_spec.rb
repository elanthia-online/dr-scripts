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
    before do
      allow(DRC).to receive(:bput).and_call_original
      allow(DRC).to receive(:bput).with('study my instructions', any_args)
                                  .and_return('You scan the crossbow instructions with a glance and completely understand all facets of the design.')
    end

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
        next 'You scan the crossbow instructions with a glance and completely understand all facets of the design.' if command == 'study my instructions'

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

  # The game answers a study with its own line, then "You now feel ready to
  # begin the crafting process." and the roundtime. When the game lags,
  # replies to earlier commands (a stray Roundtime) can come first, so the
  # bput stub below reads a queue of lines the way DRC.bput does: it skips
  # lines that match none of the matchers it was given and returns the
  # matched text of the first that does, or '' (a timeout) when none is left.
  describe '#study_instructions' do
    let(:study_line_endings) do
      [
        'completely understand all facets of the design.',
        'comprehend all but several minor details in the text.',
        "confidently discern most of the design's minutiae."
      ]
    end
    let(:again_reply) do
      ['The delicate nature of the instructions will cause them to wear out with use.',
       '[These instructions have only 5 uses remaining.  Study them again to proceed.]']
    end
    let(:study_replies) { [] }
    let(:study_options) { [] }
    let(:matched_lines) { [] }
    let(:sent) { [] }
    # Instantiate without running initialize, setting only what the study reads.
    let(:tinker) do
      instance = Tinker.allocate
      { noun: 'crossbow', bag: 'backpack', bag_items: [], belt: nil, training_spells: [] }
        .each { |k, v| instance.instance_variable_set(:"@#{k}", v) }
      instance
    end

    def study_reply(ending)
      ["You scan the crossbow instructions with a glance and #{ending}",
       'You now feel ready to begin the crafting process.',
       'Roundtime: 7 sec.']
    end

    before do
      allow(DRC).to receive(:bput) do |command, *args|
        sent << command
        next 'Roundtime' unless command == 'study my instructions'

        study_options << (args.first.is_a?(Hash) ? args.shift : {})
        matchers = args.flatten.map { |m| m.is_a?(Regexp) ? m : /#{m}/i }
        lines = (study_replies.shift || []).dup
        found = nil
        while found.nil? && (line = lines.shift)
          matchers.each do |matcher|
            next unless (match = line.match(matcher))

            matched_lines << line
            found = match.to_a.first
            break
          end
        end
        found || ''
      end
      allow(DRC).to receive(:message)
      allow(DRCC).to receive(:stow_crafting_item)
      allow(tinker).to receive(:magic_cleanup)
      allow(tinker).to receive(:waitrt?)
    end

    it 'succeeds on each of the three endings of the study line, and on nothing earlier' do
      study_line_endings.each do |ending|
        study_replies.replace([study_reply(ending)])
        matched_lines.clear

        tinker.study_instructions

        expect(matched_lines).to eq(["You scan the crossbow instructions with a glance and #{ending}"])
      end
      expect(DRC).not_to have_received(:message)
      expect(DRCC).not_to have_received(:stow_crafting_item)
    end

    it 'waits out the study roundtime after the study line' do
      study_replies.replace([study_reply(study_line_endings.first)])

      tinker.study_instructions

      expect(tinker).to have_received(:waitrt?)
    end

    it 'waits 90 seconds for each study reply' do
      study_replies.replace([again_reply, study_reply(study_line_endings.first)])

      tinker.study_instructions

      expect(study_options).to eq([{ 'timeout' => 90 }, { 'timeout' => 90 }])
    end

    it 'studies again when asked, then succeeds' do
      study_replies.replace([again_reply, study_reply(study_line_endings[2])])

      tinker.study_instructions

      expect(sent).to eq(['study my instructions'] * 2)
      expect(matched_lines.last).to eq("You scan the crossbow instructions with a glance and #{study_line_endings[2]}")
    end

    it 'stops, putting the instructions away, when still asked to study again after three studies' do
      study_replies.replace([again_reply, again_reply, again_reply, study_reply(study_line_endings.first)])

      expect { tinker.study_instructions }.to raise_error(SystemExit)
      expect(sent).to eq(['study my instructions'] * 3)
      expect(DRC).to have_received(:message).with('***Still told to study the crossbow instructions again after 3 studies. Exiting.***')
      expect(DRCC).to have_received(:stow_crafting_item).with('crossbow instructions', 'backpack', nil)
      expect(tinker).to have_received(:magic_cleanup)
    end

    it 'stops, putting the instructions away, when the game says they are not in hand' do
      study_replies.replace([['You must be holding the instructions to study them.']])

      expect { tinker.study_instructions }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('***Not holding the crossbow instructions to study them. Exiting.***')
      expect(DRCC).to have_received(:stow_crafting_item).with('crossbow instructions', 'backpack', nil)
      expect(tinker).to have_received(:magic_cleanup)
    end

    it 'stops when there are no instructions to study' do
      study_replies.replace([['What were you referring to?']])

      expect { tinker.study_instructions }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('***Could not find the crossbow instructions to study. Exiting.***')
    end

    it 'stops, putting the instructions away, when the study gets no reply' do
      study_replies.replace([[]])

      expect { tinker.study_instructions }.to raise_error(SystemExit)
      expect(sent).to eq(['study my instructions'])
      expect(DRC).to have_received(:message).with('***No reply to studying the crossbow instructions. Exiting.***')
      expect(DRCC).to have_received(:stow_crafting_item).with('crossbow instructions', 'backpack', nil)
    end

    it 'skips a late Roundtime from an earlier command and succeeds on the study line after it' do
      study_replies.replace([['Roundtime: 8 sec.'] + study_reply(study_line_endings[1])])

      tinker.study_instructions

      expect(matched_lines).to eq(["You scan the crossbow instructions with a glance and #{study_line_endings[1]}"])
    end

    it 'stops when a late Roundtime is followed by the instructions not being in hand' do
      study_replies.replace([['Roundtime: 8 sec.', 'You must be holding the instructions to study them.']])

      expect { tinker.study_instructions }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('***Not holding the crossbow instructions to study them. Exiting.***')
    end

    it 'stops when a late Roundtime is the only reply (the study itself never answered)' do
      study_replies.replace([['Roundtime: 8 sec.']])

      expect { tinker.study_instructions }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('***No reply to studying the crossbow instructions. Exiting.***')
      expect(tinker).not_to have_received(:waitrt?)
    end

    it "does not take a player's speech of the study line as done" do
      study_replies.replace([['Mallory says, "You scan the crossbow instructions with a glance and completely understand all facets of the design."']])

      expect { tinker.study_instructions }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('***No reply to studying the crossbow instructions. Exiting.***')
    end

    it "does not take a player's speech of the again prompt as a request to study again" do
      study_replies.replace([['Mallory says, "[These instructions have only 5 uses remaining.  Study them again to proceed.]"'],
                             study_reply(study_line_endings.first)])

      expect { tinker.study_instructions }.to raise_error(SystemExit)
      expect(sent).to eq(['study my instructions'])
    end

    it 'sends no crafting command after a study that does not complete' do
      study_replies.replace([['You must be holding the instructions to study them.']])

      expect { start(instructions: 'instructions', material: 'maple', noun: 'crossbow') }.to raise_error(SystemExit)
      expect(sent).to eq(['study my instructions'])
      expect(DRCC).to have_received(:get_crafting_item).with('crossbow instructions', 'backpack', [], nil)
      expect(DRCC).not_to have_received(:get_crafting_item).with('drawknife', any_args)
      expect(DRCC).not_to have_received(:get_crafting_item).with('maple lumber', any_args)
      expect(@command).to be_nil
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
  # The crafting loop reads two flags: 'tinker-done' ends the craft (stamp,
  # stow, exit) and 'tinkering-assembly' names the part to assemble. Lich tests
  # every raw server line against every Flags matcher (DRParser.check_events);
  # `deliver` does the same with the matchers tinker registered. The line
  # arrives with the reply to the first crafting step.
  describe 'lines heard while crafting' do
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

    # Runs the shaping loop on a crossbow for up to three commands, delivering
    # `line` with the first reply. Returns the commands sent and whether the
    # script exited.
    def craft_hearing(line)
      tinker = start(recipe_name: 'laminate', noun: 'crossbow')
      allow(tinker).to receive(:work).and_call_original
      allow(tinker).to receive(:exit) { throw :tinker_exited }
      sent = []
      allow(DRC).to receive(:bput) do |command, *|
        throw :tinker_stopped if sent.size >= 3
        sent << command
        deliver(line) if sent.size == 1
        'Roundtime'
      end
      exited = true
      catch(:tinker_exited) do
        catch(:tinker_stopped) { tinker.work('shape my crossbow with my shaper') }
        exited = false
      end
      { sent: sent, exited: exited }
    end

    def player_shapes(text)
      [
        %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
        %(<preset id='speech'>Mallory says</preset>, "#{text}"),
        %(<preset id='speech'>Mallory whispers</preset>, "#{text}")
      ]
    end

    describe 'the finished-item line' do
      [
        'Applying the final touches, you complete working on a crossbow.',
        '<pushBold/>Applying the final touches, you complete working on a crossbow.',
        'You finish the crossbow, which benefits from the successful lamination process.'
      ].each do |line|
        it "finishes the item on #{line.inspect}" do
          run = craft_hearing(line)

          expect(run[:exited]).to be(true)
          expect(run[:sent]).to eq(['shape my crossbow with my shaper', 'lift'])
        end
      end

      [
        'Applying the final touches, you complete working on a crossbow.',
        'You finish the crossbow, which benefits from the successful lamination process.'
      ].each do |text|
        it "keeps crafting when another player's speech or ESP carries #{text.inspect}" do
          player_shapes(text).each do |line|
            run = craft_hearing(line)

            expect(run[:exited]).to be(false), line
            expect(run[:sent]).to eq(['shape my crossbow with my shaper'] * 3), line
          end
        end
      end
    end

    # The game logs on hand have no assembly lines, so these carry each
    # pattern's own text at the start of a plain game line.
    describe 'the assembly lines' do
      {
        'The crossbow appears ready to be reinforced with some backer material.'                => 'assemble my crossbow with my backer',
        'You need another bone, wood or horn backing material to continue crafting a crossbow.' => 'assemble my crossbow with my backer',
        'You need another finished bow string to continue crafting a crossbow.'                 => 'assemble my crossbow with my string',
        'You need another finished long wooden pole to continue crafting a crossbow.'           => 'assemble my crossbow with my long pole',
        'You need another finished short leather cord to continue crafting a crossbow.'         => 'assemble my crossbow with my cord',
        'You need another lenses to continue crafting a crossbow.'                              => 'assemble my crossbow with my lenses',
        'You need another finished mechanism to continue crafting a crossbow.'                  => 'assemble my mechanism with my crossbow',
        'You must assemble the strips to continue crafting a crossbow.'                         => 'assemble my crossbow with my strips',
        'You need another barbed boltheads to continue crafting a crossbow.'                    => 'assemble my crossbow with my barbed boltheads',
        'You need another bolt flights to continue crafting a crossbow.'                        => 'assemble my crossbow with my bolt flights'
      }.each do |text, assemble|
        it "runs '#{assemble}' on #{text.inspect}" do
          run = craft_hearing(text)

          expect(run[:sent]).to eq(['shape my crossbow with my shaper', assemble, 'shape my crossbow with my shaper'])
        end

        it "assembles nothing when another player's speech or ESP carries #{text.inspect}" do
          player_shapes(text).each do |line|
            run = craft_hearing(line)

            expect(run[:sent]).to eq(['shape my crossbow with my shaper'] * 3), line
          end
        end
      end

      # Messages anchored to the line start still match when the game puts
      # tags in front of them.
      {
        '<pushBold/>You need another bone, wood or horn backing material to continue crafting a crossbow.' => 'assemble my crossbow with my backer',
        '<pushBold/>You must assemble the strips to continue crafting a crossbow.'                         => 'assemble my crossbow with my strips',
        '<pushBold/>You need another barbed boltheads to continue crafting a crossbow.'                    => 'assemble my crossbow with my barbed boltheads',
        '<pushBold/>You need another bolt flights to continue crafting a crossbow.'                        => 'assemble my crossbow with my bolt flights'
      }.each do |line, assemble|
        it "runs '#{assemble}' on #{line.inspect}" do
          run = craft_hearing(line)

          expect(run[:sent]).to eq(['shape my crossbow with my shaper', assemble, 'shape my crossbow with my shaper'])
        end
      end
    end
  end
end
