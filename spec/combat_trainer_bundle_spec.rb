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

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end
end

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
  # Shared examples — SOLID: extract common assertions for hand-freeing
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
  # #execute — bundle tying in the clean_up path (line ~598)
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
  # #check_skinning — bundle tying before skinning (line ~1099)
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
