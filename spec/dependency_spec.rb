# frozen_string_literal: true

require 'digest'
require 'tmpdir'
require 'ostruct'
require 'yaml'

# Test suite for dependency.lic
#
# Covers obsolete script detection, autostart handling, cascading includes,
# and inlined manager functions (bankbot, reportbot, slackbot).

# Stub SCRIPT_DIR, _respond, respond, and Lich::Messaging before loading methods
SCRIPT_DIR = Dir.mktmpdir('dr-scripts-test') unless defined?(SCRIPT_DIR)
LICH_DIR = Dir.mktmpdir('lich-test') unless defined?(LICH_DIR)

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

# Stub Script.current for dr_obsolete_script?
module Script
  def self.current
    OpenStruct.new(name: 'test-script')
  end
end

$clean_lich_char = ';'

def checkname
  'Testchar'
end

def echo(_msg)
  # no-op in tests
end

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

# --- Extract the constant and methods from dependency.lic ---
# We eval only the relevant sections to avoid all Lich runtime dependencies.
# Methods/constants may be at column 0 or indented inside sentinel gate blocks.
dep_path = File.join(File.dirname(__FILE__), '..', 'dependency.lic')
dep_lines = File.readlines(dep_path)

# Helper: extract a constant assignment (possibly indented) through .freeze
def extract_constant(lines, path, const_name)
  start = lines.index { |l| l =~ /^\s*#{Regexp.escape(const_name)}\s*=/ }
  raise "Could not find #{const_name} in #{path}" unless start

  freeze_offset = lines[start..].index { |l| l =~ /\.freeze$/ }
  raise "Could not find .freeze for #{const_name}" unless freeze_offset

  source = lines[start..start + freeze_offset].map(&:lstrip).join
  eval(source, TOPLEVEL_BINDING, path, start + 1)
end

# Helper: extract a method definition (possibly indented) through its matching end
def extract_method(lines, path, method_name)
  start = lines.index { |l| l =~ /^\s*def #{Regexp.escape(method_name)}[\s(]?/ }
  raise "Could not find def #{method_name} in #{path}" unless start

  indent = lines[start][/^(\s*)/, 1]
  end_offset = lines[start + 1..].index { |l| l =~ /^#{indent}end\s*$/ }
  raise "Could not find matching end for #{method_name}" unless end_offset

  source = lines[start..start + 1 + end_offset].map { |l| l.sub(/^#{indent}/, '') }.join
  eval(source, TOPLEVEL_BINDING, path, start + 1)
end

extract_constant(dep_lines, dep_path, 'DR_OBSOLETE_SCRIPTS')
extract_constant(dep_lines, dep_path, 'DR_OBSOLETE_DATA_FILES')

%w[
  dr_obsolete_script?
  warn_obsolete_scripts
  handle_obsolete_autostart
  stop_autostart
  save_bankbot_transaction
  load_bankbot_ledger
  save_reportbot_whitelist
  load_reportbot_whitelist
  register_slackbot
  send_slackbot_message
  warn_obsolete_data_files
].each { |fn| extract_method(dep_lines, dep_path, fn) }

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

  describe 'DR_OBSOLETE_DATA_FILES' do
    it 'is frozen' do
      expect(DR_OBSOLETE_DATA_FILES).to be_frozen
    end

    it 'is empty (no data files are currently obsolete)' do
      expect(DR_OBSOLETE_DATA_FILES).to be_empty
    end
  end

  describe '#warn_obsolete_data_files' do
    let(:data_dir) { File.join(SCRIPT_DIR, 'data') }

    before { FileUtils.mkdir_p(data_dir) }

    context 'when no obsolete data files exist' do
      it 'produces no warnings' do
        warn_obsolete_data_files
        expect($respond_messages).to be_empty
      end
    end
  end

  describe '#handle_obsolete_autostart' do
    before do
      UserVars.autostart_scripts = []
    end

    context 'with a non-obsolete script' do
      it 'returns false' do
        expect(handle_obsolete_autostart('crossing-training')).to be false
      end

      it 'produces no messages' do
        handle_obsolete_autostart('crossing-training')
        expect($respond_messages).to be_empty
      end
    end

    context 'when script is in UserVars autostarts' do
      before { UserVars.autostart_scripts = ['exp-monitor', 'hunting-buddy'] }

      it 'returns true' do
        expect(handle_obsolete_autostart('exp-monitor')).to be true
      end

      it 'removes from UserVars.autostart_scripts' do
        handle_obsolete_autostart('exp-monitor')
        expect(UserVars.autostart_scripts).to eq(['hunting-buddy'])
      end

      it 'warns about removal' do
        handle_obsolete_autostart('exp-monitor')
        expect($respond_messages.join).to include('Removing obsolete')
      end

      it 'includes the manual removal command' do
        handle_obsolete_autostart('exp-monitor')
        expect($respond_messages.join).to include("stop_autostart('exp-monitor')")
      end
    end

    context 'when script is in YAML profile autostarts only' do
      it 'returns true' do
        expect(handle_obsolete_autostart('spellmonitor')).to be true
      end

      it 'tells user to edit their YAML' do
        handle_obsolete_autostart('spellmonitor')
        expect($respond_messages.join).to include('profile YAML')
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

# --- Cascading Includes ---

# Minimal mock that replicates the resolve_includes_recursively behavior.
# Tests the core algorithm in isolation without SetupFiles's complex dependencies.
class IncludeResolver
  attr_reader :files, :loaded_files, :debug

  def initialize(files = {}, debug: false)
    @files = files
    @loaded_files = []
    @debug = debug
  end

  def reload_profiles(filenames)
    filenames.each { |f| @loaded_files << f unless @loaded_files.include?(f) }
  end

  def cache_get_by_filename(filename)
    return nil unless @files.key?(filename)

    data = @files[filename]
    OpenStruct.new(
      name: filename,
      data: data,
      peek: ->(prop) { data[prop.to_sym] || data[prop.to_s] }
    )
  end

  def to_include_filename(suffix)
    "include-#{suffix}.yaml"
  end

  def echo(msg)
    puts msg if @debug
  end

  def resolve_includes_recursively(filenames, visited = Set.new, include_order = [])
    filenames.each do |filename|
      next if visited.include?(filename)

      visited << filename
      reload_profiles([filename])
      file_info = cache_get_by_filename(filename)
      next unless file_info

      nested_suffixes = file_info.peek.call('include') || []
      echo "#{filename} has nested includes: #{nested_suffixes}" if @debug && !nested_suffixes.empty?
      nested_filenames = nested_suffixes.map { |suffix| to_include_filename(suffix) }

      resolve_includes_recursively(nested_filenames, visited, include_order)

      include_order << filename
    end
    include_order
  end
end

RSpec.describe 'Cascading Includes Algorithm' do
  describe '#resolve_includes_recursively' do
    context 'with no includes' do
      it 'returns empty array when no include files specified' do
        resolver = IncludeResolver.new({})
        result = resolver.resolve_includes_recursively([])
        expect(result).to eq([])
      end
    end

    context 'with single-level includes (backwards compatibility)' do
      let(:files) do
        {
          'include-hunting.yaml' => { hunting_zones: ['zone1', 'zone2'] }
        }
      end

      it 'resolves single-level includes correctly' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-hunting.yaml'])
        expect(result).to eq(['include-hunting.yaml'])
      end
    end

    context 'with two-level cascading includes' do
      let(:files) do
        {
          'include-hunting.yaml' => { include: ['combat'], hunting_zones: ['zone1'] },
          'include-combat.yaml'  => { combat_style: 'aggressive' }
        }
      end

      it 'resolves nested includes depth-first' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-hunting.yaml'])
        expect(result).to eq(['include-combat.yaml', 'include-hunting.yaml'])
      end
    end

    context 'with three-level cascading includes' do
      let(:files) do
        {
          'include-hunting.yaml' => { include: ['combat'], hunting_zones: ['zone1'] },
          'include-combat.yaml'  => { include: ['weapons'], combat_style: 'aggressive' },
          'include-weapons.yaml' => { primary_weapon: 'sword' }
        }
      end

      it 'resolves three levels depth-first' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-hunting.yaml'])
        expect(result).to eq(['include-weapons.yaml', 'include-combat.yaml', 'include-hunting.yaml'])
      end
    end

    context 'with sibling includes at same level' do
      let(:files) do
        {
          'include-hunting.yaml'  => { include: ['combat', 'survival'], hunting_zones: ['zone1'] },
          'include-combat.yaml'   => { combat_style: 'aggressive' },
          'include-survival.yaml' => { survival_skill: 'evasion' }
        }
      end

      it 'resolves siblings in order, depth-first' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-hunting.yaml'])
        expect(result).to eq(['include-combat.yaml', 'include-survival.yaml', 'include-hunting.yaml'])
      end
    end

    context 'with diamond dependency pattern' do
      let(:files) do
        {
          'include-hunting.yaml'  => { include: ['common'], hunting_zones: ['zone1'] },
          'include-crafting.yaml' => { include: ['common'], crafting_type: 'forging' },
          'include-common.yaml'   => { safe_room: 1234 }
        }
      end

      it 'resolves diamond pattern without duplicates' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-hunting.yaml', 'include-crafting.yaml'])
        expect(result).to eq(['include-common.yaml', 'include-hunting.yaml', 'include-crafting.yaml'])
        expect(result.count('include-common.yaml')).to eq(1)
      end
    end

    context 'with circular dependency' do
      let(:files) do
        {
          'include-circular-a.yaml' => { include: ['circular-b'], setting_a: 'value_a' },
          'include-circular-b.yaml' => { include: ['circular-a'], setting_b: 'value_b' }
        }
      end

      it 'handles circular dependency without infinite loop' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-circular-a.yaml'])
        expect(result).to eq(['include-circular-b.yaml', 'include-circular-a.yaml'])
      end
    end

    context 'with self-referencing include' do
      let(:files) do
        {
          'include-self-ref.yaml' => { include: ['self-ref'], setting_self: 'value_self' }
        }
      end

      it 'handles self-reference without infinite loop' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-self-ref.yaml'])
        expect(result).to eq(['include-self-ref.yaml'])
      end
    end

    context 'with missing include file' do
      let(:files) do
        {
          'include-exists.yaml' => { existing_setting: 'value' }
        }
      end

      it 'skips missing files gracefully' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-exists.yaml', 'include-missing.yaml'])
        expect(result).to eq(['include-exists.yaml'])
      end
    end

    context 'with include file having empty include array' do
      let(:files) do
        {
          'include-empty-includes.yaml' => { include: [], some_setting: 'value' }
        }
      end

      it 'handles empty include arrays' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-empty-includes.yaml'])
        expect(result).to eq(['include-empty-includes.yaml'])
      end
    end

    context 'with include file having nil/missing include key' do
      let(:files) do
        {
          'include-nil-includes.yaml' => { some_setting: 'value' }
        }
      end

      it 'handles missing include key (nil)' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-nil-includes.yaml'])
        expect(result).to eq(['include-nil-includes.yaml'])
      end
    end

    context 'with deeply nested includes (stress test)' do
      let(:files) do
        (1..10).each_with_object({}) do |level, hash|
          next_include = level < 10 ? ["level-#{level + 1}"] : []
          hash["include-level-#{level}.yaml"] = {
            include: next_include,
            "setting_#{level}": "value_#{level}"
          }
        end
      end

      it 'handles deeply nested includes' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-level-1.yaml'])
        expect(result.length).to eq(10)
      end

      it 'resolves in correct depth-first order' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-level-1.yaml'])
        expected = (1..10).to_a.reverse.map { |n| "include-level-#{n}.yaml" }
        expect(result).to eq(expected)
      end
    end

    context 'complex real-world scenario' do
      let(:files) do
        {
          'include-moon-mage.yaml'  => {
            include: ['magic-user', 'common'],
            guild: 'Moon Mage',
            cambrinth: 'moon-staff'
          },
          'include-crossing.yaml'   => {
            include: ['common'],
            hometown: 'Crossing',
            safe_room: 1234
          },
          'include-magic-user.yaml' => {
            include: ['common'],
            train_magic: true
          },
          'include-common.yaml'     => {
            loot_coins: true,
            safe_room: 9999
          }
        }
      end

      it 'resolves complex hierarchy correctly' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-moon-mage.yaml', 'include-crossing.yaml'])
        expect(result).to eq([
                               'include-common.yaml',
                               'include-magic-user.yaml',
                               'include-moon-mage.yaml',
                               'include-crossing.yaml'
                             ])
      end

      it 'common is only loaded once despite multiple references' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-moon-mage.yaml', 'include-crossing.yaml'])
        expect(result.count('include-common.yaml')).to eq(1)
        expect(result.uniq.length).to eq(result.length)
      end
    end

    context 'multiple initial includes with shared dependencies' do
      let(:files) do
        {
          'include-hunting.yaml'   => { include: ['weapons', 'armor'] },
          'include-crafting.yaml'  => { include: ['tools', 'armor'] },
          'include-weapons.yaml'   => { include: ['materials'] },
          'include-tools.yaml'     => { include: ['materials'] },
          'include-armor.yaml'     => {},
          'include-materials.yaml' => {}
        }
      end

      it 'resolves shared dependencies correctly' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-hunting.yaml', 'include-crafting.yaml'])
        expect(result.uniq.length).to eq(result.length)
        expect(result).to include('include-hunting.yaml')
        expect(result).to include('include-crafting.yaml')
        expect(result).to include('include-weapons.yaml')
        expect(result).to include('include-tools.yaml')
        expect(result).to include('include-armor.yaml')
        expect(result).to include('include-materials.yaml')
      end

      it 'maintains depth-first order' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-hunting.yaml', 'include-crafting.yaml'])
        expect(result.index('include-materials.yaml')).to be < result.index('include-weapons.yaml')
        expect(result.index('include-weapons.yaml')).to be < result.index('include-hunting.yaml')
        expect(result.index('include-hunting.yaml')).to be < result.index('include-crafting.yaml')
      end
    end
  end

  describe 'merge order verification' do
    context 'setting override precedence' do
      let(:files) do
        {
          'include-level2.yaml' => { shared: 'from_level2', level2_only: 'l2' },
          'include-level1.yaml' => { include: ['level2'], shared: 'from_level1', level1_only: 'l1' }
        }
      end

      it 'shallower include overrides deeper include' do
        resolver = IncludeResolver.new(files)
        order = resolver.resolve_includes_recursively(['include-level1.yaml'])
        merged = order.reduce({}) do |result, filename|
          data = files[filename] || {}
          result.merge(data.reject { |k, _| k == :include })
        end
        expect(merged[:shared]).to eq('from_level1')
        expect(merged[:level1_only]).to eq('l1')
        expect(merged[:level2_only]).to eq('l2')
      end
    end
  end
end

# --- Inlined Manager Functions ---

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

# --- SHA Computation (build_version_hash) ---

RSpec.describe 'SHA computation' do
  # Replicates dependency's build_version_hash SHA computation:
  #   body = File.binread(path)
  #   sha = Digest::SHA1.hexdigest("blob #{body.size}\0#{body}")
  # This must match git's blob SHA regardless of line endings.

  let(:content_lf) { "line1\nline2\nline3\n" }
  let(:content_crlf) { "line1\r\nline2\r\nline3\r\n" }

  def git_blob_sha(content)
    Digest::SHA1.hexdigest("blob #{content.size}\0#{content}")
  end

  it 'produces consistent SHAs for LF files using binread' do
    path = File.join(SCRIPT_DIR, 'test-lf.lic')
    File.binwrite(path, content_lf)
    body = File.binread(path)
    expect(git_blob_sha(body)).to eq(git_blob_sha(content_lf))
  ensure
    File.delete(path) if File.exist?(path)
  end

  it 'produces consistent SHAs for CRLF files using binread' do
    path = File.join(SCRIPT_DIR, 'test-crlf.lic')
    File.binwrite(path, content_crlf)
    body = File.binread(path)
    expect(git_blob_sha(body)).to eq(git_blob_sha(content_crlf))
  ensure
    File.delete(path) if File.exist?(path)
  end

  it 'produces DIFFERENT SHAs for LF vs CRLF content (they are different bytes)' do
    expect(git_blob_sha(content_lf)).not_to eq(git_blob_sha(content_crlf))
  end

  it 'would produce WRONG SHA if text-mode read were used on CRLF files' do
    path = File.join(SCRIPT_DIR, 'test-crlf-textmode.lic')
    File.binwrite(path, content_crlf)

    # Text-mode read (the old buggy way) - translates CRLF to LF on read
    text_body = File.open(path, 'r').readlines.join('')
    git_blob_sha(text_body)

    # Binary read (the correct way) - preserves bytes
    bin_body = File.binread(path)
    git_blob_sha(bin_body)

    # On platforms that translate line endings (Windows), these would differ.
    # On Unix they're the same because 'r' mode doesn't translate.
    # The key point: binread always gives the correct SHA regardless of platform.
    expect(git_blob_sha(bin_body)).to eq(git_blob_sha(content_crlf))
  ensure
    File.delete(path) if File.exist?(path)
  end

  it 'round-trip: write with wb then read with binread produces SHA matching original content' do
    # This is the critical regression test: if we write with 'wb' and read
    # with binread, the SHA of the round-tripped content must match the SHA
    # of the original content (as GitHub would compute it).
    # The regression in 2.4.7 was: writes used text mode ('w') which added
    # CRLF on Windows, but reads used binread which preserved CRLF,
    # producing a SHA that never matched GitHub's LF-based SHA.
    original_content = content_lf # simulates what download_raw_file returns
    path = File.join(SCRIPT_DIR, 'test-roundtrip.lic')

    # Write the way dependency does (wb mode)
    File.open(path, 'wb') { |file| file.print(original_content) }

    # Read the way build_version_hash does (binread)
    read_back = File.binread(path)

    # SHA must match the original content's SHA
    expect(git_blob_sha(read_back)).to eq(git_blob_sha(original_content))
  ensure
    File.delete(path) if File.exist?(path)
  end

  it 'round-trip: write with wb preserves LF line endings (no CRLF conversion)' do
    path = File.join(SCRIPT_DIR, 'test-roundtrip-endings.lic')
    File.open(path, 'wb') { |file| file.print(content_lf) }
    read_back = File.binread(path)

    # Content must be byte-identical - no line ending translation
    expect(read_back).to eq(content_lf)
    expect(read_back).not_to include("\r\n")
  ensure
    File.delete(path) if File.exist?(path)
  end
end

RSpec.describe 'union_keys merge behavior' do
  # Simulates the merge logic from SetupFiles#get_settings
  def merge_with_union_keys(file_data_list)
    # Peek pass: collect union_keys from all files
    union_keys = file_data_list.reduce([]) do |keys, data|
      file_keys = data['union_keys'] || []
      (keys + file_keys).uniq
    end

    # Merge pass
    file_data_list.reduce({}) do |result, data|
      result.merge(data) do |key, old_val, new_val|
        if union_keys.include?(key) && old_val.is_a?(Array) && new_val.is_a?(Array)
          (old_val + new_val).uniq
        else
          new_val
        end
      end
    end
  end

  context 'when no union_keys defined' do
    it 'overwrites arrays (existing behavior)' do
      base = { 'autostarts' => %w[esp afk] }
      char = { 'autostarts' => %w[healer] }
      result = merge_with_union_keys([base, char])
      expect(result['autostarts']).to eq(%w[healer])
    end
  end

  context 'when union_keys includes autostarts' do
    it 'unions arrays from include and character files' do
      include_file = { 'union_keys' => ['autostarts'], 'autostarts' => %w[esp afk textsubs] }
      char_file = { 'autostarts' => %w[healer moonwatch] }
      result = merge_with_union_keys([include_file, char_file])
      expect(result['autostarts']).to match_array(%w[esp afk textsubs healer moonwatch])
    end
  end

  context 'when union_keys defined in multiple files' do
    it 'unions the union_keys themselves' do
      base = { 'union_keys' => ['autostarts'], 'autostarts' => %w[esp], 'gear' => %w[backpack] }
      include_file = { 'union_keys' => ['gear'], 'autostarts' => %w[afk], 'gear' => %w[sword] }
      char = { 'autostarts' => %w[healer], 'gear' => %w[shield] }
      result = merge_with_union_keys([base, include_file, char])
      expect(result['autostarts']).to match_array(%w[esp afk healer])
      expect(result['gear']).to match_array(%w[backpack sword shield])
    end
  end

  context 'when union key value is not an array' do
    it 'falls through to overwrite' do
      base = { 'union_keys' => ['hometown'], 'hometown' => 'Crossing' }
      char = { 'hometown' => 'Shard' }
      result = merge_with_union_keys([base, char])
      expect(result['hometown']).to eq('Shard')
    end
  end

  context 'when union key only defined in one file' do
    it 'keeps the value as-is' do
      base = { 'union_keys' => ['autostarts'] }
      char = { 'autostarts' => %w[healer moonwatch] }
      result = merge_with_union_keys([base, char])
      expect(result['autostarts']).to eq(%w[healer moonwatch])
    end
  end

  context 'when union produces duplicates' do
    it 'deduplicates the result' do
      base = { 'union_keys' => ['autostarts'], 'autostarts' => %w[esp afk] }
      char = { 'autostarts' => %w[afk healer] }
      result = merge_with_union_keys([base, char])
      expect(result['autostarts']).to match_array(%w[esp afk healer])
      expect(result['autostarts'].length).to eq(3)
    end
  end

  context 'with three-file cascade (base, include, character)' do
    it 'unions across all three files' do
      base = { 'union_keys' => ['autostarts'], 'autostarts' => %w[esp] }
      include_file = { 'autostarts' => %w[afk textsubs] }
      char = { 'autostarts' => %w[healer] }
      result = merge_with_union_keys([base, include_file, char])
      expect(result['autostarts']).to match_array(%w[esp afk textsubs healer])
    end
  end

  context 'non-union keys remain unaffected' do
    it 'overwrites non-union keys normally' do
      base = { 'union_keys' => ['autostarts'], 'autostarts' => %w[esp], 'hometown' => 'Crossing' }
      char = { 'autostarts' => %w[healer], 'hometown' => 'Shard' }
      result = merge_with_union_keys([base, char])
      expect(result['autostarts']).to match_array(%w[esp healer])
      expect(result['hometown']).to eq('Shard')
    end
  end
end

# --- Sentinel Gating ---
# Validates structural integrity of the gated dependency.lic:
# - Each sentinel gates an independent block
# - No gate block nests another sentinel check
# - Functions land in the correct gate (or outside all gates)
# - Version string has been ticked

DEP_SOURCE = File.read(dep_path)

# Extracts the body of an `unless Lich::Common.const_defined?(:SENTINEL, false)` block.
# Returns the indented content between the unless and its closing end.
# Extracts all `unless Lich::Common.const_defined?(:SENTINEL, false)` blocks
# that reference the given sentinel. Returns their bodies concatenated.
# A single sentinel may gate multiple blocks (e.g. CORE_GET_SETTINGS gates
# both the get_settings/get_data functions and the ScriptManager class).
def extract_gate_block(source, sentinel_name)
  opening = "unless Lich::Common.const_defined?(:#{sentinel_name}, false)\n"
  bodies = []
  pos = 0
  while (idx = source.index(opening, pos))
    rest = source[idx + opening.length..]
    end_match = rest.match(/^end\s*#.*gate/)
    raise "Could not find closing end for #{sentinel_name} gate at position #{idx}" unless end_match

    bodies << rest[0...end_match.begin(0)]
    pos = idx + opening.length + end_match.end(0)
  end
  raise "Could not find any gate block for #{sentinel_name}" if bodies.empty?

  bodies.join("\n")
end

RSpec.describe 'Sentinel Gating Structure' do
  describe 'gate block extraction' do
    %w[CORE_GET_SETTINGS CORE_SCRIPT_LOADER CORE_MAP_OVERRIDES CORE_DR_STARTUP CORE_AUTOSTART].each do |sentinel|
      it "#{sentinel} gate block exists and is extractable" do
        expect { extract_gate_block(DEP_SOURCE, sentinel) }.not_to raise_error
      end
    end
  end

  describe 'gate independence' do
    let(:sentinels) { %w[CORE_GET_SETTINGS CORE_SCRIPT_LOADER CORE_MAP_OVERRIDES CORE_DR_STARTUP CORE_AUTOSTART] }

    it 'no gate block contains another sentinel check' do
      sentinels.each do |sentinel|
        block = extract_gate_block(DEP_SOURCE, sentinel)
        other_sentinels = sentinels - [sentinel]
        other_sentinels.each do |other|
          expect(block).not_to include("const_defined?(:#{other}"),
                               "#{sentinel} gate must not check #{other} -- gates must be independent"
        end
      end
    end
  end

  describe 'CORE_GET_SETTINGS gate contents' do
    let(:block) { extract_gate_block(DEP_SOURCE, 'CORE_GET_SETTINGS') }

    it 'defines $setupfiles global' do
      expect(block).to include('$setupfiles = SetupFiles.new')
    end

    it 'defines get_settings method' do
      expect(block).to include('def get_settings')
    end

    it 'defines get_data method' do
      expect(block).to include('def get_data')
    end

    it 'defines ScriptManager class (also gated by CORE_GET_SETTINGS)' do
      expect(block).to include('class ScriptManager')
    end

    it 'defines $manager global' do
      expect(block).to include('$manager = ScriptManager.new')
    end

    it 'defines ScriptManager-dependent helpers' do
      expect(block).to include('def get_script(')
      expect(block).to include('def force_refresh_scripts')
      expect(block).to include('def list_tracked_scripts')
      expect(block).to include('def setup_data')
    end
  end

  describe 'CORE_SCRIPT_LOADER gate contents' do
    let(:block) { extract_gate_block(DEP_SOURCE, 'CORE_SCRIPT_LOADER') }

    it 'defines custom_require method returning a lambda' do
      expect(block).to include('def custom_require')
      expect(block).to include('lambda do')
    end
  end

  describe 'CORE_MAP_OVERRIDES gate contents' do
    let(:block) { extract_gate_block(DEP_SOURCE, 'CORE_MAP_OVERRIDES') }

    it 'defines make_map_edits method' do
      expect(block).to include('def make_map_edits')
    end

    it 'handles wayto overrides' do
      expect(block).to include('base_wayto_overrides')
      expect(block).to include('personal_wayto_overrides')
    end

    it 'handles personal map targets' do
      expect(block).to include('personal_map_targets')
    end
  end

  describe 'CORE_DR_STARTUP gate contents' do
    let(:block) { extract_gate_block(DEP_SOURCE, 'CORE_DR_STARTUP') }

    it 'checks ShowRoomID and MonsterBold flags' do
      expect(block).to include('ShowRoomID')
      expect(block).to include('MonsterBold')
    end

    it 'guards flag setup with UserVars.dependency_setflags' do
      expect(block).to include('dependency_setflags')
    end

    it 'defines DR_OBSOLETE_SCRIPTS constant' do
      expect(block).to include('DR_OBSOLETE_SCRIPTS')
    end

    it 'defines DR_OBSOLETE_DATA_FILES constant' do
      expect(block).to include('DR_OBSOLETE_DATA_FILES')
    end

    it 'defines warn_obsolete_scripts method' do
      expect(block).to include('def warn_obsolete_scripts')
    end

    it 'defines warn_obsolete_data_files method' do
      expect(block).to include('def warn_obsolete_data_files')
    end

    it 'defines warn_custom_scripts method' do
      expect(block).to include('def warn_custom_scripts')
    end
  end

  describe 'CORE_AUTOSTART gate contents' do
    let(:block) { extract_gate_block(DEP_SOURCE, 'CORE_AUTOSTART') }

    it 'defines handle_obsolete_autostart method' do
      expect(block).to include('def handle_obsolete_autostart')
    end

    it 'defines dr_obsolete_script? method' do
      expect(block).to include('def dr_obsolete_script?')
    end

    it 'defines autostart method' do
      expect(block).to include('def autostart(')
    end

    it 'defines stop_autostart method' do
      expect(block).to include('def stop_autostart(')
    end

    it 'defines dependency_status method' do
      expect(block).to include('def dependency_status')
    end

    it 'merges Settings autostart into UserVars' do
      expect(block).to include("Settings['autostart']")
      expect(block).to include('UserVars.autostart_scripts')
    end
  end

  describe 'pre-existing gates' do
    it 'CORE_ARGPARSER gate exists with inline fallback' do
      expect(DEP_SOURCE).to match(/const_defined\?\(:CORE_ARGPARSER/)
      expect(DEP_SOURCE).to include('class ArgParser')
    end

    it 'CORE_SETUPFILES gate exists with inline fallback' do
      expect(DEP_SOURCE).to match(/const_defined\?\(:CORE_SETUPFILES/)
      expect(DEP_SOURCE).to include('class SetupFiles')
    end

    it 'does not define redundant top-level aliases (include Lich::Common handles it)' do
      expect(DEP_SOURCE).not_to include('ArgParser = Lich::Common::ArgParser')
      expect(DEP_SOURCE).not_to include('SetupFiles = Lich::Common::SetupFiles')
    end
  end

  describe 'ungated runtime helpers' do
    let(:runtime_marker) { DEP_SOURCE.index('# --- Runtime helpers') }

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
      it "#{fn_name} is defined outside all gate blocks" do
        fn_pos = DEP_SOURCE.index(/^def #{Regexp.escape(fn_name)}[\s(]?/)
        expect(fn_pos).not_to be_nil, "Expected to find def #{fn_name}"
        expect(fn_pos).to be > runtime_marker,
                          "#{fn_name} should be after the runtime helpers section marker"
      end
    end
  end

  describe 'version' do
    it 'has been ticked to 3.0.0' do
      expect(DEP_SOURCE).to include("$DEPENDENCY_VERSION = '3.0.0'")
    end

    it 'requires minimum lich version 5.16.2' do
      expect(DEP_SOURCE).to include("$MIN_LICH_VERSION = '5.16.2'")
    end
  end

  describe 'boot sequence' do
    it 'conditionally runs legacy ScriptManager boot' do
      expect(DEP_SOURCE).to include('if defined?($manager)')
    end

    it 'calls map overrides in non-legacy path' do
      expect(DEP_SOURCE).to match(/make_map_edits if/)
    end

    it 'reloads setupfiles cache' do
      expect(DEP_SOURCE).to include('$setupfiles.reload if')
    end

    it 'calls warning functions conditionally' do
      expect(DEP_SOURCE).to match(/warn_custom_scripts if/)
      expect(DEP_SOURCE).to match(/warn_obsolete_scripts if/)
      expect(DEP_SOURCE).to match(/warn_obsolete_data_files if/)
    end
  end
end
