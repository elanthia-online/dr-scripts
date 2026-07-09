# frozen_string_literal: true

# T2 spec suite.
#
# Focused on shutdown cleanup: T2 must stop only the scripts it launched
# itself, must honor the t2_no_kill opt-out list, and must never kill a
# script the operator started independently.
#
# Tests are split per method:
#   - Validation: expected behavior for known-good inputs
#   - Bug-finding: nil/empty/typed settings, case-sensitivity of the ALL
#     keyword, running-vs-stopped state, and repeated (idempotent) calls

require 'ostruct'

load File.join(File.dirname(__FILE__), '..', 'test', 'test_harness.rb')
include Harness

def load_lic_class(filename, class_name)
  return if Object.const_defined?(class_name)

  filepath = File.join(File.dirname(__FILE__), '..', filename)
  lines = File.readlines(filepath)

  start_idx = lines.index { |l| l =~ /^class\s+#{class_name}\b/ }
  raise "Could not find 'class #{class_name}' in #{filename}" unless start_idx

  end_idx = nil
  (start_idx + 1...lines.size).each do |i|
    if lines[i] =~ /^end\s*$/
      end_idx = i
      break
    end
  end
  raise "Could not find matching end for 'class #{class_name}' in #{filename}" unless end_idx

  class_source = lines[start_idx..end_idx].join
  eval(class_source, TOPLEVEL_BINDING, filepath, start_idx + 1)
end

# -- Module/method stubs --
# T2's cleanup path calls Script.running? and the top-level stop_script.
# Both default to safe values; individual tests override via allow().

module Script
  # Default to "running" so #stop_launched_scripts attempts a kill unless a
  # test says otherwise. This makes the "spares"/"stops" assertions meaningful.
  def self.running?(*_args) = true
end

# Top-level Lich global. Defined so it can be stubbed on a specific instance.
def stop_script(*_args) = nil

load_lic_class('t2.lic', 'T2')

# Builds a T2 without running the (Lich-dependent) initializer.
#
# @param no_kill [Object] value for the t2_no_kill setting (nil, String, Array, ...)
# @param launched [Array<String>] scripts T2 is treated as having launched
# @return [T2]
def build_t2(no_kill: nil, launched: [])
  t2 = T2.allocate
  t2.instance_variable_set(:@settings, OpenStruct.new(t2_no_kill: no_kill))
  t2.instance_variable_set(:@launched_scripts, launched)
  t2
end

# ===================================================================
# T2#scripts_to_spare -- normalizes the t2_no_kill setting to an array
# ===================================================================
RSpec.describe 'T2#scripts_to_spare' do
  it 'returns an empty array when t2_no_kill is unset (nil)' do
    expect(build_t2(no_kill: nil).scripts_to_spare).to eq([])
  end

  it 'wraps a bare string value into a single-element array' do
    expect(build_t2(no_kill: 'magic').scripts_to_spare).to eq(['magic'])
  end

  it 'passes a list value through unchanged' do
    expect(build_t2(no_kill: %w[magic pick]).scripts_to_spare).to eq(%w[magic pick])
  end

  it 'wraps the bare ALL keyword into a single-element array' do
    expect(build_t2(no_kill: 'ALL').scripts_to_spare).to eq(['ALL'])
  end

  it 'returns an empty array for an explicitly empty list' do
    expect(build_t2(no_kill: []).scripts_to_spare).to eq([])
  end
end

# ===================================================================
# T2#spare_all_scripts? -- detects the case-sensitive ALL keyword
# ===================================================================
RSpec.describe 'T2#spare_all_scripts?' do
  it 'is false when t2_no_kill is unset' do
    expect(build_t2(no_kill: nil).spare_all_scripts?).to be false
  end

  it 'is true for the bare ALL keyword' do
    expect(build_t2(no_kill: 'ALL').spare_all_scripts?).to be true
  end

  it 'is true when ALL appears in a list alongside other names' do
    expect(build_t2(no_kill: %w[magic ALL]).spare_all_scripts?).to be true
  end

  it 'is false for a normal script name' do
    expect(build_t2(no_kill: 'magic').spare_all_scripts?).to be false
  end

  # BUG-FINDING: ALL is a reserved keyword only in exact upper case. A script
  # literally named "all" must be treated as a normal name, not a wildcard.
  it 'is false for lowercase "all" (keyword is case-sensitive)' do
    expect(build_t2(no_kill: 'all').spare_all_scripts?).to be false
  end

  # BUG-FINDING: mixed-case variants must not trip the wildcard either.
  it 'is false for mixed-case "All"' do
    expect(build_t2(no_kill: 'All').spare_all_scripts?).to be false
  end
end

# ===================================================================
# T2#stop_launched_scripts -- the shutdown cleanup behavior
# ===================================================================
RSpec.describe 'T2#stop_launched_scripts' do
  # Wire a fresh instance whose stop_script calls are recorded.
  def build_and_watch(no_kill: nil, launched: [])
    t2 = build_t2(no_kill: no_kill, launched: launched)
    allow(t2).to receive(:stop_script)
    t2
  end

  context 'with no opt-out configured' do
    it 'stops every script it launched' do
      t2 = build_and_watch(launched: %w[magic pick foragetask])
      t2.stop_launched_scripts
      expect(t2).to have_received(:stop_script).with('magic')
      expect(t2).to have_received(:stop_script).with('pick')
      expect(t2).to have_received(:stop_script).with('foragetask')
    end

    it 'launches nothing to kill when it launched nothing' do
      t2 = build_and_watch(launched: [])
      t2.stop_launched_scripts
      expect(t2).not_to have_received(:stop_script)
    end

    # BUG-FINDING: a stale entry that is no longer running must be skipped,
    # not killed (stop_script on a dead script is pointless and noisy).
    it 'skips launched scripts that are no longer running' do
      t2 = build_and_watch(launched: %w[magic pick])
      allow(Script).to receive(:running?).with('magic').and_return(true)
      allow(Script).to receive(:running?).with('pick').and_return(false)
      t2.stop_launched_scripts
      expect(t2).to have_received(:stop_script).with('magic')
      expect(t2).not_to have_received(:stop_script).with('pick')
    end
  end

  context 'with a t2_no_kill list' do
    it 'spares listed scripts and stops the rest' do
      t2 = build_and_watch(no_kill: ['magic'], launched: %w[magic pick])
      t2.stop_launched_scripts
      expect(t2).not_to have_received(:stop_script).with('magic')
      expect(t2).to have_received(:stop_script).with('pick')
    end

    it 'spares multiple listed scripts' do
      t2 = build_and_watch(no_kill: %w[magic pick], launched: %w[magic pick foragetask])
      t2.stop_launched_scripts
      expect(t2).not_to have_received(:stop_script).with('magic')
      expect(t2).not_to have_received(:stop_script).with('pick')
      expect(t2).to have_received(:stop_script).with('foragetask')
    end

    # BUG-FINDING: a spare-list entry for a script T2 never launched is a
    # harmless no-op and must not raise or affect other scripts.
    it 'ignores spare-list entries for scripts it never launched' do
      t2 = build_and_watch(no_kill: %w[hunting-buddy], launched: %w[magic])
      expect { t2.stop_launched_scripts }.not_to raise_error
      expect(t2).to have_received(:stop_script).with('magic')
    end
  end

  context 'with the ALL keyword' do
    it 'stops nothing when t2_no_kill is exactly ALL' do
      t2 = build_and_watch(no_kill: 'ALL', launched: %w[magic pick])
      t2.stop_launched_scripts
      expect(t2).not_to have_received(:stop_script)
    end

    it 'stops nothing when ALL appears anywhere in the list' do
      t2 = build_and_watch(no_kill: %w[magic ALL], launched: %w[magic pick])
      t2.stop_launched_scripts
      expect(t2).not_to have_received(:stop_script)
    end

    # BUG-FINDING: lowercase "all" is a real script name, not the wildcard,
    # so everything (including a script named "all") should still be stopped.
    it 'treats lowercase "all" as a normal name and still stops scripts' do
      t2 = build_and_watch(no_kill: 'all', launched: %w[magic all])
      t2.stop_launched_scripts
      expect(t2).to have_received(:stop_script).with('magic')
    end
  end

  context 'adversarial setting shapes' do
    # BUG-FINDING: a mistyped scalar (number/hash) must not crash cleanup;
    # it simply matches no script names, so everything is stopped.
    it 'does not crash on a numeric t2_no_kill and still stops scripts' do
      t2 = build_and_watch(no_kill: 5, launched: %w[magic])
      expect { t2.stop_launched_scripts }.not_to raise_error
      expect(t2).to have_received(:stop_script).with('magic')
    end

    it 'does not crash when t2_no_kill is unset and nothing was launched' do
      t2 = build_and_watch(no_kill: nil, launched: [])
      expect { t2.stop_launched_scripts }.not_to raise_error
    end
  end

  context 'called more than once (idempotency)' do
    # BUG-FINDING: cleanup may run more than once; once a script has stopped,
    # Script.running? goes false and the second pass must not re-kill it.
    it 'does not re-stop a script that stopped after the first pass' do
      t2 = build_and_watch(launched: %w[magic])
      running = true
      allow(Script).to receive(:running?).with('magic') { running }

      t2.stop_launched_scripts
      running = false
      t2.stop_launched_scripts

      expect(t2).to have_received(:stop_script).with('magic').once
    end
  end
end
