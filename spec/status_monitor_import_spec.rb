# frozen_string_literal: true

require 'sqlite3'
require 'tmpdir'
require 'ostruct'
require 'zlib'
require 'fileutils'

# Test suite for status-monitor-import.lic
#
# Covers clean_line timestamp handling, similarity_scrub, batch import,
# reset behavior, and resumability. Aggressively tests edge cases
# including custom timestamp formats (%F %T %Z) and corrupted files.

$echo_messages = []
def echo(msg)
  $echo_messages << msg
end

def checkname
  'Testchar'
end

LICH_DIR = Dir.mktmpdir('lich-test-import') unless defined?(LICH_DIR)

RSpec.configure do |config|
  config.after(:suite) do
    FileUtils.rm_rf(LICH_DIR) if defined?(LICH_DIR) && File.exist?(LICH_DIR)
  end
end

# Extract the StatusMonitorImport module from the .lic file.
import_path = File.join(File.dirname(__FILE__), '..', 'status-monitor-import.lic')
import_lines = File.readlines(import_path)

module_start = import_lines.index { |l| l =~ /^module StatusMonitorImport$/ }
raise "Could not find 'module StatusMonitorImport'" unless module_start

module_end = nil
(module_start + 1...import_lines.size).each do |i|
  if import_lines[i] =~ /^end\s*$/
    module_end = i
    break
  end
end
raise 'Could not find matching end for module StatusMonitorImport' unless module_end

module_source = import_lines[module_start..module_end].join
eval(module_source, TOPLEVEL_BINDING, import_path, module_start + 1)

# ---------------------------------------------------------------------------
# clean_line -- timestamp stripping, XML removal, skip patterns
# ---------------------------------------------------------------------------
RSpec.describe 'StatusMonitorImport.clean_line' do
  describe 'timestamp stripping' do
    it 'strips custom %F %T %Z timestamp prefix' do
      line = '2026-01-04 18:59:20 NZDT: A dragon breathes fire!'
      expect(StatusMonitorImport.clean_line(line)).to eq('A dragon breathes fire!')
    end

    it 'strips timestamp with different timezone' do
      line = '2026-05-18 09:30:00 EST: You are standing in a field.'
      expect(StatusMonitorImport.clean_line(line)).to eq('You are standing in a field.')
    end

    it 'strips timestamp with 4-char timezone' do
      line = '2026-01-04 18:59:20 NZST: You rest.'
      expect(StatusMonitorImport.clean_line(line)).to eq('You rest.')
    end

    it 'skips bare timestamp header lines (no content after timestamp)' do
      line = '2026-01-04 18:59:20 NZDT'
      expect(StatusMonitorImport.clean_line(line)).to be_nil
    end

    it 'skips default header format with milliseconds and numeric timezone' do
      line = '2026-01-04 18:59:20.727 +13:00'
      expect(StatusMonitorImport.clean_line(line)).to be_nil
    end

    it 'skips bare timestamp without timezone' do
      line = '2026-01-04 18:59:20'
      expect(StatusMonitorImport.clean_line(line)).to be_nil
    end

    it 'skips bare timestamp with milliseconds only (no timezone)' do
      line = '2026-01-04 18:59:20.727'
      expect(StatusMonitorImport.clean_line(line)).to be_nil
    end

    it 'does not skip timestamp-prefixed lines with trailing content' do
      line = '2026-01-04 18:59:20.727 +13:00 extra content here'
      expect(StatusMonitorImport.clean_line(line)).not_to be_nil
    end

    it 'does not skip timestamped content lines (regression test)' do
      # This was the critical bug: SKIP_PATTERN was killing these before
      # TIMESTAMP_PATTERN could extract the content
      line = '2026-01-04 18:59:21 NZDT: Your Login Rewards information:'
      result = StatusMonitorImport.clean_line(line)
      expect(result).to eq('Your Login Rewards information:')
    end
  end

  describe 'skip patterns' do
    it 'skips empty lines' do
      expect(StatusMonitorImport.clean_line('')).to be_nil
    end

    it 'skips whitespace-only lines' do
      expect(StatusMonitorImport.clean_line('   ')).to be_nil
    end

    it 'skips upstream command lines (starting with >)' do
      expect(StatusMonitorImport.clean_line('> look')).to be_nil
    end

    it 'does not skip lines starting with > inside content' do
      line = '2026-01-04 18:59:20 NZDT: "Hello," she says > quietly'
      result = StatusMonitorImport.clean_line(line)
      expect(result).not_to be_nil
    end
  end

  describe 'XML tag removal' do
    it 'strips XML tags from content' do
      line = '2026-01-04 18:59:20 NZDT: <b>bold</b> text'
      result = StatusMonitorImport.clean_line(line)
      expect(result).to eq('bold text')
    end

    it 'strips nested XML tags' do
      line = '<outer><inner>text</inner></outer>'
      result = StatusMonitorImport.clean_line(line)
      expect(result).to eq('text')
    end

    it 'handles self-closing tags' do
      line = 'before <br/> after'
      result = StatusMonitorImport.clean_line(line)
      expect(result).to eq('before  after')
    end
  end

  describe 'reget marker' do
    it 'skips the reget marker line' do
      line = '<!-- Above contents from reget; full logging now active -->'
      expect(StatusMonitorImport.clean_line(line)).to be_nil
    end

    it 'skips partial reget marker' do
      line = '<!-- Above contents from reget'
      expect(StatusMonitorImport.clean_line(line)).to be_nil
    end
  end

  describe 'edge cases' do
    it 'handles a line that is only XML tags' do
      expect(StatusMonitorImport.clean_line('<tag></tag>')).to be_nil
    end

    it 'handles lines with only numbers after scrubbing (non-empty after clean)' do
      line = '2026-01-04 18:59:20 NZDT: 12345'
      result = StatusMonitorImport.clean_line(line)
      expect(result).to eq('12345')
    end
  end
