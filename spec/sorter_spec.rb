# frozen_string_literal: true

require 'spec_helper'

# Test suite for sorter.lic
#
# sorter.lic runs as a background inventory formatting script that intercepts
# game inventory output via DownstreamHook. It is class-less, so its pure helper
# methods (categorize_item and filter_inventory_line) are extracted with
# load_lic_methods.

SorterHelpers = load_lic_methods('sorter.lic', 'categorize_item', 'filter_inventory_line')

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
