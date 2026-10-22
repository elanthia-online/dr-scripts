# frozen_string_literal: true

require 'ostruct'

load_lic_class('stabbity.lic', 'Stabbity')

RSpec.describe Stabbity do
  let(:creature_registry) { Lich::DragonRealms::Creature }

  # A roster creature as Lich's Creature exposes it. matches? models lich-5's
  # contract for these specs: the noun, or the whole name minus its article.
  def creature(id:, noun:, name:, dead: false)
    c = double("creature #{id.inspect}", id: id, noun: noun, name: name)
    allow(c).to receive(:crtr_flag?) { |flag| flag == :dead && dead }
    allow(c).to receive(:matches?) { |entry| entry == noun || entry == name.to_s.sub(/\A(?:a|an) /, '') }
    c
  end

  # Seeds the roster: in_room(:not_dead) answers the live creatures, in_room
  # with no filter answers everything present (the harness ignores filters).
  def seed_roster(live:, dead: [])
    allow(creature_registry).to receive(:in_room).with(:not_dead).and_return(live)
    allow(creature_registry).to receive(:in_room).with(no_args).and_return(live + dead)
  end

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

    it 'still finds the id of a creature whose name has not arrived yet' do
      DRRoom.npcs = ['moradu']
      seed_roster(live: [creature(id: 40, noun: 'moradu', name: nil)])

      expect(run_one_pass(build)).to include('advance #40')
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
      DRRoom.npcs = ['moradu']
      seed_roster(live: [creature(id: 6, noun: 'moradu', name: 'a lean moradu')])

      expect(target(build, 'moradu', 9).npc_dead?).to be(true)
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
