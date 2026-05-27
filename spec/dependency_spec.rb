# frozen_string_literal: true

require 'tmpdir'
require 'ostruct'
require 'yaml'

# Test suite for dependency.lic (v4.0.0+)
#
# Covers the runtime helper functions that remain after all gated
# code was removed (core lich 5.17.2+ provides ArgParser, SetupFiles,
# ScriptManager, map overrides, and DR startup natively).

# Stub constants and globals before loading methods
SCRIPT_DIR = Dir.mktmpdir('dr-scripts-test') unless defined?(SCRIPT_DIR)
LICH_DIR = Dir.mktmpdir('lich-test') unless defined?(LICH_DIR)

module Lich
  module Messaging
    def self.monsterbold(msg)
      msg
    end
  end
end

$respond_messages = []
def _respond(msg)
  $respond_messages << msg
end

module Script
  def self.current
    OpenStruct.new(name: 'test-script')
  end

  def self.exists?(_name)
    false
  end
end

$clean_lich_char = ';'

def checkname
  'Testchar'
end

def echo(_msg)
  # no-op in tests
end

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
  save_reportbot_whitelist
  load_reportbot_whitelist
  register_slackbot
  send_slackbot_message
  format_name
  format_yaml_name
  verify_script
  shift_hometown
  clear_hometown
].each { |fn| extract_method(dep_lines, dep_path, fn) }

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

# --- Reportbot ---

RSpec.describe 'Reportbot Functions' do
  let(:whitelist_path) { File.join(LICH_DIR, 'reportbot-whitelist.yaml') }

  after do
    File.delete(whitelist_path) if File.exist?(whitelist_path)
  end

  describe '#save_reportbot_whitelist' do
    it 'writes the whitelist to YAML' do
      whitelist = %w[Player1 Player2 Player3]
      save_reportbot_whitelist(whitelist)

      saved = YAML.unsafe_load_file(whitelist_path)
      expect(saved).to eq(whitelist)
    end
  end

  describe '#load_reportbot_whitelist' do
    context 'when the whitelist file exists' do
      before do
        File.open(whitelist_path, 'w') { |f| f.puts(%w[Alpha Beta].to_yaml) }
      end

      it 'returns the whitelist as an array' do
        result = load_reportbot_whitelist
        expect(result).to eq(%w[Alpha Beta])
      end
    end

    context 'when the whitelist file does not exist' do
      it 'returns an empty array' do
        result = load_reportbot_whitelist
        expect(result).to eq([])
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
      stub_const('SlackBot', Class.new {
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
      let(:mock_slackbot) { instance_double('SlackBot') }

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
  describe '#format_name' do
    it 'appends .lic if missing' do
      expect(format_name('dependency')).to eq('dependency.lic')
    end

    it 'does not double-append .lic' do
      expect(format_name('dependency.lic')).to eq('dependency.lic')
    end
  end

  describe '#format_yaml_name' do
    it 'appends .yaml if missing' do
      expect(format_yaml_name('base-spells')).to eq('base-spells.yaml')
    end

    it 'does not double-append .yaml' do
      expect(format_yaml_name('base-spells.yaml')).to eq('base-spells.yaml')
    end
  end

  describe '#verify_script' do
    it 'returns false when script does not exist' do
      expect(verify_script('nonexistent-script')).to be false
    end

    it 'accepts an array of script names' do
      expect(verify_script(%w[nonexistent1 nonexistent2])).to be false
    end
  end

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
    it 'declares version 4.0.0' do
      expect(DEP_SOURCE).to include("$DEPENDENCY_VERSION = '4.0.0'")
    end

    it 'requires minimum lich version 5.17.2' do
      expect(DEP_SOURCE).to include("$MIN_LICH_VERSION = '5.17.2'")
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
      save_reportbot_whitelist
      load_reportbot_whitelist
      send_slackbot_message
      register_slackbot
      format_name
      format_yaml_name
      verify_script
      shift_hometown
      clear_hometown
    ].each do |fn_name|
      it "defines #{fn_name}" do
        expect(DEP_SOURCE).to match(/^def #{Regexp.escape(fn_name)}[\s(]/)
      end
    end
  end
end
