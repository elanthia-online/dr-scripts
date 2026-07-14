# frozen_string_literal: true

require 'sqlite3'
require 'tmpdir'
require 'ostruct'
require 'fileutils'

# Test suite for status-monitor.lic
#
# Covers MessageStore, MessageFilter, SpamDetector, CommandDetector,
# and Monitor orchestration. Aggressively tests edge cases, boundary
# conditions, and error paths.

$echo_messages = []
def echo(msg)
  $echo_messages << msg
end

def checkname
  'Testchar'
end

def pause(_duration = 0)
  # no-op in tests
end

$fput_commands = []
# Ordered log of observable side effects (fput and Slack sends), used to assert
# relative ordering across the two sinks.
$event_log = []
def fput(cmd)
  $fput_commands << cmd
  $event_log << [:fput, cmd]
end

module UserVars
  def self.npcs; []; end
  def self.players_online; nil; end
end unless defined?(UserVars)

# Minimal fake SlackBot so AlertHandler's delivery path can be exercised
# without any network or lnet dependency. Records direct_message calls and
# lets a test dictate whether the bot reports itself as initialized.
module Lich
  module DragonRealms
    class SlackBot
      class << self
        attr_accessor :next_initialized
        attr_reader :instances
      end
      @instances = []

      attr_reader :dm_calls

      def initialize
        @initialized = self.class.next_initialized
        @dm_calls = []
        self.class.instances << self
      end

      def initialized?
        @initialized
      end

      def direct_message(username, message)
        @dm_calls << [username, message]
        $event_log << [:slack, message]
        { 'ok' => true }
      end
    end
  end
end unless defined?(Lich::DragonRealms::SlackBot)

# Extract the StatusMonitor module from the .lic file (lines 22-561).
# Skip the top-level Lich runtime code (status_tags, parse_args, etc).
monitor_path = File.join(File.dirname(__FILE__), '..', 'status-monitor.lic')
monitor_lines = File.readlines(monitor_path)

module_start = monitor_lines.index { |l| l =~ /^module StatusMonitor$/ }
raise "Could not find 'module StatusMonitor' in status-monitor.lic" unless module_start

module_end = nil
(module_start + 1...monitor_lines.size).each do |i|
  if monitor_lines[i] =~ /^end\s*$/
    module_end = i
    break
  end
end
raise 'Could not find matching end for module StatusMonitor' unless module_end

module_source = monitor_lines[module_start..module_end].join
eval(module_source, TOPLEVEL_BINDING, monitor_path, module_start + 1)

