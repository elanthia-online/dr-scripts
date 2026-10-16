# frozen_string_literal: true

require 'spec_helper'

# Test suite for sorter.lic
#
# sorter.lic runs as a background inventory formatting script that intercepts
# game inventory output via DownstreamHook. It is class-less, so its pure helper
# methods (categorize_item, filter_inventory_line, strip_links and
# parse_inventory_line) are extracted with load_lic_methods.

SorterHelpers = load_lic_methods('sorter.lic', 'categorize_item', 'filter_inventory_line', 'strip_links', 'parse_inventory_line')

RSpec.describe 'sorter.lic before_dying teardown' do
  # Evaluates the real column-0 `before_dying do ... end` block from sorter.lic
  # with before_dying stubbed to capture it, so the spec runs the shipped
  # teardown rather than a copy of it.
  let(:teardown) do
    path = lic_path('sorter.lic')
    lines = File.readlines(path)
    start_idx = lines.index { |l| l =~ /^before_dying\s+do\s*$/ }
    raise "Could not find top-level 'before_dying do' in sorter.lic" unless start_idx

    end_idx = start_idx + 1 + lines[(start_idx + 1)..].index { |l| l =~ /^end\s*$/ }
    captured = nil
    context = Object.new
    context.define_singleton_method(:before_dying) { |&block| captured = block }
    context.instance_eval(lines[start_idx..end_idx].join, path, start_idx + 1)
    captured
  end

  after { DownstreamHook.remove('sorter') }

  it 'registers a before_dying block' do
    expect(teardown).to be_a(Proc)
  end

  it 'removes the sorter downstream hook when the script dies' do
    DownstreamHook.add('sorter', proc { |line| line })
    expect(DownstreamHook.list).to include('sorter')

    teardown.call

    expect(DownstreamHook.list).not_to include('sorter')
  end

  it 'leaves other scripts\' downstream hooks registered' do
    DownstreamHook.add('sorter', proc { |line| line })
    DownstreamHook.add('other-script', proc { |line| line })

    teardown.call

    expect(DownstreamHook.list).to include('other-script')
  ensure
    DownstreamHook.remove('other-script')
  end
end

