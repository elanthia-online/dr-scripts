# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('task-forage.lic', 'TaskForage')

RSpec.describe TaskForage do
  let(:messages) { [] }

  before { allow(DRC).to receive(:message) { |text| messages << text } }

  # Instantiate without running the god-initialize, setting only what the
  # method under test reads.
  def build_instance(**ivars)
    instance = TaskForage.allocate
    defaults = {
      forage_container: 'backpack',
      debug: false,
      args: OpenStruct.new(town: nil),
      settings: OpenStruct.new(fang_cove_override_town: nil),
      hometown: 'Crossing',
      task_givers: { 'shard' => { 'npc' => 'peddler' }, 'crossing' => { 'npc' => 'Mags' } }
    }
    defaults.merge(ivars).each { |k, v| instance.instance_variable_set(:"@#{k}", v) }
    instance
  end

  # Answer each command with a game line, returning only the matched text the
  # way DRC.bput does: the first pattern that matches wins, '' on no match.
  #
  # @param replies [Hash{String=>String, Proc}] command => line (or a proc giving one)
  # @return [Array<String>] the commands sent
  def stub_game(replies)
    commands = []
    allow(DRC).to receive(:bput) do |command, *patterns|
      commands << command
      reply = replies[command]
      line = (reply.respond_to?(:call) ? reply.call : reply).to_s
      patterns.lazy.map { |pattern| line[pattern.is_a?(Regexp) ? pattern : /#{Regexp.escape(pattern)}/i] }
              .find(&:itself).to_s
    end
    commands
  end

  describe '#count_stored_items' do
    let(:header) { 'You rummage through a leather backpack looking for something similar to "stem"' }

    it 'counts plural stacks in an inline listing' do
      stub_game('rummage /C stem in my backpack' =>
                  "#{header} and see some nuloe stems, a jadice flower and some nuloe stems.")
      expect(build_instance.count_stored_items('nuloe stem')).to eq(2)
    end

    it 'sums the "(N)" totals of a categorized listing, skipping category headers' do
      stub_game('rummage /C stem in my backpack' => "#{header}:")
      $history = ['  herbs (38):', '    some nuloe stems (35)', '    some jadice flowers (3)',
                  '  other (2):', '    some nuloe stems (2)', '']
      expect(build_instance.count_stored_items('nuloe stem')).to eq(37)
    end

    it 'is zero when nothing matches' do
      stub_game('rummage /C stem in my backpack' => "#{header} but can't find anything.")
      expect(build_instance.count_stored_items('nuloe stem')).to eq(0)
    end

    it 'opens a closed container and looks again' do
      open = false
      commands = stub_game(
        'rummage /C stem in my backpack' => lambda {
          open ? "#{header} and see some nuloe stems." : "While it's closed, you can't rummage through it."
        },
        'open my backpack'               => lambda {
          open = true
          'You open your leather backpack.'
        }
      )
      expect(build_instance.count_stored_items('nuloe stem')).to eq(1)
      expect(commands).to eq(['rummage /C stem in my backpack', 'open my backpack', 'rummage /C stem in my backpack'])
    end

    it 'drops an herb qualifier before building the command and matching' do
      commands = stub_game('rummage /C stem in my backpack' => "#{header} and see some nuloe stems.")
      expect(build_instance.count_stored_items('nuloe stem (limbs: internal scars)')).to eq(1)
      expect(commands).to eq(['rummage /C stem in my backpack'])
    end
  end

  describe '#use_stored_items' do
    def forager(stored)
      instance = build_instance(item_variants: ['nuloe stem'], item: 'nuloe stem', number: 5, item_count: 1)
      allow(instance).to receive(:count_stored_items).and_return(stored)
      instance
    end

    it 'counts stored items toward the task, up to the number needed' do
      instance = forager(10)
      instance.use_stored_items
      expect(instance.instance_variable_get(:@item_count)).to eq(5)
      expect(messages.last).to include('Found 10 nuloe stem')
    end

    it 'says so when there are none, rather than staying silent' do
      instance = forager(0)
      instance.use_stored_items
      expect(instance.instance_variable_get(:@item_count)).to eq(1)
      expect(messages.last).to include('No nuloe stem already in your backpack; gathering all 5.')
    end
  end

  describe '#resolve_task_town' do
    # An unexpected exit would otherwise end the whole rspec run with status 0.
    def resolved_town(instance)
      town = nil
      expect { town = instance.resolve_task_town }.not_to raise_error
      town
    end

    it 'uses the hometown' do
      expect(resolved_town(build_instance)).to eq('crossing')
    end

    it 'prefers the town argument' do
      expect(resolved_town(build_instance(args: OpenStruct.new(town: 'shard')))).to eq('shard')
    end

    it 'falls back to fang_cove_override_town from a town with no task giver' do
      instance = build_instance(hometown: 'Fang Cove',
                                settings: OpenStruct.new(fang_cove_override_town: 'Crossing'))
      expect(resolved_town(instance)).to eq('crossing')
    end

    it 'exits with advice instead of crashing when no task giver can be found' do
      instance = build_instance(hometown: 'Fang Cove')
      expect { instance.resolve_task_town }.to raise_error(SystemExit)
      expect(messages.last).to include("No forage task giver in 'fang cove'")
    end
  end
end