# ---------------------------------------------------------------------------
# SpamDetector -- pure logic, highest-value target
# ---------------------------------------------------------------------------
RSpec.describe StatusMonitor::SpamDetector do
  def make_settings(unique: 3, frequency: 5, similarity: 80)
    OpenStruct.new(
      unique_line_threshold: unique,
      line_frequency_threshold: frequency,
      line_similarity_percentage: similarity
    )
  end

  before { $echo_messages.clear }

  describe '#check' do
    context 'repeat threshold' do
      it 'fires when the same line exceeds unique_line_threshold' do
        detector = described_class.new(make_settings(unique: 2))
        expect(detector.check('hello')).to be_nil
        expect(detector.check('hello')).to be_nil
        alert = detector.check('hello')
        expect(alert).not_to be_nil
        expect(alert[:line]).to eq('hello')
      end

      it 'does not fire when count equals threshold (only exceeds)' do
        detector = described_class.new(make_settings(unique: 3))
        3.times { detector.check('hello') }
        expect($echo_messages).to be_empty
      end

      it 'fires at threshold + 1' do
        detector = described_class.new(make_settings(unique: 3))
        3.times { detector.check('hello') }
        alert = detector.check('hello')
        expect(alert).not_to be_nil
      end

      it 'with threshold 1, fires on the second occurrence' do
        detector = described_class.new(make_settings(unique: 1))
        expect(detector.check('test')).to be_nil
        alert = detector.check('test')
        expect(alert).not_to be_nil
      end

      it 'resets buffers after firing so subsequent checks restart' do
        detector = described_class.new(make_settings(unique: 1))
        detector.check('x')
        detector.check('x')
        alert = detector.check('x')
        expect(alert).to be_nil
      end
    end

    context 'time-windowed counts' do
      it 'retains all entries within the 90-second window' do
        detector = described_class.new(make_settings(unique: 100))
        25.times { |i| detector.check("line_#{i}") }
        # With time-windowed counts, line_0 is still tracked (within 90s)
        # Sending it again increments its count to 2, triggering the dedup guard
        result = detector.check('line_0')
        expect(result).to be_nil
      end
    end

    context 'returns nil for second occurrence (dedup guard)' do
      it 'returns nil when a line appears exactly twice (count > 1 guard)' do
        detector = described_class.new(make_settings(unique: 10, similarity: 0))
        detector.check('aaa')
        result = detector.check('aaa')
        expect(result).to be_nil
      end
    end

    context 'with empty and nil-like inputs' do
      it 'handles empty string without error' do
        detector = described_class.new(make_settings)
        expect { detector.check('') }.not_to raise_error
      end
    end
  end

  describe '#levenshtein_distance' do
    let(:detector) { described_class.new(make_settings) }

    it 'returns 0 for identical strings' do
      expect(detector.levenshtein_distance('hello', 'hello')).to eq(0)
    end

    it 'returns source length when compare is empty' do
      expect(detector.levenshtein_distance('hello', '')).to eq(5)
    end

    it 'returns compare length when source is empty' do
      expect(detector.levenshtein_distance('', 'hello')).to eq(5)
    end

    it 'returns 0 for two empty strings' do
      expect(detector.levenshtein_distance('', '')).to eq(0)
    end

    it 'returns 1 for single-char difference' do
      expect(detector.levenshtein_distance('cat', 'bat')).to eq(1)
    end

    it 'returns correct distance for insertion' do
      expect(detector.levenshtein_distance('abc', 'abcd')).to eq(1)
    end

    it 'returns correct distance for deletion' do
      expect(detector.levenshtein_distance('abcd', 'abc')).to eq(1)
    end

    it 'is symmetric' do
      d1 = detector.levenshtein_distance('kitten', 'sitting')
      d2 = detector.levenshtein_distance('sitting', 'kitten')
      expect(d1).to eq(d2)
    end

    it 'handles completely different strings' do
      expect(detector.levenshtein_distance('abc', 'xyz')).to eq(3)
    end
  end

  describe 'similarity percentage boundaries' do
    it 'with similarity 0%, detects all lines as similar but debounce blocks rapid fire' do
      detector = described_class.new(make_settings(unique: 100, frequency: 2, similarity: 0))
      detector.check('hello world')
      # Second unique line IS similar (dist < length * 1.0) but enters frequency buffer
      alert = detector.check('completely different line')
      expect(alert).to be_nil
      # Third line is blocked by the 0.5s debounce guard (test runs instantly)
      alert = detector.check('yet another line')
      expect(alert).to be_nil
    end

    it 'with similarity 100%, never triggers similarity path' do
      detector = described_class.new(make_settings(unique: 100, frequency: 2, similarity: 100))
      20.times { |i| detector.check("similar line #{i}") }
      expect($echo_messages.none? { |m| m.include?('freq_buffer') }).to be true
    end
  end

  describe '#reset_buffers' do
    it 'clears both recent_seen and frequency_buffer' do
      detector = described_class.new(make_settings(unique: 1))
      detector.check('a')
      detector.check('a')
      # After alert fires, buffers are reset internally
      # Verify by sending new lines that should not alert
      expect(detector.check('b')).to be_nil
    end
  end

  describe 'adversarial evasion' do
    it 'catches number-padded variants after similarity_scrub normalizes them' do
      # Attacker sends "suspicious content 1", "suspicious content 2", etc.
      # After scrub strips digits, all collapse to "suspicious content "
      detector = described_class.new(make_settings(unique: 2))
      scrubbed = 'suspicious content '
      detector.check(scrubbed)
      detector.check(scrubbed)
      alert = detector.check(scrubbed)
      expect(alert).not_to be_nil
    end

    it 'buffer flooding does not reset repeat detection (time-windowed)' do
      detector = described_class.new(make_settings(unique: 2))
      detector.check('probe message')
      detector.check('probe message')
      20.times { |i| detector.check("unique noise line #{i}") }
      alert = detector.check('probe message')
      expect(alert).not_to be_nil
    end

    it 'expires entries older than 90 seconds' do
      detector = described_class.new(make_settings(unique: 2))
      detector.check('old probe')
      detector.check('old probe')
      # Backdate timestamps to simulate 91 seconds ago
      timestamps = detector.instance_variable_get(:@seen_timestamps)
      timestamps.transform_values! { Time.now - 91 }
      # After expiry, the old probe count is gone
      expect(detector.check('old probe')).to be_nil
    end
  end
