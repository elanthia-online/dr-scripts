require 'ostruct'

module Harness
  # Lich global for the last time a user sent a command to the game
  $_IDLETIMESTAMP_ = Time.now
  # Lich global for the last time a script sent a command to the game
  $_SCRIPTIDLETIMESTAMP_ = Time.now
  # Indicate to scripts that we are in test mode
  $_TEST_MODE_ = true

  class DRSpells
    @@_data_store = {}

    def self._reset
      @@_data_store = {}
    end

    def self._set_active_spells(val)
      @@_data_store['active_spells'] = val
    end

    def self.active_spells
      @@_data_store['active_spells'] || {}
    end

    def self._set_known_spells(val)
      @@_data_store['known_spells'] = val
    end

    def self.known_spells
      @@_data_store['known_spells'] || {}
    end
  end

  class DRStats
    @@_data_store = {}

    def self._reset
      @@_data_store = {}
    end

    def self.race
      @@_data_store['race']
    end

    def self.race=(val)
      @@_data_store['race'] = val
    end

    def self.guild
      @@_data_store['guild']
    end

    def self.guild=(val)
      @@_data_store['guild'] = val
    end

    def self.gender
      @@_data_store['gender']
    end

    def self.gender=(val)
      @@_data_store['gender'] = val
    end

    def self.age
      @@_data_store['age']
    end

    def self.age=(val)
      @@_data_store['age'] = val
    end

    def self.circle
      @@_data_store['circle']
    end

    def self.circle=(val)
      @@_data_store['circle'] = val
    end

    def self.strength
      @@_data_store['strength']
    end

    def self.strength=(val)
      @@_data_store['strength'] = val
    end

    def self.stamina
      @@_data_store['stamina']
    end

    def self.stamina=(val)
      @@_data_store['stamina'] = val
    end

    def self.reflex
      @@_data_store['reflex']
    end

    def self.reflex=(val)
      @@_data_store['reflex'] = val
    end

    def self.agility
      @@_data_store['agility']
    end

    def self.agility=(val)
      @@_data_store['agility'] = val
    end

    def self.intelligence
      @@_data_store['intelligence']
    end

    def self.intelligence=(val)
      @@_data_store['intelligence'] = val
    end

    def self.wisdom
      @@_data_store['wisdom']
    end

    def self.wisdom=(val)
      @@_data_store['wisdom'] = val
    end

    def self.discipline
      @@_data_store['discipline']
    end

    def self.discipline=(val)
      @@_data_store['discipline'] = val
    end

    def self.charisma
      @@_data_store['charisma']
    end

    def self.charisma=(val)
      @@_data_store['charisma'] = val
    end

    def self.concentration
      @@_data_store['concentration']
    end

    def self.concentration=(val)
      @@_data_store['concentration'] = val
    end

    def self.favors
      @@_data_store['favors']
    end

    def self.favors=(val)
      @@_data_store['favors'] = val
    end

    def self.tdps
      @@_data_store['tdps']
    end

    def self.tdps=(val)
      @@_data_store['tdps'] = val
    end

    def self.balance
      @@_data_store['balance']
    end

    def self.balance=(val)
      @@_data_store['balance'] = val
    end

    def self.encumbrance
      @@_data_store['encumbrance']
    end

    def self.encumbrance=(val)
      @@_data_store['encumbrance'] = val
    end

    def self.health
      @@_data_store['health']
    end

    def self.health=(val)
      @@_data_store['health'] = val
    end

    def self.mana
      @@_data_store['mana']
    end

    def self.mana=(val)
      @@_data_store['mana'] = val
    end

    def self.native_mana
      case DRStats.guild
      when 'Necromancer'
        'arcane'
      when 'Barbarian', 'Thief'
        nil
      when 'Moon Mage', 'Trader'
        'lunar'
      when 'Warrior Mage', 'Bard'
        'elemental'
      when 'Cleric', 'Paladin'
        'holy'
      when 'Empath', 'Ranger'
        'life'
      end
    end

    def self.fatigue
      @@_data_store['fatigue']
    end

    def self.fatigue=(val)
      @@_data_store['fatigue'] = val
    end

    def self.spirit
      @@_data_store['spirit']
    end

    def self.spirit=(val)
      @@_data_store['spirit'] = val
    end

    def self.barbarian?
      DRStats.guild == 'Barbarian'
    end

    def self.bard?
      DRStats.guild == 'Bard'
    end

    def self.cleric?
      DRStats.guild == 'Cleric'
    end

    def self.commoner?
      DRStats.guild == 'Commoner'
    end

    def self.empath?
      DRStats.guild == 'Empath'
    end

    def self.moon_mage?
      DRStats.guild == 'Moon Mage'
    end

    def self.necromancer?
      DRStats.guild == 'Necromancer'
    end

    def self.paladin?
      DRStats.guild == 'Paladin'
    end

    def self.ranger?
      DRStats.guild == 'Ranger'
    end

    def self.thief?
      DRStats.guild == 'Thief'
    end

    def self.trader?
      DRStats.guild == 'Trader'
    end

    def self.warrior_mage?
      DRStats.guild == 'Warrior Mage'
    end
  end

  class DRSkill
    @@_data_store = {}
    @@_xp_store = {}
    @@_modrank_store = {}

    def self._reset
      @@_data_store = {}
      @@_xp_store = {}
      @@_modrank_store = {}
    end

    def self._set_rank(skillname, val)
      @@_data_store[skillname] = val
    end

    def self.getrank(skillname)
      @@_data_store[skillname] || 100
    end

    def self._set_xp(skillname, val)
      @@_xp_store[skillname] = val
    end

    def self._reset_xp
      @@_xp_store = {}
    end

    def self.getxp(skillname)
      @@_xp_store[skillname] || 0
    end

    def self._set_modrank(skillname, val)
      @@_modrank_store[skillname] = val
    end

    def self._reset_modrank
      @@_modrank_store = {}
    end

    def self.getmodrank(skillname)
      @@_modrank_store[skillname] || 0
    end
  end

  class DRRoom
    @@_data_store = {}

    def self._reset
      @@_data_store = {}
    end

    def self.npcs
      @@_data_store['npcs'] || []
    end

    def self.npcs=(val)
      @@_data_store['npcs'] = val
    end

    def self.pcs
      @@_data_store['pcs'] || []
    end

    def self.pcs=(val)
      @@_data_store['pcs'] = val
    end

    def self.exits
      @@_data_store['exits'] || []
    end

    def self.exits=(val)
      @@_data_store['exits'] = val
    end

    def self.title
      @@_data_store['title'] || ''
    end

    def self.title=(val)
      @@_data_store['title'] = val
    end

    def self.description
      @@_data_store['description'] || ''
    end

    def self.description=(val)
      @@_data_store['description'] = val
    end

    def self.group_members
      @@_data_store['group_members'] || []
    end

    def self.group_members=(val)
      @@_data_store['group_members'] = val
    end

    def self.pcs_prone
      @@_data_store['pcs_prone'] || []
    end

    def self.pcs_prone=(val)
      @@_data_store['pcs_prone'] = val
    end

    def self.pcs_sitting
      @@_data_store['pcs_sitting'] || []
    end

    def self.pcs_sitting=(val)
      @@_data_store['pcs_sitting'] = val
    end

    def self.dead_npcs
      @@_data_store['dead_npcs'] || []
    end

    def self.dead_npcs=(val)
      @@_data_store['dead_npcs'] = val
    end

    def self.room_objs
      @@_data_store['room_objs'] || []
    end

    def self.room_objs=(val)
      @@_data_store['room_objs'] = val
    end
  end

  class GameObj
    def self.left_hand
      item = Harness.left_hand || 'Empty'
      OpenStruct.new({ name: item, noun: item })
    end

    def self.left_hand=(val)
      Harness.left_hand(val)
    end

    def self.right_hand
      item = Harness.right_hand || 'Empty'
      OpenStruct.new({ name: item, noun: item })
    end

    def self.right_hand=(val)
      Harness.right_hand(val)
    end
  end

  class Flags
    @@flags = {}
    @@matchers = {}

    def self._reset
      @@flags = {}
      @@matchers = {}
    end

    def self.[](key)
      @@flags[key]
    end

    def self.[]=(key, value)
      @@flags[key] = value
    end

    def self.add(key, *matchers)
      @@flags[key] = false
      @@matchers[key] = matchers.map { |item| item.is_a?(Regexp) ? item : /#{item}/i }
    end

    def self.reset(key)
      @@flags[key] = false
    end

    def self.delete(key)
      @@matchers.delete key
      @@flags.delete key
    end

    def self.flags
      @@flags
    end

    def self.matchers
      @@matchers
    end
  end

  class Script
    def gets?
      get?
    end

    def gets
      get?
    end

    def self.running?(script_name)
      $running_scripts.include?(script_name)
    end

    def self.current
      OpenStruct.new(name: 'test-script')
    end

    def self.exists?(_name)
      false
    end

    def self.at_exit(&_block); end
  end

  # Copied from lich.rbw
  class UpstreamHook
    @@upstream_hooks ||= Hash.new

    def UpstreamHook.add(name, action)
      unless action.class == Proc
        echo "UpstreamHook: not a Proc (#{action})"
        return false
      end
      @@upstream_hooks[name] = action
    end

    def UpstreamHook.run(client_string)
      for key in @@upstream_hooks.keys
        begin
          client_string = @@upstream_hooks[key].call(client_string)
        rescue
          @@upstream_hooks.delete(key)
          respond "--- Lich: UpstreamHook: #{$!}"
          respond $!.backtrace.first
        end
        return nil if client_string.nil?
      end
      return client_string
    end

    def UpstreamHook.remove(name)
      @@upstream_hooks.delete(name)
    end

    def UpstreamHook.list
      @@upstream_hooks.keys.dup
    end
  end

  # Copied from lich.rbw
  class DownstreamHook
    @@downstream_hooks ||= Hash.new

    def DownstreamHook.add(name, action)
      unless action.class == Proc
        echo "DownstreamHook: not a Proc (#{action})"
        return false
      end
      @@downstream_hooks[name] = action
    end

    def DownstreamHook.run(server_string)
      for key in @@downstream_hooks.keys
        begin
          server_string = @@downstream_hooks[key].call(server_string.dup)
        rescue
          @@downstream_hooks.delete(key)
          respond "--- Lich: DownstreamHook: #{$!}"
          respond $!.backtrace.first
        end
        return nil if server_string.nil?
      end
      return server_string
    end

    def DownstreamHook.remove(name)
      @@downstream_hooks.delete(name)
    end

    def DownstreamHook.list
      @@downstream_hooks.keys.dup
    end
  end

  class EquipmentManager
    def empty_hands; end

    def remove_gear_by; end

    def wear_items(_items); end

    def wear_equipment_set?(_set_name); end
  end

  class Room
    def self.current
      Map.new(
        :id    => 1,
        :wayto => {
          2 => nil
        }
      )
    end
  end

  class Map
    @@_data_store = {}

    def initialize(id: nil, wayto: nil)
      self.id = id
      self.wayto = wayto
    end

    def self._reset
      @@_data_store = {}
    end

    def id
      @@_data_store['id']
    end

    def id=(val)
      @@_data_store['id'] = val
    end

    def wayto
      @@_data_store['wayto']
    end

    def wayto=(val)
      @@_data_store['wayto'] = val
    end
  end

  class XMLData
    @@_room_title = nil

    def self._reset
      @@_room_title = nil
    end

    def self.room_title
      @@_room_title || 'Middle of Nowhere'
    end

    def self.room_title=(val)
      @@_room_title = val
    end
  end

  def before_dying(&code)
    Script.at_exit(&code)
  end

  def script
    Script.new
  end

  def smart_pause_all
    []
  end

  def unpause_all_list(scripts)
  end

  def custom_require(*)
    proc { |_args| }
  end

  def pause(duration = 1)
    $pause = duration
    # Don't actually sleep, slows down tests.
    # Use Timecop gem to simulate elapsed time.
    # See test_bput as an example.
  end

  def parse_args(_data, _flex_args = false)
    args = OpenStruct.new($parsed_args.dup || {})
    args.flex = 'test'
    args
  end

  def get_settings(dummy = nil)
    $settings_called_with = dummy
    $test_settings
  end

  def get_data(dummy)
    $data_called_with << dummy
    $test_data[dummy.to_sym]
  end

  # After tests run, we need to wipe out/reset
  # constants and other contextual data so that
  # each test doesn't interfere with the others.
  # Not doing so can lead to hard to find bugs
  # because the test framework may run tests
  # in random order, so sometimes things work
  # and then other times they don't.
  # https://stackoverflow.com/questions/11463060/how-to-reload-a-ruby-class
  def reset_data
    $test_data = OpenStruct.new
    $test_settings = OpenStruct.new
    $parsed_args = OpenStruct.new

    # We use queues because they are thread safe
    # https://ruby-doc.org/core-2.5.5/Queue.html
    $data_called_with = []
    $warn_msgs = []
    $error_msgs = []
    $history = []
    $server_buffer = []
    $displayed_messages = []
    $running_scripts = []

    # Captures for the Lich script seams (respond/start_script/stop_script).
    $respond_messages = []
    $started_scripts = []
    $stopped_scripts = []

    # Overridable character/state flags (default to a safe, inert value).
    $sitting = false
    $stunned = false
    $bleeding = false
    $charname = nil

    # Uses a queue for thread safety.
    # See assert_sends_messages method for usage.
    $sent_messages = Queue.new

    $health = 100
    $spirit = 100
    $concentration = 100
    $dead = false
    $standing = true
    $hidden = false
    $invisible = false

    $left_hand = nil
    $right_hand = nil

    Flags._reset
    DRSpells._reset
    DRStats._reset
    DRSkill._reset
    DRRoom._reset
    Map._reset
    XMLData._reset
  end

  def echo(message)
    print(message.to_s + "\n") if $audible
    displayed_messages << message
    if message =~ /^WARNING:/
      $warn_msgs << message
    elsif message =~ /^ERROR:/
      $error_msgs << message
    end
  end

  def message(message = '')
    echo(message)
  end

  def respond(message = '')
    echo(message)
  end

  def displayed_messages
    $displayed_messages
  end

  def standing?
    $standing || false
  end

  def hiding?
    hidden?
  end

  def hidden?
    $hidden || false
  end

  def invisible?
    $invisible || false
  end

  def dead?
    $dead || false
  end

  def health
    $health || 100
  end

  def spirit
    $spirit || 100
  end

  def concentration
    $concentration || 100
  end

  def fput(message)
    sent_messages << message
  end

  def put(message)
    sent_messages << message
  end

  def sent_messages
    $sent_messages
  end

  # Raw Lich respond. Captured so specs can assert on script output.
  def _respond(message = '')
    $respond_messages << message
  end

  # Script lifecycle helpers. start_script/stop_script capture their calls so
  # specs can assert which scripts were launched or killed; move/waitfor are
  # inert seams that scripts call during navigation.
  def start_script(name, *args)
    $started_scripts << [name, *args]
  end

  def stop_script(name)
    $stopped_scripts << name
  end

  def move(*_args); end

  def waitfor(*_args); end

  # Character/state seams with test-overridable globals.
  def checkname
    $charname || 'Testchar'
  end

  def sitting?
    $sitting || false
  end

  def stunned?
    $stunned || false
  end

  def bleeding?
    $bleeding || false
  end

  def health=(health)
    $health = health
  end

  def spirit=(spirit)
    $spirit = spirit
  end

  def dead=(dead)
    $dead = dead
  end

  def left_hand=(item)
    $left_hand = item
  end

  def left_hand
    $left_hand
  end

  def right_hand=(item)
    $right_hand = item
  end

  def right_hand
    $right_hand
  end

  def waitrt?; end

  def waitcastrt?; end

  def get?
    $history ? $history.shift : nil
  end

  alias get get?

  def reget(*lines)
    lines.flatten!
    history = $server_buffer.dup.join("\n")
    history.gsub!(/<pushStream id=["'](?:spellfront|inv|bounty|society)["'][^>]*\/>.*?<popStream[^>]*>/m, '')
    history.gsub!(/<stream id="Spells">.*?<\/stream>/m, '')
    history.gsub!(/<(compDef|inv|component|right|left|spell|prompt)[^>]*>.*?<\/\1>/m, '')
    history.gsub!(/<[^>]+>/, '')
    history.gsub!('&gt;', '>')
    history.gsub!('&lt;', '<')
    history = history.split("\n").delete_if { |line| line.nil? || line.empty? || line =~ /^[\r\n\s\t]*$/ }
    if lines.first.is_a?(Numeric) || lines.first.to_i.nonzero?
      history = history[-[lines.shift.to_i, history.length].min..-1]
    end
    unless lines.empty? || lines.nil?
      regex = /#{lines.join('|')}/i
      history = history.find_all { |line| line =~ regex }
    end
    if history.empty?
      nil
    else
      history
    end
  end

  def no_pause_all; end

  def no_kill_all; end

  def setpriority(*); end

  def register_slackbot(username); end

  def send_slackbot_message(message); end

  def clear; end

  def get_character_setting
    $character_setting
  end

  def save_character_profile(data)
    $save_character_profile = data
  end

  def run_script(script)
    thread = Thread.new do
      script = "#{script}.lic" unless script.end_with?('.lic')
      load script
    end
    $threads ||= []
    $threads << thread
    thread
  end

  def run_script_with_proc(scripts, test)
    thread = Thread.new do
      scripts = [scripts] unless scripts.is_a?(Array)
      scripts.each do |script|
        # To collect code coverage with the simplecov gem
        # then the scripts MUST be launched via `require_relative` command.
        # To be launched via `require_relative` command
        # then the scripts MUST use the `.rb` extension.
        script = "tmp/#{script}.rb" unless script.end_with?('.rb')
        require_relative script
      end
      test.call
    end
    $threads ||= []
    $threads << thread
    thread
  end

  # Copied from lich.rbw
  def force_start_script(script_name, cli_vars = [], flags = {})
  end

  def assert_sends_messages(expected_messages)
    expected_messages = expected_messages.clone

    consumer = Thread.new do
      loop do
        message = sent_messages.pop
        if $debug_message_assert
          puts "message  :  #{message}"
          puts "expected :#{expected_messages}"
        end
        expected_messages.delete_at(expected_messages.index(message) || expected_messages.length)
        break if expected_messages.empty?
        sleep 0.1
      end
    end

    10.times do |_|
      sleep 0.1 if consumer.alive?
    end

    $threads.last.kill if $threads

    $debug_message_assert = false
    assert_empty expected_messages, 'Expected script to send messages'
  end

  def assert_displayed_messages_include_any(phrases)
    proc do |_error|
      result = $displayed_messages.any? do |message|
        phrases.any? do |phrase|
          message.include?(phrase)
        end
      end
      assert(result)
    end
  end

  def assert_raise_error(error_class, error_message)
    proc do |error|
      assert_equal(error_class, error.class)
      assert(error.message.include?(error_message))
    end
  end

  # ---------------------------------------------------------------------------
  # Commons command-module stubs (DRC, DRCI, DRCC, ...).
  #
  # The commons layer cannot be loaded in specs, so these modules provide the
  # union of the methods the scripts call, with neutral defaults:
  #   - "is it present / did it happen" predicates default to false,
  #   - "did the action succeed" predicates default to true,
  #   - list/count accessors default to [] / 0,
  #   - everything else is an inert nil-returning seam.
  # Individual specs override the handful of returns they assert on with
  # per-example `allow(...).to receive(...)`. Centralizing them here (rather
  # than redefining them in each spec) keeps a single, consistent stub surface
  # so co-running specs cannot clobber each other's game doubles.
  # ---------------------------------------------------------------------------

  # Derive the trailing noun of an item long-name (mirrors DRC.get_noun).
  def self._noun(long_name)
    long_name.to_s.strip.scan(/[a-z\-']+$/i).first
  end

  module DRC
    class << self
      def bput(*_args); 'Roundtime'; end
      def left_hand; $left_hand; end
      def right_hand; $right_hand; end
      def left_hand_noun; Harness._noun($left_hand); end
      def right_hand_noun; Harness._noun($right_hand); end
      def get_noun(long_name); Harness._noun(long_name); end
      def get_gems(*_args); []; end
      def get_town_name(name); name; end
      def text2num(text); text; end
      def message(*_args); end
      def wait_for_script_to_complete(*_args); end
      def fix_standing; end
      def release_invisibility; end
      def beep; end
      def hide?(*_args); false; end
      def forage?(*_args); false; end
      def collect(*_args); end
      def retreat(*_args); end
      def rummage(*_args); end
      def log_window(*_args); end
    end
  end

  module DRCI
    class << self
      def in_hands?(*_args); false; end
      def in_left_hand?(*_args); false; end
      def in_right_hand?(*_args); false; end
      def exists?(*_args); false; end
      def lift?(*_args); false; end
      def wearing?(*_args); false; end
      def inside?(*_args); false; end
      def get_item?(*_args); true; end
      def get_item_if_not_held?(*_args); true; end
      def get_item_unsafe(*_args); end
      def get_item(*_args); end
      def put_away_item?(*_args); true; end
      def put_away_item_unsafe?(*_args); true; end
      def remove_item?(*_args); true; end
      def wear_item?(*_args); true; end
      def lower_item?(*_args); true; end
      def stow_item?(*_args); true; end
      def stow_hand(*_args); true; end
      def stow_hands(*_args); true; end
      def untie_item?(*_args); true; end
      def tie_gem_pouch?(*_args); true; end
      def swap_out_full_gempouch?(*_args); true; end
      def fill_gem_pouch_with_container(*_args); end
      def open_container?(*_args); true; end
      def dispose_trash(*_args); end
      def get_item_list(*_args); []; end
      def get_box_list_in_container(*_args); []; end
      def count_items_in_container(*_args); 0; end
      def count_all_boxes(*_args); 0; end
      def count_lockpick_container(*_args); 0; end
    end
  end

  module DRCC
    class << self
      def check_for_existing_sigil?(*_args); true; end
      def get_adjust_tongs?(*_args); true; end
      def stow_crafting_item(*_args); true; end
      def get_crafting_item(*_args); end
      def logbook_item(*_args); end
      def order_enchant(*_args); end
      def repair_own_tools(*_args); end
      def check_consumables(*_args); end
      def find_recipe2(*_args); end
      def find_grindstone(*_args); end
      def find_empty_crucible(*_args); end
      def find_enchanting_room(*_args); end
      def find_sewing_room(*_args); end
      def find_shaping_room(*_args); end
      def fount(*_args); end
    end
  end

  module DRCM
    class << self
      def ensure_copper_on_hand(*_args); true; end
      def wealth(*_args); 0; end
      def check_wealth(*_args); 0; end
      def get_total_wealth(*_args); {}; end
      def convert_to_copper(amount, _denom = nil); amount.to_i; end
      def minimize_coins(*_args); []; end
      def deposit_coins(*_args); end
    end
  end

  module DRCT
    class << self
      def walk_to(*_args); true; end
      def sort_destinations(ids); ids; end
      def buy_item(*_args); end
      def order_item(*_args); end
      def dispose(*_args); end
      def refill_lockpick_container(*_args); end
    end
  end

  module DRCH
    class << self
      def check_health(*_args); { 'score' => 0, 'bleeders' => [], 'poisoned' => false, 'diseased' => false }; end
      def has_tendable_bleeders?(*_args); false; end
      def bind_wound(*_args); end
      def perceive_health(*_args); end
      def perceive_health_other(*_args); end
    end
  end

  module DRCA
    class << self
      def cast?(*_args); true; end
      def cast_spell?(*_args); true; end
      def prepare?(*_args); true; end
      def segue?(*_args); true; end
      def activate_khri?(*_args); true; end
      def activate_barb_buff?(*_args); true; end
      def shatter_regalia?(*_args); true; end
      def cast_spell(*_args); end
      def cast_spells(*_args); end
      def check_discern(*_args); end
      def check_elemental_charge(*_args); end
      def check_to_harness(*_args); end
      def crafting_magic_routine(*_args); end
      def find_cambrinth(*_args); end
      def infuse_om(*_args); end
      def invoke(*_args); end
      def parse_regalia(*_args); end
      def perc_aura(*_args); end
      def perc_mana(*_args); end
      def release_cyclics(*_args); end
      def stow_cambrinth(*_args); end
      def update_avtalia(*_args); end
    end
  end

  module DRCS
    class << self
      def summon_weapon(*_args); end
      def summon_admittance(*_args); end
      def break_summoned_weapon(*_args); end
      def pull_summoned_weapon(*_args); end
      def push_summoned_weapon(*_args); end
      def shape_summoned_weapon(*_args); end
      def turn_summoned_weapon(*_args); end
    end
  end

  module DRCMM
    class << self
      def any_celestial_object?(*_args); false; end
      def bright_celestial_object?(*_args); false; end
      def hold_moon_weapon?(*_args); false; end
      def wear_moon_weapon?(*_args); false; end
      def moon_used_to_summon_weapon(*_args); end
      def get_telescope?(*_args); true; end
      def store_telescope?(*_args); true; end
      def store_div_tool?(*_args); true; end
      def observe(*_args); end
      def predict(*_args); end
      def study_sky(*_args); end
      def align(*_args); end
      def roll_bones(*_args); end
      def use_div_tool(*_args); end
      def center_telescope(*_args); end
      def peer_telescope(*_args); []; end
    end
  end

  module DRCTH
    class << self
      def sprinkle_holy_water?(*_args); true; end
      def wave_incense?(*_args); true; end
      def empty_cleric_hands(*_args); end
    end
  end

  module Lich
    module Messaging
      def self.msg(*_args); end
      def self.monsterbold(text); text; end
      def self.stream_window(*_args); end
    end

    module Util
      def self.issue_command(*_args); []; end
    end
  end
end
