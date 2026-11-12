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
      next 'You scan the bow instructions with a glance and completely understand all facets of the design.' if command == 'study my instructions'

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

    def study_reply(ending)
      ["You scan the bow instructions with a glance and #{ending}",
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
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRCC).to receive(:stow_crafting_item)
      allow(shape).to receive(:magic_cleanup)
      allow(shape).to receive(:waitrt?)
    end

    it 'succeeds on each of the three endings of the study line, and on nothing earlier' do
      study_line_endings.each do |ending|
        study_replies.replace([study_reply(ending)])
        matched_lines.clear

        shape.study_instructions

        expect(matched_lines).to eq(["You scan the bow instructions with a glance and #{ending}"])
      end
      expect(DRC).not_to have_received(:message)
      expect(DRCC).not_to have_received(:stow_crafting_item)
    end

    it 'succeeds on the shaping study line from a game log' do
      study_replies.replace([['You scan the haircomb instructions with a glance and completely understand all facets of the design.']])

      expect { shape.study_instructions }.not_to raise_error
      expect(shape).to have_received(:waitrt?)
    end

    it 'waits 90 seconds for each study reply' do
      study_replies.replace([again_reply, study_reply(study_line_endings.first)])

      shape.study_instructions

      expect(study_options).to eq([{ 'timeout' => 90 }, { 'timeout' => 90 }])
    end

    it 'studies again when asked, then succeeds' do
      study_replies.replace([again_reply, study_reply(study_line_endings[2])])

      shape.study_instructions

      expect(sent).to eq(['study my instructions'] * 2)
      expect(matched_lines.last).to eq("You scan the bow instructions with a glance and #{study_line_endings[2]}")
    end

    it 'stops, putting the instructions away, when still asked to study again after three studies' do
      study_replies.replace([again_reply, again_reply, again_reply, study_reply(study_line_endings.first)])

      expect { shape.study_instructions }.to raise_error(SystemExit)
      expect(sent).to eq(['study my instructions'] * 3)
      expect(DRC).to have_received(:message).with('***Still told to study the bow instructions again after 3 studies. Exiting.***')
      expect(DRCC).to have_received(:stow_crafting_item).with('bow instructions', 'backpack', nil)
      expect(shape).to have_received(:magic_cleanup)
    end

    it 'stops, putting the instructions away, when the game says they are not in hand' do
      study_replies.replace([['You must be holding the instructions to study them.']])

      expect { shape.study_instructions }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('***Not holding the bow instructions to study them. Exiting.***')
      expect(DRCC).to have_received(:stow_crafting_item).with('bow instructions', 'backpack', nil)
      expect(shape).to have_received(:magic_cleanup)
    end

    it 'stops when there are no instructions to study' do
      study_replies.replace([['What were you referring to?']])

      expect { shape.study_instructions }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('***Could not find the bow instructions to study. Exiting.***')
    end

    it 'stops, putting the instructions away, when the study gets no reply' do
      study_replies.replace([[]])

      expect { shape.study_instructions }.to raise_error(SystemExit)
      expect(sent).to eq(['study my instructions'])
      expect(DRC).to have_received(:message).with('***No reply to studying the bow instructions. Exiting.***')
      expect(DRCC).to have_received(:stow_crafting_item).with('bow instructions', 'backpack', nil)
    end

    it 'skips a late Roundtime from an earlier command and succeeds on the study line after it' do
      study_replies.replace([['Roundtime: 8 sec.'] + study_reply(study_line_endings[1])])

      shape.study_instructions

      expect(matched_lines).to eq(["You scan the bow instructions with a glance and #{study_line_endings[1]}"])
    end

    it 'stops when a late Roundtime is followed by the instructions not being in hand' do
      study_replies.replace([['Roundtime: 8 sec.', 'You must be holding the instructions to study them.']])

      expect { shape.study_instructions }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('***Not holding the bow instructions to study them. Exiting.***')
    end

    it 'stops when a late Roundtime is the only reply (the study itself never answered)' do
      study_replies.replace([['Roundtime: 8 sec.']])

      expect { shape.study_instructions }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('***No reply to studying the bow instructions. Exiting.***')
      expect(shape).not_to have_received(:waitrt?)
    end

    it "does not take a player's speech of the study line as done" do
      study_replies.replace([['Mallory says, "You scan the bow instructions with a glance and completely understand all facets of the design."']])

      expect { shape.study_instructions }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('***No reply to studying the bow instructions. Exiting.***')
    end

    it "does not take a player's speech of the again prompt as a request to study again" do
      study_replies.replace([['Mallory says, "[These instructions have only 5 uses remaining.  Study them again to proceed.]"'],
                             study_reply(study_line_endings.first)])

      expect { shape.study_instructions }.to raise_error(SystemExit)
      expect(sent).to eq(['study my instructions'])
    end

    it 'sends no crafting command after a study that does not complete' do
      study_replies.replace([['You must be holding the instructions to study them.']])

      expect { shape.prep }.to raise_error(SystemExit)
      expect(sent).to eq(['study my instructions'])
      expect(DRCC).to have_received(:get_crafting_item).with('bow instructions', 'backpack', [], nil)
      expect(DRCC).not_to have_received(:get_crafting_item).with('drawknife', any_args)
      expect(DRCC).not_to have_received(:get_crafting_item).with('maple lumber', any_args)
    end
  end

  describe 'crafting message flags' do
    # Runs the real initialize, which registers the Flags, without starting
    # the craft.
    let(:crafter) do
      $test_settings = OpenStruct.new(hometown: 'Crossing', crafting_training_spells: [])
      $test_data = OpenStruct.new(crafting: { 'shaping' => { 'Crossing' => {} } })
      $parsed_args = OpenStruct.new(finish: 'trash', recipe_name: +'longbow', material: 'maple', noun: 'bow')
      instance = Shape.allocate
      allow(instance).to receive(:prep).and_return('shape my bow with my shaper')
      allow(instance).to receive(:work)
      instance.send(:initialize)
      instance
    end

    # Feed a server line through the registered Flags matchers, the way
    # Lich's DRParser.check_events does for every downstream line.
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

    # Other players' text, in the raw forms the Flags see.
    def player_lines(text)
      [
        %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
        %([General][Mallory] "#{text}"),
        %(<preset id='speech'>Mallory says</preset>, "#{text}"),
        %(Mallory says, "#{text}"),
        %(Mallory whispers, "#{text}")
      ]
    end

    # Runs the craft loop with every step answering Roundtime; `line` arrives
    # with the first step's output. Returns the commands sent and :exited
    # (finish ran) or :carried_on (a second craft step was sent).
    def run_craft(line)
      sent = []
      allow(DRC).to receive(:bput) do |command, *|
        sent << command
        # Not StopIteration: Kernel#loop would swallow it.
        raise 'craft carried on' if sent.count { |c| c.start_with?('shape my') } > 1

        deliver(line) if sent.size == 1
        'Roundtime'
      end
      allow(DRC).to receive(:right_hand).and_return('shaper')
      allow(DRC).to receive(:right_hand_noun).and_return('shaper')
      allow(DRCI).to receive(:dispose_trash)
      allow(crafter).to receive(:work).and_call_original
      outcome = begin
        crafter.work('shape my bow with my shaper')
      rescue SystemExit
        :exited
      rescue RuntimeError => e
        raise unless e.message == 'craft carried on'

        :carried_on
      end
      [sent, outcome]
    end

    describe "'shaping-done'" do
      real_done = [
        'Applying the final touches, you complete working on a maple longbow.',
        'The longbow shows signs of a new strength from the successful lamination process.'
      ]

      real_done.each do |line|
        it "finishes the craft on the game's line: #{line}" do
          sent, outcome = run_craft(line)

          expect(outcome).to eq(:exited)
          expect(DRCI).to have_received(:dispose_trash).with('bow', nil, nil)
          expect(sent).to eq(['shape my bow with my shaper', 'stow feet'])
        end
      end

      ['Applying the final touches, you complete working on a maple longbow.',
       'from the successful cable-backing process'].each do |text|
        it "keeps crafting, and does not trash the item, when another player sends: #{text}" do
          player_lines(text).each do |line|
            Flags.reset('shaping-done')
            sent, outcome = run_craft(line)

            expect(Flags['shaping-done']).to be(false), line
            expect(outcome).to eq(:carried_on), line
            expect(sent).to eq(['shape my bow with my shaper'] * 2), line
          end
          expect(DRCI).not_to have_received(:dispose_trash)
        end
      end
    end

    describe "'shaping-assembly'" do
      # The part each game line asks for, as assemble_part gets and assembles it.
      real_parts = {
        'The longbow appears ready to be reinforced with some backer.'                                => 'backer',
        'The longbow appears ready to be strengthened with some leather strips.'                      => 'strips',
        'Glue should now be applied to the longbow and assembly with the backing material can begin.' => 'backer',
        'You need another bone, wood or horn backing material to continue crafting.'                  => 'backer',
        'You need another finished bow string to continue crafting.'                                  => 'string',
        'You need another finished long wooden pole to continue crafting.'                            => 'long pole',
        'You need another finished short wooden pole to continue crafting.'                           => 'short pole',
        'You need another finished leather strips to continue crafting.'                              => 'leather strips',
        'You need another finished short leather cord to continue crafting.'                          => 'short cord',
        'You must assemble the backer before you can continue.'                                       => 'backer',
        'You must assemble the strips before you can continue.'                                       => 'strips',
        'You need another arrow flights to continue crafting.'                                        => 'arrow flights',
        'You need another bronze arrowheads to continue crafting.'                                    => 'bronze arrowheads'
      }

      def assembly_commands
        commands = []
        allow(DRC).to receive(:right_hand).and_return('shaper')
        allow(DRC).to receive(:right_hand_noun).and_return('shaper')
        allow(DRCC).to receive(:get_crafting_item)
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRC).to receive(:bput) { |command, *| commands << command && 'affix it securely in place' }
        crafter.assemble_part
        commands
      end

      real_parts.each do |line, part|
        # Tables take four legs (base-recipes: four long or short poles), and
        # the game asks for the first one only.
        times = part.end_with?(' pole') ? 4 : 1

        it "assembles the #{part} #{times}x on the game's line: #{line}" do
          crafter
          deliver(line)

          expect(assembly_commands).to eq(["assemble my bow with my #{part}"] * times)
          expect(DRCC).to have_received(:get_crafting_item).with(part, nil, nil, nil).exactly(times).times
        end
      end

      real_parts.each_key do |text|
        it "does not assemble when another player sends: #{text}" do
          crafter
          player_lines(text).each do |line|
            deliver(line)

            expect(Flags['shaping-assembly']).to be(false), line
          end
          expect(assembly_commands).to be_empty
          expect(DRCC).not_to have_received(:get_crafting_item)
        end
      end
    end
  end
end