end

# ---------------------------------------------------------------------------
# MessageStore -- SQLite persistence, migration, lifecycle
# ---------------------------------------------------------------------------
RSpec.describe StatusMonitor::MessageStore do
  let(:tmpdir) { Dir.mktmpdir('status-monitor-test') }

  before do
    $echo_messages.clear
    @original_dir = Dir.pwd
    Dir.chdir(tmpdir)
  end

  after do
    Dir.chdir(@original_dir)
    FileUtils.rm_rf(tmpdir)
  end

  describe '#unseen?' do
    it 'returns true for a never-seen line' do
      store = described_class.new('Testchar')
      expect(store.unseen?('hello world')).to be true
    end

    it 'returns false for a line seen in the recent cache' do
      store = described_class.new('Testchar')
      store.unseen?('hello world')
      expect(store.unseen?('hello world')).to be false
    end

    it 'returns false for nil' do
      store = described_class.new('Testchar')
      expect(store.unseen?(nil)).to be false
    end

    it 'returns false for empty string' do
      store = described_class.new('Testchar')
      expect(store.unseen?('')).to be false
    end

    it 'returns false for a line that was saved to DB then flushed from cache' do
      store = described_class.new('Testchar')
      store.unseen?('persistent line')
      store.save
      # After save, recent cache is cleared but line is in DB
      expect(store.unseen?('persistent line')).to be false
    end

    it 'rejects whitespace-only lines' do
      store = described_class.new('Testchar')
      expect(store.unseen?('   ')).to be false
    end

    it 'rejects tabs and newlines' do
      store = described_class.new('Testchar')
      expect(store.unseen?("\t")).to be false
      expect(store.unseen?("\n")).to be false
      expect(store.unseen?(" \t \n ")).to be false
    end

    it 'is case-sensitive' do
      store = described_class.new('Testchar')
      expect(store.unseen?('Hello')).to be true
      expect(store.unseen?('hello')).to be true
    end
  end

  describe '#migrate_recent' do
    it 'moves lines older than 600 seconds to the database' do
      store = described_class.new('Testchar')
      store.unseen?('old line')
      # Backdate the timestamp in @recent_seen_lines
      store.instance_variable_get(:@recent_seen_lines)['old line'] = Time.now - 601
      store.migrate_recent
      # Line should now be in DB, not in recent cache
      recent = store.instance_variable_get(:@recent_seen_lines)
      expect(recent).not_to have_key('old line')
      # And unseen? should return false (found in DB)
      expect(store.unseen?('old line')).to be false
    end

    it 'does not migrate lines younger than 600 seconds' do
      store = described_class.new('Testchar')
      store.unseen?('new line')
      store.migrate_recent
      recent = store.instance_variable_get(:@recent_seen_lines)
      expect(recent).to have_key('new line')
    end

    it 'is a no-op when recent cache is empty' do
      store = described_class.new('Testchar')
      expect { store.migrate_recent }.not_to raise_error
    end
  end

  describe '#save' do
    it 'flushes recent lines to the database' do
      store = described_class.new('Testchar')
      store.unseen?('line1')
      store.unseen?('line2')
      store.save
      expect(store.count).to eq(2)
    end

    it 'clears the recent cache after save' do
      store = described_class.new('Testchar')
      store.unseen?('line1')
      store.save
      recent = store.instance_variable_get(:@recent_seen_lines)
      expect(recent).to be_empty
    end

    it 'applies filter patterns to reject matching lines' do
      store = described_class.new('Testchar')
      store.unseen?('gold coins')
      store.unseen?('important message')
      store.save([/gold/])
      expect(store.count).to eq(1)
    end

    it 'is a no-op when recent cache is empty' do
      store = described_class.new('Testchar')
      store.save
      expect(store.count).to eq(0)
    end
  end

  describe '#shutdown' do
    it 'flushes and closes the database' do
      store = described_class.new('Testchar')
      store.unseen?('persist me')
      store.shutdown
      # Verify the DB file exists and has the data
      db = SQLite3::Database.new("seen_messages_Testchar.db")
      count = db.get_first_value('SELECT COUNT(*) FROM seen_messages').to_i
      expect(count).to eq(1)
      db.close
    end

    it 'raises on subsequent operations after close' do
      store = described_class.new('Testchar')
      store.shutdown
      expect { store.count }.to raise_error(StandardError)
    end

    it 'survives double shutdown (before_dying can fire twice)' do
      store = described_class.new('Testchar')
      store.shutdown
      expect { store.shutdown }.not_to raise_error
    end
  end

  describe '#count' do
    it 'returns 0 for a fresh database' do
      store = described_class.new('Testchar')
      expect(store.count).to eq(0)
    end

    it 'reflects saved entries' do
      store = described_class.new('Testchar')
      5.times { |i| store.unseen?("line_#{i}") }
      store.save
      expect(store.count).to eq(5)
    end

    it 'does not count recent (unflushed) entries' do
      store = described_class.new('Testchar')
      store.unseen?('unflushed')
      expect(store.count).to eq(0)
    end
  end

  describe 'Marshal migration' do
    it 'migrates .dat file entries into SQLite' do
      dat_path = "seen_messages_Testchar.dat"
      data = { 'old line one' => true, 'old line two' => true }
      File.open(dat_path, 'wb') { |f| Marshal.dump(data, f) }
      store = described_class.new('Testchar')
      expect(store.count).to eq(2)
      expect(store.unseen?('old line one')).to be false
      expect(store.unseen?('old line two')).to be false
    end

    it 'renames .dat to .dat.migrated' do
      dat_path = "seen_messages_Testchar.dat"
      File.open(dat_path, 'wb') { |f| Marshal.dump({}, f) }
      described_class.new('Testchar')
      expect(File.exist?("#{dat_path}.migrated")).to be true
      expect(File.exist?(dat_path)).to be false
    end

    it 'renames backup file if present' do
      dat_path = "seen_messages_Testchar.dat"
      bak_path = "backup/#{File.basename(dat_path, '.dat')}.bak"
      FileUtils.mkdir_p('backup')
      File.open(dat_path, 'wb') { |f| Marshal.dump({}, f) }
      File.open(bak_path, 'wb') { |f| Marshal.dump({}, f) }
      described_class.new('Testchar')
      expect(File.exist?("#{bak_path}.migrated")).to be true
    end

    it 'survives .dat containing non-Hash data (Array)' do
      dat_path = "seen_messages_Testchar.dat"
      File.open(dat_path, 'wb') { |f| Marshal.dump(["not", "a", "hash"], f) }
      store = nil
      expect { store = described_class.new('Testchar') }.not_to raise_error
      expect(store.count).to eq(0)
      expect($echo_messages.any? { |m| m.include?('Warning') }).to be true
    end

    it 'constructs the correct backup path (no doubled prefix)' do
      dat_path = "seen_messages_Testchar.dat"
      correct_bak = "backup/seen_messages_Testchar.bak"
      wrong_bak = "backup/seen_messages_seen_messages_Testchar.bak"
      FileUtils.mkdir_p('backup')
      File.open(dat_path, 'wb') { |f| Marshal.dump({}, f) }
      File.open(correct_bak, 'wb') { |f| Marshal.dump({}, f) }
      described_class.new('Testchar')
      expect(File.exist?("#{correct_bak}.migrated")).to be true
      expect(File.exist?(wrong_bak)).to be false
    end

    it 'survives corrupted .dat without crashing' do
      File.write("seen_messages_Testchar.dat", "corrupted garbage data")
      store = nil
      expect { store = described_class.new('Testchar') }.not_to raise_error
      expect(store.count).to eq(0)
      expect($echo_messages.any? { |m| m.include?('Warning') }).to be true
    end

    it 'does not re-migrate if .dat is absent' do
      store = described_class.new('Testchar')
      expect($echo_messages.none? { |m| m.include?('Migrating') }).to be true
      expect(store.count).to eq(0)
    end
  end

  describe 'schema creation' do
    it 'creates seen_messages table with correct columns' do
      described_class.new('Testchar')
      db = SQLite3::Database.new("seen_messages_Testchar.db")
      columns = db.table_info('seen_messages').map { |c| c['name'] }
      expect(columns).to contain_exactly('line_text', 'first_seen_at', 'source')
      db.close
    end

    it 'uses WAL journal mode' do
      described_class.new('Testchar')
      db = SQLite3::Database.new("seen_messages_Testchar.db")
      mode = db.get_first_value('PRAGMA journal_mode')
      expect(mode).to eq('wal')
      db.close
    end

    it 'sets a busy_timeout so a concurrent writer waits instead of erroring' do
      store = described_class.new('Testchar')
      db = store.instance_variable_get(:@db)
      expect(db.get_first_value('PRAGMA busy_timeout')).to eq(5000)
    end
  end
