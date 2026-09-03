# frozen_string_literal: true

require 'ostruct'

# Cross-script parity guard for status-monitor.lic <-> status-monitor-import.lic.
#
# The two scripts each carry their own copy of the message-normalization logic
# (similarity_scrub) and both strip the same XML/whitespace, so that a line
# imported from a log produces the SAME corpus key the live monitor would store.
# If the two ever diverge, the imported corpus silently stops recognizing live
# lines as "seen" and the import feature becomes a no-op with no error.
#
# Lich eval's scripts as text (see lich-5 lib/common/script.rb), so there is no
# reliable require_relative and the logic cannot be lifted into a shared file
# both scripts load. This spec is the single source of truth instead: it fails
# CI the moment the two implementations produce different output.
#
# Both modules are extracted with a const guard so this file is order-independent
# whether it runs alone or alongside the per-script specs.
def self.extract_lic_module(filename, module_name)
  return if Object.const_defined?(module_name)

  path = File.join(File.dirname(__FILE__), '..', filename)
  lines = File.readlines(path)
  start = lines.index { |l| l =~ /^module #{module_name}$/ }
  raise "Could not find 'module #{module_name}' in #{filename}" unless start

  stop = (start + 1...lines.size).find { |i| lines[i] =~ /^end\s*$/ }
  raise "Could not find matching end for '#{module_name}' in #{filename}" unless stop

  eval(lines[start..stop].join, TOPLEVEL_BINDING, path, start + 1)
end

extract_lic_module('status-monitor.lic', 'StatusMonitor')
extract_lic_module('status-monitor-import.lic', 'StatusMonitorImport')

RSpec.describe 'status-monitor / status-monitor-import parity' do
  # similarity_scrub is an instance method on the live filter and a module
  # method on the importer; build a bare live filter to reach the instance one.
  let(:live_filter) { StatusMonitor::MessageFilter.new([]) }

  describe 'similarity_scrub produces identical output in both scripts' do
    [
      'you have 42 gold',
      'you paid 10 Kronars',
      '5 kronars',
      '5 LIRUMS',
      '5 Dokoras',
      'no scrub targets here at all',
      '',
      'mixed 100 lirums and 3 dokoras 7',
      'digits123embedded456text',
      'Kronars lirums DOKORAS with no numbers',
    ].each do |input|
      it "normalizes #{input.inspect} the same way" do
        expect(live_filter.similarity_scrub(input.dup))
          .to eq(StatusMonitorImport.similarity_scrub(input.dup))
      end
    end
  end

  describe 'a kept live line and its logged form scrub to the same corpus key' do
    # Each raw line is one the live monitor keeps (no room-player/NPC/stream
    # filtering). The same line in a log is timestamp-prefixed; both paths must
    # reduce it to the same key or the import will not mark it as seen.
    [
      'A dragon breathes fire!',
      'You dodge <b>the flames</b>.',
      'The <pushBold/>guard<popBold/> nods at you.',
      'You gain 15 experience in Sorcery.',
      'She hands you 200 kronars and a note.',
      'Roundtime: 3 seconds.',
    ].each do |raw|
      it "aligns the key for #{raw.inspect}" do
        cleaned_live = live_filter.clean(raw.dup)
        expect(cleaned_live).not_to be_nil, "fixture line should be kept by live clean: #{raw.inspect}"
        live_key = live_filter.similarity_scrub(cleaned_live).strip

        log_line = "2026-01-04 18:59:20 NZDT: #{raw}"
        cleaned_import = StatusMonitorImport.clean_line(log_line.dup)
        expect(cleaned_import).not_to be_nil, "fixture line should be kept by import clean_line: #{raw.inspect}"
        import_key = StatusMonitorImport.similarity_scrub(cleaned_import).strip

        expect(import_key).to eq(live_key)
      end
    end
  end
end
