# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')

RSpec.describe TaskMaster do
  describe '#remember_sack' do
    def build(npc = 'zasele')
      tm = described_class.allocate
      tm.instance_variable_set(:@npc, npc)
      tm
    end

    it 'records each sack for loot_history' do
      UserVars.taskmaster_sacks = { 'zasele' => [] }
      build.remember_sack(' a large haledroth shard.')
      expect(UserVars.taskmaster_sacks['zasele']).to eq([' a large haledroth shard.'])
    end

    it 'keeps only the most recent 100 sacks' do
      UserVars.taskmaster_sacks = { 'zasele' => [] }
      tm = build
      150.times { |i| tm.remember_sack("sack #{i}") }
      history = UserVars.taskmaster_sacks['zasele']
      expect(history.size).to eq(100)
      expect(history.first).to eq('sack 50')
      expect(history.last).to eq('sack 149')
    end

    it 'trims an already oversized history from older runs on the next sack' do
      UserVars.taskmaster_sacks = { 'zasele' => Array.new(3_000) { |i| "old #{i}" } }
      build.remember_sack('new')
      expect(UserVars.taskmaster_sacks['zasele'].size).to eq(100)
      expect(UserVars.taskmaster_sacks['zasele'].last).to eq('new')
    end

    it 'starts a history for a taskmaster with none yet' do
      UserVars.taskmaster_sacks = nil
      build('poltu').remember_sack('a bronze bar.')
      expect(UserVars.taskmaster_sacks).to eq('poltu' => ['a bronze bar.'])
    end
  end
end
