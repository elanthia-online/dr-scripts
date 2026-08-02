# frozen_string_literal: true

# Specs for paladin-quests.lic, focused on the Glyph of Bonding fountain
# auto-selection logic (PaladinQuests#choose_fountain_item).
#
# The quest presents an ornate item alongside a humble one and the paladin must
# "choose wisely" by taking the humble reward. The script keeps a list of
# known-correct nouns (gathered from player-reported logs) and takes the first
# one that the fountain accepts, falling back to a manual selection otherwise.
#
# @see PaladinQuests#choose_fountain_item
# @see https://github.com/elanthia-online/dr-scripts/issues/7461

require_relative 'spec_helper'

load_lic_class('paladin-quests.lic', 'PaladinQuests')

RSpec.describe PaladinQuests do
  # Build the instance without running the constructor, which would otherwise
  # drive the entire quest (guild checks, walking, and interactive prompts).
  subject(:quest) { described_class.allocate }

  before(:each) do
    reset_data
    allow(DRC).to receive(:bput)
    allow(DRC).to receive(:message)
  end

  describe 'BONDING_FOUNTAIN_ITEMS' do
    it 'records the lead cup as a known-correct reward (GitHub issue #7461)' do
      expect(described_class::BONDING_FOUNTAIN_ITEMS).to include('cup')
    end
  end

  describe '#choose_fountain_item' do
    # The fountain confirms a correct selection with a "chosen wisely" line;
    # any other line means the item was not in this particular fountain.
    let(:chosen_wisely_response) do
      'The cup disappears in a flash of white. A voice says to you, "You have chosen wisely. Receive your reward."'
    end
    let(:item_absent_response) { 'What were you referring to?' }

    context 'when a known-correct item is present in the fountain' do
      before do
        allow(DRC).to receive(:bput)
          .with('get cup', 'chosen wisely', anything, anything)
          .and_return(chosen_wisely_response)
      end

      it 'returns true once the paladin has chosen wisely' do
        expect(quest.choose_fountain_item).to be true
      end

      it 'takes the item by issuing a get for its noun' do
        quest.choose_fountain_item
        expect(DRC).to have_received(:bput).with('get cup', 'chosen wisely', anything, anything)
      end
    end

    context 'when none of the known items are present in the fountain' do
      before do
        allow(DRC).to receive(:bput).and_return(item_absent_response)
      end

      it 'returns false so the caller can fall back to a manual selection' do
        expect(quest.choose_fountain_item).to be false
      end
    end

    context 'when the fountain gives no recognized response' do
      before do
        allow(DRC).to receive(:bput).and_return(nil)
      end

      it 'returns false rather than raising on a nil response' do
        expect(quest.choose_fountain_item).to be false
      end
    end

    context 'when several known items are configured' do
      # Verify the iteration and short-circuit behavior independently of the
      # currently shipped data by substituting a multi-item list.
      before do
        stub_const("#{described_class}::BONDING_FOUNTAIN_ITEMS", %w[helm cup goblet])
        allow(DRC).to receive(:bput).with('get helm', any_args).and_return(item_absent_response)
        allow(DRC).to receive(:bput).with('get cup', any_args).and_return(chosen_wisely_response)
        allow(DRC).to receive(:bput).with('get goblet', any_args).and_return(item_absent_response)
      end

      it 'takes the first item the fountain accepts and stops trying the rest' do
        expect(quest.choose_fountain_item).to be true
        expect(DRC).to have_received(:bput).with('get helm', any_args)
        expect(DRC).to have_received(:bput).with('get cup', any_args)
        expect(DRC).not_to have_received(:bput).with('get goblet', any_args)
      end
    end
  end
end
