# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')

RSpec.describe TaskMaster do
  # A bare instance: initialize runs the whole script, so each example injects
  # only the state the method under test reads.
  def build(settings = {})
    tm = described_class.allocate
    tm.instance_variable_set(:@settings, OpenStruct.new(settings))
    tm.instance_variable_set(:@npc, 'zasele')
    tm.instance_variable_set(:@lootbag, 'backpack')
    tm.send(:configure_loot_filter)
    tm
  end

  # Sack contents as LOOK prints them (2025 Hollow Eve logs).
  def sack(contents)
    "In the woven sack you see #{contents}."
  end

  describe '#keeper?' do
    context 'with only a keep list (the default)' do
      let(:tm) { build(task_keep_list: %w[agonite haledroth]) }

      it 'keeps listed prizes' do
        expect(tm.keeper?(sack('a large haledroth shard'))).to be(true)
      end

      it 'bins everything else' do
        expect(tm.keeper?(sack('some brown dye'))).to be(false)
      end
    end

    context 'with a junk list' do
      let(:tm) do
        build(task_keep_list: %w[agonite], task_junk_list: [/\bdye/, /(?<!crystal-bone)(?<!mammoth-bone) stack/, 'alabaster'])
      end

      it 'bins prizes matching a string entry' do
        expect(tm.keeper?(sack('a boulder alabaster deed'))).to be(false)
      end

      it 'bins prizes matching a regexp entry' do
        expect(tm.keeper?(sack('some coral dye'))).to be(false)
        expect(tm.keeper?(sack('a bear-bone stack'))).to be(false)
      end

      it 'keeps what a regexp entry deliberately excludes' do
        expect(tm.keeper?(sack('a mammoth-bone stack'))).to be(true)
      end

      it 'keeps a prize nobody has listed, which the keep list would have binned' do
        expect(tm.keeper?(sack('some punka leather'))).to be(true)
      end

      it 'ignores the keep list' do
        expect(tm.keeper?(sack('some agonite dye'))).to be(false)
      end
    end

    it 'falls back to the keep list when the junk list is empty' do
      tm = build(task_keep_list: %w[agonite], task_junk_list: [])
      expect(tm.keeper?(sack('some punka leather'))).to be(false)
    end

    it 'keeps nothing, without raising, when neither list is set' do
      tm = build
      expect(tm.keeper?(sack('a large haledroth shard'))).to be(false)
    end

    it 'never keeps an empty or missing LOOK reply, in either mode' do
      expect(build(task_keep_list: %w[agonite]).keeper?('')).to be(false)
      expect(build(task_junk_list: ['dye']).keeper?('')).to be(false)
      expect(build(task_junk_list: ['dye']).keeper?(nil)).to be(false)
    end
  end

  describe '#sort_sack' do
    def sort(tm, contents)
      allow(DRC).to receive(:bput).and_return('You pick up')
      allow(DRC).to receive(:bput).with('look in my sack', anything).and_return(sack(contents))
      allow(DRC).to receive(:message)
      allow(DRCI).to receive(:put_away_item?)
      allow(DRCI).to receive(:dispose_trash)
      UserVars.taskmaster_sacks = { 'zasele' => [] }
      tm.sort_sack('rope')
    end

    it 'puts a keeper in the loot bag and pings Slack when asked to' do
      tm = build(task_junk_list: ['dye'], task_slack_keepers: true)
      expect(tm).to receive(:send_slackbot_message).with('Found a keeper: large haledroth shard')
      sort(tm, 'a large haledroth shard')
      expect(DRCI).to have_received(:put_away_item?).with('sack', 'backpack')
    end

    it 'does not ping Slack unless task_slack_keepers is set' do
      tm = build(task_junk_list: ['dye'])
      expect(tm).not_to receive(:send_slackbot_message)
      sort(tm, 'a large haledroth shard')
    end

    it 'bins junk without a Slack message' do
      tm = build(task_junk_list: ['dye'], task_slack_keepers: true)
      expect(tm).not_to receive(:send_slackbot_message)
      sort(tm, 'some coral dye')
      expect(DRCI).to have_received(:dispose_trash)
    end

    it 'names a keeper whose description has no leading article without raising' do
      tm = build(task_junk_list: ['dye'])
      expect { sort(tm, '3 haledroth shards') }.not_to raise_error
      expect(DRC).to have_received(:message).with('Found a keeper: 3 haledroth shards')
    end
  end

  describe 'Slack registration' do
    it 'registers the slackbot with slack_username only when keepers are reported' do
      tm = described_class.allocate
      tm.instance_variable_set(:@settings, OpenStruct.new(task_slack_keepers: true, slack_username: 'someone'))
      expect(tm).to receive(:register_slackbot).with('someone')
      tm.send(:configure_loot_filter)
    end

    it 'leaves the slackbot alone otherwise' do
      tm = described_class.allocate
      tm.instance_variable_set(:@settings, OpenStruct.new(slack_username: 'someone'))
      expect(tm).not_to receive(:register_slackbot)
      tm.send(:configure_loot_filter)
    end
  end
end
