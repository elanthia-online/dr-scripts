require 'ostruct'

require_relative 'spec_helper'

# Load the Repair class without executing repair.lic's top-level code. The
# shared game doubles (DRCC.get_crafting_item / stow_crafting_item, DRCI, etc.)
# come from test/test_harness.rb via spec_helper -- per the spec_helper header,
# they must never be reopened here; examples override them with `allow(...)`.
load_lic_class('repair.lic', 'Repair')

RSpec.describe Repair do
  # The methods under test read only @disciplines / @settings (build_tool_lists)
  # and @toolbelts_list / @toolset_list / @bag / @bag_items (smart_get/stow), so
  # a bare allocated instance with those injected isolates the belt logic.
  let(:repair) { Repair.allocate }

  # Real discipline order from Repair#initialize; the new sub-discipline belts
  # (carving/shaping/tinkering) live between forging and outfitting.
  let(:disciplines) { %w[forging tinkering carving shaping outfitting alchemy enchanting engineering] }

  describe '#build_tool_lists' do
    before(:each) { repair.instance_variable_set(:@disciplines, disciplines) }

    # Issue #1420: carving_belt/shaping_belt/tinkering_belt are new and usually
    # unset, so @settings.send('carving_belt') is nil. The list must exclude
    # those nils or smart_get_gear/smart_stow_gear crash on belt["items"].
    it 'excludes disciplines whose belt is unset (nil), leaving no nil holes' do
      repair.instance_variable_set(:@settings, OpenStruct.new(
                                                 forging_belt: { 'name' => 'forging belt', 'items' => ['hammer'] },
                                                 engineering_belt: { 'name' => 'engineering belt', 'items' => ['shaper'] }
                                               ))
      toolbelts, = repair.build_tool_lists
      expect(toolbelts).not_to include(nil)
      expect(toolbelts).to contain_exactly(
        { 'name' => 'forging belt', 'items' => ['hammer'] },
        { 'name' => 'engineering belt', 'items' => ['shaper'] }
      )
    end

    it 'excludes disciplines whose tools are unset (nil)' do
      repair.instance_variable_set(:@settings, OpenStruct.new(
                                                 forging_tools: %w[hammer tongs]
                                               ))
      _, toolsets = repair.build_tool_lists
      expect(toolsets).not_to include(nil)
      expect(toolsets).to eq([%w[hammer tongs]])
    end

    it 'includes a configured sub-discipline belt (carving_belt)' do
      carving = { 'name' => 'carving belt', 'items' => ['rasp'] }
      engineering = { 'name' => 'engineering belt', 'items' => ['shaper'] }
      repair.instance_variable_set(:@settings, OpenStruct.new(carving_belt: carving, engineering_belt: engineering))
      toolbelts, = repair.build_tool_lists
      expect(toolbelts).to contain_exactly(carving, engineering)
    end

    it 'returns two empty lists when nothing is configured' do
      repair.instance_variable_set(:@settings, OpenStruct.new)
      expect(repair.build_tool_lists).to eq([[], []])
    end
  end

  describe '#smart_get_gear' do
    before(:each) do
      repair.instance_variable_set(:@bag, 'backpack')
      repair.instance_variable_set(:@bag_items, [])
      repair.instance_variable_set(:@toolset_list, [])
      allow(DRCC).to receive(:get_crafting_item)
    end

    it 'fetches a tool from the belt whose items include it' do
      belt = { 'name' => 'engineering belt', 'items' => ['shaper', 'carving knife'] }
      repair.instance_variable_set(:@toolbelts_list, [belt])
      repair.smart_get_gear('shaper')
      expect(DRCC).to have_received(:get_crafting_item).with('shaper', 'backpack', [], belt)
    end

    it 'returns false for a nil gear_item without touching the belts' do
      repair.instance_variable_set(:@toolbelts_list, [])
      expect(repair.smart_get_gear(nil)).to be false
      expect(DRCC).not_to have_received(:get_crafting_item)
    end

    # End-to-end: a realistic config (only forging + engineering belts set) must
    # build a nil-free list and resolve a tool without a NoMethodError -- the
    # crash the #1420 nil-guard prevents.
    it 'resolves a tool end-to-end from a config with unset sub-belts, without crashing' do
      repair.instance_variable_set(:@disciplines, disciplines)
      repair.instance_variable_set(:@settings, OpenStruct.new(
                                                 forging_belt: { 'name' => 'forging belt', 'items' => ['hammer'] },
                                                 engineering_belt: { 'name' => 'engineering belt', 'items' => ['shaper'] }
                                               ))
      toolbelts, toolsets = repair.build_tool_lists
      repair.instance_variable_set(:@toolbelts_list, toolbelts)
      repair.instance_variable_set(:@toolset_list, toolsets)
      expect { repair.smart_get_gear('shaper') }.not_to raise_error
      expect(DRCC).to have_received(:get_crafting_item).with('shaper', 'backpack', [], hash_including('name' => 'engineering belt'))
    end
  end

  describe '#smart_stow_gear' do
    before(:each) do
      repair.instance_variable_set(:@bag, 'backpack')
      repair.instance_variable_set(:@toolset_list, [])
      allow(DRCC).to receive(:stow_crafting_item)
    end

    it 'stows a tool into the belt whose items include it' do
      belt = { 'name' => 'forging belt', 'items' => %w[hammer tongs] }
      repair.instance_variable_set(:@toolbelts_list, [belt])
      repair.smart_stow_gear('hammer')
      expect(DRCC).to have_received(:stow_crafting_item).with('hammer', 'backpack', belt)
    end

    it 'returns true for a nil gear_item without touching the belts' do
      repair.instance_variable_set(:@toolbelts_list, [])
      expect(repair.smart_stow_gear(nil)).to be true
      expect(DRCC).not_to have_received(:stow_crafting_item)
    end
  end
end
