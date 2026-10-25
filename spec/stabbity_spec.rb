# frozen_string_literal: true

require 'ostruct'

load_lic_class('stabbity.lic', 'Stabbity')

RSpec.describe Stabbity do
  let(:creature_registry) { Lich::DragonRealms::Creature }

  # A roster creature: the harness CreatureInstance, whose matches? follows
  # lich-5's rule.
  def creature(id:, noun:, name:, dead: false)
    Lich::DragonRealms::CreatureInstance.new(id, noun, name, dead: dead)
  end

  # Seeds the roster: in_room(:not_dead) answers the live creatures, in_room
  # with no filter answers everything present (the harness ignores filters).
  def seed_roster(live:, dead: [])
    allow(creature_registry).to receive(:in_room).with(:not_dead).and_return(live)
    allow(creature_registry).to receive(:in_room).with(no_args).and_return(live + dead)
  end

  # A Lich release without lich-5#1817: no DRRoom.unignored_npcs.
  def without_unignored_npcs
    allow(DRRoom).to receive(:respond_to?).and_call_original
    allow(DRRoom).to receive(:respond_to?).with(:unignored_npcs).and_return(false)
    allow(DRRoom).to receive(:unignored_npcs).and_raise(NoMethodError)
  end

  # A roster creature from a Lich release without CreatureInstance#matches?;
  # a Struct, unlike an OpenStruct, raises NoMethodError on it.
  let(:pre_matches_creature) { Struct.new(:id, :noun, :name) }

  def build(mode: nil, ignored: [])
    s = Stabbity.allocate
    s.instance_variable_set(:@mode, mode)
    s.instance_variable_set(:@ignored_npcs, ignored)
    s.instance_variable_set(:@debug, false)
    s.instance_variable_set(:@noloot, true)
    s.instance_variable_set(:@alternate_weapon_npcs, [])
    s.instance_variable_set(:@thrown_weapon_npcs, [])
    s.instance_variable_set(:@khri_eliminate, false)
    s
  end

  # Runs one pass of combat_loop: check_wands closes every pass, and loop ends
  # cleanly on StopIteration. Returns every command sent via bput or fput.
  def run_one_pass(stabbity)
    commands = []
    allow(DRC).to receive(:bput) do |cmd, *_rest|
      commands << cmd
      'Roundtime'
    end
    allow(stabbity).to receive(:fput) { |cmd| commands << cmd }
    allow(stabbity).to receive(:switch_weapon)
    allow(stabbity).to receive(:kill_stabbity)
    allow(stabbity).to receive(:kill_thrown)
    allow(stabbity).to receive(:use_weapon)
    allow(stabbity).to receive(:check_buffs)
    allow(stabbity).to receive(:check_wands).and_raise(StopIteration)
    stabbity.combat_loop
    commands
  end

  describe '#get_npcs' do
    it 'drops a creature ignored by its full name, keeping its same-noun neighbour' do
      DRRoom.npcs = %w[moradu moradu]
      allow(DRRoom).to receive(:unignored_npcs).with(['jeol moradu']).and_return(['moradu'])

      expect(build(ignored: ['jeol moradu']).get_npcs).to eq(['moradu'])
    end

    it 'keeps duplicates of an unignored noun' do
      DRRoom.npcs = %w[goblin moradu moradu]

      expect(build(ignored: ['goblin']).get_npcs).to eq(%w[moradu moradu])
    end

    it 'tolerates a nil ignore list' do
      DRRoom.npcs = ['moradu']

      expect(build(ignored: nil).get_npcs).to eq(['moradu'])
    end

    it 'returns every NPC, ignored or not, in the arena' do
      DRRoom.npcs = %w[goblin moradu]

      expect(build(mode: 'arena', ignored: ['goblin']).get_npcs).to eq(%w[goblin moradu])
    end

    it 'returns an empty list for an empty room' do
      DRRoom.npcs = []

      expect(build(ignored: ['goblin']).get_npcs).to eq([])
    end

    context 'on a Lich without DRRoom.unignored_npcs' do
      before { without_unignored_npcs }

      it 'drops ignored nouns only' do
        DRRoom.npcs = %w[goblin moradu moradu]

        expect(build(ignored: ['goblin']).get_npcs).to eq(%w[moradu moradu])
      end

      it 'leaves a full-name entry without effect, as before' do
        DRRoom.npcs = %w[moradu moradu]

        expect(build(ignored: ['jeol moradu']).get_npcs).to eq(%w[moradu moradu])
      end

      it 'tolerates a nil ignore list' do
        DRRoom.npcs = ['moradu']

        expect(build(ignored: nil).get_npcs).to eq(['moradu'])
      end
    end
  end

  describe 'choosing and addressing the target' do
    it 'advances on the unignored creature by id when its same-noun neighbour is ignored by name' do
      DRRoom.npcs = %w[moradu moradu]
      allow(DRRoom).to receive(:unignored_npcs).with(['jeol moradu']).and_return(['moradu'])
      seed_roster(live: [creature(id: 11, noun: 'moradu', name: 'a jeol moradu'),
                         creature(id: 12, noun: 'moradu', name: 'a lean moradu')])

      expect(run_one_pass(build(ignored: ['jeol moradu']))).to include('advance #12')
    end

    it 'skips a dead same-noun creature when picking the id' do
      DRRoom.npcs = ['moradu']
      DRRoom.dead_npcs = ['moradu']
      seed_roster(live: [creature(id: 22, noun: 'moradu', name: 'a lean moradu')],
                  dead: [creature(id: 21, noun: 'moradu', name: 'a jeol moradu', dead: true)])

      stabbity = build
      expect(run_one_pass(stabbity)).to include('advance #22')
      expect(stabbity.instance_variable_get(:@target)).to eq('moradu')
    end

    it 'asks the roster for living creatures only' do
      DRRoom.npcs = ['moradu']
      creature_registry._set_room([creature(id: 7, noun: 'moradu', name: 'a moradu')])

      run_one_pass(build)

      expect(creature_registry._in_room_filters).to include([:not_dead])
    end

    it 'does not pick a creature of another noun' do
      DRRoom.npcs = %w[goblin moradu]
      seed_roster(live: [creature(id: 30, noun: 'moradu', name: 'a moradu'),
                         creature(id: 31, noun: 'goblin', name: 'a goblin')])

      expect(run_one_pass(build)).to include('advance #31')
    end

    it 'falls back to the noun when the roster is empty (legacy stream)' do
      DRRoom.npcs = ['moradu']
      seed_roster(live: [])

      commands = run_one_pass(build)

      expect(commands).to include('advance moradu')
      expect(commands.grep(/#/)).to be_empty
    end

    it 'falls back to the noun when the matching creature has no id' do
      DRRoom.npcs = ['moradu']
      seed_roster(live: [creature(id: nil, noun: 'moradu', name: 'a moradu')])

      expect(run_one_pass(build)).to include('advance moradu')
    end

    # lich-5 registers a creature seen only in <crtrStatus> with no name and
    # no noun (Creature.sync -> register(nil, id)).
    it 'falls back to the noun when the only creature has an id but no name or noun yet' do
      DRRoom.npcs = ['moradu']
      seed_roster(live: [Lich::DragonRealms::CreatureInstance.new(40, nil, nil, noun_from_server: false)])

      expect(run_one_pass(build)).to include('advance moradu')
    end

    it 'advances by noun on a Lich without DRRoom.unignored_npcs or CreatureInstance#matches?' do
      without_unignored_npcs
      DRRoom.npcs = %w[goblin moradu]
      seed_roster(live: [pre_matches_creature.new(80, 'moradu', 'a moradu')])

      commands = run_one_pass(build(ignored: ['goblin']))

      expect(commands).to include('advance moradu')
      expect(commands.grep(/#/)).to be_empty
    end

    it 'falls back to the noun when the only same-noun creature is ignored by name' do
      DRRoom.npcs = ['moradu']
      allow(DRRoom).to receive(:unignored_npcs).and_return(['moradu'])
      seed_roster(live: [creature(id: 50, noun: 'moradu', name: 'a jeol moradu')])

      expect(run_one_pass(build(ignored: ['jeol moradu']))).to include('advance moradu')
    end

    it 'watches and advances on the creature by id in the arena, ignore list or not' do
      DRRoom.npcs = ['moradu']
      seed_roster(live: [creature(id: 60, noun: 'moradu', name: 'a jeol moradu')])

      commands = run_one_pass(build(mode: 'arena', ignored: ['jeol moradu']))

      expect(commands).to include('watch #60', 'advance #60')
    end

    it 'keys the use_thrown_on list by noun, not id' do
      DRRoom.npcs = ['moradu']
      seed_roster(live: [creature(id: 70, noun: 'moradu', name: 'a moradu')])
      stabbity = build
      stabbity.instance_variable_set(:@thrown_weapon_npcs, ['moradu'])

      run_one_pass(stabbity)

      expect(stabbity).to have_received(:kill_thrown)
      expect(stabbity).not_to have_received(:kill_stabbity)
    end
  end

  describe 'arena game-line matchers' do
    let(:real_watch) do
      'You appraise the situation and notice the piruati serpent may push you into a jet of scalding-hot steam, ' \
        'you could try to pedal back out of the way!'
    end
    let(:real_round) do
      %(An iron portcullis is raised, heralding the arrival of a piruati serpent!  ) +
        %(The announcers calls out, "And here's our next foe!  Round 5, FIGHT!")
    end

    # Player-written lines as Flags (raw XML) and bput (stripped) see them.
    def player_shapes(text)
      [%([General][Mallory] "#{text}"), %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
       %(Mallory says, "#{text}"), %(<preset id='speech'>Mallory says</preset>, "#{text}"),
       %(Mallory whispers, "#{text}")]
    end

    # The reply DRC.bput returns, as lich-5 matches it: Strings become /x/i,
    # and the first line (in arrival order) that hits any pattern returns
    # match[0]; nothing matching returns ''.
    def lich_bput_reply(lines, patterns)
      regexes = patterns.flatten.map { |p| p.is_a?(Regexp) ? p : /#{p}/i }
      lines.each do |line|
        regexes.each do |r|
          m = line.match(r)
          return m.to_a.first if m
        end
      end
      ''
    end

    # Runs watch_target then dodge_arena_trap with `lines` arriving after the
    # WATCH; returns the commands sent after the WATCH.
    def dodge_after_watch(lines)
      stabbity = build(mode: 'arena')
      allow(stabbity).to receive(:target_ref).and_return('#60')
      sent = []
      allow(DRC).to receive(:bput) do |cmd, *patterns|
        sent << cmd
        cmd.start_with?('watch ') ? lich_bput_reply(lines, patterns) : 'You set yourself up to'
      end
      stabbity.watch_target
      stabbity.dodge_arena_trap
      sent - ['watch #60']
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

    # Runs the script's own setup in arena mode with eliminate on, so the
    # khri-eliminate flag is registered exactly as the script does it.
    def start_arena_with_eliminate
      DRStats.guild = 'Thief'
      $parsed_args = { mode: 'arena' }
      $test_settings = OpenStruct.new(stabbity: { 'weapons'   => { 'preferred' => 'dagger', 'alternate' => '', 'thrown' => '' },
                                                  'eliminate' => true },
                                      ignored_npcs: [])
      stabbity = Stabbity.allocate
      allow(stabbity).to receive(:use_weapon)
      allow(stabbity).to receive(:check_buffs)
      allow(stabbity).to receive(:check_wands)
      allow(stabbity).to receive(:combat_loop)
      allow(DRC).to receive(:hide?)
      stabbity.send(:initialize)
      stabbity
    end

    it 'dodges with the verb from the real WATCH reply' do
      expect(dodge_after_watch([real_watch])).to eq(['pedal'])
    end

    it 'reads the dodge verb from the other WATCH reply wordings' do
      {
        'you could try to back pedal out of the way!'   => 'pedal',
        'you could try to prepare to jump!'             => 'jump',
        'you could try to bob back and forth!'          => 'bob',
        'you could try to cower into a smaller target!' => 'cower',
        'you could try to duck down!'                   => 'duck',
        'you could try to lean out of the way!'         => 'lean'
      }.each do |tail, verb|
        line = "You appraise the situation and notice the transmogrified oaf may drive you into a spiked pit, #{tail}"
        expect(dodge_after_watch([line])).to eq([verb]), "for #{tail}"
      end
    end

    it 'ignores player speech, ESP and whispers that arrive before the WATCH reply' do
      ["I'm cleaning out my pack", 'anyone want to duck out for food', 'you could try to jump over it!'].each do |text|
        player_shapes(text).values_at(0, 2, 4).each do |line|
          expect(dodge_after_watch([line, real_watch])).to eq(['pedal']), "for #{line}"
        end
      end
    end

    it 'ignores a dodge word inside another word on a room line' do
      expect(dodge_after_watch(['Mallory just arrived, bobbing her head.', real_watch])).to eq(['pedal'])
    end

    it 'sends khri eliminate after the real fifth-round announcement' do
      DRRoom.npcs = ['serpent']
      seed_roster(live: [creature(id: 60, noun: 'serpent', name: 'a piruati serpent')])
      stabbity = start_arena_with_eliminate
      allow(stabbity).to receive(:combat_loop).and_call_original
      deliver(real_round)

      expect(run_one_pass(stabbity)).to include('advance #60', 'khri eliminate')
    end

    it 'does not send khri eliminate when only another player repeated the call' do
      DRRoom.npcs = ['serpent']
      seed_roster(live: [creature(id: 60, noun: 'serpent', name: 'a piruati serpent')])
      stabbity = start_arena_with_eliminate
      allow(stabbity).to receive(:combat_loop).and_call_original
      player_shapes('Round 5, FIGHT!').each { |line| deliver(line) }

      commands = run_one_pass(stabbity)
      expect(commands).to include('advance #60')
      expect(commands).not_to include('khri eliminate')
    end

    it 'still hears the announcement with the call wrapped in a speech preset' do
      start_arena_with_eliminate
      deliver(%(<preset id='speech'>The announcers calls out</preset>, "And here's our next foe!  Round 25, FIGHT!"))
      expect(Flags['khri-eliminate']).to be_truthy
    end

    it 'does not fire on a non-fifth round' do
      start_arena_with_eliminate
      deliver(real_round.sub('Round 5,', 'Round 4,'))
      expect(Flags['khri-eliminate']).to be_falsey
    end

    it 'does not fire on another player repeating the call' do
      start_arena_with_eliminate
      ['Round 10, FIGHT!', %(The announcers calls out, "And here's our next foe!  Round 10, FIGHT!")].each do |text|
        player_shapes(text).each { |line| deliver(line) }
      end
      expect(Flags['khri-eliminate']).to be_falsey
    end
  end

  describe '#npc_dead?' do
    def target(stabbity, noun, id)
      stabbity.instance_variable_set(:@target, noun)
      stabbity.instance_variable_set(:@target_id, id)
      stabbity.instance_variable_set(:@npc_is_alive, true)
      stabbity
    end

    it 'is false for a live target while a same-noun corpse lies in the room' do
      DRRoom.npcs = ['moradu']
      DRRoom.dead_npcs = ['moradu']
      seed_roster(live: [creature(id: 6, noun: 'moradu', name: 'a lean moradu')],
                  dead: [creature(id: 5, noun: 'moradu', name: 'a jeol moradu', dead: true)])
      stabbity = target(build, 'moradu', 6)

      expect(stabbity.npc_dead?).to be(false)
      expect(stabbity.instance_variable_get(:@npc_is_alive)).to be(true)
    end

    it 'is true once the target itself is dead, though a same-noun creature lives on' do
      DRRoom.npcs = ['moradu']
      DRRoom.dead_npcs = ['moradu']
      seed_roster(live: [creature(id: 6, noun: 'moradu', name: 'a lean moradu')],
                  dead: [creature(id: 5, noun: 'moradu', name: 'a jeol moradu', dead: true)])
      stabbity = target(build, 'moradu', 5)

      expect(stabbity.npc_dead?).to be(true)
      expect(stabbity.instance_variable_get(:@npc_is_alive)).to be(false)
    end

    it 'is true once the target has left the room, though other NPCs remain' do
      DRRoom.npcs = ['goblin']
      seed_roster(live: [creature(id: 6, noun: 'goblin', name: 'a goblin')])

      expect(target(build, 'moradu', 9).npc_dead?).to be(true)
    end

    it 'is true once the target has left and only an ignored same-noun creature remains' do
      DRRoom.npcs = %w[goblin moradu]
      allow(DRRoom).to receive(:unignored_npcs).with(['jeol moradu']).and_return(['goblin'])
      seed_roster(live: [creature(id: 6, noun: 'moradu', name: 'a jeol moradu'),
                         creature(id: 7, noun: 'goblin', name: 'a goblin')])

      expect(target(build(ignored: ['jeol moradu']), 'moradu', 9).npc_dead?).to be(true)
    end

    # A room refresh clears the roster before re-registering its creatures
    # (lich-5 Creature.clear_room); DRRoom.npcs is replaced whole.
    it 'is false while the roster is empty mid-refresh and the target noun is still listed' do
      DRRoom.npcs = ['moradu']
      seed_roster(live: [])
      stabbity = target(build, 'moradu', 6)

      expect(stabbity.npc_dead?).to be(false)
      expect(stabbity.instance_variable_get(:@npc_is_alive)).to be(true)
    end

    it 'falls back to the corpse noun when no id is known' do
      DRRoom.npcs = ['moradu']
      DRRoom.dead_npcs = ['moradu']
      seed_roster(live: [])

      expect(target(build, 'moradu', nil).npc_dead?).to be(true)
    end

    it 'is false with no id, no corpse and the target still listed' do
      DRRoom.npcs = ['moradu']
      seed_roster(live: [])

      expect(target(build, 'moradu', nil).npc_dead?).to be(false)
    end

    it 'is true when the room has emptied' do
      DRRoom.npcs = []
      seed_roster(live: [creature(id: 6, noun: 'moradu', name: 'a lean moradu')])

      expect(target(build, 'moradu', 6).npc_dead?).to be(true)
    end
  end
end