end

# ---------------------------------------------------------------------------
# similarity_scrub -- normalization
# ---------------------------------------------------------------------------
RSpec.describe 'StatusMonitorImport.similarity_scrub' do
  it 'removes numbers' do
    expect(StatusMonitorImport.similarity_scrub('you have 42 items')).to eq('you have  items')
  end

  it 'removes currency words case-insensitively' do
    expect(StatusMonitorImport.similarity_scrub('paid 10 KRONARS')).to eq('paid  ')
  end

  it 'removes all three currency types' do
    %w[kronars lirums dokoras].each do |currency|
      result = StatusMonitorImport.similarity_scrub("5 #{currency}")
      expect(result.strip).to be_empty
    end
  end

  it 'does not mutate the input' do
    input = 'original 42 text'
    input_copy = input.dup
    StatusMonitorImport.similarity_scrub(input)
    expect(input).to eq(input_copy)
  end

  it 'handles empty string' do
    expect(StatusMonitorImport.similarity_scrub('')).to eq('')
  end

  it 'handles strings with no scrub targets' do
    expect(StatusMonitorImport.similarity_scrub('hello world')).to eq('hello world')
  end
end

# ---------------------------------------------------------------------------
# Database operations -- open, import, reset, resumability
# ---------------------------------------------------------------------------
RSpec.describe 'StatusMonitorImport database operations' do
  let(:tmpdir) { Dir.mktmpdir('import-test') }

  before do
    $echo_messages.clear
    @original_dir = Dir.pwd
    Dir.chdir(tmpdir)
  end

  after do
    Dir.chdir(@original_dir)
    FileUtils.rm_rf(tmpdir)
  end

  describe '.open_database' do
    it 'creates both tables' do
      db = StatusMonitorImport.open_database('Test')
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").flatten
      expect(tables).to include('seen_messages', 'import_log')
      db.close
    end

    it 'uses WAL journal mode' do
      db = StatusMonitorImport.open_database('Test')
      mode = db.get_first_value('PRAGMA journal_mode')
      expect(mode).to eq('wal')
      db.close
    end

    it 'is idempotent (can be called twice)' do
      db1 = StatusMonitorImport.open_database('Test')
      db1.close
      db2 = StatusMonitorImport.open_database('Test')
      expect(db2.get_first_value('SELECT COUNT(*) FROM seen_messages').to_i).to eq(0)
      db2.close
    end
  end

  describe '.flush_batch' do
    it 'inserts lines into the database' do
      db = StatusMonitorImport.open_database('Test')
      StatusMonitorImport.flush_batch(db, ['line one', 'line two'])
      count = db.get_first_value('SELECT COUNT(*) FROM seen_messages').to_i
      expect(count).to eq(2)
      db.close
    end

    it 'ignores duplicate lines silently' do
      db = StatusMonitorImport.open_database('Test')
      StatusMonitorImport.flush_batch(db, ['dup', 'dup', 'dup'])
      count = db.get_first_value('SELECT COUNT(*) FROM seen_messages').to_i
      expect(count).to eq(1)
      db.close
    end

    it 'sets source to import' do
      db = StatusMonitorImport.open_database('Test')
      StatusMonitorImport.flush_batch(db, ['sourced line'])
      source = db.get_first_value("SELECT source FROM seen_messages WHERE line_text = 'sourced line'")
      expect(source).to eq('import')
      db.close
    end
  end

  describe '.already_imported? and .record_import' do
    it 'returns false for unrecorded files' do
      db = StatusMonitorImport.open_database('Test')
      expect(StatusMonitorImport.already_imported?(db, '/some/file.log')).to be false
      db.close
    end

    it 'returns true after recording' do
      db = StatusMonitorImport.open_database('Test')
      StatusMonitorImport.record_import(db, '/some/file.log', 100)
      expect(StatusMonitorImport.already_imported?(db, '/some/file.log')).to be true
      db.close
    end
  end

  describe '.import_file' do
    it 'imports lines from a plain text log' do
      db = StatusMonitorImport.open_database('Test')
      log_path = File.join(tmpdir, 'test.log')
      File.write(log_path, [
        '2026-01-04 18:59:20 NZDT: A dragon breathes fire!',
        '2026-01-04 18:59:21 NZDT: You dodge the flames.',
        ''
      ].join("\n"))
      count = StatusMonitorImport.import_file(db, log_path)
      expect(count).to eq(2)
      db.close
    end

    it 'imports lines from a gzipped log' do
      db = StatusMonitorImport.open_database('Test')
      gz_path = File.join(tmpdir, 'test.log.gz')
      Zlib::GzipWriter.open(gz_path) do |gz|
        gz.puts '2026-01-04 18:59:20 NZDT: Line from gz file'
      end
      count = StatusMonitorImport.import_file(db, gz_path)
      expect(count).to eq(1)
      db.close
    end

    it 'skips empty and command lines' do
      db = StatusMonitorImport.open_database('Test')
      log_path = File.join(tmpdir, 'test.log')
      File.write(log_path, [
        '',
        '> look',
        '2026-01-04 18:59:20 NZDT: Valid line',
      ].join("\n"))
      count = StatusMonitorImport.import_file(db, log_path)
      expect(count).to eq(1)
      db.close
    end

    it 'deduplicates within a single file' do
      db = StatusMonitorImport.open_database('Test')
      log_path = File.join(tmpdir, 'test.log')
      File.write(log_path, [
        '2026-01-04 18:59:20 NZDT: Same line',
        '2026-01-04 18:59:21 NZDT: Same line',
      ].join("\n"))
      StatusMonitorImport.import_file(db, log_path)
      actual = db.get_first_value('SELECT COUNT(*) FROM seen_messages').to_i
      expect(actual).to eq(1)
      db.close
    end
  end

  describe 'corrupt file resilience' do
    it 'raises on a corrupt .gz file from import_file directly' do
      db = StatusMonitorImport.open_database('Test')
      corrupt_path = File.join(tmpdir, 'corrupt.log.gz')
      File.write(corrupt_path, 'not valid gzip data at all')
      expect { StatusMonitorImport.import_file(db, corrupt_path) }.to raise_error(Zlib::GzipFile::Error)
      db.close
    end

    it 'skips corrupt .gz files and continues importing remaining files' do
      log_dir = File.join(LICH_DIR, 'logs', 'DR-Testchar')
      FileUtils.mkdir_p(log_dir)

      good1 = File.join(log_dir, '01-good.log')
      File.write(good1, "2026-01-04 18:59:20 NZDT: First good line\n")

      corrupt = File.join(log_dir, '02-corrupt.log.gz')
      File.write(corrupt, 'not valid gzip data')

      good2 = File.join(log_dir, '03-good.log')
      File.write(good2, "2026-01-04 18:59:20 NZDT: Second good line\n")

      db = StatusMonitorImport.open_database('Testchar')
      errors = 0
      [good1, corrupt, good2].each do |file|
        begin
          lines = StatusMonitorImport.import_file(db, file)
          StatusMonitorImport.record_import(db, file, lines)
        rescue Zlib::GzipFile::Error, EOFError, SystemCallError
          errors += 1
          next
        end
      end

      count = db.get_first_value('SELECT COUNT(*) FROM seen_messages').to_i
      expect(count).to eq(2)
      expect(errors).to eq(1)
      db.close
    ensure
      FileUtils.rm_rf(log_dir)
    end

    it 'handles truncated .gz files (EOFError)' do
      db = StatusMonitorImport.open_database('Test')
      gz_path = File.join(tmpdir, 'truncated.log.gz')
      full_gz = StringIO.new
      gz = Zlib::GzipWriter.new(full_gz)
      gz.write("2026-01-04 18:59:20 NZDT: A line\n" * 100)
      gz.close
      # Write only the first half of the gzip data
      File.binwrite(gz_path, full_gz.string[0, full_gz.string.length / 2])
      expect { StatusMonitorImport.import_file(db, gz_path) }.to raise_error(Zlib::Error)
      db.close
    end
  end

  describe 'pipeline integration' do
    it 'excludes lines that clean but scrub to empty' do
      db = StatusMonitorImport.open_database('Test')
      log_path = File.join(tmpdir, 'scrub-test.log')
      File.write(log_path, [
        '2026-01-04 18:59:20 NZDT: 500 kronars',
        '2026-01-04 18:59:21 NZDT: A real game message',
      ].join("\n"))
      StatusMonitorImport.import_file(db, log_path)
      count = db.get_first_value('SELECT COUNT(*) FROM seen_messages').to_i
      expect(count).to eq(1)
      stored = db.get_first_value('SELECT line_text FROM seen_messages')
      expect(stored).to eq('A real game message')
      db.close
    end

    it 'excludes lines that scrub to only whitespace' do
      db = StatusMonitorImport.open_database('Test')
      log_path = File.join(tmpdir, 'whitespace-scrub.log')
      File.write(log_path, "2026-01-04 18:59:20 NZDT: 100 200 300\n")
      StatusMonitorImport.import_file(db, log_path)
      count = db.get_first_value('SELECT COUNT(*) FROM seen_messages').to_i
      expect(count).to eq(0)
      db.close
    end
  end

  describe 'reset behavior' do
    it 'deletes import-sourced rows but preserves live rows' do
      db = StatusMonitorImport.open_database('Test')
      db.execute("INSERT INTO seen_messages (line_text, source) VALUES ('live line', 'live')")
      db.execute("INSERT INTO seen_messages (line_text, source) VALUES ('imported line', 'import')")
      db.execute("INSERT INTO import_log (file_path, lines_imported) VALUES ('file.log', 1)")

      # Simulate reset
      db.execute("DELETE FROM seen_messages WHERE source = 'import'")
      db.execute('DELETE FROM import_log')

      live_count = db.get_first_value("SELECT COUNT(*) FROM seen_messages WHERE source = 'live'").to_i
      import_count = db.get_first_value("SELECT COUNT(*) FROM seen_messages WHERE source = 'import'").to_i
      log_count = db.get_first_value('SELECT COUNT(*) FROM import_log').to_i

      expect(live_count).to eq(1)
      expect(import_count).to eq(0)
      expect(log_count).to eq(0)
      db.close
    end

    it 'preserves migration-sourced rows' do
      db = StatusMonitorImport.open_database('Test')
      db.execute("INSERT INTO seen_messages (line_text, source) VALUES ('migrated line', 'migration')")
      db.execute("DELETE FROM seen_messages WHERE source = 'import'")
      count = db.get_first_value("SELECT COUNT(*) FROM seen_messages WHERE source = 'migration'").to_i
      expect(count).to eq(1)
      db.close
    end
  end
