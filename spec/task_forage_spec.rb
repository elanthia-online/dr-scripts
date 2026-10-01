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
      task_givers: { 'shard' => { 'npc' => 'peddler' }, 'crossing' => { 'npc' => 'Mags' } },
      item: 'root',
      item_variants: ['root'],
      task_giver: 'Mags',
      number: 5,
      delivered: 0,
      item_count: 0
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

  describe '#give_item' do
    def reply(line)
      allow(DRC).to receive(:bput) do |_command, *patterns|
        patterns.lazy.map { |pattern| line[pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern)] }.find(&:itself).to_s
      end
    end

    it 'counts a thanked item' do
      reply('The firewood peddler Mags takes the stems and says, "Thanks, Someone!  I need 4 more."')
      instance = build_instance
      expect(instance.give_item('root')).to be(true)
      expect(instance.instance_variable_get(:@delivered)).to eq(1)
    end

    it 'counts an item taken with a reply it does not know, once it has left the hand' do
      reply('(a reply the script does not know)')
      allow(DRCI).to receive(:in_hands?).with('root').and_return(false)
      instance = build_instance
      expect(instance.give_item('root')).to be(true)
      expect(instance.instance_variable_get(:@delivered)).to eq(1)
    end

    it 'puts back an item still in hand after a reply it does not know, or none at all' do
      ['(a reply the script does not know)', ''].each do |line|
        reply(line)
        allow(DRCI).to receive(:in_hands?).with('root').and_return(true)
        expect(DRCI).to receive(:put_away_item?).with('root', 'backpack').and_return(true)
        instance = build_instance
        expect(instance.give_item('root')).to be(false)
        expect(instance.instance_variable_get(:@delivered)).to eq(0)
        expect(messages.last).to eq("Mags didn't take the root. Put it back in your backpack.")
      end
    end

    it 'says the item is still in hand when it will not go back in the container' do
      reply('(a reply the script does not know)')
      allow(DRCI).to receive(:in_hands?).with('root').and_return(true)
      allow(DRCI).to receive(:put_away_item?).and_return(false)
      expect(build_instance.give_item('root')).to be(false)
      expect(messages.last).to include("it wouldn't go back in your backpack. It's still in your hand.")
    end

    it "puts back an item Mags says she doesn't take, rather than exiting with it in hand" do
      reply(%(Mags sighs and says, "Aye-yah!  Tha' isnae somethin' I take.  P'rhaps a stick, or a branch -- ) +
            %(or a sack full of both!  Aye-yah, return when ye hae one of those!"))
      expect(DRCI).to receive(:put_away_item?).with('stem', 'backpack').and_return(true)
      instance = build_instance(item: 'stick')
      allow(instance).to receive(:room_safe?)
      # An unexpected exit would otherwise end the whole rspec run with status 0.
      given = nil
      expect { given = instance.give_item('stem') }.not_to raise_error
      expect(given).to be(false)
      expect(instance.instance_variable_get(:@item)).to eq('stick')
      expect(messages.last).to include("Mags didn't take the stem")
    end

    it 'still exits on any other sigh from Mags' do
      reply('Mags sighs and says, "(some other reply)"')
      instance = build_instance
      allow(instance).to receive(:room_safe?)
      expect { instance.give_item('root') }.to raise_error(SystemExit)
    end
  end

  describe '#complete_task' do
    before { UserVars.task_forage = { 'item_failures' => {} } }

    it 'stops with an error when an item is refused, rather than carrying on silently' do
      instance = build_instance(number: 3)
      allow(instance).to receive(:get_task_item).and_return('root')
      allow(instance).to receive(:give_item).and_return(true, false)
      allow(instance).to receive(:room_safe?)
      expect { instance.complete_task }.to raise_error(SystemExit)
      expect(instance).to have_received(:give_item).twice
      expect(messages.last).to include("Mags wouldn't take the root")
    end
  end

  describe '#deliver_gathered_items' do
    it 'stops emptying the container when an item is refused, instead of looping on it' do
      instance = build_instance(item_count: 4, number: 10, item_location: 1)
      allow(instance).to receive(:find_giver)
      allow(instance).to receive(:give_item).with(no_args) { instance.instance_variable_set(:@delivered, 1) }
      allow(instance).to receive(:give_item).with('root').and_return(false)
      allow(instance).to receive(:get_task_item).and_return('root')
      allow(DRCT).to receive(:walk_to)
      instance.deliver_gathered_items
      expect(instance).to have_received(:get_task_item).once
    end
  end
end
