# frozen_string_literal: true

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

module DRC
  class << self
    def bput(*_args)
      'Roundtime'
    end

    def message(*_args); end

    def fix_standing; end

    def retreat; end

    def right_hand
      $right_hand
    end

    def left_hand
      $left_hand
    end

    def right_hand_noun
      $right_hand
    end

    def left_hand_noun
      $left_hand
    end

    def wait_for_script_to_complete(*_args); end

    def hide?(*_args)
      true
    end
  end
end

module DRCI
  class << self
    def lower_item?(*_args)
      true
    end

    def get_item?(*_args)
      true
    end

    def get_item_unsafe(*_args)
      true
    end

    def dispose_trash(*_args); end

    def wear_item?(*_args)
      true
    end

    def put_away_item?(*_args)
      true
    end

    def in_hands?(*_args)
      false
    end

    def inside?(*_args)
      false
    end
  end
end

module DRCA
  class << self
    def prepare?(*_args)
      true
    end

    def cast?(*_args)
      true
    end

    def release_cyclics(*_args); end

    def cast_spell(*_args); end

    def shatter_regalia?(*_args); end

    def parse_regalia
      []
    end

    def check_elemental_charge
      0
    end

    def invoke(*_args); end

    def find_cambrinth(*_args); end

    def stow_cambrinth(*_args); end

    def check_to_harness(*_args)
      false
    end

    def segue?(*_args); end

    def activate_barb_buff?(*_args)
      true
    end

    def activate_khri?(*_args)
      true
    end

    def infuse_om(*_args); end

    def update_avtalia; end

    def perc_aura
      {}
    end
  end
end

module DRCH
  class << self
    def bind_wound(*_args); end

    def check_health
      { 'wounds' => {} }
    end

    def perceive_health
      { 'wounds' => {} }
    end

    def has_tendable_bleeders?
      false
    end
  end
end

module DRCMM
  class << self
    def wear_moon_weapon?
      false
    end

    def hold_moon_weapon?
      false
    end

    def moon_used_to_summon_weapon
      nil
    end

    def bright_celestial_object?
      false
    end

    def any_celestial_object?
      false
    end

    def peer_telescope(*_args); end
  end
end

module DRCS
  class << self
    def break_summoned_weapon(*_args); end

    def summon_weapon(*_args); end

    def shape_summoned_weapon(*_args); end

    def turn_summoned_weapon(*_args); end

    def push_summoned_weapon(*_args); end

    def pull_summoned_weapon(*_args); end
  end
end

module DRCTH
  class << self
    def sprinkle_holy_water?(*_args)
      true
    end

    def wave_incense?(*_args)
      true
    end

    def empty_cleric_hands(*_args); end
  end
end

class Script
  def self.running?(*_args)
    false
  end
end

class UserVars
  class << self
    attr_accessor :moons unless method_defined?(:moons)
    attr_accessor :sun unless method_defined?(:sun)
    attr_accessor :discerns unless method_defined?(:discerns)
    attr_accessor :friends unless method_defined?(:friends)
  end
end

class DRSpells
  @@_known_spells = {}
  @@_slivers = false

  def self.known_spells
    @@_known_spells
  end

  def self._set_known_spells(val)
    @@_known_spells = val
  end

  def self.slivers
    @@_slivers
  end

  def self._set_slivers(val)
    @@_slivers = val
  end
end

$HUNTING_BUDDY = nil
$COMBAT_TRAINER = nil
$debug_mode_ct = false
$ORDINALS = %w[first second third fourth fifth sixth seventh eighth ninth tenth]

# Globals used by GameState class body
$martial_skills ||= ['Brawling']
$edged_skills ||= ['Small Edged', 'Large Edged', 'Twohanded Edged']
$blunt_skills ||= ['Small Blunt', 'Large Blunt', 'Twohanded Blunt']
$staff_skills ||= ['Staves']
$polearm_skills ||= ['Polearms']
$melee_skills ||= $edged_skills + $blunt_skills + $staff_skills + $polearm_skills + ['Melee Mastery']
$thrown_skills ||= ['Heavy Thrown', 'Light Thrown', 'Missile Mastery']
$twohanded_skills ||= ['Twohanded Edged', 'Twohanded Blunt']
$aim_skills ||= ['Bow', 'Slings', 'Crossbow']
$ranged_skills ||= $thrown_skills + $aim_skills + ['Missile Mastery']
$non_dance_skills ||= $ranged_skills + ['Brawling', 'Offhand Weapon']
$tactics_actions ||= %w[bob weave circle]
$weapon_buffs ||= ['Ignite', "Rutilor's Edge", 'Resonance']