end

# ---------------------------------------------------------------------------
# CommandDetector -- deduplication and command extraction
# ---------------------------------------------------------------------------
RSpec.describe StatusMonitor::CommandDetector do
  before { $fput_commands.clear }

  describe '.check' do
    it 'detects uppercase commands in a line' do
      described_class.check('you see JUMP here')
      expect($fput_commands).to include('jump')
    end

    it 'does not auto-execute denylisted destructive commands' do
      described_class.check('you must QUIT and SELL and DROP now')
      expect($fput_commands).to be_empty
    end

    it 'does not execute a denylisted command even when obfuscated' do
      described_class.check('try Q_U_I_T now')
      expect($fput_commands).not_to include('quit')
    end

    it 'still executes safe commands in a line that also contains a denylisted one' do
      described_class.check('you should JUMP but do not QUIT')
      expect($fput_commands).to include('jump')
      expect($fput_commands).not_to include('quit')
    end

    it 'detects obfuscated commands with separators' do
      described_class.check('try J_U_M_P now')
      expect($fput_commands).to include('jump')
    end

    it 'deduplicates commands that match both scanners' do
      described_class.check('do J_U_M_P or JUMP')
      jump_count = $fput_commands.count('jump')
      expect(jump_count).to eq(1)
    end

    it 'detects multiple different commands' do
      described_class.check('JUMP and LOOK around')
      expect($fput_commands).to include('jump', 'look')
    end

    it 'ignores commands not in VALID_COMMANDS' do
      described_class.check('XYZZY is not a command')
      expect($fput_commands).to be_empty
    end

    it 'ignores short uppercase sequences (< 3 chars)' do
      described_class.check('I AM here')
      expect($fput_commands).not_to include('am')
    end

    it 'handles a line with no commands' do
      described_class.check('just a normal line of text')
      expect($fput_commands).to be_empty
    end

    it 'handles empty string' do
      expect { described_class.check('') }.not_to raise_error
      expect($fput_commands).to be_empty
    end

    it 'detects tilde-separated obfuscation' do
      described_class.check('try L~O~O~K now')
      expect($fput_commands).to include('look')
    end

    it 'detects equals-separated obfuscation' do
      described_class.check('try L=O=O=K now')
      expect($fput_commands).to include('look')
    end

    it 'handles mixed separators in one token' do
      described_class.check('try J_U~M=P now')
      expect($fput_commands).to include('jump')
    end

    it 'detects dot-separated obfuscation via first scanner' do
      described_class.check('try J.U.M.P now')
      expect($fput_commands).to include('jump')
    end

    it 'detects hyphen-separated obfuscation' do
      described_class.check('try J-U-M-P now')
      expect($fput_commands).to include('jump')
    end

    it 'detects a bare command with no surrounding text' do
      described_class.check('JUMP')
      expect($fput_commands).to include('jump')
    end

    it 'detects uppercase runs embedded in lowercase words (character class scan)' do
      described_class.check('theJUMPwasfast')
      expect($fput_commands).to include('jump')
    end

    it 'detects commands with multiple consecutive separators' do
      described_class.check('try J__U__M__P now')
      expect($fput_commands).to include('jump')
    end
  end

  describe 'adversarial evasion' do
    it 'misses commands with Cyrillic lookalike letters (known gap, needs transliteration)' do
      cyrillic_em = 0x041C.chr(Encoding::UTF_8) # lookalike for Latin capital M
      line = "JU#{cyrillic_em}P here"
      described_class.check(line)
      expect($fput_commands).not_to include('jump')
    end

    it 'detects commands despite zero-width characters inserted' do
      zero_width_space = 0x200B.chr(Encoding::UTF_8)
      line = "JU#{zero_width_space}MP here"
      described_class.check(line)
      expect($fput_commands).to include('jump')
    end

    it 'detects mixed-case commands via second scanner upcase' do
      described_class.check('try j_U_m_P now')
      expect($fput_commands).to include('jump')
    end

    it 'finds commands in very long lines' do
      padding = 'a' * 5000
      described_class.check("#{padding} JUMP #{padding}")
      expect($fput_commands).to include('jump')
    end
  end
