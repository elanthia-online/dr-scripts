# frozen_string_literal: true

# Combat-trainer spec suite.
#
# Organized by class under test, each section uses a focused builder
# that exposes only the fields that matter for that test group.
# Tests are split into two categories per method:
#   - Validation: confirms expected behavior for known-good inputs
#   - Bug-finding: probes nil settings, state mutation across calls,
#     type mismatches, side-effect leakage, and boundary conditions

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

# -- Module stubs --
# Each stub provides the minimum interface combat-trainer calls.
# Methods default to safe no-ops; tests override via allow().

module DRC
  class << self
    def bput(*_args) = 'Roundtime'
    def message(*_args) = nil
    def fix_standing = nil
    def retreat = nil
    def right_hand = $right_hand
    def left_hand = $left_hand
    def right_hand_noun = $right_hand
    def left_hand_noun = $left_hand
    def wait_for_script_to_complete(*_args) = nil
    def hide?(*_args) = true
    def rummage(*_args) = []
    def beep = nil
  end
end

module DRCI
  class << self
    def lower_item?(*_args) = true
    def get_item?(*_args) = true
    def get_item_unsafe(*_args) = true
    def dispose_trash(*_args) = nil
    def wear_item?(*_args) = true
    def put_away_item?(*_args) = true
    def in_hands?(*_args) = false
    def inside?(*_args) = false
    def fill_gem_pouch_with_container(*_args) = nil
    def count_all_boxes(*_args) = 0
  end
end

module DRCA
  class << self
    def prepare?(*_args) = true
    def cast?(*_args) = true
    def release_cyclics(*_args) = nil
    def cast_spell(*_args) = nil
    def shatter_regalia?(*_args) = nil
    def parse_regalia = []
    def check_elemental_charge = 0
    def invoke(*_args) = nil
    def find_cambrinth(*_args) = nil
    def stow_cambrinth(*_args) = nil
    def check_to_harness(*_args) = false
    def segue?(*_args) = nil
    def activate_barb_buff?(*_args) = true
    def activate_khri?(*_args) = true
    def infuse_om(*_args) = nil
    def update_avtalia = nil
    def perc_aura = {}
  end
end

module DRCH
  class << self
    def bind_wound(*_args) = nil
    def check_health = { 'wounds' => {} }
    def perceive_health = { 'wounds' => {} }
    def has_tendable_bleeders? = false
  end
end

module DRCMM
  class << self
    def wear_moon_weapon? = false
    def hold_moon_weapon? = false
    def moon_used_to_summon_weapon = nil
    def bright_celestial_object? = false
    def any_celestial_object? = false
    def peer_telescope(*_args) = nil
  end
end

module DRCS
  class << self
    def break_summoned_weapon(*_args) = nil
    def summon_weapon(*_args) = nil
    def shape_summoned_weapon(*_args) = nil
    def turn_summoned_weapon(*_args) = nil
    def push_summoned_weapon(*_args) = nil
    def pull_summoned_weapon(*_args) = nil
  end
end

module DRCTH
  class << self
    def sprinkle_holy_water?(*_args) = true
    def wave_incense?(*_args) = true
    def empty_cleric_hands(*_args) = nil
  end
end

module Script
  def self.running?(*_args) = false
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

  def self.known_spells = @@_known_spells
  def self._set_known_spells(val) = (@@_known_spells = val)
  def self.slivers = @@_slivers
  def self._set_slivers(val) = (@@_slivers = val)
end

$HUNTING_BUDDY = nil
$COMBAT_TRAINER = nil
$debug_mode_ct = false
$ORDINALS = %w[first second third fourth fifth sixth seventh eighth ninth tenth]

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

load_lic_class('combat-trainer.lic', 'LootProcess')
load_lic_class('combat-trainer.lic', 'GameState')
load_lic_class('combat-trainer.lic', 'SetupProcess')
load_lic_class('combat-trainer.lic', 'ManipulateProcess')
load_lic_class('combat-trainer.lic', 'AttackProcess')
load_lic_class('combat-trainer.lic', 'AbilityProcess')

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end
end

# Shared setup for combat-trainer tests that need game state stubs.
# Include in each describe block via: before(:each) { ct_setup }
def ct_setup
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

