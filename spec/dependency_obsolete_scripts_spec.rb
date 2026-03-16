# frozen_string_literal: true

require 'tmpdir'
require 'ostruct'

# Test suite for dependency.lic obsolete script detection
#
# Tests DR_OBSOLETE_SCRIPTS, dr_obsolete_script?, warn_obsolete_scripts,
# and handle_obsolete_autostart using minimal mocks to avoid the full
# Lich runtime.

# Stub SCRIPT_DIR, _respond, respond, and Lich::Messaging before loading methods
SCRIPT_DIR = Dir.mktmpdir('dr-scripts-test') unless defined?(SCRIPT_DIR)

module Lich
  module Messaging
    def self.monsterbold(msg)
      msg
    end
  end
end

# Capture _respond and respond calls for assertion
$respond_messages = []
def _respond(msg)
  $respond_messages << msg
end

def respond(msg)
  $respond_messages << msg
end

# Stub Script.current for dr_obsolete_script?
module Script
  def self.current
    OpenStruct.new(name: 'test-script')
  end
end

$clean_lich_char = ';'

# Mock UserVars with a mutable autostart_scripts array
module UserVars
  class << self
    attr_accessor :autostart_scripts
  end
  self.autostart_scripts = []
end unless defined?(UserVars)

# Mock Settings as a hash-like store
module Settings
  @store = { 'autostart' => [] }

  def self.[](key)
    @store[key]
  end

  def self.[]=(key, value)
    @store[key] = value
  end

  def self.reset!
    @store = { 'autostart' => [] }
  end
end unless defined?(Settings)

# Mock $manager for remove_global_auto tracking
class MockManager
  attr_reader :removed

  def initialize
    @removed = []
  end

  def remove_global_auto(script)
    @removed << script
  end
end

# --- Extract the constant and methods from dependency.lic ---
# We eval only the relevant sections to avoid all Lich runtime dependencies.
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

# Extract handle_obsolete_autostart method
ha_start = dep_lines.index { |l| l =~ /^def handle_obsolete_autostart/ }
ha_end = dep_lines[ha_start + 1..].index { |l| l =~ /^end\s*$/ }
eval(dep_lines[ha_start..ha_start + 1 + ha_end].join, TOPLEVEL_BINDING, dep_path, ha_start + 1)

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

  describe '#handle_obsolete_autostart' do
    let(:manager) { MockManager.new }

    before do
      UserVars.autostart_scripts = []
      Settings.reset!
      $manager = manager
    end

    shared_examples 'skips the script' do
      it 'returns true' do
        expect(handle_obsolete_autostart(script_name)).to be true
      end

      it 'announces the script is obsolete' do
        handle_obsolete_autostart(script_name)
        expect($respond_messages).to include(match(/obsolete and no longer needed/))
      end

      it 'wraps output in delimiters' do
        handle_obsolete_autostart(script_name)
        expect($respond_messages.first).to eq("\n---")
        expect($respond_messages.last).to eq("---\n")
      end
    end

    context 'with a non-obsolete script' do
      it 'returns false' do
        expect(handle_obsolete_autostart('crossing-training')).to be false
      end

      it 'produces no messages' do
        handle_obsolete_autostart('crossing-training')
        expect($respond_messages).to be_empty
      end

      it 'does not modify UserVars' do
        UserVars.autostart_scripts = ['crossing-training']
        handle_obsolete_autostart('crossing-training')
        expect(UserVars.autostart_scripts).to eq(['crossing-training'])
      end

      it 'does not queue global removal' do
        handle_obsolete_autostart('crossing-training')
        expect(manager.removed).to be_empty
      end
    end

    context 'when script is in character autostarts' do
      let(:script_name) { 'exp-monitor' }

      before { UserVars.autostart_scripts = ['exp-monitor', 'hunting-buddy'] }

      include_examples 'skips the script'

      it 'mentions character autostarts' do
        handle_obsolete_autostart(script_name)
        expect($respond_messages).to include(match(/character autostarts/))
      end

      it 'removes from UserVars.autostart_scripts' do
        handle_obsolete_autostart(script_name)
        expect(UserVars.autostart_scripts).to eq(['hunting-buddy'])
      end

      it 'includes the manual removal command' do
        handle_obsolete_autostart(script_name)
        expect($respond_messages).to include(match(/;e stop_autostart\('exp-monitor'\)/))
      end

      it 'does not mention YAML profile' do
        handle_obsolete_autostart(script_name)
        expect($respond_messages.join).not_to include('YAML profile')
      end

      it 'does not queue global removal' do
        handle_obsolete_autostart(script_name)
        expect(manager.removed).to be_empty
      end
    end

    context 'when script is in global autostarts' do
      let(:script_name) { 'drinfomon' }

      before { Settings['autostart'] = ['drinfomon', 'other-script'] }

      include_examples 'skips the script'

      it 'mentions global autostarts' do
        handle_obsolete_autostart(script_name)
        expect($respond_messages).to include(match(/global autostarts/))
      end

      it 'queues removal via $manager.remove_global_auto' do
        handle_obsolete_autostart(script_name)
        expect(manager.removed).to eq(['drinfomon'])
      end

      it 'includes the manual removal command' do
        handle_obsolete_autostart(script_name)
        expect($respond_messages).to include(match(/;e stop_autostart\('drinfomon'\)/))
      end

      it 'does not modify UserVars.autostart_scripts' do
        handle_obsolete_autostart(script_name)
        expect(UserVars.autostart_scripts).to be_empty
      end

      it 'does not mention YAML profile' do
        handle_obsolete_autostart(script_name)
        expect($respond_messages.join).not_to include('YAML profile')
      end
    end

    context 'when script is in YAML profile autostarts only' do
      let(:script_name) { 'spellmonitor' }

      include_examples 'skips the script'

      it 'mentions YAML profile autostarts' do
        handle_obsolete_autostart(script_name)
        expect($respond_messages).to include(match(/YAML profile autostarts/))
      end

      it 'tells user to edit their YAML' do
        handle_obsolete_autostart(script_name)
        expect($respond_messages).to include(match(/remove 'spellmonitor' from the 'autostarts' setting/))
      end

      it 'does not modify UserVars.autostart_scripts' do
        handle_obsolete_autostart(script_name)
        expect(UserVars.autostart_scripts).to be_empty
      end

      it 'does not queue global removal' do
        handle_obsolete_autostart(script_name)
        expect(manager.removed).to be_empty
      end
    end

    context 'when script is in both character and global autostarts' do
      let(:script_name) { 'common' }

      before do
        UserVars.autostart_scripts = ['common']
        Settings['autostart'] = ['common']
      end

      include_examples 'skips the script'

      it 'removes from character autostarts' do
        handle_obsolete_autostart(script_name)
        expect(UserVars.autostart_scripts).not_to include('common')
      end

      it 'queues removal from global autostarts' do
        handle_obsolete_autostart(script_name)
        expect(manager.removed).to eq(['common'])
      end

      it 'mentions both sources' do
        handle_obsolete_autostart(script_name)
        messages = $respond_messages.join("\n")
        expect(messages).to include('character autostarts')
        expect(messages).to include('global autostarts')
      end

      it 'does not mention YAML profile' do
        handle_obsolete_autostart(script_name)
        expect($respond_messages.join).not_to include('YAML profile')
      end
    end

    context 'each obsolete script is recognized' do
      DR_OBSOLETE_SCRIPTS.each do |script_name|
        it "handles '#{script_name}'" do
          expect(handle_obsolete_autostart(script_name)).to be true
        end
      end
    end
  end
end