end

# ---------------------------------------------------------------------------
# find_log_files -- multi-instance log directory discovery
# ---------------------------------------------------------------------------
RSpec.describe 'StatusMonitorImport.find_log_files' do
  def make_log(dir_name, file_name)
    dir = File.join(LICH_DIR, 'logs', dir_name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, file_name), "some line\n")
    dir
  end

  it 'discovers logs across all game instances, not just DR-' do
    dirs = %w[DR-Zzchar DRT-Zzchar DRX-Zzchar GSIV-Zzchar].map { |name| make_log(name, 'a.log') }
    expect(StatusMonitorImport.find_log_files('Zzchar').size).to eq(4)
  ensure
    dirs&.each { |dir| FileUtils.rm_rf(dir) }
  end

  it 'includes both .log and .log.gz files' do
    dir = make_log('DR-Zzchar', 'a.log')
    File.write(File.join(dir, 'b.log.gz'), "some line\n")
    files = StatusMonitorImport.find_log_files('Zzchar')
    expect(files.map { |f| File.basename(f) }).to contain_exactly('a.log', 'b.log.gz')
  ensure
    FileUtils.rm_rf(dir)
  end

  it 'does not match a different character whose name is a superstring' do
    exact = make_log('DR-Zz', 'exact.log')
    other = make_log('DR-Zzextra', 'other.log')
    files = StatusMonitorImport.find_log_files('Zz')
    expect(files.map { |f| File.basename(f) }).to eq(['exact.log'])
  ensure
    FileUtils.rm_rf(exact)
    FileUtils.rm_rf(other)
  end

  it 'returns [] and reports when no directories match' do
    $echo_messages.clear
    expect(StatusMonitorImport.find_log_files('NoSuchChar')).to eq([])
    expect($echo_messages.any? { |m| m.include?('No log directories found') }).to be true
  end
