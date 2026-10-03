# frozen_string_literal: true

require 'sqlite3'
require 'tmpdir'
require 'ostruct'
require 'fileutils'

# Test suite for status-monitor.lic
#
# Covers MessageStore, MessageFilter, CommandDetector, AlertHandler,
# and Monitor orchestration. Aggressively tests edge cases, boundary
# conditions, and error paths.

# echo, fput, checkname and pause all come from the shared harness
# (test/test_harness.rb, mixed in at the top level by spec_helper's
# `include Harness`). Do NOT redefine them here -- a top-level def wins for the
# whole process and clobbers every other spec's harness seams. checkname already
# returns 'Testchar' and pause is already a no-op. echo output is captured in the
# harness's displayed_messages; fput is asserted via per-example spies.

# The generic UserVars store lives in the harness (Harness::UserVars); reopen it
# to add status-monitor's one domain default: npcs reads back an empty list when
# unset so MessageFilter#clean can safely call UserVars.npcs.any?. Everything
# else (players_online, ...) is handled by the shared store (unset -> nil).
# Do NOT define a fresh top-level `UserVars` -- it would shadow the harness store
# for the whole process. (See spec_helper's "Shared game doubles" notes.)
class Harness::UserVars
  class << self
    def npcs
      _store[:npcs] || []
    end
  end
end

# Minimal fake SlackBot so AlertHandler's delivery path can be exercised without
# any network or lnet dependency. SlackBot is a genuinely new class the harness
# does not provide, so it is added under the harness's Lich::DragonRealms
# namespace (resolved as Lich::DragonRealms::SlackBot via `include Harness`).
# Defining a fresh top-level `module Lich` instead would create a real ::Lich
# constant that shadows the harness Lich and wipes out Lich::Messaging/Util for
# every spec that runs after this file loads.
module Harness
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
          { 'ok' => true }
        end
      end
    end
  end
