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
        it "assembles the #{part} on the game's line: #{line}" do
          crafter
          deliver(line)

          expect(assembly_commands).to eq(["assemble my bow with my #{part}"])
          expect(DRCC).to have_received(:get_crafting_item).with(part, nil, nil, nil)
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