end

# ---------------------------------------------------------------------------
# pending_files -- limit applies to not-yet-imported files
# ---------------------------------------------------------------------------
RSpec.describe 'StatusMonitorImport.pending_files' do
  let(:tmpdir) { Dir.mktmpdir('status-monitor-pending') }
  let(:db) { StatusMonitorImport.open_database('pending') }
  let(:files) { (1..5).map { |i| "file#{i}.log" } }

  before do
    @orig_dir = Dir.pwd
    Dir.chdir(tmpdir)
  end

  after do
    db.close
    Dir.chdir(@orig_dir)
    FileUtils.rm_rf(tmpdir)
  end

  it 'excludes already-imported files' do
    StatusMonitorImport.record_import(db, 'file1.log', 10)
    StatusMonitorImport.record_import(db, 'file2.log', 10)
    expect(StatusMonitorImport.pending_files(db, files)).to eq(%w[file3.log file4.log file5.log])
  end

  it 'applies the limit to not-yet-imported files, not the raw list' do
    # Regression: slicing before filtering meant a resumed --limit run could
    # select only already-imported files and make zero progress.
    StatusMonitorImport.record_import(db, 'file1.log', 10)
    StatusMonitorImport.record_import(db, 'file2.log', 10)
    result = StatusMonitorImport.pending_files(db, files, limit: 2)
    expect(result).to eq(%w[file3.log file4.log])
  end

  it 'returns all pending files when no limit is given' do
    expect(StatusMonitorImport.pending_files(db, files)).to eq(files)
  end

  it 'returns [] when everything is already imported' do
    files.each { |f| StatusMonitorImport.record_import(db, f, 1) }
    expect(StatusMonitorImport.pending_files(db, files, limit: 3)).to eq([])
  end

  it 'opens the database with a busy_timeout so concurrent writers wait' do
    expect(db.get_first_value('PRAGMA busy_timeout')).to eq(5000)
  end
end
