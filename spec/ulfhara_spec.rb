# frozen_string_literal: true

require 'ostruct'

load_lic_class('ulfhara.lic', 'UlfHara')

RSpec.describe UlfHara do
  let(:creature) { Lich::DragonRealms::Creature }
  let(:ulfhara) do
    described_class.allocate.tap do |script|
      script.instance_variable_set(:@baddies, %w[ruffian bandit zombie Human])
      script.instance_variable_set(:@ignore, ['Zukir'])
      script.instance_variable_set(:@handled_ids, [])
      script.instance_variable_set(:@rooms, %w[12872 12873 12874 12875])
      script.instance_variable_set(:@rooms_count, 0)
      script.instance_variable_set(:@notfoods, %w[water])
      script.instance_variable_set(:@notdrinks, %w[bread])
    end
  end
  let(:sent) { [] }
  let(:walks) { [] }

  def npc(id, noun, name = "a #{noun}", noun_from_server: true)
    Lich::DragonRealms::CreatureInstance.new(id, noun, name, noun_from_server: noun_from_server)
  end

  def finish_task
    Flags['UlfHara-task-complete'] = true
  end

  before do
    Flags['UlfHara-task-complete'] = false
    allow(ulfhara).to receive(:task)
    allow(DRC).to receive(:list_to_nouns) { |list| list.scan(/(\w+)(?:,| and|$)/).flatten }
    # Runaway guard: a loop that never clears its room spins on unhandled_npcs.
    calls = 0
    allow(creature).to receive(:in_room).and_wrap_original do |original, *filters|
      calls += 1
      raise 'runaway loop: room never cleared' if calls > 200

      original.call(*filters)
    end
  end

  describe '#unhandled_npcs' do
    it 'asks the roster for living creatures only' do
      creature._set_room([npc(1, 'guard')])
      ulfhara.unhandled_npcs
      expect(creature).to have_received(:in_room).with(:not_dead)
    end

    it 'lists two same-noun NPCs apart, by id' do
      creature._set_room([npc(11, 'guard'), npc(12, 'guard')])
      expect(ulfhara.unhandled_npcs).to eq(['#11', '#12'])
    end

    it 'skips baddies and ignored names by noun, case-insensitively' do
      creature._set_room([npc(1, 'Zukir', 'Lord Zukir'), npc(2, 'ruffian'), npc(3, 'human', 'a filthy human'), npc(4, 'guard')])
      expect(ulfhara.unhandled_npcs).to eq(['#4'])
    end

    it 'skips a baddie whose noun Lich derived from its name (legacy stream)' do
      creature._set_room([npc(1, 'ruffian', 'a scarred ruffian', noun_from_server: false), npc(2, 'guard')])
      expect(ulfhara.unhandled_npcs).to eq(['#2'])
    end

    it 'falls back to DRRoom.unignored_npcs while a roster creature has no noun' do
      creature._set_room([npc(1, nil, nil), npc(2, 'guard')])
      DRRoom.npcs = %w[guard ruffian]
      expect(ulfhara.unhandled_npcs).to eq(['guard'])
    end

    it 'skips an NPC an @ignore entry names by full name' do
      ulfhara.instance_variable_get(:@ignore).push('wounded guard')
      creature._set_room([npc(1, 'guard', 'a wounded guard'), npc(2, 'guard', 'a weary guard')])
      expect(ulfhara.unhandled_npcs).to eq(['#2'])
    end

    it 'skips handled ids but keeps the other same-noun NPC' do
      ulfhara.instance_variable_set(:@handled_ids, [11])
      creature._set_room([npc(11, 'guard'), npc(12, 'guard')])
      expect(ulfhara.unhandled_npcs).to eq(['#12'])
    end

    it 'falls back to the noun for a creature without an id' do
      creature._set_room([npc(nil, 'sentry', nil), npc(5, 'guard')])
      expect(ulfhara.unhandled_npcs).to eq(['sentry', '#5'])
    end

    it 'falls back to DRRoom.unignored_npcs when the roster is empty' do
      DRRoom.npcs = %w[Zukir ruffian sentry]
      allow(DRRoom).to receive(:unignored_npcs).and_call_original
      expect(ulfhara.unhandled_npcs).to eq(['sentry'])
      expect(DRRoom).to have_received(:unignored_npcs).with(%w[ruffian bandit zombie Human Zukir])
    end

    it 'is empty for an empty room' do
      expect(ulfhara.unhandled_npcs).to eq([])
    end
  end

  describe '#mark_handled' do
    it 'records an id target as handled without touching @ignore' do
      ulfhara.mark_handled('#42')
      expect(ulfhara.instance_variable_get(:@handled_ids)).to eq([42])
      expect(ulfhara.instance_variable_get(:@ignore)).to eq(['Zukir'])
    end

    it 'ignores a noun target by name' do
      ulfhara.mark_handled('sentry')
      expect(ulfhara.instance_variable_get(:@ignore)).to eq(%w[Zukir sentry])
      expect(ulfhara.instance_variable_get(:@handled_ids)).to eq([])
    end
  end

  describe '#supply' do
    let(:study_replies) { {} }

    before do
      allow(ulfhara).to receive(:walk_to_special) do |room|
        walks << room
        finish_task
      end
      allow(DRC).to receive(:bput) do |cmd, *_matches|
        sent << cmd
        case cmd
        when /^look in my sack/ then 'In the dirty sack you see a loaf of bread and a flask of water.'
        when /^study (.+)/ then study_replies.fetch(Regexp.last_match(1), 'Others will assist')
        when /^get my/ then 'You get'
        when /^give/ then 'Save that for our allies'
        else 'Roundtime'
        end
      end
    end

    it 'studies each of two same-noun NPCs once, by id, then moves on' do
      DRRoom.npcs = %w[guard guard]
      creature._set_room([npc(11, 'guard'), npc(12, 'guard')])
      ulfhara.supply
      expect(sent.grep(/^study/)).to eq(['study #11', 'study #12'])
      expect(walks).to eq(['12873'])
    end

    it 'gives to the NPC it studied, by id, and keeps @ignore to configured names' do
      DRRoom.npcs = %w[guard guard]
      creature._set_room([npc(11, 'guard'), npc(12, 'guard')])
      study_replies['#11'] = 'They are in need of loaves to complete their mission.'
      ulfhara.supply
      expect(sent).to include('give #11')
      expect(sent.grep(/^give/)).to eq(['give #11'])
      expect(sent.grep(/^study/)).to eq(['study #11', 'study #12'])
    end

    it 'resets handled ids when it walks to the next room' do
      creature._set_room([npc(11, 'guard')])
      ulfhara.supply
      expect(ulfhara.instance_variable_get(:@handled_ids)).to eq([])
      expect(ulfhara.instance_variable_get(:@ignore)).to eq(['Zukir'])
    end

    it 'never studies baddies or Zukir' do
      creature._set_room([npc(1, 'Zukir', 'Lord Zukir'), npc(2, 'ruffian'), npc(3, 'guard')])
      ulfhara.supply
      expect(sent.grep(/^study/)).to eq(['study #3'])
    end

    it 'studies by noun on a stream without creature ids' do
      DRRoom.npcs = %w[Zukir sentry]
      ulfhara.supply
      expect(sent.grep(/^study/)).to eq(['study sentry'])
      expect(walks).to eq(['12873'])
    end

    it 'walks on at once from an empty room' do
      ulfhara.supply
      expect(sent.grep(/^study/)).to be_empty
      expect(walks).to eq(['12873'])
    end
  end

  describe '#healing' do
    let(:last_study) { [] }

    before do
      $right_hand = 'medicated cloth'
      allow(ulfhara).to receive(:walk_to_special) do |room|
        walks << room
        finish_task if walks.size > 1
      end
      allow(ulfhara).to receive(:reget) do |_lines, *patterns|
        last_study.last.to_s =~ Regexp.union(patterns) ? [last_study.last] : nil
      end
      allow(DRC).to receive(:bput) do |cmd, *_matches|
        sent << cmd
        reply = case cmd
                when /^study #21/ then 'He carries some wounds that an Empath or medic could tend.'
                when /^study/ then 'Others will assist this one.'
                when /^rub/ then 'Rub what?'
                else 'Roundtime'
                end
        last_study << reply if cmd.start_with?('study')
        reply
      end
    end

    it 'studies and tends each of two same-noun NPCs by id' do
      DRRoom.npcs = %w[soldier soldier]
      creature._set_room([npc(21, 'soldier'), npc(22, 'soldier')])
      ulfhara.healing
      expect(sent.grep(/^study/)).to eq(['study #21', 'study #22'])
      expect(sent.grep(/^rub/)).to eq(['rub #21 with cloth'])
    end
  end

  describe '#missing' do
    let(:room) { OpenStruct.new(id: 12_872) }

    before do
      allow(Room).to receive(:current).and_return(room)
      allow(Room).to receive(:[]).and_return(room)
      allow(ulfhara).to receive(:walk_to_special) do |dest|
        walks << dest
        creature._set_room([]) # the next room is empty
        finish_task
      end
      allow(DRC).to receive(:bput) do |cmd, *_matches|
        sent << cmd
        if cmd == 'ask #32 about follow'
          finish_task
          'I appreciate your help'
        else
          'The refugee does not seem to know anything about that.'
        end
      end
    end

    it 'asks each of two same-noun NPCs in turn, by id, before moving on' do
      DRRoom.npcs = %w[refugee refugee]
      creature._set_room([npc(31, 'refugee'), npc(32, 'refugee')])
      ulfhara.missing
      expect(sent.grep(/^ask/)).to eq(['ask #31 about follow', 'ask #32 about follow'])
      expect(walks).to be_empty
    end

    it 'walks on once every NPC in the room has answered no' do
      creature._set_room([npc(31, 'refugee'), npc(33, 'refugee')])
      ulfhara.missing
      expect(sent.grep(/^ask/)).to eq(['ask #31 about follow', 'ask #33 about follow'])
      expect(walks).to eq(['12873'])
    end
  end
end