end

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
# MessageStore -- SQLite persistence, migration, lifecycle
# ---------------------------------------------------------------------------
RSpec.describe StatusMonitor::MessageStore do
  let(:tmpdir) { Dir.mktmpdir('status-monitor-test') }
  let(:db_path) { File.join(tmpdir, 'seen_messages.db') }
  let(:store) { described_class.new(db_path) }

  before do
    @original_dir = Dir.pwd
    Dir.chdir(tmpdir)
  end

  after do
    Dir.chdir(@original_dir)
    FileUtils.rm_rf(tmpdir)
  end

  describe '#in_corpus? and #record' do
    it 'is false for a never-seen line' do
      expect(store.in_corpus?('hello world')).to be false
    end

    it 'becomes true after record, written through immediately (visible to a fresh handle)' do
      store.record('shared line')
      expect(store.in_corpus?('shared line')).to be true
      # A separate connection (another character's process) sees it at once.
      other = described_class.new(db_path)
      expect(other.in_corpus?('shared line')).to be true
    end

    it 'treats nil/empty/whitespace as known (never novel) and never records them' do
      expect(store.in_corpus?(nil)).to be true
      expect(store.in_corpus?('')).to be true
      expect(store.in_corpus?('   ')).to be true
      store.record('')
      store.record('   ')
      expect(store.count).to eq(0)
    end

    it 'is case-sensitive' do
      store.record('Hello')
      expect(store.in_corpus?('Hello')).to be true
      expect(store.in_corpus?('hello')).to be false
    end
  end

  describe '#shutdown' do
    it 'persists records and closes the database' do
      store.record('persist me')
      store.shutdown
      db = SQLite3::Database.new(db_path)
      expect(db.get_first_value('SELECT COUNT(*) FROM seen_messages').to_i).to eq(1)
      db.close
    end

    it 'raises on subsequent operations after close' do
      store.shutdown
      expect { store.count }.to raise_error(StandardError)
    end

    it 'survives double shutdown (before_dying can fire twice)' do
      store.shutdown
      expect { store.shutdown }.not_to raise_error
    end
  end

  describe '#count' do
    it 'returns 0 for a fresh database' do
      expect(store.count).to eq(0)
    end

    it 'reflects recorded entries immediately (no flush step)' do
      5.times { |i| store.record("line_#{i}") }
      expect(store.count).to eq(5)
    end
  end

  describe 'legacy migration (installation-wide merge)' do
    it 'merges legacy per-character .dat entries into the shared corpus' do
      File.open('seen_messages_Alice.dat', 'wb') { |f| Marshal.dump({ 'alice line' => true }, f) }
      File.open('seen_messages_Bob.dat', 'wb') { |f| Marshal.dump({ 'bob line' => true }, f) }
      expect(store.count).to eq(2)
      expect(store.in_corpus?('alice line')).to be true
      expect(store.in_corpus?('bob line')).to be true
    end

    it 'merges legacy per-character .db entries into the shared corpus' do
      legacy = SQLite3::Database.new('seen_messages_Alice.db')
      legacy.execute('CREATE TABLE seen_messages (line_text TEXT PRIMARY KEY, first_seen_at DATETIME, source TEXT)')
      legacy.execute("INSERT INTO seen_messages (line_text, source) VALUES ('legacy db line', 'live')")
      legacy.close
      expect(store.count).to eq(1)
      expect(store.in_corpus?('legacy db line')).to be true
    end

    it 'renames migrated legacy files to .migrated and does not re-migrate' do
      File.open('seen_messages_Alice.dat', 'wb') { |f| Marshal.dump({ 'x' => true }, f) }
      described_class.new(db_path)
      expect(File.exist?('seen_messages_Alice.dat.migrated')).to be true
      expect(File.exist?('seen_messages_Alice.dat')).to be false
    end

    it 'renames a legacy .dat backup if present' do
      File.open('seen_messages_Alice.dat', 'wb') { |f| Marshal.dump({}, f) }
      FileUtils.mkdir_p('backup')
      File.open('backup/seen_messages_Alice.bak', 'wb') { |f| Marshal.dump({}, f) }
      described_class.new(db_path)
      expect(File.exist?('backup/seen_messages_Alice.bak.migrated')).to be true
    end

    it 'does not treat the shared db itself as a legacy per-character db' do
      # db_path basename is seen_messages.db; the *_ glob must not match it.
      store.record('keep me')
      expect { described_class.new(db_path) }.not_to raise_error
      expect(File.exist?("#{db_path}.migrated")).to be false
    end

    it 'survives a corrupt legacy .dat without crashing, and still migrates the rest' do
      File.write('seen_messages_Bad.dat', 'corrupted garbage')
      File.open('seen_messages_Good.dat', 'wb') { |f| Marshal.dump({ 'good' => true }, f) }
      s = nil
      expect { s = described_class.new(db_path) }.not_to raise_error
      expect(s.in_corpus?('good')).to be true
    end

    it 'does nothing when no legacy files are present' do
      expect(store.count).to eq(0)
      expect(displayed_messages.none? { |m| m.include?('merged') }).to be true
    end
  end

  describe 'schema creation' do
    it 'creates seen_messages table with correct columns' do
      store
      db = SQLite3::Database.new(db_path)
      columns = db.table_info('seen_messages').map { |c| c['name'] }
      expect(columns).to contain_exactly('line_text', 'first_seen_at', 'source')
      db.close
    end

    it 'uses WAL journal mode' do
      store
      db = SQLite3::Database.new(db_path)
      expect(db.get_first_value('PRAGMA journal_mode')).to eq('wal')
      db.close
    end

    it 'sets a busy_timeout so a concurrent writer waits instead of erroring' do
      expect(store.instance_variable_get(:@db).get_first_value('PRAGMA busy_timeout')).to eq(5000)
    end

    it 'creates the parent directory for the db path if missing' do
      nested = File.join(tmpdir, 'status-monitor', 'seen_messages.db')
      expect { described_class.new(nested) }.not_to raise_error
      expect(File.exist?(nested)).to be true
    end
  end
end

