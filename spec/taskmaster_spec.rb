# frozen_string_literal: true

require 'ostruct'
require 'yaml'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')

RSpec.describe TaskMaster do
  describe '#run_before_scripts' do
    def run(entries)
      tm = described_class.allocate
      tm.instance_variable_set(:@before_scripts, Array(entries))
      ran = []
      allow(DRC).to receive(:wait_for_script_to_complete) { |name, args| ran << [name, args] }
      tm.run_before_scripts
      ran
    end

    it 'runs each script to completion, in order' do
      expect(run(%w[restock buff])).to eq([['restock', []], ['buff', []]])
    end

    it 'passes arguments written after the script name' do
      expect(run(['buff crafting', 'sell-loot skip'])).to eq([['buff', ['crafting']], ['sell-loot', ['skip']]])
    end

    it 'runs nothing when the setting is missing' do
      expect(run(nil)).to eq([])
    end

    it 'runs nothing with the base.yaml default' do
      base = YAML.unsafe_load_file(File.expand_path('../profiles/base.yaml', __dir__))
      expect(base).to have_key('task_before_scripts')
      expect(run(base['task_before_scripts'])).to eq([])
    end

    it 'skips blank entries instead of starting a script with no name' do
      expect(run(['', '   ', nil, 'restock'])).to eq([['restock', []]])
    end
  end
end
