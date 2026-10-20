# frozen_string_literal: true

require 'yaml'

require_relative 'spec_helper'

load_lic_module('aesthene.lic', 'AestheneWords')
load_lic_module('aesthene.lic', 'AestheneGrid')
load_lic_class('aesthene.lic', 'AestheneSolver')
load_lic_class('aesthene.lic', 'Aesthene')

# Game output below is copied from a real Aesthene's Close session log,
# including the unrelated lines the game interleaved with the grid.

# The POACH lock after its first probe. The '[multi]>' echo sits between grid
# rows exactly as it did in the log.
AESTHENE_FIRST_PROBE_TRANSCRIPT = [
  "You quietly whisper 'aeiou' to the lock.  Eldritch lights surround the tiles as they settle into place.",
  ' +-----+-----+-----+-----+-----+',
  ' |  1  |  2  |  3  |  4  |  5  |',
  ' +-----+-----+-----+-----+-----+',
  ' | _A_ | *E* | *I* | _O_ | *U* |',
  ' | ___ | ___ | ___ | ___ | ___ |',
  '[multi]>whisper lock tmprs',
  ' | ___ | ___ | ___ | ___ | ___ |',
  ' | ___ | ___ | ___ | ___ | ___ |',
  ' | ___ | ___ | ___ | ___ | ___ |',
  ' | ___ | ___ | ___ | ___ | ___ |',
  ' +-----+-----+-----+-----+-----+',
  '[1 of the 6 rows are locked into place.]',
  '[Remaining letters: BCDFGHJKLMNPQRSTVWXYZ]',
  '[+ indicates right letter in the right place.]',
  '[_ indicates wrong letter for a given place, but letter is in the final word.]',
  "[* indicates a wrong letter that isn't used in the final word.]",
  '[LOOK at the lock for an update on your progress!]'
].freeze

# The LIGHT lock being solved on row five. This reward line says
# "1 role-playing point", singular.
AESTHENE_SOLVED_TRANSCRIPT = [
  "You quietly whisper 'light' to the lock.  Eldritch lights surround the tiles as they settle into place.",
  ' +-----+-----+-----+-----+-----+',
  ' |  1  |  2  |  3  |  4  |  5  |',
  ' +-----+-----+-----+-----+-----+',
  ' | *A* | *E* | _I_ | *O* | *U* |',
  ' | *B* | *C* | *D* | _G_ | *N* |',
  ' | _T_ | *M* | *P* | *R* | *S* |',
  ' | *F* | _H_ | *K* | _L_ | *W* |',
  ' | +L+ | +I+ | +G+ | +H+ | +T+ |',
  ' | ___ | ___ | ___ | ___ | ___ |',
  ' +-----+-----+-----+-----+-----+',
  '[5 of the 6 rows are locked into place.]',
  '[Remaining letters: JQVXYZ]',
  '[+ indicates right letter in the right place.]',
  '[_ indicates wrong letter for a given place, but letter is in the final word.]',
  "[* indicates a wrong letter that isn't used in the final word.]",
  'The letters on a time lock pulsing with multi-colored light pulse with blue light and lock in place.',
  'You innately sense that fate has smiled on you, and the world seems just a bit brighter.',
  "[You have received 1 role-playing point for your assistance in locking away unstable temporal magics at Aesthene's Close!  Type RPA HELP to review how to use it.]"
].freeze

# LOOK output for a THROW lock after four probes, from a second player's log.
# A look prints no progress prompt; the legend is its last line.
AESTHENE_LOOK_TRANSCRIPT = [
  'The time lock is divided into several grids.  One such grid rises up before you --  five spaces wide and six spaces tall.  A nearby tray contains stone tiles, each displaying a single letter and shaped appropriately to be set within the grid.',
  ' +-----+-----+-----+-----+-----+',
  ' |  1  |  2  |  3  |  4  |  5  |',
  ' +-----+-----+-----+-----+-----+',
  ' | *A* | *E* | *I* | +O+ | *U* |',
  ' | +T+ | *P* | *M* | _R_ | *S* |',
  ' | *B* | *C* | *D* | *G* | *N* |',
  ' | *F* | +H+ | *K* | *L* | +W+ |',
  ' | ___ | ___ | ___ | ___ | ___ |',
  ' | ___ | ___ | ___ | ___ | ___ |',
  ' +-----+-----+-----+-----+-----+',
  '[4 of the 6 rows are locked into place.]',
  '[Remaining letters: JQVXYZ]',
  '[+ indicates right letter in the right place.]',
  '[_ indicates wrong letter for a given place, but letter is in the final word.]',
  "[* indicates a wrong letter that isn't used in the final word.]"
].freeze

# The four probe rows of the POACH lock, as printed.
AESTHENE_POACH_PROBE_ROWS = [
  ' | _A_ | *E* | *I* | _O_ | *U* |',
  ' | *B* | _C_ | *D* | *G* | *N* |',
  ' | *T* | *M* | _P_ | *R* | *S* |',
  ' | *F* | _H_ | *K* | *L* | *W* |'
].freeze