load_lic_class('combat-trainer.lic', 'GameState')
load_lic_class('combat-trainer.lic', 'ManipulateProcess')
load_lic_class('combat-trainer.lic', 'AttackProcess')
load_lic_class('combat-trainer.lic', 'AbilityProcess')

RSpec.configure do |config|
  config.before(:each) do
    reset_data
    DRSpells._set_known_spells({})
    DRSpells._set_slivers(false)
    UserVars.moons = { 'visible' => [] }
    UserVars.sun = { 'night' => false, 'day' => true }
    UserVars.discerns = {}
    UserVars.friends = []
    $HUNTING_BUDDY = double('HuntingBuddy', stop_hunting: nil)
    $COMBAT_TRAINER = double('CombatTrainer', stop: nil)
    $right_hand = nil
    $left_hand = nil
  end
end

# ------------------------------------------------------------------
# GameState
# ------------------------------------------------------------------

RSpec.describe GameState do
  def build_game_state(**overrides)
    instance = GameState.allocate
    defaults = {
      is_empath: false,
      is_permashocked: false,
      construct_mode: false,
      undead_mode: false,
      innocence_mode: false,
      ignored_npcs: [],
      dance_threshold: 1,
      retreat_threshold: nil,
      cached_npcs: nil,
      dancing: false,
      retreating: false,
      rush_shield: nil,
      rush_to_engage: false,
      rush_retreat_skip: false,
      rush_engage_only: false,
      stomp_to_engage: false,
      stomp_on_cooldown: false,
      pounce_on_cooldown: false,
      pounce_to_engage: false,
      charged_maneuvers: {},
      cooldown_timers: {},
      current_weapon_skill: nil,
      weapon_training: {},
      clean_up_step: nil
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  # ---- is_permashocked? ----

  describe '#is_permashocked?' do
    it 'returns true for non-empaths' do
      gs = build_game_state(is_empath: false)
      expect(gs.is_permashocked?).to be true
    end

    it 'returns true for empaths with permashocked setting' do
      gs = build_game_state(is_empath: true, is_permashocked: true)
      expect(gs.is_permashocked?).to be true
    end

    it 'returns false for empaths without permashocked setting' do
      gs = build_game_state(is_empath: true, is_permashocked: false)
      expect(gs.is_permashocked?).to be false
    end
  end

  # ---- is_offense_allowed? ----

  describe '#is_offense_allowed?' do
    it 'returns true for non-empaths' do
      gs = build_game_state(is_empath: false)
      expect(gs.is_offense_allowed?).to be true
    end

    it 'returns true for permashocked empaths' do
      gs = build_game_state(is_empath: true, is_permashocked: true)
      expect(gs.is_offense_allowed?).to be true
    end

    it 'returns true for empaths in construct mode' do
      gs = build_game_state(is_empath: true, construct_mode: true)
      expect(gs.is_offense_allowed?).to be true
    end

    it 'returns true for empaths in undead mode with Absolution active' do
      gs = build_game_state(is_empath: true, undead_mode: true)
      allow(DRSpells).to receive(:active_spells).and_return({ 'Absolution' => 100 })
      expect(gs.is_offense_allowed?).to be true
    end

    it 'returns false for empaths in undead mode without Absolution' do
      gs = build_game_state(is_empath: true, undead_mode: true)
      allow(DRSpells).to receive(:active_spells).and_return({})
      expect(gs.is_offense_allowed?).to be false
    end

    it 'returns false for empaths with no offense flags' do
      gs = build_game_state(is_empath: true, is_permashocked: false, construct_mode: false, undead_mode: false)
      allow(DRSpells).to receive(:active_spells).and_return({})
      expect(gs.is_offense_allowed?).to be false
    end

    it 'returns false when ALL offense flags are explicitly false' do
      gs = build_game_state(
        is_empath: true,
        is_permashocked: false,
        construct_mode: false,
        undead_mode: false
      )
      allow(DRSpells).to receive(:active_spells).and_return({})
      expect(gs.is_offense_allowed?).to be false
    end
  end

  # ---- can_face? / can_engage? ----

  describe '#can_face?' do
    it 'returns false when innocence mode is active' do
      gs = build_game_state(innocence_mode: true)
      DRRoom.npcs = ['rat']
      expect(gs.can_face?).to be false
    end

    it 'returns false when npcs list is empty' do
      gs = build_game_state(innocence_mode: false, cached_npcs: [])
      DRRoom.npcs = []
      expect(gs.can_face?).to be false
    end

    it 'returns true when npcs present and no innocence' do
      gs = build_game_state(innocence_mode: false)
      DRRoom.npcs = ['rat']
      gs.instance_variable_set(:@cached_npcs, ['rat'])
      expect(gs.can_face?).to be true
    end
  end

  describe '#can_engage?' do
    it 'returns false when can_face? is false' do
      gs = build_game_state(innocence_mode: true)
      expect(gs.can_engage?).to be false
    end

    it 'returns false when retreating' do
      gs = build_game_state(retreating: true, cached_npcs: ['rat'])
      DRRoom.npcs = ['rat']
      expect(gs.can_engage?).to be false
    end

    it 'returns true when npcs present, not retreating, not innocent' do
      gs = build_game_state(innocence_mode: false, retreating: false, cached_npcs: ['rat'])
      DRRoom.npcs = ['rat']
      expect(gs.can_engage?).to be true
    end
  end

  # ---- NPC caching ----

  describe '#update_room_npcs' do
    it 'caches npcs minus ignored' do
      DRRoom.npcs = ['rat', 'kobold', 'gremlin']
      gs = build_game_state(ignored_npcs: ['gremlin'], dance_threshold: 1)
      gs.update_room_npcs
      expect(gs.npcs).to eq(['rat', 'kobold'])
    end

    it 'sets dancing when npcs count <= dance_threshold' do
      DRRoom.npcs = ['rat']
      gs = build_game_state(ignored_npcs: [], dance_threshold: 1)
      gs.update_room_npcs
      expect(gs.dancing?).to be true
    end

    it 'sets dancing when npcs are empty' do
      DRRoom.npcs = []
      gs = build_game_state(ignored_npcs: [], dance_threshold: 1)
      gs.update_room_npcs
      expect(gs.dancing?).to be true
    end

    it 'clears dancing when npcs exceed dance_threshold' do
      DRRoom.npcs = %w[rat kobold gremlin]
      gs = build_game_state(ignored_npcs: [], dance_threshold: 1)
      gs.update_room_npcs
      expect(gs.dancing?).to be false
    end

    it 'sets retreating when npcs >= retreat_threshold' do
      DRRoom.npcs = %w[rat kobold gremlin]
      gs = build_game_state(ignored_npcs: [], dance_threshold: 0, retreat_threshold: 3)
      gs.update_room_npcs
      expect(gs.retreating?).to be true
    end

    it 'does not set retreating when retreat_threshold is nil' do
      DRRoom.npcs = %w[rat kobold gremlin]
      gs = build_game_state(ignored_npcs: [], dance_threshold: 0, retreat_threshold: nil)
      gs.update_room_npcs
      expect(gs.retreating?).to be_falsy
    end

    it 'sets dancing when dance_threshold is 0 and room is empty' do
      DRRoom.npcs = []
      gs = build_game_state(ignored_npcs: [], dance_threshold: 0)
      gs.update_room_npcs
      expect(gs.dancing?).to be true
    end

    it 'handles retreat_threshold equal to npc count (boundary)' do
      DRRoom.npcs = %w[rat kobold]
      gs = build_game_state(ignored_npcs: [], dance_threshold: 0, retreat_threshold: 2)
      gs.update_room_npcs
      expect(gs.retreating?).to be true
    end
  end

  describe '#npcs' do
    it 'recomputes npcs from DRRoom on every call' do
      DRRoom.npcs = ['rat', 'kobold']
      gs = build_game_state(ignored_npcs: [])
      expect(gs.npcs).to eq(['rat', 'kobold'])
      DRRoom.npcs = ['something_else']
      expect(gs.npcs).to eq(['something_else'])
    end

    it 'filters out ignored_npcs' do
      DRRoom.npcs = ['rat', 'kobold']
      gs = build_game_state(ignored_npcs: ['kobold'])
      expect(gs.npcs).to eq(['rat'])
    end
  end

  # ---- engage chain ----

  describe '#rush' do
    it 'returns false when is_offense_allowed? is false' do
      gs = build_game_state(
        is_empath: true, is_permashocked: false, construct_mode: false, undead_mode: false,
        rush_shield: 'shield', rush_to_engage: true, cached_npcs: ['rat'],
        charged_maneuvers: { 'Shield Usage' => 'rush' }, cooldown_timers: {}
      )
      allow(DRSpells).to receive(:active_spells).and_return({})
      allow(gs).to receive(:retreating?).and_return(false)
      allow(gs).to receive(:loaded).and_return(false)
      allow(gs).to receive(:charged_maneuver_off_cooldown?).and_return(true)
      expect(gs.rush).to be false
    end

    it 'returns false when retreating' do
      gs = build_game_state(is_empath: false, retreating: true, rush_shield: 'shield')
      allow(gs).to receive(:retreating?).and_return(true)
      expect(gs.rush).to be_falsy
    end

    it 'returns false when left hand is occupied' do
      $left_hand = 'sword'
      gs = build_game_state(is_empath: false, rush_shield: 'shield')
      allow(gs).to receive(:retreating?).and_return(false)
      expect(gs.rush).to be false
    end

    it 'returns false when no rush_shield configured' do
      gs = build_game_state(is_empath: false, rush_shield: nil)
      allow(gs).to receive(:retreating?).and_return(false)
      expect(gs.rush).to be false
    end

    it 'returns false when no npcs present' do
      gs = build_game_state(is_empath: false, rush_shield: 'shield', rush_to_engage: true, cached_npcs: [])
      DRRoom.npcs = []
      allow(gs).to receive(:retreating?).and_return(false)
      allow(gs).to receive(:loaded).and_return(false)
      expect(gs.rush).to be false
    end

    it 'returns false when rush_to_engage is false' do
      gs = build_game_state(is_empath: false, rush_shield: 'shield', rush_to_engage: false, cached_npcs: ['rat'])
      DRRoom.npcs = ['rat']
      allow(gs).to receive(:retreating?).and_return(false)
      allow(gs).to receive(:loaded).and_return(false)
      expect(gs.rush).to be false
    end
  end

  describe '#stomp' do
    it 'returns false for non-barbarians' do
      DRStats.guild = 'Empath'
      gs = build_game_state(stomp_to_engage: true, cached_npcs: ['rat'])
      Flags['war-stomp-ready'] = true
      allow(gs).to receive(:retreating?).and_return(false)
      expect(gs.stomp).to be false
    end

    it 'returns false for barbarians below circle 100' do
      DRStats.guild = 'Barbarian'
      DRStats.circle = 50
      gs = build_game_state(stomp_to_engage: true, cached_npcs: ['rat'])
      Flags['war-stomp-ready'] = true
      allow(gs).to receive(:retreating?).and_return(false)
      expect(gs.stomp).to be false
    end

    it 'returns false when no npcs present' do
      DRStats.guild = 'Barbarian'
      DRStats.circle = 100
      gs = build_game_state(stomp_to_engage: true, cached_npcs: [])
      DRRoom.npcs = []
      Flags['war-stomp-ready'] = true
      allow(gs).to receive(:retreating?).and_return(false)
      expect(gs.stomp).to be false
    end

    it 'returns false when neither stomp setting is enabled' do
      DRStats.guild = 'Barbarian'
      DRStats.circle = 100
      gs = build_game_state(stomp_to_engage: false, stomp_on_cooldown: false, cached_npcs: ['rat'])
      DRRoom.npcs = ['rat']
      Flags['war-stomp-ready'] = true
      allow(gs).to receive(:retreating?).and_return(false)
      expect(gs.stomp).to be false
    end

    it 'returns false when war-stomp-ready flag is not set' do
      DRStats.guild = 'Barbarian'
      DRStats.circle = 100
      gs = build_game_state(stomp_to_engage: true, cached_npcs: ['rat'])
      DRRoom.npcs = ['rat']
      Flags['war-stomp-ready'] = false
      allow(gs).to receive(:retreating?).and_return(false)
      expect(gs.stomp).to be false
    end
  end

  describe '#pounce' do
    it 'returns false for non-rangers' do
      DRStats.guild = 'Barbarian'
      gs = build_game_state(pounce_on_cooldown: true, pounce_to_engage: true, cached_npcs: ['rat'])
      Flags['pounce-ready'] = true
      allow(gs).to receive(:retreating?).and_return(false)
      expect(gs.pounce).to be false
    end

    it 'returns false when no npcs present' do
      DRStats.guild = 'Ranger'
      gs = build_game_state(pounce_on_cooldown: true, pounce_to_engage: true, cached_npcs: [])
      DRRoom.npcs = []
      Flags['pounce-ready'] = true
      allow(gs).to receive(:retreating?).and_return(false)
      expect(gs.pounce).to be false
    end

    it 'returns false when cooldown flag is not ready' do
      DRStats.guild = 'Ranger'
      gs = build_game_state(pounce_on_cooldown: true, pounce_to_engage: true, cached_npcs: ['rat'])
      DRRoom.npcs = ['rat']
      Flags['pounce-ready'] = false
      allow(gs).to receive(:retreating?).and_return(false)
      expect(gs.pounce).to be false
    end
  end
end

# ------------------------------------------------------------------
# ManipulateProcess
# ------------------------------------------------------------------

RSpec.describe ManipulateProcess do
  def build_manipulate_process(**overrides)
    instance = ManipulateProcess.allocate
    defaults = {
      threshold: 2,
      manip_to_train: false,
      last_manip: Time.now - 200
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  def build_game_state_double(**attrs)
    defaults = {
      danger: false,
      construct_mode?: false,
      npcs: ['rat', 'kobold']
    }
    double('GameState', defaults.merge(attrs))
  end

  describe '#execute' do
    it 'skips when danger is true' do
      mp = build_manipulate_process
      gs = build_game_state_double(danger: true)
      expect(mp).not_to receive(:manipulate)
      mp.execute(gs)
    end

    it 'skips when threshold is nil' do
      mp = build_manipulate_process(threshold: nil)
      gs = build_game_state_double
      expect(mp).not_to receive(:manipulate)
      mp.execute(gs)
    end

    it 'skips when construct_mode is true' do
      mp = build_manipulate_process
      gs = build_game_state_double(construct_mode?: true)
      expect(mp).not_to receive(:manipulate)
      mp.execute(gs)
    end

    it 'skips when empathy XP > 30 and manip_to_train is true' do
      allow(DRSkill).to receive(:getxp).with('Empathy').and_return(31)
      mp = build_manipulate_process(manip_to_train: true)
      gs = build_game_state_double
      mp.execute(gs)
      expect(mp.instance_variable_get(:@threshold)).not_to be_nil
    end

    it 'manipulates when npcs >= threshold and cooldown elapsed' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      allow(DRC).to receive(:bput).and_return('You attempt to empathically manipulate')
      mp = build_manipulate_process(threshold: 2, last_manip: Time.now - 200)
      gs = build_game_state_double(npcs: %w[rat kobold])
      allow(gs).to receive(:construct?).and_return(false)
      mp.execute(gs)
      expect(mp.instance_variable_get(:@last_manip)).to be_within(2).of(Time.now)
    end

    it 'does not manipulate when cooldown has not elapsed' do
      mp = build_manipulate_process(threshold: 2, last_manip: Time.now)
      gs = build_game_state_double(npcs: %w[rat kobold])
      mp.execute(gs)
      expect(mp.instance_variable_get(:@last_manip)).to be_within(2).of(Time.now)
    end

    it 'detects shock and disables threshold' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      allow(DRC).to receive(:bput).and_return('deep sense of loss')
      allow(DRC).to receive(:message)
      mp = build_manipulate_process(threshold: 1, last_manip: Time.now - 200)
      gs = build_game_state_double(npcs: ['rat'])
      allow(gs).to receive(:construct?).and_return(false)
      mp.execute(gs)
      expect(mp.instance_variable_get(:@threshold)).to be_nil
    end

    it 'marks NPC as construct on life essence message' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      allow(DRC).to receive(:bput).and_return('does not seem to have a life essence')
      mp = build_manipulate_process(threshold: 1, last_manip: Time.now - 200)
      gs = build_game_state_double(npcs: ['golem'])
      allow(gs).to receive(:construct?).and_return(false)
      expect(gs).to receive(:construct).with('golem')
      mp.execute(gs)
    end

    it 'with threshold 0 enters manipulate but loop body is a no-op on empty npcs' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      allow(DRC).to receive(:bput).and_return("But you aren't manipulating anything")
      mp = build_manipulate_process(threshold: 0, last_manip: Time.now - 200)
      gs = build_game_state_double(npcs: [])
      mp.execute(gs)
      expect(mp.instance_variable_get(:@last_manip)).to be_within(2).of(Time.now)
    end
  end
end

# ------------------------------------------------------------------
# AttackProcess
# ------------------------------------------------------------------

RSpec.describe AttackProcess do
  def build_attack_process(**overrides)
    instance = AttackProcess.allocate
    defaults = {
      fatigue_regen_action: 'bob',
      stealth_attack_aimed_action: nil,
      hide_type: 'hide',
      offhand_thrown: false,
      ambush_location: nil,
      get_actions: %w[get wield],
      rt_actions: %w[gouge attack jab feint draw lunge slice lob throw],
      stow_actions: %w[stow sheath put],
      use_overrides_for_aiming_trainables: false,
      firing_delay: 0,
      firing_timer: Time.now,
      firing_check: 0
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    allow(instance).to receive(:waitrt?)
    instance
  end

  def build_game_state_double(**attrs)
    defaults = {
      dancing?: false,
      weapon_skill: 'Small Edged',
      weapon_name: 'sword',
      is_offense_allowed?: true,
      finish_killing?: false,
      npcs: ['rat'],
      no_stab_current_mob: false,
      mob_died: false,
      stabbable?: true,
      thrown_skill?: false,
      aimed_skill?: false,
      fatigue_low?: false,
      retreating?: false,
      loaded: false,
      melee_weapon_skill?: true,
      offhand?: false,
      brawling?: false,
      backstab?: false,
      use_stealth_attack?: false,
      ambush?: false,
      ambush_stun_training?: false,
      determine_charged_maneuver: nil,
      reset_barb_whirlwind_flags_if_needed: nil,
      action_taken: nil,
      can_engage?: true,
      use_weak_attacks?: false,
      attack_override: 'attack',
      melee_attack_verb: 'attack',
      engage: nil,
      set_dance_queue: nil,
      next_dance_action: 'bob',
      next_clean_up_step: nil
    }
    double('GameState', defaults.merge(attrs))
  end

  describe '#execute' do
    before(:each) do
      Flags.add('ct-face-what', 'Face what')
      Flags.add('ct-ranged-ammo', 'ammo pattern')
      Flags.add('ct-powershot-ammo', 'powershot')
      Flags.add('ct-ranged-loaded', 'loaded')
      Flags.add('ct-using-repeating-crossbow', /repeating/)
      Flags.add('ct-aim-failed', 'stop aiming')
      Flags.add('ct-ranged-ready', 'best shot')
      Flags.add('war-stomp-ready', 'ready')
      Flags.add('pounce-ready', 'ready')
      Flags.add('ct-maneuver-cooldown-reduced', 'expert skill')
      Flags.add('ct-attack-out-of-range', 'not close enough')
    end

    it 'dances when is_offense_allowed? is false' do
      ap = build_attack_process
      gs = build_game_state_double(is_offense_allowed?: false, can_engage?: true)
      allow(DRC).to receive(:bput).and_return('Roundtime')

      ap.execute(gs)

      expect(gs).to have_received(:set_dance_queue)
    end

    it 'dances when weapon_skill is nil' do
      ap = build_attack_process
      gs = build_game_state_double(weapon_skill: nil, can_engage?: true)
      allow(DRC).to receive(:bput).and_return('Roundtime')

      ap.execute(gs)

      expect(gs).to have_received(:set_dance_queue)
    end

    it 'dances when weapon_skill is Targeted Magic' do
      ap = build_attack_process
      gs = build_game_state_double(weapon_skill: 'Targeted Magic', can_engage?: true)
      allow(DRC).to receive(:bput).and_return('Roundtime')

      ap.execute(gs)

      expect(gs).to have_received(:set_dance_queue)
    end

    it 'dances when dancing? is true' do
      ap = build_attack_process
      gs = build_game_state_double(dancing?: true, can_engage?: true)
      allow(DRC).to receive(:bput).and_return('Roundtime')

      ap.execute(gs)

      expect(gs).to have_received(:set_dance_queue)
    end

    it 'calls next_clean_up_step when finish_killing and not offense_allowed' do
      ap = build_attack_process
      gs = build_game_state_double(is_offense_allowed?: false, finish_killing?: true)

      ap.execute(gs)

      expect(gs).to have_received(:next_clean_up_step)
    end

    it 'attacks melee when melee skill equipped and offense allowed' do
      ap = build_attack_process
      gs = build_game_state_double(
        weapon_skill: 'Small Edged',
        is_offense_allowed?: true,
        thrown_skill?: false,
        aimed_skill?: false,
        can_engage?: true
      )
      allow(gs).to receive(:loaded=)
      allow(DRC).to receive(:bput).and_return('Roundtime')

      result = ap.execute(gs)

      expect(result).to be false
    end
  end
end

# ------------------------------------------------------------------
# AbilityProcess (init-time guild gates)
# ------------------------------------------------------------------

RSpec.describe AbilityProcess do
  def build_ability_process(**overrides)
    instance = AbilityProcess.allocate
    defaults = {
      can_stomp: false,
      can_pounce: false,
      paladin_use_badge: false,
      yiamura_exists: false,
      buffs: {},
      khri: [],
      khri_adaptation: '',
      barb_buffs: [],
      battle_cries: [],
      battle_cry_cycle: [],
      battle_cry_cooldown: 120,
      warhorn_or_egg: nil,
      stomp_on_cooldown: false,
      pounce_on_cooldown: false,
      barb_buffs_inner_fire_threshold: 50,
      meditation_pause_timer: nil,
      roar_helm_noun: nil
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  def build_game_state_double(**attrs)
    defaults = {
      npcs: ['rat'],
      cooldown_timers: {},
      can_face?: true,
      danger: false,
      stomp: nil,
      pounce: nil,
      melee_weapon_skill?: true
    }
    double('GameState', defaults.merge(attrs))
  end

  describe '#execute' do
    it 'fires stomp for barbarian with stomp_on_cooldown and npcs and flag ready' do
      DRStats.guild = 'Barbarian'
      Flags.add('war-stomp-ready', 'ready')
      Flags['war-stomp-ready'] = true
      ap = build_ability_process(stomp_on_cooldown: true)
      gs = build_game_state_double(npcs: ['rat'])
      allow(gs).to receive(:npcs).and_return(['rat'])

      ap.execute(gs)

      expect(gs).to have_received(:stomp)
    end

    it 'does NOT fire stomp for non-barbarians' do
      DRStats.guild = 'Ranger'
      Flags.add('war-stomp-ready', 'ready')
      Flags['war-stomp-ready'] = true
      ap = build_ability_process(stomp_on_cooldown: true)
      gs = build_game_state_double(npcs: ['rat'])
      allow(gs).to receive(:npcs).and_return(['rat'])

      ap.execute(gs)

      expect(gs).not_to have_received(:stomp)
    end

    it 'does NOT fire stomp when stomp_on_cooldown is false' do
      DRStats.guild = 'Barbarian'
      Flags.add('war-stomp-ready', 'ready')
      Flags['war-stomp-ready'] = true
      ap = build_ability_process(stomp_on_cooldown: false)
      gs = build_game_state_double(npcs: ['rat'])
      allow(gs).to receive(:npcs).and_return(['rat'])

      ap.execute(gs)

      expect(gs).not_to have_received(:stomp)
    end

    it 'fires pounce for ranger with pounce_on_cooldown and npcs and flag ready' do
      DRStats.guild = 'Ranger'
      Flags.add('pounce-ready', 'ready')
      Flags['pounce-ready'] = true
      ap = build_ability_process(pounce_on_cooldown: true)
      gs = build_game_state_double(npcs: ['rat'])
      allow(gs).to receive(:npcs).and_return(['rat'])

      ap.execute(gs)

      expect(gs).to have_received(:pounce)
    end

    it 'does NOT fire pounce for non-rangers' do
      DRStats.guild = 'Barbarian'
      Flags.add('pounce-ready', 'ready')
      Flags['pounce-ready'] = true
      ap = build_ability_process(pounce_on_cooldown: true)
      gs = build_game_state_double(npcs: ['rat'])
      allow(gs).to receive(:npcs).and_return(['rat'])

      ap.execute(gs)

      expect(gs).not_to have_received(:pounce)
    end
  end
end

# ------------------------------------------------------------------
# Boundary and adversarial edge cases
# ------------------------------------------------------------------

RSpec.describe 'Adversarial edge cases' do
  describe 'empath offense gating edge cases' do
    def build_game_state(**overrides)
      instance = GameState.allocate
      defaults = {
        is_empath: true,
        is_permashocked: false,
        construct_mode: false,
        undead_mode: false,
        innocence_mode: false,
        ignored_npcs: [],
        dance_threshold: 1,
        retreat_threshold: nil,
        cached_npcs: ['rat'],
        dancing: false,
        retreating: false,
        rush_shield: nil,
        rush_to_engage: false,
        rush_retreat_skip: false,
        rush_engage_only: false,
        stomp_to_engage: false,
        stomp_on_cooldown: false,
        pounce_on_cooldown: false,
        pounce_to_engage: false,
        charged_maneuvers: {},
        cooldown_timers: {},
        current_weapon_skill: nil,
        weapon_training: {},
        clean_up_step: nil
      }
      defaults.merge(overrides).each do |k, v|
        instance.instance_variable_set(:"@#{k}", v)
      end
      instance
    end

    it 'non-permashocked empath with construct mode can attack but shock warning still drops spells' do
      gs = build_game_state(is_empath: true, construct_mode: true)
      expect(gs.is_offense_allowed?).to be true
      expect(gs.is_permashocked?).to be false
    end

    it 'permashocked empath bypasses both offense and shock gates' do
      gs = build_game_state(is_empath: true, is_permashocked: true)
      expect(gs.is_offense_allowed?).to be true
      expect(gs.is_permashocked?).to be true
    end

    it 'empath in undead mode but Absolution dropped mid-hunt blocks offense' do
      gs = build_game_state(is_empath: true, undead_mode: true)
      allow(DRSpells).to receive(:active_spells).and_return({ 'Absolution' => 100 })
      expect(gs.is_offense_allowed?).to be true

      allow(DRSpells).to receive(:active_spells).and_return({})
      expect(gs.is_offense_allowed?).to be false
    end

    it 'rush is blocked for non-permashocked empath even with all rush settings configured' do
      gs = build_game_state(
        is_empath: true, is_permashocked: false, construct_mode: false, undead_mode: false,
        rush_shield: 'shield', rush_to_engage: true, cached_npcs: ['rat'],
        charged_maneuvers: { 'Shield Usage' => 'rush' }
      )
      allow(DRSpells).to receive(:active_spells).and_return({})
      allow(gs).to receive(:retreating?).and_return(false)
      allow(gs).to receive(:loaded).and_return(false)
      allow(gs).to receive(:charged_maneuver_off_cooldown?).and_return(true)
      expect(gs.rush).to be false
    end
  end

  describe 'NPC boundary conditions' do
    def build_game_state(**overrides)
      instance = GameState.allocate
      defaults = {
        is_empath: false, is_permashocked: false, construct_mode: false, undead_mode: false,
        innocence_mode: false, ignored_npcs: [], dance_threshold: 0, retreat_threshold: nil,
        cached_npcs: nil, dancing: false, retreating: false,
        rush_shield: nil, rush_to_engage: false, rush_retreat_skip: false, rush_engage_only: false,
        stomp_to_engage: false, stomp_on_cooldown: false,
        pounce_on_cooldown: false, pounce_to_engage: false,
        charged_maneuvers: {}, cooldown_timers: {},
        current_weapon_skill: nil, weapon_training: {}, clean_up_step: nil
      }
      defaults.merge(overrides).each do |k, v|
        instance.instance_variable_set(:"@#{k}", v)
      end
      instance
    end

    it 'all ignored_npcs filters everything' do
      DRRoom.npcs = %w[rat kobold]
      gs = build_game_state(ignored_npcs: %w[rat kobold], dance_threshold: 0)
      gs.update_room_npcs
      expect(gs.npcs).to eq([])
      expect(gs.dancing?).to be true
    end

    it 'dance_threshold 0 with exactly 1 npc is NOT dancing' do
      DRRoom.npcs = ['rat']
      gs = build_game_state(dance_threshold: 0)
      gs.update_room_npcs
      expect(gs.dancing?).to be false
    end

    it 'dance_threshold 1 with exactly 1 npc IS dancing' do
      DRRoom.npcs = ['rat']
      gs = build_game_state(dance_threshold: 1)
      gs.update_room_npcs
      expect(gs.dancing?).to be true
    end

    it 'retreat_threshold 1 with exactly 1 npc IS retreating' do
      DRRoom.npcs = ['rat']
      gs = build_game_state(dance_threshold: 0, retreat_threshold: 1)
      gs.update_room_npcs
      expect(gs.retreating?).to be true
    end
  end
end
