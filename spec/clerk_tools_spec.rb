# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('clerk-tools.lic', 'Clerk')

RSpec.describe Clerk do
  # Crossing repair rooms/NPCs, mirroring data/base-crafting.yaml. Only the two
  # keys clerk-tools reads are included so a mismatch is obvious in the failure.
  let(:crafting_data) do
    {
      'blacksmithing' => { 'Crossing' => { 'repair-room' => 8776, 'repair-npc' => 'clerk' } },
      'tailoring'     => { 'Crossing' => { 'repair-room' => 16659, 'repair-npc' => 'clerk' } },
      'shaping'       => { 'Crossing' => { 'repair-room' => 19209, 'repair-npc' => 'Rangu' } },
      'carving'       => { 'Crossing' => { 'repair-room' => 19209, 'repair-npc' => 'Rangu' } },
      'remedies'      => { 'Crossing' => { 'repair-room' => 8860, 'repair-npc' => 'clerk' } },
      'artificing'    => { 'Crossing' => { 'repair-room' => 19209, 'repair-npc' => 'Rangu' } }
    }
  end

  let(:settings) do
    OpenStruct.new(
      hometown: 'Crossing',
      crafting_container: 'backpack',
      crafting_items_in_container: [],
      forging_tools: ['tong'],
      outfitting_tools: ['knitting needle'],
      shaping_tools: ['shaper'],
      carving_tools: ['rifflers'],
      tinkering_tools: ['tinker tools'],
      alchemy_tools: ['pestle'],
      enchanting_tools: ['burin'],
      forging_belt: 'forging belt',
      engineering_belt: 'engineering belt',
      outfitting_belt: 'outfitting belt',
      alchemy_belt: 'alchemy belt',
      enchanting_belt: 'enchanting belt'
    )
  end

  before(:each) do
    $test_settings = settings
    $test_data = OpenStruct.new(crafting: crafting_data)
  end

  # Runs the real initialize for a toolset and reports what it resolved to.
  def resolve(toolset, action = 'get')
    $parsed_args = OpenStruct.new(toolset: toolset, action: action)
    asked_room = nil
    asked_npc = nil
    stowed = []
    allow(DRCT).to receive(:walk_to) { |room| asked_room = room }
    allow(DRC).to receive(:bput) do |command, *_matches|
      asked_npc = command[/^ask (\S+) for /, 1]
      'Ah, yes, we have one of your tools like that'
    end
    allow(DRCC).to receive(:stow_crafting_item) { |tool, _bag, belt| stowed << [tool, belt] }

    described_class.new
    { room: asked_room, npc: asked_npc, tools: stowed.map(&:first), belt: stowed.map(&:last).first }
  end

  describe 'discipline names shared with workorders' do
    {
      'blacksmithing'  => { room: 8776, npc: 'clerk', tools: ['tong'], belt: 'forging belt' },
      'weaponsmithing' => { room: 8776, npc: 'clerk', tools: ['tong'], belt: 'forging belt' },
      'armorsmithing'  => { room: 8776, npc: 'clerk', tools: ['tong'], belt: 'forging belt' },
      'tailoring'      => { room: 16659, npc: 'clerk', tools: ['knitting needle'], belt: 'outfitting belt' },
      'shaping'        => { room: 19209, npc: 'Rangu', tools: ['shaper'], belt: 'engineering belt' },
      'carving'        => { room: 19209, npc: 'Rangu', tools: ['rifflers'], belt: 'engineering belt' },
      'remedies'       => { room: 8860, npc: 'clerk', tools: ['pestle'], belt: 'alchemy belt' },
      'artificing'     => { room: 19209, npc: 'Rangu', tools: ['burin'], belt: 'enchanting belt' }
    }.each do |toolset, expected|
      it "resolves #{toolset} to its society clerk, tools and belt" do
        expect(resolve(toolset)).to include(expected)
      end
    end

    it 'resolves tinkering through the shaping society, which has no area of its own' do
      expect(resolve('tinkering')).to include(room: 19209, npc: 'Rangu', tools: ['tinker tools'], belt: 'engineering belt')
    end
  end

  describe 'legacy core discipline names' do
    # The values each legacy name resolved to before the rename. These are the
    # arguments other scripts (arrows, bolts, create_remedies) still pass.
    {
      'forging'     => { room: 8776, npc: 'clerk', tools: ['tong'], belt: 'forging belt' },
      'outfitting'  => { room: 16659, npc: 'clerk', tools: ['knitting needle'], belt: 'outfitting belt' },
      'engineering' => { room: 19209, npc: 'Rangu', tools: ['shaper'], belt: 'engineering belt' },
      'alchemy'     => { room: 8860, npc: 'clerk', tools: ['pestle'], belt: 'alchemy belt' },
      'enchanting'  => { room: 19209, npc: 'Rangu', tools: ['burin'], belt: 'enchanting belt' }
    }.each do |toolset, expected|
      it "keeps #{toolset} behaving exactly as it did" do
        expect(resolve(toolset)).to include(expected)
      end
    end
  end

  describe 'unconfigured belts' do
    it 'leaves the belt unset when engineering_belt is not configured' do
      settings.engineering_belt = nil
      expect(resolve('carving')[:belt]).to be_nil
    end
  end

  describe 'carving_belt/tinkering_belt overrides (#1420)' do
    it 'prefers carving_belt over engineering_belt when set, matching carve.lic' do
      settings.carving_belt = 'carving belt'
      expect(resolve('carving')[:belt]).to eq('carving belt')
    end

    it 'falls back to engineering_belt when carving_belt is not set' do
      expect(resolve('carving')[:belt]).to eq('engineering belt')
    end

    it 'prefers tinkering_belt over engineering_belt when set, matching tinker.lic' do
      settings.tinkering_belt = 'tinkering belt'
      expect(resolve('tinkering')[:belt]).to eq('tinkering belt')
    end

    it 'falls back to engineering_belt when tinkering_belt is not set' do
      expect(resolve('tinkering')[:belt]).to eq('engineering belt')
    end
  end

  describe 'custom toolsets' do
    before(:each) do
      settings.custom_clerk_tools = {
        'mining' => { area: 'blacksmithing', tool_list: ['tapered shovel'] }
      }
    end

    it 'uses the configured area and tool list, with no belt' do
      expect(resolve('custom=mining')).to include(room: 8776, npc: 'clerk', tools: ['tapered shovel'], belt: nil)
    end

    it 'exits when the named toolset is not configured' do
      $parsed_args = OpenStruct.new(toolset: 'custom=missing', action: 'get')
      expect { described_class.new }.to raise_error(SystemExit)
    end
  end

  describe 'argument validation' do
    it 'accepts every toolset name it advertises' do
      described_class::TOOLSET_NAMES.each do |name|
        expect(name).to match(described_class::TOOLSET_REGEX)
      end
    end

    it 'accepts a custom toolset' do
      expect('custom=mining').to match(described_class::TOOLSET_REGEX)
    end

    it 'rejects names that merely contain a toolset name' do
      expect('woodcarving').not_to match(described_class::TOOLSET_REGEX)
    end

    it 'maps every legacy name onto a known toolset' do
      described_class::LEGACY_TOOLSETS.each_value do |toolset|
        expect(described_class::TOOLSETS).to have_key(toolset)
      end
    end

    it 'points every toolset at an area present in the crafting data' do
      described_class::TOOLSETS.each_value do |toolset|
        expect(get_data('crafting')).to have_key(toolset[:area])
      end
    end
  end

  describe 'unconfigured tools' do
    it 'exits rather than crashing when the tool list setting is unset' do
      settings.carving_tools = nil
      $parsed_args = OpenStruct.new(toolset: 'carving', action: 'get')
      expect { described_class.new }.to raise_error(SystemExit)
    end
  end
end