# ---------------------------------------------------------------------------
# CommandDetector -- deduplication and command extraction
# ---------------------------------------------------------------------------
RSpec.describe StatusMonitor::CommandDetector do
  # CommandDetector.check calls the harness fput on the module itself; capture
  # those calls per-example instead of redefining the shared fput seam.
  let(:fput_commands) { [] }
  before { allow(described_class).to receive(:fput) { |cmd| fput_commands << cmd } }

  describe '.check' do
    it 'detects uppercase commands in a line' do
      described_class.execute('you see JUMP here')
      expect(fput_commands).to include('jump')
    end

    it 'does not auto-execute denylisted destructive commands' do
      described_class.execute('you must QUIT and SELL and DROP now')
      expect(fput_commands).to be_empty
    end

    it 'does not execute a denylisted command even when obfuscated' do
      described_class.execute('try Q_U_I_T now')
      expect(fput_commands).not_to include('quit')
    end

    it 'still executes safe commands in a line that also contains a denylisted one' do
      described_class.execute('you should JUMP but do not QUIT')
      expect(fput_commands).to include('jump')
      expect(fput_commands).not_to include('quit')
    end

    it 'detects obfuscated commands with separators' do
      described_class.execute('try J_U_M_P now')
      expect(fput_commands).to include('jump')
    end

    it 'deduplicates commands that match both scanners' do
      described_class.execute('do J_U_M_P or JUMP')
      jump_count = fput_commands.count('jump')
      expect(jump_count).to eq(1)
    end

    it 'detects multiple different commands' do
      described_class.execute('JUMP and LOOK around')
      expect(fput_commands).to include('jump', 'look')
    end

    it 'ignores commands not in VALID_COMMANDS' do
      described_class.execute('XYZZY is not a command')
      expect(fput_commands).to be_empty
    end

    it 'ignores short uppercase sequences (< 3 chars)' do
      described_class.execute('I AM here')
      expect(fput_commands).not_to include('am')
    end

    it 'handles a line with no commands' do
      described_class.execute('just a normal line of text')
      expect(fput_commands).to be_empty
    end

    it 'handles empty string' do
      expect { described_class.execute('') }.not_to raise_error
      expect(fput_commands).to be_empty
    end

    it 'detects tilde-separated obfuscation' do
      described_class.execute('try L~O~O~K now')
      expect(fput_commands).to include('look')
    end

    it 'detects equals-separated obfuscation' do
      described_class.execute('try L=O=O=K now')
      expect(fput_commands).to include('look')
    end

    it 'handles mixed separators in one token' do
      described_class.execute('try J_U~M=P now')
      expect(fput_commands).to include('jump')
    end

    it 'detects dot-separated obfuscation via first scanner' do
      described_class.execute('try J.U.M.P now')
      expect(fput_commands).to include('jump')
    end

    it 'detects hyphen-separated obfuscation' do
      described_class.execute('try J-U-M-P now')
      expect(fput_commands).to include('jump')
    end

    it 'detects a bare command with no surrounding text' do
      described_class.execute('JUMP')
      expect(fput_commands).to include('jump')
    end

    it 'detects uppercase runs embedded in lowercase words (character class scan)' do
      described_class.execute('theJUMPwasfast')
      expect(fput_commands).to include('jump')
    end

    it 'detects commands with multiple consecutive separators' do
      described_class.execute('try J__U__M__P now')
      expect(fput_commands).to include('jump')
    end
  end

  describe 'adversarial evasion' do
    it 'misses commands with Cyrillic lookalike letters (known gap, needs transliteration)' do
      cyrillic_em = 0x041C.chr(Encoding::UTF_8) # lookalike for Latin capital M
      line = "JU#{cyrillic_em}P here"
      described_class.execute(line)
      expect(fput_commands).not_to include('jump')
    end

    it 'detects commands despite zero-width characters inserted' do
      zero_width_space = 0x200B.chr(Encoding::UTF_8)
      line = "JU#{zero_width_space}MP here"
      described_class.execute(line)
      expect(fput_commands).to include('jump')
    end

    it 'detects mixed-case commands via second scanner upcase' do
      described_class.execute('try j_U_m_P now')
      expect(fput_commands).to include('jump')
    end

    it 'finds commands in very long lines' do
      padding = 'a' * 5000
      described_class.execute("#{padding} JUMP #{padding}")
      expect(fput_commands).to include('jump')
    end
  end

  describe '.commands_in (detect only, no side effects)' do
    it 'returns detected valid commands without typing anything' do
      expect(described_class.commands_in('you should JUMP and LOOK')).to contain_exactly('JUMP', 'LOOK')
      expect(fput_commands).to be_empty
    end

    it 'includes denylisted commands (they are still a check signal)' do
      expect(described_class.commands_in('you must QUIT now')).to include('QUIT')
    end

    it 'returns [] for a line with no commands' do
      expect(described_class.commands_in('just some ordinary prose')).to eq([])
    end

    it 'detects obfuscated commands' do
      expect(described_class.commands_in('try J_U_M_P')).to include('JUMP')
    end
  end
