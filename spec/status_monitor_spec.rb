# frozen_string_literal: true

require 'sqlite3'
require 'tmpdir'
require 'ostruct'
require 'fileutils'

# Test suite for status-monitor.lic
#
# Covers MessageStore, MessageFilter, AlertHandler,
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

  # Lich hands scripts binary (ASCII-8BIT) game lines; logs are imported as
  # UTF-8 TEXT. The sqlite3 gem binds binary strings as BLOBs, and a BLOB never
  # equals TEXT, so without normalization the two corpora never matched.
  describe 'encoding (binary live lines vs imported UTF-8 TEXT)' do
    snowflakes = 'You feel your coralite yiamura cool and sense that a frosty observer manifested as a series of swirling snowflakes has imparted some new knowledge it observed to the device.'

    def import_text_row(path, line)
      db = SQLite3::Database.new(path)
      db.execute("INSERT INTO seen_messages (line_text, source) VALUES (?, 'import')", [line.encode('UTF-8')])
      db.close
    end

    def row_types(path)
      db = SQLite3::Database.new(path)
      db.execute('SELECT typeof(line_text), typeof(source) FROM seen_messages').tap { db.close }
    end

    it 'finds an imported TEXT line when the live line arrives binary-encoded' do
      store # create the schema
      import_text_row(db_path, snowflakes)
      fresh = described_class.new(db_path) # no in-process cache
      expect(fresh.in_corpus?(snowflakes.b)).to be true
    end

    it 'stores a binary-encoded live line as TEXT (and its source tag as TEXT)' do
      store.record(snowflakes.b, 'learn:Testchar:2026-10-22T04:00:00Z'.b)
      expect(row_types(db_path)).to eq([%w[text text]])
    end

    it 'does not store a second row for a line already imported as TEXT' do
      store
      import_text_row(db_path, snowflakes)
      described_class.new(db_path).record(snowflakes.b)
      expect(store.count).to eq(1)
    end

    it 'matches non-ASCII text across encodings' do
      line = "The bard sings of Tr#{0xE9.chr(Encoding::UTF_8)}maine and the #{0xE6.chr(Encoding::UTF_8)}ther."
      store
      import_text_row(db_path, line)
      expect(described_class.new(db_path).in_corpus?(line.b)).to be true
    end

    it 'matches a line with invalid UTF-8 bytes the same way the importer stores it (scrubbed)' do
      raw = "a broken #{0xFF.chr} byte line".b
      store
      import_text_row(db_path, raw.dup.force_encoding('UTF-8').scrub)
      expect(described_class.new(db_path).in_corpus?(raw)).to be true
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
# AlertHandler -- alert responses
# ---------------------------------------------------------------------------
RSpec.describe StatusMonitor::AlertHandler do
  # handle sends via the harness fput on the handler instance. Capture it
  # per-example rather than redefining the shared fput seam. echo output
  # (beeps, the alert line) lands in the harness displayed_messages.
  let(:fput_commands) { [] }
  before do
    allow_any_instance_of(described_class).to receive(:fput) { |_receiver, cmd| fput_commands << cmd }
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

  context 'notify-only (novel line, not a GM check)' do
    it 'does not type commands, canned responses, or exit' do
      handler = described_class.new(make_alert_settings(respond: true, quit: true))
      handler.handle('you see JUMP here', strong: false)
      expect(fput_commands).to be_empty
    end
  end

  context 'strong signal (GM check)' do
    it 'never types a command found in the line' do
      described_class.new(make_alert_settings).handle('you see JUMP here', strong: true)
      expect(fput_commands).to be_empty
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

    it 'strips the indent the game puts before room text' do
      result = filter.clean(+'<style id=""/>  You also see a <a exist="1" noun="bar">huge bronze bar</a>.')
      expect(result).to eq('You also see a huge bronze bar.')
    end

    it 'reduces a whitespace-only line to an empty string' do
      expect(filter.clean(+"<style id=\"\"/>  \r\n")).to eq('')
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

  describe 'room players parsing (legacy and Saga-identity streams)' do
    let(:legacy_players_line) do
      "<component id='room players'>Also here: Monster Aldric, Brenna who is sitting, " \
        'Corwin (invisible) and Druid Delphine.</component>'
    end

    let(:saga_players_line) do
      "<component id='room players'>Also here: Monster <a exist=\"-10514490\" noun=\"Aldric\">Aldric</a>, " \
        '<a exist="-10514491" noun="Brenna">Brenna</a> who is sitting, ' \
        '<a exist="-10514492" noun="Corwin">Corwin</a> (invisible) and ' \
        'Druid <a exist="-10614301" noun="Delphine">Delphine</a>.</component>'
    end

    it 'parses names from the legacy players line' do
      filter.clean(legacy_players_line)
      expect(filter.instance_variable_get(:@room_players)).to eq(%w[Aldric Brenna Corwin Delphine])
    end

    it 'parses names from the Saga players line, where each name is a link' do
      filter.clean(saga_players_line)
      expect(filter.instance_variable_get(:@room_players)).to eq(%w[Aldric Brenna Corwin Delphine])
    end

    it 'skips an entry that does not end in a name instead of storing nil' do
      filter.clean(+"<component id='room players'>Also here: Aldric and <b>?</b>.</component>")
      expect(filter.instance_variable_get(:@room_players)).to eq(%w[Aldric])
    end

    it 'drops a line that mentions a player from a Saga players line' do
      filter.clean(saga_players_line)
      expect(filter.clean(+'Delphine waves.')).to be_nil
    end

    it 'keeps processing lines after a players line with an unparseable entry' do
      filter.clean(+"<component id='room players'>Also here: <b>?</b>.</component>")
      expect(filter.clean(+'A cold wind blows.')).to eq('A cold wind blows.')
    end

    it 'treats the Saga room block as non-useful' do
      line = '<resource picture="0"/><room><name>[Bosque Deriel, Burial Ground] (230007)</name>' \
             '<description>A quiet place.</description></room>'
      expect(filter.clean(line)).to be_nil
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
      status_monitor_grace_seconds: 0, # disable warm-up grace so alert behavior is testable
      slack_username: nil
    )
  end
  # Injected shared corpus, scoped to the test's tmpdir (never the real DATA_DIR).
  let(:store) { StatusMonitor::MessageStore.new(File.join(tmpdir, 'corpus.db')) }
  # Capture strong-signal auto-actions (canned responses / exit)
  # without redefining the shared fput seam.
  let(:fput_commands) { [] }

  def build_monitor(learn_minutes: nil)
    described_class.new(settings, store, learn_minutes: learn_minutes)
  end

  before do
    @original_dir = Dir.pwd
    Dir.chdir(tmpdir)
    # Monitor#load_filter_strings calls the harness get_data('filters'), which
    # returns $test_data[:filters] (reset before each example by reset_data).
    $test_data.filters = OpenStruct.new('filter_strings' => [])
    allow_any_instance_of(StatusMonitor::AlertHandler).to receive(:fput) { |_r, cmd| fput_commands << cmd }
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

  describe 'alert once, then known' do
    it 'alerts on the first sight of a novel line and records it' do
      monitor = build_monitor
      expect(monitor.process(+'a brand new benign remark')).to be true
      expect(store.in_corpus?('a brand new benign remark')).to be true
    end

    it 'stays silent on the second sight of a line it alerted on' do
      monitor = build_monitor
      expect(monitor.process(+'a brand new benign remark')).to be true
      expect(monitor.process(+'a brand new benign remark')).to be false
    end

    it 'goes quiet for every character once any character has alerted on it (shared corpus)' do
      build_monitor.process(+'a line first seen on one character')
      other_character = build_monitor
      expect(other_character.process(+'a line first seen on one character')).to be false
    end

    it 'treats an own-name line like any other line (alert once)' do
      # checkname is 'Testchar' in the harness.
      monitor = build_monitor
      expect(monitor.process(+'The clerk says, "Testchar, your balance is low."')).to be true
      expect(monitor.process(+'The clerk says, "Testchar, your balance is low."')).to be false
    end
  end

  describe 'commands in game output are never typed' do
    it 'alerts on "---Active RPA---" once without typing rpa, then goes quiet (no rpag feedback loop)' do
      monitor = build_monitor
      expect(monitor.process(+'   ---Active RPA---')).to be true
      expect(monitor.process(+'   ---Active RPA---')).to be false
      expect(fput_commands).to be_empty
    end

    it 'does not type open for the autoloot "when OPENed" notice' do
      build_monitor.process(+'You will automatically loot treasure chests when OPENed. (requires AutoLoot to be enabled)')
      expect(fput_commands).to be_empty
    end

    it 'does not type an obfuscated command either' do
      build_monitor.process(+'a voice says you should J_U_M_P now')
      expect(fput_commands).to be_empty
    end
  end

  describe 'GM checks (CHECK_PATTERNS)' do
    # Verbatim from a failed check (DR-Gnarta, 2026-10-22).
    squirrel_lines = [
      'A fuzzy brown squirrel scurries into the room and looks at you with curious eyes before it runs off.  You hear a child nearby yelling, "Where is my pet squirrel it, it has run away to bother people.  Say go away to shoo him away!"',
      'A large burly squirrel scurries into the room and runs over your foot before it runs off.  You hear a child nearby yelling, "Crazy squirrel, stop bothering people!  Say go away to shoo him away!"',
      'A giant scruffy squirrel scurries into the room and stomps on your feet before it runs off.  You hear a child nearby yelling, "Stupid squirrel, stop bothering people!  Say go away and shake fist to shoo him away!"',
      'A massive red squirrel scurries into the room and stomps on your feet before it runs off.  You hear a child nearby yelling, "That squirrel is very annoying.  It would be a very good idea to shoo it away.  Say go away to get him to leave, before he gets even more annoying."',
      'The child voice sounds like a very sad GameMaster. "I\'m sorry, but have failed this test of your conscious awareness and must now take a little nap.',
      '[Scripting Violation Limbo]',
      'SEND[Sarhanna] ***THIS IS FOR YOUR SCROLLBACK*** You were moved here because you were unresponsive.',
      '[You can use RESPOND {MESSAGE} to reply!]'
    ]

    squirrel_lines.each do |line|
      it "alerts on every recurrence of: #{line[0, 50]}" do
        monitor = build_monitor
        3.times { expect(monitor.process(+line)).to be true }
        expect(store.in_corpus?(line.strip)).to be false
      end
    end

    it 'alerts even when the line is already in the corpus (e.g. merged from a legacy file)' do
      store.record(squirrel_lines.first)
      expect(build_monitor.process(+squirrel_lines.first)).to be true
    end

    it 'alerts during the start-up grace period, and does not record it' do
      settings.status_monitor_grace_seconds = 300
      expect(build_monitor.process(+squirrel_lines.first)).to be true
      expect(store.in_corpus?(squirrel_lines.first)).to be false
    end

    it 'alerts in learn mode, and does not record it' do
      expect(build_monitor(learn_minutes: 30).process(+squirrel_lines.first)).to be true
      expect(store.in_corpus?(squirrel_lines.first)).to be false
    end

    it 'alerts past the rate cap' do
      monitor = build_monitor
      StatusMonitor::Monitor::ALERT_RATE_MAX.times { |i| monitor.process(+"distinct novel remark item #{('a'..'z').to_a[i]}") }
      expect(monitor.process(+'yet another distinct novel line over the cap')).to be false
      expect(monitor.process(+squirrel_lines.first)).to be true
    end

    it 'alerts even when a configured filter would hide the line' do
      $test_data.filters = OpenStruct.new('filter_strings' => ['squirrel'])
      expect(build_monitor.process(+squirrel_lines.first)).to be true
    end

    it 'matches the check on the tag-stripped line' do
      expect(build_monitor.process(+'<pushBold/>[Scripting Violation Limbo]<popBold/>')).to be true
    end

    it 'is the strong signal: canned response and auto-quit fire when configured' do
      settings.status_monitor_respond = true
      settings.quit_on_status_warning = true
      build_monitor.process(+squirrel_lines.first)
      expect(fput_commands).to include('exit')
      expect(fput_commands.any? { |cmd| ["'Hmmm?", "'Yes", "'Ok?"].include?(cmd) }).to be true
    end

    it 'does not auto-act on a plain novel line, even with those settings on' do
      settings.status_monitor_respond = true
      settings.quit_on_status_warning = true
      build_monitor.process(+'an entirely new but harmless observation')
      expect(fput_commands).to be_empty
    end

    it 'does not treat ambient squirrel room text as a check' do
      monitor = build_monitor
      line = 'A fluffy-tailed grey squirrel dashes across the path, closely followed by another.'
      expect(monitor.process(+line)).to be true
      expect(monitor.process(+line)).to be false
    end
  end

  describe 'warm-up suppression (learn / grace) and the rate cap' do
    it 'learns silently with no alert in learn mode' do
      monitor = build_monitor(learn_minutes: 30)
      expect(monitor.process(+'a novel line during learn mode')).to be false
      expect(store.in_corpus?(+'a novel line during learn mode')).to be true
    end

    it 'suppresses alerts during the start-up grace period, still learning' do
      settings.status_monitor_grace_seconds = 300
      monitor = build_monitor
      expect(monitor.process(+'a novel line during grace')).to be false
      expect(store.in_corpus?(+'a novel line during grace')).to be true
    end

    it 'alerts again once the grace period has elapsed' do
      settings.status_monitor_grace_seconds = 60
      start = Time.now
      allow(Time).to receive(:now).and_return(start)
      monitor = build_monitor
      allow(Time).to receive(:now).and_return(start + 61)
      expect(monitor.process(+'a novel line after grace')).to be true
    end

    it 'drops lines past the cap WITHOUT recording them' do
      monitor = build_monitor
      cap = StatusMonitor::Monitor::ALERT_RATE_MAX
      cap.times { |i| expect(monitor.process(+"distinct novel remark item #{('a'..'z').to_a[i]}")).to be true }
      over = 'yet another distinct novel line over the cap'
      expect(monitor.process(+over)).to be false
      expect(store.in_corpus?(over)).to be false
    end

    it 'alerts on a dropped line once the cap window clears' do
      start = Time.now
      allow(Time).to receive(:now).and_return(start)
      monitor = build_monitor
      StatusMonitor::Monitor::ALERT_RATE_MAX.times { |i| monitor.process(+"distinct novel remark item #{('a'..'z').to_a[i]}") }
      over = 'yet another distinct novel line over the cap'
      expect(monitor.process(+over)).to be false
      allow(Time).to receive(:now).and_return(start + StatusMonitor::Monitor::ALERT_RATE_WINDOW + 1)
      expect(monitor.process(+over)).to be true
    end

    it 'does not count GM-check alerts toward the cap' do
      monitor = build_monitor
      20.times { monitor.process(+'[Scripting Violation Limbo]') }
      expect(monitor.process(+'a plain novel line after many checks')).to be true
    end
  end

  describe 'learn mode (explicit, expiring)' do
    let(:start) { Time.local(2026, 10, 22, 16, 30, 0) }
    let(:db) { SQLite3::Database.new(File.join(tmpdir, 'corpus.db')) }

    before do
      allow(Time).to receive(:now).and_return(start)
      Lich::DragonRealms::SlackBot.instances.clear
      settings.slack_username = 'someuser'
    end

    after { db.close }

    def slack_messages
      Lich::DragonRealms::SlackBot.instances.flat_map { |bot| bot.dm_calls.map(&:last) }
    end

    def source_of(line)
      db.get_first_value('SELECT source FROM seen_messages WHERE line_text = ?', [line])
    end

    it 'is off unless requested: a plain start alerts on novel lines (grace disabled in these specs)' do
      expect(build_monitor.process(+'a novel line with no learn argument')).to be true
    end

    it 'announces the session, its end time and that GM checks still alert, on Slack too' do
      build_monitor(learn_minutes: 30)
      expect(slack_messages.last).to include('LEARN MODE for 30 min (until 17:00)', 'GM checks still alert')
    end

    it 'prints the exact undo statement for the session' do
      monitor = build_monitor(learn_minutes: 30)
      expect(displayed_messages.last).to eq("status-monitor: to undo this session: DELETE FROM seen_messages WHERE source = '#{monitor.learn_source}'")
    end

    it 'tags lines it learns with a per-session source naming the character and start time' do
      monitor = build_monitor(learn_minutes: 30)
      monitor.process(+'a line learned in this session')
      expect(monitor.learn_source).to eq("learn:Testchar:#{start.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}")
      expect(source_of('a line learned in this session')).to eq(monitor.learn_source)
    end

    it 'the undo statement removes exactly what the session learned' do
      store.record('a line known before the session')
      monitor = build_monitor(learn_minutes: 30)
      monitor.process(+'a line learned in this session')
      db.execute('DELETE FROM seen_messages WHERE source = ?', [monitor.learn_source])
      expect(source_of('a line learned in this session')).to be_nil
      expect(source_of('a line known before the session')).to eq('live')
    end

    it 'still learns right up to the last second of the window' do
      monitor = build_monitor(learn_minutes: 30)
      allow(Time).to receive(:now).and_return(start + (30 * 60) - 1)
      expect(monitor.process(+'a line just before expiry')).to be false
    end

    it 'expires on its own and alerts on the next novel line' do
      monitor = build_monitor(learn_minutes: 30)
      allow(Time).to receive(:now).and_return(start + (30 * 60))
      expect(monitor.process(+'a novel line after learn mode')).to be true
    end

    it 'announces the end on Slack as soon as any line arrives, even a known one' do
      store.record('a line already known')
      monitor = build_monitor(learn_minutes: 30)
      allow(Time).to receive(:now).and_return(start + (31 * 60))
      monitor.process(+'a line already known')
      expect(slack_messages.last).to eq('status-monitor: learn mode ended -- alerting on new lines again.')
    end

    it 'announces the end only once' do
      monitor = build_monitor(learn_minutes: 30)
      allow(Time).to receive(:now).and_return(start + (31 * 60))
      3.times { monitor.process(+'a line already known') }
      expect(slack_messages.count { |m| m.include?('learn mode ended') }).to eq(1)
    end

    it 'reminds every 10 minutes while learning' do
      monitor = build_monitor(learn_minutes: 30)
      [599, 600, 900, 1200].each do |offset|
        allow(Time).to receive(:now).and_return(start + offset)
        monitor.process(+'a line already known')
      end
      reminders = displayed_messages.grep(/LEARN MODE until 17:00 -- not alerting/)
      expect(reminders.size).to eq(2) # at 600s and 1200s, not at 599s or 900s
    end

    it 'honours a custom length' do
      monitor = build_monitor(learn_minutes: 90)
      allow(Time).to receive(:now).and_return(start + (89 * 60))
      expect(monitor.process(+'still learning at 89 minutes')).to be false
      allow(Time).to receive(:now).and_return(start + (90 * 60))
      expect(monitor.process(+'alerting at 90 minutes')).to be true
    end

    it 'never records a GM check line while learning' do
      monitor = build_monitor(learn_minutes: 30)
      monitor.process(+'[Scripting Violation Limbo]')
      expect(source_of('[Scripting Violation Limbo]')).to be_nil
    end

    it 'keeps the start-up grace period quiet: no Slack notices at start or end' do
      settings.status_monitor_grace_seconds = 60
      monitor = build_monitor
      allow(Time).to receive(:now).and_return(start + 61)
      monitor.process(+'a line after grace')
      expect(slack_messages.grep(/LEARN MODE|learn mode ended/)).to be_empty
    end

    it 'tags lines learned during the grace period with the session source too' do
      settings.status_monitor_grace_seconds = 60
      monitor = build_monitor
      monitor.process(+'a line learned during grace')
      expect(source_of('a line learned during grace')).to eq(monitor.learn_source)
    end

    it 'records alerted lines as live, not as learned' do
      monitor = build_monitor
      monitor.process(+'an alerted novel line')
      expect(source_of('an alerted novel line')).to eq('live')
    end
  end

  describe 'the learn argument' do
    # The arg definitions are top-level script code, so read the literal back.
    let(:learn_regex) do
      definition = File.readlines(File.join(File.dirname(__FILE__), '..', 'status-monitor.lic')).grep(/name: 'learn'/).first
      source, flags = definition.match(%r{regex: /(.*?)/(\w*),}).captures
      Regexp.new(source, flags.include?('i') ? Regexp::IGNORECASE : nil)
    end

    it 'accepts learn and learn=N' do
      expect(%w[learn LEARN learn=90 learn=5]).to all(match(learn_regex))
    end

    it 'rejects learn=0, negative, non-numeric and partial words (Lich then shows usage)' do
      %w[learn=0 learn=-5 learn=abc learning relearn learn= learn=05].each do |arg|
        expect(arg).not_to match(learn_regex)
      end
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

    it 'applies ^-anchored filters to indented room text, and does not record it' do
      $test_data.filters = OpenStruct.new('filter_strings' => ['^You also see (?:an?|some|[Tt]he) '])
      line = '<style id=""/>  You also see a <a exist="1" noun="bar">huge bronze bar</a>.'
      expect(build_monitor.process(+line)).to be false
      expect(store.in_corpus?('You also see a huge bronze bar.')).to be false
    end
  end

  it 'consume_spam_line clears the spam line' do
    monitor = build_monitor
    monitor.instance_variable_set(:@spam_line, 'test spam')
    expect(monitor.consume_spam_line).to eq('test spam')
    expect(monitor.spam_line).to be_nil
  end
end
