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
    let(:root_header) { 'You rummage through a leather backpack looking for something similar to "root"' }
    let(:sentinel) { 'The petal-crested dryanoxie moves into a position to parry.' }

    it 'counts each listed item, including the herb qualifier the game appends' do
      stub_game('rummage /C stem in my backpack' =>
                  "#{header} and see some nuloe stems (limbs: internal scars), a jadice flower " \
                  'and some nuloe stems (limbs: internal scars).')
      expect(build_instance.count_stored_items('nuloe stem')).to eq(2)
    end

    it 'counts only the plain item, not other items sharing its noun' do
      stub_game('rummage /C root in my backpack' =>
                  "#{root_header} and see some ojhenik roots, a tree root, a pig root and a root.")
      expect(build_instance.count_stored_items('root')).to eq(1)
    end

    it 'is zero for an empty reply, without waiting on a grouped listing' do
      stub_game('rummage /C stem in my backpack' => "#{header} but there is nothing in there like that.")
      $history = [sentinel]
      expect(build_instance.count_stored_items('nuloe stem')).to eq(0)
      expect($history).to eq([sentinel])
    end

    context 'with a grouped listing' do
      before { stub_game('rummage /C stem in my backpack' => "#{header}:") }

      it 'sums the "(N)" totals, counts a bare entry as one, and skips category headers' do
        $history = ['  herbs (38):', '    some nuloe stems (35)', '    some jadice flowers (3)',
                    '  other (3):', '    some nuloe stems (2)', '    some nuloe stems', sentinel, 'later line']
        expect(build_instance.count_stored_items('nuloe stem')).to eq(38)
      end

      it 'stops at the first unindented line after the listing (Lich passes no blank lines)' do
        $history = ['  herbs (35):', '    some nuloe stems (35)', sentinel, 'later line']
        build_instance.count_stored_items('nuloe stem')
        expect($history).to eq(['later line'])
      end
    end

    it 'opens a closed container and looks again' do
      open = false
      stub_game('rummage /C stem in my backpack' => lambda {
        open ? "#{header} and see some nuloe stems." : "While it's closed, you can't rummage through it."
      })
      expect(DRCI).to receive(:open_container?).with('my backpack') { open = true }
      expect(build_instance.count_stored_items('nuloe stem')).to eq(1)
    end

    it 'is nil when a closed container will not open, without rummaging again' do
      commands = stub_game('rummage /C stem in my backpack' => "While it's closed, you can't rummage through it.")
      allow(DRCI).to receive(:open_container?).and_return(false)
      expect(build_instance.count_stored_items('nuloe stem')).to be_nil
      expect(commands).to eq(['rummage /C stem in my backpack'])
    end

    it 'is nil when the container is missing' do
      stub_game('rummage /C stem in my backpack' => 'What were you referring to?')
      expect(build_instance.count_stored_items('nuloe stem')).to be_nil
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

    it 'says the container could not be checked, rather than that none were found' do
      instance = forager(nil)
      instance.use_stored_items
      expect(instance.instance_variable_get(:@item_count)).to eq(1)
      expect(messages.last).to include("Couldn't check your backpack for nuloe stem; gathering all 5.")
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

    it 'skips a leftover override with no task giver and uses the hometown' do
      instance = build_instance(hometown: 'Crossing',
                                settings: OpenStruct.new(fang_cove_override_town: 'Riverhaven'))
      expect(resolved_town(instance)).to eq('crossing')
    end

    it 'exits with advice instead of crashing when no task giver can be found' do
      instance = build_instance(hometown: 'Fang Cove')
      allow(instance).to receive(:room_safe?)
      expect { instance.resolve_task_town }.to raise_error(SystemExit)
      expect(messages.last).to include("No forage task giver in 'fang cove'")
    end
  end
end
