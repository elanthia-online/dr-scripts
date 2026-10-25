# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('locksmithing.lic', 'Locksmithing')

# Locksmithing#pick_box sends `pick my <trainer>` and picks a branch from the
# line DRC.bput returns: close and relock, stop, or throw the trainer away.
# DRC.bput is replaced by a model of lich-5's DRC.bput: String patterns become
# case-insensitive regexes, the incoming lines are read in order, the first
# line matching any pattern wins, and bput returns the matched text (or ''
# when nothing matches).
#
# The reply patterns must match only the game's own line, not another
# player's speech, ESP or whisper that contains the same words.
RSpec.describe Locksmithing do
  let(:trainer) { 'locksmith box' }
  let(:locksmith) { Locksmithing.allocate }
  let(:bput_commands) { [] }
  let(:progress_line) { 'You are not making any progress on the lock.' }

  # Incoming lines for each `pick` command, one list per pick.
  let(:pick_replies) { [] }

  before do
    locksmith.instance_variable_set(:@worn_trashcan, 'bucket')
    locksmith.instance_variable_set(:@worn_trashcan_verb, 'put')
    locksmith.instance_variable_set(:@pick_once, false)
    @held = true
    allow(DRCI).to receive(:in_hands?) { @held }
    allow(DRCI).to receive(:dispose_trash)
    allow(DRC).to receive(:message)
    allow(DRC).to receive(:bput) do |command, *patterns|
      bput_commands << command
      next 'You close' unless command.start_with?('pick ')

      raise "sent #{command.inspect} more than 5 times" if bput_commands.count(command) > 5

      lines = pick_replies.shift || []
      # The trainer is put down once the scripted picks run out.
      @held = false if pick_replies.empty?
      model_bput(lines, patterns)
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

  def pick(*replies)
    @held = true
    pick_replies.concat(replies)
    locksmith.pick_box(trainer)
  end

  def picks
    bput_commands.count("pick my #{trainer}")
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

  # The text corpus has no trainer replies, so the game lines below put each
  # phrase at the start of the line and after narrative text without a quote
  # (the shape of the one corpus hit, "... With a faint *CLICK* it opens.").
  describe 'with the game lines' do
    it 'throws the trainer away when the lock looks weak' do
      pick(['The lock looks weak.'])
      expect(DRCI).to have_received(:dispose_trash).with(trainer, 'bucket', 'put')
      expect(picks).to eq(1)
    end

    it 'throws the trainer away when the weak-lock message follows other text' do
      pick(['With a faint *CLICK* the lock gives way.  The lock looks weak.'])
      expect(DRCI).to have_received(:dispose_trash).with(trainer, 'bucket', 'put')
    end

    it 'stops without throwing the trainer away when the lock feels warm' do
      pick(['The lock feels warm.'])
      expect(DRC).to have_received(:message).with('Charges Burned, moving on.')
      expect(DRCI).not_to have_received(:dispose_trash)
      expect(picks).to eq(1)
    end

    it 'closes and relocks the trainer when it opens, then picks again' do
      pick(['With a faint *CLICK* it opens.'], [progress_line])
      expect(bput_commands).to eq(["pick my #{trainer}", "close my #{trainer}", "lock my #{trainer}", "pick my #{trainer}"])
    end

    it 'stops after one opening with the once argument' do
      locksmith.instance_variable_set(:@pick_once, true)
      allow(DRC).to receive(:retreat).and_return(false)
      pick(['With a faint *CLICK* it opens.'], [progress_line])
      expect(picks).to eq(1)
      expect(locksmith.instance_variable_get(:@once_picked_twice_shy)).to be(true)
    end

    it "closes and relocks the trainer when it isn't locked" do
      pick(["The locksmith box isn't locked."])
      expect(bput_commands).to eq(["pick my #{trainer}", "close my #{trainer}", "lock my #{trainer}"])
    end

    it 'closes and relocks the trainer when told to close it' do
      pick(['Maybe you should close the locksmith box first.'])
      expect(bput_commands).to eq(["pick my #{trainer}", "close my #{trainer}", "lock my #{trainer}"])
    end

    it 'keeps picking while no progress is made' do
      pick([progress_line], [progress_line], [progress_line])
      expect(picks).to eq(3)
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'stops on a box that shares the noun' do
      pick(["It's not even locked, why bother?"])
      expect(DRC).to have_received(:message).with(/is not a valid option but shares a noun/)
      expect(picks).to eq(1)
    end

    it 'stops when the trainer is not held' do
      pick(["But you aren't holding that."])
      expect(DRC).to have_received(:message).with(/may not be specific enough/)
      expect(picks).to eq(1)
    end

    it 'exits without lockpicks' do
      expect { pick(['You need some type of tool to pick most locks.']) }.to raise_error(SystemExit)
    end

    it 'treats Pick what? as no branch and picks again' do
      pick(['Pick what?'], [progress_line])
      expect(picks).to eq(2)
    end
  end

  describe 'with player lines in the pick window' do
    phrases = ['The lock looks weak', 'The lock feels warm', 'With a faint *CLICK* it opens.', "isn't locked",
               'Maybe you should close', 'why bother', "But you aren't holding", 'You need some type of tool to pick',
               'Pick what']

    phrases.each do |phrase|
      it "ignores #{phrase.inspect} in ESP, speech and whispers" do
        # A matched lockpick-missing line would exit the script.
        player_lines(phrase).each { |line| expect { pick([line, progress_line]) }.not_to raise_error }
        expect(picks).to eq(3)
        expect(DRCI).not_to have_received(:dispose_trash)
        expect(DRC).not_to have_received(:message)
        expect(bput_commands.uniq).to eq(["pick my #{trainer}"])
      end
    end

    it 'still throws the trainer away on the game line after a player line' do
      pick([esp('The lock feels warm'), 'The lock looks weak.'])
      expect(DRCI).to have_received(:dispose_trash).with(trainer, 'bucket', 'put')
      expect(DRC).not_to have_received(:message)
    end
  end
end