end

# ---------------------------------------------------------------------------
# AlertHandler -- alert responses
# ---------------------------------------------------------------------------
RSpec.describe StatusMonitor::AlertHandler do
  before do
    $echo_messages.clear
    $fput_commands.clear
  end

  def make_alert_settings(respond: false, quit: false, slack: nil)
    OpenStruct.new(
      status_monitor_respond: respond,
      quit_on_status_warning: quit,
      slack_username: slack
    )
  end

  it 'calls echo three times for beeps' do
    handler = described_class.new(make_alert_settings)
    handler.fire('suspicious line', 'counts')
    beeps = $echo_messages.count { |m| m == "\a" }
    expect(beeps).to eq(3)
  end

  it 'executes detected commands via CommandDetector' do
    handler = described_class.new(make_alert_settings)
    handler.fire('you see JUMP here', 'counts')
    expect($fput_commands).to include('jump')
  end

  it 'sends a response when status_monitor_respond is true' do
    handler = described_class.new(make_alert_settings(respond: true))
    handler.fire('suspicious line', 'counts')
    responses = ["'Hmmm?", "'Yes", "'Ok?"]
    expect($fput_commands.any? { |cmd| responses.include?(cmd) }).to be true
  end

  it 'does not send a response when status_monitor_respond is false' do
    handler = described_class.new(make_alert_settings(respond: false))
    handler.fire('a plain line with no commands', 'counts')
    responses = ["'Hmmm?", "'Yes", "'Ok?"]
    expect($fput_commands.none? { |cmd| responses.include?(cmd) }).to be true
  end

  it 'sends exit when quit_on_status_warning is true' do
    handler = described_class.new(make_alert_settings(quit: true))
    handler.fire('suspicious line', 'counts')
    expect($fput_commands).to include('exit')
  end

  it 'does not send exit when quit_on_status_warning is false' do
    handler = described_class.new(make_alert_settings(quit: false))
    handler.fire('a plain line', 'counts')
    expect($fput_commands).not_to include('exit')
  end

  describe 'Slack delivery' do
    before do
      Lich::DragonRealms::SlackBot.instances.clear
      $event_log.clear
    end

    it 'queues the auto-quit before the (possibly blocking) Slack send' do
      handler = described_class.new(make_alert_settings(quit: true, slack: 'someuser'))
      handler.fire('a plain line', 'counts')
      exit_at = $event_log.index([:fput, 'exit'])
      slack_at = $event_log.index { |kind, _| kind == :slack }
      expect(exit_at).not_to be_nil
      expect(slack_at).not_to be_nil
      expect(exit_at).to be < slack_at
    end

    it 'delivers the alert even when the bot reports it is not initialized' do
      # Regression: gating on initialized? here would suppress delivery forever
      # after a failed first connect. direct_message reconnects on its own.
      Lich::DragonRealms::SlackBot.next_initialized = false
      handler = described_class.new(make_alert_settings(slack: 'someuser'))
      handler.fire('a plain line', 'counts info')
      bot = Lich::DragonRealms::SlackBot.instances.last
      expect(bot).not_to be_nil
      expect(bot.dm_calls.last).to eq(['someuser', 'counts info'])
    end

    it 'does not construct a SlackBot when no username is configured' do
      handler = described_class.new(make_alert_settings(slack: nil))
      handler.fire('a plain line', 'counts')
      expect(Lich::DragonRealms::SlackBot.instances).to be_empty
    end

    it 'does not construct a SlackBot at initialize time (lazy, avoids blocking startup)' do
      described_class.new(make_alert_settings(slack: 'someuser'))
      expect(Lich::DragonRealms::SlackBot.instances).to be_empty
    end

    it 'constructs the SlackBot only once across multiple alerts' do
      handler = described_class.new(make_alert_settings(slack: 'someuser'))
      handler.fire('first', 'counts1')
      handler.fire('second', 'counts2')
      expect(Lich::DragonRealms::SlackBot.instances.size).to eq(1)
      expect(Lich::DragonRealms::SlackBot.instances.first.dm_calls.size).to eq(2)
    end
  end