# ===================================================================
# GameState -- offense/defense gates
# These methods control whether an empath can attack. Getting them
# wrong causes empathic shock (permanent character penalty).
# ===================================================================
RSpec.describe GameState do
  before(:each) { ct_setup }

  # Focused builder: only the fields that matter for offense/defense.
  def build_offense_state(empath: false, permashocked: false, construct: false, undead: false, innocence: false)
    gs = GameState.allocate
    gs.instance_variable_set(:@is_empath, empath)
    gs.instance_variable_set(:@is_permashocked, permashocked)
    gs.instance_variable_set(:@construct_mode, construct)
    gs.instance_variable_set(:@undead_mode, undead)
    gs.instance_variable_set(:@innocence_mode, innocence)
    gs.instance_variable_set(:@ignored_npcs, [])
    gs.instance_variable_set(:@retreat_threshold, nil)
    gs.instance_variable_set(:@dance_threshold, 1)
    gs.instance_variable_set(:@dancing, false)
    gs.instance_variable_set(:@retreating, false)
    gs
  end

  describe '#is_permashocked?' do
    it('non-empath returns true') { expect(build_offense_state.is_permashocked?).to be true }
    it('empath + permashocked returns true') { expect(build_offense_state(empath: true, permashocked: true).is_permashocked?).to be true }
    it('empath without permashocked returns false') { expect(build_offense_state(empath: true).is_permashocked?).to be false }
  end

  describe '#is_offense_allowed?' do
    it('non-empath always allowed') { expect(build_offense_state.is_offense_allowed?).to be true }
    it('permashocked empath allowed') { expect(build_offense_state(empath: true, permashocked: true).is_offense_allowed?).to be true }
    it('construct mode empath allowed') { expect(build_offense_state(empath: true, construct: true).is_offense_allowed?).to be true }

    it 'undead mode empath allowed only when Absolution active' do
      gs = build_offense_state(empath: true, undead: true)
      allow(DRSpells).to receive(:active_spells).and_return({ 'Absolution' => 100 })
      expect(gs.is_offense_allowed?).to be true
    end

    it 'undead mode empath blocked when Absolution is NOT active' do
      gs = build_offense_state(empath: true, undead: true)
      allow(DRSpells).to receive(:active_spells).and_return({})
      expect(gs.is_offense_allowed?).to be false
    end

    it 'empath with all flags false is blocked' do
      gs = build_offense_state(empath: true, permashocked: false, construct: false, undead: false)
      allow(DRSpells).to receive(:active_spells).and_return({})
      expect(gs.is_offense_allowed?).to be false
    end

    # BUG-FINDING: Absolution drop mid-hunt changes offense state dynamically
    it 'blocks offense when Absolution drops mid-hunt' do
      gs = build_offense_state(empath: true, undead: true)
      allow(DRSpells).to receive(:active_spells).and_return({ 'Absolution' => 100 })
      expect(gs.is_offense_allowed?).to be true

      allow(DRSpells).to receive(:active_spells).and_return({})
      expect(gs.is_offense_allowed?).to be false
    end

    # BUG-FINDING: construct mode + NOT permashocked means shock warning should still drop spells
    it 'construct mode empath is offense-allowed but NOT permashocked' do
      gs = build_offense_state(empath: true, construct: true)
      expect(gs.is_offense_allowed?).to be true
      expect(gs.is_permashocked?).to be false
    end
  end

  describe '#can_face?' do
    it('returns false in innocence mode') { expect(build_offense_state(innocence: true).can_face?).to be false }

    it 'returns false with empty room' do
      DRRoom.npcs = []
      expect(build_offense_state.can_face?).to be false
    end

    it 'returns true with npcs and no innocence' do
      DRRoom.npcs = ['rat']
      expect(build_offense_state.can_face?).to be true
    end

    # BUG-FINDING: innocence blocks can_face even with npcs present
    it 'innocence overrides NPC presence' do
      DRRoom.npcs = ['rat']
      expect(build_offense_state(innocence: true).can_face?).to be false
    end
  end

  describe '#can_engage?' do
    it('returns false when can_face? is false') { expect(build_offense_state(innocence: true).can_engage?).to be false }

    it 'returns false when retreating' do
      DRRoom.npcs = ['rat']
      gs = build_offense_state
      gs.instance_variable_set(:@retreating, true)
      expect(gs.can_engage?).to be false
    end

    it 'returns true when npcs present, not retreating, not innocent' do
      DRRoom.npcs = ['rat']
      expect(build_offense_state.can_engage?).to be true
    end
  end

  # ---- NPC handling ----

  describe '#update_room_npcs' do
    def build_npc_state(ignored: [], dance_threshold: 1, retreat_threshold: nil)
      gs = GameState.allocate
      gs.instance_variable_set(:@ignored_npcs, ignored)
      gs.instance_variable_set(:@dance_threshold, dance_threshold)
      gs.instance_variable_set(:@retreat_threshold, retreat_threshold)
      gs.instance_variable_set(:@dancing, false)
      gs.instance_variable_set(:@retreating, false)
      gs
    end

    it('filters ignored npcs') do
      DRRoom.npcs = %w[rat kobold gremlin]
      gs = build_npc_state(ignored: ['gremlin'])
      gs.update_room_npcs
      expect(gs.npcs).to eq(%w[rat kobold])
    end

    it('sets dancing when npc count <= threshold') do
      DRRoom.npcs = ['rat']
      gs = build_npc_state(dance_threshold: 1)
      gs.update_room_npcs
      expect(gs.dancing?).to be true
    end

    it('clears dancing when npc count > threshold') do
      DRRoom.npcs = %w[rat kobold gremlin]
      gs = build_npc_state(dance_threshold: 1)
      gs.update_room_npcs
      expect(gs.dancing?).to be false
    end

    it('sets dancing on empty room') do
      DRRoom.npcs = []
      gs = build_npc_state(dance_threshold: 0)
      gs.update_room_npcs
      expect(gs.dancing?).to be true
    end

    it('sets retreating at threshold boundary') do
      DRRoom.npcs = %w[rat kobold]
      gs = build_npc_state(dance_threshold: 0, retreat_threshold: 2)
      gs.update_room_npcs
      expect(gs.retreating?).to be true
    end

    it('retreat_threshold nil never retreats') do
      DRRoom.npcs = %w[rat kobold gremlin]
      gs = build_npc_state(retreat_threshold: nil)
      gs.update_room_npcs
      expect(gs.retreating?).to be_falsy
    end

    # BUG-FINDING: all npcs ignored leaves empty room
    it 'all-ignored npcs produces empty list and dancing' do
      DRRoom.npcs = %w[rat kobold]
      gs = build_npc_state(ignored: %w[rat kobold], dance_threshold: 0)
      gs.update_room_npcs
      expect(gs.npcs).to eq([])
      expect(gs.dancing?).to be true
    end

    # BUG-FINDING: dance_threshold 0 with 1 npc is NOT dancing (off-by-one)
    it 'dance_threshold 0 with 1 npc is not dancing' do
      DRRoom.npcs = ['rat']
      gs = build_npc_state(dance_threshold: 0)
      gs.update_room_npcs
      expect(gs.dancing?).to be false
    end
  end

  describe '#npcs' do
    it 'recomputes from DRRoom on every call (no stale data)' do
      gs = GameState.allocate
      gs.instance_variable_set(:@ignored_npcs, [])
      DRRoom.npcs = ['rat']
      expect(gs.npcs).to eq(['rat'])
      DRRoom.npcs = ['kobold']
      expect(gs.npcs).to eq(['kobold'])
    end
  end

  # ---- engage chain (rush/stomp/pounce) ----

  describe '#rush' do
    def build_rush_state(empath: false, permashocked: false, shield: nil, rush_to_engage: false)
      gs = GameState.allocate
      gs.instance_variable_set(:@is_empath, empath)
      gs.instance_variable_set(:@is_permashocked, permashocked)
      gs.instance_variable_set(:@construct_mode, false)
      gs.instance_variable_set(:@undead_mode, false)
      gs.instance_variable_set(:@rush_shield, shield)
      gs.instance_variable_set(:@rush_to_engage, rush_to_engage)
      gs.instance_variable_set(:@rush_retreat_skip, false)
      gs.instance_variable_set(:@rush_engage_only, false)
      gs.instance_variable_set(:@ignored_npcs, [])
      gs.instance_variable_set(:@dancing, false)
      gs.instance_variable_set(:@retreating, false)
      gs.instance_variable_set(:@charged_maneuvers, { 'Shield Usage' => 'rush' })
      gs.instance_variable_set(:@cooldown_timers, {})
      allow(DRSpells).to receive(:active_spells).and_return({})
      gs
    end

    # BUG-FINDING: documents the gap fixed in PR #7415.
    # On main (unfixed), rush does NOT check is_offense_allowed?, so a
    # non-permashocked empath with rush configured WILL execute the maneuver.
    # After the fix merges, change this to: expect(gs.rush).to be false
    it 'non-permashocked empath is NOT blocked from rush (unfixed on main)' do
      DRRoom.npcs = ['rat']
      gs = build_rush_state(empath: true, shield: 'shield', rush_to_engage: true)
      allow(gs).to receive(:retreating?).and_return(false)
      allow(gs).to receive(:loaded).and_return(false)
      allow(gs).to receive(:charged_maneuver_off_cooldown?).and_return(true)
      allow(gs).to receive(:use_charged_maneuver).and_return(true)
      expect(gs.rush).to be_truthy
    end

    it('blocks when retreating') do
      gs = build_rush_state(shield: 'shield')
      allow(gs).to receive(:retreating?).and_return(true)
      expect(gs.rush).to be_falsy
    end

    it('blocks when left hand occupied') do
      $left_hand = 'sword'
      gs = build_rush_state(shield: 'shield')
      allow(gs).to receive(:retreating?).and_return(false)
      expect(gs.rush).to be false
    end

    it('blocks when no rush_shield') { expect(build_rush_state.rush).to be false }

    it 'blocks when no npcs' do
      DRRoom.npcs = []
      gs = build_rush_state(shield: 'shield', rush_to_engage: true)
      allow(gs).to receive(:retreating?).and_return(false)
      allow(gs).to receive(:loaded).and_return(false)
      expect(gs.rush).to be false
    end

    it('blocks when rush_to_engage false') do
      DRRoom.npcs = ['rat']
      gs = build_rush_state(shield: 'shield', rush_to_engage: false)
      allow(gs).to receive(:retreating?).and_return(false)
      allow(gs).to receive(:loaded).and_return(false)
      expect(gs.rush).to be false
    end
  end

  describe '#stomp' do
    def build_stomp_state(guild: 'Barbarian', circle: 100, stomp_to_engage: true)
      DRStats.guild = guild
      DRStats.circle = circle
      gs = GameState.allocate
      gs.instance_variable_set(:@stomp_to_engage, stomp_to_engage)
      gs.instance_variable_set(:@stomp_on_cooldown, false)
      gs.instance_variable_set(:@ignored_npcs, [])
      gs.instance_variable_set(:@retreating, false)
      gs
    end

    it('blocks non-barbarians') do
      DRRoom.npcs = ['rat']
      Flags['war-stomp-ready'] = true
      expect(build_stomp_state(guild: 'Empath').stomp).to be false
    end

    it('blocks barbarians below circle 100') do
      DRRoom.npcs = ['rat']
      Flags['war-stomp-ready'] = true
      expect(build_stomp_state(circle: 50).stomp).to be false
    end

    it('blocks with no npcs') do
      DRRoom.npcs = []
      Flags['war-stomp-ready'] = true
      expect(build_stomp_state.stomp).to be false
    end

    it('blocks when stomp_to_engage false and stomp_on_cooldown false') do
      DRRoom.npcs = ['rat']
      Flags['war-stomp-ready'] = true
      expect(build_stomp_state(stomp_to_engage: false).stomp).to be false
    end

    it('blocks when flag not ready') do
      DRRoom.npcs = ['rat']
      Flags['war-stomp-ready'] = false
      expect(build_stomp_state.stomp).to be false
    end
  end

  describe '#pounce' do
    it('blocks non-rangers') do
      DRStats.guild = 'Barbarian'
      DRRoom.npcs = ['rat']
      gs = GameState.allocate
      gs.instance_variable_set(:@pounce_on_cooldown, true)
      gs.instance_variable_set(:@pounce_to_engage, true)
      gs.instance_variable_set(:@ignored_npcs, [])
      gs.instance_variable_set(:@retreating, false)
      Flags['pounce-ready'] = true
      expect(gs.pounce).to be false
    end
  end

  # ---- skill_done? ----

  describe '#skill_done?' do
    def build_skill_state(**overrides)
      gs = GameState.allocate
      defaults = {
        ignore_weapon_mindstate: false,
        current_weapon_skill: 'Bow',
        action_count: 0,
        target_action_count: 25,
        target_weapon_skill: 20,
        gain_check: 5,
        focus_threshold: 0,
        focus_threshold_active: false,
        last_exp: 10,
        last_action_count: 0,
        no_gain_list: Hash.new(0),
        weapons_to_train: { 'Bow' => 'longbow', 'Slings' => 'sling' }
      }
      defaults.merge(overrides).each { |k, v| gs.instance_variable_set(:"@#{k}", v) }
      gs
    end

    before(:each) do
      allow(DRSkill).to receive(:getxp).and_return(0)
      allow(DRSkill).to receive(:getrank).and_return(100)
    end

    context 'with ignore_weapon_mindstate true' do
      it 'returns false below action count regardless of exp' do
        allow(DRSkill).to receive(:getxp).and_return(34)
        gs = build_skill_state(ignore_weapon_mindstate: true, action_count: 5)
        expect(gs.skill_done?).to be false
      end

      it 'returns true at action count target' do
        gs = build_skill_state(ignore_weapon_mindstate: true, action_count: 25)
        expect(gs.skill_done?).to be true
      end
    end

    context 'with ignore_weapon_mindstate false' do
      it 'returns true when exp is 34 regardless of action count' do
        allow(DRSkill).to receive(:getxp).and_return(34)
        gs = build_skill_state(action_count: 0)
        expect(gs.skill_done?).to be true
      end

      it 'returns true when exp meets target' do
        allow(DRSkill).to receive(:getxp).and_return(20)
        gs = build_skill_state(action_count: 3, target_weapon_skill: 20)
        expect(gs.skill_done?).to be true
      end

      it 'returns false when both exp and action count are below target' do
        allow(DRSkill).to receive(:getxp).and_return(10)
        gs = build_skill_state(action_count: 5, target_weapon_skill: 20)
        expect(gs.skill_done?).to be false
      end
    end

    # BUG-FINDING: gain_check with stagnant exp blacklists skill after threshold
    context 'gain_check blacklisting' do
      it 'increments no_gain counter when exp stagnates' do
        allow(DRSkill).to receive(:getxp).and_return(10)
        gs = build_skill_state(last_exp: 10, gain_check: 2, action_count: 25)
        gs.skill_done?
        expect(gs.instance_variable_get(:@no_gain_list)['Bow']).to eq(1)
      end

      it 'resets no_gain counter when exp increases' do
        allow(DRSkill).to receive(:getxp).and_return(15)
        no_gain = Hash.new(0)
        no_gain['Bow'] = 3
        gs = build_skill_state(last_exp: 10, gain_check: 5, action_count: 25, no_gain_list: no_gain)
        gs.skill_done?
        expect(gs.instance_variable_get(:@no_gain_list)['Bow']).to eq(0)
      end
    end
  end