RSpec.describe 'sorter.lic helpers' do
  let(:item_data) do
    {
      'gear - weapon_nouns' => %w[sword blade dagger mace spear],
      'gear - armour_nouns' => %w[shield helm mask cowl leathers plate],
      'gem_nouns'           => %w[diamond ruby sapphire emerald pearl],
      'scroll_nouns'        => %w[scroll parchment vellum],
      'metal_types'         => %w[bronze iron steel glaes haralun]
    }
  end

  describe '.categorize_item' do
    it 'identifies an item category matching its noun' do
      expect(SorterHelpers.categorize_item('broadsword', item_data)).to eq('gear - weapon')
    end

    it 'strips _nouns suffix to derive category name' do
      expect(SorterHelpers.categorize_item('small ruby', item_data)).to eq('gem')
    end

    it 'strips _types suffix to derive category name' do
      expect(SorterHelpers.categorize_item('iron', item_data)).to eq('metal')
    end

    it 'categorizes items with flavor text stripped' do
      expect(SorterHelpers.categorize_item('a broadsword adorned with rubies', item_data)).to eq('gear - weapon')
    end

    it 'detects NPC pushBold or popBold tags and categorizes as NPC' do
      expect(SorterHelpers.categorize_item('<pushBold/>Gorbesh warrior<popBold/>', item_data)).to eq('NPC')
    end

    it 'respects ignore_categories pattern' do
      expect(SorterHelpers.categorize_item('broadsword', item_data, 'gear - weapon')).to eq('other')
    end

    it 'returns other when no category matches' do
      expect(SorterHelpers.categorize_item('mysterious wooden gadget', item_data)).to eq('other')
    end

    it 'gracefully ignores non-array values in item_data without raising NoMethodError' do
      corrupt_data = item_data.merge(
        'home_city'  => 'Crossing',
        'enabled'    => true,
        'count'      => 42,
        'empty_list' => [],
        'nil_value'  => nil
      )

      expect { SorterHelpers.categorize_item('broadsword', corrupt_data) }.not_to raise_error
      expect(SorterHelpers.categorize_item('broadsword', corrupt_data)).to eq('gear - weapon')
      expect(SorterHelpers.categorize_item('unknown item', corrupt_data)).to eq('other')
    end
  end

  describe '.filter_inventory_line' do
    let(:inventory_line) { 'In the backpack you see a silver coin and a broadsword.' }
    let(:rummage_line) { 'You rummage through your backpack and see a silver coin and a gem.' }
    let(:look_items_line) { 'You take a moment to look for all the items in the area and see a rock.' }
    let(:wear_self_line) { 'You are wearing a black leather robe.' }
    let(:wear_male_line) { 'He is wearing a rugged hunting jacket.' }
    let(:wear_female_line) { 'She is wearing an elegant silk gown.' }
    let(:chat_line) { 'A giant goblin gestures at you threateningly.' }

    context 'when mute_old_inventory is disabled or settings are nil' do
      it 'passes through inventory lines unmodified' do
        expect(SorterHelpers.filter_inventory_line(inventory_line, nil)).to eq(inventory_line)
        expect(SorterHelpers.filter_inventory_line(inventory_line, {})).to eq(inventory_line)
        expect(SorterHelpers.filter_inventory_line(inventory_line, { 'mute_old_inventory' => false })).to eq(inventory_line)
      end

      it 'passes through regular room output unmodified' do
        expect(SorterHelpers.filter_inventory_line(chat_line, { 'mute_old_inventory' => false })).to eq(chat_line)
      end
    end

    context 'when mute_old_inventory is enabled' do
      let(:settings) { { 'mute_old_inventory' => true } }

      it 'mutes standard container inventory output' do
        expect(SorterHelpers.filter_inventory_line(inventory_line, settings)).to be_nil
        expect(SorterHelpers.filter_inventory_line('On the table you see a book.', settings)).to be_nil
      end

      it 'mutes rummage inventory output' do
        expect(SorterHelpers.filter_inventory_line(rummage_line, settings)).to be_nil
      end

      it 'passes through non-inventory output unmodified' do
        expect(SorterHelpers.filter_inventory_line(chat_line, settings)).to eq(chat_line)
      end

      describe 'look items filtering' do
        it 'passes through look items line when sort_look_items_command is false' do
          expect(SorterHelpers.filter_inventory_line(look_items_line, settings.merge('sort_look_items_command' => false))).to eq(look_items_line)
        end

        it 'mutes look items line when sort_look_items_command is true' do
          expect(SorterHelpers.filter_inventory_line(look_items_line, settings.merge('sort_look_items_command' => true))).to be_nil
        end
      end

      describe 'own equipment wearing filtering' do
        it 'passes through wearing line when sort_inv_command is false' do
          expect(SorterHelpers.filter_inventory_line(wear_self_line, settings.merge('sort_inv_command' => false))).to eq(wear_self_line)
        end

        it 'mutes wearing line when sort_inv_command is true' do
          expect(SorterHelpers.filter_inventory_line(wear_self_line, settings.merge('sort_inv_command' => true))).to be_nil
        end
      end

      describe 'other player wearing filtering' do
        it 'passes through wearing lines when sort_look_others is false' do
          expect(SorterHelpers.filter_inventory_line(wear_male_line, settings.merge('sort_look_others' => false))).to eq(wear_male_line)
          expect(SorterHelpers.filter_inventory_line(wear_female_line, settings.merge('sort_look_others' => false))).to eq(wear_female_line)
        end

        it 'mutes wearing lines when sort_look_others is true' do
          expect(SorterHelpers.filter_inventory_line(wear_male_line, settings.merge('sort_look_others' => true))).to be_nil
          expect(SorterHelpers.filter_inventory_line(wear_female_line, settings.merge('sort_look_others' => true))).to be_nil
        end
      end
    end
  end