end

# ---------------------------------------------------------------------------
# MessageFilter -- line cleaning and similarity scrub
# ---------------------------------------------------------------------------
RSpec.describe StatusMonitor::MessageFilter do
  let(:filter) { described_class.new([]) }

  describe '#similarity_scrub' do
    it 'removes numbers from the line' do
      expect(filter.similarity_scrub('you have 42 gold')).to eq('you have  gold')
    end

    it 'removes currency words (case-insensitive)' do
      expect(filter.similarity_scrub('you paid 10 Kronars')).to eq('you paid  ')
    end

    it 'removes all three currency types' do
      %w[kronars lirums dokoras].each do |currency|
        result = filter.similarity_scrub("5 #{currency}")
        expect(result.strip).to be_empty
      end
    end

    it 'does not mutate the original string' do
      original = 'you have 42 gold'
      original_copy = original.dup
      filter.similarity_scrub(original)
      expect(original).to eq(original_copy)
    end

    it 'handles string with no scrub targets' do
      expect(filter.similarity_scrub('hello world')).to eq('hello world')
    end

    it 'handles empty string' do
      expect(filter.similarity_scrub('')).to eq('')
    end
  end

  describe '#filtered?' do
    it 'returns true for nil' do
      expect(filter.filtered?(nil)).to be true
    end

    it 'returns true for empty string' do
      expect(filter.filtered?('')).to be true
    end

    it 'returns false when no patterns match' do
      expect(filter.filtered?('hello world')).to be false
    end

    it 'returns true when a pattern matches' do
      f = described_class.new([/secret/])
      expect(f.filtered?('this is secret')).to be true
    end

    it 'handles multiple patterns' do
      f = described_class.new([/alpha/, /beta/])
      expect(f.filtered?('the beta test')).to be true
      expect(f.filtered?('the gamma test')).to be false
    end
  end

  describe '#clean' do
    it 'strips XML tags from lines' do
      result = filter.clean(+"<b>bold text</b> and more")
      expect(result).to eq('bold text and more')
    end

    it 'does not mutate its argument' do
      original = +"<b>bold text</b> and more"
      before = original.dup
      filter.clean(original)
      expect(original).to eq(before)
    end

    it 'does not raise on a frozen input line' do
      expect { filter.clean("<b>frozen</b> line".freeze) }.not_to raise_error
    end

    it 'returns nil for empty lines' do
      expect(filter.clean(+'')).to be_nil
    end

    it 'returns nil for nil lines' do
      expect(filter.clean(nil)).to be_nil
    end

    it 'returns nil for lines matching non_useful_tags' do
      expect(filter.clean(+"<preset id='roomDesc'>A room</preset>")).to be_nil
    end

    it 'filters content within a filtered stream (percWindow)' do
      filter.clean(+'<pushStream id="percWindow"/>')
      expect(filter.clean(+'spell data here')).to be_nil
      expect(filter.clean(+'more spell data')).to be_nil
    end

    it 'unblocks after popStream' do
      filter.clean(+'<pushStream id="percWindow"/>')
      filter.clean(+'<popStream/>')
      result = filter.clean(+'normal line after perc')
      expect(result).not_to be_nil
    end

    it 'filters content within all filtered streams' do
      %w[assess ooc atmospherics thoughts talk death group logons shopWindow].each do |stream|
        f = described_class.new([])
        f.clean(+"<pushStream id=\"#{stream}\"/>")
        expect(f.clean(+'content inside stream')).to be_nil, "Expected #{stream} stream content to be filtered"
        f.clean(+'<popStream/>')
        expect(f.clean(+'content after stream')).not_to be_nil, "Expected content after #{stream} popStream to pass"
      end
    end

    it 'passes content within non-filtered streams (e.g., room)' do
      filter.clean(+'<pushStream id="room"/>')
      result = filter.clean(+'room content should pass')
      expect(result).not_to be_nil
      filter.clean(+'<popStream/>')
    end

    it 'filters lines containing room player names' do
      filter.clean(+"'room players'>Also here: Warrior Bob.</component>")
      result = filter.clean(+'Bob waves at you')
      expect(result).to be_nil
    end

    it 'resets room players on new room entry' do
      filter.clean(+"'room players'>Also here: Warrior Alice.</component>")
      filter.clean(+"'room players'>Also here: Warrior Charlie.</component>")
      result = filter.clean(+'Alice walks in')
      expect(result).not_to be_nil
    end
  end

  describe 'adversarial scenarios' do
    it 'does not trigger stream state from pushStream substring in normal text' do
      filter.clean(+'Someone says, "check pushStream id="percWindow" this out"')
      result = filter.clean(+'This important line should be visible')
      expect(result).not_to be_nil
    end
  end
