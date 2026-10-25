# frozen_string_literal: true

require_relative 'spec_helper'

# jail-buddy.lic is class-less: the whole script is top-level code that reads
# game lines with script.gets in an endless loop and, on an arrest line, pauses
# every script and walks through the court with waitfor. These specs run the
# real file in a fresh object whose script.gets hands out the given lines in
# order and ends the run when they are used up (an exit ends it too and is
# recorded in @exited). waitfor and DRC.bput are
# modelled on lich-5: waitfor joins its strings with '|' into one /.../i and
# returns the first matching line; bput compiles Strings to /.../i and returns
# the matched text of the first reply line that matches.
#
# script.gets, waitfor and bput see the stripped game stream, which also
# carries other players' ESP, speech and whispers. Every message the script
# acts on must match only the game's own line, not another player's line
# quoting the same words.
RSpec.describe 'jail-buddy.lic' do
  # Ends the script's endless loop.
  let(:run_over) { Class.new(StandardError) }

  # The logs hold no copy of the arrest, court or release messages, so these
  # lines use the script's own words.
  arrest_lines = [
    "Before you really realize what's happening, you are marched off.",
    'The guards wrestle you to the ground, bind you in chains, and drag you off to jail.',
    'You are ushered to a cell, the door opened just long enough for you to be shoved inside.',
    '[Guard House, Jail Cell]',
    'The guard looks you over carefully and leads you firmly off to jail.',
    'A sparkling cloud of silver motes envelops your body like a mist of stars.',
    'Although your head is still ringing from the assault, you realize where you are.',
    'The sentinel brings you to the jail.',
    'You slowly wake up again to find that all your belongings have been stripped.'
  ]
  fine_lines = ['I pronounce a fine upon you of 5 silver Kronars.', 'I hereby fine you a total of 5 silver Kronars.']
  player_prefixes = ['[General][Mallory] "', 'Mallory says, "', 'Mallory whispers, "']

  let(:arrest_line) { '[Guard House, Jail Cell]' }
  let(:plead_line) { 'You may PLEAD INNOCENT or PLEAD GUILTY.' }
  let(:innocent_line) { 'Mallory, this court finds you innocent of the charges brought upon you.' }
  let(:no_crime_line) { 'The magistrate declares that Mallory is guilty of no crime in my district.' }
  let(:pronounce_line) { fine_lines[0] }
  let(:hereby_line) { fine_lines[1] }
  let(:stocks_line) { 'I will send you to the stocks.' }
  let(:free_line) { 'You are free to go.' }
  let(:possessions_line) { 'Pay your debt; your possessions will be in a sack marked with your name.' }
  let(:stocks_done_line) { 'You accept a sack and retrieve the equipment stored inside.' }

  let(:bput_calls) { [] }
  let(:bput_replies) { {} }

  before do
    $test_settings = OpenStruct.new(guilty_plea: 'guilty', sell_loot_money_on_hand: '3 silver')
    $running_scripts = ['go2']
    allow(Room).to receive(:current).and_return(double('room', id: 365, find_nearest: 365))
    allow(Map).to receive(:list).and_return([])
    allow(DRC).to receive(:pause_all).and_return(true)
    allow(DRC).to receive(:unpause_all)
    allow(DRC).to receive(:wait_for_script_to_complete)
    allow(DRCM).to receive(:ensure_copper_on_hand)
    allow(DRCI).to receive(:dispose_trash)
    allow(DRCI).to receive(:put_away_item?).and_return(true)
    allow(DRC).to receive(:bput) do |command, *patterns|
      bput_calls << command
      bput_reply(patterns, bput_replies.fetch(command, []))
    end
  end

  # lich-5 DRC.bput: Strings become /x/i; the first reply line that matches any
  # pattern ends the wait and bput returns the matched text ('' on timeout).
  def bput_reply(patterns, lines)
    regexps = patterns.flatten.map { |p| p.is_a?(Regexp) ? p : /#{p}/i }
    lines.each do |line|
      regexps.each do |re|
        match = line.match(re)
        return match.to_a.first if match
      end
    end
    ''
  end

  def run_script(lines)
    queue = lines.dup
    over = run_over
    reader = Object.new
    reader.define_singleton_method(:gets) { queue.empty? ? raise(over) : queue.shift }
    runner = Object.new
    runner.define_singleton_method(:script) { reader }
    # lich-5 global_defs.rb waitfor.
    runner.define_singleton_method(:waitfor) do |*strings|
      regexpstr = strings.flatten.join('|')
      loop do
        line_in = reader.gets
        return line_in if line_in =~ /#{regexpstr}/i
      end
    end
    path = lic_path('jail-buddy.lic')
    runner.instance_eval(File.read(path), path, 1)
  rescue run_over
    nil
  rescue SystemExit
    @exited = true
  end

  def sent
    messages = []
    messages << sent_messages.pop until sent_messages.empty?
    messages
  end

  define_method(:player_lines) do |text|
    player_prefixes.map { |prefix| %(#{prefix}#{text}") }
  end

  describe 'arrest triggers' do
    arrest_lines.each do |line|
      it "starts the jail routine on the real line #{line.inspect}" do
        run_script([line])
        expect(DRC).to have_received(:pause_all).once
        expect($stopped_scripts).to eq(['go2'])
      end
    end

    it 'ignores the arrest messages in ESP, speech and whispers' do
      run_script(arrest_lines.flat_map { |line| player_lines(line) })
      expect(DRC).not_to have_received(:pause_all)
      expect($stopped_scripts).to be_empty
      expect(displayed_messages).not_to include(a_string_including('JAIL BUDDY HAS YOUR BACK'))
    end
  end

  describe 'court' do
    it 'pleads on the real plea prompt' do
      run_script([arrest_line, plead_line])
      expect(sent).to eq(['plead guilty'])
    end

    it 'does not plead on the plea prompt in ESP, speech and whispers' do
      run_script([arrest_line] + player_lines(plead_line))
      expect(sent).to be_empty
    end

    it 'finishes and resumes scripts on a real innocent verdict' do
      run_script([arrest_line, plead_line, innocent_line])
      expect(DRCM).to have_received(:ensure_copper_on_hand)
      expect(DRC).to have_received(:wait_for_script_to_complete).with('go2', ['365'], force: true)
      expect(DRC).to have_received(:unpause_all)
    end

    it 'finishes on the real no-crime verdict' do
      run_script([arrest_line, plead_line, no_crime_line])
      expect(DRC).to have_received(:unpause_all)
    end

    it 'ignores verdicts in ESP, speech and whispers' do
      verdicts = [innocent_line, no_crime_line, pronounce_line, hereby_line, stocks_line]
      run_script([arrest_line, plead_line] + verdicts.flat_map { |line| player_lines(line) } + [free_line])
      expect(DRCM).not_to have_received(:ensure_copper_on_hand)
      expect(DRC).not_to have_received(:unpause_all)
    end

    fine_lines.each do |fine|
      it "waits for release after the real fine #{fine.inspect} and finishes on the real release line" do
        run_script([arrest_line, plead_line, fine, free_line])
        expect(DRC).to have_received(:unpause_all).once
        expect(DRC).not_to have_received(:wait_for_script_to_complete).with('pay-debt', anything)
      end
    end

    it 'runs pay-debt on the real possessions line' do
      allow(DRC).to receive(:wait_for_script_to_complete) do |name, *_args|
        $right_hand = 'small sack' if name == 'pay-debt'
      end
      bput_replies['look in my sack'] = ['In the small sack you see a steel sword.']
      run_script([arrest_line, plead_line, hereby_line, possessions_line])
      expect(DRC).to have_received(:wait_for_script_to_complete).with('pay-debt', %w[sack therengia])
      expect(DRC).to have_received(:unpause_all)
      expect(@exited).to be_nil
    end

    it 'ignores the release and possessions lines in ESP, speech and whispers' do
      run_script([arrest_line, plead_line, hereby_line] + player_lines(possessions_line) + player_lines(free_line))
      expect(DRC).not_to have_received(:wait_for_script_to_complete).with('pay-debt', anything)
      expect(DRC).not_to have_received(:unpause_all)
      expect(@exited).to be_nil
    end

    it 'waits out the stocks until the real equipment line' do
      allow(DRC).to receive(:fix_standing)
      run_script([arrest_line, plead_line, stocks_line] + player_lines(stocks_done_line))
      expect(DRC).not_to have_received(:fix_standing)
      expect(DRC).not_to have_received(:unpause_all)

      run_script([arrest_line, plead_line, stocks_line, stocks_done_line])
      expect(DRC).to have_received(:fix_standing)
      expect(DRC).to have_received(:unpause_all)
    end
  end

  describe 'emptying the returned sack' do
    before { $right_hand = 'small sack' }

    it 'throws away the sack on the real empty reply' do
      bput_replies['look in my sack'] = ['There is nothing in there.']
      run_script([arrest_line, plead_line, innocent_line])
      expect(DRCI).to have_received(:dispose_trash).with('sack')
    end

    player_prefixes.each do |prefix|
      it "does not throw away a full sack because of #{prefix}There is nothing in there.\"" do
        bput_replies['look in my sack'] = ["#{prefix}There is nothing in there.\"", 'In the small sack you see a steel sword.']
        run_script([arrest_line, plead_line, innocent_line])
        expect(DRCI).not_to have_received(:dispose_trash)
      end
    end

    it 'stows each item by the noun the game accepts' do
      bput_replies['look in my sack'] = ['In the small sack you see a bundle of rope.']
      bput_replies['get rope from my sack'] = ['What were you referring to?']
      bput_replies['get of from my sack'] = ['Please rephrase that command.']
      bput_replies['get bundle from my sack'] = ['You get a bundle of rope from inside your small sack.']
      run_script([arrest_line, plead_line, innocent_line])
      expect(DRCI).to have_received(:put_away_item?).with('bundle')
    end

    player_prefixes.each do |prefix|
      it "does not take #{prefix}You get it.\" as the game accepting the noun" do
        bput_replies['look in my sack'] = ['In the small sack you see a bundle of rope.']
        bput_replies['get rope from my sack'] = ["#{prefix}You get it.\"", 'What were you referring to?']
        bput_replies['get of from my sack'] = ['Please rephrase that command.']
        bput_replies['get bundle from my sack'] = ['You get a bundle of rope from inside your small sack.']
        run_script([arrest_line, plead_line, innocent_line])
        expect(DRCI).to have_received(:put_away_item?).with('bundle')
        expect(DRCI).not_to have_received(:put_away_item?).with('rope')
      end
    end
  end
end
