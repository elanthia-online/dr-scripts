# frozen_string_literal: true

require 'json'
require 'tempfile'

# Self-tests of the replay support in test/: ReplayGame (a game played from
# real log lines), ReplayCommons (an API-level model of the commons helpers),
# ArgParserModel (lich-5's ArgParser), ReplayTranscript (a real run's replies
# from a transcript fixture) and spec_helper's run_lic_entry. Each
# example names the lich-5 line (at 480bdee3) the model imitates, so a script
# spec built on them tests the script, not the model.
#
# Every game line is a real log line, ReplayGame.log('<log>:<line>'), from
# spec/fixtures/replay_game/log_lines.json, or is built with ReplayGame.code
# and says where from.
RSpec.describe 'test harness replay support' do
  let(:game) { ReplayGame.new.install(self) }

  # The real reply to `mix my heavy cauldron with my mixing stick` at
  # 26:6737: the mix line, Roundtime, then the completion line after it.
  let(:final_mix_reply) { [ReplayGame.log('26:6738'), ReplayGame.log('26:6740'), ReplayGame.log('26:6742')] }

  describe 'ReplayGame lines' do
    it 'reads a cited line from the fixtures' do
      line = ReplayGame.log('26:6742')
      expect([line.text, line.label, line.code?])
        .to eq(['Applying the final touches, you complete working on a belradi elixir.', '26:6742', false])
    end

    it 'refuses a cite no fixture holds' do
      expect { ReplayGame.log('26:1') }.to raise_error(ArgumentError, /"26:1" is in no fixture/)
    end

    it 'labels a line built from code as CODE-DERIVED with its source' do
      line = ReplayGame.code('That craftable requires more pieces of that plant to begin.', from: 'R:290')
      expect([line.label, line.code?]).to eq(['CODE-DERIVED(R:290)', true])
    end

    it 'refuses a code-derived line that does not say where it comes from' do
      expect { ReplayGame.code('anything', from: ' ') }.to raise_error(ArgumentError, /needs from:/)
    end

    it 'refuses a bare string as a reply line' do
      expect { game.script('look', 'You see nothing.') }.to raise_error(ArgumentError, /ReplayGame.log or ReplayGame.code/)
    end

    describe '.load_log_lines' do
      def fixture(content)
        file = Tempfile.new(['log_lines', '.json'])
        file.write(JSON.generate(content))
        file.close
        (@tempfiles ||= []) << file # keeps the file from being unlinked by GC
        file.path
      end

      it 'merges fixtures and skips metadata keys' do
        paths = [fixture('_source' => 'x', '25:1' => 'a'), fixture('25:1' => 'a', '26:2' => 'b')]
        expect(ReplayGame.load_log_lines(paths)).to eq('25:1' => 'a', '26:2' => 'b')
      end

      it 'refuses two fixtures that give one cite different texts' do
        paths = [fixture('25:1' => 'a'), fixture('25:1' => 'b')]
        expect { ReplayGame.load_log_lines(paths) }.to raise_error(ArgumentError, /25:1 has another text/)
      end

      it 'refuses a key that is not a <log>:<line> cite' do
        expect { ReplayGame.load_log_lines([fixture('line 3' => 'a')]) }.to raise_error(ArgumentError, /not a <log>:<line> cite/)
      end
    end
  end

  describe 'ReplayGame#bput (model of DRC.bput, common.rb:179-288)' do
    before { game } # installed even where nothing is scripted (silence)

    it 'returns on the first matching LINE, even when a later line matches a pattern listed first (:261-276)' do
      game.script('mix my heavy cauldron with my mixing stick', *final_mix_reply)
      result = DRC.bput('mix my heavy cauldron with my mixing stick', '^Applying the final touches', /^[^"]*?Roundtime:/i)
      expect(result).to eq('Roundtime:')
    end

    it 'returns the matched text, not the whole line (match.to_a.first, :275)' do
      game.script("get my pewter ingot from my botanist's toolbag", ReplayGame.log('26:39162'))
      # The String pattern becomes /What were you referring to?/i (:197), where
      # "?" makes the "o" optional, so the question mark is not in the match.
      expect(DRC.bput("get my pewter ingot from my botanist's toolbag", 'What were you referring to?'))
        .to eq('What were you referring to')
    end

    it 'turns String patterns into case-insensitive Regexps (:197)' do
      game.script('mix my heavy cauldron with my mixing stick', *final_mix_reply)
      expect(DRC.bput('mix my heavy cauldron with my mixing stick', 'APPLYING THE FINAL')).to eq('Applying the final')
    end

    it 'accepts an options Hash before the patterns (:180)' do
      game.script('mix my heavy cauldron with my mixing stick', *final_mix_reply)
      expect(DRC.bput('mix my heavy cauldron with my mixing stick', { 'timeout' => 5 }, 'Roundtime')).to eq('Roundtime')
    end

    it "returns '' after a 15 s stall and records lich-5's no-match message when the game is silent (:72, :280-287)" do
      expect(DRC.bput('turn my heavy cauldron', 'Roundtime')).to eq('')
      expect(game.clock).to eq(15.0)
      expect(game.diagnostics).to eq(["DRC: No match was found after 15 seconds for command 'turn my heavy cauldron' (0 lines seen)"])
    end

    it "times out the same way when lines arrive but none matches, and honours 'timeout' and 'suppress_no_match'" do
      game.script('mix my heavy cauldron with my mixing stick', *final_mix_reply)
      result = DRC.bput('mix my heavy cauldron with my mixing stick', { 'timeout' => 4, 'suppress_no_match' => true }, 'You toss')
      expect([result, game.clock, game.diagnostics]).to eq(['', 4.0, []])
    end

    it 'waits out a "...wait N seconds." line and resends the command once (:221-224, 25:11582 then 25:11587)' do
      command = "put my wire brush in my botanist's toolbag"
      game.script(command, ReplayGame.log('25:11582'))
      game.script(command, ReplayGame.log('25:11587'))
      expect(DRC.bput(command, '^You put your')).to eq('You put your')
      expect(game.sent).to eq([command, command])
      expect(game.clock).to eq(1.0)
    end

    it 'reads the lines that came with the wait before the resend reply, skipping wait lines (:211, :301-311)' do
      command = 'mix my heavy cauldron with my mixing stick'
      game.script(command, ReplayGame.log('25:11582'), ReplayGame.log('26:6740'), ReplayGame.log('25:11582'))
      game.script(command, *final_mix_reply)
      expect(DRC.bput(command, 'Roundtime: \d+ sec', 'With wide strokes')).to eq('Roundtime: 9 sec')
      expect(game.sent).to eq([command, command])
    end

    # 25:11582 twice in one reply: the second copy stands for a later wait
    # line read during the hold (the model's arrangement, not a logged pair).
    it 'resends once, not once per wait line, when a wait line came with the wait (:211 skips a replayed wait line)' do
      command = 'mix my heavy cauldron with my mixing stick'
      game.script(command, ReplayGame.log('25:11582'), ReplayGame.log('25:11582'), ReplayGame.log('26:6740'))
      game.script(command, ReplayGame.log('26:6738'))
      expect(DRC.bput(command, 'Roundtime: \d+ sec')).to eq('Roundtime: 9 sec')
      expect([game.sent, game.clock]).to eq([[command, command], 1.0])
    end

    it 'drops lines left over from the last command before sending (clear, :198)' do
      game.script('mix my heavy cauldron with my mixing stick', *final_mix_reply)
      DRC.bput('mix my heavy cauldron with my mixing stick', 'Roundtime')
      # 26:6742 was still unread; the next bput must not see it.
      expect(DRC.bput('turn my heavy cauldron', 'Applying the final touches')).to eq('')
    end

    it 'strips XML tags from what bput reads (lich-5 games.rb:1139)' do
      tagged = ReplayGame.code("<pushBold/>#{ReplayGame.log('26:6742').text}<popBold/>", from: '26:6742 wrapped in tags; Genie client logs carry no XML')
      game.script('mix my heavy cauldron with my mixing stick', tagged)
      expect(DRC.bput('mix my heavy cauldron with my mixing stick', '^Applying the final touches'))
        .to eq('Applying the final touches')
    end
  end

  describe 'Flags (model of DRParser.check_events, drparser.rb:145-155)' do
    it 'catches a line that arrives after the line bput returned on (26:6740 then 26:6742)' do
      Flags.add('replay-done', /Applying the final touches/)
      game.script('mix my heavy cauldron with my mixing stick', *final_mix_reply)
      expect(DRC.bput('mix my heavy cauldron with my mixing stick', 'Roundtime:')).to eq('Roundtime:')
      expect(Flags['replay-done']).to be_a(MatchData)
      expect(game.flag_sets).to eq([%w[replay-done 26:6742]])
    end

    it 'sees the raw line with its XML, which bput does not' do
      Flags.add('replay-bold', %r{\A<pushBold/>Applying})
      tagged = ReplayGame.code("<pushBold/>#{ReplayGame.log('26:6742').text}", from: '26:6742 wrapped in a tag; Genie client logs carry no XML')
      game.script('mix my heavy cauldron with my mixing stick', tagged)
      DRC.bput('mix my heavy cauldron with my mixing stick', 'Applying')
      expect(Flags['replay-bold'][0]).to eq('<pushBold/>Applying')
    end

    it 'matches a Flag against the line with object links removed, as DRParser.match_line does (drparser.rb:124-139, :582-584)' do
      Flags.add('replay-put', /^You put your brush in/)
      linked = ReplayGame.code(%(You put your <a exist="1" noun="brush">brush</a> in your botanist's toolbag.),
                               from: "25:11587 with a DR object link; Genie client logs carry no XML")
      game.script("put my brush in my botanist's toolbag", linked)
      DRC.bput("put my brush in my botanist's toolbag", '^You put your')
      expect(Flags['replay-put'][0]).to eq('You put your brush in')
    end

    it 'collapses doubled bold for a Flag, as DRParser.match_line does (drparser.rb:125-126, :138)' do
      Flags.add('replay-bold', %r{\A<pushBold/>Applying[^<]*touches<popBold/>\z})
      tagged = ReplayGame.code("<pushBold/><pushBold/>Applying the final touches<popBold/><popBold/>",
                               from: '26:6742 cut short, in doubled bold; Genie client logs carry no XML')
      game.script('mix my heavy cauldron with my mixing stick', tagged)
      DRC.bput('mix my heavy cauldron with my mixing stick', 'Applying')
      expect(Flags['replay-bold'][0]).to eq('<pushBold/>Applying the final touches<popBold/>')
    end

    it "records only the first of a flag's patterns that matches a line" do
      Flags.add('replay-done', /final touches/, /Applying/)
      game.script('mix my heavy cauldron with my mixing stick', *final_mix_reply)
      DRC.bput('mix my heavy cauldron with my mixing stick', 'Roundtime')
      expect(Flags['replay-done'].regexp).to eq(/final touches/)
    end

    it 'sets a flag on a line that came with no command, sending nothing and taking no time (#unprompted)' do
      Flags.add('replay-done', /Applying the final touches/)
      game.unprompted(ReplayGame.log('26:6742'))
      expect(Flags['replay-done']).to be_a(MatchData)
      expect([game.sent, game.clock, game.flag_sets]).to eq([[], 0, [%w[replay-done 26:6742]]])
    end

    it 'drops an unprompted line at the next command, as bput clears what came before it (DRC:198)' do
      game.unprompted(ReplayGame.log('26:6742'))
      game.script('mix my heavy cauldron with my mixing stick', ReplayGame.log('26:6740'))
      expect(DRC.bput('mix my heavy cauldron with my mixing stick', 'Applying', 'Roundtime')).to eq('Roundtime')
    end

    it 'refuses an unprompted line that is not cited' do
      expect { game.unprompted('You struggle to recall.') }.to raise_error(ArgumentError, /ReplayGame.log or ReplayGame.code/)
    end

    it 'leaves a flag false when no line matches it' do
      Flags.add('replay-water', /You need another splash of water/)
      game.script('mix my heavy cauldron with my mixing stick', *final_mix_reply)
      DRC.bput('mix my heavy cauldron with my mixing stick', 'Roundtime')
      expect(Flags['replay-water']).to be(false)
    end
  end

  describe 'ReplayGame reply rules' do
    it 'uses scripted replies for one command in the order they were scripted' do
      game.script('mix my heavy cauldron with my mixing stick', ReplayGame.log('26:6740'))
      game.script('mix my heavy cauldron with my mixing stick', ReplayGame.log('26:6773'))
      first = DRC.bput('mix my heavy cauldron with my mixing stick', 'Roundtime', 'Try as you might')
      second = DRC.bput('mix my heavy cauldron with my mixing stick', 'Roundtime', 'Try as you might')
      expect([first, second]).to eq(['Roundtime', 'Try as you might'])
    end

    it 'answers through a verb signature Regexp' do
      game.script(/\Amix my \S+ cauldron with my /, ReplayGame.log('26:6740'))
      expect(DRC.bput('mix my heavy cauldron with my mixing stick', 'Roundtime')).to eq('Roundtime')
    end

    it 'answers an aliased command with the replies scripted for the logged wording' do
      game.alias_command('mix my cauldron with my stick', as: 'mix my heavy cauldron with my mixing stick')
      game.script('mix my heavy cauldron with my mixing stick', ReplayGame.log('26:6740'))
      expect(DRC.bput('mix my cauldron with my stick', 'Roundtime')).to eq('Roundtime')
    end

    it 'prefers an override, then a scripted reply, then a fallback' do
      game.fallback('mix my heavy cauldron with my mixing stick', ReplayGame.log('26:6773'))
      game.script('mix my heavy cauldron with my mixing stick', ReplayGame.log('26:6740'))
      game.override('mix my heavy cauldron with my mixing stick', ReplayGame.log('26:6742'))
      replies = Array.new(4) { DRC.bput('mix my heavy cauldron with my mixing stick', 'Roundtime', 'Applying', 'Try as you might') }
      expect(replies).to eq(['Applying', 'Roundtime', 'Try as you might', 'Try as you might'])
      expect(game.trace.select { |event| event.kind == :send }.map(&:label)).to eq(%w[override script fallback fallback])
    end

    it 'runs an after: hook once the reply has arrived' do
      game.script('untie my mixing stick from my grass toolstrap', ReplayGame.log('26:6733'),
                  after: ->(_game) { $right_hand = 'luminescent starshine mixing stick' })
      DRC.bput('untie my mixing stick from my grass toolstrap', 'You untie')
      expect($right_hand).to eq('luminescent starshine mixing stick')
    end

    it 'raises ReplayLoopGuard, which `rescue => e` cannot swallow, once the send budget is spent' do
      small = ReplayGame.new(send_budget: 3).install(self)
      looping = lambda do
        loop do
          DRC.bput('turn my heavy cauldron', 'Roundtime')
        rescue StandardError
          next
        end
      end
      expect { looping.call }.to raise_error(ReplayLoopGuard, /more than 3 commands sent/)
      expect(small.sent.size).to eq(4)
    end

    it 'pins a command sequence as a timeline of sends and modelled calls' do
      commons = ReplayCommons.new(game: game, inventory: { 'heavy cauldron' => 'grass toolstrap' }).install(self)
      DRCC.get_crafting_item('cauldron', "botanist's toolbag", [], nil)
      DRC.bput('turn my heavy cauldron', 'Roundtime')
      expect(game.timeline).to eq(
        ['** DRCC.get_crafting_item("cauldron", "botanist\'s toolbag", [], nil, false)', '>> turn my heavy cauldron']
      )
      expect(game.timeline(calls: false)).to eq(['>> turn my heavy cauldron'])
      expect(commons.calls.size).to eq(1)
    end
  end

  describe 'harness fput and pause during a replay' do
    before { game } # installed even where nothing is scripted (silence)

    it 'routes fput to the replay and returns the first line of the reply (global_defs.rb:1483-1641)' do
      game.script('mix my heavy cauldron with my mixing stick', *final_mix_reply)
      expect(fput('mix my heavy cauldron with my mixing stick')).to eq(ReplayGame.log('26:6738').text)
      expect(sent_messages).to be_empty
    end

    it 'resends after a "...wait" line (:1560-1568)' do
      command = "put my wire brush in my botanist's toolbag"
      game.script(command, ReplayGame.log('25:11582'))
      game.script(command, ReplayGame.log('25:11587'))
      expect(fput(command)).to eq("You put your brush in your botanist's toolbag.")
      expect(game.sent).to eq([command, command])
    end

    it 'returns false after 60 s when the game is silent (:1549-1552)' do
      expect(fput('rub my flask')).to be(false)
      expect([game.clock, game.diagnostics]).to eq([60.0, ["fput: No game response for 60s to 'rub my flask'"]])
    end

    it "returns false on a refusal it does not resend, such as \"can't seem\" (:1582-1608)" do
      refusal = ReplayGame.code("You can't seem to do that.", from: 'global_defs.rb:1582 refusal pattern')
      game.script('rub my flask', refusal)
      expect(fput('rub my flask')).to be(false)
    end

    it 'refuses fput with patterns, which it does not model' do
      expect { fput('look', 'You see') }.to raise_error(NotImplementedError)
    end

    it 'moves the fake clock on pause' do
      pause 0.2
      expect(game.clock).to be_within(1e-9).of(0.2)
    end
  end

  describe 'ReplayGame#issue_command (model of Lich::Util.issue_command, util.rb:157-224)' do
    before { game } # installed even where nothing is scripted (silence)

    # The real reply to `read my moisturizer instructions` at 6100:207: the
    # uses line, then the title, the description and the ingredients.
    let(:moisturizer_read) { (208..220).map { |line| ReplayGame.log("6100:#{line}") } }

    it 'is what Lich::Util.issue_command answers once installed, skipping the lines before the start line (:202) and ending with the reply (:205-208)' do
      game.script('read my moisturizer instructions', *moisturizer_read)
      lines = Lich::Util.issue_command('read my moisturizer instructions', /Instructions for crafting/)
      expect(lines.first).to eq('        -=   Instructions for crafting some scale moisturizer    =-')
      expect(lines.last).to eq('   (1) catalyst material')
      expect(lines.size).to eq(11)
      expect([game.clock, game.timeline]).to eq([0.0, ['>> read my moisturizer instructions']])
    end

    it 'right-strips each line and keeps the empty ones (:203, :206)' do
      game.script('read my moisturizer instructions', *moisturizer_read)
      lines = game.issue_command('read my moisturizer instructions', /They have only/)
      expect(lines[0..2]).to eq(['These instructions appear to be very fragile and will wear out quickly when studied.  They have only 13 uses remaining.', '',
                                 '        -=   Instructions for crafting some scale moisturizer    =-'])
    end

    it 'stops at another end pattern, without the end line unless include_end (:205, :209-213)' do
      game.script('read my moisturizer instructions', *moisturizer_read)
      game.script('read my moisturizer instructions', *moisturizer_read)
      with_end = game.issue_command('read my moisturizer instructions', /Instructions for crafting/, /A list of ingredients/)
      without_end = game.issue_command('read my moisturizer instructions', /Instructions for crafting/, /A list of ingredients/, include_end: false)
      expect(with_end.last).to eq(' A list of ingredients is provided:')
      expect(without_end).to eq(with_end[0..-2])
    end

    it 'keeps only the start line with end pattern :ignore (:160, :204)' do
      game.script('read my moisturizer instructions', *moisturizer_read)
      expect(game.issue_command('read my moisturizer instructions', /Instructions for crafting/, :ignore))
        .to eq(['        -=   Instructions for crafting some scale moisturizer    =-'])
    end

    it 'returns no lines after the timeout when no line starts the capture (:171, :215-216)' do
      game.script('read my glop instructions', ReplayGame.log('6100:202'))
      expect(Lich::Util.issue_command('read my glop instructions', /Instructions for crafting/, timeout: 3)).to eq([])
      expect(game.clock).to eq(3.0)
    end

    it 'returns the lines kept so far after the timeout when another end pattern never comes' do
      game.script('read my moisturizer instructions', *moisturizer_read)
      lines = game.issue_command('read my moisturizer instructions', /Instructions for crafting/, /never sent/)
      expect([lines.size, game.clock]).to eq([11, 5.0])
    end

    it 'resends after a "...wait" line before the start line, as fput does (global_defs.rb:1560-1568)' do
      game.script('read my moisturizer instructions', ReplayGame.log('25:11582'))
      game.script('read my moisturizer instructions', *moisturizer_read)
      expect(game.issue_command('read my moisturizer instructions', /Instructions for crafting/).size).to eq(11)
      expect([game.sent.size, game.clock]).to eq([2, 1.0])
    end

    # fput sleeps out a "...wait N" inside issue_command's Timeout (:171), so
    # a wait as long as the timeout ends the capture empty (:215-216). The
    # waits are real roundtime refusals: 6 s (6100:14245) and 5 s
    # (6100:22299), both after a study.
    it 'returns nothing when a "...wait" before the start line reaches the timeout, the clock stopped at the timeout (:171, :215-216)' do
      game.script('read my moisturizer instructions', ReplayGame.log('6100:14245'))
      game.script('read my moisturizer instructions', *moisturizer_read)
      expect(game.issue_command('read my moisturizer instructions', /Instructions for crafting/)).to eq([])
      expect([game.sent, game.clock]).to eq([['read my moisturizer instructions'], 5.0])
    end

    it 'counts every wait against the timeout, and a wait exactly at the timeout ends it too' do
      game.script('read my moisturizer instructions', ReplayGame.log('25:11582'))
      game.script('read my moisturizer instructions', ReplayGame.log('6100:22299'))
      game.script('read my moisturizer instructions', *moisturizer_read)
      expect(game.issue_command('read my moisturizer instructions', /Instructions for crafting/, timeout: 6)).to eq([])
      expect([game.sent.size, game.clock]).to eq([2, 6.0])

      game.script('read my glop instructions', ReplayGame.log('6100:22299'))
      expect(game.issue_command('read my glop instructions', /Instructions for crafting/)).to eq([])
      expect(game.clock).to eq(11.0)
    end

    it 'reads past a wait shorter than a longer timeout, and a later timeout counts only what is left' do
      game.script('read my moisturizer instructions', ReplayGame.log('6100:14245'))
      game.script('read my moisturizer instructions', *moisturizer_read)
      expect(game.issue_command('read my moisturizer instructions', /Instructions for crafting/, timeout: 15).size).to eq(11)
      expect(game.clock).to eq(6.0)

      game.script('read my glop instructions', ReplayGame.log('6100:14245'))
      game.script('read my glop instructions', ReplayGame.log('6100:202'))
      expect(game.issue_command('read my glop instructions', /Instructions for crafting/, timeout: 15)).to eq([])
      expect(game.clock).to eq(21.0)
    end

    it 'drops lines left over from an earlier command (fput clears, :200)' do
      game.script('look', *moisturizer_read)
      game.bput('look', 'They have only')
      expect(game.issue_command('read my glop instructions', /Instructions for crafting/, timeout: 1)).to eq([])
    end
  end

  describe 'harness fput without a replay' do
    it 'records the command, as before' do
      fput('look')
      expect(sent_messages.pop).to eq('look')
    end
  end

  describe ReplayCommons do
    let(:belt) do
      { 'name' => 'grass toolstrap', 'items' => ['heavy cauldron', 'mixing stick', 'turtle-shaped sieve'] }
    end
    let(:bag) { "botanist's toolbag" }

    def commons_for(lich5, inventory = {})
      ReplayCommons.new(game: game, lich5: lich5, inventory: inventory).install(self)
    end

    it 'refuses an unknown lich-5 release' do
      expect { ReplayCommons.new(lich5: :v5_19) }.to raise_error(ArgumentError, /lich5: must be one of/)
    end

    it 'finds an item the way DRC::Item.short_regex does: first word, anything, last word (common.rb:629-656)' do
      expect(ReplayCommons.matches?('luminescent starshine mixing stick', 'mixing stick')).to be(true)
      expect(ReplayCommons.matches?('luminescent starshine mixing stick', 'stick')).to be(true)
      expect(ReplayCommons.matches?('shining clubmoss liniment instructions', 'liniment instructions')).to be(true)
      # 26:6733's stick: first and last word with words between them, but not
      # in the other order.
      expect(ReplayCommons.matches?('luminescent starshine mixing stick', 'luminescent stick')).to be(true)
      expect(ReplayCommons.matches?('luminescent starshine mixing stick', 'stick luminescent')).to be(false)
      expect(ReplayCommons.matches?('heavy cauldron', 'mixing stick')).to be(false)
      expect(ReplayCommons.matches?(nil, 'stick')).to be(false)
      expect(ReplayCommons.matches?('heavy cauldron', '')).to be(false)
    end

    describe 'DRCC.get_crafting_item by lich-5 release' do
      it 'returns true on :current and puts the item in the right hand first' do
        commons_for(:current, 'luminescent starshine mixing stick' => 'grass toolstrap')
        expect(DRCC.get_crafting_item('mixing stick', bag, [], belt)).to be(true)
        expect([$right_hand, $left_hand]).to eq(['luminescent starshine mixing stick', nil])
      end

      it 'returns nil on success on :v5_22 and :v5_21' do
        results = %i[v5_22 v5_21].map do |release|
          $right_hand = nil
          commons_for(release, 'heavy cauldron' => 'grass toolstrap')
          DRCC.get_crafting_item('cauldron', bag, [], belt)
        end
        expect(results).to eq([nil, nil])
        expect($right_hand).to eq('heavy cauldron')
      end

      it 'counts an item already in hand as got' do
        $left_hand = 'heavy cauldron'
        commons_for(:current)
        expect(DRCC.get_crafting_item('cauldron', bag, [], belt)).to be(true)
      end

      it 'exits on a missing item on :current, after the missing and stopping lines' do
        commons = commons_for(:current)
        expect { DRCC.get_crafting_item('pewter ingot', bag, [], belt) }.to raise_error(SystemExit)
        expect(commons.messages).to eq(['DRCC: You seem to be missing: pewter ingot', ReplayCommons::STOP_MESSAGE])
      end

      it 'returns false for a missing item on :current with skip_exit' do
        commons = commons_for(:current)
        expect(DRCC.get_crafting_item('pewter ingot', bag, [], belt, true)).to be(false)
        expect(commons.messages).to eq(['DRCC: You seem to be missing: pewter ingot'])
      end

      it 'exits on a missing item on :v5_22, and returns nil with skip_exit' do
        commons_for(:v5_22)
        expect { DRCC.get_crafting_item('pewter ingot', bag, [], belt) }.to raise_error(SystemExit)
        expect(DRCC.get_crafting_item('pewter ingot', bag, [], belt, true)).to be_nil
      end

      # Every release beeps before the missing line: v5.21.0 and v5.22.0
      # common-crafting.rb:344, 480bdee3 crafting_item_failed :517.
      %i[current v5_22 v5_21].each do |release|
        it "beeps once before the missing line on :#{release}, with skip_exit or not" do
          allow(DRC).to receive(:beep)
          commons_for(release)
          DRCC.get_crafting_item('pewter ingot', bag, [], belt, true)
          expect(DRC).to have_received(:beep).once
        end
      end

      it 'beeps nothing for an item it gets' do
        allow(DRC).to receive(:beep)
        commons_for(:current, 'heavy cauldron' => 'grass toolstrap')
        DRCC.get_crafting_item('cauldron', bag, [], belt)
        expect(DRC).not_to have_received(:beep)
      end

      it 'never exits on :v5_21: a missing item returns nil and says it stops, but does not' do
        commons = commons_for(:v5_21)
        expect(DRCC.get_crafting_item('pewter ingot', bag, [], belt)).to be_nil
        expect(commons.messages).to eq(['DRCC: You seem to be missing: pewter ingot', ReplayCommons::STOP_MESSAGE])
      end

      it 'takes a second one from the bag when bag_items lists the name, even with one in hand (common-crafting.rb:455-456)' do
        commons = commons_for(:current)
        2.times { commons.inventory << ReplayCommons::Item.new('dried nemoih', bag) }
        expect(DRCC.get_crafting_item('nemoih', bag, ['nemoih'], belt)).to be(true)
        expect(DRCC.get_crafting_item('nemoih', bag, ['nemoih'], belt)).to be(true)
        expect([$right_hand, $left_hand, commons.location_of('nemoih')]).to eq(['dried nemoih', 'dried nemoih', 'right'])
        expect(commons.inventory).to be_empty
      end

      it 'counts one in hand as got when the bag holds no other' do
        commons = commons_for(:current)
        $right_hand = 'dried nemoih'
        expect(DRCC.get_crafting_item('nemoih', bag, ['nemoih'], belt)).to be(true)
        expect([$left_hand, commons.moves]).to eq([nil, []])
      end

      it 'takes only the item it finds when two owned items are equal' do
        commons = commons_for(:current, 'dried nemoih' => bag)
        commons.inventory << ReplayCommons::Item.new('dried nemoih', bag)
        DRCC.get_crafting_item('nemoih', bag, [], belt)
        expect(commons.inventory).to eq([ReplayCommons::Item.new('dried nemoih', bag)])
      end

      it 'looks only in the bag when bag_items lists the name' do
        commons_for(:current, 'pewter ingot' => 'leather satchel')
        expect(DRCC.get_crafting_item('pewter ingot', bag, ['pewter ingot'], belt, true)).to be(false)
      end

      context 'when the belt lists the name, which the real helper unties first (480bdee3 common-crafting.rb:446-455)' do
        let(:belt_with_book) { { 'name' => 'grass toolstrap', 'items' => ['mixing stick', 'remed book'] } }

        it 'takes it from the belt, though bag_items lists it too' do
          commons = commons_for(:current, 'remed book' => 'grass toolstrap')
          expect(DRCC.get_crafting_item('remed book', bag, ['remed book'], belt_with_book, true)).to be(true)
          expect(commons.moves).to eq(['remed book: grass toolstrap -> hand'])
        end

        it 'goes on to the bag when none is tied there' do
          commons = commons_for(:current, 'remed book' => bag)
          expect(DRCC.get_crafting_item('remed book', bag, ['remed book'], belt_with_book, true)).to be(true)
          expect(commons.moves).to eq(["remed book: #{bag} -> hand"])
        end

        it 'fails as before when it is neither on the belt nor in the bag' do
          commons = commons_for(:current, 'remed book' => 'leather satchel')
          expect(DRCC.get_crafting_item('remed book', bag, ['remed book'], belt_with_book, true)).to be(false)
          expect(commons.messages).to eq(['DRCC: You seem to be missing: remed book'])
        end
      end

      it 'fails with no hand free on :current, and returns nil on older releases' do
        $right_hand = 'heavy cauldron'
        $left_hand = 'luminescent starshine mixing stick'
        commons = commons_for(:current, 'pewter ingot' => bag)
        expect(DRCC.get_crafting_item('pewter ingot', bag, [], belt, true)).to be(false)
        expect(commons.messages).to eq(['DRCC: No free hand to get: pewter ingot'])
        commons_for(:v5_21, 'pewter ingot' => bag)
        expect(DRCC.get_crafting_item('pewter ingot', bag, [], belt)).to be_nil
      end
    end

    describe 'DRCC.stow_crafting_item' do
      it 'ties a tool the belt lists back to the belt (common-crafting.rb:532)' do
        commons = commons_for(:current)
        $left_hand = 'luminescent starshine mixing stick'
        expect(DRCC.stow_crafting_item('luminescent starshine mixing stick', bag, belt)).to be(true)
        expect([$left_hand, commons.location_of('mixing stick')]).to eq([nil, 'grass toolstrap'])
      end

      it 'puts anything else in the bag' do
        commons = commons_for(:current)
        $right_hand = 'some belradi elixir'
        DRCC.stow_crafting_item('elixir', bag, belt)
        expect(commons.location_of('elixir')).to eq(bag)
      end

      it 'does nothing for a nil name, as remedy sends for an empty hand (common-crafting.rb:529)' do
        commons = commons_for(:current)
        expect(DRCC.stow_crafting_item(nil, bag, belt)).to be_nil
        expect(commons.inventory).to be_empty
      end

      it 'answers true when the item is not held' do
        commons_for(:current)
        expect(DRCC.stow_crafting_item('stamp', bag, belt)).to be(true)
      end
    end

    describe 'DRCI helpers' do
      it 'in_hands? matches either hand by short_regex (common-items.rb:935-998)' do
        commons_for(:current)
        $left_hand = 'shining clubmoss liniment instructions'
        expect([DRCI.in_hands?('liniment instructions'), DRCI.in_hands?('stamp')]).to eq([true, false])
      end

      it 'in_left_hand? and in_right_hand? each read only their own hand, by short_regex (common-items.rb:945-957, :985-990)' do
        commons_for(:current)
        $left_hand = 'diamondique large mortar'
        $right_hand = 'rounded pestle'
        expect([DRCI.in_left_hand?('mortar'), DRCI.in_right_hand?('mortar')]).to eq([true, false])
        expect([DRCI.in_left_hand?('pestle'), DRCI.in_right_hand?('pestle')]).to eq([false, true])
        expect([DRCI.in_left_hand?('large mortar'), DRCI.in_left_hand?('mortar large')]).to eq([true, false])
      end

      it 'in_left_hand? and in_right_hand? answer false for an empty hand' do
        commons_for(:current)
        expect([DRCI.in_left_hand?('mortar'), DRCI.in_right_hand?('mortar')]).to eq([false, false])
      end

      it 'get_item? takes from a container when given, and counts an item in hand as got (common-items.rb:135)' do
        commons = commons_for(:current, 'nemoih' => 'large mortar')
        expect(DRCI.get_item?('nemoih', bag)).to be(false)
        expect(DRCI.get_item?('nemoih', 'large mortar')).to be(true)
        expect(DRCI.get_item?('nemoih')).to be(true)
        expect(commons.location_of('nemoih')).to eq('right')
      end

      it 'put_away_item? puts a held item in a container, stows it without one, and fails when not held' do
        commons = commons_for(:current)
        $right_hand = 'nemoih'
        $left_hand = 'dried clubmoss'
        expect(DRCI.put_away_item?('nemoih', 'large mortar')).to be(true)
        expect(DRCI.put_away_item?('clubmoss')).to be(true)
        expect(DRCI.put_away_item?('clubmoss')).to be(false)
        expect([commons.location_of('nemoih'), commons.location_of('clubmoss')]).to eq(['large mortar', ReplayCommons::STOWED])
      end

      # Not modelled (class comment): lich-5 sends `stow my second nemoih`
      # (480bdee3 common-items.rb:1868-1890) and the game picks the stack.
      it 'put_away_item? finds no item by its place in hand ("second nemoih", remedy.lic:239), so it moves nothing and answers false' do
        commons = commons_for(:current)
        $right_hand = 'nemoih'
        $left_hand = 'nemoih'
        expect(DRCI.put_away_item?('second nemoih')).to be(false)
        expect(DRCI.in_hands?('first nemoih')).to be(false)
        expect([$right_hand, $left_hand, commons.inventory]).to eq(['nemoih', 'nemoih', []])
      end

      it 'lower_item? puts a held item on the ground and fails when not held (common-items.rb:1617-1626)' do
        commons = commons_for(:current)
        $right_hand = 'large mortar'
        expect([DRCI.lower_item?('mortar'), DRCI.lower_item?('mortar')]).to eq([true, false])
        expect(commons.location_of('mortar')).to eq(ReplayCommons::GROUND)
      end

      it 'exists? finds an owned item, in a container when given, and a held one only without a container' do
        commons_for(:current, 'nemoih' => bag)
        $right_hand = 'heavy cauldron'
        expect([DRCI.exists?('nemoih'), DRCI.exists?('nemoih', bag), DRCI.exists?('nemoih', 'large mortar')]).to eq([true, true, false])
        expect([DRCI.exists?('cauldron'), DRCI.exists?('cauldron', bag)]).to eq([true, false])
      end
    end

    it 'puts an ordered item in hand and records the travel, bank and magic calls without effects' do
      commons = ReplayCommons.new(game: game, orders: { 7 => 'some water' }).install(self)
      DRCM.get_money_from_bank('5 silver', nil)
      DRCT.order_item(19_073, 7)
      DRCT.order_item(19_073, 8)
      expect(DRCT.walk_to(19_088)).to be(true)
      DRCA.crafting_magic_routine(nil)
      DRC.wait_for_script_to_complete('buff', ['remedy'])
      expect([$right_hand, $left_hand]).to eq(['some water', nil])
      expect(commons.calls.map(&:first)).to eq(
        %w[DRCM.get_money_from_bank DRCT.order_item DRCT.order_item DRCT.walk_to DRCA.crafting_magic_routine DRC.wait_for_script_to_complete]
      )
    end

    it 'records ensure_copper_on_hand with the amount and town, leaving the settings out, and succeeds' do
      commons = ReplayCommons.new(game: game).install(self)
      expect(DRCM.ensure_copper_on_hand(1500, { hometown: 'Crossing' }, 'Shard')).to be(true)
      expect(commons.calls).to eq([['DRCM.ensure_copper_on_hand', 1500, 'Shard']])
    end

    it 'hold and release change the hands for scenario setup and after: hooks' do
      commons = commons_for(:current)
      expect([commons.hold('heavy cauldron'), commons.hold('mixing stick'), commons.hold('sieve')]).to eq([:right, :left, nil])
      expect(commons.release('stick')).to eq('mixing stick')
      expect(commons.release('stick')).to be_nil
    end

    describe '#moves' do
      it 'records each item a helper moves by its full name, whatever name it was asked by' do
        commons = commons_for(:current, 'luminescent starshine mixing stick' => 'grass toolstrap', 'nemoih' => bag)
        DRCC.get_crafting_item('mixing stick', bag, [], belt)
        DRCI.get_item?('nemoih', bag)
        DRCI.put_away_item?('nemoih', 'large mortar')
        DRCC.stow_crafting_item($right_hand, bag, belt)
        expect(commons.moves).to eq(['luminescent starshine mixing stick: grass toolstrap -> hand', "nemoih: #{bag} -> hand",
                                     'nemoih: hand -> large mortar', 'luminescent starshine mixing stick: hand -> grass toolstrap'])
      end

      it 'records lowering, a plain stow, an order and the game handing over or taking an item' do
        commons = ReplayCommons.new(game: game, orders: { 1 => 'water' }).install(self)
        DRCT.order_item(8862, 1)
        DRCI.put_away_item?('water')
        commons.hold('large mortar')
        DRCI.lower_item?('mortar')
        commons.hold('nemoih unguent')
        commons.release('unguent')
        expect(commons.moves).to eq(['water: shop -> hand', 'water: hand -> stowed', 'large mortar: game -> hand',
                                     'large mortar: hand -> ground', 'nemoih unguent: game -> hand', 'nemoih unguent: hand -> game'])
      end

      it 'records nothing for a failed or empty-handed call' do
        commons = commons_for(:v5_21)
        DRCC.get_crafting_item('pewter ingot', bag, [], belt)
        DRCC.stow_crafting_item(nil, bag, belt)
        DRCC.stow_crafting_item('stamp', bag, belt)
        DRCI.put_away_item?('stamp')
        DRCI.lower_item?('stamp')
        commons.release('stamp')
        expect(commons.moves).to be_empty
      end

      it 'records no order when both hands are full' do
        commons = ReplayCommons.new(game: game, orders: { 1 => 'water' }).install(self)
        $right_hand = 'heavy cauldron'
        $left_hand = 'luminescent starshine mixing stick'
        DRCT.order_item(8862, 1)
        expect(commons.moves).to be_empty
      end
    end

    # The ids are made up (code-derived): Genie client logs carry no ids.
    describe 'item ids (GameObj.left_hand.id / right_hand.id)' do
      it 'gives no hand an id by default, as for every run of the logs' do
        commons = commons_for(:current, 'dried nemoih' => bag)
        DRCC.get_crafting_item('nemoih', bag, [], belt)
        expect($right_hand).to eq('dried nemoih')
        expect(GameObj.right_hand.id).to be_nil
        expect(commons.id_of('nemoih')).to be_nil
      end

      it 'shows the id of the item a hand holds, by its full name, once installed' do
        ReplayCommons.new(game: game, inventory: { 'dried nemoih' => bag }, ids: { 'dried nemoih' => '41782305' }).install(self)
        DRCC.get_crafting_item('nemoih', bag, [], belt)
        expect(GameObj.right_hand.id).to eq('41782305')
        expect(GameObj.left_hand.id).to be_nil
        expect(GameObj.left_hand.name).to eq('Empty')
      end

      it 'drops the id with the item: an emptied hand shows none' do
        commons = ReplayCommons.new(game: game, ids: { 'dried nemoih' => '41782305' }).install(self)
        commons.hold('dried nemoih')
        commons.release('nemoih')
        expect(GameObj.right_hand.id).to be_nil
      end

      it 'answers the id a requested name finds, as the helpers find items (id_of, id_in)' do
        ids = { 'rounded pestle' => '41782399', 'dried nemoih' => '41782305' }
        expect(ReplayCommons.new(ids: ids).id_of('nemoih')).to eq('41782305')
        expect(ReplayCommons.id_in(ids, 'dried nemoih')).to eq('41782305')
        expect(ReplayCommons.id_in(ids, 'pestle')).to eq('41782399')
        expect(ReplayCommons.id_in(ids, 'mortar')).to be_nil
        expect(ReplayCommons.id_in({}, 'nemoih')).to be_nil
      end

      # lich-5 DRCI.item_ref passes a "#<id>" reference through unchanged
      # (480bdee3 common-items.rb:50-58), so put_away_item?("#<id>", bag)
      # sends `put #<id> in my <bag>` and get_item?("#<id>") `get #<id>`.
      describe 'a "#<id>" reference' do
        let(:ids) { { 'nemoih unguent' => '41782311' } }

        it 'puts away the held item with that id, and only that one' do
          commons = ReplayCommons.new(game: game, ids: ids).install(self)
          commons.hold('rounded pestle')
          commons.hold('nemoih unguent')
          expect(DRCI.put_away_item?('#41782311', bag)).to be(true)
          expect([$right_hand, $left_hand]).to eq(['rounded pestle', nil])
          expect(commons.moves.last).to eq("nemoih unguent: hand -> #{bag}")
        end

        it 'gets the item with that id back from wherever it is, past another of the same noun' do
          commons = ReplayCommons.new(game: game, inventory: { 'blister unguent' => bag, 'nemoih unguent' => bag }, ids: ids).install(self)
          expect(DRCI.get_item?('#41782311')).to be(true)
          expect($right_hand).to eq('nemoih unguent')
          expect(commons.location_of('blister unguent')).to eq(bag)
        end

        it 'finds nothing for an id no item has, held or owned' do
          commons = ReplayCommons.new(game: game, inventory: { 'nemoih unguent' => bag }, ids: ids).install(self)
          commons.hold('rounded pestle')
          expect(DRCI.put_away_item?('#99999999', bag)).to be(false)
          expect(DRCI.get_item?('#99999999')).to be(false)
          expect([$right_hand, $left_hand]).to eq(['rounded pestle', nil])
        end
      end
    end
  end

  describe ArgParserModel do
    # Two forms, like remedy's: a positional form and a `continue` form.
    let(:forms) do
      [
        [
          { name: 'book_type', options: %w[remedies], variable: true, description: 'Book type.' },
          { name: 'chapter', regex: /\d+/i, variable: true, description: 'Chapter.' },
          { name: 'noun', regex: /\w+/i, variable: true, description: 'Product.' },
          { name: 'debug', regex: /^debug$/i, optional: true, description: 'Echo more.' }
        ],
        [
          { name: 'continue', regex: /continue/i, variable: true },
          { name: 'noun', regex: /\w+/i, variable: true, description: 'Product.' }
        ]
      ]
    end

    describe '.script_vars (Script#initialize, script.rb:1837-1843)' do
      it 'keeps the whole string first, then each argument with its double quotes removed' do
        expect(ArgParserModel.script_vars('remedies 2 "blister cream" "red flower" nemoih'))
          .to eq(['remedies 2 "blister cream" "red flower" nemoih', 'remedies', '2', 'blister cream', 'red flower', 'nemoih'])
      end

      it 'keeps a quoted part inside a word, and an escaped quote as a quote' do
        expect(ArgParserModel.script_vars('a"b c"d \\"x').drop(1)).to eq(['ab cd', '"x'])
      end

      it 'gives nothing for an empty string and drops repeated spaces' do
        expect(ArgParserModel.script_vars('')).to eq([])
        expect(ArgParserModel.script_vars('a  b').drop(1)).to eq(%w[a b])
      end
    end

    describe '.caller_vars (DRC.wait_for_script_to_complete, common.rb:339, and start_script)' do
      it 'quotes an argument holding whitespace and turns others into strings' do
        expect(ArgParserModel.caller_vars(['remedies', 6, 'a general elixir', 'belradi']))
          .to eq(['remedies 6 "a general elixir" belradi', 'remedies', '6', 'a general elixir', 'belradi'])
      end

      it 'loses a nil or empty argument, shifting the ones after it' do
        expect(ArgParserModel.caller_vars(['remedies', nil, 'tea', '']).drop(1)).to eq(%w[remedies tea])
      end
    end

    it 'matches required arguments in order and downcases every value (arg_parser.rb:96-101)' do
      args = ArgParserModel.parse(forms, %w[Remedies 2 CREAM])
      expect([args.book_type, args.chapter, args.noun, args.debug]).to eq(['remedies', '2', 'cream', nil])
    end

    it 'matches required arguments first and optional ones in any order among the rest (:96-108)' do
      # The optional definitions come first in the form, yet match after the
      # required one, in whatever order the user typed them.
      optional_first = [[
        { name: 'debug', regex: /^debug$/i, optional: true },
        { name: 'fast', regex: /^fast$/i, optional: true },
        { name: 'noun', regex: /\w+/i, variable: true }
      ]]
      typed = [%w[cream FAST debug], %w[cream debug fast]].map do |argv|
        args = ArgParserModel.parse(optional_first, argv)
        [args.noun, args.debug, args.fast]
      end
      expect(typed).to eq([%w[cream debug fast], %w[cream debug fast]])
    end

    it 'matches an option as a prefix unless option_exact (:88)' do
      expect(ArgParserModel.parse(forms, %w[remediesXYZ 2 cream]).book_type).to eq('remediesxyz')
      exact = [[{ name: 'book_type', options: %w[remedies], option_exact: true }]]
      expect { ArgParserModel.parse(exact, %w[remediesXYZ]) }.to raise_error(SystemExit)
    end

    it "rejects arguments that match two forms, printing lich-5's message and the help (:37-44)" do
      ambiguous = [[{ name: 'a', regex: /\w+/ }], [{ name: 'b', regex: /\d+/ }]]
      expect { ArgParserModel.parse(ambiguous, %w[7], raw: '7') }.to raise_error(SystemExit)
      expect(displayed_messages).to include(ArgParserModel::MULTIPLE_MATCH_MESSAGE, "Provided Arguments: '7'")
    end

    it 'rejects arguments that match no form, and a form with an argument left over (:34-36, :123-125)' do
      expect { ArgParserModel.parse(forms, %w[remedies two cream]) }.to raise_error(SystemExit)
      expect { ArgParserModel.parse(forms, %w[remedies 2 cream extra]) }.to raise_error(SystemExit)
      expect(displayed_messages.count(ArgParserModel::NO_MATCH_MESSAGE)).to eq(2)
    end

    it 'rejects too few arguments without raising on the missing one (:97)' do
      expect { ArgParserModel.parse(forms, %w[remedies 2]) }.to raise_error(SystemExit)
    end

    it 'keeps leftover arguments in flex when flex is on (:110-111)' do
      args = ArgParserModel.parse([[{ name: 'noun', regex: /\w+/ }]], %w[cream Extra], flex: true)
      expect([args.noun, args.flex]).to eq(['cream', ['Extra']])
    end

    it 'prints the help and exits for a lone "help" (:29, :43-44)' do
      expect { ArgParserModel.parse(forms, %w[help]) }.to raise_error(SystemExit)
      expect(displayed_messages).to include('  ;test-script <book_type> <chapter> <noun> [debug]')
      expect(displayed_messages).not_to include(ArgParserModel::NO_MATCH_MESSAGE)
    end

    it 'is what the harness parse_args uses when $parse_args_model is set, reading $script_vars' do
      $parse_args_model = true
      $script_vars = ['remedies 2 Cream', 'remedies', '2', 'Cream']
      expect(parse_args(forms).noun).to eq('cream')
    end

    context 'when an earlier example left $script_vars set', order: :defined do
      it 'parses what this example sets' do
        $parse_args_model = true
        $script_vars = ['remedies 2 cream', 'remedies', '2', 'cream']
        expect(parse_args(forms).noun).to eq('cream')
      end

      it 'starts the next example with none, as reset_data clears it' do
        expect($script_vars).to be_nil
      end
    end

    it 'leaves the harness parse_args returning $parsed_args by default' do
      $parsed_args = OpenStruct.new(noun: 'Cream')
      $script_vars = ['nonsense']
      args = parse_args(forms)
      expect([args.noun, args.flex]).to eq(%w[Cream test])
    end
  end

  describe ReplayTranscript do
    let(:transcript) { ReplayTranscript.load('spec/fixtures/replay_game/transcript.json') }
    let(:mix) { 'mix my heavy cauldron with my mixing stick' }

    def transcript_file(content)
      file = Tempfile.new(['transcript', '.json'])
      file.write(JSON.generate(content))
      file.close
      (@tempfiles ||= []) << file # keeps the file from being unlinked by GC
      file.path
    end

    it 'reads each logged command with its reply lines, cited <log>:<line>' do
      step = transcript.step(6736)
      expect([step.command, step.user, step.lines.map(&:label)]).to eq([mix, false, %w[26:6738 26:6740 26:6742]])
      expect(step.lines.last.text).to eq(ReplayGame.log('26:6742').text)
    end

    it 'refuses a step line that names no command' do
      expect { transcript.step(6737) }.to raise_error(ArgumentError, /no command at line 6737/)
    end

    it 'refuses a reply line whose text differs from the same cite in a log_lines.json fixture' do
      path = transcript_file('run' => 'x', 'log' => '26', 'source' => 'test', 'steps' => [
                               { 'cmd' => 'mix', 'line' => 6736, 'user' => false, 'responses' => [{ 'text' => 'Roundtime: 1 sec.', 'line' => 6740 }] }
                             ])
      expect { ReplayTranscript.load(path) }.to raise_error(ArgumentError, /26:6740 reads "Roundtime: 1 sec\.", but a log_lines.json fixture has "Roundtime: 9 sec\."/)
    end

    it 'scripts the selected steps in log order, one reply per send' do
      transcript.script(game, commands: /\Amix /)
      expect(DRC.bput(mix, 'Roundtime:')).to eq('Roundtime:')
      expect(DRC.bput(mix, /^[^"]*?Try as you might/i)).to eq('Try as you might')
      expect(DRC.bput(mix, 'Roundtime:')).to eq('')
    end

    it 'leaves out skipped steps and steps before from:' do
      expect(transcript.script(game, commands: /\A(?:mix|untie) /, skip: [6736]).map(&:line)).to eq([6731, 6770])
      expect(transcript.script(ReplayGame.new, commands: /\A(?:mix|untie) /, from: 6736).map(&:line)).to eq([6736, 6770])
    end

    it 'refuses a skip line that names no step' do
      expect { transcript.script(game, commands: /\Amix /, skip: [1]) }.to raise_error(ArgumentError, /no command at line 1/)
    end

    it 'injects an extra reply before a step, so the resend after a real "...wait" (25:11582) gets the logged reply' do
      transcript.script(game, commands: /\Amix /, inject: { 6736 => [ReplayGame.log('25:11582')] })
      expect(DRC.bput(mix, 'Roundtime:')).to eq('Roundtime:')
      expect(game.sent).to eq([mix, mix])
    end

    it 'injects one silent reply for an empty inject: the step after it is answered on the resend' do
      transcript.script(game, commands: /\Amix /, skip: [6731], inject: { 6736 => [] })
      expect(DRC.bput(mix, 'Roundtime:')).to eq('')
      expect(DRC.bput(mix, 'Roundtime:')).to eq('Roundtime:')
    end

    it 'injects a list of replies in turn: two silences, a real "...wait" (25:11582), then the logged reply' do
      transcript.script(game, commands: /\Amix /, skip: [6731], inject: { 6736 => [[], [], [ReplayGame.log('25:11582')]] })
      expect(Array.new(2) { DRC.bput(mix, 'Roundtime:') }).to eq(['', ''])
      expect(DRC.bput(mix, 'Roundtime:')).to eq('Roundtime:')
      expect(game.sent).to eq([mix] * 4)
      expect(game.diagnostics.size).to eq(2)
    end

    it 'replaces the reply of a step' do
      transcript.script(game, commands: /\Amix /, replace: { 6736 => [ReplayGame.log('26:6773')] })
      expect(DRC.bput(mix, 'Roundtime:', /^[^"]*?Try as you might/i)).to eq('Try as you might')
    end

    it 'refuses an inject or replace line that is not a scripted step' do
      expect { transcript.script(game, commands: /\Amix /, inject: { 6731 => [] }) }.to raise_error(ArgumentError, /6731 is not a scripted step/)
      expect { transcript.script(game, commands: /\Amix /, skip: [6770], replace: { 6770 => [] }) }
        .to raise_error(ArgumentError, /6770 is not a scripted step/)
    end
  end

  describe 'run_lic_entry' do
    let(:probe) { 'spec/fixtures/replay_game/entry_probe.lic' }

    before do
      load_lic_class(probe, 'ReplayEntryProbe')
      ReplayEntryProbe.runs.clear
      $parse_args_model = true
    end

    it 'runs the code after the class each time it is called, at its real line numbers' do
      $script_vars = %w[first first]
      run_lic_entry(probe, 'ReplayEntryProbe')
      $script_vars = %w[second second]
      run_lic_entry(probe, 'ReplayEntryProbe')
      line = File.readlines(lic_path(probe)).index { |l| l.include?('ReplayEntryProbe.runs <<') } + 1
      expect(ReplayEntryProbe.runs).to eq([['first', line], ['second', line]])
    end

    it 'keeps the entry locals out of the top-level binding' do
      $script_vars = %w[word word]
      run_lic_entry(probe, 'ReplayEntryProbe')
      expect(TOPLEVEL_BINDING.local_variable_defined?(:probe_args)).to be(false)
    end

    it 'points a backtrace at the .lic line that raised' do
      $script_vars = %w[fail fail]
      line = File.readlines(lic_path(probe)).index { |l| l.include?('was asked to fail') } + 1
      expect { run_lic_entry(probe, 'ReplayEntryProbe') }
        .to raise_error(ArgumentError) { |error| expect(error.backtrace.first).to start_with("#{lic_path(probe)}:#{line}:") }
    end

    it 'lets the entry exit through the real argument model (help + exit on a bad call)' do
      $script_vars = ['', 'two', 'words']
      expect { run_lic_entry(probe, 'ReplayEntryProbe') }.to raise_error(SystemExit)
      expect(ReplayEntryProbe.runs).to be_empty
    end

    it 'refuses to run before the class is loaded' do
      expect { run_lic_entry(probe, 'ReplayEntryProbeNotLoaded') }.to raise_error(RuntimeError, /load ReplayEntryProbeNotLoaded with load_lic_class/)
    end
  end
end
