# frozen_string_literal: true

require_relative 'spec_helper'

load_lic_class('su-helmas.lic', 'SuHelmas')

# su-helmas waits in the catacombs for the room and NPC lines it registered as
# Flags, then acts on them. Lich tests every Flags matcher against every game
# line, including other players' speech, whispers and ESP, so each matcher must
# match only the game's own line.
RSpec.describe SuHelmas do
  let(:helmas) { SuHelmas.allocate }

  # Raised by the stubbed pause once every queued line has been delivered,
  # ending the script's wait loop.
  let(:out_of_lines) { Class.new(StandardError) }

  before(:each) do
    reset_data
    allow(DRC).to receive(:message)
  end

  # Feed a server line through the registered Flags matchers, the way
  # Lich's DRParser.check_events does for every downstream line.
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

  # Model of lich-5's DRC.bput: String patterns become case-insensitive
  # regexes, lines are read in order, the first line matching any pattern wins
  # and bput returns the matched text ('' when nothing matches).
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

  describe '#run_short_maze' do
    # Runs the wait loop with each line arriving during one pause. Returns what
    # the script did, and whether the loop ended because the task was done.
    def run_maze(*lines)
      queue = lines.dup
      actions = []
      allow(helmas).to receive(:join_empath) { actions << :join_empath }
      allow(helmas).to receive(:stow_loot) { |item| actions << [:stow, item] }
      allow(helmas).to receive(:warn_need_weapon) { actions << :warn_need_weapon }
      allow(helmas).to receive(:waitrt?)
      allow(helmas).to receive(:fput) { |command| actions << command }
      allow(helmas).to receive(:pause) do
        raise out_of_lines if queue.empty?

        deliver(queue.shift)
      end
      finished = begin
        helmas.run_short_maze
        true
      rescue out_of_lines
        false
      end
      { actions: actions, finished: finished }
    end

    # Each task's phrase in a room line the game sends, and the command the
    # script answers it with. The phrases are the script's own; the text around
    # them is reconstructed (no capture of these rooms exists).
    room_lines = {
      'search'   => 'Something unseen moves in the dark, enough to tickle at the frayed edges of sanity.',
      'sit seat' => 'In the center of the lit area is a metal seat, bolted to the floor.',
      'meditate' => "The silence is calming, but it's certainly enough to make someone scream, too.",
      'climb'    => 'Carvings cover the granite slab at the center of the sunken pit.',
      'dodge'    => 'Thorny vines lash across the passage, and past the vines you see a lit chamber beckoning.',
      'crawl'    => 'A low tunnel is the only way on, and there is little sense moving forward until this is dealt with.',
      'smite'    => 'The seed might well be the only thing in the world right now.'
    }
    barrier_line = 'A shimmering magical barrier blocks further travel down the cold passageway.'
    weapon_line = 'You see a weakness in the barrier, but being unarmed you have no way to exploit the weakness.'
    # The guide's line on return, as quoted in the Genie quest triggers on Elanthipedia.
    reward_line = 'Your guide enthusiastically greets you as you return, "Well done!  Here, I have something for you!"  ' \
                  'Your guide shoves a violet-hued gem into your left hand.'
    done_text = "Thanks for all the hard work.  Here's a little something to show my appreciation."

    room_lines.each do |command, line|
      it "sends #{command.inspect} for the game's room line" do
        expect(run_maze(line)[:actions]).to eq([:join_empath, command])
      end

      it "sends #{command.inspect} for the room line after leading XML tags" do
        expect(run_maze("<style id=\"roomDesc\"/>#{line}")[:actions]).to eq([:join_empath, command])
      end
    end

    it 'breaks or invokes at the barrier line depending on the guild' do
      DRStats.guild = 'Barbarian'
      expect(run_maze(barrier_line)[:actions]).to eq([:join_empath, 'break'])
      DRStats.guild = 'Cleric'
      expect(run_maze(barrier_line)[:actions]).to eq([:join_empath, 'invoke'])
    end

    it "warns about a weapon on the game's unarmed line" do
      expect(run_maze(weapon_line)[:actions]).to eq(%i[join_empath warn_need_weapon])
    end

    it "stows the reward and joins the empath again on the guide's line" do
      $left_hand = 'violet-hued gem'
      expect(run_maze(reward_line)[:actions]).to eq([:join_empath, [:stow, 'violet-hued gem'], :join_empath])
    end

    it "stows the reward when the guide's line arrives as a speech preset" do
      line = "<preset id='speech'>Your guide enthusiastically greets you as you return</preset>, " \
             '"Well done!  Here, I have something for you!"'
      expect(run_maze(line)[:actions]).to eq([:join_empath, [:stow, nil], :join_empath])
    end

    [
      done_text,
      "An empath wreathed in violet robes says, \"#{done_text}\"",
      "Your guide says, \"#{done_text}\"",
      "<preset id='speech'>The violet empath says</preset>, \"#{done_text}\""
    ].each do |line|
      it "ends the run on the task's done line: #{line[0, 40].inspect}" do
        expect(run_maze(line)).to eq(actions: [:join_empath], finished: true)
      end
    end

    # Other players' text, in the shapes the game delivers it to Flags.
    def player_shapes(text)
      [
        %([General][Mallory] "#{text}"),
        %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
        %(Mallory says, "#{text}"),
        %(<preset id='speech'>Mallory says</preset>, "#{text}"),
        %(Mallory whispers, "#{text}"),
        %(Mallory says to an empath wreathed in violet robes, "#{text}"),
        %(Mallory asks your guide, "#{text}")
      ]
    end

    (room_lines.values + [barrier_line, weapon_line, reward_line, done_text,
                          "An empath wreathed in violet robes says, \"#{done_text}\""]).each do |text|
      it "ignores another player's speech, whisper and ESP of #{text[0, 40].inspect}" do
        player_shapes(text).each do |line|
          expect(run_maze(line)).to eq(actions: [:join_empath], finished: false), "acted on #{line.inspect}"
        end
      end
    end

    it 'still acts on the real line in the same server chunk as a player line' do
      chunk = %(Mallory says, "Here, I have something for you!"\n#{room_lines['climb']})
      expect(run_maze(chunk)[:actions]).to eq([:join_empath, 'climb'])
    end
  end

  describe '#join_empath' do
    let(:joined) { 'An empath wreathed in violet robes summons a guide, who leads you deep into the catacombs.  Gesturing to an opening, the guide leaves.' }
    let(:busy) { 'An empath wreathed in violet robes says, "Sorry, I\'m quite busy.  Come back later."' }
    let(:not_here) { 'What were you referring to?' }

    # Runs join_empath with one list of incoming lines per JOIN sent.
    # Returns what the script did.
    def join_with(*replies)
      actions = []
      allow(DRCT).to receive(:walk_to)
      allow(helmas).to receive(:redeem_contract) { actions << :redeem_contract }
      allow(DRC).to receive(:bput) do |command, *patterns|
        actions << command
        raise "sent #{command.inspect} too often" if actions.count(command) > replies.size

        model_bput(replies[actions.count(command) - 1], patterns)
      end
      begin
        helmas.join_empath
      rescue SystemExit
        actions << :exit
      end
      actions
    end

    it 'stops after the join line' do
      expect(join_with([joined])).to eq(['join empath'])
    end

    it 'redeems a contract and joins again when the empath is busy' do
      expect(join_with([busy], [joined])).to eq(['join empath', :redeem_contract, 'join empath'])
    end

    it 'exits when there is no empath' do
      expect(join_with([not_here])).to eq(['join empath', :exit])
    end

    [
      %([General][Mallory] "Sorry, I'm quite busy"),
      %(Mallory says, "What were you referring to?"),
      %(Mallory whispers, "who leads you deep into the catacombs"),
      %(Mallory says, "An empath wreathed in violet robes says, \\"Sorry, I'm quite busy.\\""),
      %(Mallory says to an empath wreathed in violet robes, "Sorry, I'm quite busy")
    ].each do |line|
      it "answers the game's reply, not another player's line before it: #{line[0, 40].inspect}" do
        expect(join_with([line, joined])).to eq(['join empath'])
        expect(join_with([line, busy], [joined])).to eq(['join empath', :redeem_contract, 'join empath'])
        expect(join_with([line, not_here])).to eq(['join empath', :exit])
      end
    end
  end
end
