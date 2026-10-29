# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')

RSpec.describe TaskMaster do
  # Zasele's search rooms, in the script's order.
  let(:rooms) { [16_145, 16_146, 16_148, 16_150, 16_153, 16_154, 16_147, 16_276, 16_277, 16_278, 16_290] }

  describe '#search_order' do
    let(:tm) { described_class.allocate }

    it 'keeps the list as it is with no last-seen room' do
      expect(tm.search_order(rooms, nil)).to eq(rooms)
    end

    it 'keeps the list as it is when the last-seen room is not one of the search rooms' do
      expect(tm.search_order(rooms, 12_345)).to eq(rooms)
    end

    it 'starts at the last-seen room and alternates outwards' do
      expect(tm.search_order(rooms, 16_150).first(5)).to eq([16_150, 16_153, 16_148, 16_154, 16_146])
    end

    it 'visits every room exactly once from any starting point' do
      rooms.each do |start|
        expect(tm.search_order(rooms, start)).to match_array(rooms)
      end
    end

    it 'handles the ends of the list' do
      expect(tm.search_order(rooms, rooms.last).first(3)).to eq([16_290, 16_278, 16_277])
      expect(tm.search_order(rooms, rooms.first).first(3)).to eq([16_145, 16_146, 16_148])
    end
  end

  describe '#find_npc' do
    # A small world: walking changes the current room, and Zasele is listed
    # among the NPCs only in her room. Returns the rooms walked to.
    def search(zasele_in:, start_in:)
      tm = described_class.allocate
      here = start_in
      walked = []
      allow(Room).to receive(:current) { OpenStruct.new(id: here) }
      allow(DRRoom).to receive(:npcs) { here == zasele_in ? ['Zasele'] : [] }
      allow(DRCT).to receive(:walk_to) do |room|
        walked << room
        here = room
      end
      tm.find_npc(rooms, 'zasele')
      walked
    end

    it 'remembers where the taskmaster was found' do
      search(zasele_in: 16_276, start_in: 16_936)
      expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_276)
    end

    it 'goes straight back to the last-seen room when she is still there' do
      UserVars.taskmaster_last_seen = { 'zasele' => 16_276 }
      expect(search(zasele_in: 16_276, start_in: 16_936)).to eq([16_276])
    end

    it 'finds her a room or two away from where she was last seen' do
      UserVars.taskmaster_last_seen = { 'zasele' => 16_276 }
      expect(search(zasele_in: 16_154, start_in: 16_936)).to eq([16_276, 16_277, 16_147, 16_278, 16_154])
    end

    it 'searches the whole list in its own order the first time' do
      expect(search(zasele_in: 16_150, start_in: 16_936)).to eq([16_145, 16_146, 16_148, 16_150])
    end

    it 'does not move, and still remembers the room, when she is already here' do
      expect(search(zasele_in: 16_153, start_in: 16_153)).to eq([])
      expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_153)
    end

    it 'keeps the old last-seen room when she cannot be found at all' do
      UserVars.taskmaster_last_seen = { 'zasele' => 16_150 }
      expect(search(zasele_in: 99_999, start_in: 16_936)).to match_array(rooms)
      expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_150)
    end

    it 'remembers each taskmaster separately' do
      UserVars.taskmaster_last_seen = { 'poltu' => 16_290 }
      search(zasele_in: 16_146, start_in: 16_936)
      expect(UserVars.taskmaster_last_seen).to eq('poltu' => 16_290, 'zasele' => 16_146)
    end
  end
end
