# frozen_string_literal: true

require 'ostruct'
require 'yaml'

require_relative 'spec_helper'

load_lic_class('task-forage.lic', 'TaskForage')

RSpec.describe TaskForage do
  let(:messages) { [] }
  let(:foragables) { YAML.load_file(File.join(__dir__, '..', 'data', 'base-forage.yaml'))['foragables'] }

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
      foraging_data: foragables,
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

  # A forage container as the game resolves it: "<ordinal> <item>" picks the nth
  # entry whose noun starts with the item's noun and that carries each of its
  # adjectives, in container order. TAP names that entry and leaves it; GET moves
  # it into a hand.
  #
  # @param contents [Array<String>] item names in container order
  # @param put_back [Symbol] where PUT lands an item. The game puts it at the front
  #   (seen in game), but the fetch shouldn't depend on it, so specs try :end as well.
  def stub_container(contents, put_back: :front)
    container = contents.dup
    taps = []
    resolve = lambda do |ref|
      words = ref.split
      ordinal = $ORDINALS.index(words.first) ? words.shift : 'first'
      *adjectives, noun = words
      matches = container.each_index.select do |i|
        *name_adjectives, name_noun = container[i].split
        name_noun.start_with?(noun) && adjectives.all? { |adj| name_adjectives.any? { |w| w.start_with?(adj) } }
      end
      matches[$ORDINALS.index(ordinal)]
    end

    allow(DRCI).to receive(:tap) do |ref, _container|
      taps << ref
      index = resolve.call(ref)
      index ? "You tap a #{container[index]} inside your leather backpack." : 'I could not find what you were referring to.'
    end
    allow(DRCI).to receive(:get_item?) do |ref, _container|
      index = resolve.call(ref)
      next false unless index

      name = container.delete_at(index)
      $right_hand.nil? ? $right_hand = name : $left_hand = name
      true
    end
    allow(DRCI).to receive(:put_away_item?) do |noun, _container|
      hand = [$right_hand, $left_hand].index { |name| name&.split&.last&.start_with?(noun.split.last) }
      next false unless hand

      name = hand.zero? ? $right_hand : $left_hand
      hand.zero? ? $right_hand = nil : $left_hand = nil
      put_back == :front ? container.unshift(name) : container.push(name)
      true
    end
    { contents: container, taps: taps }
  end

  # Hand the item in hand to the giver, as a successful GIVE does.
  def hand_over
    given = $right_hand || $left_hand
    $right_hand ? $right_hand = nil : $left_hand = nil
    given
  end

  describe '#shared_noun?' do
    it 'holds for every plain item that another base-forage item shares its noun with' do
      %w[root stem grass moss sap weed leaf shell clover berries rose].each do |item|
        expect(build_instance.shared_noun?(item)).to be(true), item
      end
    end

    it 'holds for a qualified item too, since "first ojhenik root" can still match other roots' do
      expect(build_instance.shared_noun?('ojhenik root')).to be(true)
    end

    it 'does not hold for items no other forage item shares a noun with' do
      ['corn', 'lavender', 'stick', 'shark tooth', 'chamomile'].each do |item|
        expect(build_instance.shared_noun?(item)).to be(false), item
      end
    end
  end

  describe '#names_item?' do
    subject(:instance) { build_instance }

    it 'accepts the item with or without an article, singular or plural' do
      ['a root', 'some roots', 'root', 'the root', 'Root'].each do |name|
        expect(instance.names_item?(name, 'root')).to be(true), name
      end
    end

    it 'rejects items that only share the noun' do
      ['an ojhenik root', 'a tree root', 'some pig roots', 'a rootstock', 'some ojhenik roots'].each do |name|
        expect(instance.names_item?(name, 'root')).to be(false), name
      end
    end

    it 'handles irregular plurals and plural-named items' do
      expect(instance.names_item?('some leaves', 'leaf')).to be(true)
      expect(instance.names_item?('some tea leaves', 'leaf')).to be(false)
      expect(instance.names_item?('some berries', 'berries')).to be(true)
      expect(instance.names_item?('some wild berries', 'berries')).to be(false)
      expect(instance.names_item?('some grasses', 'grass')).to be(true)
    end

    it 'ignores the herb qualifier the game appends' do
      expect(instance.names_item?('some nuloe stems (limbs: internal scars)', 'nuloe stem')).to be(true)
    end
  end

  describe '#get_task_item' do
    it 'passes over an earlier item sharing the noun and takes the plain one' do
      game = stub_container(['ojhenik root', 'tree root', 'root'])
      expect(build_instance.get_task_item).to eq('root')
      expect($right_hand).to eq('root')
      expect(game[:taps]).to eq(['first root', 'second root', 'third root'])
      expect(game[:contents]).to eq(['ojhenik root', 'tree root'])
    end

    it 'is nil, without taking anything, when every match shares only the noun' do
      game = stub_container(['ojhenik root', 'tree root'])
      expect(build_instance.get_task_item).to be_nil
      expect(game[:contents]).to eq(['ojhenik root', 'tree root'])
      expect($right_hand).to be_nil
    end

    it 'stops at the last ordinal and says so, rather than taking a wrong item' do
      game = stub_container(Array.new($ORDINALS.size, 'ojhenik root') + ['root'])
      expect(build_instance.get_task_item).to be_nil
      expect(game[:taps].size).to eq($ORDINALS.size)
      expect(game[:contents].last).to eq('root')
      expect(messages.last).to include("No plain root among the first #{$ORDINALS.size} matches")
    end

    it 'takes the task item even when the game names it differently from base-forage.yaml' do
      game = stub_container(['muljin sap', 'glob of sap'])
      expect(build_instance(item: 'sap', item_variants: ['sap']).get_task_item).to eq('sap')
      expect($right_hand).to eq('glob of sap')
      expect(game[:contents]).to eq(['muljin sap'])
    end

    it 'passes over the plain item and other qualified ones for a qualified task item' do
      stub_container(['root', 'genich stem', 'stem', 'nuloe stem'])
      expect(build_instance(item: 'nuloe stem', item_variants: ['nuloe stem']).get_task_item).to eq('nuloe stem')
      expect($right_hand).to eq('nuloe stem')
    end

    it 'handles an item named in three words' do
      stub_container(['jasmine blossom', 'red fox blossom'])
      expect(build_instance(item: 'red fox blossom', item_variants: ['red fox blossom']).get_task_item)
        .to eq('red fox blossom')
      expect($right_hand).to eq('red fox blossom')
    end

    context 'with the TAP replies seen in game' do
      def tap_replies(replies)
        allow(DRCI).to receive(:tap) { |ref, _container| replies.fetch(ref, 'I could not find what you were referring to.') }
      end

      it 'reads "some <item>" and skips the look-alike' do
        tap_replies('first root'  => 'You tap some ojhenik root inside your void-black rift.',
                    'second root' => 'You tap a root inside your void-black rift.')
        expect(DRCI).to receive(:get_item?).with('second root', 'backpack').and_return(true)
        expect(build_instance.get_task_item).to eq('root')
      end

      it 'takes an ordinal whose reply does not name the item, not the look-alike before it' do
        tap_replies('first root'  => 'You tap some ojhenik root inside your void-black rift.',
                    'second root' => 'You drum your fingers on a root.')
        expect(DRCI).to receive(:get_item?).with('second root', 'backpack').and_return(true)
        expect(build_instance.get_task_item).to eq('root')
      end

      it 'stops without a GET when TAP gets no reply' do
        tap_replies('first root' => '')
        expect(DRCI).not_to receive(:get_item?)
        expect(build_instance.get_task_item).to be_nil
      end
    end

    it 'fetches by noun alone, with no TAP, when no other forage item shares the noun' do
      game = stub_container(['piece of wild corn'])
      expect(build_instance(item: 'corn', item_variants: ['corn']).get_task_item).to eq('corn')
      expect(game[:taps]).to be_empty
    end

    it 'tries each accepted noun in turn' do
      stub_container(%w[limb])
      instance = build_instance(item: 'stick', item_variants: %w[stick branch limb])
      expect(instance.get_task_item).to eq('limb')
    end

    it 'does not re-tap earlier ordinals for the next item in the same round' do
      game = stub_container(['ojhenik root', 'tree root', 'root', 'root'])
      instance = build_instance
      instance.reset_task_item_search
      instance.get_task_item
      hand_over
      game[:taps].clear
      expect(instance.get_task_item).to eq('root')
      expect(game[:taps]).to eq(['third root'])
    end

    it 'starts from the first ordinal again in a new round, finding an item put in since' do
      game = stub_container(['ojhenik root', 'root'], put_back: :front)
      instance = build_instance
      instance.reset_task_item_search
      instance.get_task_item
      hand_over
      game[:contents].unshift('root')
      instance.reset_task_item_search
      expect(instance.get_task_item).to eq('root')
      expect(game[:contents]).to eq(['ojhenik root'])
    end

    # Random containers: a full round must hand over exactly the plain items,
    # whatever sits between them and wherever PUT drops an item.
    [:front, :end].each do |put_back|
      it "turns in every plain item and nothing else over a round (put back to #{put_back})" do
        rng = Random.new(7629)
        others = ['ojhenik root', 'tree root', 'pig root', 'jadice flower', 'nuloe stem']
        200.times do
          $right_hand = nil
          $left_hand = nil
          contents = Array.new(rng.rand(0..12)) { rng.rand < 0.4 ? 'root' : others.sample(random: rng) }
          contents.pop while contents.count { |name| name.end_with?('root') } > $ORDINALS.size
          game = stub_container(contents, put_back: put_back)
          instance = build_instance
          instance.reset_task_item_search

          given = []
          while instance.get_task_item
            given << hand_over
          end

          expect(given).to all(eq('root')), contents.inspect
          expect(given.size).to eq(contents.count('root')), contents.inspect
          expect(game[:contents]).to eq(contents - ['root'])
        end
      end
    end
  end

  describe '#give_item' do
    def reply(line)
      allow(DRC).to receive(:bput) do |_command, *patterns|
        patterns.lazy.map { |pattern| line[pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern)] }.find(&:itself).to_s
      end
    end

    it 'counts a thanked item' do
      reply('Mags smiles and says, "Thanks, that is just what I needed."')
      instance = build_instance
      expect(instance.give_item('root')).to be(true)
      expect(instance.instance_variable_get(:@delivered)).to eq(1)
    end

    it 'counts an item taken with a reply it does not know, once it has left the hand' do
      reply('Mags nods absently.')
      allow(DRCI).to receive(:in_hands?).with('root').and_return(false)
      instance = build_instance
      expect(instance.give_item('root')).to be(true)
      expect(instance.instance_variable_get(:@delivered)).to eq(1)
    end

    it 'puts back a refused item instead of carrying it into the next GET' do
      reply('Mags shakes her head.')
      allow(DRCI).to receive(:in_hands?).with('root').and_return(true)
      expect(DRCI).to receive(:put_away_item?).with('root', 'backpack')
      instance = build_instance
      expect(instance.give_item('root')).to be(false)
      expect(instance.instance_variable_get(:@delivered)).to eq(0)
      expect(messages.last).to include("Mags didn't take the root")
    end

    it "puts back an item Mags says she doesn't take, rather than exiting with it in hand" do
      reply(%(Mags sighs and says, "Aye-yah!  Tha' isnae somethin' I take.  P'rhaps a stick, or a branch -- ) +
            %(or a sack full of both!  Aye-yah, return when ye hae one of those!"))
      expect(DRCI).to receive(:put_away_item?).with('stem', 'backpack')
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

    it 'searches each turn-in from the first ordinal' do
      instance = build_instance(number: 1)
      instance.instance_variable_set(:@task_item_search, Hash.new(0).merge('root' => 3))
      game = stub_container(%w[root])
      allow(instance).to receive(:give_item) { hand_over }
      allow(instance).to receive(:room_safe?)
      expect { instance.complete_task }.not_to raise_error
      expect(game[:taps]).to eq(['first root'])
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
