#!/usr/bin/env ruby
# frozen_string_literal: true

# Empirical parity diagnostic for status-monitor <-> status-monitor-import.
#
# Replays real game logs through BOTH code paths and reports where they disagree:
#   - the IMPORT path:  similarity_scrub(clean_line(raw_log_line))
#   - the LIVE path:     similarity_scrub(clean(raw_log_line_without_timestamp))
#
# The live monitor only ever stores a line as key K if clean() keeps it. So the
# invariant that makes the import feature actually work is:
#
#     for every line the LIVE path keeps, the IMPORT path must produce the SAME key
#
# Each line is bucketed:
#   [import-only]  live dropped it (stream/room-player/non-useful filter) but
#                  import kept it -- expected corpus bloat, harmless.
#   [live-only]    live kept it but import dropped it -- import is MISSING a line
#                  the live monitor would record. A real gap.
#   [match]        both kept it and the keys are identical -- good.
#   [MISMATCH]     both kept it but the keys differ -- the corpus will not
#                  recognize this live line as seen. A real bug.
#
# NOTE npcs / players_online filtering cannot be reproduced offline (no live
# game state), so a handful of [import-only] lines here would also be dropped
# live in practice. That only inflates [import-only]; it never hides a MISMATCH,
# because a MISMATCH requires the live path to KEEP the line.
#
# Usage:
#   ruby util/status_monitor_parity_diag.rb <log_file_or_dir> [options]
#     --db=PATH     also cross-check against a real seen_messages_<Char>.db:
#                   what fraction of its source='live' keys appear in the
#                   corpus this run would import.
#     --repo=PATH   dr-scripts root (default: parent of this script's dir)
#     --show=N      how many distinct examples to print per bucket (default 15)

require 'zlib'

opts = { show: 15, repo: File.expand_path('..', __dir__) }
paths = []
ARGV.each do |a|
  case a
  when /\A--db=(.+)/     then opts[:db] = Regexp.last_match(1)
  when /\A--repo=(.+)/   then opts[:repo] = Regexp.last_match(1)
  when /\A--show=(\d+)/  then opts[:show] = Regexp.last_match(1).to_i
  when /\A--/            then abort "unknown option: #{a}"
  else paths << a
  end
end
abort 'usage: status_monitor_parity_diag.rb <log_file_or_dir> [--db=PATH] [--repo=PATH] [--show=N]' if paths.empty?

# --- Minimal Lich seams the extracted modules touch (offline) ---------------
module UserVars
  def self.npcs = []
  def self.players_online = nil
end

def checkname = 'diag'
def echo(*) = nil
def pause(*) = nil

