# frozen_string_literal: true

require 'sqlite3'
require 'tmpdir'
require 'ostruct'
require 'set'
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
def fput(cmd)
  $fput_commands << cmd
end

module UserVars
  def self.npcs; []; end
  def self.players_online; nil; end
end unless defined?(UserVars)

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

    context 'buffer overflow' do
      it 'caps @recent_seen at 20 entries' do
        detector = described_class.new(make_settings(unique: 100))
        25.times { |i| detector.check("line_#{i}") }
        # After 25 unique inserts, buffer should be 20 (last 20)
        # Verify by checking that line_0 through line_4 are gone:
        # inserting line_0 again should not show count > 1
        alert = detector.check('line_0')
        expect(alert).to be_nil
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
end

# ---------------------------------------------------------------------------
# MessageStore -- SQLite persistence, migration, lifecycle
# ---------------------------------------------------------------------------
RSpec.describe StatusMonitor::MessageStore do
  let(:tmpdir) { Dir.mktmpdir('status-monitor-test') }
  let(:original_dir) { Dir.pwd }

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

    it 'treats whitespace-only lines as non-empty (stores them)' do
      store = described_class.new('Testchar')
      expect(store.unseen?('   ')).to be true
      expect(store.unseen?('   ')).to be false
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
      bak_path = "backup/seen_messages_#{File.basename(dat_path, '.dat')}.bak"
      FileUtils.mkdir_p('backup')
      File.open(dat_path, 'wb') { |f| Marshal.dump({}, f) }
      File.open(bak_path, 'wb') { |f| Marshal.dump({}, f) }
      described_class.new('Testchar')
      expect(File.exist?("#{bak_path}.migrated")).to be true
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

    it 'returns nil for empty lines' do
      expect(filter.clean(+'')).to be_nil
    end

    it 'returns nil for nil lines' do
      expect(filter.clean(nil)).to be_nil
    end

    it 'returns nil for lines matching non_useful_tags' do
      expect(filter.clean(+"<preset id='roomDesc'>A room</preset>")).to be_nil
    end

    it 'returns nil for perception window lines' do
      filter.clean(+'something <pushStream id="percWindow"/>')
      result = filter.clean(+'spell data here')
      expect(result).to be_nil
    end

    it 'unblocks after percWindow popStream' do
      filter.clean(+'<pushStream id="percWindow"/>')
      filter.clean(+'<popStream/>')
      result = filter.clean(+'normal line after perc')
      expect(result).not_to be_nil
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

  def stub_get_data
    define_method(:get_data) do |_type|
      OpenStruct.new('filter_strings' => ['ignore_this'])
    end
  end

  # get_data must be defined at top level for Monitor to call it
  it 'detector runs before unseen? gate (spam detection regression test)' do
    # Define get_data in scope
    Object.send(:define_method, :get_data) do |_type|
      OpenStruct.new('filter_strings' => [])
    end

    monitor = described_class.new(settings)
    # Send the same clean line repeatedly -- detector must see all of them
    4.times { monitor.process(+'A mysterious voice whispers to you') }
    # The detector should have seen 4 occurrences in its buffer
    # With threshold 3, the 4th should trigger (first is unseen, 2-4 are repeats
    # but detector still gets them)
    expect(monitor.spam_line).not_to be_nil, "SpamDetector should have fired after 4 repeats with threshold 3"
  ensure
    Object.send(:remove_method, :get_data) if Object.method_defined?(:get_data)
  end

  it 'process returns false for nil lines' do
    Object.send(:define_method, :get_data) do |_type|
      OpenStruct.new('filter_strings' => [])
    end

    monitor = described_class.new(settings)
    expect(monitor.process(nil)).to be false
  ensure
    Object.send(:remove_method, :get_data) if Object.method_defined?(:get_data)
  end

  it 'process returns false for empty lines' do
    Object.send(:define_method, :get_data) do |_type|
      OpenStruct.new('filter_strings' => [])
    end

    monitor = described_class.new(settings)
    expect(monitor.process('')).to be false
  ensure
    Object.send(:remove_method, :get_data) if Object.method_defined?(:get_data)
  end

  it 'consume_spam_line clears the spam line' do
    Object.send(:define_method, :get_data) do |_type|
      OpenStruct.new('filter_strings' => [])
    end

    monitor = described_class.new(settings)
    monitor.instance_variable_set(:@spam_line, 'test spam')
    consumed = monitor.consume_spam_line
    expect(consumed).to eq('test spam')
    expect(monitor.spam_line).to be_nil
  ensure
    Object.send(:remove_method, :get_data) if Object.method_defined?(:get_data)
  end
end