end

# ---------------------------------------------------------------------------
# AlertHandler -- alert responses
# ---------------------------------------------------------------------------
RSpec.describe StatusMonitor::AlertHandler do
  # handle sends via the harness fput on the handler instance, and delegates
  # command execution to CommandDetector (which sends on the module). Capture
  # both per-example rather than redefining the shared fput seam. echo output
  # (beeps, the alert line) lands in the harness displayed_messages.
  let(:fput_commands) { [] }
  before do
    allow_any_instance_of(described_class).to receive(:fput) { |_receiver, cmd| fput_commands << cmd }
    allow(StatusMonitor::CommandDetector).to receive(:fput) { |cmd| fput_commands << cmd }
  end

  def make_alert_settings(respond: false, quit: false, slack: nil)
    OpenStruct.new(
      status_monitor_respond: respond,
      quit_on_status_warning: quit,
      slack_username: slack
    )
  end

  it 'beeps three times on any handled line (notify)' do
    described_class.new(make_alert_settings).handle('suspicious line', strong: false)
    expect(displayed_messages.count { |m| m == "\a" }).to eq(3)
  end

  context 'notify-only (novelty, not a strong signal)' do
    it 'does not type commands, canned responses, or exit' do
      handler = described_class.new(make_alert_settings(respond: true, quit: true))
      handler.handle('you see JUMP here', strong: false)
      expect(fput_commands).to be_empty
    end
  end

  context 'strong signal (repeat or embedded command)' do
    it 'executes detected commands via CommandDetector' do
      described_class.new(make_alert_settings).handle('you see JUMP here', strong: true)
      expect(fput_commands).to include('jump')
    end

    it 'sends a canned response when status_monitor_respond is true' do
      described_class.new(make_alert_settings(respond: true)).handle('suspicious line', strong: true)
      expect(fput_commands.any? { |cmd| ["'Hmmm?", "'Yes", "'Ok?"].include?(cmd) }).to be true
    end

    it 'does not respond when status_monitor_respond is false' do
      described_class.new(make_alert_settings(respond: false)).handle('a plain line', strong: true)
      expect(fput_commands.none? { |cmd| ["'Hmmm?", "'Yes", "'Ok?"].include?(cmd) }).to be true
    end

    it 'sends exit when quit_on_status_warning is true' do
      described_class.new(make_alert_settings(quit: true)).handle('suspicious line', strong: true)
      expect(fput_commands).to include('exit')
    end

    it 'does not send exit when quit_on_status_warning is false' do
      described_class.new(make_alert_settings(quit: false)).handle('a plain line', strong: true)
      expect(fput_commands).not_to include('exit')
    end
  end

  describe 'Slack delivery' do
    before do
      Lich::DragonRealms::SlackBot.instances.clear
      Lich::DragonRealms::SlackBot.next_initialized = nil
    end

    it 'notifies Slack even on a notify-only (non-strong) line' do
      handler = described_class.new(make_alert_settings(slack: 'someuser'))
      handler.handle('a novel line', strong: false)
      expect(Lich::DragonRealms::SlackBot.instances.last.dm_calls.last).to eq(['someuser', 'a novel line'])
    end

    it 'queues the auto-quit before the (possibly blocking) Slack send' do
      events = []
      allow_any_instance_of(described_class).to receive(:fput) { |_receiver, cmd| events << [:fput, cmd] }
      allow_any_instance_of(Lich::DragonRealms::SlackBot).to receive(:direct_message) do |_receiver, _user, message|
        events << [:slack, message]
        { 'ok' => true }
      end
      handler = described_class.new(make_alert_settings(quit: true, slack: 'someuser'))
      handler.handle('a plain line', strong: true)
      exit_at = events.index([:fput, 'exit'])
      slack_at = events.index { |kind, _| kind == :slack }
      expect(exit_at).not_to be_nil
      expect(slack_at).not_to be_nil
      expect(exit_at).to be < slack_at
    end

    it 'delivers the alert even when the bot reports it is not initialized' do
      # Regression: gating on initialized? here would suppress delivery forever
      # after a failed first connect. direct_message reconnects on its own.
      Lich::DragonRealms::SlackBot.next_initialized = false
      handler = described_class.new(make_alert_settings(slack: 'someuser'))
      handler.handle('a novel line', strong: false)
      bot = Lich::DragonRealms::SlackBot.instances.last
      expect(bot).not_to be_nil
      expect(bot.dm_calls.last).to eq(['someuser', 'a novel line'])
    end

    it 'does not construct a SlackBot when no username is configured' do
      described_class.new(make_alert_settings(slack: nil)).handle('a plain line', strong: false)
      expect(Lich::DragonRealms::SlackBot.instances).to be_empty
    end

    it 'does not construct a SlackBot at initialize time (lazy, avoids blocking startup)' do
      described_class.new(make_alert_settings(slack: 'someuser'))
      expect(Lich::DragonRealms::SlackBot.instances).to be_empty
    end

    it 'constructs the SlackBot only once across multiple alerts' do
      handler = described_class.new(make_alert_settings(slack: 'someuser'))
      handler.handle('first', strong: false)
      handler.handle('second', strong: false)
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

    it 'filters lines containing an NPC name from UserVars.npcs' do
      UserVars.npcs = ['Grubbnash']
      expect(filter.clean(+'Grubbnash the orc snarls at you')).to be_nil
    end

    it 'does not raise when UserVars.npcs is nil' do
      allow(UserVars).to receive(:npcs).and_return(nil)
      expect { filter.clean(+'a plain line') }.not_to raise_error
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
      status_monitor_learn: false,
      status_monitor_grace_seconds: 0, # disable warm-up grace so alert behavior is testable
      slack_username: nil
    )
  end
  # Injected shared corpus, scoped to the test's tmpdir (never the real DATA_DIR).
  let(:store) { StatusMonitor::MessageStore.new(File.join(tmpdir, 'corpus.db')) }
  # Capture strong-signal auto-actions (typed commands / responses / exit)
  # without redefining the shared fput seam.
  let(:fput_commands) { [] }

  def build_monitor
    described_class.new(settings, store)
  end

  before do
    @original_dir = Dir.pwd
    Dir.chdir(tmpdir)
    # Monitor#load_filter_strings calls the harness get_data('filters'), which
    # returns $test_data[:filters] (reset before each example by reset_data).
    $test_data.filters = OpenStruct.new('filter_strings' => [])
    allow_any_instance_of(StatusMonitor::AlertHandler).to receive(:fput) { |_r, cmd| fput_commands << cmd }
    allow(StatusMonitor::CommandDetector).to receive(:fput) { |cmd| fput_commands << cmd }
  end

  after do
    Dir.chdir(@original_dir)
    FileUtils.rm_rf(tmpdir)
  end

  it 'runs with no filters when the filter data never loads (degrades, does not raise)' do
    $test_data.filters = nil
    monitor = nil
    expect { monitor = build_monitor }.not_to raise_error
    expect(monitor.process(+'a wholly ordinary novel line')).to be true
  end

  describe 'novelty gating (novel-alone)' do
    it 'alerts on a novel line' do
      monitor = build_monitor
      expect(monitor.process(+'A mysterious voice whispers to you')).to be true
      expect(monitor.spam_line).not_to be_nil
    end

    it 'stays silent on a line already persisted in the corpus' do
      store.record('previously imported line')
      monitor = build_monitor
      expect(monitor.process(+'previously imported line')).to be false
      expect(monitor.spam_line).to be_nil
    end
  end

  describe 'alerted lines are never whitelisted' do
    it 'keeps alerting on a plain novel line on every recurrence' do
      monitor = build_monitor
      expect(monitor.process(+'a brand new benign remark')).to be true
      expect(monitor.process(+'a brand new benign remark')).to be true
      expect(store.in_corpus?('a brand new benign remark')).to be false
    end

    it 'never whitelists an own-name line it alerted on (the Kaluto opener stays hot)' do
      # checkname is 'Testchar' in the harness.
      monitor = build_monitor
      expect(monitor.process(+'a crewman mutters that Testchar is wanted')).to be true
      expect(monitor.process(+'a crewman mutters that Testchar is wanted')).to be true
    end

    it 'keeps alerting on a line embedding a command' do
      monitor = build_monitor
      expect(monitor.process(+'a voice says you should JUMP')).to be true
      expect(monitor.process(+'a voice says you should JUMP')).to be true
    end
  end

  describe 'auto-actions gated behind the strong signal' do
    it 'auto-types an embedded command on a novel line (command = strong)' do
      build_monitor.process(+'a voice says you should JUMP')
      expect(fput_commands).to include('jump')
    end

    it 'does not auto-type or quit on a plain novel line, even with those settings on' do
      settings.status_monitor_respond = true
      settings.quit_on_status_warning = true
      build_monitor.process(+'an entirely new but harmless observation')
      expect(fput_commands).to be_empty
    end
  end

  describe 'warm-up suppression (learn / grace / rate-limit)' do
    it 'learns silently with no alert when status_monitor_learn is true' do
      settings.status_monitor_learn = true
      monitor = build_monitor
      expect(monitor.process(+'a novel line during learn mode')).to be false
      # ...but it was still recorded, so it is now known-safe.
      expect(store.in_corpus?(+'a novel line during learn mode')).to be true
    end

    it 'suppresses alerts during the start-up grace period, still learning' do
      settings.status_monitor_grace_seconds = 300
      monitor = build_monitor
      expect(monitor.process(+'a novel line during grace')).to be false
      expect(store.in_corpus?(+'a novel line during grace')).to be true
    end

    it 'never silently whitelists a command line, even during grace' do
      settings.status_monitor_grace_seconds = 300
      monitor = build_monitor
      expect(monitor.process(+'a voice says you should JUMP')).to be false # suppressed
      expect(store.in_corpus?('a voice says you should JUMP')).to be false # but NOT recorded
    end

    it 'rate-limits alerts past the cap, still learning the excess quietly' do
      monitor = build_monitor
      cap = StatusMonitor::Monitor::ALERT_RATE_MAX
      # Distinct, digit-free novel lines so each is its own corpus key.
      cap.times { |i| expect(monitor.process(+"distinct novel remark item #{('a'..'z').to_a[i]}")).to be true }
      # The next distinct novel line is over the cap -> suppressed but learned.
      over = 'yet another distinct novel line over the cap'
      expect(monitor.process(+over)).to be false
      expect(store.in_corpus?(over)).to be true
    end
  end

  describe 'lines that never reach the corpus gate' do
    it 'returns false for nil lines' do
      expect(build_monitor.process(nil)).to be false
    end

    it 'returns false for empty lines' do
      expect(build_monitor.process('')).to be false
    end

    it 'returns false for lines that scrub to whitespace' do
      expect(build_monitor.process(+'42 kronars')).to be false
    end

    it 'returns false for lines matching a filter pattern' do
      $test_data.filters = OpenStruct.new('filter_strings' => ['gold coins'])
      expect(build_monitor.process(+'you see gold coins on the ground')).to be false
    end
  end

  it 'consume_spam_line clears the spam line' do
    monitor = build_monitor
    monitor.instance_variable_set(:@spam_line, 'test spam')
    expect(monitor.consume_spam_line).to eq('test spam')
    expect(monitor.spam_line).to be_nil
  end
end