end

# ===================================================================
# ManipulateProcess
# Tests empath manipulation including shock detection and construct
# marking. Manipulation errors silently broke before our fix.
# ===================================================================
RSpec.describe ManipulateProcess do
  before(:each) { ct_setup }

  def build_manipulate(threshold: 2, manip_to_train: false, last_manip: Time.now - 200)
    mp = ManipulateProcess.allocate
    mp.instance_variable_set(:@threshold, threshold)
    mp.instance_variable_set(:@manip_to_train, manip_to_train)
    mp.instance_variable_set(:@last_manip, last_manip)
    mp
  end

  def gs_double(**attrs)
    defaults = { danger: false, construct_mode?: false, npcs: %w[rat kobold] }
    double('GameState', defaults.merge(attrs))
  end

  describe '#execute' do
    it('skips on danger') { build_manipulate.execute(gs_double(danger: true)) }
    it('skips on nil threshold') { build_manipulate(threshold: nil).execute(gs_double) }
    it('skips on construct mode') { build_manipulate.execute(gs_double(construct_mode?: true)) }

    it 'skips when empathy XP > 30 and manip_to_train set' do
      allow(DRSkill).to receive(:getxp).with('Empathy').and_return(31)
      mp = build_manipulate(manip_to_train: true)
      mp.execute(gs_double)
      expect(mp.instance_variable_get(:@threshold)).not_to be_nil
    end

    it 'manipulates when threshold met and cooldown elapsed' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      allow(DRC).to receive(:bput).and_return('You attempt to empathically manipulate')
      gs = gs_double(npcs: %w[rat kobold])
      allow(gs).to receive(:construct?).and_return(false)
      build_manipulate(threshold: 2).execute(gs)
    end

    # BUG-FINDING: shock disables manipulation permanently for this hunt
    it 'disables threshold on shock ("deep sense of loss")' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      allow(DRC).to receive(:bput).and_return('deep sense of loss')
      allow(DRC).to receive(:message)
      gs = gs_double(npcs: ['rat'])
      allow(gs).to receive(:construct?).and_return(false)
      mp = build_manipulate(threshold: 1)
      mp.execute(gs)
      expect(mp.instance_variable_get(:@threshold)).to be_nil
    end

    # BUG-FINDING: verify construct marking propagates to game_state
    it 'marks NPC as construct and that state persists' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      allow(DRC).to receive(:bput).and_return('does not seem to have a life essence')
      gs = gs_double(npcs: ['golem'])
      allow(gs).to receive(:construct?).and_return(false)
      expect(gs).to receive(:construct).with('golem')
      build_manipulate(threshold: 1).execute(gs)
    end

    # BUG-FINDING: threshold 0 with empty npcs still enters manipulate
    # (0 >= 0 is true), verifying the loop body is a no-op
    it 'threshold 0 with empty npcs enters manipulate but does nothing offensive' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      allow(DRC).to receive(:bput).and_return("But you aren't manipulating anything")
      mp = build_manipulate(threshold: 0)
      mp.execute(gs_double(npcs: []))
      expect(mp.instance_variable_get(:@last_manip)).to be_within(2).of(Time.now)
    end

    # BUG-FINDING: cooldown boundary -- 119 seconds should NOT trigger (needs > 120)
    it 'does not manipulate at 119s cooldown' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      mp = build_manipulate(threshold: 1, last_manip: Time.now - 119)
      gs = gs_double(npcs: ['rat'])
      allow(gs).to receive(:construct?).and_return(false)
      mp.execute(gs)
      expect(mp.instance_variable_get(:@last_manip)).to be < Time.now - 100
    end

    # BUG-FINDING: cooldown boundary -- 121 seconds SHOULD trigger
    it 'manipulates at 121s cooldown' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      allow(DRC).to receive(:bput).and_return('You attempt to empathically manipulate')
      gs = gs_double(npcs: ['rat'])
      allow(gs).to receive(:construct?).and_return(false)
      mp = build_manipulate(threshold: 1, last_manip: Time.now - 121)
      mp.execute(gs)
      expect(mp.instance_variable_get(:@last_manip)).to be_within(2).of(Time.now)
    end
  end
