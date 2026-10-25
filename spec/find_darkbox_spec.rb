# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

# find-darkbox.lic is class-less: the whole script is top-level code. These
# specs run the real file in a fresh object. Each `play darkbox` delivers that
# play's server lines the way lich-5 does: into the reget buffer
# ($server_buffer, read by the harness copy of lich-5's reget, which strips
# tags) and through every registered Flags matcher, as DRParser.check_events
# does for each downstream line. When the scripted plays run out, the next play
# ends the run.
#
# The Flags and reget checks walk to the bank, stop the run, clear the saved
# Darkbox room or run heal-remedy (which uses up herbs and remedies), so each
# must match only the game's own line and not another player's speech, ESP or
# whisper that contains the same words.
RSpec.describe 'find-darkbox.lic' do
  let(:end_of_run) { Class.new(StandardError) }
  let(:script) { Object.new }
  let(:walks) { [] }
  let(:sent) { [] }
  # Server lines per `play darkbox`, in order.
  let(:plays) { [] }
  # Server lines that arrive while heal-remedy runs.
  let(:during_heal) { [] }

  let(:gone_line) { 'Without warning, the Darkbox simply vanishes!' }
  let(:no_money_line) { "You try to play the Darkbox, but realize you don't have the 200 Kronars required.  How depressing." }
  let(:wounded_line) { 'Your injury increases the difficulty of the game, but you press on.' }
  let(:no_darkbox_line) { 'What type of song did you want to play?' }
  let(:wounds_line) { 'You try to play the Darkbox, but your wounds make it impossible.' }
  let(:what_were_line) { 'What were you referring to?' }
  let(:try_line) { 'You try, but you cannot get through.' }

  before do
    $test_settings = OpenStruct.new(
      hollow_eve_junk: [],
      darkbox_stop_on_wounded: false,
      he_use_herbs_remedies: true,
      hollow_eve_loot_container: 'sack',
      worn_trashcan: nil,
      worn_trashcan_verb: nil
    )
    DRRoom.room_objs = ['Darkbox']
    allow(DRCT).to receive(:walk_to) { |id| walks << id }
    allow(DRC).to receive(:message)
    allow(DRC).to receive(:bput).and_return('The clerk counts out')
    allow(DRC).to receive(:wait_for_script_to_complete) { during_heal.each { |line| receive_line(line) } }
    allow(script).to receive(:pause)
    allow(script).to receive(:fput) do |command|
      sent << command
      next unless command == 'play darkbox'

      raise end_of_run if plays.empty?

      plays.shift.each { |line| receive_line(line) }
    end
  end

  # Feed a server line to reget and through the registered Flags matchers,
  # the way Lich's DRParser.check_events does for every downstream line.
  def receive_line(line)
    $server_buffer << line
    Flags.matchers.each do |key, regexes|
      regexes.each do |regex|
        if (match = line.match(regex))
          Flags[key] = match
          break
        end
      end
    end
  end

  def run_script
    path = lic_path('find-darkbox.lic')
    script.instance_eval(File.read(path), path, 1)
    :finished
  rescue end_of_run
    :played_on
  rescue SystemExit
    :exited
  end

  def play_count
    sent.count('play darkbox')
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
    [esp(text), esp_xml(text), say(text), say_xml(text), whisper(text)]
  end

  describe 'with the game lines' do
    it 'forgets the Darkbox room and goes back to the start when the Darkbox vanishes' do
      plays << [gone_line]
      expect(run_script).to eq(:finished)
      expect(UserVars.last_darkbox).to be_nil
      expect(walks).to eq([16_150])
      expect(play_count).to eq(1)
    end

    it 'still sees the vanish line behind a leading tag' do
      plays << ["<pushBold/>#{gone_line}"]
      expect(run_script).to eq(:finished)
      expect(UserVars.last_darkbox).to be_nil
    end

    it 'goes to the bank and back when out of money' do
      plays << [no_money_line]
      expect(run_script).to eq(:played_on)
      expect(walks).to eq([16_315, 1])
      expect(DRC).to have_received(:bput).with('withdraw 3 platinum', any_args)
    end

    it 'stops playing when wounded and the setting is on' do
      $test_settings.darkbox_stop_on_wounded = true
      plays << [wounded_line]
      expect(run_script).to eq(:finished)
      expect(play_count).to eq(1)
    end

    it 'stops the script when there is no Darkbox to play' do
      plays << [no_darkbox_line]
      expect(run_script).to eq(:exited)
      expect(DRC).to have_received(:message).with('*** Darkbox not found in any of the rooms! ***')
    end

    it 'runs heal-remedy when wounds stop the game, then stops if out of herbs' do
      plays << [wounds_line]
      during_heal << what_were_line
      expect(run_script).to eq(:finished)
      expect(DRC).to have_received(:wait_for_script_to_complete).with('heal-remedy', ['quick'])
      expect(DRC).to have_received(:message).with('*** Out of herbs or remedies! Seek out more or an Empath! ***')
    end

    it 'waits before walking when the last move was refused' do
      $server_buffer << try_line
      plays << []
      run_script
      expect(script).to have_received(:pause).with(20)
    end
  end

  describe 'with player lines carrying the same words' do
    it 'keeps the Darkbox room and keeps playing' do
      plays << player_lines(gone_line)
      expect(run_script).to eq(:played_on)
      expect(UserVars.last_darkbox).to eq(1)
      expect(walks).to be_empty
      expect(play_count).to eq(2)
    end

    it 'does not go to the bank' do
      plays << player_lines(no_money_line)
      expect(run_script).to eq(:played_on)
      expect(walks).to be_empty
      expect(DRC).not_to have_received(:bput)
    end

    it 'keeps playing when wounded-stop is on' do
      $test_settings.darkbox_stop_on_wounded = true
      plays << player_lines(wounded_line)
      expect(run_script).to eq(:played_on)
      expect(play_count).to eq(2)
    end

    it 'does not stop the script as if there were no Darkbox' do
      plays << player_lines(no_darkbox_line)
      expect(run_script).to eq(:played_on)
      expect(DRC).not_to have_received(:message)
    end

    it 'does not run heal-remedy' do
      plays << player_lines('your wounds make it impossible')
      expect(run_script).to eq(:played_on)
      expect(DRC).not_to have_received(:wait_for_script_to_complete)
    end

    it 'keeps playing after heal-remedy when only a player says the item is missing' do
      plays << [wounds_line]
      during_heal.concat(player_lines(what_were_line))
      expect(run_script).to eq(:played_on)
      expect(script).to have_received(:pause).with(65)
      expect(DRC).not_to have_received(:message)
    end

    it 'does not wait before walking' do
      $server_buffer.concat(player_lines('You try, but'))
      plays << []
      run_script
      expect(script).not_to have_received(:pause).with(20)
    end
  end
end
