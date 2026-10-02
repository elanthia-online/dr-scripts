# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('sell-pouches.lic', 'PouchSeller')

RSpec.describe PouchSeller do
  let(:messages) { [] }
  let(:sale_line) { 'The clerk counts out the gems and hands you 12,345 Kronars.' }

  before do
    allow(DRC).to receive(:message) { |text| messages << text }
    allow(DRC).to receive(:wait_for_script_to_complete)
    allow(DRCI).to receive(:dispose_trash).and_return(true)
    allow(DRCI).to receive(:put_away_item?).and_return(true)
    allow(DRCI).to receive(:in_hands?).with('pouch').and_return(true)
  end

  # Instantiate without running initialize, setting only what sell_pouch reads.
  def build_seller(**ivars)
    seller = PouchSeller.allocate
    { pouch_container: 'backpack', worn_trashcan: nil, worn_trashcan_verb: nil }
      .merge(ivars).each { |k, v| seller.instance_variable_set(:"@#{k}", v) }
    allow(seller).to receive(:fput)
    allow(seller).to receive(:pause)
    seller
  end

  # Answer each command with a game line, returning only the matched text the
  # way DRC.bput does: the first pattern that matches wins, '' on no match, and
  # string patterns are case-insensitive regexes rather than literals.
  #
  # @param replies [Hash{String=>String}] command => game line
  def stub_game(replies)
    allow(DRC).to receive(:bput) do |command, *patterns|
      line = replies[command].to_s
      patterns.lazy.map { |pattern| line[pattern.is_a?(Regexp) ? pattern : /#{pattern}/i] }.find(&:itself).to_s
    end
  end

  describe '#sell_pouch' do
    context 'when the gem shop buys the pouch' do
      before { stub_game('sell pouch' => sale_line) }

      it 'throws the empty pouch away using the worn trashcan settings' do
        build_seller(worn_trashcan: 'shroud', worn_trashcan_verb: 'tap').sell_pouch(1234)

        expect(DRCI).to have_received(:dispose_trash).with('pouch', 'shroud', 'tap')
        expect(DRCI).not_to have_received(:put_away_item?)
      end

      it 'never puts the pouch in a hard-coded bucket' do
        seller = build_seller
        seller.sell_pouch(1234)

        expect(seller).not_to have_received(:fput).with(/bucket/)
      end

      it 'says to check your hands when the empty pouch cannot be thrown away' do
        allow(DRCI).to receive(:dispose_trash).and_return(nil)

        build_seller.sell_pouch(1234)

        expect(messages).to include(a_string_matching(/Couldn't throw away the empty pouch -- check your hands/))
      end

      it 'throws nothing away when the empty pouch is not in hand' do
        allow(DRCI).to receive(:in_hands?).with('pouch').and_return(false)

        build_seller.sell_pouch(1234)

        expect(DRCI).not_to have_received(:dispose_trash)
        expect(messages).to include(a_string_matching(/isn't in your hand -- not throwing anything away/))
      end

      it 'waits for a hand update that trails the sale' do
        allow(DRCI).to receive(:in_hands?).with('pouch').and_return(false, false, true)

        build_seller.sell_pouch(1234)

        expect(DRCI).to have_received(:dispose_trash).once
      end

      it 'runs sell-loot afterwards' do
        build_seller.sell_pouch(1234)

        expect(DRC).to have_received(:wait_for_script_to_complete).with('sell-loot')
      end
    end

    {
      'refuses it'        => "There's not a market for that around here.",
      'is not interested' => "The clerk says, \"I'm not interested in that.\"",
      'does not answer'   => ''
    }.each do |label, line|
      context "when the gem shop #{label}" do
        before { stub_game('sell pouch' => line) }

        it 'puts the pouch back instead of throwing it away' do
          build_seller.sell_pouch(1234)

          expect(DRCI).to have_received(:put_away_item?).with('pouch', 'backpack')
          expect(DRCI).not_to have_received(:dispose_trash)
          expect(messages).to include(a_string_matching(/didn't buy the pouch/))
        end

        it 'says the same pouch will be tried first next time' do
          build_seller.sell_pouch(1234)

          expect(messages).to include(a_string_matching(/tried first again next time -- sell it by hand or move it out of your backpack/))
        end

        it 'says the pouch is still in hand with its gems when it will not go back' do
          allow(DRCI).to receive(:put_away_item?).and_return(false)

          build_seller.sell_pouch(1234)

          expect(messages).to include(a_string_matching(/won't go back in your backpack -- it's still in your hand with its gems/))
          expect(messages).not_to include(a_string_matching(/it's back in your/))
        end

        it 'still runs sell-loot afterwards' do
          build_seller.sell_pouch(1234)

          expect(DRC).to have_received(:wait_for_script_to_complete).with('sell-loot')
        end
      end
    end
  end

  describe '#initialize' do
    before do
      $test_settings = OpenStruct.new(hometown: 'Crossing', sale_pouches_container: 'backpack',
                                      worn_trashcan: 'shroud', worn_trashcan_verb: 'tap')
      $test_data.town = { 'Crossing' => { 'gemshop' => { 'id' => 1234 } } }
      stub_game('get pouch from my backpack' => 'You get a gem pouch from inside your backpack.',
                'sell pouch'                 => sale_line)
    end

    it 'reads the worn trashcan settings for the empty pouch' do
      expect { PouchSeller.new }.not_to raise_error

      expect(DRCI).to have_received(:dispose_trash).with('pouch', 'shroud', 'tap')
    end
  end
end