end

# ---------------------------------------------------------------------------
# Monitor -- orchestration and process ordering
# ---------------------------------------------------------------------------
RSpec.describe StatusMonitor::Monitor do
  let(:tmpdir) { Dir.mktmpdir('status-monitor-test') }
  let(:settings) do
    OpenStruct.new(
      unique_line_threshold: 3,
      line_frequency_threshold: 5,
      line_similarity_percentage: 80,
      status_monitor_respond: false,
      quit_on_status_warning: false,
      slack_username: nil
    )
  end

  # Stub get_data for filter loading
  before do
    $echo_messages.clear
    @original_dir = Dir.pwd
    Dir.chdir(tmpdir)
  end

  after do
    Dir.chdir(@original_dir)
    FileUtils.rm_rf(tmpdir)
  end

  # Monitor#load_filter_strings calls the top-level get_data. Define a default
  # (empty filter_strings) around every example and always remove it afterward.
  # An example that needs specific filters redefines get_data before it
  # constructs the Monitor; the hook still removes it in the ensure.
  around do |example|
    Object.send(:define_method, :get_data) do |_type|
      OpenStruct.new('filter_strings' => [])
    end
    example.run
  ensure
    Object.send(:remove_method, :get_data) if Object.method_defined?(:get_data)
  end

  it 'detector runs before unseen? gate (spam detection regression test)' do
    monitor = described_class.new(settings)
    # Send the same clean line repeatedly -- detector must see all of them
    4.times { monitor.process(+'A mysterious voice whispers to you') }
    # The detector should have seen 4 occurrences in its buffer
    # With threshold 3, the 4th should trigger (first is unseen, 2-4 are repeats
    # but detector still gets them)
    expect(monitor.spam_line).not_to be_nil, "SpamDetector should have fired after 4 repeats with threshold 3"
  end

  it 'process returns false for nil lines' do
    monitor = described_class.new(settings)
    expect(monitor.process(nil)).to be false
  end

  it 'process returns false for empty lines' do
    monitor = described_class.new(settings)
    expect(monitor.process('')).to be false
  end

  it 'returns false for lines that scrub to whitespace' do
    monitor = described_class.new(settings)
    result = monitor.process(+'42 kronars')
    expect(result).to be false
  end

  it 'returns false for lines matching a filter pattern' do
    # Override the shared default with a non-empty filter for this example only.
    Object.send(:define_method, :get_data) do |_type|
      OpenStruct.new('filter_strings' => ['gold coins'])
    end

    monitor = described_class.new(settings)
    result = monitor.process(+'you see gold coins on the ground')
    expect(result).to be false
  end

  it 'consume_spam_line clears the spam line' do
    monitor = described_class.new(settings)
    monitor.instance_variable_set(:@spam_line, 'test spam')
    consumed = monitor.consume_spam_line
    expect(consumed).to eq('test spam')
    expect(monitor.spam_line).to be_nil
  end
end
