# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'ostruct'
require 'yaml'

# Test suite for dependency.lic (v4.2.0+)
#
# Covers the runtime helper functions that remain after all gated
# code was removed (core lich 5.18.0+ provides ArgParser, SetupFiles,
# ScriptManager, map overrides, and DR startup natively).
#
# verify_script now lives in core as DRC.verify_script; the dead
# reportbot/format helpers were removed in v4.1.0. v4.2.0 added
# obsolete-script detection (DR_OBSOLETE_SCRIPTS / warn_obsolete_scripts).

# Stub constants and globals before loading methods
SCRIPT_DIR = Dir.mktmpdir('dr-scripts-test') unless defined?(SCRIPT_DIR)
LICH_DIR = Dir.mktmpdir('lich-test') unless defined?(LICH_DIR)

$clean_lich_char = ';'

# --- Extract methods from dependency.lic ---
dep_path = File.join(File.dirname(__FILE__), '..', 'dependency.lic')
dep_lines = File.readlines(dep_path)

DEP_SOURCE = File.read(dep_path)

def extract_method(lines, path, method_name)
  start = lines.index { |l| l =~ /^\s*def #{Regexp.escape(method_name)}[\s(]?/ }
  raise "Could not find def #{method_name} in #{path}" unless start

  indent = lines[start][/^(\s*)/, 1]
  end_offset = lines[start + 1..].index { |l| l =~ /^#{indent}end\s*$/ }
  raise "Could not find matching end for #{method_name}" unless end_offset

  source = lines[start..start + 1 + end_offset].map { |l| l.sub(/^#{indent}/, '') }.join
  eval(source, TOPLEVEL_BINDING, path, start + 1)
end

%w[
  save_bankbot_transaction
  load_bankbot_ledger
  register_slackbot
  send_slackbot_message
  shift_hometown
  clear_hometown
  obsolete_script_dirs
  warn_obsolete_scripts
].each { |fn| extract_method(dep_lines, dep_path, fn) }

# Extract the frozen DR_OBSOLETE_SCRIPTS constant (assignment line through the
# terminating ".freeze"); extract_method only handles def bodies.
obsolete_const_start = dep_lines.index { |l| l =~ /^DR_OBSOLETE_SCRIPTS\s*=/ }
raise 'Could not find DR_OBSOLETE_SCRIPTS in dependency.lic' unless obsolete_const_start

obsolete_const_offset = dep_lines[obsolete_const_start..].index { |l| l =~ /\.freeze\s*$/ }
raise 'Could not find .freeze terminating DR_OBSOLETE_SCRIPTS' unless obsolete_const_offset

eval(
  dep_lines[obsolete_const_start..obsolete_const_start + obsolete_const_offset].join,
  TOPLEVEL_BINDING, dep_path, obsolete_const_start + 1
)

# --- Bankbot ---

RSpec.describe 'Bankbot Functions' do
  let(:ledger_path) { File.join(LICH_DIR, 'Testchar-ledger.yaml') }
  let(:transaction_log_path) { File.join(LICH_DIR, 'Testchar-transactions.log') }

  after do
    File.delete(ledger_path) if File.exist?(ledger_path)
    File.delete(transaction_log_path) if File.exist?(transaction_log_path)
  end

  describe '#save_bankbot_transaction' do
    let(:ledger) { { 'Testchar' => { 'kronars' => 500, 'lirums' => 200 } } }
    let(:transaction) { 'Testchar, deposit, 100, kronars, tip' }

    it 'writes the transaction to the log file' do
      save_bankbot_transaction(transaction, ledger)

      log_content = File.read(transaction_log_path)
      expect(log_content).to include(transaction)
      expect(log_content).to include('----------')
    end

    it 'writes the ledger to the YAML file' do
      save_bankbot_transaction(transaction, ledger)

      saved_ledger = YAML.unsafe_load_file(ledger_path)
      expect(saved_ledger['Testchar']['kronars']).to eq(500)
      expect(saved_ledger['Testchar']['lirums']).to eq(200)
    end

    it 'appends to the transaction log on successive calls' do
      save_bankbot_transaction('first transaction', ledger)
      save_bankbot_transaction('second transaction', ledger)

      log_content = File.read(transaction_log_path)
      expect(log_content).to include('first transaction')
      expect(log_content).to include('second transaction')
    end
  end

  describe '#load_bankbot_ledger' do
    context 'when the ledger file exists' do
      before do
        ledger_data = { 'Testchar' => { 'kronars' => 1000 } }
        File.open(ledger_path, 'w') { |f| f.puts(ledger_data.to_yaml) }
      end

      it 'returns the ledger as a hash' do
        result = load_bankbot_ledger
        expect(result).to be_a(Hash)
        expect(result[:Testchar]['kronars']).to eq(1000)
      end
    end

    context 'when the ledger file does not exist' do
      it 'returns an empty hash' do
        result = load_bankbot_ledger
        expect(result).to eq({})
      end
    end
  end
end

# --- Slackbot ---

RSpec.describe 'Slackbot Functions' do
  before do
    $slackbot_instance = nil
    $slackbot_username = nil
  end

  describe '#register_slackbot' do
    before do
      stub_const('Lich::DragonRealms::SlackBot', Class.new {
        define_method(:initialize) {}
        define_method(:direct_message) { |_user, _msg| }
      })
    end

    context 'with a valid username' do
      it 'sets the global slackbot instance' do
        register_slackbot('myuser')
        expect($slackbot_instance).not_to be_nil
      end

      it 'stores the username' do
        register_slackbot('myuser')
        expect($slackbot_username).to eq('myuser')
      end
    end

    context 'with nil username' do
      it 'does not create a slackbot instance' do
        register_slackbot(nil)
        expect($slackbot_instance).to be_nil
      end
    end

    context 'with blank username' do
      it 'does not create a slackbot instance' do
        register_slackbot('  ')
        expect($slackbot_instance).to be_nil
      end
    end

    context 'when already registered' do
      it 'does not replace the existing instance' do
        register_slackbot('first_user')
        original = $slackbot_instance
        register_slackbot('second_user')
        expect($slackbot_instance).to equal(original)
        expect($slackbot_username).to eq('first_user')
      end
    end
  end

  describe '#send_slackbot_message' do
    context 'when slackbot is not registered' do
      it 'does nothing' do
        expect { send_slackbot_message('hello') }.not_to raise_error
      end
    end

    context 'with nil message' do
      it 'returns early' do
        expect { send_slackbot_message(nil) }.not_to raise_error
      end
    end

    context 'when slackbot is registered' do
      let(:mock_slackbot) { instance_double('Lich::DragonRealms::SlackBot') }

      before do
        $slackbot_instance = mock_slackbot
        $slackbot_username = 'testuser'
      end

      it 'sends the message via the slackbot instance' do
        expect(mock_slackbot).to receive(:direct_message).with('testuser', 'hello world')
        send_slackbot_message('hello world')
      end
    end
  end
end

# --- Utility helpers ---

RSpec.describe 'Utility Functions' do
  describe '#shift_hometown' do
    after { $HOMETOWN = nil }

    it 'sets the $HOMETOWN global' do
      shift_hometown('Shard')
      expect($HOMETOWN).to eq('Shard')
    end
  end

  describe '#clear_hometown' do
    it 'clears the $HOMETOWN global' do
      $HOMETOWN = 'Shard'
      clear_hometown
      expect($HOMETOWN).to be_nil
    end
  end
end

# --- Version and structure ---

RSpec.describe 'Dependency Structure' do
  describe 'version' do
    it 'declares version 4.2.0' do
      expect(DEP_SOURCE).to include("$DEPENDENCY_VERSION = '4.2.0'")
    end

    it 'requires minimum lich version 5.18.0' do
      expect(DEP_SOURCE).to include("$MIN_LICH_VERSION = '5.18.0'")
    end
  end

  describe 'removed gated code' do
    it 'does not contain any sentinel gate blocks' do
      expect(DEP_SOURCE).not_to include('const_defined?')
    end

    it 'does not define ArgParser class' do
      expect(DEP_SOURCE).not_to include('class ArgParser')
    end

    it 'does not define SetupFiles class' do
      expect(DEP_SOURCE).not_to include('class SetupFiles')
    end

    it 'does not define ScriptManager class' do
      expect(DEP_SOURCE).not_to include('class ScriptManager')
    end

    it 'does not reference $manager' do
      expect(DEP_SOURCE).not_to include('$manager')
    end

    it 'does not reference $setupfiles' do
      expect(DEP_SOURCE).not_to include('$setupfiles')
    end
  end

  describe 'runtime helpers are present' do
    %w[
      save_bankbot_transaction
      load_bankbot_ledger
      send_slackbot_message
      register_slackbot
      shift_hometown
      clear_hometown
    ].each do |fn_name|
      it "defines #{fn_name}" do
        expect(DEP_SOURCE).to match(/^def #{Regexp.escape(fn_name)}[\s(]/)
      end
    end
  end

  describe 'removed helpers are absent' do
    %w[
      save_reportbot_whitelist
      load_reportbot_whitelist
      format_name
      format_yaml_name
      verify_script
    ].each do |fn_name|
      it "does not define #{fn_name}" do
        expect(DEP_SOURCE).not_to match(/^def #{Regexp.escape(fn_name)}[\s(]/)
      end
    end
  end
end

# --- Obsolete script detection (v4.2.0) ---
#
# dependency.lic warns at startup about scripts superseded by native core lich
# functionality (DR_OBSOLETE_SCRIPTS) so a lingering copy on disk can be found
# and deleted before it duplicates work core lich now performs. roomnumbers.lic
# is the first such script. SCRIPT_DIR (from the harness above) is a real temp
# directory, so File.file? checks exercise the actual filesystem.

RSpec.describe 'Obsolete Script Detection' do
  let(:main_dir) { SCRIPT_DIR }
  let(:custom_dir) { File.join(SCRIPT_DIR, 'custom') }

  # Create a real file so File.file? checks have something to find.
  def write_script(dir, filename)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, filename)
    File.write(path, "# placeholder for testing\n")
    path
  end

  before do
    $respond_messages = []
    # Start each example from a clean SCRIPT_DIR (this includes custom/).
    FileUtils.rm_rf(Dir.glob(File.join(SCRIPT_DIR, '*')))
  end

  describe 'the DR_OBSOLETE_SCRIPTS constant' do
    it 'lists roomnumbers as an obsolete script' do
      expect(DR_OBSOLETE_SCRIPTS).to include('roomnumbers')
    end

    it 'is frozen so it cannot be mutated at runtime' do
      expect(DR_OBSOLETE_SCRIPTS).to be_frozen
    end

    it 'stores base names with no .lic extension' do
      expect(DR_OBSOLETE_SCRIPTS).to all(satisfy { |name| !name.include?('.lic') })
    end
  end

  describe '#obsolete_script_dirs' do
    it 'searches the custom directory before the main script directory' do
      expect(obsolete_script_dirs).to eq([custom_dir, main_dir])
    end
  end

  describe '#warn_obsolete_scripts' do
    context 'when no obsolete script exists on disk' do
      it 'returns an empty array' do
        expect(warn_obsolete_scripts).to eq([])
      end

      it 'emits no warnings' do
        warn_obsolete_scripts
        expect($respond_messages).to be_empty
      end
    end

    context 'when an obsolete script lingers in the main script directory' do
      before { write_script(main_dir, 'roomnumbers.lic') }

      it 'returns the offending script name' do
        expect(warn_obsolete_scripts).to eq(['roomnumbers'])
      end

      it 'warns that the file is obsolete and should be deleted' do
        warn_obsolete_scripts
        expect($respond_messages.first).to include("'roomnumbers.lic' is obsolete")
      end

      it 'names the main script directory in the warning' do
        warn_obsolete_scripts
        expect($respond_messages.first).to include(main_dir)
      end
    end

    context 'when an obsolete script lingers only in the custom directory' do
      before { write_script(custom_dir, 'roomnumbers.lic') }

      it 'still detects and returns it' do
        expect(warn_obsolete_scripts).to eq(['roomnumbers'])
      end

      it 'names the custom directory in the warning' do
        warn_obsolete_scripts
        expect($respond_messages.first).to include(custom_dir)
      end
    end

    context 'when an obsolete script exists in both the custom and main directories' do
      before do
        write_script(custom_dir, 'roomnumbers.lic')
        write_script(main_dir, 'roomnumbers.lic')
      end

      it 'reports the script only once' do
        warn_obsolete_scripts
        expect($respond_messages.length).to eq(1)
      end

      it 'reports the higher-priority custom directory' do
        warn_obsolete_scripts
        expect($respond_messages.first).to include(custom_dir)
      end
    end

    context 'when a non-obsolete script shares the directory' do
      before { write_script(main_dir, 'combat-trainer.lic') }

      it 'ignores it and returns an empty array' do
        expect(warn_obsolete_scripts).to eq([])
      end

      it 'emits no warnings' do
        warn_obsolete_scripts
        expect($respond_messages).to be_empty
      end
    end

    context 'with an explicitly injected obsolete list' do
      before { write_script(main_dir, 'legacy-thing.lic') }

      it 'checks the provided names instead of the default constant' do
        expect(warn_obsolete_scripts(['legacy-thing'])).to eq(['legacy-thing'])
      end

      it 'does not mutate the frozen default constant' do
        warn_obsolete_scripts(['legacy-thing'])
        expect(DR_OBSOLETE_SCRIPTS).to eq(['roomnumbers'])
      end
    end

    describe 'adversarial inputs' do
      it 'returns an empty array for an empty obsolete list' do
        write_script(main_dir, 'roomnumbers.lic')
        expect(warn_obsolete_scripts([])).to eq([])
      end

      it 'does not match a file whose name lacks the .lic extension' do
        write_script(main_dir, 'roomnumbers') # no extension
        expect(warn_obsolete_scripts).to eq([])
      end

      it 'does not match a directory that shares the script name' do
        FileUtils.mkdir_p(File.join(main_dir, 'roomnumbers.lic'))
        expect(warn_obsolete_scripts).to eq([])
      end

      it 'does not raise when the custom directory is absent' do
        FileUtils.rm_rf(custom_dir)
        expect { warn_obsolete_scripts }.not_to raise_error
      end

      it 'does not warn for a script whose name is only a substring of a present file' do
        write_script(main_dir, 'roomnumbers-extra.lic')
        expect(warn_obsolete_scripts).to eq([])
      end
    end
  end
end
