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

  # Seats NPCs in the room: on the roster and, by noun, in DRRoom.npcs.
  def seat(*npcs)
    creature._set_room(npcs)
    DRRoom.npcs = npcs.map(&:noun)
  end

  def finish_task
    Flags['UlfHara-task-complete'] = true
  end

  # Feed a raw server line through the registered Flags matchers, the way
  # lich-5's DRParser.check_events does for every line.
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

  # lich-5 DRC.bput matching: Strings compile to /x/i, each incoming line is
  # tried against every pattern in order, and the first match's text is
  # returned ('' when nothing matches).
  def model_bput(lines, patterns)
    regexes = patterns.flatten.map { |item| item.is_a?(Regexp) ? item : /#{item}/i }
    lines.each do |line|
      regexes.each do |regex|
        match = line.match(regex)
        return match.to_a.first if match
      end
    end
    ''
  end

  # Replies per command: a list of batches of incoming lines, one batch per
  # bput (the last batch repeats). Unlisted commands get 'Roundtime: 1 sec.'.
  def model_replies(replies)
    allow(DRC).to receive(:bput) do |command, *patterns|
      sent << command
      key = replies.keys.find { |prefix| command.start_with?(prefix) }
      batches = key ? replies[key] : [['Roundtime: 1 sec.']]
      model_bput(batches.size > 1 ? batches.shift : batches.first, patterns)
    end
  end

  # lich-5 reget over the last lines of the (stripped) server buffer.
  def model_reget(buffer)
    allow(ulfhara).to receive(:reget) do |_count, *patterns|
      hits = buffer.grep(/#{patterns.join('|')}/i)
      hits.empty? ? nil : hits
    end
  end

  # Other players' lines carrying a message: ESP, say and whisper, stripped
  # (what bput, waitfor and reget see) and raw XML (what Flags see).
  def esp(text) = %([General][Mallory] "#{text}")
  def esp_xml(text) = %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>)
  def say(text) = %(Mallory says, "#{text}")
  def say_xml(text) = %(<preset id='speech'>Mallory says</preset>, "#{text}")
  def whisper(text) = %(Mallory whispers, "#{text}")
  def player_lines(text) = [esp(text), say(text), whisper(text)]
  def raw_player_lines(text) = [esp_xml(text), say_xml(text), whisper(text)]

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
      seat(npc(1, 'guard'))
      ulfhara.unhandled_npcs
      expect(creature).to have_received(:in_room).with(:not_dead)
    end

    it 'lists two same-noun NPCs apart, by id' do
      seat(npc(11, 'guard'), npc(12, 'guard'))
      expect(ulfhara.unhandled_npcs).to eq(['#11', '#12'])
    end

    it 'skips baddies and ignored names by noun, case-insensitively' do
      seat(npc(1, 'Zukir', 'Lord Zukir'), npc(2, 'ruffian'), npc(3, 'human', 'a filthy human'), npc(4, 'guard'))
      expect(ulfhara.unhandled_npcs).to eq(['#4'])
    end

    it 'skips a baddie whose noun Lich derived from its name (legacy stream)' do
      seat(npc(1, 'ruffian', 'a scarred ruffian', noun_from_server: false), npc(2, 'guard'))
      expect(ulfhara.unhandled_npcs).to eq(['#2'])
    end

    it 'falls back to DRRoom.unignored_npcs while a roster creature has no noun' do
      creature._set_room([npc(1, nil, nil), npc(2, 'guard')])
      DRRoom.npcs = %w[guard ruffian]
      expect(ulfhara.unhandled_npcs).to eq(['guard'])
    end

    it 'falls back to DRRoom.unignored_npcs when the roster misses NPCs DRRoom.npcs lists' do
      # Legacy stream: only the baddie sent <crtrStatus>; the townsfolk aren't on the roster.
      creature._set_room([npc(1, 'ruffian', 'a scarred ruffian', noun_from_server: false)])
      DRRoom.npcs = %w[guard guard ruffian]
      expect(ulfhara.unhandled_npcs).to eq(%w[guard guard])
    end

    it 'skips an NPC an @ignore entry names by full name' do
      ulfhara.instance_variable_get(:@ignore).push('wounded guard')
      seat(npc(1, 'guard', 'a wounded guard'), npc(2, 'guard', 'a weary guard'))
      expect(ulfhara.unhandled_npcs).to eq(['#2'])
    end

    it 'skips handled ids but keeps the other same-noun NPC' do
      ulfhara.instance_variable_set(:@handled_ids, [11])
      seat(npc(11, 'guard'), npc(12, 'guard'))
      expect(ulfhara.unhandled_npcs).to eq(['#12'])
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

    it 'drops a handled noun when the roster is empty' do
      DRRoom.npcs = %w[sentry guard]
      ulfhara.mark_handled('sentry')
      expect(ulfhara.unhandled_npcs).to eq(['guard'])
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

  describe '#add_flags' do
    before { ulfhara.add_flags }

    # Game lines, raw as Flags see them. None of these messages is in our
    # logs; the ally's speech line is the shape Elanthipedia records, the
    # rest are illustrative.
    {
      'UlfHara-task-complete' => [
        'You have completed your task!  Return to Zukir!',
        '[ASK ZUKIR ABOUT TASK COMPLETE]',
        'You quickly snatch it up before a foe can!',
        %(<preset id='speech'>Saymos says</preset>, "You should probably go find Zukir.  I hear he's looking for an update from you!  Don't keep him waiting!"),
        'Your task is complete!  You should notify Zukir at once!',
        'You should go and report back to Zukir.',
        %(Lord Zukir says, "Report back and I'll give you another mission."),
        %(Saymos says, "Thanks!  You should head back to Zukir.")
      ],
      'UlfHara-combo-chest'   => ['You poke and prod, but fail to find anything of interest.'],
      'disarm-more'           => ['The coffer is not fully disarmed.', 'The coffer is not yet fully disarmed.', 'The coffer still has more to torment you with.'],
      'maze-reset'            => ["You can't go there.", "<pushBold/>You can't swim in that direction."],
      'cameo-loot'            => ['You quickly snatch it up!  Zukir will want this right away!'],
      'missing-found'         => ['Saymos enters, following you.'],
      'spell-ready'           => ['You feel fully prepared to cast your spell.', '<pushBold/>You feel fully prepared to cast your spell.<popBold/>']
    }.each do |key, lines|
      lines.each do |line|
        it "sets #{key} on the game line #{line[0, 50].inspect}" do
          deliver(line)
          expect(Flags[key]).to be_truthy
        end
      end
    end

    {
      'UlfHara-task-complete' => ['You have completed your task!  Return to Zukir!', 'ASK ZUKIR ABOUT TASK COMPLETE', 'You quickly snatch it', 'You should notify Zukir at once!'],
      'UlfHara-combo-chest'   => ['You poke and prod, but fail to find anything of interest'],
      'disarm-more'           => ['not fully disarmed', 'not yet fully disarmed', 'still has more to torment you with'],
      'maze-reset'            => ["You can't go there", "You can't swim in that direction."],
      'cameo-loot'            => ['You quickly snatch it up!  Zukir will want this right away!'],
      'missing-found'         => ['Saymos enters, following you'],
      'spell-ready'           => ['You feel fully prepared to cast your spell']
    }.each do |key, texts|
      it "ignores ESP, say and whisper lines carrying the #{key} text" do
        texts.flat_map { |text| raw_player_lines(text) }.each { |line| deliver(line) }
        expect(Flags[key]).to be_falsey
      end
    end

    # These may be an NPC's speech, so a quote before them is allowed; an ESP
    # channel or a whisper still never sets the flag.
    it 'ignores ESP and whispers carrying a task-complete line an NPC may speak' do
      ['You should probably go find Zukir.', 'You should go and report', 'give you another mission', 'You should head back to Zukir'].each do |text|
        [esp_xml(text), esp(text), whisper(text), %(<preset id='speech'>Mallory whispers</preset>, "#{text}")].each { |line| deliver(line) }
      end
      expect(Flags['UlfHara-task-complete']).to be_falsey
    end

    it 'keeps tending allies after an ESP line saying the task is complete' do
      $right_hand = 'medicated cloth'
      seat(npc(21, 'soldier'))
      model_replies('study' => [['Others will assist this one.']])
      allow(ulfhara).to receive(:walk_to_special) { |room| walks << room }
      model_reget(['Others will assist this one.'])
      deliver(esp_xml('Your task is complete!  You should notify Zukir at once!'))
      allow(ulfhara).to receive(:mark_handled) { finish_task }
      ulfhara.healing
      expect(sent).to include('study #21')
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
      seat(npc(11, 'guard'), npc(12, 'guard'))
      ulfhara.supply
      expect(sent.grep(/^study/)).to eq(['study #11', 'study #12'])
      expect(walks).to eq(['12873'])
    end

    it 'gives to the NPC it studied, by id, and keeps @ignore to configured names' do
      seat(npc(11, 'guard'), npc(12, 'guard'))
      study_replies['#11'] = 'They are in need of loaves to complete their mission.'
      ulfhara.supply
      expect(sent).to include('give #11')
      expect(sent.grep(/^give/)).to eq(['give #11'])
      expect(sent.grep(/^study/)).to eq(['study #11', 'study #12'])
    end

    it 'resets handled ids when it walks to the next room' do
      seat(npc(11, 'guard'))
      ulfhara.supply
      expect(ulfhara.instance_variable_get(:@handled_ids)).to eq([])
      expect(ulfhara.instance_variable_get(:@ignore)).to eq(['Zukir'])
    end

    it 'never studies baddies or Zukir' do
      seat(npc(1, 'Zukir', 'Lord Zukir'), npc(2, 'ruffian'), npc(3, 'guard'))
      ulfhara.supply
      expect(sent.grep(/^study/)).to eq(['study #3'])
    end

    it 'studies by noun on a stream without creature ids' do
      DRRoom.npcs = %w[Zukir sentry]
      ulfhara.supply
      expect(sent.grep(/^study/)).to eq(['study sentry'])
      expect(walks).to eq(['12873'])
    end

    it 'studies townsfolk by noun when the roster holds only the baddie' do
      creature._set_room([npc(1, 'ruffian', 'a scarred ruffian', noun_from_server: false)])
      DRRoom.npcs = %w[ruffian sentry]
      ulfhara.supply
      expect(sent.grep(/^study/)).to eq(['study sentry'])
      expect(walks).to eq(['12873'])
    end

    it 'walks on at once from an empty room' do
      ulfhara.supply
      expect(sent.grep(/^study/)).to be_empty
      expect(walks).to eq(['12873'])
    end

    context 'with replies matched the way lich-5 bput does' do
      let(:sack) { [['In the dirty sack you see a torch, a loaf of bread and a flask of water.']] }

      before do
        allow(ulfhara).to receive(:fput) { |command| sent << command }
        allow(Room).to receive(:current).and_return(OpenStruct.new(id: 12_873))
        seat(npc(11, 'guard'))
      end

      it 'acts on the real study reply, not a player line naming a supply' do
        model_replies('look in my sack' => sack, 'study' => [[say('They are in need of amulets to complete their mission.'), 'Others will assist this one.']])
        ulfhara.supply
        expect(sent.grep(/amulet/)).to be_empty
        expect(walks).to eq(['12873'])
      end

      it 'reads the sack contents from the game line, not a player line' do
        model_replies('look in my sack' => [[whisper('In the dirty sack you see a cursed amulet.'), 'In the dirty sack you see a loaf of bread and a flask of water.']],
                      'study'           => [['Saymos is surely a sign of dehydration.'], ['Others will assist this one.']],
                      'get my'          => [['You get a flask of water from inside your dirty sack.']])
        ulfhara.supply
        expect(sent).to include('get my water in my sack')
        expect(sent.count('drop my sack')).to eq(1) # the drop when the task ends
      end

      it 'does not drop the sack and fetch new supplies on a player line saying the item is missing' do
        model_replies('look in my sack' => sack,
                      'study'           => [['Saymos appears to be in need of torches to complete his mission for Zukir.'], ['Others will assist this one.']],
                      'get my'          => [[esp('What were you referring to?'), 'You get a torch from inside your dirty sack.']])
        ulfhara.supply
        expect(sent).to include('give #11')
        expect(sent.count('drop my sack')).to eq(1) # the drop when the task ends
      end

      it 'does not put the item back and skip the ally on a player whisper' do
        model_replies('look in my sack' => sack,
                      'study'           => [['Saymos appears to be in need of torches to complete his mission for Zukir.'], ['Others will assist this one.']],
                      'get my'          => [['You get a torch from inside your dirty sack.']],
                      'give'            => [[whisper('Save that for our allies.'), 'Roundtime: 1 sec.']])
        ulfhara.supply
        expect(sent).not_to include('put my torch in my sack')
      end

      it "still puts the item back when the ally says to save it" do
        model_replies('look in my sack' => sack,
                      'study'           => [['Saymos appears to be in need of torches to complete his mission for Zukir.']],
                      'get my'          => [['You get a torch from inside your dirty sack.']],
                      'give'            => [[%(Saymos says, "Save that for our allies.")]])
        ulfhara.supply
        expect(sent).to include('put my torch in my sack')
        expect(walks).to eq(['12873'])
      end
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
      seat(npc(21, 'soldier'), npc(22, 'soldier'))
      ulfhara.healing
      expect(sent.grep(/^study/)).to eq(['study #21', 'study #22'])
      expect(sent.grep(/^rub/)).to eq(['rub #21 with cloth'])
    end

    it 'does not tend an ally a player line says is wounded' do
      seat(npc(22, 'soldier'))
      model_reget([say('He carries some wounds that an Empath or medic could tend to.'), 'Others will assist this one.'])
      ulfhara.healing
      expect(sent.grep(/^rub/)).to be_empty
      expect(sent).to include('study #22')
    end

    it 'only takes the game line as the ally being taken care of' do
      seat(npc(22, 'soldier'))
      patterns = []
      allow(ulfhara).to receive(:reget) do |_count, *list|
        patterns << list
        nil
      end
      ulfhara.healing
      handled = patterns.find { |list| 'Others will assist this one.'.match?(/#{list.join('|')}/i) }
      regex = /#{handled.join('|')}/i
      expect('Others will assist this one.').to match(regex)
      expect('You give the soldier a studious look.').to match(regex)
      expect((player_lines('Others will assist') + player_lines('You give him a studious look')).grep(regex)).to be_empty
    end

    it 'keeps rubbing while the game answers Roundtime, whatever players say' do
      seat(npc(21, 'soldier'))
      model_replies('study' => [['He carries some wounds that an Empath or medic could tend to.']],
                    'rub'   => [[whisper('Rub what?'), 'Roundtime: 2 sec.'], [esp('That is probably not a good idea.'), 'Roundtime: 2 sec.'], ['Rub what?']])
      model_reget(['He carries some wounds that an Empath or medic could tend to.'])
      ulfhara.healing
      expect(sent.grep(/^rub/)).to eq(['rub #21 with cloth'] * 3)
    end

    it 'waits out the real "Best wait a bit" for a cloth, not a player line' do
      $right_hand = nil
      finish_task
      model_replies('get my medi cloth' => [['What were you referring to?']],
                    'get medi cloth'    => [[esp('What a mess.'), 'Best wait a bit before taking another cloth.'], ['You get a medicated cloth.']])
      ulfhara.healing
      expect(sent.count('get medi cloth')).to eq(2)
    end
  end

  describe '#combo' do
    before do
      allow(ulfhara).to receive(:walk_to_special)
      allow(ulfhara).to receive(:fput) { |command| sent << command }
      allow(ulfhara).to receive(:move).and_return(true)
      stub_const('MazeRoom', Class.new do
        define_method(:wander) { Flags['UlfHara-task-complete'] = true }
      end)
      DRRoom.pcs = []
      DRRoom.room_objs = ['ladder']
    end

    it 'does not work a chest a player line says was found' do
      model_replies('search' => [[say('After much shuffling, you manage to find a chest!'), "You're sure you searched this area recently."]])
      ulfhara.combo
      expect(sent.grep(/dial|latch/)).to be_empty
    end

    it 'turns the dials until the game says the mechanism clicked' do
      model_replies('search'         => [['After much shuffling, you manage to find a gleaming chest.']],
                    'turn blue dial' => [[say('A faint click can be heard from the mechanism.'), 'A faint tick can be heard from the mechanism.'], ['A faint click can be heard from the mechanism.']])
      ulfhara.combo
      expect(sent.count('turn blue dial')).to eq(2)
      expect(sent).to include('push blue dial', 'pull latch')
    end
  end

  describe '#wander_maze_until' do
    before do
      allow(ulfhara).to receive(:move).and_return(true)
      stub_const('MazeRoom', Class.new)
      DRRoom.room_objs = ['ladder']
    end

    it 'does not look and move on a player line saying the way is blocked' do
      ulfhara.add_flags
      raw_player_lines("You can't go there.").each { |line| deliver(line) }
      model_replies({})
      ulfhara.wander_maze_until('ladder', 'climb ladder')
      expect(sent).not_to include('look')
      expect(ulfhara).to have_received(:move).once.with('climb ladder')
    end

    it 'takes the first exit from the game line after a real blocked move, not from a player line' do
      Flags['maze-reset'] = true
      model_replies('look' => [[say('Obvious exits: up.'), 'Obvious exits: north, east.']])
      ulfhara.wander_maze_until('ladder', 'climb ladder')
      expect(ulfhara).to have_received(:move).with(' north')
      expect(ulfhara).not_to have_received(:move).with(/up/)
    end
  end

  describe 'lock picking replies' do
    before do
      allow(ulfhara).to receive(:pause)
      ulfhara.instance_variable_set(:@settings, OpenStruct.new(pick_blind: false, lockpick_force_disarm_careful: false))
      ulfhara.instance_variable_set(:@disarm_identify_failed, ['fails to reveal'])
      ulfhara.instance_variable_set(:@disarm_too_hard, ['a deadly trap'])
      ulfhara.instance_variable_set(:@disarm_careful, ['a tricky trap'])
      ulfhara.instance_variable_set(:@disarm_quick, ['a trivially constructed trap'])
      ulfhara.instance_variable_set(:@disarm_normal, ['a fairly simple trap'])
      ulfhara.instance_variable_set(:@disarm_failed, ['you set it off'])
      ulfhara.instance_variable_set(:@disarm_retry, ['You work at the trap but make no progress'])
      $left_hand = nil
    end

    it 'does not give up on the lockpicks when a player says "What were you referring to?"' do
      model_replies('get my lockpick' => [[say('What were you referring to?'), 'You get a slim lockpick from your lockpick ring.']])
      expect { ulfhara.find_lockpick }.not_to raise_error
    end

    it 'still stops when the game has no lockpick to get' do
      model_replies('get my lockpick' => [['What were you referring to?']])
      expect { ulfhara.find_lockpick }.to raise_error(SystemExit)
    end

    it 'reads the lock result from the game line, not a player line' do
      model_replies('pick coffer' => [[esp('Roundtime is a pain'), 'You discover another lock protecting the coffer.']])
      expect(ulfhara.pick_speed('coffer', 'quick')).to be(true)
    end

    it 'picks the disarm speed from the game line, not a player line naming another difficulty' do
      model_replies('disarm coffer identify' => [[say('That is a tricky trap.'), 'The coffer has a trivially constructed trap.']])
      ulfhara.disarm?('coffer')
      expect(sent).to include('disarm coffer quick')
      expect(sent).not_to include('disarm coffer careful')
    end

    it 'keeps the disarm speed when only a player line says something will shift' do
      model_replies('disarm coffer quick' => [['You work at the trap but make no progress.'], ['Roundtime: 1 sec.']])
      model_reget([esp('something to shift'), 'You work at the trap but make no progress.'])
      ulfhara.disarm_speed?('coffer', 'quick')
      expect(sent).to eq(['disarm coffer quick', 'disarm coffer quick'])
    end

    it 'slows to careful when the game says something will shift' do
      model_replies('disarm coffer quick' => [['You work at the trap but make no progress.']])
      model_reget(['You work at the trap but make no progress, and feel something to shift.'])
      ulfhara.disarm_speed?('coffer', 'quick')
      expect(sent).to eq(['disarm coffer quick', 'disarm coffer careful'])
    end
  end

  describe 'other reply patterns' do
    let(:patterns) { {} }

    before do
      allow(DRC).to receive(:bput) do |command, *list|
        patterns[command] = list
        raise StopIteration
      end
    end

    it 'reads the hunting task count only from the game line' do
      expect { ulfhara.hunting }.to raise_error(StopIteration)
      list = patterns.fetch('task')
      game = 'Lord Zukir wants you to kill as many as you must to recover 3 of these treasures.'
      expect(model_bput([game], list)).to eq('wants you to kill as many as you must to recover 3 of these treasures')
      expect(model_bput(player_lines('He wants you to kill as many as you must to recover 9 of these treasures'), list)).to eq('')
    end

    it 'reads the loot list only from the game line' do
      expect { ulfhara.loot_box('gleaming chest') }.to raise_error(StopIteration)
      list = patterns.fetch('look in gleaming chest')
      expect(model_bput(['In the gleaming chest you see a ring and some coins.'], list)).to eq('In the gleaming chest you see a ring and some coins.')
      expect(model_bput(player_lines('In the gleaming chest you see a cursed ring.'), list)).to eq('')
    end

    it 'ends the recovery search only on the game line' do
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: 1), OpenStruct.new(id: 2))
      allow(ulfhara).to receive(:walk_to_special)
      allow(ulfhara).to receive(:kneeling?).and_return(true)
      expect { ulfhara.recovery }.to raise_error(StopIteration)
      list = patterns.fetch('search')
      expect(model_bput(['You quickly snatch it up before a foe can!'], list)).to eq('You quickly snatch')
      expect(model_bput(['Roundtime: 3 sec.'], list)).to eq('Roundtime')
      expect(model_bput(player_lines('You quickly snatch it, Roundtime'), list)).to eq('')
    end
  end

  describe '#missing' do
    let(:room) { OpenStruct.new(id: 12_872) }

    before do
      allow(Room).to receive(:current).and_return(room)
      allow(Room).to receive(:[]).and_return(room)
      allow(ulfhara).to receive(:walk_to_special) do |dest|
        walks << dest
        seat # the next room is empty
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
      seat(npc(31, 'refugee'), npc(32, 'refugee'))
      ulfhara.missing
      expect(sent.grep(/^ask/)).to eq(['ask #31 about follow', 'ask #32 about follow'])
      expect(walks).to be_empty
    end

    it 'walks on once every NPC in the room has answered no' do
      seat(npc(31, 'refugee'), npc(33, 'refugee'))
      ulfhara.missing
      expect(sent.grep(/^ask/)).to eq(['ask #31 about follow', 'ask #33 about follow'])
      expect(walks).to eq(['12873'])
    end

    context 'with replies matched the way lich-5 bput does' do
      let(:destination) { OpenStruct.new(id: 12_872) }

      before do
        allow(Room).to receive(:[]).and_return(destination)
        allow(Room).to receive(:current).and_return(OpenStruct.new(id: 12_900))
        allow(ulfhara).to receive(:escort).and_raise('escorted')
      end

      it 'does not start escorting on an ESP or whisper line thanking you' do
        seat(npc(31, 'refugee'))
        model_replies('ask #31' => [[esp('I appreciate your help!'), whisper('Did you hit your head too?'), 'The refugee does not seem to know anything about that.']])
        ulfhara.missing
        expect(walks).to eq(['12873'])
      end

      it 'still escorts the ally who thanks you' do
        seat(npc(31, 'refugee'))
        model_replies('ask #31' => [[%(The refugee says, "I appreciate your help!  Lead the way.")]])
        expect { ulfhara.missing }.to raise_error('escorted')
      end

      it 'waits for the ally to follow on the game line only' do
        arrived = false
        waits = []
        allow(Room).to receive(:current) { arrived ? destination : OpenStruct.new(id: 12_900) }
        allow(ulfhara).to receive(:escort) { arrived = true }
        allow(ulfhara).to receive(:waitfor) { |*args| waits.concat(args) }
        model_replies('search' => [[say('Look, you notice an unconscious form!'), 'Searching the rubble, you notice the still, unconscious form of a guardsman.']])
        ulfhara.missing
        expect(waits.size).to eq(1)
        expect('Saymos enters, following you.').to match(waits.first)
        expect(player_lines('Saymos enters, following you.').grep(waits.first)).to be_empty
      end
    end
  end
end
