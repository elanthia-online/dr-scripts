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
  def self.bput(*_args)
    $mock_bput_result || 'Roundtime'
  end

  def self.left_hand
    $left_hand
  end

  def self.right_hand
    $right_hand
  end

  def self.wait_for_script_to_complete(*_args); end
end

module DRCC
  def self.get_crafting_item(*_args); end

  def self.stow_crafting_item(*_args); end

  def self.find_recipe2(*_args); end
end

module DRCI
  def self.exists?(*_args)
    $mock_drci_exists.nil? ? true : $mock_drci_exists
  end

  def self.get_item?(*_args)
    $mock_drci_get_item.nil? ? true : $mock_drci_get_item
  end

  def self.dispose_trash(*_args); end
end

module DRCA
  def self.cast_spell?(*_args)
    $mock_drca_cast_spell.nil? ? true : $mock_drca_cast_spell
  end
end

module Lich
  module Messaging
    def self.msg(*_args); end
  end
end

class EquipmentManager
  def empty_hands; end
end

load_lic_class('enchant.lic', 'Enchant')

RSpec.describe Enchant do
  before(:each) do
    reset_data
    $mock_bput_result = nil
    $mock_drci_exists = nil
    $mock_drci_get_item = nil
    $mock_drca_cast_spell = nil
    $left_hand = nil
    $right_hand = nil
  end

  # Helper: create a bare Enchant instance without running initialize
  def build_instance(**overrides)
    instance = Enchant.allocate
    # Set default ivars
    instance.instance_variable_set(:@settings, OpenStruct.new(
                                                 crafting_container: 'backpack',
                                                 crafting_items_in_container: ['burin'],
                                                 enchanting_belt: 'toolbelt',
                                                 mark_crafted_goods: false,
                                                 worn_trashcan: 'bucket',
                                                 worn_trashcan_verb: 'put',
                                                 enchanting_tools: ['brazier', 'fount', 'aug loop', 'rod', 'burin'],
                                                 master_crafting_book: nil,
                                                 cube_armor_piece: nil
                                               ))
    instance.instance_variable_set(:@bag, 'backpack')
    instance.instance_variable_set(:@bag_items, ['burin'])
    instance.instance_variable_set(:@belt, 'toolbelt')
    instance.instance_variable_set(:@brazier, 'brazier')
    instance.instance_variable_set(:@fount, 'fount')
    instance.instance_variable_set(:@loop, 'aug loop')
    instance.instance_variable_set(:@imbue_wand, 'rod')
    instance.instance_variable_set(:@burin, 'burin')
    instance.instance_variable_set(:@item, 'totem')
    instance.instance_variable_set(:@baseitem, 'totem')
    instance.instance_variable_set(:@use_own_brazier, true)
    instance.instance_variable_set(:@worn_trashcan, 'bucket')
    instance.instance_variable_set(:@worn_trashcan_verb, 'put')
    instance.instance_variable_set(:@stamp, false)
    instance.instance_variable_set(:@equipment_manager, EquipmentManager.new)
    overrides.each { |k, v| instance.instance_variable_set(:"@#{k}", v) }
    instance
  end

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  describe 'constants' do
    it 'defines ANALYZE_READY_PATTERNS as frozen array' do
      expect(Enchant::ANALYZE_READY_PATTERNS).to be_frozen
      expect(Enchant::ANALYZE_READY_PATTERNS).to be_an(Array)
    end

    it 'defines BRAZIER_CONTENTS_PATTERN with named capture' do
      pattern = Enchant::BRAZIER_CONTENTS_PATTERN
      match = pattern.match('On the brass brazier you see a fount and a totem.')
      expect(match).not_to be_nil
      expect(match[:items]).to eq('a fount and a totem')
    end

    it 'defines FLAG_NAMES as frozen array' do
      expect(Enchant::FLAG_NAMES).to be_frozen
      expect(Enchant::FLAG_NAMES).to include('enchant-complete')
    end
  end

  # ---------------------------------------------------------------------------
  # setup_flags / cleanup_flags
  # ---------------------------------------------------------------------------

  describe '#setup_flags' do
    it 'calls Flags.add for all required flags' do
      instance = build_instance

      expect(Flags).to receive(:add).with('enchant-focus', anything)
      expect(Flags).to receive(:add).with('enchant-meditate', anything)
      expect(Flags).to receive(:add).with('enchant-imbue', anything)
      expect(Flags).to receive(:add).with('enchant-push', anything)
      expect(Flags).to receive(:add).with('enchant-sigil', anything)
      expect(Flags).to receive(:add).with('enchant-complete', anything, anything, anything, anything)
      expect(Flags).to receive(:add).with('imbue-failed', anything)
      expect(Flags).to receive(:add).with('imbue-backlash', anything)

      instance.send(:setup_flags)
    end
  end

  describe '#cleanup_flags' do
    it 'calls Flags.delete for all flags' do
      instance = build_instance

      Enchant::FLAG_NAMES.each do |flag|
        expect(Flags).to receive(:delete).with(flag)
      end

      instance.send(:cleanup_flags)
    end
  end

  # ---------------------------------------------------------------------------
  # empty_brazier - named capture extraction
  # ---------------------------------------------------------------------------

  describe '#empty_brazier' do
    it 'extracts items using named capture from brazier contents' do
      instance = build_instance

      allow(DRC).to receive(:bput).and_return('On the brass brazier you see a fount and a totem.')
      expect(DRCI).to receive(:get_item?).with('fount', 'brazier').and_return(true)
      expect(DRCI).to receive(:get_item?).with('totem', 'brazier').and_return(true)
      expect(DRCC).to receive(:stow_crafting_item).twice

      instance.send(:empty_brazier)
    end

    it 'handles nothing on brazier' do
      instance = build_instance

      allow(DRC).to receive(:bput).and_return('There is nothing')
      expect(DRCI).not_to receive(:get_item?)

      instance.send(:empty_brazier)
    end

    it 'logs error when item cannot be retrieved' do
      instance = build_instance

      allow(DRC).to receive(:bput).and_return('On the brass brazier you see a fount.')
      expect(DRCI).to receive(:get_item?).with('fount', 'brazier').and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to get fount/)

      instance.send(:empty_brazier)
    end
  end

  # ---------------------------------------------------------------------------
  # scribe - the main bug fix (waitrt? before recursive call)
  # ---------------------------------------------------------------------------

  describe '#scribe' do
    it 'checks enchant-complete flag before scribing again' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-focus').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-meditate').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-push').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-imbue').and_return(nil)
      allow(Flags).to receive(:[]).with('imbue-backlash').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-complete').and_return(true)

      expect(instance).to receive(:handle_complete_flag)
      expect(DRC).not_to receive(:bput)

      instance.send(:scribe)
    end

    it 'checks enchant-sigil flag and handles it' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return({ type: 'induction ', order: 'primary' })

      expect(instance).to receive(:handle_sigil_flag)

      instance.send(:scribe)
    end

    it 'checks imbue-backlash flag' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-focus').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-meditate').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-push').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-imbue').and_return(nil)
      allow(Flags).to receive(:[]).with('imbue-backlash').and_return(true)

      expect(instance).to receive(:handle_backlash_flag)

      instance.send(:scribe)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_sigil_flag
  # ---------------------------------------------------------------------------

  describe '#handle_sigil_flag' do
    it 'extracts sigil type from flag and traces it' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return({ type: 'induction ', order: 'primary' })
      allow(Flags).to receive(:reset).with('enchant-sigil')

      expect(DRCC).to receive(:stow_crafting_item).with('burin', 'backpack', 'toolbelt')
      expect(instance).to receive(:trace_sigil).with('induction')
      expect(DRCC).to receive(:get_crafting_item)
      expect(instance).to receive(:scribe)

      instance.send(:handle_sigil_flag)
    end

    it 'defaults to congruence sigil when type is empty' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return({ type: '', order: 'primary' })
      allow(Flags).to receive(:reset).with('enchant-sigil')

      expect(instance).to receive(:trace_sigil).with('congruence')
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCC).to receive(:get_crafting_item)
      allow(instance).to receive(:scribe)

      instance.send(:handle_sigil_flag)
    end
  end

  # ---------------------------------------------------------------------------
  # trace_sigil
  # ---------------------------------------------------------------------------

  describe '#trace_sigil' do
    it 'gets sigil, studies it, and traces on item' do
      instance = build_instance

      expect(DRCI).to receive(:get_item?).with('induction sigil').and_return(true)
      expect(DRC).to receive(:bput).with('study my induction sigil', Enchant::SIGIL_STUDY_SUCCESS)
      expect(DRC).to receive(:bput).with('trace totem on brazier', Enchant::SIGIL_TRACE_SUCCESS)

      instance.send(:trace_sigil, 'induction')
    end

    it 'logs error and returns early when sigil not found' do
      instance = build_instance

      expect(DRCI).to receive(:get_item?).with('induction sigil').and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to get induction sigil/)
      expect(DRC).not_to receive(:bput)

      instance.send(:trace_sigil, 'induction')
    end
  end

  # ---------------------------------------------------------------------------
  # handle_complete_flag
  # ---------------------------------------------------------------------------

  describe '#handle_complete_flag' do
    it 'outputs completion message and calls cleanup' do
      instance = build_instance

      expect(Lich::Messaging).to receive(:msg).with('plain', 'Enchant: Enchanting complete!')
      expect(instance).to receive(:cleanup)

      instance.send(:handle_complete_flag)
    end

    it 'stamps item when @stamp is true' do
      instance = build_instance(stamp: true)

      allow(Lich::Messaging).to receive(:msg)
      allow(instance).to receive(:cleanup)
      expect(instance).to receive(:stamp_item).with('totem')

      instance.send(:handle_complete_flag)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_backlash_flag
  # ---------------------------------------------------------------------------

  describe '#handle_backlash_flag' do
    it 'outputs error message, cleans up, and goes to safe room' do
      instance = build_instance

      expect(Lich::Messaging).to receive(:msg).with('bold', /Imbue backlash occurred/)
      expect(instance).to receive(:cleanup)
      expect(DRC).to receive(:wait_for_script_to_complete).with('safe-room', ['force'])

      instance.send(:handle_backlash_flag)
    end
  end

  # ---------------------------------------------------------------------------
  # imbue
  # ---------------------------------------------------------------------------

  describe '#imbue' do
    context 'with waggle spell config' do
      it 'casts spell using DRCA and retries on failure' do
        instance = build_instance(
          settings: OpenStruct.new(
            'waggle_sets' => { 'imbue' => { 'Imbue' => { 'mana' => 20 } } }
          )
        )

        # First call fails, second succeeds
        call_count = 0
        allow(DRCA).to receive(:cast_spell?) do
          call_count += 1
          call_count > 1
        end
        allow(Flags).to receive(:reset).with('enchant-imbue')

        expect(Lich::Messaging).to receive(:msg).with('bold', /Casting Imbue failed/).once

        instance.send(:imbue)
      end
    end

    context 'with imbue wand' do
      it 'waves wand at item on brazier' do
        instance = build_instance(
          settings: OpenStruct.new('waggle_sets' => { 'imbue' => {} })
        )
        $left_hand = nil

        expect(DRCC).to receive(:get_crafting_item).with('rod', 'backpack', ['burin'], 'toolbelt')
        expect(DRC).to receive(:bput).with(
          'wave rod at totem on brazier',
          Enchant::IMBUE_WAND_SUCCESS,
          Enchant::IMBUE_WAND_SIGIL_NEEDED,
          Enchant::IMBUE_WAND_FAILED
        ).and_return('Roundtime')
        allow(Flags).to receive(:reset).with('enchant-imbue')

        instance.send(:imbue)
      end

      it 'retries when wand fails' do
        instance = build_instance(
          settings: OpenStruct.new('waggle_sets' => { 'imbue' => {} })
        )
        $left_hand = 'rod'

        # First call fails, second succeeds
        call_count = 0
        allow(DRC).to receive(:bput) do
          call_count += 1
          call_count > 1 ? 'Roundtime' : Enchant::IMBUE_WAND_FAILED
        end
        allow(Flags).to receive(:reset).with('enchant-imbue')

        expect(Lich::Messaging).to receive(:msg).with('bold', /Imbue wand failed/).once

        instance.send(:imbue)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # clean_brazier
  # ---------------------------------------------------------------------------

  describe '#clean_brazier' do
    it 'cleans brazier when successful' do
      instance = build_instance

      expect(DRC).to receive(:bput).with(
        'clean brazier',
        Enchant::CLEAN_SUCCESS,
        Enchant::CLEAN_NOTHING,
        Enchant::CLEAN_NOT_LIT
      ).and_return(Enchant::CLEAN_SUCCESS)
      expect(DRC).to receive(:bput).with('clean brazier', Enchant::CLEAN_SINGED)

      instance.send(:clean_brazier)
    end

    it 'stows left hand when brazier not lit' do
      instance = build_instance
      $left_hand = 'burin'

      allow(DRC).to receive(:bput).and_return(Enchant::CLEAN_NOT_LIT)
      expect(DRCC).to receive(:stow_crafting_item).with('burin', 'backpack', 'toolbelt')

      instance.send(:clean_brazier)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_new_enchant - fount existence check
  # ---------------------------------------------------------------------------

  describe '#handle_new_enchant' do
    it 'exits early with message when fount not found' do
      instance = build_instance(item: 'totem')
      $mock_drci_exists = false

      allow(instance).to receive(:study_recipe)
      expect(Lich::Messaging).to receive(:msg).with('bold', /fount not found in inventory/)
      expect(instance).to receive(:cleanup)
      expect(instance).not_to receive(:imbue)

      instance.send(:handle_new_enchant)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_resume
  # ---------------------------------------------------------------------------

  describe '#handle_resume' do
    it 'logs error for unexpected analyze result' do
      instance = build_instance
      $mock_bput_result = 'Something unexpected'

      allow(DRCC).to receive(:get_crafting_item)
      expect(Lich::Messaging).to receive(:msg).with('bold', /Unexpected analyze result/)

      instance.send(:handle_resume)
    end
  end
end
