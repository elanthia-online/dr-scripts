# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

# accept-sell.lic is class-less: the whole script is top-level code. These
# specs run the real file in a fresh object with DRC.bput replaced by a model
# of lich-5's DRC.bput: String patterns become case-insensitive regexes, the
# incoming lines are read in order, the first line matching any pattern wins,
# and bput returns the matched text (or '' when nothing matches).
#
# The values the script tips come from the text bput returns, so every pattern
# must match only the game's own line and not another player's speech, ESP or
# whisper that contains the same words.
RSpec.describe 'accept-sell.lic' do
  # Raised by the model on the second ACCEPT, ending the script's endless loop.
  let(:next_offer) { Class.new(StandardError) }

  let(:accept_line) { "You accept Mallory's offer and are now holding a soft gem pouch." }
  let(:appraisal_line) { "You sort through the gems and finally decide that they're worth a total of about 1000 Kronars." }
  let(:sale_line) { 'Ghendil examines the contents of the soft gem pouch carefully, then hands you 1500 Kronars.' }
  let(:accepted_line) { 'Mallory has accepted your offer and is now holding a soft gem pouch.' }
  let(:declined_line) { 'Mallory has declined the offer.' }

  # Incoming lines per command, one list per time the command is sent.
  def default_replies
    {
      'accept'                => [[accept_line]],
      'app my pouch'          => [[appraisal_line]],
      'sell my pouch'         => [[sale_line]],
      'give pouch to Mallory' => [[accepted_line]]
    }
  end

  def replies
    @replies ||= default_replies
  end

  # Clears the state of a previous run so one example can run the script again.
  def fresh_run
    reset_data
    bput_commands.clear
    @replies = default_replies
  end

  let(:bput_commands) { [] }

  before do
    allow(DRCM).to receive(:minimize_coins).and_return(['5 platinum'])
    allow(DRC).to receive(:bput) do |command, *patterns|
      bput_commands << command
      raise next_offer if command == 'accept' && bput_commands.count('accept') > 1
      raise "sent #{command.inspect} 5 times" if bput_commands.count(command) > 5

      result = model_bput(Array(replies.fetch(command, []).shift), patterns)
      $right_hand = 'pouch' if command == 'accept' && result.start_with?('You accept')
      $right_hand = nil if command.start_with?('give') && result.include?('has accepted')
      result
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

  def run_script
    path = lic_path('accept-sell.lic')
    Object.new.instance_eval(File.read(path), path, 1)
  rescue next_offer, SystemExit
    nil
  end

  def sent
    messages = []
    messages << sent_messages.pop until sent_messages.empty?
    messages
  end

  def esp(text)
    %([General][Bob] "#{text}")
  end

  def say(text)
    %(Bob says, "#{text}")
  end

  def whisper(text)
    %(Bob whispers, "#{text}")
  end

  def player_lines(text)
    [esp(text), say(text), whisper(text)]
  end

  describe 'selling with the real game lines' do
    it 'tips the giver the sale amount and reports the profit over the appraisal' do
      run_script
      expect(sent).to eq([
                           'whisper Mallory This pouch sold for 50% above appraisal, a profit of 5 platinum Kronars',
                           'tip Mallory 1500 Kronars'
                         ])
    end

    it 'reads the amount from the appraiser NPC shape of the sale line' do
      replies['sell my pouch'] = [['The Dwarven appraiser scrutinizes the contents of the black gem pouch carefully, then hands you 43 Kronars.']]
      $parsed_args = OpenStruct.new(skip: true)
      run_script
      expect(sent).to eq(['tip Mallory 43 Kronars'])
    end

    it 'with buy, tips one and a half times the appraisal' do
      $parsed_args = OpenStruct.new(buy: true)
      run_script
      expect(sent).to eq(['stow pouch', 'tip Mallory 1500 Kronars'])
    end

    it 'puts the pouch in the bucket when the giver declines it' do
      replies['give pouch to Mallory'] = [[declined_line]]
      run_script
      expect(sent.last).to eq('put pouch in bucket')
    end

    it 'does nothing when there is no offer' do
      replies['accept'] = [['You have no offers to accept.']]
      run_script
      expect(bput_commands).to eq(%w[accept accept])
      expect(sent).to be_empty
    end
  end

  describe 'player text in the reply window' do
    shared_examples 'ignores player shapes' do |label|
      it "ignores the #{label} line and acts on the game's line" do
        player_lines(spoken).each do |line|
          fresh_run
          $parsed_args = OpenStruct.new(parsed)
          replies[command] = [[line] + replies[command].first]
          run_script
          expect(sent).to eq(expected), "for #{line.inspect}"
        end
      end
    end

    let(:parsed) { {} }

    context 'when the sale window carries a player line with a sale amount' do
      let(:command) { 'sell my pouch' }
      let(:spoken) { 'then hands you 99999 Kronars.' }
      let(:expected) do
        ['whisper Mallory This pouch sold for 50% above appraisal, a profit of 5 platinum Kronars',
         'tip Mallory 1500 Kronars']
      end

      it_behaves_like 'ignores player shapes', 'sale'
    end

    context 'when the sale window carries a player line copying the whole NPC sale line' do
      let(:command) { 'sell my pouch' }
      let(:spoken) { 'Ghendil examines the contents of the soft gem pouch carefully, then hands you 99999 Kronars.' }
      let(:expected) do
        ['whisper Mallory This pouch sold for 50% above appraisal, a profit of 5 platinum Kronars',
         'tip Mallory 1500 Kronars']
      end

      it_behaves_like 'ignores player shapes', 'copied sale'
    end

    context 'when the appraisal window carries a player line with an appraisal amount (buy)' do
      let(:parsed) { { buy: true } }
      let(:command) { 'app my pouch' }
      let(:spoken) { "You sort through the gems and finally decide that they're worth a total of about 99999 Kronars." }
      let(:expected) { ['stow pouch', 'tip Mallory 1500 Kronars'] }

      it_behaves_like 'ignores player shapes', 'appraisal'
    end

    context 'when the appraisal window carries a player line saying the pouch is closed' do
      let(:command) { 'app my pouch' }
      let(:spoken) { "You'll need to open the pouch to examine its contents." }
      let(:expected) do
        ['whisper Mallory This pouch sold for 50% above appraisal, a profit of 5 platinum Kronars',
         'tip Mallory 1500 Kronars']
      end

      it_behaves_like 'ignores player shapes', 'closed pouch'
    end

    context 'when the give window carries a player line saying the giver declined' do
      let(:command) { 'give pouch to Mallory' }
      let(:spoken) { 'Mallory has declined the offer.' }
      let(:expected) do
        ['whisper Mallory This pouch sold for 50% above appraisal, a profit of 5 platinum Kronars',
         'tip Mallory 1500 Kronars']
      end

      it_behaves_like 'ignores player shapes', 'declined'
    end

    context 'when the accept window carries a player line claiming an accepted offer' do
      it 'treats it as no offer and sends nothing' do
        player_lines("You accept Mallory's offer and are now holding a soft gem pouch.").each do |line|
          fresh_run
          replies['accept'] = [[line, 'You have no offers to accept.']]
          run_script
          expect(bput_commands).to eq(%w[accept accept]), "for #{line.inspect}"
          expect(sent).to be_empty
        end
      end
    end
  end
end