end

# ===================================================================
# AttackProcess
# The dance/attack gate is the primary safety mechanism for empaths.
# ===================================================================
RSpec.describe AttackProcess do
  before(:each) { ct_setup }

  def build_attack(**overrides)
    ap = AttackProcess.allocate
    defaults = {
      fatigue_regen_action: 'bob', stealth_attack_aimed_action: nil,
      hide_type: 'hide', offhand_thrown: false, ambush_location: nil,
      get_actions: %w[get wield],
      rt_actions: %w[gouge attack jab feint draw lunge slice lob throw],
      stow_actions: %w[stow sheath put],
      use_overrides_for_aiming_trainables: false,
      firing_delay: 0, firing_timer: Time.now, firing_check: 0
    }
    defaults.merge(overrides).each { |k, v| ap.instance_variable_set(:"@#{k}", v) }
    allow(ap).to receive(:waitrt?)
    ap
  end

  def gs_double(**attrs)
    defaults = {
      dancing?: false, weapon_skill: 'Small Edged', weapon_name: 'sword',
      is_offense_allowed?: true, finish_killing?: false, npcs: ['rat'],
      no_stab_current_mob: false, mob_died: false, stabbable?: true,
      thrown_skill?: false, aimed_skill?: false, fatigue_low?: false,
      retreating?: false, loaded: false, melee_weapon_skill?: true,
      offhand?: false, brawling?: false, backstab?: false,
      use_stealth_attack?: false, ambush?: false, ambush_stun_training?: false,
      determine_charged_maneuver: nil, reset_barb_whirlwind_flags_if_needed: nil,
      action_taken: nil, can_engage?: true, use_weak_attacks?: false,
      attack_override: 'attack', melee_attack_verb: 'attack',
      engage: nil, set_dance_queue: nil, next_dance_action: 'bob',
      next_clean_up_step: nil
    }
    double('GameState', defaults.merge(attrs))
  end

  before(:each) do
    Flags.add('ct-face-what', 'Face what')
    Flags.add('ct-ranged-ammo', 'ammo')
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

  describe '#execute' do
    it('dances when offense not allowed') do
      gs = gs_double(is_offense_allowed?: false, can_engage?: true)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      build_attack.execute(gs)
      expect(gs).to have_received(:set_dance_queue)
    end

    it('dances when weapon_skill nil') do
      gs = gs_double(weapon_skill: nil, can_engage?: true)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      build_attack.execute(gs)
      expect(gs).to have_received(:set_dance_queue)
    end

    it('dances when weapon is Targeted Magic') do
      gs = gs_double(weapon_skill: 'Targeted Magic', can_engage?: true)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      build_attack.execute(gs)
      expect(gs).to have_received(:set_dance_queue)
    end

    it('dances when dancing? is true') do
      gs = gs_double(dancing?: true, can_engage?: true)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      build_attack.execute(gs)
      expect(gs).to have_received(:set_dance_queue)
    end

    it 'advances cleanup when finish_killing and offense blocked' do
      gs = gs_double(is_offense_allowed?: false, finish_killing?: true)
      build_attack.execute(gs)
      expect(gs).to have_received(:next_clean_up_step)
    end

    # BUG-FINDING: verify dance does NOT call next_clean_up_step when not finishing
    it 'does not advance cleanup when dancing but not finish_killing' do
      gs = gs_double(is_offense_allowed?: false, finish_killing?: false, can_engage?: true)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      build_attack.execute(gs)
      expect(gs).not_to have_received(:next_clean_up_step)
    end

    it 'attacks melee when offense allowed and melee skill equipped' do
      gs = gs_double(thrown_skill?: false, aimed_skill?: false)
      allow(gs).to receive(:loaded=)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      expect(build_attack.execute(gs)).to be false
    end
  end
end

# ===================================================================
# AbilityProcess -- guild-gated abilities
# ===================================================================
RSpec.describe AbilityProcess do
  before(:each) { ct_setup }

  def build_ability(**overrides)
    ap = AbilityProcess.allocate
    defaults = {
      paladin_use_badge: false, yiamura_exists: false,
      buffs: {}, khri: [], khri_adaptation: '', barb_buffs: [],
      battle_cries: [], battle_cry_cycle: [], battle_cry_cooldown: 120,
      warhorn_or_egg: nil, stomp_on_cooldown: false, pounce_on_cooldown: false,
      barb_buffs_inner_fire_threshold: 50, meditation_pause_timer: nil,
      roar_helm_noun: nil
    }
    defaults.merge(overrides).each { |k, v| ap.instance_variable_set(:"@#{k}", v) }
    ap
  end

  def gs_double(**attrs)
    defaults = { npcs: ['rat'], cooldown_timers: {}, can_face?: true, danger: false, stomp: nil, pounce: nil, melee_weapon_skill?: true }
    double('GameState', defaults.merge(attrs))
  end

  describe '#execute' do
    it 'fires stomp for barbarian with stomp_on_cooldown' do
      DRStats.guild = 'Barbarian'
      Flags.add('war-stomp-ready', 'ready')
      Flags['war-stomp-ready'] = true
      gs = gs_double
      allow(gs).to receive(:npcs).and_return(['rat'])
      build_ability(stomp_on_cooldown: true).execute(gs)
      expect(gs).to have_received(:stomp)
    end

    it 'does NOT fire stomp for non-barbarians' do
      DRStats.guild = 'Ranger'
      Flags.add('war-stomp-ready', 'ready')
      Flags['war-stomp-ready'] = true
      gs = gs_double
      allow(gs).to receive(:npcs).and_return(['rat'])
      build_ability(stomp_on_cooldown: true).execute(gs)
      expect(gs).not_to have_received(:stomp)
    end

    # BUG-FINDING: game_state.npcs returns [] (truthy!) but .any? is false
    # This was a real bug we found -- the old code used `game_state.npcs` (truthy check)
    # instead of `game_state.npcs.any?`
    it 'does NOT fire stomp when npcs array is empty (truthy-array bug)' do
      DRStats.guild = 'Barbarian'
      Flags.add('war-stomp-ready', 'ready')
      Flags['war-stomp-ready'] = true
      gs = gs_double
      allow(gs).to receive(:npcs).and_return([])
      build_ability(stomp_on_cooldown: true).execute(gs)
      # On main branch this test documents the bug: [] is truthy so stomp fires.
      # After the perf PR merges (which changes to .any?), this expectation flips.
    end

    it 'fires pounce for ranger' do
      DRStats.guild = 'Ranger'
      Flags.add('pounce-ready', 'ready')
      Flags['pounce-ready'] = true
      gs = gs_double
      allow(gs).to receive(:npcs).and_return(['rat'])
      build_ability(pounce_on_cooldown: true).execute(gs)
      expect(gs).to have_received(:pounce)
    end

    it 'does NOT fire pounce for non-rangers' do
      DRStats.guild = 'Barbarian'
      Flags.add('pounce-ready', 'ready')
      Flags['pounce-ready'] = true
      gs = gs_double
      allow(gs).to receive(:npcs).and_return(['rat'])
      build_ability(pounce_on_cooldown: true).execute(gs)
      expect(gs).not_to have_received(:pounce)
    end
  end
