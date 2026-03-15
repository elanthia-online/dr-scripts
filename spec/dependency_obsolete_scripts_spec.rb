# frozen_string_literal: true

require 'tmpdir'

# Test suite for dependency.lic obsolete script detection
#
# Tests DR_OBSOLETE_SCRIPTS, dr_obsolete_script?, and warn_obsolete_scripts
# using minimal mocks to avoid the full Lich runtime.

# Stub SCRIPT_DIR, _respond, and Lich::Messaging before loading the methods
SCRIPT_DIR = Dir.mktmpdir('dr-scripts-test') unless defined?(SCRIPT_DIR)

module Lich
  module Messaging
    def self.monsterbold(msg)
      msg
    end
  end
end

# Capture _respond calls for assertion
$respond_messages = []
def _respond(msg)
  $respond_messages << msg
end

# Stub Script.current for dr_obsolete_script?
module Script
  def self.current
    OpenStruct.new(name: 'test-script')
  end
end

# Extract the constant and methods from dependency.lic
# We eval only the relevant section to avoid all Lich runtime dependencies.
dep_path = File.join(File.dirname(__FILE__), '..', 'dependency.lic')
dep_lines = File.readlines(dep_path)

# Extract DR_OBSOLETE_SCRIPTS constant
obs_start = dep_lines.index { |l| l =~ /^DR_OBSOLETE_SCRIPTS\s*=/ }
obs_end = dep_lines[obs_start..].index { |l| l =~ /\.freeze$/ }
eval(dep_lines[obs_start..obs_start + obs_end].join, TOPLEVEL_BINDING, dep_path, obs_start + 1)

# Extract dr_obsolete_script? method
fn_start = dep_lines.index { |l| l =~ /^def dr_obsolete_script\?/ }
fn_end = dep_lines[fn_start + 1..].index { |l| l =~ /^end\s*$/ }
eval(dep_lines[fn_start..fn_start + 1 + fn_end].join, TOPLEVEL_BINDING, dep_path, fn_start + 1)

# Extract warn_obsolete_scripts method
wn_start = dep_lines.index { |l| l =~ /^def warn_obsolete_scripts/ }
wn_end = dep_lines[wn_start + 1..].index { |l| l =~ /^end\s*$/ }
eval(dep_lines[wn_start..wn_start + 1 + wn_end].join, TOPLEVEL_BINDING, dep_path, wn_start + 1)

RSpec.describe 'Obsolete Scripts' do
  before { $respond_messages.clear }

  describe 'DR_OBSOLETE_SCRIPTS' do
    it 'includes exp-monitor' do
      expect(DR_OBSOLETE_SCRIPTS).to include('exp-monitor')
    end

    it 'includes previously obsoleted scripts' do
      %w[events slackbot spellmonitor].each do |script|
        expect(DR_OBSOLETE_SCRIPTS).to include(script)
      end
    end

    it 'is frozen' do
      expect(DR_OBSOLETE_SCRIPTS).to be_frozen
    end
  end

  describe '#dr_obsolete_script?' do
    context 'with a non-obsolete script' do
      it 'returns false without warnings' do
        expect(dr_obsolete_script?('hunting-buddy')).to be false
        expect($respond_messages).to be_empty
      end
    end

    context 'with an obsolete script name' do
      it 'returns false (allows caller to decide behavior)' do
        expect(dr_obsolete_script?('exp-monitor')).to be false
      end

      it 'warns about the calling script referencing an obsolete script' do
        dr_obsolete_script?('exp-monitor')
        expect($respond_messages.last).to include('exp-monitor')
        expect($respond_messages.last).to include('references obsolete script')
      end
    end

    context 'when the .lic suffix is included' do
      it 'strips the suffix and still detects obsolete scripts' do
        dr_obsolete_script?('exp-monitor.lic')
        expect($respond_messages).not_to be_empty
      end
    end

    context 'when the obsolete script file exists locally' do
      around do |example|
        path = File.join(SCRIPT_DIR, 'exp-monitor.lic')
        File.write(path, '# obsolete')
        example.run
      ensure
        File.delete(path) if File.exist?(path)
      end

      it 'warns user to delete the file' do
        dr_obsolete_script?('exp-monitor')
        expect($respond_messages.first).to include('should be deleted')
      end
    end

    context 'when the obsolete script file exists in custom/' do
      around do |example|
        custom_dir = File.join(SCRIPT_DIR, 'custom')
        FileUtils.mkdir_p(custom_dir)
        path = File.join(custom_dir, 'exp-monitor.lic')
        File.write(path, '# obsolete')
        example.run
      ensure
        File.delete(path) if File.exist?(path)
        FileUtils.rm_rf(custom_dir)
      end

      it 'warns user to delete from scripts/custom' do
        dr_obsolete_script?('exp-monitor')
        expect($respond_messages.first).to include('scripts/custom')
      end
    end
  end

  describe '#warn_obsolete_scripts' do
    context 'when no obsolete script files exist' do
      it 'produces no warnings' do
        warn_obsolete_scripts
        expect($respond_messages).to be_empty
      end
    end

    context 'when an obsolete script file exists in SCRIPT_DIR' do
      around do |example|
        path = File.join(SCRIPT_DIR, 'exp-monitor.lic')
        File.write(path, '# obsolete')
        example.run
      ensure
        File.delete(path) if File.exist?(path)
      end

      it 'warns about the obsolete file' do
        warn_obsolete_scripts
        warning = $respond_messages.find { |m| m.include?('exp-monitor') }
        expect(warning).to include('obsolete')
        expect(warning).to include('should be deleted')
      end
    end
  end
end
