# frozen_string_literal: true

require 'ostruct'

# arenawatch.lic runs `mainloop` at load, so only its top-level defs are
# extracted (load_lic_methods); the trailing `mainloop` call never runs.
RSpec.describe 'arenawatch' do
  let(:arenawatch) { load_lic_methods('arenawatch.lic', 'arena_target', 'mainloop') }
  let(:ignore_npcs) { %w[Usdiwi Servant Traumatologist Usdiwi] }

  def creature(id, noun, name: "a #{noun}", dead: false)
    OpenStruct.new(id: id, noun: noun, name: name, dead: dead)
  end

  def seed_room(*creatures)
    Lich::DragonRealms::Creature._set_room(creatures)
  end

  describe '#arena_target' do
    it 'addresses the opponent by id, skipping ignored arena NPCs listed ahead of it' do
      seed_room(creature(1, 'Servant'), creature(2, 'Traumatologist'), creature(3, 'Usdiwi'), creature(4, 'leucro'))
      DRRoom.npcs = %w[Servant Traumatologist Usdiwi leucro]

      expect(arenawatch.arena_target(ignore_npcs)).to eq('#4')
    end

    it 'asks the roster for live creatures only' do
      seed_room(creature(4, 'leucro'))

      arenawatch.arena_target(ignore_npcs)

      expect(Lich::DragonRealms::Creature._in_room_filters).to eq([[:not_dead]])
    end

    it 'ignores arena NPC nouns case-insensitively' do
      seed_room(creature(1, 'servant'), creature(2, 'USDIWI'), creature(3, 'traumatologist'), creature(4, 'leucro'))

      expect(arenawatch.arena_target(ignore_npcs)).to eq('#4')
    end

    it 'picks the first of several same-noun opponents by its own id' do
      seed_room(creature(1, 'Usdiwi'), creature(7, 'rat'), creature(8, 'rat'))
      DRRoom.npcs = %w[Usdiwi rat rat]

      expect(arenawatch.arena_target(ignore_npcs)).to eq('#7')
    end

    it 'never targets a dead same-noun creature (the live filter excludes it)' do
      dead_rat = creature(5, 'rat', dead: true)
      live_rat = creature(6, 'rat')
      allow(Lich::DragonRealms::Creature).to receive(:in_room).with(no_args).and_return([dead_rat, live_rat])
      allow(Lich::DragonRealms::Creature).to receive(:in_room).with(:not_dead).and_return([live_rat])

      expect(arenawatch.arena_target(ignore_npcs)).to eq('#6')
    end

    it 'still uses the id when the creature has no name yet' do
      seed_room(creature(9, 'leucro', name: nil))

      expect(arenawatch.arena_target(ignore_npcs)).to eq('#9')
    end

    it 'never picks a creature with no noun yet, which could be an ignored NPC' do
      seed_room(creature(9, nil, name: nil))
      DRRoom.npcs = %w[Servant]

      expect(arenawatch.arena_target(ignore_npcs)).to be_nil
    end

    it 'picks a named opponent past a creature with no noun yet' do
      seed_room(creature(9, nil, name: nil), creature(10, 'leucro'))

      expect(arenawatch.arena_target(ignore_npcs)).to eq('#10')
    end

    it 'skips a creature without an id in favour of a later one that has one' do
      seed_room(creature(nil, 'leucro'), creature(12, 'rat'))

      expect(arenawatch.arena_target(ignore_npcs)).to eq('#12')
    end

    it 'falls back to the first non-ignored noun when no creature carries an id' do
      seed_room(creature(nil, 'leucro'))
      DRRoom.npcs = %w[Servant Usdiwi leucro]

      expect(arenawatch.arena_target(ignore_npcs)).to eq('leucro')
    end

    it 'falls back to the first non-ignored noun when the roster is empty, ignoring case' do
      DRRoom.npcs = %w[servant usdiwi rat rat]

      expect(arenawatch.arena_target(ignore_npcs)).to eq('rat')
    end

    it 'returns nil when only ignored arena NPCs are present' do
      seed_room(creature(1, 'Usdiwi'), creature(2, 'Servant'))
      DRRoom.npcs = %w[Servant Usdiwi]

      expect(arenawatch.arena_target(ignore_npcs)).to be_nil
    end

    it 'returns nil for an empty room' do
      expect(arenawatch.arena_target(ignore_npcs)).to be_nil
    end
  end

  describe '#mainloop' do
    let(:sent) { [] }
    let(:watch_patterns) { [] }

    # The text before the advice is a stand-in; the advice wordings are the
    # ones the Genie arena triggers on Elanthipedia ("Genie quest triggers")
    # answer with a dodge.
    def advice(tail)
      "You notice the serpent may push you into a jet of steam, you could try to #{tail}"
    end

    # Reads `lines` against the script's own bput patterns the way lich-5
    # DRC.bput does: line by line, patterns in order (a String as /x/i), and
    # returns the matched text of the first hit, or '' when nothing matches.
    def bput_reply(lines, matches)
      patterns = matches.flatten.map { |m| m.is_a?(Regexp) ? m : /#{m}/i }
      lines.each do |line|
        patterns.each do |pattern|
          match = line.match(pattern)
          return match.to_a.first if match
        end
      end
      ''
    end

    # DRRoom.npcs reads `before` on the first call (the loop's baseline) and
    # `after` from then on, so the loop sees the room change once. `pause` at
    # the bottom of the loop raises StopIteration, which ends `loop do`.
    # The first WATCH of the opponent reads `watch_lines`; a later one reads
    # the game's re-watch reply. A WATCH of anything else reads 'Watch out
    # for whom'.
    def run_mainloop(before:, after:, watch_lines: [advice('duck down!')])
      %w[ARENA_WATCH_DODGE ARENA_WATCH_DONE ARENA_WATCH_OTHER].each { |c| load_lic_constant('arenawatch.lic', c) }
      calls = 0
      allow(DRRoom).to receive(:npcs) do
        calls += 1
        calls == 1 ? before : after
      end
      allow(DRC).to receive(:bput) do |command, *matches|
        sent << command
        raise 'watched too often' if sent.size > 6

        if command.start_with?('watch ')
          watch_patterns.replace(matches)
          lines = if !command.start_with?('watch #4', 'watch leucro')
                    ['Watch out for whom?']
                  elsif sent.count { |c| c.start_with?('watch ') } == 1
                    watch_lines
                  else
                    ["You've already spotted the serpent's intentions."]
                  end
          bput_reply(lines, matches)
        else
          "You set yourself up to #{command}"
        end
      end
      allow(arenawatch).to receive(:pause).and_raise(StopIteration)
      allow(arenawatch).to receive(:pause_script)
      allow(arenawatch).to receive(:unpause_script)

      arenawatch.mainloop
    end

    it 'watches the opponent by id rather than the ignored NPC that sorts first' do
      seed_room(creature(1, 'Servant'), creature(3, 'Usdiwi'), creature(4, 'leucro'))

      run_mainloop(before: %w[Servant Usdiwi], after: %w[Servant Usdiwi leucro])

      expect(sent).to eq(['watch #4', 'duck'])
      expect(arenawatch).to have_received(:pause_script).with('combat-trainer')
      expect(arenawatch).to have_received(:unpause_script).with('combat-trainer')
    end

    it 'watches the plain noun when no creature id is available' do
      run_mainloop(before: %w[Servant Usdiwi], after: %w[Servant Usdiwi leucro], watch_lines: [advice('jump over it!')])

      expect(sent).to eq(['watch leucro', 'jump'])
    end

    it 'sends no watch and resumes combat-trainer when only ignored NPCs remain' do
      seed_room(creature(1, 'Servant'), creature(3, 'Usdiwi'))

      run_mainloop(before: %w[Servant Usdiwi leucro], after: %w[Servant Usdiwi])

      expect(sent).to be_empty
      expect(arenawatch).to have_received(:unpause_script).with('combat-trainer')
    end

    describe 'reading the WATCH reply' do
      before { seed_room(creature(4, 'leucro')) }

      def watch_with(*lines)
        run_mainloop(before: [], after: %w[leucro], watch_lines: lines)
      end

      {
        'pedal back out of the way!' => 'pedal', 'back pedal out of the way!' => 'pedal',
        'jump over it!' => 'jump', 'prepare to jump!' => 'jump',
        'bob back and forth!' => 'bob', 'cower into a smaller target!' => 'cower',
        'cower out of the way!' => 'cower', 'duck down!' => 'duck', 'lean out of the way!' => 'lean'
      }.each do |tail, verb|
        it "sends #{verb} for the advice '...you could try to #{tail}'" do
          watch_with(advice(tail))

          expect(sent).to eq(['watch #4', verb])
          expect(arenawatch).to have_received(:unpause_script).with('combat-trainer')
        end
      end

      {
        'say'     => 'Mallory says, "anyone up for a hunt?"',
        'ESP'     => '[General][Mallory] "back in a bit"',
        'whisper' => 'Mallory whispers, "nice hat"'
      }.each do |shape, line|
        it "still takes the real advice when another player's #{shape} arrives first" do
          watch_with(line, advice('duck down!'))

          expect(sent).to eq(['watch #4', 'duck'])
        end
      end

      it "never takes a dodge from another player's line that repeats the advice" do
        watch_with('Mallory says, "you could try to lean on him"', '[General][Mallory] "you could try to cower"', advice('duck down!'))

        expect(sent).to eq(['watch #4', 'duck'])
      end

      it "never ends the watch on another player's line that repeats a no-dodge reply" do
        watch_with(%(Mallory whispers, "You've already spotted the troll's intentions"), %([General][Mallory] "Watch out for whom"), advice('lean out of the way!'))

        expect(sent).to eq(['watch #4', 'lean'])
      end

      it "ends the watch with no dodge on the game's re-watch reply" do
        watch_with("You've already spotted the serpent's intentions.")

        expect(sent).to eq(['watch #4'])
        expect(arenawatch).to have_received(:unpause_script).with('combat-trainer')
      end

      it 'still ends the bput at once on any other game line, then watches again' do
        watch_with('The serpent hisses.', advice('duck down!'))

        expect(sent).to eq(['watch #4', 'watch #4'])
      end

      it 'passes WATCH patterns that skip player speech and ESP but still catch game lines' do
        watch_with(advice('duck down!'))
        player = ['Mallory says, "you could try to duck"', '[General][Mallory] "you could try to duck"',
                  'Mallory whispers, "Watch out for whom"', 'Mallory asks, "may not be the best use of your time?"',
                  'Mallory exclaims, "zzz"', 'Mallory yells, "zzz"']

        expect(player.map { |line| bput_reply([line], watch_patterns) }).to all(eq(''))
        expect(bput_reply(['The serpent hisses.'], watch_patterns)).not_to be_empty
        expect(bput_reply([advice('cower out of the way!')], watch_patterns)).to eq('cower')
      end
    end
  end
end
