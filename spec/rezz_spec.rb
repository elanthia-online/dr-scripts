# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('rezz.lic', 'Rezz')

# rezz.lic decides whether to rejuvenate, resurrect, skip or vigil a body from
# Flags set by the perceive, infuse and cast output, and from the lines its
# bputs return. These specs run the real script (Rezz#initialize) against a
# small model of the game:
#
# - every incoming line is fed through the registered Flags matchers the way
#   lich-5 DRParser.check_events does (raw line, first matching regex per key);
# - DRC.bput reads the same lines with tags stripped, String patterns become
#   /x/i, the first line matching any pattern ends the window and bput returns
#   the matched text; lines after it arrive only after the script has moved on.
#
# Every decision must come from the game's own lines, not from the same words
# in another player's speech, whisper or ESP.
RSpec.describe Rezz do
  let(:victim) { 'Victim' }

  # Real perceive output for a dead, unrejuvenated body (samples/rezz.lic).
  let(:perc_dead) do
    ['His soul is not bound to his body.',
     'His body will decay in about 1 hour.',
     "#{victim} has gained a few favors with his god.",
     'Roundtime: 5 sec.']
  end
  let(:favors_line) { "#{victim} has gained a few favors with his god." }
  let(:found_line) { "You can sense the spirit of #{victim} in the Void." }
  let(:not_found_line) { 'You sense a spirit nearby, but you are unable to make it out clearly.' }
  # Only the script's own pattern is known for these lines; the rest of the
  # wording is assumed.
  let(:look_line) { "You take a moment to look for everybody in the area and see the body of #{victim} (dead)." }
  let(:broken_line) { 'You cannot restore the gift of life to a body that badly broken.' }

  let(:replies) { Hash.new { |hash, command| hash[command] = [] } }
  let(:casts) { [] }
  let(:commands) { [] }

  # Lines the game sends back when a spell is cast, keyed by its abbrev.
  let(:cast_replies) do
    { 'REJUV' => ["A thin silver nimbus surrounds #{victim}."],
      'rejuv' => ["A thin silver nimbus surrounds #{victim}."] }
  end

  before do
    build_world
    allow(DRC).to receive(:bput) { |command, *patterns| game_bput(command, patterns) }
    allow(DRCA).to receive(:cast_spell?) do |spell, _settings|
      arrive_late
      casts << spell['abbrev']
      raise 'cast loop did not end' if casts.size > 20

      cast_replies.fetch(spell['abbrev'], []).each { |line| deliver(line) }
      true
    end
  end

  # A dead body and the game's replies for a full run. Each player-line shape
  # below runs the script again from a clean world, so this is also called
  # after reset_data.
  def build_world
    @late = nil
    [replies, casts, commands].each(&:clear)
    DRStats.guild = 'Cleric'
    DRStats.mana = 100
    $test_settings = OpenStruct.new(
      osrel_no_harness: true,
      waggle_sets: { 'rezz' => { 'Resurrection' => { 'abbrev' => 'REZZ', 'mana' => 40 },
                                 'Rejuvenation' => { 'abbrev' => 'REJUV', 'mana' => 25 } } }
    )
    $test_data.spells = OpenStruct.new(cast_messages: ['You gesture'])
    replies['look people'] << [look_line]
    replies["perc #{victim}"] << perc_dead
    replies['infuse rezz 40'] << [found_line]
    replies["gesture #{victim}"] << ['Roundtime: 3 sec.']
  end

  def fresh_world
    reset_data
    build_world
  end

  # lich-5 DRParser.check_events over one raw server line.
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

  # Lines after the one that ended a bput window reach Flags only once the
  # script has acted on that bput.
  def arrive_late
    (@late || []).each { |line| deliver(line) }
    @late = nil
  end

  def game_bput(command, patterns)
    arrive_late
    commands << command
    raise "sent #{command.inspect} too often" if commands.count(command) > 20

    regexes = patterns.flatten.map { |item| item.is_a?(Regexp) ? item : /#{item}/i }
    lines = replies[command].shift || []
    lines.each_with_index do |raw, index|
      deliver(raw)
      text = raw.gsub(/<[^>]+>/, '')
      regexes.each do |regex|
        next unless (match = text.match(regex))

        @late = lines[(index + 1)..]
        return match.to_a.first
      end
    end
    ''
  end

  def run_rezz
    rezz = Rezz.allocate
    rezz.instance_variable_set(:@infuse_attempts, 0) # nil + 1 is masked by Lich's NilClass patch
    rezz.define_singleton_method(:checkprep) { 'None' }
    rezz.send(:initialize)
    arrive_late
    rezz
  end

  def said
    messages = []
    messages << sent_messages.pop until sent_messages.empty?
    messages
  end

  # Other players' lines as Flags (raw XML) and bput (tags stripped) receive them.
  def player_lines(text)
    {
      'ESP'     => %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
      'say'     => %(<preset id='speech'>Mallory says</preset>, "#{text}"),
      'whisper' => %(<pushStream id="whispers"/><preset id="whisper">Mallory whispers,</preset> "#{text}")
    }
  end

  describe 'with only the game lines' do
    it 'rejuvenates, resurrects, soul-binds and rejuvenates again' do
      run_rezz
      expect(casts).to eq(%w[REJUV REZZ sb rejuv])
      expect(commands).to eq(['look people', "perc #{victim}", 'infuse rezz 40', "gesture #{victim}"])
    end

    it 'skips a body with no favors' do
      replies["perc #{victim}"] = [['His soul is not bound to his body.', "#{victim} has no favor with his god!"]]
      run_rezz
      expect(casts).to eq(['REJUV'])
      expect(displayed_messages).to include("*** #{victim} has no favors! ***")
    end

    it 'skips a necromancer' do
      replies["perc #{victim}"] = [['His soul is not bound to his body.', "#{victim} has no protection from the gods' judgment.", favors_line]]
      run_rezz
      expect(displayed_messages).to include("*** #{victim} is a necro! ***")
      expect(casts).not_to include('REZZ')
    end

    it 'leaves a living character alone' do
      replies["perc #{victim}"] = [[favors_line]]
      run_rezz
      expect(casts).to be_empty
      expect(displayed_messages).to include("*** #{victim} is already alive, dumbass! ***")
    end

    it 'does not cast Rejuvenation again on a body that already has it' do
      replies["perc #{victim}"] = [["As you concentrate, a thin silver nimbus flickers into view around #{victim}'s head.  You sense the Rejuvenation spell upon him, guarding his memories from further decay."] + perc_dead]
      run_rezz
      expect(casts).to eq(%w[REZZ sb rejuv])
    end

    it 'casts Vigil on a decaying body' do
      replies["perc #{victim}"] = [['His soul is not bound to his body.', 'His body will decay in less than a minute.', favors_line]]
      run_rezz
      expect(casts.first(2)).to eq(%w[vigil REJUV])
    end

    it 'casts Vigil when the body starts to rot during the search' do
      replies['infuse rezz 40'] = [["#{victim}'s body grows paler.", not_found_line], [found_line]]
      run_rezz
      # The flag stays set, so every later infuse casts Vigil too.
      expect(casts).to eq(%w[REJUV REZZ vigil vigil sb rejuv])
    end

    it 'keeps infusing until the spirit is found' do
      replies['infuse rezz 40'] = [[not_found_line], ["You struggle to sense the spirit of #{victim} in the Void.  You see ethereal cords of silver tethering his soul to his body."]]
      run_rezz
      expect(commands.count('infuse rezz 40')).to eq(2)
      expect(casts.last(2)).to eq(%w[sb rejuv])
    end

    it 'announces a body too broken to raise' do
      replies["gesture #{victim}"] = [[broken_line, 'Roundtime: 3 sec.']]
      run_rezz
      expect(said).to eq(["'#{victim} still needs healing."])
    end
  end

  describe 'ignores other players repeating game lines' do
    {
      'no favors'      => 'Victim has no favor with his god!',
      'necromancer'    => "Victim has no protection from the gods' judgment.",
      'favor standing' => 'Victim has gained a few favors with his god.'
    }.each do |label, text|
      it "resurrects a dead body when someone says the #{label} line during the perceive" do
        player_lines(text).each_value do |line|
          fresh_world
          replies["perc #{victim}"] = [[line] + perc_dead]
          run_rezz
          expect(casts).to eq(%w[REJUV REZZ sb rejuv]), "#{line}: cast #{casts}"
        end
      end
    end

    it 'leaves a living character alone when someone says the soul line' do
      player_lines('His soul is bound to his body.').each_value do |line|
        fresh_world
        replies["perc #{victim}"] = [[line, favors_line]]
        run_rezz
        expect(casts).to be_empty, "#{line}: cast #{casts}"
      end
    end

    ['A thin silver nimbus surrounds Victim.', 'his memories are protected from loss by the Resumption spell'].each do |text|
      it "still rejuvenates when someone says '#{text}'" do
        player_lines(text).each_value do |line|
          fresh_world
          replies["perc #{victim}"] = [[line] + perc_dead]
          run_rezz
          expect(casts).to eq(%w[REJUV REZZ sb rejuv]), "#{line}: cast #{casts}"
        end
      end
    end

    it 'does not cast Vigil when someone says a decay line' do
      player_lines('it will decay in less than a minute').each_value do |line|
        fresh_world
        replies["perc #{victim}"] = [[line] + perc_dead]
        run_rezz
        expect(casts).not_to include('vigil'), "#{line}: cast #{casts}"
      end
    end

    it "does not cast Vigil when someone says the patient's body is rotting" do
      player_lines("Victim's body grows paler").each_value do |line|
        fresh_world
        replies['infuse rezz 40'] = [[line, found_line]]
        run_rezz
        expect(casts).to eq(%w[REJUV REZZ sb rejuv]), "#{line}: cast #{casts}"
      end
    end

    it 'keeps infusing when someone says the spirit was found' do
      player_lines('I see the spirit of Victim in the Void').each_value do |line|
        fresh_world
        replies['infuse rezz 40'] = [[line, not_found_line], [found_line]]
        run_rezz
        expect(commands.count('infuse rezz 40')).to eq(2), line
      end
    end

    it 'does not announce a broken body when someone says so' do
      player_lines('gift of life to a body that badly broken').each_value do |line|
        fresh_world
        replies["gesture #{victim}"] = [[line, 'Roundtime: 3 sec.']]
        run_rezz
        expect(said).to be_empty, line
      end
    end

    it 'still announces a broken body when someone says Roundtime first' do
      player_lines('Roundtime').each_value do |line|
        fresh_world
        replies["gesture #{victim}"] = [[line, broken_line, 'Roundtime: 3 sec.']]
        run_rezz
        expect(said).to eq(["'#{victim} still needs healing."]), line
      end
    end

    it 'perceives the body the game lists, not one named by another player' do
      player_lines('You take a moment to look for everybody in the area and see the body of Mallory (dead).').each_value do |line|
        fresh_world
        replies['look people'] = [[line, look_line]]
        run_rezz
        expect(commands).to include("perc #{victim}"), "#{line}: #{commands}"
        expect(commands).not_to include('perc Mallory')
      end
    end
  end
end