# A stand-in for the Timekeeper and one time lock, answering each command with
# the lines the game printed in the two reference logs. Unrelated lines are
# interleaved with every grid, as they were in the logs.
class AestheneFakeLock
  NOISE = ['A traveler just arrived.', '[multi]>get my multiplier'].freeze

  # @return [Array<String>] every command the script sent, in order
  attr_reader :commands

  # @param answer [String] the lock's answer
  # @param passes [Integer] redeemed passes the character already holds
  # @param attuned_rows [Array<String>, nil] guesses already on a lock the
  #   character is attuned to; nil when not attuned
  def initialize(answer, passes: 0, attuned_rows: nil)
    @answer = answer
    @passes = passes
    @rows = attuned_rows
    @commands = []
    @redeem_confirmed = false
    @touch_confirmed = false
    @drop_row_once = false
    @whispers_to_ignore = 0
  end

  # Makes the next whisper reply leave out one grid row, as if it were missed.
  def drop_a_row_next_whisper
    @drop_row_once = true
  end

  # Makes the next whispers get a reply that adds no row, as if the lock
  # did not take them.
  #
  # @param count [Integer] whispers to ignore; Float::INFINITY for all
  def ignore_whispers(count)
    @whispers_to_ignore = count
  end

  # @param command [String]
  # @return [Array<String>] the game's reply
  def reply(command)
    @commands << command
    # A script stuck re-sending the same whisper would otherwise hang the suite.
    raise 'the script kept whispering' if @commands.grep(/\Awhisper /).size > 20

    case command
    when 'redeem my slip' then redeem
    when 'ask timekeeper about access' then ask_access
    when 'touch lock' then touch
    when 'look lock' then look
    when /\Awhisper lock (\w+)\z/ then whisper(Regexp.last_match(1).upcase)
    else []
    end
  end

  private

  def redeem
    unless @redeem_confirmed
      @redeem_confirmed = true
      return ["Once you redeem this, you'll have 1 instance access to the Aesthene's Close.  If you're prepared to immediately begin, repeat the command within 10 seconds."]
    end
    @redeem_confirmed = false
    @passes += 1
    ['The apprentice Timekeeper takes one of your slips.',
     "[You have just redeemed 1 instance of access to a task to earn chronocoins from the Timekeepers at Aesthene's Close.  Be sure to ASK TIMEKEEPER ABOUT ACCESS to be moved in!]"]
  end

  def ask_access
    ['"Yes, yes, let me show you the way."  The apprentice leads you away.',
     "[Aesthene's Close, Chronoscape] (**)",
     'The apprentice Timekeeper shows you to a time lock, and explains "There are thousands of these throughout the area."']
  end

  def touch
    return ['You are already connected to the lock.'] if @rows
    return ['[To interact with the lock, you must redeem a pass for the event.  Passes are available in the SimuCoin store via the website.  Once redeemed, simply TOUCH the lock!]'] if @passes.zero?

    unless @touch_confirmed
      @touch_confirmed = true
      return ['You reach towards the lock, but pause to consider.',
              "[This will consume a pass for Aesthene's Close.  If you're sure you want to do this, TOUCH the lock again within 15 seconds.]"]
    end
    @passes -= 1
    @rows = []
    ['You reach out and touch the lock, and an alarming pulse of energy surges from it and through you.',
     '[LOOK at the lock to see your progress.  STUDY the lock for more information.]']
  end

  def look
    ['The time lock is divided into several grids.  One such grid rises up before you --  five spaces wide and six spaces tall.'] +
      grid(@rows || []) + legend
  end

  def whisper(guess)
    return ["You whisper quietly to the lock.  It doesn't respond.", '[You are not currently tasked with solving the puzzle.  TOUCH the lock to begin.]'] unless @rows
    if @whispers_to_ignore.positive?
      @whispers_to_ignore -= 1
      return ["You whisper quietly to the lock.  It doesn't respond."]
    end

    @rows += [guess]
    lines = ["You quietly whisper '#{guess.downcase}' to the lock.  Eldritch lights surround the tiles as they settle into place."]
    body = grid(@rows)
    if @drop_row_once
      @drop_row_once = false
      body.delete_at(3) # the first filled row
    end
    lines += body + legend
    if guess == @answer
      lines + ['The letters on a time lock pulsing with multi-colored light pulse with blue light and lock in place.',
               "[You have received 1 role-playing point for your assistance in locking away unstable temporal magics at Aesthene's Close!  Type RPA HELP to review how to use it.]"]
    else
      lines + ['[LOOK at the lock for an update on your progress!]']
    end
  end

  def grid(rows)
    filled = rows.map { |guess| row_line(guess) }
    empty = Array.new(6 - rows.size, ' | ___ | ___ | ___ | ___ | ___ |')
    [' +-----+-----+-----+-----+-----+', ' |  1  |  2  |  3  |  4  |  5  |', ' +-----+-----+-----+-----+-----+'] +
      filled.first(1) + [NOISE[0]] + filled.drop(1) + [NOISE[1]] + empty +
      [' +-----+-----+-----+-----+-----+', "[#{rows.size} of the 6 rows are locked into place.]"]
  end

  def row_line(guess)
    code = AestheneSolver.feedback_code(guess, @answer)
    marks = Array.new(5) do
      mark = ['*', '_', '+'][code % 3]
      code /= 3
      mark
    end.reverse
    ' | ' + guess.chars.zip(marks).map { |letter, mark| "#{mark}#{letter}#{mark}" }.join(' | ') + ' |'
  end

  def legend
    ['[+ indicates right letter in the right place.]',
     '[_ indicates wrong letter for a given place, but letter is in the final word.]',
     "[* indicates a wrong letter that isn't used in the final word.]"]
  end
end

