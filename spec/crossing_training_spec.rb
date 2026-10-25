# frozen_string_literal: true

require_relative 'spec_helper'

load_lic_class('crossing-training.lic', 'CrossingTraining')

# crossing-training reads game replies through Flags (song finished, no
# instrument, research interrupted), DRC.bput (weather, research, chadatru,
# tessera, scholarship book), waitfor (chadatru prayer) and fput (research
# status). Every matcher must hear only the game's own line, not another
# player's speech, whisper or ESP that contains the same words.
#
# Flags are fed raw lines the way lich-5 DRParser.check_events does. DRC.bput,
# waitfor and fput are replaced by models of lich-5's matching: String patterns
# become case-insensitive regexes and the first incoming line that matches
# wins. bput returns the matched text, waitfor the whole line, fput the
# pattern that matched.
RSpec.describe CrossingTraining do
  let(:trainer) { CrossingTraining.allocate }

  def esp(text) = %([General][Mallory] "#{text}")
  def esp_xml(text) = %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>)
  def say(text) = %(Mallory says, "#{text}")
  def say_xml(text) = %(<preset id='speech'>Mallory says</preset>, "#{text}")
  def whisper(text) = %(Mallory whispers, "#{text}")

  # Stripped shapes, as bput/waitfor/fput see them.
  def player_lines(text) = [esp(text), say(text), whisper(text)]

  # Raw shapes, as Flags see them.
  def raw_player_lines(text) = [esp_xml(text), say_xml(text), whisper(text)]

  # Feed a raw server line through the registered Flags matchers, the way
  # lich-5 DRParser.check_events does for every downstream line.
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

  # lich-5 DRC.bput: Strings compile to /x/i, each line is tried against every
  # pattern in order, and the first match's text is returned ('' on timeout).
  def bput_reply(patterns, lines)
    regexes = patterns.flatten.map { |item| item.is_a?(Regexp) ? item : /#{item}/i }
    lines.each do |line|
      regexes.each do |regex|
        match = line.match(regex)
        return match.to_a.first if match
      end
    end
    ''
  end

  # Stub DRC.bput with the lines that arrive after each command (first key the
  # command starts with wins), run through the script's real patterns.
  def stub_bput_lines(responses)
    allow(DRC).to receive(:bput) do |command, *patterns|
      pair = responses.find { |key, _| command.start_with?(key) }
      lines = pair ? pair.last : []
      lines = lines.shift if lines.first.is_a?(Array) # one reply per call
      bput_reply(patterns, lines || [])
    end
  end

  describe 'game-line flags' do
    before do
      $test_settings = OpenStruct.new(storage_containers: [], training_rooms: [1],
                                      crossing_training_requires_movement: [])
      $test_data = OpenStruct.new(perform: OpenStruct.new(perform_options: {}))
      allow(EquipmentManager).to receive(:new).and_return(EquipmentManager.allocate)
      trainer.send(:initialize)
    end

    context "'research-partial' (restarts the research project)" do
      before do
        trainer.instance_variable_set(:@researching, 'FUNDAMENTAL')
        allow(trainer).to receive(:check_osrel)
        allow(trainer).to receive(:refresh_cyclic)
        stub_bput_lines('research' => ['You focus on your research.'])
      end

      [
        'You lose your focus on your research project.',
        'You realize there is still more to learn before you arrive at a breakthrough.',
        'You are distracted by combat and lose your train of thought.',
        'You are distracted by your spellcasting and lose your place.',
        'Distracted, you forget what you were researching.',
        '<pushBold/>You lose your focus on your research project.<popBold/>'
      ].each do |line|
        it "restarts research on the game line #{line.inspect}" do
          deliver(line)
          trainer.check_research
          expect(DRC).to have_received(:bput).with('research FUNDAMENTAL 300', any_args)
        end
      end

      [
        'You lose your focus on your research project',
        'there is still more to learn before you arrive at a breakthrough',
        'distracted by combat',
        'distracted by your spellcasting',
        'you forget what you were'
      ].each do |text|
        it "ignores other players saying #{text.inspect}" do
          raw_player_lines(text).each { |line| deliver(line) }
          trainer.check_research
          expect(Flags['research-partial']).to be(false)
          expect(DRC).not_to have_received(:bput)
        end
      end
    end

    context "'ct-song' (blocking play waits for the song to end)" do
      it 'is set by the game line' do
        deliver('You finish playing a halting ruff on your copper zills.')
        expect(Flags['ct-song']).to be_truthy
      end

      it 'is not set by other players saying the words' do
        raw_player_lines('you finish playing').each { |line| deliver(line) }
        expect(Flags['ct-song']).to be(false)
      end
    end

    context "'ct-no-instrument' (stops playing for the rest of the run)" do
      before do
        allow(DRSkill).to receive(:getxp).with('Performance').and_return(0)
        trainer.instance_variable_set(:@settings, OpenStruct.new(instrument: 'zills'))
      end

      def play_after(line)
        allow(DRC).to receive(:play_song?) do
          deliver(line)
          false
        end
        trainer.play_song?
      end

      it 'marks the instrument missing on the game line' do
        play_after('Play on what instrument?')
        expect(trainer.instance_variable_get(:@no_instrument)).to be_truthy
      end

      it 'keeps playing when another player says the words' do
        raw_player_lines('Play on what instrument?').each do |line|
          play_after(line)
          expect(trainer.instance_variable_get(:@no_instrument)).to be_falsey
        end
      end
    end
  end

  describe '#research' do
    def drain_sent_messages
      Array.new(sent_messages.size) { sent_messages.pop }
    end

    before do
      trainer.instance_variable_set(:@researching, 'FUNDAMENTAL')
      allow(trainer).to receive(:refresh_cyclic)
    end

    it 'cancels and restarts when the game says it cannot begin' do
      stub_bput_lines('research' => [['You cannot begin to research that while you are already researching.'],
                                     ['You focus on your research.']])
      trainer.research
      expect(drain_sent_messages).to eq(['research cancel', 'research cancel'])
    end

    it 'still cancels when the game line has text before "You cannot begin"' do
      stub_bput_lines('research' => [['You pause.  You cannot begin another project right now.'],
                                     ['You focus on your research.']])
      trainer.research
      expect(drain_sent_messages).to eq(['research cancel', 'research cancel'])
    end

    it 'keeps the project when another player says "You cannot begin"' do
      player_lines('You cannot begin').each do |line|
        stub_bput_lines('research' => [line, 'You focus on your research.'])
        trainer.research
      end
      expect(drain_sent_messages).to be_empty
    end
  end

  describe '#train_theurgy research status check' do
    before do
      trainer.instance_variable_set(:@researching, 'FUNDAMENTAL')
      allow(DRC).to receive(:wait_for_script_to_complete)
      Flags.add('research-partial', 'x')
      Flags.add('research-complete', 'x')
    end

    # lich-5 fput: every waited-for value is tried as /value/i against each
    # line, and the value that matched is returned.
    def status_after(*lines)
      allow(trainer).to receive(:fput) do |_command, *vals|
        lines.each do |line|
          found = vals.find { |val| line =~ /#{val}/i }
          break found if found
        end
      end
      trainer.train_theurgy
    end

    it 'forgets the project when the game says nothing is being researched' do
      status_after("You're not researching anything!")
      expect(trainer.instance_variable_get(:@researching)).to be_nil
    end

    it 'keeps the project when another player says "not researching anything"' do
      player_lines('not researching anything').each do |line|
        status_after(line, 'You are researching Fundamental magic and are about halfway done.')
      end
      expect(trainer.instance_variable_get(:@researching)).to eq('FUNDAMENTAL')
    end
  end

  describe '#check_chadatru' do
    let(:waited) { [] }

    before do
      allow(DRStats).to receive(:paladin?).and_return(true)
      trainer.instance_variable_set(:@pray_to_chadatru, true)
      trainer.instance_variable_set(:@chadatru_prayer_cooldown, 3600)
      trainer.instance_variable_set(:@hometown, 'Crossing')
      UserVars.chadatru_prayer_last = Time.now - 4000
      $test_data = OpenStruct.new(theurgy: { 'Crossing' => { 'chadatru_altar' => { 'id' => 5 } } })
      allow(trainer).to receive(:waitfor) { |*strings| waited << strings }
    end

    it 'waits for the prayer to finish after the game line' do
      stub_bput_lines('kneel' => ['You kneel.'], 'pray chadatru' => ['As you kneel before the altar, you pray to Chadatru.'])
      trainer.check_chadatru
      expect(waited.size).to eq(1)
    end

    it 'does not wait when another player says "As you kneel" before the refusal' do
      player_lines('As you kneel').each do |line|
        stub_bput_lines('kneel'         => ['You kneel.'],
                        'pray chadatru' => [line, 'You decide it would be inappropriate to pray right now.'])
        trainer.check_chadatru
      end
      expect(waited).to be_empty
    end

    it 'still prays when another player says "decide it would be inappropriate"' do
      stub_bput_lines('kneel'         => ['You kneel.'],
                      'pray chadatru' => [esp('decide it would be inappropriate'), 'As you kneel before the altar, you pray to Chadatru.'])
      trainer.check_chadatru
      expect(waited.size).to eq(1)
    end

    it 'waits through other players\' lines for the soothing sensation' do
      stub_bput_lines('kneel' => ['You kneel.'], 'pray chadatru' => ['As you kneel before the altar, you pray to Chadatru.'])
      trainer.check_chadatru
      waitfor_regex = /#{waited.first.join('|')}/i
      incoming = player_lines('soothing sensation washes over your soul') +
                 ['A soothing sensation washes over your soul.']
      expect(incoming.find { |line| line =~ waitfor_regex }).to eq('A soothing sensation washes over your soul.')
    end
  end

  describe '#check_tessera' do
    before do
      allow(DRStats).to receive(:trader?).and_return(true)
      trainer.instance_variable_set(:@use_tessera, true)
      trainer.instance_variable_set(:@tessera_invoke_cooldown, 660)
      UserVars.tessera_invoke_last = Time.now - 1000
      allow(DRC).to receive(:left_hand).and_return('')
      allow(DRC).to receive(:right_hand).and_return('')
    end

    it 'puts the tessera back in the container the game named, not one another player named' do
      put_patterns = nil
      stub_bput_lines('get my tessera' => player_lines('You get a red tessera from inside your sword.') +
                                          ['You get a jade tessera from inside your leather pouch.'])
      allow(DRC).to receive(:bput).with(/\Aput my tessera/, any_args) do |command, *patterns|
        put_patterns = [command, patterns]
        'You put'
      end
      trainer.check_tessera
      expect(put_patterns.first).to eq('put my tessera in my pouch')
      expect(bput_reply(put_patterns.last, player_lines('you put in your hair') + ['You put your tessera in your leather pouch.']))
        .to eq('You put')
    end
  end

  describe '#train_scholarship' do
    before do
      allow(trainer).to receive(:play_song?)
      allow(trainer).to receive(:waitrt?)
      allow(DRSkill).to receive(:getxp).with('Scholarship').and_return(30)
      trainer.instance_variable_set(:@hometown, 'Shard')
      trainer.instance_variable_set(:@settings, OpenStruct.new(crossing_training: ['Scholarship']))
    end

    it 'drops Scholarship when the game says there is no book' do
      stub_bput_lines('get my blacksmithing book' => ['What were you referring to?'])
      trainer.train_scholarship
      expect(trainer.instance_variable_get(:@settings).crossing_training).to eq([])
    end

    it 'keeps Scholarship when another player says "What were you" before the book arrives' do
      player_lines('What were you thinking?').each do |line|
        stub_bput_lines('get my blacksmithing book' => [line, 'You get a blacksmithing book from your backpack.'])
        trainer.train_scholarship
      end
      expect(trainer.instance_variable_get(:@settings).crossing_training).to eq(['Scholarship'])
    end

    it 'drops Scholarship when another player says "did you get" before the game says there is no book' do
      stub_bput_lines('get my blacksmithing book' => [esp('did you get him some help?'), 'What were you referring to?'])
      trainer.train_scholarship
      expect(trainer.instance_variable_get(:@settings).crossing_training).to eq([])
    end
  end

  describe '#cast_spell moon check' do
    let(:spell) { { 'abbrev' => 'PG', 'moon' => true, 'mana' => 5 } }

    before do
      trainer.instance_variable_set(:@settings, OpenStruct.new(outdoor_room: 4321))
      allow(DRCA).to receive(:check_discern) { |data, _settings| data }
      allow(DRCMM).to receive(:check_moonwatch).and_return(true)
      allow(DRCMM).to receive(:set_moon_data).and_return(nil)
      allow(DRCT).to receive(:walk_to)
    end

    it 'walks to the outdoor room when the game says it is too hard inside' do
      stub_bput_lines('weather' => ["That's a bit hard to do while inside."])
      trainer.cast_spell(spell, 'Lunar Magic')
      expect(DRCT).to have_received(:walk_to).with(4321)
    end

    it 'stays put when another player mentions "inside" before the sky reply' do
      player_lines('Looking for a cleric to help someone inside the portal').each do |line|
        stub_bput_lines('weather' => [line, 'You glance up at the sky.'])
        trainer.cast_spell(spell, 'Lunar Magic')
      end
      expect(DRCT).not_to have_received(:walk_to)
    end
  end
end
