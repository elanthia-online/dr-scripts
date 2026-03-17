# frozen_string_literal: true

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

# Mock DRC.message for handle_obsolete_autostart
module DRC
  def self.message(msg, _bold = true)
    $respond_messages << msg
  end
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

# Extract inlined manager functions
%w[
  save_bankbot_transaction
  load_bankbot_ledger
  save_reportbot_whitelist
  load_reportbot_whitelist
  register_slackbot
  send_slackbot_message
  warn_obsolete_data_files
].each do |fn_name|
  fn_s = dep_lines.index { |l| l =~ /^def #{Regexp.escape(fn_name)}\b/ }
  fn_e = dep_lines[fn_s + 1..].index { |l| l =~ /^end\s*$/ }
  eval(dep_lines[fn_s..fn_s + 1 + fn_e].join, TOPLEVEL_BINDING, dep_path, fn_s + 1)
end

# Extract DR_OBSOLETE_DATA_FILES constant
odf_start = dep_lines.index { |l| l =~ /^DR_OBSOLETE_DATA_FILES\s*=/ }
odf_end = dep_lines[odf_start..].index { |l| l =~ /\.freeze$/ }
eval(dep_lines[odf_start..odf_start + odf_end].join, TOPLEVEL_BINDING, dep_path, odf_start + 1)

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
        expect($respond_messages.first).to eq("---")
        expect($respond_messages.last).to eq("---")
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