RSpec.describe 'aesthene.lic' do
  # Builds a Row the way the game would mark a guess against an answer.
  def row_for(guess, answer)
    code = AestheneSolver.feedback_code(guess, answer)
    marks = Array.new(5) do
      mark = %i[absent present hit][code % 3]
      code /= 3
      mark
    end
    AestheneGrid::Row.new(guess, marks.reverse)
  end

  def reading_from(lines)
    AestheneGrid::Reading.new.tap { |reading| lines.each { |line| reading.feed(line) } }
  end

  def drain_sent_messages
    Array.new(sent_messages.size) { sent_messages.pop }
  end

  # -------------------------------------------------------------------
  # AestheneWords
  # -------------------------------------------------------------------
  describe AestheneWords do
    describe '.normalize' do
      it 'upcases and strips entries, because lock answers are case-insensitive' do
        expect(AestheneWords.normalize(['cloak', ' Patch ', 'PaNsY'])).to eq([%w[CLOAK PATCH PANSY], []])
      end

      it 'drops duplicates that differ only by case' do
        expect(AestheneWords.normalize(%w[cloak CLOAK Cloak]).first).to eq(['CLOAK'])
      end

      it 'rejects words that are not exactly five letters, reporting them as written' do
        expect(AestheneWords.normalize(%w[were sparkle yo-yo ab1de])).to eq([[], %w[were sparkle yo-yo ab1de]])
      end

      it 'rejects non-ASCII letters, which the lock cannot show' do
        # "naive" with an i-diaeresis, built from codepoints because source files must be ASCII.
        naive = [110, 97, 239, 118, 101].pack('U*')
        expect(AestheneWords.normalize([naive])).to eq([[], [naive]])
      end

      it 'recovers the word FALSE when Psych loads a bare false as a boolean' do
        expect(AestheneWords.normalize(YAML.safe_load("- false\n- cloak\n")).first).to eq(%w[FALSE CLOAK])
      end

      it 'accepts a single string instead of a list' do
        expect(AestheneWords.normalize('cloak')).to eq([['CLOAK'], []])
      end

      it 'treats a missing setting as no words' do
        expect(AestheneWords.normalize(nil)).to eq([[], []])
      end

      it 'rejects nil entries inside a list instead of crashing' do
        expect(AestheneWords.normalize(['cloak', nil])).to eq([['CLOAK'], ['']])
      end

      it 'does not mutate the caller list' do
        entries = ['cloak ']
        AestheneWords.normalize(entries)
        expect(entries).to eq(['cloak '])
      end
    end

    describe '.answers' do
      it 'appends character additions to the built-in answers' do
        expect(AestheneWords.answers(%w[POACH], %w[cloak]).first).to eq(%w[POACH CLOAK])
      end

      it 'does not duplicate an addition the built-in list already has' do
        expect(AestheneWords.answers(%w[POACH], %w[poach]).first).to eq(%w[POACH])
      end

      it 'returns rejected additions so they can be reported' do
        expect(AestheneWords.answers(%w[POACH], %w[cloak cloaks]).last).to eq(%w[cloaks])
      end

      it 'works with no additions configured' do
        expect(AestheneWords.answers(%w[POACH], nil)).to eq([%w[POACH], []])
      end
    end

    describe '.dictionary' do
      it 'leaves out words that are already known answers' do
        expect(AestheneWords.dictionary(%w[poach pansy], %w[POACH])).to eq(%w[PANSY])
      end

      it 'drops invalid dictionary entries' do
        expect(AestheneWords.dictionary(%w[pansy yo-yo], [])).to eq(%w[PANSY])
      end
    end
  end

  # -------------------------------------------------------------------
  # AestheneGrid
  # -------------------------------------------------------------------
  describe AestheneGrid do
    describe '.parse_row' do
      it 'parses a row with mixed marks' do
        row = AestheneGrid.parse_row(' | _A_ | *E* | *I* | _O_ | *U* |')
        expect(row.guess).to eq('AEIOU')
        expect(row.marks).to eq(%i[present absent absent present absent])
      end

      it 'parses a solved row' do
        expect(AestheneGrid.parse_row(' | +P+ | +O+ | +A+ | +C+ | +H+ |')).to be_solved
      end

      it 'does not call a row solved when one tile is off' do
        expect(AestheneGrid.parse_row(' | +P+ | +O+ | +A+ | +C+ | *X* |')).not_to be_solved
      end

      it 'upcases a lowercase letter' do
        expect(AestheneGrid.parse_row(' | +p+ | +o+ | +a+ | +c+ | +h+ |').guess).to eq('POACH')
      end

      it 'ignores an empty row' do
        expect(AestheneGrid.parse_row(' | ___ | ___ | ___ | ___ | ___ |')).to be_nil
      end

      it 'ignores the border and header lines' do
        expect(AestheneGrid.parse_row(' +-----+-----+-----+-----+-----+')).to be_nil
        expect(AestheneGrid.parse_row(' |  1  |  2  |  3  |  4  |  5  |')).to be_nil
      end

      it 'ignores interleaved game lines that crashed the old parser' do
        expect(AestheneGrid.parse_row('A traveler just arrived, leading a group.')).to be_nil
        expect(AestheneGrid.parse_row('[multi]>whisper lock tmprs')).to be_nil
        expect(AestheneGrid.parse_row(nil)).to be_nil
      end

      it 'rejects a tile whose two marks disagree' do
        expect(AestheneGrid.parse_row(' | +P_ | +O+ | +A+ | +C+ | +H+ |')).to be_nil
      end

      it 'parses a row that still carries a CRLF carriage return' do
        expect(AestheneGrid.parse_row(" | +T+ | +H+ | +R+ | +O+ | +W+ |\r").guess).to eq('THROW')
      end

      it 'rejects a row with only four tiles' do
        expect(AestheneGrid.parse_row(' | +P+ | +O+ | +A+ | +C+ |')).to be_nil
      end
    end

    describe AestheneGrid::Reading do
      context 'after a probe on a fresh lock' do
        let(:reading) { reading_from(AESTHENE_FIRST_PROBE_TRANSCRIPT) }

        it 'reads the one filled row despite the interleaved echo' do
          expect(reading.rows.map(&:guess)).to eq(%w[AEIOU])
        end

        it 'is waiting for the next guess' do
          expect(reading.status).to eq(:prompt)
        end

        it 'has five rows left' do
          expect(reading.rows_left).to eq(5)
        end

        it 'records the guess the game echoed' do
          expect(reading.whispered).to eq('AEIOU')
        end

        it 'is complete and consistent' do
          expect(reading).to be_grid_complete
          expect(reading).to be_consistent
        end

        it 'is not solved' do
          expect(reading).not_to be_solved
        end
      end

      context 'when the lock is solved' do
        let(:reading) { reading_from(AESTHENE_SOLVED_TRANSCRIPT) }

        it 'reports solved even though the reward line says "1 role-playing point"' do
          expect(reading.status).to eq(:solved)
          expect(reading).to be_solved
        end

        it 'reads every row, ending with the answer' do
          expect(reading.rows.map(&:guess)).to eq(%w[AEIOU BCDGN TMPRS FHKLW LIGHT])
        end
      end

      context 'when looking at a lock mid-puzzle' do
        let(:reading) { reading_from(AESTHENE_LOOK_TRANSCRIPT) }

        it 'reads every filled row' do
          expect(reading.rows.map(&:guess)).to eq(%w[AEIOU TPMRS BCDGN FHKLW])
        end

        it 'is complete without a progress prompt' do
          expect(reading).to be_grid_complete
          expect(reading.status).to be_nil
        end

        it 'has two rows left' do
          expect(reading.rows_left).to eq(2)
        end
      end

      it 'keeps only the newest grid when two are in the buffer' do
        reading = reading_from(AESTHENE_FIRST_PROBE_TRANSCRIPT.first(5) + AESTHENE_SOLVED_TRANSCRIPT)
        expect(reading.rows.first.guess).to eq('AEIOU')
        expect(reading.rows.size).to eq(5)
      end

      it 'flags a reading whose row count disagrees with the status line' do
        lines = AESTHENE_SOLVED_TRANSCRIPT.reject { |line| line.include?('_G_') }
        expect(reading_from(lines)).not_to be_consistent
      end

      it 'is not complete before the legend arrives' do
        expect(reading_from(AESTHENE_FIRST_PROBE_TRANSCRIPT.first(13))).not_to be_grid_complete
      end

      it 'is out of rows once all six are used' do
        expect(reading_from(['[6 of the 6 rows are locked into place.]'])).to be_out_of_rows
      end

      it 'never reports negative rows left' do
        expect(reading_from(['[7 of the 6 rows are locked into place.]']).rows_left).to eq(0)
      end

      it 'recognizes a whisper to a lock you are not attuned to' do
        reading = reading_from(['You whisper quietly to the lock.  It doesn\'t respond.',
                                '[You are not currently tasked with solving the puzzle.  TOUCH the lock to begin.]'])
        expect(reading.status).to eq(:not_tasked)
      end

      it 'recognizes having no pass' do
        reading = reading_from(['[To interact with the lock, you must redeem a pass for the event.  Passes are available in the SimuCoin store via the website.  Once redeemed, simply TOUCH the lock!]'])
        expect(reading.status).to eq(:no_pass)
      end

      it 'keeps the first decisive status' do
        reading = reading_from(['[LOOK at the lock for an update on your progress!]',
                                '[You are not currently tasked with solving the puzzle.  TOUCH the lock to begin.]'])
        expect(reading.status).to eq(:prompt)
      end
    end
  end

  # -------------------------------------------------------------------
  # AestheneSolver
  # -------------------------------------------------------------------
  describe AestheneSolver do
    describe '.feedback_code' do
      it 'scores the answer itself as all hits' do
        expect(AestheneSolver.feedback_code('POACH', 'POACH')).to eq(AestheneSolver::ALL_HIT)
      end

      it 'scores a guess with no shared letters as zero' do
        expect(AestheneSolver.feedback_code('BUILT', 'POACH')).to eq(0)
      end

      it 'marks both copies of a repeated letter present when the answer has two' do
        # LEVEL vs HELLO: present, hit, absent, absent, present.
        expect(AestheneSolver.feedback_code('LEVEL', 'HELLO')).to eq(136)
      end

      it 'marks an extra copy of a letter absent once the answer runs out' do
        # EERIE vs THREE: present, absent, hit, absent, hit.
        expect(AestheneSolver.feedback_code('EERIE', 'THREE')).to eq(101)
      end
    end

    describe '.fits?' do
      def row(guess, *marks)
        AestheneGrid::Row.new(guess, marks)
      end

      it 'requires a hit letter in that exact place' do
        hit_first = row('PXXXX', :hit, :absent, :absent, :absent, :absent)
        expect(AestheneSolver.fits?('POACH', hit_first)).to be(true)
        expect(AestheneSolver.fits?('APOCH', hit_first)).to be(false)
      end

      it 'requires a present letter somewhere else' do
        present_first = row('OXXXX', :present, :absent, :absent, :absent, :absent)
        expect(AestheneSolver.fits?('POACH', present_first)).to be(true)
        expect(AestheneSolver.fits?('OPACH', present_first)).to be(false)
        expect(AestheneSolver.fits?('PLACE', present_first)).to be(false)
      end

      it 'rules out a word containing an absent letter' do
        expect(AestheneSolver.fits?('POACH', row('ZXXXX', :absent, :absent, :absent, :absent, :absent))).to be(true)
        expect(AestheneSolver.fits?('ZEBRA', row('ZXXXX', :absent, :absent, :absent, :absent, :absent))).to be(false)
      end

      it 'treats a letter both confirmed and starred in one row as an exact count' do
        # One E present, one E starred: the answer has exactly one E, not at 1 or 2.
        one_e = row('EEZZZ', :present, :absent, :absent, :absent, :absent)
        expect(AestheneSolver.fits?('CRANE', one_e)).to be(true)
        # GREET passes every per-tile check; only the count rules it out.
        expect(AestheneSolver.fits?('GREET', one_e)).to be(false)
      end

      it 'keeps the answer that produced a row with a repeated letter' do
        # The game's real feedback for EERIE against THREE.
        expect(AestheneSolver.fits?('THREE', row_for('EERIE', 'THREE'))).to be(true)
      end

      it 'does not demand two copies when both repeated tiles are marked present' do
        # If the game marks every copy present, HYDRA (one A) must survive.
        double_a = row('AAXXX', :present, :present, :absent, :absent, :absent)
        expect(AestheneSolver.fits?('HYDRA', double_a)).to be(true)
      end
    end

    describe '#observe' do
      let(:answers) { %w[BANJO CLOAK CORAL LOACH POACH PANSY] }
      let(:solver) { AestheneSolver.new(answers, []) }
      let(:probe_rows) { AESTHENE_POACH_PROBE_ROWS.map { |line| AestheneGrid.parse_row(line) } }

      it 'narrows the POACH lock to four answers after two probes' do
        expect(solver.observe(probe_rows.first(2))).to eq(%w[CLOAK CORAL LOACH POACH])
      end

      it 'narrows the POACH lock to POACH after three probes' do
        expect(solver.observe(probe_rows.first(3))).to eq(%w[POACH])
      end

      it 're-derives from the rows given, so fewer rows widens the candidates again' do
        solver.observe(probe_rows)
        expect(solver.observe([])).to eq(answers)
      end

      it 'stays on the known answers while one still fits' do
        solver.observe(probe_rows)
        expect(solver).not_to be_fallback
      end
    end

    describe 'dictionary fallback' do
      let(:solver) { AestheneSolver.new(%w[POACH], %w[PANSY PATCH]) }

      it 'switches to the dictionary when feedback rules out every known answer' do
        expect(solver.observe([row_for('PANSY', 'PANSY')])).to eq(%w[PANSY])
        expect(solver).to be_fallback
      end

      it 'returns no candidates and no guess when nothing anywhere fits' do
        solver.observe([row_for('ZZZZZ', 'POACH'), row_for('PANSY', 'QUERY'), row_for('PATCH', 'QUERY')])
        expect(solver.candidates).to be_empty
        expect(solver.next_guess(3)).to be_nil
      end
    end

    describe '#next_guess' do
      it 'guesses the only candidate' do
        solver = AestheneSolver.new(%w[POACH], [])
        expect(solver.next_guess(6)).to eq('POACH')
      end

      it 'guesses a candidate, never a probe, on the last row' do
        solver = AestheneSolver.new(%w[CLOAK CORAL LOACH POACH], [])
        expect(%w[CLOAK CORAL LOACH POACH]).to include(solver.next_guess(1))
      end

      it 'never repeats a probe already on the lock' do
        solver = AestheneSolver.new(%w[CLOAK CORAL LOACH POACH BANJO PANSY], [])
        solver.observe([AestheneGrid::Row.new('AEIOU', %i[absent absent absent absent absent])])
        expect(solver.next_guess(5)).not_to eq('AEIOU')
      end

      it 'picks a guess that separates every candidate when one exists' do
        candidates = %w[CLOAK CORAL LOACH POACH]
        solver = AestheneSolver.new(candidates, [])
        guess = solver.next_guess(2)
        codes = candidates.map { |answer| AestheneSolver.feedback_code(guess, answer) }
        expect(codes.uniq.size).to eq(candidates.size)
      end

      it 'is deterministic for the same candidates' do
        a = AestheneSolver.new(%w[CLOAK CORAL LOACH POACH BANJO PANSY], []).next_guess(6)
        b = AestheneSolver.new(%w[CLOAK CORAL LOACH POACH BANJO PANSY], []).next_guess(6)
        expect(a).to eq(b)
      end

      context 'when hedging toward unlisted words' do
        # FHKLW tells all four words apart (F, K, H and L each show present);
        # guessing the known answer ABCDF only separates ABCDF itself.
        let(:solver) { AestheneSolver.new(%w[ABCDF ABCDK], %w[ABCDH ABCDL]) }

        it 'goes straight for a known answer when unlisted words carry no weight' do
          stub_const('AestheneSolver::HEDGE_WEIGHT', 0.0)
          expect(solver.next_guess(3)).to eq('ABCDF')
        end

        it 'prefers a guess that also splits the unlisted words when they carry weight' do
          stub_const('AestheneSolver::HEDGE_WEIGHT', 0.5)
          expect(solver.next_guess(3)).to eq('FHKLW')
        end

        it 'still offers only known answers as candidates' do
          expect(solver.candidates).to eq(%w[ABCDF ABCDK])
          expect(solver).not_to be_fallback
        end
      end

      context 'with a precomputed opening' do
        let(:solver) { AestheneSolver.new(%w[CLOAK CORAL LOACH POACH], [], opening: 'RAISE') }

        it 'opens with it on an empty lock' do
          expect(solver.next_guess(6)).to eq('RAISE')
        end

        it 'stops using it once the lock has a row' do
          solver.observe([row_for('RAISE', 'POACH')])
          expect(solver.next_guess(5)).not_to eq('RAISE')
        end

        it 'still guesses the answer outright when only one fits' do
          single = AestheneSolver.new(%w[POACH], [], opening: 'RAISE')
          expect(single.next_guess(6)).to eq('POACH')
        end
      end

      it 'solves every answer in a small list within six guesses' do
        answers = %w[POACH THROW ANLAS PANSY HYDRA LIGHT HORSE LANKY CLOAK PATCH CORAL LOACH]
        answers.each do |answer|
          solver = AestheneSolver.new(answers, [])
          rows = []
          6.times do
            solver.observe(rows)
            guess = solver.next_guess(6 - rows.size)
            rows << row_for(guess, answer)
            break if guess == answer
          end
          expect(rows.last.guess).to eq(answer), "failed to solve #{answer}: #{rows.map(&:guess)}"
        end
      end
    end
  end

  # -------------------------------------------------------------------
  # Aesthene (game I/O)
  # -------------------------------------------------------------------
  describe Aesthene do
    let(:instance) { Aesthene.allocate }
    let(:solver) { AestheneSolver.new(%w[CLOAK CORAL LOACH POACH], []) }

    before do
      stub_const('Aesthene::READ_TIMEOUT', 0.2)
      stub_const('Aesthene::SOLVE_GRACE', 0.05)
      instance.instance_variable_set(:@solver, solver)
      instance.instance_variable_set(:@builtin_answers, %w[CLOAK CORAL LOACH POACH])
    end

    describe '#initialize' do
      before do
        $test_data = OpenStruct.new(aesthene: OpenStruct.new(lock_answers: %w[POACH], dictionary: []))
        allow(instance).to receive(:check_lock)
        allow(instance).to receive(:attune_and_solve)
        allow(instance).to receive(:redeem_slip)
      end

      it 'only reads the lock for check' do
        $parsed_args = OpenStruct.new(check: true)
        instance.send(:initialize)
        expect(instance).to have_received(:check_lock)
        expect(instance).not_to have_received(:redeem_slip)
        expect(instance).not_to have_received(:attune_and_solve)
      end

      it 'solves in place without redeeming for solve' do
        $parsed_args = OpenStruct.new(solve: true)
        instance.send(:initialize)
        expect(instance).to have_received(:attune_and_solve)
        expect(instance).not_to have_received(:redeem_slip)
      end

      it 'redeems a slip and then solves for full' do
        $parsed_args = OpenStruct.new(full: true)
        instance.send(:initialize)
        expect(instance).to have_received(:redeem_slip).ordered
        expect(instance).to have_received(:attune_and_solve).ordered
      end

      it 'loads the aesthene data file' do
        $parsed_args = OpenStruct.new(check: true)
        instance.send(:initialize)
        expect($data_called_with).to include('aesthene')
      end

      it 'remembers the built-in answers apart from the character additions' do
        $parsed_args = OpenStruct.new(check: true)
        $test_settings = OpenStruct.new(aesthene_lock_answers: %w[cloak])
        instance.send(:initialize)
        expect(instance.instance_variable_get(:@builtin_answers)).to eq(%w[POACH])
      end
    end

    describe '#build_solver' do
      let(:data) { OpenStruct.new(lock_answers: %w[POACH], dictionary: %w[PANSY]) }

      it 'adds the aesthene_lock_answers setting to the known answers' do
        built = instance.build_solver(data, OpenStruct.new(aesthene_lock_answers: %w[cloak]))
        expect(built.observe([])).to eq(%w[POACH CLOAK])
      end

      it 'reports additions that are not five letters, and keeps the rest' do
        allow(DRC).to receive(:message)
        built = instance.build_solver(data, OpenStruct.new(aesthene_lock_answers: %w[cloak cloaks]))
        expect(DRC).to have_received(:message).with(/cloaks/)
        expect(built.observe([])).to eq(%w[POACH CLOAK])
      end

      it 'stops when the data file is missing and there are no additions' do
        expect { instance.build_solver(nil, OpenStruct.new) }.to raise_error(SystemExit)
      end

      it 'uses the opening from the data file' do
        built = instance.build_solver(OpenStruct.new(lock_answers: %w[CLOAK CORAL POACH], dictionary: [], opening: 'raise'), OpenStruct.new)
        expect(built.next_guess(6)).to eq('RAISE')
      end

      it 'computes the opening itself when the data file has no valid one' do
        built = instance.build_solver(OpenStruct.new(lock_answers: %w[CLOAK CORAL POACH], dictionary: [], opening: 'raises'), OpenStruct.new)
        expect(built.next_guess(6)).not_to eq('RAISES')
        expect(built.next_guess(6)).to match(/\A[A-Z]{5}\z/)
      end

      it 'still runs from additions alone when the data file is missing' do
        built = instance.build_solver(nil, OpenStruct.new(aesthene_lock_answers: %w[cloak]))
        expect(built.observe([])).to eq(%w[CLOAK])
      end
    end

    describe '#redeem_slip' do
      let(:confirm) { "Once you redeem this, you'll have 1 instance access to the Aesthene's Close.  If you're prepared to immediately begin, repeat the command within 10 seconds." }
      let(:redeemed) { "[You have just redeemed 1 instance of access to a task to earn chronocoins from the Timekeepers at Aesthene's Close.  Be sure to ASK TIMEKEEPER ABOUT ACCESS to be moved in!]" }
      let(:escorted) { 'The apprentice Timekeeper shows you to a time lock, and explains "There are thousands of these throughout the area."' }

      it 'redeems twice, then asks for access' do
        allow(DRC).to receive(:bput).and_return(confirm, redeemed, escorted)
        instance.redeem_slip
        expect(DRC).to have_received(:bput).with('redeem my slip', any_args).twice
        expect(DRC).to have_received(:bput).with('ask timekeeper about access', any_args)
      end

      it 'stops when it cannot reach the Timekeeper' do
        allow(DRCT).to receive(:walk_to).and_return(false)
        allow(DRC).to receive(:bput)
        expect { instance.redeem_slip }.to raise_error(SystemExit)
        expect(DRC).not_to have_received(:bput)
      end

      it 'stops before redeeming when there is no time slip' do
        allow(DRCI).to receive(:get_item?).and_return(false)
        allow(DRC).to receive(:bput)
        expect { instance.redeem_slip }.to raise_error(SystemExit)
        expect(DRC).not_to have_received(:bput)
      end

      it 'does not fetch another slip when one is already in hand' do
        allow(DRCI).to receive(:in_hands?).and_return(true)
        allow(DRCI).to receive(:get_item?)
        allow(DRC).to receive(:bput).and_return(confirm, redeemed, escorted)
        instance.redeem_slip
        expect(DRCI).not_to have_received(:get_item?)
      end

      it 'stows the slip and stops when the Timekeeper does not take it' do
        allow(DRCI).to receive(:stow_item?)
        allow(DRC).to receive(:bput).and_return(confirm, "The representative for a task to earn chronocoins from the Timekeepers at Aesthene's Close isn't here!")
        expect { instance.redeem_slip }.to raise_error(SystemExit)
        expect(DRCI).to have_received(:stow_item?).with('time slip')
      end

      it 'stops when the Timekeeper does not take you to a lock' do
        allow(DRC).to receive(:bput).and_return(confirm, redeemed, '')
        expect { instance.redeem_slip }.to raise_error(SystemExit)
      end
    end

    describe '#attune_to_lock' do
      let(:confirm) { "[This will consume a pass for Aesthene's Close.  If you're sure you want to do this, TOUCH the lock again within 15 seconds.]" }
      let(:attuned) { 'You reach out and touch the lock, and an alarming pulse of energy surges from it and through you.' }

      it 'touches twice and starts from an empty grid' do
        allow(DRC).to receive(:bput).and_return(confirm, attuned)
        reading = instance.attune_to_lock
        expect(DRC).to have_received(:bput).with('touch lock', any_args).twice
        expect(reading.rows).to be_empty
        expect(reading.rows_left).to eq(6)
      end

      it 'reads the grid when already attuned, to resume the lock' do
        allow(DRC).to receive(:bput).and_return('You are already connected to the lock.')
        allow(instance).to receive(:look_at_lock).and_return(:current_grid)
        expect(instance.attune_to_lock).to eq(:current_grid)
      end

      it 'stops when there is no pass' do
        allow(DRC).to receive(:bput).and_return('[To interact with the lock, you must redeem a pass for the event.]')
        expect { instance.attune_to_lock }.to raise_error(SystemExit)
      end

      it 'stops when there is no lock to touch' do
        allow(DRC).to receive(:bput).and_return('')
        expect { instance.attune_to_lock }.to raise_error(SystemExit)
      end
    end

    describe '#read_lock' do
      it 'sends the command and reads the grid past interleaved lines' do
        $history = AESTHENE_FIRST_PROBE_TRANSCRIPT.dup
        reading = instance.read_lock('whisper lock aeiou')
        expect(drain_sent_messages).to eq(['whisper lock aeiou'])
        expect(reading.rows.map(&:guess)).to eq(%w[AEIOU])
        expect(reading.status).to eq(:prompt)
      end

      it 'stops at the solved message' do
        $history = AESTHENE_SOLVED_TRANSCRIPT.dup + ['An attendant runs up and thrusts 100 chronocoins at you.']
        expect(instance.read_lock('whisper lock light')).to be_solved
        expect($history).not_to be_empty
      end

      it 'stops at the legend for a look, which has no progress prompt' do
        $history = AESTHENE_FIRST_PROBE_TRANSCRIPT[1..16] + ['Unrelated line after the look.']
        reading = instance.read_lock('look lock')
        expect(reading).to be_grid_complete
        expect($history).to eq(['Unrelated line after the look.'])
      end

      it 'returns an incomplete reading when the game says nothing' do
        $history = []
        expect(instance.read_lock('look lock')).not_to be_grid_complete
      end
    end

    describe '#whisper' do
      it 'returns the reading for the guess' do
        allow(instance).to receive(:read_lock).and_return(reading_from(AESTHENE_FIRST_PROBE_TRANSCRIPT))
        expect(instance.whisper('AEIOU').rows.last.guess).to eq('AEIOU')
        expect(instance).to have_received(:read_lock).with('whisper lock aeiou')
      end

      it 'stops when the lock says you are not attuned' do
        allow(instance).to receive(:read_lock).and_return(reading_from(['[You are not currently tasked with solving the puzzle.  TOUCH the lock to begin.]']))
        expect { instance.whisper('AEIOU') }.to raise_error(SystemExit)
      end

      it 'looks at the lock again when rows were missed' do
        partial = reading_from(AESTHENE_SOLVED_TRANSCRIPT.reject { |line| line.include?('_G_') })
        allow(instance).to receive(:read_lock).and_return(partial)
        allow(instance).to receive(:look_at_lock).and_return(reading_from(AESTHENE_SOLVED_TRANSCRIPT))
        expect(instance.whisper('LIGHT').rows.size).to eq(5)
        expect(instance).to have_received(:look_at_lock)
      end

      it 'warns when the last row is not the guess it sent' do
        allow(DRC).to receive(:message)
        allow(instance).to receive(:read_lock).and_return(reading_from(AESTHENE_FIRST_PROBE_TRANSCRIPT))
        instance.whisper('POACH')
        expect(DRC).to have_received(:message).with(/expected the last row to be POACH but read AEIOU/)
      end
    end

    describe '#solve' do
      # Answers each whisper as the lock would for a hidden answer.
      def play_lock(answer)
        rows = []
        allow(instance).to receive(:whisper) do |guess|
          rows += [row_for(guess, answer)]
          reading = AestheneGrid::Reading.new
          reading.instance_variable_set(:@rows, rows)
          reading.instance_variable_set(:@locked, rows.size)
          reading
        end
      end

      before { allow(DRC).to receive(:message) }

      it 'solves a known answer and announces it' do
        play_lock('POACH')
        instance.solve(AestheneGrid::Reading.new)
        expect(DRC).to have_received(:message).with('aesthene: solved! The word was POACH.')
      end

      it 'does not ask for a report when the built-in list has the answer' do
        play_lock('POACH')
        instance.solve(AestheneGrid::Reading.new)
        expect(DRC).not_to have_received(:message).with(/lich discord/)
      end

      context 'when only the dictionary had the answer' do
        before do
          instance.instance_variable_set(:@builtin_answers, %w[CLOAK])
          instance.instance_variable_set(:@solver, AestheneSolver.new(%w[CLOAK], %w[PANSY]))
          play_lock('PANSY')
          instance.solve(AestheneGrid::Reading.new)
        end

        it 'asks you to post the word on Discord' do
          expect(DRC).to have_received(:message).with(/PANSY is not in the built-in answer list\. Please post it in the lich discord \(listed in .*links\) so it can be added to the built-in list for everyone\./)
        end

        it 'tells you to add it to your YAML meanwhile' do
          expect(DRC).to have_received(:message).with('aesthene: until then, add PANSY to aesthene_lock_answers in your YAML.')
        end
      end

      context 'when the answer came from your aesthene_lock_answers' do
        before do
          # PANSY is a known answer only because the character added it.
          instance.instance_variable_set(:@builtin_answers, %w[CLOAK])
          instance.instance_variable_set(:@solver, AestheneSolver.new(%w[CLOAK PANSY], []))
          play_lock('PANSY')
          instance.solve(AestheneGrid::Reading.new)
        end

        it 'still asks you to post the word on Discord' do
          expect(DRC).to have_received(:message).with(/PANSY is not in the built-in answer list\. Please post it in the lich discord/)
        end

        it 'does not tell you to add a word you already added' do
          expect(DRC).not_to have_received(:message).with(/until then/)
        end
      end

      context 'when no word in any list fits' do
        before do
          play_lock('QUERY')
          instance.instance_variable_set(:@solver, AestheneSolver.new(%w[CORAL], []))
          instance.solve(reading_from([' | *C* | *O* | *R* | *A* | *L* |', '[1 of the 6 rows are locked into place.]']))
        end

        it 'stops without whispering' do
          expect(instance).not_to have_received(:whisper)
          expect(DRC).to have_received(:message).with(/no word in the lists fits the feedback/)
        end

        it 'asks you to finish by hand and post the answer on Discord' do
          expect(DRC).to have_received(:message).with(/the answer is not in any word list\. Finish the lock by hand, then please post the answer in the lich discord/)
        end
      end

      it 'reports failure when the lock has no rows left' do
        play_lock('POACH')
        instance.solve(reading_from(['[6 of the 6 rows are locked into place.]']))
        expect(instance).not_to have_received(:whisper)
        expect(DRC).to have_received(:message).with(/the lock has no rows left/)
      end

      it 'stops when two whispers in a row add no row' do
        stuck = reading_from(['[1 of the 6 rows are locked into place.]'])
        calls = 0
        allow(instance).to receive(:whisper) do
          raise 'solve kept whispering' if (calls += 1) > 5

          stuck
        end
        instance.solve(stuck)
        expect(instance).to have_received(:whisper).twice
        expect(DRC).to have_received(:message).with(/2 whispers in a row added no row to the lock/)
      end

      it 'keeps going after a single whisper that adds no row' do
        rows = []
        calls = 0
        allow(instance).to receive(:whisper) do |guess|
          # The first whisper is lost; the rest land as on a real lock.
          rows += [row_for(guess, 'POACH')] unless (calls += 1) == 1
          reading = AestheneGrid::Reading.new
          reading.instance_variable_set(:@rows, rows)
          reading.instance_variable_set(:@locked, rows.size)
          reading
        end
        instance.solve(AestheneGrid::Reading.new)
        expect(DRC).to have_received(:message).with('aesthene: solved! The word was POACH.')
      end

      it 'finishes a resumed lock from its current grid' do
        play_lock('POACH')
        resumed = reading_from(AESTHENE_POACH_PROBE_ROWS.first(3) + ['[3 of the 6 rows are locked into place.]'])
        instance.solve(resumed)
        expect(instance).to have_received(:whisper).once.with('POACH')
      end
    end

    describe '#check_lock' do
      before { allow(DRC).to receive(:message) }

      it 'lists the possible answers and suggests a guess without whispering' do
        reading = reading_from(AESTHENE_POACH_PROBE_ROWS.first(2) + ['[2 of the 6 rows are locked into place.]', "[* indicates a wrong letter that isn't used in the final word.]"])
        allow(instance).to receive(:look_at_lock).and_return(reading)
        allow(instance).to receive(:whisper)
        instance.check_lock
        expect(DRC).to have_received(:message).with('aesthene: 4 possible known answers: CLOAK, CORAL, LOACH, POACH')
        expect(DRC).to have_received(:message).with(/suggested guess: [A-Z]{5}/)
        expect(instance).not_to have_received(:whisper)
      end

      it 'reads real LOOK output end to end and names the only answer left' do
        instance.instance_variable_set(:@solver, AestheneSolver.new(%w[BLOOD CROOK ORLOG PHLOX THROW], []))
        $history = AESTHENE_LOOK_TRANSCRIPT.dup
        instance.check_lock
        expect(drain_sent_messages).to eq(['look lock'])
        expect(DRC).to have_received(:message).with('aesthene: 1 possible known answer: THROW')
        expect(DRC).to have_received(:message).with('aesthene: suggested guess: THROW')
      end

      it 'asks for the answer to be reported when nothing fits the lock' do
        instance.instance_variable_set(:@solver, AestheneSolver.new(%w[CORAL], []))
        allow(instance).to receive(:look_at_lock).and_return(reading_from([' | *C* | *O* | *R* | *A* | *L* |', '[1 of the 6 rows are locked into place.]']))
        instance.check_lock
        expect(DRC).to have_received(:message).with(/the answer is not in any word list\..*lich discord/)
        expect(DRC).not_to have_received(:message).with(/suggested guess/)
      end

      it 'truncates a long candidate list' do
        many = Array.new(Aesthene::LIST_LIMIT + 5) { |i| "W#{format('%04d', i).tr('0-9', 'A-J')}" }
        instance.instance_variable_set(:@solver, AestheneSolver.new(many, []))
        allow(instance).to receive(:look_at_lock).and_return(AestheneGrid::Reading.new)
        instance.check_lock
        expect(DRC).to have_received(:message).with(/\.\.\. \(5 more\)/)
      end
    end
  end

  # -------------------------------------------------------------------
  # End to end against a simulated lock
  # -------------------------------------------------------------------
  describe 'a full run against a simulated lock' do
    let(:answers) { %w[CLOAK CORAL LOACH POACH THROW HYDRA] }
    let(:dictionary) { %w[PANSY PATCH QUERY] }
    let(:messages) { [] }

    # Runs the script's entry point with every game command answered by the lock.
    #
    # RSpec does not rescue SystemExit, so an unexpected exit would end the
    # whole suite and report what had run so far as passing. It is turned into
    # a failure here unless the example expects the script to stop.
    def run_script(lock, mode, exits: false)
      $parsed_args = OpenStruct.new(mode => true)
      $test_data = OpenStruct.new(aesthene: OpenStruct.new(lock_answers: answers, dictionary: dictionary))
      $history = []
      script = Aesthene.allocate
      allow(script).to receive(:put) { |command| $history.concat(lock.reply(command)) }
      # Lich's clear empties the script's line buffer.
      allow(script).to receive(:clear) { $history.clear }
      allow(DRC).to receive(:bput) do |command, *patterns|
        lock.reply(command).find { |line| patterns.any? { |pattern| line.match?(pattern) } } || ''
      end
      allow(DRC).to receive(:message) { |text| messages << text }
      begin
        script.send(:initialize)
      rescue SystemExit
        raise if exits

        raise "the script exited early; last message: #{messages.last.inspect}"
      end
    end

    def whispers(lock)
      lock.commands.grep(/\Awhisper lock /)
    end

    before do
      stub_const('Aesthene::READ_TIMEOUT', 0.2)
      stub_const('Aesthene::SOLVE_GRACE', 0.05)
    end

    it 'redeems, attunes and solves a known answer with ;aesthene full' do
      lock = AestheneFakeLock.new('POACH')
      run_script(lock, :full)
      expect(lock.commands.first(5)).to eq(['redeem my slip', 'redeem my slip', 'ask timekeeper about access', 'touch lock', 'touch lock'])
      expect(whispers(lock).last).to eq('whisper lock poach')
      expect(messages).to include('aesthene: solved! The word was POACH.')
      expect(messages.grep(/lich discord/)).to be_empty
    end

    it 'solves in at most six whispers for every known answer' do
      answers.each do |answer|
        lock = AestheneFakeLock.new(answer, passes: 1)
        messages.clear
        run_script(lock, :solve)
        expect(messages).to include("aesthene: solved! The word was #{answer}."), "#{answer}: #{whispers(lock)}"
        expect(whispers(lock).size).to be <= 6
      end
    end

    it 'solves a dictionary-only answer and asks for it on Discord' do
      lock = AestheneFakeLock.new('PANSY', passes: 1)
      run_script(lock, :solve)
      expect(messages).to include('aesthene: solved! The word was PANSY.')
      expect(messages.grep(/PANSY is not in the built-in answer list\. Please post it in the lich discord/)).not_to be_empty
    end

    it 'resumes a lock that is already part-solved' do
      lock = AestheneFakeLock.new('THROW', attuned_rows: %w[AEIOU TPMRS])
      run_script(lock, :solve)
      expect(lock.commands.first(2)).to eq(['touch lock', 'look lock'])
      expect(messages).to include('aesthene: solved! The word was THROW.')
    end

    it 'looks at the lock again when a whisper reply misses a row, and still solves' do
      lock = AestheneFakeLock.new('HYDRA', passes: 1)
      lock.drop_a_row_next_whisper
      run_script(lock, :solve)
      expect(lock.commands[3]).to eq('look lock')
      expect(messages).to include('aesthene: solved! The word was HYDRA.')
    end

    it 'whispers the same guess again when the lock does not take it once, and still solves' do
      lock = AestheneFakeLock.new('POACH', passes: 1)
      lock.ignore_whispers(1)
      run_script(lock, :solve)
      expect(whispers(lock).first(2).uniq.size).to eq(1)
      expect(messages).to include('aesthene: solved! The word was POACH.')
    end

    it 'stops after two whispers in a row that add no row, and lists what is still possible' do
      lock = AestheneFakeLock.new('POACH', passes: 1)
      lock.ignore_whispers(Float::INFINITY)
      run_script(lock, :solve)
      expect(whispers(lock).size).to eq(2)
      expect(whispers(lock).uniq.size).to eq(1)
      expect(messages.grep(/couldn't solve the lock: 2 whispers in a row added no row to the lock\./)).not_to be_empty
      expect(messages.grep(/possible known answers: CLOAK, CORAL/)).not_to be_empty
    end

    it 'stops with a message when there is no pass to attune with' do
      lock = AestheneFakeLock.new('POACH')
      expect { run_script(lock, :solve, exits: true) }.to raise_error(SystemExit)
      expect(messages).to include('aesthene: you need a redeemed pass. Try ;aesthene full.')
      expect(whispers(lock)).to be_empty
    end

    it 'checks a lock without whispering' do
      lock = AestheneFakeLock.new('THROW', attuned_rows: %w[AEIOU TPMRS])
      run_script(lock, :check)
      expect(lock.commands).to eq(['look lock'])
      expect(messages.grep(/possible known answer/)).not_to be_empty
    end
  end

  # -------------------------------------------------------------------
  # Shipped files
  # -------------------------------------------------------------------
  describe 'shipped files' do
    let(:data) { YAML.safe_load_file(File.join(__dir__, '..', 'data', 'base-aesthene.yaml')) }

    it 'has no bare "word:" line, which Lich would split into a label' do
      labels = File.readlines(lic_path('aesthene.lic')).grep(/^[\w]+:$/)
      expect(labels).to be_empty
    end

    it 'ships only valid, unique lock answers' do
      valid, rejected = AestheneWords.normalize(data['lock_answers'])
      expect(rejected).to be_empty
      expect(valid.size).to eq(data['lock_answers'].size)
    end

    it 'ships only valid, unique dictionary words' do
      valid, rejected = AestheneWords.normalize(data['dictionary'])
      expect(rejected).to be_empty
      expect(valid.size).to eq(data['dictionary'].size)
    end

    it 'keeps the dictionary disjoint from the answers' do
      expect(data['dictionary'] & data['lock_answers']).to be_empty
    end

    # Slow (several seconds): scores every answer against the full guess pool.
    it 'ships the opening the solver would compute from these lists' do
      answers, = AestheneWords.answers(data['lock_answers'], nil)
      dictionary = AestheneWords.dictionary(data['dictionary'], answers)
      expect(AestheneSolver.new(answers, dictionary).next_guess(6)).to eq(data['opening'])
    end

    it 'loads FALSE as a word, not a boolean' do
      expect(data['dictionary']).to include('FALSE')
    end

    it 'knows every answer solved in the reference session log, and the two the old list missed' do
      expect(data['lock_answers']).to include('POACH', 'THROW', 'ANLAS', 'PANSY', 'HYDRA', 'LIGHT', 'HORSE', 'LANKY', 'CLOAK', 'PATCH')
    end
  end
end
