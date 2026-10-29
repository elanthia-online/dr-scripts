# frozen_string_literal: true

require 'ostruct'
require 'yaml'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')

RSpec.describe TaskMaster do
  # A bare instance: initialize runs the whole script, so each example injects
  # only the state the method under test reads.
  def build(settings = {})
    tm = described_class.allocate
    tm.instance_variable_set(:@settings, OpenStruct.new(settings))
    tm.send(:configure_boosts)
    tm
  end

  describe '#configure_boosts' do
    it 'uses no boosts by default' do
      tm = build
      expect(tm.instance_variable_get(:@boosts)).to eq([])
      expect(tm.instance_variable_get(:@boost)).to be(false)
    end

    it 'keeps task_use_boost meaning the task boost' do
      tm = build(task_use_boost: true)
      expect(tm.instance_variable_get(:@boosts)).to eq(['task'])
      expect(tm.instance_variable_get(:@boost)).to be(true)
    end

    it 'reads task_boosts, case-insensitively, without duplicating task' do
      tm = build(task_boosts: %w[Task HASTE], task_use_boost: true)
      expect(tm.instance_variable_get(:@boosts)).to eq(%w[task haste])
    end

    it 'keeps both defaults when task_boosts comes from base.yaml' do
      base = YAML.unsafe_load_file(File.expand_path('../profiles/base.yaml', __dir__))
      expect(base).to have_key('task_boosts')
      expect(build(task_boosts: base['task_boosts']).instance_variable_get(:@boosts)).to eq([])
      tm = build(task_boosts: base['task_boosts'], task_use_boost: true)
      expect(tm.instance_variable_get(:@boosts)).to eq(['task'])
      expect(tm.instance_variable_get(:@boost)).to be(true)
    end

    it 'can run haste without the task boost' do
      tm = build(task_boosts: ['haste'])
      expect(tm.instance_variable_get(:@boost)).to be(false)
    end
  end

  describe '#refresh_haste' do
    # Boost replies as the game prints them (2025 Hollow Eve logs).
    let(:activated) { "You've activated the Minor Haste boost for an hour!" }
    let(:no_credits) { "You don't have enough credits for the Minor Haste boost.  You currently have 0 available but need 1." }

    def reply_with(text)
      allow(DRC).to receive(:bput).with('boost haste', any_args).and_return(text)
    end

    it 'sends nothing when haste is not configured' do
      tm = build(task_boosts: ['task'])
      expect(DRC).not_to receive(:bput)
      tm.refresh_haste
    end

    it 'activates haste and remembers it for an hour' do
      tm = build(task_boosts: ['haste'])
      reply_with(activated)
      tm.refresh_haste
      expect(UserVars.taskmaster_haste_expires).to be_within(5).of(Time.now.to_i + 3600)
    end

    it 'does not ask again while the hour is running, even from a new run' do
      UserVars.taskmaster_haste_expires = Time.now.to_i + 1800
      tm = build(task_boosts: ['haste'])
      expect(DRC).not_to receive(:bput)
      tm.refresh_haste
    end

    it 'asks again once the hour is up' do
      UserVars.taskmaster_haste_expires = Time.now.to_i - 1
      tm = build(task_boosts: ['haste'])
      reply_with(activated)
      tm.refresh_haste
      expect(DRC).to have_received(:bput).with('boost haste', any_args)
    end

    it 'leaves the expiry alone when out of credits, so the next task tries again' do
      tm = build(task_boosts: ['haste'])
      reply_with(no_credits)
      tm.refresh_haste
      expect(UserVars.taskmaster_haste_expires).to be_nil
    end

    it 'backs off for ten minutes after any other answer, such as haste already running' do
      tm = build(task_boosts: ['haste'])
      # The real wording for an already-running boost is not in the logs; any
      # other reply naming Minor Haste lands here.
      reply_with('You already have an active Minor Haste boost.')
      tm.refresh_haste
      expect(UserVars.taskmaster_haste_expires).to be_within(5).of(Time.now.to_i + 600)
    end

    it 'backs off the same way when the reply never arrives' do
      tm = build(task_boosts: ['haste'])
      reply_with('')
      tm.refresh_haste
      expect(UserVars.taskmaster_haste_expires).to be_within(5).of(Time.now.to_i + 600)
    end

    it 'ignores other players mentioning a boost while waiting for the reply' do
      tm = build(task_boosts: ['haste'])
      expect(DRC).to receive(:bput).with('boost haste', TaskMaster::HASTE_ACTIVATED, TaskMaster::HASTE_NO_CREDITS, /Minor Haste/).and_return(activated)
      tm.refresh_haste
    end
  end
end