end

# DragonRealms sends container lists in two shapes. The legacy stream sends
# plain text. The rich (Saga) stream wraps the container name, and often the
# last item of the list, in an object link; the article of that item can sit
# inside the link. Lich may or may not have stripped those links before sorter
# sees the line. Every pair below is the same game output in both shapes
# (synthetic names and ids), and sorter must treat the two identically.
RSpec.describe 'sorter.lic stream shapes' do
  let(:item_data) do
    {
      'gem_nouns'  => %w[sapphire amethyst],
      'misc_nouns' => %w[rope mortar stack skates]
    }
  end

  # Runs the real parse + DRC.list_to_array + article strip + categorize
  # chain sorter's main loop uses, returning [container, [[item, category], ...]].
  def sort_line(line, settings = {})
    container, contents = SorterHelpers.parse_inventory_line(line, settings)
    return nil unless container

    list = contents[/(?:and|you) see (.*)\./, 1]
    items = DRC.list_to_array(list).map { |item| item.sub(/^\s*?\b(?:a|an|some|and|the)\b\s/, '') }
    [container, items.map { |item| [item, SorterHelpers.categorize_item(item, item_data)] }]
  end

  shared_examples 'a stream-agnostic line' do |legacy, rich, expected, settings = {}|
    it 'sorts the legacy (plain) shape as expected' do
      expect(sort_line(legacy, settings)).to eq(expected)
    end

    it 'sorts the rich (linked) shape exactly like the legacy shape' do
      expect(sort_line(rich, settings)).to eq(expected)
    end
  end

  describe 'an In the ... you see line with a linked container' do
    include_examples 'a stream-agnostic line',
                     'In the oak chest you see a large blue sapphire and some silver coins.',
                     'In the <a exist="9001" noun="chest">oak chest</a> you see a large blue sapphire and some silver coins.',
                     ['In the oak chest', [['large blue sapphire', 'gem'], ['silver coins', 'other']]]
  end

  describe 'a rummage line whose last item is linked' do
    include_examples 'a stream-agnostic line',
                     'You rummage through a canvas sack and see a stone mortar and a bone stack.',
                     'You rummage through a <a exist="9002" noun="sack">canvas sack</a> and see a stone mortar and a <a exist="9003" noun="stack">bone stack</a>.',
                     ['You rummage through a canvas sack', [['stone mortar', 'misc'], ['bone stack', 'misc']]]
  end

  describe 'a rummage line whose linked last item carries its article inside the link' do
    include_examples 'a stream-agnostic line',
                     'You rummage through a canvas sack and see a stone mortar and some coiled rope.',
                     'You rummage through a canvas sack and see a stone mortar and <a exist="9004" noun="rope">some coiled rope</a>.',
                     ['You rummage through a canvas sack', [['stone mortar', 'misc'], ['coiled rope', 'misc']]]
  end

  describe 'a linked item whose text ends in flavor after the noun' do
    include_examples 'a stream-agnostic line',
                     'You rummage through a canvas sack and see a stone mortar and some leather skates with brown laces.',
                     'You rummage through a canvas sack and see a stone mortar and <a exist="9005" noun="skates">some leather skates with brown laces</a>.',
                     ['You rummage through a canvas sack', [['stone mortar', 'misc'], ['leather skates with brown laces', 'misc']]]
  end

  describe 'a rummage search line' do
    include_examples 'a stream-agnostic line',
                     'You rummage through a canvas sack looking for something similar to "pouch" and see a gem pouch and a gem pouch.',
                     'You rummage through a canvas sack looking for something similar to "pouch" and see a gem pouch and a <a exist="9006" noun="pouch">gem pouch</a>.',
                     ['You rummage through a canvas sack looking for something similar to "pouch"', [['gem pouch', 'other'], ['gem pouch', 'other']]]
  end

  describe 'a look-items line when sort_look_items_command is set' do
    include_examples 'a stream-agnostic line',
                     'You take a moment to look for all the items in the area and see a small amethyst and a bone stack.',
                     'You take a moment to look for all the items in the area and see a small amethyst and a <a exist="9007" noun="stack">bone stack</a>.',
                     ['You take a moment to look for all the items in the area', [['small amethyst', 'gem'], ['bone stack', 'misc']]],
                     { 'sort_look_items_command' => true }
  end

  describe 'a wearing line when sort_inv_command is set' do
    include_examples 'a stream-agnostic line',
                     'You are wearing a gem pouch and some coiled rope.',
                     'You are wearing a gem pouch and <a exist="9008" noun="rope">some coiled rope</a>.',
                     ['Inventory', [['gem pouch', 'other'], ['coiled rope', 'misc']]],
                     { 'sort_inv_command' => true }
  end

  describe 'a line sorter leaves alone' do
    include_examples 'a stream-agnostic line',
                     'You rummage through a canvas sack but there is nothing in there.',
                     'You rummage through a <a exist="9009" noun="sack">canvas sack</a> but there is nothing in there.',
                     nil
  end

  describe '.strip_links' do
    it 'removes link open and close tags but keeps their text' do
      expect(SorterHelpers.strip_links('a <a exist="-12" noun="stack">bone stack</a>.')).to eq('a bone stack.')
    end

    it 'leaves bold markup, which categorize_item uses to spot NPCs' do
      line = 'a <pushBold/><pushBold/><a exist="-34" noun="goblin">goblin</a><popBold/><popBold/>'
      expect(SorterHelpers.strip_links(line)).to eq('a <pushBold/><pushBold/>goblin<popBold/><popBold/>')
    end

    it 'returns a plain line unchanged and does not mutate the argument' do
      line = 'In the oak chest you see a bone stack.'
      expect(SorterHelpers.strip_links(line)).to eq(line)
      linked = +'a <a exist="1" noun="stack">bone stack</a>'
      SorterHelpers.strip_links(linked)
      expect(linked).to eq('a <a exist="1" noun="stack">bone stack</a>')
    end
  end

  describe '.parse_inventory_line' do
    it 'tolerates nil settings' do
      expect(SorterHelpers.parse_inventory_line('In the oak chest you see a bone stack.', nil)).to eq(['In the oak chest', 'you see a bone stack.'])
    end

    it 'skips lines that mention both In the and On the' do
      expect(SorterHelpers.parse_inventory_line('In the oak chest you see a note On the table.', {})).to be_nil
    end
  end

  describe '.filter_inventory_line on the rich shape' do
    let(:settings) { { 'mute_old_inventory' => true } }

    it 'mutes a linked container line just like the plain one' do
      rich = 'In the <a exist="9001" noun="chest">oak chest</a> you see a large blue sapphire and some silver coins.'
      expect(SorterHelpers.filter_inventory_line(rich, settings)).to be_nil
    end

    it 'mutes a rummage line whose linked last item carries its article, just like the plain one' do
      legacy = 'You rummage through a canvas sack and see a stone mortar and some coiled rope.'
      rich = 'You rummage through a <a exist="9002" noun="sack">canvas sack</a> and see a stone mortar and <a exist="9004" noun="rope">some coiled rope</a>.'
      expect(SorterHelpers.filter_inventory_line(legacy, settings)).to be_nil
      expect(SorterHelpers.filter_inventory_line(rich, settings)).to be_nil
    end

    it 'passes an unsorted linked line through with its links intact' do
      rich = 'You take a moment to look for all the items in the area and see a <a exist="9010" noun="stack">bone stack</a>.'
      expect(SorterHelpers.filter_inventory_line(rich, settings)).to eq(rich)
    end

    it 'passes an empty linked rummage line through' do
      rich = 'You rummage through a <a exist="9009" noun="sack">canvas sack</a> but there is nothing in there.'
      expect(SorterHelpers.filter_inventory_line(rich, settings)).to eq(rich)
    end
  end
end
