# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('lockbox.lic', 'Lockbox')

# Lockbox sends `remove`/`get`, then `pick my <box>`, and picks a branch from
# the line DRC.bput returns: relock, fall back to pick.lic, or exit.
# DRC.bput is replaced by a model of lich-5's DRC.bput: String patterns become
# case-insensitive regexes, the incoming lines are read in order, the first
# line matching any pattern wins, and bput returns the matched text (or ''
# when nothing matches).
#
# The reply patterns must match only the game's own line, not another
# player's speech, ESP or whisper that contains the same words.
RSpec.describe Lockbox do
  let(:box) { 'training box' }
  let(:lockbox) { Lockbox.allocate }
  let(:equipment_manager) { instance_double('EquipmentManager', empty_hands: nil) }
  let(:bput_commands) { [] }
  let(:progress_line) { 'You are not making any progress on the lock.' }

  # Incoming lines per command, consumed in order; commands without scripted
  # lines get no reply.
  let(:replies) { Hash.new { |hash, key| hash[key] = [] } }

  before do
    lockbox.instance_variable_set(:@box, box)
    lockbox.instance_variable_set(:@equipment_manager, equipment_manager)
    lockbox.instance_variable_set(:@worn_lockbox, false)
    lockbox.instance_variable_set(:@performance_pause, 0)
    $running_scripts << 'performance'
    allow(lockbox).to receive(:echo)
    allow(DRC).to receive(:wait_for_script_to_complete)
    allow(DRC).to receive(:bput) do |command, *patterns|
      bput_commands << command
      model_bput(replies[command].shift || [], patterns)
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

  # Patterns of the next bput for a command, captured without running it.
  def captured_patterns(command)
    captured = nil
    allow(DRC).to receive(:bput) do |sent, *patterns|
      captured = patterns if sent == command && captured.nil?
      ''
    end
    yield
    captured
  end

  def pick(*lines)
    replies["pick my #{box}"] << lines
    lockbox.pick_box
  end

  def esp(text)
    %([General][Mallory] "#{text}")
  end

  def say(text)
    %(Mallory says, "#{text}")
  end

  def whisper(text)
    %(Mallory whispers, "#{text}")
  end

  def player_lines(text)
    [esp(text), say(text), whisper(text)]
  end

  describe 'getting the box' do
    before { allow(DRSkill).to receive(:getxp).with('Locksmithing').and_return(34) }

    it 'falls back to pick.lic when the box is not found' do
      replies["get my #{box}"] << ['What were you referring to?']
      expect { lockbox.do_stuff }.to raise_error(SystemExit)
      expect(DRC).to have_received(:wait_for_script_to_complete).with('pick')
    end

    it 'exits when the worn box is not worn' do
      lockbox.instance_variable_set(:@worn_lockbox, true)
      replies["remove my #{box}"] << ['Remove what?']
      expect { lockbox.do_stuff }.to raise_error(SystemExit)
      expect(lockbox).to have_received(:echo).with(/Lockbox is not worn/)
    end

    it 'goes on to close the worn box after removing it' do
      lockbox.instance_variable_set(:@worn_lockbox, true)
      replies["remove my #{box}"] << ['You remove a training box from your belt.']
      lockbox.do_stuff
      expect(bput_commands.first(2)).to eq(["remove my #{box}", "close my #{box}"])
    end

    ['What were', 'What were you referring to?'].each do |phrase|
      it "ignores #{phrase.inspect} from players while getting the box" do
        player_lines(phrase).each do |line|
          replies["get my #{box}"] << [line, 'You get a training box from inside your backpack.']
          expect { lockbox.do_stuff }.not_to raise_error
        end
        expect(DRC).not_to have_received(:wait_for_script_to_complete)
      end
    end

    ['Remove what', "You aren't wearing that"].each do |phrase|
      it "ignores #{phrase.inspect} from players while removing the worn box" do
        lockbox.instance_variable_set(:@worn_lockbox, true)
        player_lines(phrase).each do |line|
          replies["remove my #{box}"] << [line, 'You remove a training box from your belt.']
          expect { lockbox.do_stuff }.not_to raise_error
        end
        expect(lockbox).not_to have_received(:echo)
      end
    end
  end

  # The text corpus has no box replies, so the game lines below put each
  # phrase at the start of the line and after narrative text without a quote
  # (the shape of the one corpus hit, "... With a faint *CLICK* it opens.").
  describe '#pick_box with the game lines' do
    it 'relocks the box when it opens' do
      pick('With a faint *CLICK* it opens.')
      expect(bput_commands).to eq(["pick my #{box}", "lock my #{box}"])
    end

    it "relocks the box when it isn't locked" do
      pick("The training box isn't locked.")
      expect(bput_commands).to eq(["pick my #{box}", "lock my #{box}"])
    end

    it 'falls back to pick.lic when the lock feels warm' do
      expect { pick('The lock feels warm.') }.to raise_error(SystemExit)
      expect(lockbox).to have_received(:echo).with('Charges used for the day, falling back to pick.lic.')
      expect(DRC).to have_received(:wait_for_script_to_complete).with('pick')
    end

    it 'sends nothing else while no progress is made' do
      pick(progress_line)
      expect(bput_commands).to eq(["pick my #{box}"])
    end
  end

  describe '#pick_box with player lines in the pick window' do
    phrases = ['With a faint *CLICK* it opens.', 'it opens.', "isn't locked", 'The lock feels warm']

    phrases.each do |phrase|
      it "ignores #{phrase.inspect} in ESP, speech and whispers" do
        # A matched warm-lock line would exit the script.
        player_lines(phrase).each { |line| expect { pick(line, progress_line) }.not_to raise_error }
        expect(bput_commands).to eq(["pick my #{box}"] * 3)
        expect(DRC).not_to have_received(:wait_for_script_to_complete)
      end
    end

    it 'still relocks on the game line after a player line' do
      expect { pick(esp('The lock feels warm'), 'With a faint *CLICK* it opens.') }.not_to raise_error
      expect(bput_commands).to eq(["pick my #{box}", "lock my #{box}"])
      expect(lockbox).not_to have_received(:echo)
    end
  end

  describe '#cleanup pick of the worn box' do
    let(:patterns) do
      lockbox.instance_variable_set(:@worn_lockbox, true)
      captured_patterns("pick my #{box}") { lockbox.cleanup }
    end

    it 'matches the game lines' do
      expect(model_bput(['With a faint *CLICK* it opens.'], patterns)).to match(/it opens\./)
      expect(model_bput(["The training box isn't locked."], patterns)).to match(/isn't locked/)
      expect(model_bput([progress_line], patterns)).to match(/not making any progress/)
    end

    it 'does not match the phrases in ESP, speech and whispers' do
      ['it opens.', "isn't locked", 'The lock feels warm', 'not making any progress'].each do |phrase|
        player_lines(phrase).each { |line| expect(model_bput([line], patterns)).to eq('') }
      end
    end
  end
end
