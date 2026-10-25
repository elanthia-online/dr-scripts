# frozen_string_literal: true

require_relative 'spec_helper'

load_lic_class('invoke-rune.lic', 'Runestone')

# Runestone#runestone_cast sends `invoke my <rune>` and picks a branch from the
# line DRC.bput returns: throw a used-up rune away, give up on this cast, stop
# the script, or go on to harness and cast. Runestone#get_runestone greps the
# last 3 lines after the get for the used-up rune and throws it away.
#
# DRC.bput is replaced by a model of lich-5's DRC.bput: String patterns become
# case-insensitive regexes, the incoming lines are read in order, the first
# line matching any pattern wins, and bput returns the matched text (or ''
# when nothing matches). reget is the harness copy of lich-5's, reading
# $server_buffer.
#
# Every reply pattern must match only the game's own line, not another
# player's speech, ESP or whisper that contains the same words.
#
# An unescaped '?' in a String pattern makes the character before it
# optional and drops the '?' from the returned text: 'Invoke what?' returns
# "Invoke what", which never equals the `when 'Invoke what?'` literal.
RSpec.describe Runestone do
  let(:rune_name) { 'elbaite runestone' }
  let(:runestone) { Runestone.allocate }
  let(:bput_commands) { [] }
  let(:bput_patterns) { {} }

  # Incoming lines per command verb.
  let(:replies) { { 'invoke' => [], 'harn' => [], 'cast' => [] } }

  before do
    runestone.instance_variable_set(:@rune, rune_name)
    runestone.instance_variable_set(:@harness, 10)
    runestone.instance_variable_set(:@runestone_storage, 'pouch')
    runestone.instance_variable_set(:@buff_spell_mana_threshold, 0)
    allow(runestone).to receive(:mana).and_return(100)
    allow(DRCI).to receive(:dispose_trash)
    allow(DRCI).to receive(:put_away_item?).and_return(true)
    allow(DRC).to receive(:message)
    allow(DRC).to receive(:bput) do |command, *patterns|
      bput_commands << command
      verb = command.split.first
      bput_patterns[verb] = patterns
      model_bput(replies.fetch(verb), patterns)
    end
  end

  # lich-5 DRC.bput matching: Strings compile to /x/i, each line is tried
  # against every pattern in order, and the first match's text is returned.
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

  def invoke(*lines)
    replies['invoke'].concat(lines)
    runestone.runestone_cast
  end

  def harnessed?
    bput_commands.include?('harn 10')
  end

  def esp(text)
    %([General][Mallory] "#{text}")
  end

  def esp_xml(text)
    %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>)
  end

  def say(text)
    %(Mallory says, "#{text}")
  end

  def say_xml(text)
    %(<preset id='speech'>Mallory says</preset>, "#{text}")
  end

  def whisper(text)
    %(Mallory whispers, "#{text}")
  end

  def player_lines(text)
    [esp(text), say(text), whisper(text)]
  end

  let(:invoked_line) { 'Closing your eyes, you trace the pattern of the elbaite runestone.' }

  describe '#runestone_cast with the game lines' do
    it 'throws the rune away when it is used up, without casting' do
      invoke('Well, that was fun.')
      expect(DRCI).to have_received(:dispose_trash).with(rune_name)
      expect(harnessed?).to be(false)
    end

    it 'harnesses, casts and puts the rune away after a successful invoke' do
      invoke(invoked_line)
      expect(bput_commands).to eq(["invoke my #{rune_name}", 'harn 10', 'cast'])
      expect(DRCI).to have_received(:put_away_item?).with(rune_name, 'pouch')
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'gives up on this cast when the pattern resists' do
      invoke('The spell pattern resists the influx of Holy mana and fails completely.')
      expect(harnessed?).to be(false)
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'gives up on this cast when the spell backfires' do
      invoke('Your spell barely backfires.')
      expect(harnessed?).to be(false)
    end

    it 'stops the script when too fatigued to finish the pattern' do
      expect { invoke('You strain, but are too mentally fatigued to finish the pattern.') }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('Cannot cast this spell currently!')
    end
  end

  describe '#runestone_cast when the rune is not in hand' do
    before { invoke('Invoke what?') }

    it 'gets the whole reply, question mark included, back from bput' do
      expect(model_bput(['Invoke what?'], bput_patterns.fetch('invoke'))).to eq('Invoke what?')
    end

    it 'gives up on this cast instead of harnessing and casting' do
      expect(bput_commands).to eq(["invoke my #{rune_name}"])
    end

    it 'does not try to put away a rune it is not holding' do
      expect(DRCI).not_to have_received(:put_away_item?)
    end
  end

  describe '#runestone_cast with player lines carrying the replies' do
    it 'keeps the rune when a player says the used-up message' do
      player_lines('Well, that was fun.').each do |line|
        replies['invoke'].replace([line, invoked_line])
        runestone.runestone_cast
      end
      expect(DRCI).not_to have_received(:dispose_trash)
      expect(bput_commands.count('cast')).to eq(3)
    end

    it 'does not give up on the cast for a player line about resisting or backfiring' do
      ['The spell pattern resists.', 'Watch it backfire!'].flat_map { |t| player_lines(t) }.each do |line|
        replies['invoke'].replace([line, invoked_line])
        runestone.runestone_cast
      end
      expect(bput_commands.count('harn 10')).to eq(6)
    end

    it 'does not stop the script for a player line about fatigue' do
      player_lines('You strain, but are too mentally fatigued to finish the pattern.').each do |line|
        replies['invoke'].replace([line, invoked_line])
        expect { runestone.runestone_cast }.not_to raise_error
      end
      expect(DRC).not_to have_received(:message)
    end
  end

  describe '#runestone_cast harness and cast replies' do
    before { invoke(invoked_line) }

    it 'ends the harness wait on the game line only' do
      patterns = bput_patterns.fetch('harn')
      game = 'You tap into the mana from fifty of the surrounding streams and attempt to keep it channeling in a stream around you.'
      expect(model_bput([game], patterns)).not_to eq('')
      expect(model_bput(player_lines('You tap into the mana'), patterns)).to eq('')
    end

    it 'ends the cast wait on a game line that mentions you, not on quoted player text' do
      patterns = bput_patterns.fetch('cast')
      expect(model_bput(['You gesture.'], patterns)).not_to eq('')
      expect(model_bput(['A warm glow surrounds you.'], patterns)).not_to eq('')
      expect(model_bput(player_lines('You feel better.'), patterns)).to eq('')
    end
  end

  describe '#get_runestone' do
    before { allow(DRCI).to receive(:get_item) }

    it 'throws away a used-up rune it just got' do
      $server_buffer = ["You get a useless #{rune_name} from inside your pouch."]
      expect(runestone.get_runestone).to be(false)
      expect(DRCI).to have_received(:dispose_trash).with(rune_name)
    end

    it 'keeps a good rune' do
      $server_buffer = ["You get a colorful #{rune_name} marked with a symbol for Bless from inside your pouch."]
      expect(runestone.get_runestone).to be(true)
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'keeps a good rune when a player line names a useless one' do
      text = "You get a useless #{rune_name} from inside your pouch."
      [esp(text), esp_xml(text), say(text), say_xml(text), whisper(text)].each do |line|
        $server_buffer = [line, "You get a colorful #{rune_name} from inside your pouch."]
        expect(runestone.get_runestone).to be(true)
      end
      expect(DRCI).not_to have_received(:dispose_trash)
    end
  end
end
