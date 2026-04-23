# frozen_string_literal: true

require 'ostruct'

# Load test harness which provides mock game objects
load File.join(File.dirname(__FILE__), '..', 'test', 'test_harness.rb')
include Harness

# Extract and eval a class from a .lic file without executing top-level code
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

# Minimal stub modules for game interaction
module DRC
  class << self
    def right_hand
      $right_hand
    end

    def left_hand
      $left_hand
    end

    def bput(*_args)
      'Roundtime'
    end

    def message(*_args); end

    def rummage(*_args)
      []
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

    def dispose_trash(*_args); end

    def wear_item?(*_args)
      true
    end

    def fill_gem_pouch_with_container(*_args); end

    def count_all_boxes(*_args)
      0
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
  end
end

module DRCS
  class << self
    def break_summoned_weapon(*_args); end
  end
end

$debug_mode_ct = false

load_lic_class('combat-trainer.lic', 'LootProcess')
load_lic_class('combat-trainer.lic', 'GameState')
load_lic_class('combat-trainer.lic', 'SetupProcess')

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end
end

# ===========================================================================
# LootProcess specs
# ===========================================================================
RSpec.describe LootProcess do
  # Build a LootProcess instance without calling initialize (avoids game I/O).
  def build_loot_process(**overrides)
    instance = LootProcess.allocate
    defaults = {
      tie_bundle: false,
      skin: false,
      dissect: false,
      dump_timer: Time.now,
      dump_junk: false,
      dump_item_count: 10,
      autoloot_container: nil,
      autoloot_gems: false,
      equipment_manager: double('EquipmentManager', stow_weapon: nil, wield_weapon?: nil, is_listed_item?: false)
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  # Build a minimal game_state double with sensible defaults.
  def build_game_state(**attrs)
    defaults = {
      need_bundle: true,
      mob_died: false,
      npcs: [],
      skinnable?: true,
      finish_killing?: false,
      finish_spell_casting?: false,
      stowing?: false,
      currently_whirlwinding: false,
      summoned_info: nil,
      weapon_name: 'javelin',
      weapon_skill: 'Polearms'
    }
    state = double('GameState', defaults.merge(attrs))
    allow(state).to receive(:need_bundle=) { |val| allow(state).to receive(:need_bundle).and_return(val) }
    allow(state).to receive(:mob_died=)
    state
  end

  # ===========================================================================
  # Shared examples -- SOLID: extract common assertions for hand-freeing
  # ===========================================================================
  shared_examples 'frees a hand before tying the bundle' do
    it 'lowers the left hand item before attempting to tie' do
      expect(DRCI).to have_received(:lower_item?).with('javelin')
    end

    it 'sends tie my bundle commands after freeing a hand' do
      expect(DRC).to have_received(:bput).with('tie my bundle', anything, anything).at_least(:once)
    end

    it 'picks the lowered item back up after tying and adjusting' do
      expect(DRCI).to have_received(:get_item?).with('javelin')
    end
  end

  shared_examples 'does not lower any item' do
    it 'does not call lower_item?' do
      expect(DRCI).not_to have_received(:lower_item?)
    end
  end

  shared_examples 'clears need_bundle on game_state' do
    it 'sets game_state.need_bundle to false' do
      expect(game_state).to have_received(:need_bundle=).with(false)
    end
  end

  # ===========================================================================
  # #execute -- bundle tying in the clean_up path (line ~598)
  # The execute method checks game_state.need_bundle && Flags['ct-successful-skin']
  # and attempts to tie/adjust a worn bundle. When both hands are full, it must
  # lower an item first to free a hand for the tie command.
  # ===========================================================================
  describe '#execute' do
    # Stubs to skip the parts of execute() before the bundle-tying logic
    before(:each) do
      allow(DRC).to receive(:bput).and_return('Roundtime')
      allow(DRCI).to receive(:lower_item?).and_return(true)
      allow(DRCI).to receive(:get_item?).and_return(true)
    end

    # Stub the early parts of execute to be no-ops so we reach the bundle section
    def run_execute(instance, game_state)
      # Stub dispose_body and stow_lootables (private methods called before bundle logic)
      allow(instance).to receive(:dispose_body)
      allow(instance).to receive(:stow_lootables)
      allow(instance).to receive(:fill_pouch_with_autolooter)

      instance.execute(game_state)
    end

    context 'when @tie_bundle is true, need_bundle is true, and both hands are full' do
      let(:game_state) { build_game_state(need_bundle: true) }

      before(:each) do
        Flags['ct-successful-skin'] = true
        $right_hand = 'bastard sword'
        $left_hand = 'javelin'

        # First tie: confirmation prompt
        allow(DRC).to receive(:bput)
          .with('tie my bundle', 'TIE the bundle again', 'But this bundle has already been tied off')
          .and_return('TIE the bundle again')
        # Second tie: actual tie
        allow(DRC).to receive(:bput)
          .with('tie my bundle', 'you tie the bundle', 'But this bundle has already been tied off', "You don't seem to be able to do that right now")
          .and_return('you tie the bundle')
        # Adjust: success
        allow(DRC).to receive(:bput)
          .with('adjust my bundle', /^You adjust your .*/, /You'll need a free hand for that/)
          .and_return('You adjust your lumpy bundle so that you can more easily')

        instance = build_loot_process(tie_bundle: true)
        run_execute(instance, game_state)
      end

      include_examples 'frees a hand before tying the bundle'
      include_examples 'clears need_bundle on game_state'
    end

    context 'when @tie_bundle is true, need_bundle is true, and one hand is free' do
      let(:game_state) { build_game_state(need_bundle: true) }

      before(:each) do
        Flags['ct-successful-skin'] = true
        $right_hand = 'bastard sword'
        $left_hand = nil

        allow(DRC).to receive(:bput)
          .with('tie my bundle', 'TIE the bundle again', 'But this bundle has already been tied off')
          .and_return('TIE the bundle again')
        allow(DRC).to receive(:bput)
          .with('tie my bundle', 'you tie the bundle', 'But this bundle has already been tied off', "You don't seem to be able to do that right now")
          .and_return('you tie the bundle')
        allow(DRC).to receive(:bput)
          .with('adjust my bundle', /^You adjust your .*/, /You'll need a free hand for that/)
          .and_return('You adjust your lumpy bundle so that you can more easily')

        instance = build_loot_process(tie_bundle: true)
        run_execute(instance, game_state)
      end

      include_examples 'does not lower any item'
      include_examples 'clears need_bundle on game_state'

      it 'does not attempt to pick up a lowered item' do
        expect(DRCI).not_to have_received(:get_item?)
      end
    end

    context 'when @tie_bundle is false and need_bundle is true' do
      let(:game_state) { build_game_state(need_bundle: true) }

      before(:each) do
        Flags['ct-successful-skin'] = true
        $right_hand = 'bastard sword'
        $left_hand = 'javelin'

        instance = build_loot_process(tie_bundle: false)
        run_execute(instance, game_state)
      end

      include_examples 'does not lower any item'
      include_examples 'clears need_bundle on game_state'

      it 'does not attempt to tie the bundle' do
        expect(DRC).not_to have_received(:bput).with('tie my bundle', anything, anything)
      end
    end

    context 'when need_bundle is false' do
      let(:game_state) { build_game_state(need_bundle: false) }

      before(:each) do
        Flags['ct-successful-skin'] = true
        $right_hand = 'bastard sword'
        $left_hand = 'javelin'

        instance = build_loot_process(tie_bundle: true)
        run_execute(instance, game_state)
      end

      it 'does not attempt to tie or adjust the bundle' do
        expect(DRC).not_to have_received(:bput).with('tie my bundle', anything, anything)
        expect(DRC).not_to have_received(:bput).with('adjust my bundle', anything, anything)
      end
    end

    context 'when ct-successful-skin flag is not set' do
      let(:game_state) { build_game_state(need_bundle: true) }

      before(:each) do
        Flags['ct-successful-skin'] = nil
        $right_hand = 'bastard sword'
        $left_hand = 'javelin'

        instance = build_loot_process(tie_bundle: true)
        run_execute(instance, game_state)
      end

      it 'does not attempt to tie the bundle' do
        expect(DRC).not_to have_received(:bput).with('tie my bundle', anything, anything)
      end
    end
  end

  # ===========================================================================
  # #check_skinning -- bundle tying before skinning (line ~1099)
  # When game_state.need_bundle is true and the player has a lumpy bundle,
  # check_skinning ties it off before skinning. When both hands are full,
  # it must lower an item to free a hand for the tie command.
  # ===========================================================================
  describe '#check_skinning' do
    before(:each) do
      allow(DRC).to receive(:bput).and_return('Roundtime')
      allow(DRCI).to receive(:lower_item?).and_return(true)
      allow(DRCI).to receive(:get_item?).and_return(true)
    end

    context 'when need_bundle is true, bundle is lumpy, and both hands are full' do
      let(:game_state) { build_game_state(need_bundle: true) }

      before(:each) do
        $right_hand = 'bastard sword'
        $left_hand = 'javelin'

        # tap: lumpy bundle
        allow(DRC).to receive(:bput)
          .with('tap my bundle', anything, anything, anything)
          .and_return('You tap a lumpy bundle that you are wearing')
        # First tie: confirmation
        allow(DRC).to receive(:bput)
          .with('tie my bundle', 'TIE the bundle again', 'But this bundle has already been tied off')
          .and_return('TIE the bundle again')
        # Second tie: success
        allow(DRC).to receive(:bput)
          .with('tie my bundle', 'you tie the bundle', 'But this bundle has already been tied off', "You don't seem to be able to do that right now")
          .and_return('you tie the bundle')
        # Adjust: success
        allow(DRC).to receive(:bput)
          .with('adjust my bundle', /^You adjust your .*/, /You'll need a free hand for that/)
          .and_return('You adjust your lumpy bundle so that you can more easily')
        # Skin: success
        allow(DRC).to receive(:bput)
          .with('skin', anything, anything, anything, anything, anything, anything, anything)
          .and_return('roundtime')

        instance = build_loot_process(tie_bundle: true, skin: true)
        instance.send(:check_skinning, 'kobold', game_state)
      end

      include_examples 'frees a hand before tying the bundle'
      include_examples 'clears need_bundle on game_state'
    end

    context 'when need_bundle is true, bundle is lumpy, and one hand is free' do
      let(:game_state) { build_game_state(need_bundle: true) }

      before(:each) do
        $right_hand = 'bastard sword'
        $left_hand = nil

        allow(DRC).to receive(:bput)
          .with('tap my bundle', anything, anything, anything)
          .and_return('You tap a lumpy bundle that you are wearing')
        allow(DRC).to receive(:bput)
          .with('tie my bundle', 'TIE the bundle again', 'But this bundle has already been tied off')
          .and_return('TIE the bundle again')
        allow(DRC).to receive(:bput)
          .with('tie my bundle', 'you tie the bundle', 'But this bundle has already been tied off', "You don't seem to be able to do that right now")
          .and_return('you tie the bundle')
        allow(DRC).to receive(:bput)
          .with('adjust my bundle', /^You adjust your .*/, /You'll need a free hand for that/)
          .and_return('You adjust your lumpy bundle so that you can more easily')
        allow(DRC).to receive(:bput)
          .with('skin', anything, anything, anything, anything, anything, anything, anything)
          .and_return('roundtime')

        instance = build_loot_process(tie_bundle: true, skin: true)
        instance.send(:check_skinning, 'kobold', game_state)
      end

      include_examples 'does not lower any item'
      include_examples 'clears need_bundle on game_state'

      it 'does not attempt to pick up a lowered item' do
        expect(DRCI).not_to have_received(:get_item?)
      end
    end

    context 'when need_bundle is true, bundle is lumpy with bundling rope, and both hands are full' do
      let(:game_state) { build_game_state(need_bundle: true) }

      before(:each) do
        $right_hand = 'bastard sword'
        $left_hand = 'javelin'

        # tap: lumpy bundle with extra description from bundling rope
        allow(DRC).to receive(:bput)
          .with('tap my bundle', anything, anything, anything)
          .and_return('You tap a lumpy bundle bound by a braided bundling rope that you are wearing')
        allow(DRC).to receive(:bput)
          .with('tie my bundle', 'TIE the bundle again', 'But this bundle has already been tied off')
          .and_return('TIE the bundle again')
        allow(DRC).to receive(:bput)
          .with('tie my bundle', 'you tie the bundle', 'But this bundle has already been tied off', "You don't seem to be able to do that right now")
          .and_return('you tie the bundle')
        allow(DRC).to receive(:bput)
          .with('adjust my bundle', /^You adjust your .*/, /You'll need a free hand for that/)
          .and_return('You adjust your lumpy bundle so that you can more easily')
        allow(DRC).to receive(:bput)
          .with('skin', anything, anything, anything, anything, anything, anything, anything)
          .and_return('roundtime')

        instance = build_loot_process(tie_bundle: true, skin: true)
        instance.send(:check_skinning, 'kobold', game_state)
      end

      include_examples 'frees a hand before tying the bundle'
      include_examples 'clears need_bundle on game_state'
    end

    context 'when need_bundle is true and bundle is tight (already tied)' do
      let(:game_state) { build_game_state(need_bundle: true) }

      before(:each) do
        $right_hand = 'bastard sword'
        $left_hand = 'javelin'

        allow(DRC).to receive(:bput)
          .with('tap my bundle', anything, anything, anything)
          .and_return('You tap a tight bundle inside')
        allow(DRC).to receive(:bput)
          .with('skin', anything, anything, anything, anything, anything, anything, anything)
          .and_return('roundtime')

        instance = build_loot_process(tie_bundle: true, skin: true)
        instance.send(:check_skinning, 'kobold', game_state)
      end

      include_examples 'clears need_bundle on game_state'

      it 'does not attempt to tie the bundle' do
        expect(DRC).not_to have_received(:bput).with('tie my bundle', anything, anything)
      end
    end

    context 'when need_bundle is true, bundle is lumpy, and @tie_bundle is false' do
      let(:game_state) { build_game_state(need_bundle: true) }

      before(:each) do
        $right_hand = 'bastard sword'
        $left_hand = 'javelin'

        allow(DRC).to receive(:bput)
          .with('tap my bundle', anything, anything, anything)
          .and_return('You tap a lumpy bundle that you are wearing')
        allow(DRC).to receive(:bput)
          .with('skin', anything, anything, anything, anything, anything, anything, anything)
          .and_return('roundtime')

        instance = build_loot_process(tie_bundle: false, skin: true)
        instance.send(:check_skinning, 'kobold', game_state)
      end

      include_examples 'clears need_bundle on game_state'

      it 'does not attempt to tie the bundle' do
        expect(DRC).not_to have_received(:bput).with('tie my bundle', anything, anything)
      end
    end

    context 'when need_bundle is false' do
      let(:game_state) { build_game_state(need_bundle: false) }

      before(:each) do
        $right_hand = 'bastard sword'
        $left_hand = 'javelin'

        allow(DRC).to receive(:bput)
          .with('skin', anything, anything, anything, anything, anything, anything, anything)
          .and_return('roundtime')

        instance = build_loot_process(tie_bundle: true, skin: true)
        instance.send(:check_skinning, 'kobold', game_state)
      end

      it 'does not tap the bundle' do
        expect(DRC).not_to have_received(:bput).with('tap my bundle', anything, anything, anything)
      end
    end
  end
end

# ===========================================================================
# GameState#skill_done? specs
#
# Validates that ignore_weapon_mindstate controls whether weapon switching
# is driven by mindstate (exp) or purely by action count.
# ===========================================================================
RSpec.describe GameState do
  # Build a GameState via allocate to bypass initialize (avoids settings/game I/O).
  # Sets only the instance variables relevant to skill_done?.
  def build_game_state_instance(**overrides)
    instance = GameState.allocate
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
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  before(:each) do
    allow(DRSkill).to receive(:getxp).and_return(0)
    allow(DRSkill).to receive(:getrank).and_return(100)
  end

  describe '#skill_done?' do
    # =========================================================================
    # Shared examples -- DRY assertions for the two decision modes
    # =========================================================================
    shared_examples 'switches only on action count' do |exp_value|
      it 'returns false when action count is below target' do
        allow(DRSkill).to receive(:getxp).and_return(exp_value)
        gs = build_game_state_instance(
          ignore_weapon_mindstate: true,
          action_count: 5,
          target_action_count: 25
        )
        expect(gs.skill_done?).to be false
      end

      it 'returns true when action count meets target' do
        allow(DRSkill).to receive(:getxp).and_return(exp_value)
        gs = build_game_state_instance(
          ignore_weapon_mindstate: true,
          action_count: 25,
          target_action_count: 25
        )
        expect(gs.skill_done?).to be true
      end

      it 'returns true when action count exceeds target' do
        allow(DRSkill).to receive(:getxp).and_return(exp_value)
        gs = build_game_state_instance(
          ignore_weapon_mindstate: true,
          action_count: 30,
          target_action_count: 25
        )
        expect(gs.skill_done?).to be true
      end
    end

    context 'with ignore_weapon_mindstate true' do
      context 'when exp is 0 (fresh skill)' do
        include_examples 'switches only on action count', 0
      end

      context 'when exp is 17 (mid-training)' do
        include_examples 'switches only on action count', 17
      end

      context 'when exp is 34 (capped)' do
        include_examples 'switches only on action count', 34
      end
    end

    context 'with ignore_weapon_mindstate false' do
      it 'returns true when exp is 34 regardless of action count' do
        allow(DRSkill).to receive(:getxp).and_return(34)
        gs = build_game_state_instance(
          ignore_weapon_mindstate: false,
          action_count: 0,
          target_action_count: 25
        )
        expect(gs.skill_done?).to be true
      end

      it 'returns true when action count meets target with exp at 0' do
        allow(DRSkill).to receive(:getxp).and_return(0)
        gs = build_game_state_instance(
          ignore_weapon_mindstate: false,
          action_count: 25,
          target_action_count: 25,
          target_weapon_skill: 34
        )
        expect(gs.skill_done?).to be true
      end

      it 'returns true when exp meets target_weapon_skill with low action count' do
        allow(DRSkill).to receive(:getxp).and_return(20)
        gs = build_game_state_instance(
          ignore_weapon_mindstate: false,
          action_count: 3,
          target_action_count: 25,
          target_weapon_skill: 20
        )
        expect(gs.skill_done?).to be true
      end

      it 'returns false when exp is 17 and action count is below target' do
        allow(DRSkill).to receive(:getxp).and_return(17)
        gs = build_game_state_instance(
          ignore_weapon_mindstate: false,
          action_count: 5,
          target_action_count: 25,
          target_weapon_skill: 20
        )
        expect(gs.skill_done?).to be false
      end

      it 'returns false when exp is 0 and action count is below target' do
        allow(DRSkill).to receive(:getxp).and_return(0)
        gs = build_game_state_instance(
          ignore_weapon_mindstate: false,
          action_count: 0,
          target_action_count: 25,
          target_weapon_skill: 20
        )
        expect(gs.skill_done?).to be false
      end
    end
  end
end

# ===========================================================================
# SetupProcess#determine_next_to_train specs
#
# Validates the all-weapons-locked guard: when all weapons are at 34/34,
# stay on the current weapon (5a) or select one if none equipped (5b).
# ===========================================================================
RSpec.describe SetupProcess do
  def build_setup_process(**overrides)
    instance = SetupProcess.allocate
    defaults = {
      ignore_weapon_mindstate: false,
      offhand_trainables: false,
      priority_weapons: []
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  before(:each) do
    allow(DRSkill).to receive(:getxp).and_return(34)
    allow(DRSkill).to receive(:getrank).and_return(100)
  end

  describe '#determine_next_to_train' do
    let(:weapon_training) { { 'Bow' => 'longbow', 'Slings' => 'sling', 'Crossbow' => 'latchbow' } }

    # Build a game_state double for determine_next_to_train tests.
    # SRP: isolate the game_state interface from test setup details.
    def build_game_state_double(weapon_skill:, skill_done: true)
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

    context 'when all weapons at 34 and weapon is equipped (5a)' do
      it 'returns without switching weapons' do
        game_state = build_game_state_double(weapon_skill: 'Bow')
        setup = build_setup_process

        setup.send(:determine_next_to_train, game_state, weapon_training, false)

        expect(game_state).not_to have_received(:update_weapon_info)
      end
    end

    context 'when all weapons at 34 and no weapon equipped (5b)' do
      it 'falls through to weapon selection' do
        game_state = build_game_state_double(weapon_skill: nil)
        setup = build_setup_process

        setup.send(:determine_next_to_train, game_state, weapon_training, false)

        expect(game_state).to have_received(:update_weapon_info)
      end
    end

    context 'when some weapons below 34' do
      it 'proceeds to weapon selection' do
        allow(DRSkill).to receive(:getxp).and_return(34)
        allow(DRSkill).to receive(:getxp).with('Slings').and_return(17)

        game_state = build_game_state_double(weapon_skill: 'Bow')
        setup = build_setup_process

        setup.send(:determine_next_to_train, game_state, weapon_training, false)

        expect(game_state).to have_received(:update_weapon_info)
      end
    end

    context 'when all weapons at 0 (fresh start)' do
      it 'proceeds to weapon selection' do
        allow(DRSkill).to receive(:getxp).and_return(0)

        game_state = build_game_state_double(weapon_skill: 'Bow')
        setup = build_setup_process

        setup.send(:determine_next_to_train, game_state, weapon_training, false)

        expect(game_state).to have_received(:update_weapon_info)
      end
    end

    context 'with ignore_weapon_mindstate true and all weapons at 34' do
      it 'skips the all-locked guard and proceeds to weapon selection' do
        game_state = build_game_state_double(weapon_skill: 'Bow')
        setup = build_setup_process(ignore_weapon_mindstate: true)

        setup.send(:determine_next_to_train, game_state, weapon_training, false)

        expect(game_state).to have_received(:update_weapon_info)
      end
    end

    context 'with ignore_weapon_mindstate true and all weapons at 0' do
      it 'proceeds to weapon selection' do
        allow(DRSkill).to receive(:getxp).and_return(0)

        game_state = build_game_state_double(weapon_skill: 'Bow')
        setup = build_setup_process(ignore_weapon_mindstate: true)

        setup.send(:determine_next_to_train, game_state, weapon_training, false)

        expect(game_state).to have_received(:update_weapon_info)
      end
    end

    context 'when skill_done? returns false' do
      it 'returns early without any weapon switching' do
        game_state = build_game_state_double(weapon_skill: 'Bow', skill_done: false)
        # weapon_training includes current weapon so !weapon_training[weapon_skill] is false
        setup = build_setup_process

        setup.send(:determine_next_to_train, game_state, weapon_training, false)

        expect(game_state).not_to have_received(:update_weapon_info)
      end
    end

    # =========================================================================
    # Blank/nil weapon_training guard
    # =========================================================================
    shared_examples 'returns without selecting a weapon' do
      it 'does not call skill_done? or update_weapon_info' do
        expect(game_state).not_to have_received(:skill_done?)
        expect(game_state).not_to have_received(:update_weapon_info)
      end

      it 'warns the user with a DRC.message' do
        expect(DRC).to have_received(:message).with(/No weapons configured/).at_least(:once)
      end
    end

    context 'when weapon_training is empty' do
      let(:game_state) { build_game_state_double(weapon_skill: nil) }

      before(:each) do
        allow(DRC).to receive(:message)
        setup = build_setup_process
        setup.send(:determine_next_to_train, game_state, {}, false)
      end

      include_examples 'returns without selecting a weapon'
    end

    context 'when weapon_training is nil' do
      let(:game_state) { build_game_state_double(weapon_skill: nil) }

      before(:each) do
        allow(DRC).to receive(:message)
        setup = build_setup_process
        setup.send(:determine_next_to_train, game_state, nil, false)
      end

      include_examples 'returns without selecting a weapon'
    end

    # =========================================================================
    # User-facing messaging
    # =========================================================================
    context 'messaging for 5a (all at 34, weapon equipped)' do
      it 'warns the user once about continuing with current weapon' do
        allow(DRC).to receive(:message)
        game_state = build_game_state_double(weapon_skill: 'Bow')
        setup = build_setup_process

        setup.send(:determine_next_to_train, game_state, weapon_training, false)
        setup.send(:determine_next_to_train, game_state, weapon_training, false)

        expect(DRC).to have_received(:message).with(/Continuing to attack with Bow/).once
      end
    end

    context 'messaging for 5b (all at 34, no weapon equipped)' do
      it 'warns the user once about selecting initial weapon' do
        allow(DRC).to receive(:message)
        game_state = build_game_state_double(weapon_skill: nil)
        setup = build_setup_process

        setup.send(:determine_next_to_train, game_state, weapon_training, false)

        expect(DRC).to have_received(:message).with(/Selecting initial weapon/).once
      end
    end

    context 'messaging for ignore_weapon_mindstate when all at 34' do
      it 'warns the user once about cycling by action count' do
        allow(DRC).to receive(:message)
        game_state = build_game_state_double(weapon_skill: 'Bow')
        setup = build_setup_process(ignore_weapon_mindstate: true)

        setup.send(:determine_next_to_train, game_state, weapon_training, false)
        setup.send(:determine_next_to_train, game_state, weapon_training, false)

        expect(DRC).to have_received(:message).with(/Cycling weapons by combat_trainer_action_count/).once
      end
    end

    context 'messaging for ignore_weapon_mindstate when not all at 34' do
      it 'does not warn about action count cycling' do
        allow(DRC).to receive(:message)
        allow(DRSkill).to receive(:getxp).and_return(17)
        game_state = build_game_state_double(weapon_skill: 'Bow')
        setup = build_setup_process(ignore_weapon_mindstate: true)

        setup.send(:determine_next_to_train, game_state, weapon_training, false)

        expect(DRC).not_to have_received(:message).with(/Cycling weapons by combat_trainer_action_count/)
      end
    end
  end
end