# --- Extract the two modules straight out of the .lic files ------------------
def extract_lic_module(repo, filename, module_name)
  path = File.join(repo, filename)
  lines = File.readlines(path)
  start = lines.index { |l| l =~ /^module #{module_name}$/ } or abort "no module #{module_name} in #{filename}"
  stop  = (start + 1...lines.size).find { |i| lines[i] =~ /^end\s*$/ } or abort "no end for #{module_name}"
  eval(lines[start..stop].join, TOPLEVEL_BINDING, path, start + 1)
end
extract_lic_module(opts[:repo], 'status-monitor.lic', 'StatusMonitor')
extract_lic_module(opts[:repo], 'status-monitor-import.lic', 'StatusMonitorImport')

# --- Gather log files --------------------------------------------------------
def log_files(paths)
  paths.flat_map do |p|
    if File.directory?(p)
      Dir.glob(File.join(p, '**', '*.log')) + Dir.glob(File.join(p, '**', '*.log.gz'))
    else
      [p]
    end
  end.sort
end

def each_line(path)
  reader = path.end_with?('.gz') ? Zlib::GzipReader.open(path) : File.open(path, 'r')
  reader.each_line { |l| yield l.scrub } # scrub: don't let one bad byte kill the diag
ensure
  reader&.close
end

TS = StatusMonitorImport::TIMESTAMP_PATTERN

# Log framing the real game stream never delivers to the live monitor: blank
# lines, upstream command echoes, bare-timestamp headers, and reget markers.
# These are exactly clean_line's structural skips, so reusing them keeps the
# simulation aligned with the importer by construction. (pushStream/popStream
# lines are NOT framing -- they are real stream content and must still flow to
# live.clean so its per-stream filter state stays in sync.)
def framing?(stripped)
  StatusMonitorImport::SKIP_PATTERNS.any? { |p| p.match?(stripped) } ||
    stripped.match?(StatusMonitorImport::BARE_TIMESTAMP_PATTERN) ||
    stripped.match?(StatusMonitorImport::REGET_MARKER)
end

def key_for(cleaned, scrub)
  return nil unless cleaned

  k = scrub.call(cleaned).strip
  k.empty? ? nil : k
end

counts = Hash.new(0)
examples = Hash.new { |h, k| h[k] = [] }
import_keys = {} # corpus this run would produce (for the --db cross-check)
bad_bytes = 0

files = log_files(paths)
abort "no .log/.log.gz files under #{paths.inspect}" if files.empty?
warn "Scanning #{files.size} file(s)..."

files.each do |file|
  live = StatusMonitor::MessageFilter.new([]) # fresh per file: stream state is per session
  import_scrub = StatusMonitorImport.method(:similarity_scrub)
  live_scrub = live.method(:similarity_scrub)
  begin
    each_line(file) do |raw|
      counts[:lines] += 1
      next if framing?(raw.strip) # never reaches either detector as content

      stream_line = raw.sub(TS, '') # what the live monitor would have seen
      import_key = key_for(StatusMonitorImport.clean_line(raw), import_scrub)
      live_key = key_for(live.clean(stream_line), live_scrub)
      import_keys[import_key] = true if import_key

      if live_key && import_key
        if live_key == import_key
          counts[:match] += 1
        else
          counts[:mismatch] += 1
          examples[:mismatch] << [live_key, import_key] if examples[:mismatch].size < opts[:show] * 4
        end
      elsif live_key && import_key.nil?
        counts[:live_only] += 1
        examples[:live_only] << live_key if examples[:live_only].size < opts[:show] * 4
      elsif import_key && live_key.nil?
        counts[:import_only] += 1
      end
    end
  rescue ArgumentError, Zlib::Error, EOFError, SystemCallError => e
    bad_bytes += 1
    warn "  skipped #{file}: #{e.class}: #{e.message}"
  end
end

def uniq_take(list, n)
  list.uniq.first(n)
end

puts
puts '=== status-monitor import/live parity ==='
puts "files scanned      : #{files.size} (#{bad_bytes} skipped on error)"
puts "lines seen         : #{counts[:lines]}"
puts "both keep, MATCH   : #{counts[:match]}"
puts "both keep, MISMATCH: #{counts[:mismatch]}   <-- must be 0"
puts "live-only (import missed a kept line): #{counts[:live_only]}   <-- should be ~0"
puts "import-only (live filtered it)        : #{counts[:import_only]}   (expected bloat)"

if counts[:mismatch].positive?
  puts
  puts "-- distinct MISMATCH examples (live_key  |  import_key) --"
  uniq_take(examples[:mismatch], opts[:show]).each { |lk, ik| puts "  #{lk.inspect}\n    -> #{ik.inspect}" }
end

if counts[:live_only].positive?
  puts
  puts '-- distinct live-only examples (kept live, dropped by import) --'
  uniq_take(examples[:live_only], opts[:show]).each { |lk| puts "  #{lk.inspect}" }
end

if opts[:db]
  require 'sqlite3'
  db = SQLite3::Database.new(opts[:db])
  live_corpus = db.execute("SELECT line_text FROM seen_messages WHERE source = 'live'").flatten
  db.close
  covered = live_corpus.count { |k| import_keys[k] }
  pct = live_corpus.empty? ? 0.0 : (covered * 100.0 / live_corpus.size).round(1)
  puts
  puts '=== cross-check vs real live corpus ==='
  puts "live keys in #{File.basename(opts[:db])}: #{live_corpus.size}"
  puts "also produced by this import run   : #{covered} (#{pct}%)"
  puts '(< 100% is expected -- live saw lines not in these logs. A LOW % signals'
  puts ' systemic format divergence, e.g. HTML-entity encoding differences.)'
end
