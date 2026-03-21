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
      false
    end

    def dispose_trash(*_args); end

    def wear_item?(*_args)
      true
    end

    def fill_gem_pouch_with_container(*_args); end

    def count_all_boxes(*_args)
      0
    end

    def swap_out_full_gempouch?(*_args)
      true
    end

    def put_away_item?(*_args)
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

# ===========================================================================
# LootProcess#stow_loot -- gem pouch swap when pouch is full
#
# Flow: stow_loot tries to stow an item. If the pouch-full flag fires
# (set by a game message matcher), the method drops the item, swaps
# the full pouch for a spare via DRCI.swap_out_full_gempouch?, then
# picks up the dropped gem.
# ===========================================================================
RSpec.describe LootProcess do
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
      loot_bodies: true,
      lootables: [],
      gem_nouns: ['diamond'],
      box_nouns: [],
      box_loot_limit: nil,
      current_box_count: 0,
      loot_specials: [],
      gem_pouch_adjective: 'black',
      gem_pouch_noun: 'pouch',
      full_pouch_container: 'backpack',
      spare_gem_pouch_container: 'locker',
      tie_pouch: false,
      equipment_manager: double('EquipmentManager', stow_weapon: nil, wield_weapon?: nil, is_listed_item?: false)
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  def build_game_state(**attrs)
    defaults = {
      need_bundle: false,
      mob_died: false,
      npcs: [],
      skinnable?: false,
      finish_killing?: false,
      finish_spell_casting?: false,
      stowing?: false,
      currently_whirlwinding: false
    }
    state = double('GameState', defaults.merge(attrs))
    allow(state).to receive(:unlootable)
    allow(state).to receive(:lootable?).and_return(true)
    state
  end

  describe '#stow_loot (pouch-full swap)' do
    before(:each) do
      # Allow all bput calls by default (stow, drop, etc.)
      allow(DRC).to receive(:bput).and_return('You put')
      allow(DRCI).to receive(:swap_out_full_gempouch?).and_return(true)
      allow(DRCI).to receive(:get_item_unsafe).and_return(false)
    end

    context 'when pouch-full flag is set and swap succeeds' do
      let(:game_state) { build_game_state }

      before(:each) do
        Flags['container-full'] = nil
        # The pouch-full flag fires as a side effect during the stow bput call.
        # Simulate this by having the stow bput set the flag.
        allow(DRC).to receive(:bput).with(/^stow /, *Array.new(15, anything)) do
          Flags['pouch-full'] = true
          'You put'
        end
      end

      it 'calls DRCI.swap_out_full_gempouch? with correct arguments' do
        instance = build_loot_process
        instance.send(:stow_loot, 'diamond', game_state)

        expect(DRCI).to have_received(:swap_out_full_gempouch?).with(
          'black', 'pouch', 'backpack', 'locker', false
        )
      end

      it 'passes tie_pouch=true when configured' do
        instance = build_loot_process(tie_pouch: true)
        instance.send(:stow_loot, 'diamond', game_state)

        expect(DRCI).to have_received(:swap_out_full_gempouch?).with(
          'black', 'pouch', 'backpack', 'locker', true
        )
      end

      it 'picks up the dropped gem after successful swap' do
        instance = build_loot_process
        instance.send(:stow_loot, 'diamond', game_state)

        expect(DRC).to have_received(:bput).with('stow gem', anything, anything, anything, anything, anything, anything, anything)
      end

      it 'does not mark item as unlootable' do
        instance = build_loot_process
        instance.send(:stow_loot, 'diamond', game_state)

        expect(game_state).not_to have_received(:unlootable)
      end
    end

    context 'when pouch-full flag is set and swap fails' do
      let(:game_state) { build_game_state }

      before(:each) do
        Flags['container-full'] = nil
        allow(DRC).to receive(:bput).with(/^stow /, *Array.new(15, anything)) do
          Flags['pouch-full'] = true
          'You put'
        end
        allow(DRCI).to receive(:swap_out_full_gempouch?).and_return(false)
      end

      it 'marks item as unlootable' do
        instance = build_loot_process
        instance.send(:stow_loot, 'diamond', game_state)

        expect(game_state).to have_received(:unlootable).with('diamond')
      end

      it 'does not try to pick up the gem' do
        instance = build_loot_process
        instance.send(:stow_loot, 'diamond', game_state)

        expect(DRC).not_to have_received(:bput).with('stow gem', anything, anything, anything, anything, anything, anything, anything)
      end
    end

    context 'when pouch-full flag is set but no spare container configured' do
      let(:game_state) { build_game_state }

      before(:each) do
        Flags['container-full'] = nil
        allow(DRC).to receive(:bput).with(/^stow /, *Array.new(15, anything)) do
          Flags['pouch-full'] = true
          'You put'
        end
      end

      it 'marks item unlootable without attempting swap' do
        instance = build_loot_process(spare_gem_pouch_container: nil)
        instance.send(:stow_loot, 'diamond', game_state)

        expect(game_state).to have_received(:unlootable).with('diamond')
        expect(DRCI).not_to have_received(:swap_out_full_gempouch?)
      end
    end

    context 'when pouch-full flag is not set' do
      let(:game_state) { build_game_state }

      before(:each) do
        Flags['pouch-full'] = nil
        Flags['container-full'] = nil
      end

      it 'does not attempt to swap pouches' do
        instance = build_loot_process
        instance.send(:stow_loot, 'diamond', game_state)

        expect(DRCI).not_to have_received(:swap_out_full_gempouch?)
      end
    end
  end
end