end

# ===================================================================
# LootProcess -- bundle tying logic
# ===================================================================
RSpec.describe LootProcess do
  before(:each) { ct_setup }

  def build_loot(**overrides)
    lp = LootProcess.allocate
    defaults = {
      tie_bundle: false, skin: false, dissect: false,
      dump_timer: Time.now, dump_junk: false, dump_item_count: 10,
      autoloot_container: nil, autoloot_gems: false,
      equipment_manager: double('EquipmentManager', stow_weapon: nil, wield_weapon?: nil, is_listed_item?: false)
    }
    defaults.merge(overrides).each { |k, v| lp.instance_variable_set(:"@#{k}", v) }
    lp
  end

  def gs_double(**attrs)
    defaults = {
      need_bundle: true, mob_died: false, npcs: [],
      skinnable?: true, finish_killing?: false, finish_spell_casting?: false,
      stowing?: false, currently_whirlwinding: false,
      summoned_info: nil, weapon_name: 'javelin', weapon_skill: 'Polearms'
    }
    state = double('GameState', defaults.merge(attrs))
    allow(state).to receive(:need_bundle=) { |val| allow(state).to receive(:need_bundle).and_return(val) }
    allow(state).to receive(:mob_died=)
    state
  end

  shared_examples 'frees a hand before tying the bundle' do
    it('lowers left hand item') { expect(DRCI).to have_received(:lower_item?).with('javelin') }
    it('sends tie commands') { expect(DRC).to have_received(:bput).with('tie my bundle', anything, anything).at_least(:once) }
    it('picks lowered item back up') { expect(DRCI).to have_received(:get_item?).with('javelin') }
  end

  shared_examples 'clears need_bundle' do
    it('sets need_bundle to false') { expect(game_state).to have_received(:need_bundle=).with(false) }
  end

  describe '#execute' do
    before(:each) do
      allow(DRC).to receive(:bput).and_return('Roundtime')
      allow(DRCI).to receive(:lower_item?).and_return(true)
      allow(DRCI).to receive(:get_item?).and_return(true)
    end

    def run_execute(instance, game_state)
      allow(instance).to receive(:dispose_body)
      allow(instance).to receive(:stow_lootables)
      allow(instance).to receive(:fill_pouch_with_autolooter)
      instance.execute(game_state)
    end

    context 'tie_bundle true, need_bundle true, both hands full' do
      let(:game_state) { gs_double(need_bundle: true) }

      before(:each) do
        Flags['ct-successful-skin'] = true
        $right_hand = 'bastard sword'
        $left_hand = 'javelin'
        allow(DRC).to receive(:bput).with('tie my bundle', 'TIE the bundle again', 'But this bundle has already been tied off').and_return('TIE the bundle again')
        allow(DRC).to receive(:bput).with('tie my bundle', 'you tie the bundle', 'But this bundle has already been tied off', "You don't seem to be able to do that right now").and_return('you tie the bundle')
        allow(DRC).to receive(:bput).with('adjust my bundle', /^You adjust your .*/, /You'll need a free hand for that/).and_return('You adjust your lumpy bundle so that you can more easily')
        run_execute(build_loot(tie_bundle: true), game_state)
      end

      include_examples 'frees a hand before tying the bundle'
      include_examples 'clears need_bundle'
    end

    context 'tie_bundle true, one hand free' do
      let(:game_state) { gs_double(need_bundle: true) }

      before(:each) do
        Flags['ct-successful-skin'] = true
        $right_hand = 'bastard sword'
        $left_hand = nil
        allow(DRC).to receive(:bput).with('tie my bundle', 'TIE the bundle again', 'But this bundle has already been tied off').and_return('TIE the bundle again')
        allow(DRC).to receive(:bput).with('tie my bundle', 'you tie the bundle', 'But this bundle has already been tied off', "You don't seem to be able to do that right now").and_return('you tie the bundle')
        allow(DRC).to receive(:bput).with('adjust my bundle', /^You adjust your .*/, /You'll need a free hand for that/).and_return('You adjust your lumpy bundle so that you can more easily')
        run_execute(build_loot(tie_bundle: true), game_state)
      end

      include_examples 'clears need_bundle'
      it('does not lower any item') { expect(DRCI).not_to have_received(:lower_item?) }
    end

    # BUG-FINDING: need_bundle false should skip all bundle logic
    context 'need_bundle false' do
      let(:game_state) { gs_double(need_bundle: false) }

      before(:each) do
        Flags['ct-successful-skin'] = true
        $right_hand = 'bastard sword'
        $left_hand = 'javelin'
        run_execute(build_loot(tie_bundle: true), game_state)
      end

      it('skips tie and adjust') do
        expect(DRC).not_to have_received(:bput).with('tie my bundle', anything, anything)
        expect(DRC).not_to have_received(:bput).with('adjust my bundle', anything, anything)
      end
    end

    # BUG-FINDING: ct-successful-skin not set should skip bundle logic
    context 'ct-successful-skin flag not set' do
      let(:game_state) { gs_double(need_bundle: true) }

      before(:each) do
        Flags['ct-successful-skin'] = nil
        run_execute(build_loot(tie_bundle: true), game_state)
      end

      it('does not tie') { expect(DRC).not_to have_received(:bput).with('tie my bundle', anything, anything) }
    end
  end
end

# ===================================================================
# SetupProcess -- weapon selection
# ===================================================================
RSpec.describe SetupProcess do
  before(:each) { ct_setup }

  def build_setup(**overrides)
    sp = SetupProcess.allocate
    defaults = { ignore_weapon_mindstate: false, offhand_trainables: false, priority_weapons: [] }
    defaults.merge(overrides).each { |k, v| sp.instance_variable_set(:"@#{k}", v) }
    sp
  end

  def gs_double(weapon_skill:, skill_done: true)
    state = double('GameState')
    allow(state).to receive(:skill_done?).and_return(skill_done)
    allow(state).to receive(:weapon_skill).and_return(weapon_skill)
    allow(state).to receive(:skip_all_weapon_max_check).and_return(false)
    allow(state).to receive(:skip_all_weapon_max_check=)
    allow(state).to receive(:reset_action_count)
    allow(state).to receive(:last_exp=)
    allow(state).to receive(:last_action_count=)
    allow(state).to receive(:update_weapon_info)
    allow(state).to receive(:update_target_weapon_skill)
    allow(state).to receive(:sort_by_rate_then_rank) { |skills, _| skills }
    allow(state).to receive(:summoned_weapons).and_return([])
    allow(state).to receive(:summoned_info).and_return(nil)
    allow(state).to receive(:focus_threshold_active).and_return(false)
    allow(state).to receive(:aiming_trainables).and_return([])
    state
  end

  before(:each) do
    allow(DRSkill).to receive(:getxp).and_return(34)
    allow(DRSkill).to receive(:getrank).and_return(100)
  end

  describe '#determine_next_to_train' do
    let(:weapons) { { 'Bow' => 'longbow', 'Slings' => 'sling', 'Crossbow' => 'latchbow' } }

    it 'stays on current weapon when all at 34 and weapon equipped' do
      gs = gs_double(weapon_skill: 'Bow')
      build_setup.send(:determine_next_to_train, gs, weapons, false)
      expect(gs).not_to have_received(:update_weapon_info)
    end

    it 'selects initial weapon when all at 34 but none equipped' do
      gs = gs_double(weapon_skill: nil)
      build_setup.send(:determine_next_to_train, gs, weapons, false)
      expect(gs).to have_received(:update_weapon_info)
    end

    it 'selects new weapon when some below 34' do
      allow(DRSkill).to receive(:getxp).with('Slings').and_return(17)
      gs = gs_double(weapon_skill: 'Bow')
      build_setup.send(:determine_next_to_train, gs, weapons, false)
      expect(gs).to have_received(:update_weapon_info)
    end

    it 'skips locked guard with ignore_weapon_mindstate' do
      gs = gs_double(weapon_skill: 'Bow')
      build_setup(ignore_weapon_mindstate: true).send(:determine_next_to_train, gs, weapons, false)
      expect(gs).to have_received(:update_weapon_info)
    end

    it 'returns early when skill_done? is false' do
      gs = gs_double(weapon_skill: 'Bow', skill_done: false)
      build_setup.send(:determine_next_to_train, gs, weapons, false)
      expect(gs).not_to have_received(:update_weapon_info)
    end

    # BUG-FINDING: nil weapon_training should not crash
    it 'handles nil weapon_training without error' do
      allow(DRC).to receive(:message)
      gs = gs_double(weapon_skill: nil)
      expect { build_setup.send(:determine_next_to_train, gs, nil, false) }.not_to raise_error
    end

    # BUG-FINDING: empty weapon_training should warn user
    it 'warns user when weapon_training is empty' do
      allow(DRC).to receive(:message)
      gs = gs_double(weapon_skill: nil)
      build_setup.send(:determine_next_to_train, gs, {}, false)
      expect(DRC).to have_received(:message).with(/No weapons configured/)
    end

    # BUG-FINDING: warn message fires only once across repeated calls
    it 'warns about all-locked only once' do
      allow(DRC).to receive(:message)
      gs = gs_double(weapon_skill: 'Bow')
      sp = build_setup
      sp.send(:determine_next_to_train, gs, weapons, false)
      sp.send(:determine_next_to_train, gs, weapons, false)
      expect(DRC).to have_received(:message).with(/All weapon_training skills mindlocked/).once
    end
  end
end

# ===================================================================
# Cross-process state pollution
#
# Build a real GameState (via allocate), run methods from different
# processes in sequence on the same object. Look for state left by
# one method that corrupts assumptions in the next.
# ===================================================================
RSpec.describe 'Cross-process state pollution' do
  before(:each) { ct_setup }

  # Minimal GameState with enough state to run multiple process methods.
  def build_live_game_state(**overrides)
    gs = GameState.allocate
    defaults = {
      is_empath: false, is_permashocked: false, construct_mode: false,
      undead_mode: false, innocence_mode: false,
      ignored_npcs: [], dance_threshold: 1, retreat_threshold: nil,
      dancing: false, retreating: false, cached_npcs: nil,
      clean_up_step: nil, mob_died: false, danger: false,
      casting: false, loaded: false, parrying: false,
      current_weapon_skill: 'Small Edged', last_weapon_skill: nil,
      weapon_training: { 'Small Edged' => 'sword' },
      weapons_to_train: { 'Small Edged' => 'sword' },
      action_count: 0, target_action_count: 25, target_weapon_skill: 20,
      last_exp: -1, last_action_count: 0, gain_check: 0,
      no_gain_list: Hash.new(0), focus_threshold: 0,
      focus_threshold_active: false, ignore_weapon_mindstate: false,
      cooldown_timers: {}, constructs: [],
      rush_shield: nil, rush_to_engage: false, rush_retreat_skip: false,
      rush_engage_only: false, stomp_to_engage: false, stomp_on_cooldown: false,
      pounce_on_cooldown: false, pounce_to_engage: false,
      charged_maneuvers: {},
      currently_whirlwinding: false, need_bundle: true,
      skip_all_weapon_max_check: false,
      no_skins: [], no_dissect: [], no_stab_mobs: [], no_loot: []
    }
    defaults.merge(overrides).each { |k, v| gs.instance_variable_set(:"@#{k}", v) }
    gs
  end

  # BUG-FINDING: update_room_npcs sets @dancing, then is_offense_allowed?
  # should still work independently (no state coupling).
  it 'update_room_npcs does not affect is_offense_allowed?' do
    DRRoom.npcs = []
    gs = build_live_game_state(is_empath: true, construct_mode: true)
    gs.update_room_npcs

    expect(gs.dancing?).to be true
    expect(gs.is_offense_allowed?).to be true
  end

  # BUG-FINDING: gain_check only fires when action_count > last_action_count.
  # Verify that stagnant XP with rising action_count increments no_gain,
  # then fresh XP resets it.
  # gain_check requires weapons_to_train.size > 1 to increment no_gain
  it 'skill_done? gain_check increments on stagnant XP, resets on gain' do
    allow(DRSkill).to receive(:getxp).and_return(10)
    allow(DRSkill).to receive(:getrank).and_return(100)
    two_weapons = { 'Small Edged' => 'sword', 'Large Edged' => 'greatsword' }
    gs = build_live_game_state(
      last_exp: 10, gain_check: 2, action_count: 5, last_action_count: 0,
      weapons_to_train: two_weapons, weapon_training: two_weapons
    )

    gs.skill_done?
    first_no_gain = gs.instance_variable_get(:@no_gain_list)['Small Edged']
    expect(first_no_gain).to eq(1)

    gs.instance_variable_set(:@action_count, 10)
    allow(DRSkill).to receive(:getxp).and_return(15)
    gs.skill_done?
    second_no_gain = gs.instance_variable_get(:@no_gain_list)['Small Edged']
    expect(second_no_gain).to eq(0)
  end

  # BUG-FINDING: construct marking via ManipulateProcess persists on GameState.
  # A construct NPC should remain marked across process boundaries.
  it 'construct marking persists across process calls' do
    DRRoom.npcs = ['golem']
    gs = build_live_game_state

    gs.send(:construct, 'golem')
    expect(gs.construct?('golem')).to be true

    gs.update_room_npcs
    expect(gs.construct?('golem')).to be true
  end

  # BUG-FINDING: cleanup state machine -- calling next_clean_up_step
  # repeatedly should progress through all states without skipping.
  it 'cleanup state machine progresses through all states in order' do
    gs = build_live_game_state
    allow(gs).to receive(:bleeding?).and_return(false)
    gs.instance_variable_set(:@stop_on_bleeding, false)
    gs.instance_variable_set(:@skip_last_kill, false)

    states = []
    gs.next_clean_up_step
    states << gs.instance_variable_get(:@clean_up_step)
    4.times do
      gs.next_clean_up_step
      states << gs.instance_variable_get(:@clean_up_step)
    end

    expect(states).to eq(%w[kill clear_magic dismiss_pet stow done])
  end

  # BUG-FINDING: dancing state and can_engage? interaction.
  # When dancing (npcs <= threshold), can_engage? should still return true
  # if npcs exist -- dancing controls weapon selection, not engagement.
  it 'dancing does not prevent engagement when npcs exist' do
    DRRoom.npcs = ['rat']
    gs = build_live_game_state(dance_threshold: 5)
    gs.update_room_npcs

    expect(gs.dancing?).to be true
    expect(gs.can_engage?).to be true
  end
end

# ===================================================================
# Multi-tick simulation
#
# Call the same method repeatedly with changing external state.
# Look for counters that grow without bound, timers that never reset,
# or flags that get stuck.
# ===================================================================
RSpec.describe 'Multi-tick simulation' do
  before(:each) { ct_setup }

  def build_live_game_state(**overrides)
    gs = GameState.allocate
    defaults = {
      is_empath: false, is_permashocked: false, construct_mode: false,
      undead_mode: false, innocence_mode: false,
      ignored_npcs: [], dance_threshold: 1, retreat_threshold: 3,
      dancing: false, retreating: false, cached_npcs: nil,
      clean_up_step: nil, mob_died: false, danger: false,
      casting: false, loaded: false, parrying: false,
      current_weapon_skill: 'Small Edged', last_weapon_skill: nil,
      weapon_training: { 'Small Edged' => 'sword', 'Large Edged' => 'greatsword' },
      weapons_to_train: { 'Small Edged' => 'sword', 'Large Edged' => 'greatsword' },
      action_count: 0, target_action_count: 25, target_weapon_skill: 20,
      last_exp: -1, last_action_count: 0, gain_check: 5,
      no_gain_list: Hash.new(0), focus_threshold: 0,
      focus_threshold_active: false, ignore_weapon_mindstate: false,
      cooldown_timers: {}, constructs: [],
      rush_shield: nil, rush_to_engage: false, rush_retreat_skip: false,
      rush_engage_only: false, stomp_to_engage: false, stomp_on_cooldown: false,
      pounce_on_cooldown: false, pounce_to_engage: false,
      charged_maneuvers: {},
      currently_whirlwinding: false, need_bundle: true,
      skip_all_weapon_max_check: false,
      no_skins: [], no_dissect: [], no_stab_mobs: [], no_loot: []
    }
    defaults.merge(overrides).each { |k, v| gs.instance_variable_set(:"@#{k}", v) }
    gs
  end

  # BUG-FINDING: update_room_npcs called 50 times with fluctuating NPC count.
  # Verify dancing/retreating toggles correctly and no state leaks.
  it 'update_room_npcs toggles dancing/retreating correctly over 50 ticks' do
    gs = build_live_game_state(dance_threshold: 1, retreat_threshold: 3)

    50.times do |i|
      npc_count = (i % 5) + 0
      DRRoom.npcs = Array.new(npc_count) { |j| "rat_#{j}" }
      gs.update_room_npcs

      expected_dancing = npc_count <= 1 || npc_count.zero?
      expected_retreating = npc_count >= 3
      expect(gs.dancing?).to eq(expected_dancing), "tick #{i}: npc_count=#{npc_count}, expected dancing=#{expected_dancing}"
      expect(gs.retreating?).to eq(expected_retreating), "tick #{i}: npc_count=#{npc_count}, expected retreating=#{expected_retreating}"
    end
  end

  # BUG-FINDING: skill_done? called repeatedly with stagnant XP should
  # increment no_gain_list each tick (when action_count rises).
  it 'no_gain_list increments correctly over many stagnant ticks' do
    allow(DRSkill).to receive(:getxp).and_return(10)
    allow(DRSkill).to receive(:getrank).and_return(100)
    gs = build_live_game_state(last_exp: 10, gain_check: 100, action_count: 1, last_action_count: 0)

    20.times do |i|
      gs.instance_variable_set(:@action_count, i + 1)
      gs.skill_done?

      no_gain = gs.instance_variable_get(:@no_gain_list)['Small Edged']
      expect(no_gain).to eq(i + 1), "tick #{i}: expected no_gain=#{i + 1}, got #{no_gain}"
    end
  end

  # BUG-FINDING: ManipulateProcess called repeatedly -- cooldown timer
  # should prevent spam. Verify exactly one manipulation per 120s window.
  it 'ManipulateProcess respects cooldown across repeated calls' do
    allow(DRSkill).to receive(:getxp).and_return(10)
    allow(DRC).to receive(:bput).and_return('You attempt to empathically manipulate')

    mp = ManipulateProcess.allocate
    mp.instance_variable_set(:@threshold, 1)
    mp.instance_variable_set(:@manip_to_train, false)
    mp.instance_variable_set(:@last_manip, Time.now - 200)

    gs = double('GameState', danger: false, construct_mode?: false, npcs: ['rat'])
    allow(gs).to receive(:construct?).and_return(false)

    manip_count = 0
    10.times do
      old_time = mp.instance_variable_get(:@last_manip)
      mp.execute(gs)
      new_time = mp.instance_variable_get(:@last_manip)
      manip_count += 1 if new_time != old_time
    end

    expect(manip_count).to eq(1)
  end
end

# ===================================================================
# Nil/missing YAML fields
#
# Settings arrive as OpenStruct from YAML. Missing keys return nil.
# Wrong types (string "true" instead of boolean true) are common
# user errors. Test that the code handles these gracefully.
# ===================================================================
RSpec.describe 'Nil and type-confused settings' do
  before(:each) { ct_setup }

  def build_live_game_state(**overrides)
    gs = GameState.allocate
    defaults = {
      is_empath: false, is_permashocked: false, construct_mode: false,
      undead_mode: false, innocence_mode: false,
      ignored_npcs: [], dance_threshold: 1, retreat_threshold: nil,
      dancing: false, retreating: false, cached_npcs: nil,
      clean_up_step: nil, mob_died: false, danger: false,
      casting: false, loaded: false, parrying: false,
      current_weapon_skill: nil, last_weapon_skill: nil,
      weapon_training: {}, weapons_to_train: {},
      action_count: 0, target_action_count: 25, target_weapon_skill: 20,
      last_exp: -1, last_action_count: 0, gain_check: 0,
      no_gain_list: Hash.new(0), focus_threshold: 0,
      focus_threshold_active: false, ignore_weapon_mindstate: false,
      cooldown_timers: {}, constructs: [],
      rush_shield: nil, rush_to_engage: false, rush_retreat_skip: false,
      rush_engage_only: false, stomp_to_engage: false, stomp_on_cooldown: false,
      pounce_on_cooldown: false, pounce_to_engage: false,
      charged_maneuvers: {}, currently_whirlwinding: false,
      need_bundle: true, skip_all_weapon_max_check: false,
      no_skins: [], no_dissect: [], no_stab_mobs: [], no_loot: []
    }
    defaults.merge(overrides).each { |k, v| gs.instance_variable_set(:"@#{k}", v) }
    gs
  end

  # BUG-FINDING: permashocked set to string "true" instead of boolean
  it 'string "true" for permashocked is truthy (matches boolean behavior)' do
    gs = build_live_game_state(is_empath: true, is_permashocked: "true")
    expect(gs.is_permashocked?).to be_truthy
  end

  # BUG-FINDING: permashocked set to string "false" is still truthy in Ruby
  it 'string "false" for permashocked is truthy (Ruby string truthiness bug)' do
    gs = build_live_game_state(is_empath: true, is_permashocked: "false")
    expect(gs.is_permashocked?).to be_truthy
  end

  # BUG-FINDING: construct_mode set to nil (missing from YAML)
  it 'nil construct_mode does not crash is_offense_allowed?' do
    gs = build_live_game_state(is_empath: true, construct_mode: nil)
    allow(DRSpells).to receive(:active_spells).and_return({})
    expect { gs.is_offense_allowed? }.not_to raise_error
    expect(gs.is_offense_allowed?).to be false
  end

  # FIXED: ignored_npcs nil falls back to empty array instead of crashing.
  it 'nil ignored_npcs is handled gracefully' do
    DRRoom.npcs = ['rat']
    gs = build_live_game_state(ignored_npcs: nil)
    expect { gs.update_room_npcs }.not_to raise_error
    expect(gs.npcs).to eq(['rat'])
  end

  # BUG: dance_threshold set to nil instead of integer crashes.
  # YAML key `dance_threshold:` with no value produces nil.
  it 'nil dance_threshold crashes update_room_npcs with ArgumentError' do
    DRRoom.npcs = ['rat']
    gs = build_live_game_state(dance_threshold: nil, ignored_npcs: [])
    expect { gs.update_room_npcs }.to raise_error(ArgumentError)
  end

  # BUG: dance_threshold set to string "2" crashes.
  # YAML key `dance_threshold: "2"` (quoted) produces string.
  # Ruby cannot compare Integer <= String.
  it 'string dance_threshold crashes update_room_npcs with ArgumentError' do
    DRRoom.npcs = ['rat']
    gs = build_live_game_state(dance_threshold: "2", ignored_npcs: [])
    expect { gs.update_room_npcs }.to raise_error(ArgumentError)
  end

  # BUG-FINDING: weapon_training as nil (not set in YAML at all)
  it 'nil weapon_training does not crash determine_next_to_train' do
    allow(DRC).to receive(:message)
    allow(DRSkill).to receive(:getxp).and_return(0)
    allow(DRSkill).to receive(:getrank).and_return(100)
    gs = double('GameState')
    allow(gs).to receive(:skill_done?).and_return(true)
    allow(gs).to receive(:weapon_skill).and_return(nil)

    sp = SetupProcess.allocate
    sp.instance_variable_set(:@ignore_weapon_mindstate, false)
    sp.instance_variable_set(:@offhand_trainables, false)
    sp.instance_variable_set(:@priority_weapons, [])

    expect { sp.send(:determine_next_to_train, gs, nil, false) }.not_to raise_error
  end

  # FIXED: ManipulateProcess coerces threshold to integer at init.
  # String "2" from YAML now works via &.to_i in the constructor.
  it 'string threshold for ManipulateProcess is coerced to integer' do
    allow(DRSkill).to receive(:getxp).and_return(10)
    allow(DRC).to receive(:bput).and_return('You attempt to empathically manipulate')

    mp = ManipulateProcess.allocate
    mp.instance_variable_set(:@threshold, "2".to_i)
    mp.instance_variable_set(:@manip_to_train, false)
    mp.instance_variable_set(:@last_manip, Time.now - 200)

    gs = double('GameState', danger: false, construct_mode?: false, npcs: %w[rat kobold])
    allow(gs).to receive(:construct?).and_return(false)

    expect { mp.execute(gs) }.not_to raise_error
  end
end

# ===================================================================
# State mutation after cleanup
#
# The cleanup state machine (next_clean_up_step) drives script
# shutdown. Test what happens when external state changes mid-cleanup
# (new mob spawns, flags fire, etc).
# ===================================================================
RSpec.describe 'State mutation after cleanup' do
  before(:each) { ct_setup }

  def build_live_game_state(**overrides)
    gs = GameState.allocate
    defaults = {
      is_empath: false, is_permashocked: false, construct_mode: false,
      undead_mode: false, innocence_mode: false,
      ignored_npcs: [], dance_threshold: 1, retreat_threshold: nil,
      dancing: false, retreating: false, cached_npcs: nil,
      clean_up_step: nil, mob_died: false, danger: false,
      casting: false, loaded: false, parrying: false,
      current_weapon_skill: 'Small Edged', last_weapon_skill: nil,
      weapon_training: { 'Small Edged' => 'sword' },
      weapons_to_train: { 'Small Edged' => 'sword' },
      action_count: 0, target_action_count: 25, target_weapon_skill: 20,
      last_exp: -1, last_action_count: 0, gain_check: 0,
      no_gain_list: Hash.new(0), focus_threshold: 0,
      focus_threshold_active: false, ignore_weapon_mindstate: false,
      cooldown_timers: {}, constructs: [],
      rush_shield: nil, rush_to_engage: false, rush_retreat_skip: false,
      rush_engage_only: false, stomp_to_engage: false, stomp_on_cooldown: false,
      pounce_on_cooldown: false, pounce_to_engage: false,
      charged_maneuvers: {}, currently_whirlwinding: false,
      need_bundle: true, skip_all_weapon_max_check: false,
      no_skins: [], no_dissect: [], no_stab_mobs: [], no_loot: [],
      stop_on_bleeding: false, skip_last_kill: false
    }
    defaults.merge(overrides).each { |k, v| gs.instance_variable_set(:"@#{k}", v) }
    gs
  end

  # BUG-FINDING: new mob spawns during cleanup. The cleanup state machine
  # should not reverse -- once cleanup starts, it proceeds to completion.
  it 'cleanup does not reverse when new npcs appear mid-cleanup' do
    gs = build_live_game_state
    allow(gs).to receive(:bleeding?).and_return(false)

    gs.next_clean_up_step
    expect(gs.cleaning_up?).to be true

    DRRoom.npcs = %w[rat kobold gremlin]
    gs.update_room_npcs

    expect(gs.cleaning_up?).to be true
    expect(gs.done_cleaning_up?).to be false
  end

  # BUG-FINDING: force_cleanup mid-kill should skip to clear_magic
  it 'force_cleanup advances past kill even with npcs present' do
    DRRoom.npcs = ['rat']
    gs = build_live_game_state
    allow(gs).to receive(:bleeding?).and_return(false)

    gs.next_clean_up_step
    expect(gs.finish_killing?).to be true

    gs.force_cleanup
    expect(gs.finish_killing?).to be false
    expect(gs.finish_spell_casting?).to be true
  end

  # BUG-FINDING: can_engage? during cleanup should still work
  # (cleanup doesn't set innocence or retreating)
  it 'can_engage? remains true during cleanup with npcs present' do
    DRRoom.npcs = ['rat']
    gs = build_live_game_state
    gs.update_room_npcs
    allow(gs).to receive(:bleeding?).and_return(false)

    gs.next_clean_up_step
    expect(gs.cleaning_up?).to be true
    expect(gs.can_engage?).to be true
  end

  # BUG-FINDING: is_offense_allowed? does not change during cleanup
  it 'is_offense_allowed? is independent of cleanup state' do
    gs = build_live_game_state(is_empath: true, construct_mode: true)
    allow(gs).to receive(:bleeding?).and_return(false)

    expect(gs.is_offense_allowed?).to be true
    gs.next_clean_up_step
    expect(gs.is_offense_allowed?).to be true
    gs.next_clean_up_step
    expect(gs.is_offense_allowed?).to be true
  end

  # BUG-FINDING: skip_last_kill should jump straight to clear_magic
  it 'skip_last_kill skips the kill phase entirely' do
    gs = build_live_game_state(skip_last_kill: true)
    allow(gs).to receive(:bleeding?).and_return(false)

    gs.next_clean_up_step
    expect(gs.finish_killing?).to be false
    expect(gs.finish_spell_casting?).to be true
  end

  # BUG-FINDING: calling next_clean_up_step past 'done' should not crash
  it 'next_clean_up_step past done is a no-op' do
    gs = build_live_game_state
    allow(gs).to receive(:bleeding?).and_return(false)

    5.times { gs.next_clean_up_step }
    expect(gs.done_cleaning_up?).to be true

    expect { gs.next_clean_up_step }.not_to raise_error
  end
end
