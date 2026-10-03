# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('sell-pouches.lic', 'PouchSeller')

RSpec.describe PouchSeller do
  let(:messages) { [] }
  let(:get_line) { 'You get a gem pouch from inside your backpack.' }
  let(:appraise_line) { 'You glance at the pouch and estimate the gems are worth a total of about 10,000 Kronars.' }
  let(:empty_line) { "There doesn't appear to be anything in the pouch." }
  let(:sale_line) { 'The clerk counts out the gems and hands you 12,345 Kronars.' }

  before do
    allow(DRC).to receive(:message) { |text| messages << text }
    allow(DRC).to receive(:wait_for_script_to_complete)
    allow(DRCI).to receive(:dispose_trash).and_return(true)
    allow(DRCI).to receive(:put_away_item?).and_return(true)
    allow(DRCI).to receive(:inside?).and_return(true)
    allow(DRCI).to receive(:in_hands?).with('pouch').and_return(true)
    allow(DRCT).to receive(:walk_to)
    allow(DRSkill).to receive(:getxp).with('Trading').and_return(10)
  end

  # Instantiate without running initialize, setting only what the loop reads.
  def build_seller(**ivars)
    seller = PouchSeller.allocate
    defaults = { pouch_container: 'backpack', spare_container: nil, trading_limit: 30,
                 worn_trashcan: nil, worn_trashcan_verb: nil }
    defaults.merge(ivars).each { |k, v| seller.instance_variable_set(:"@#{k}", v) }
    allow(seller).to receive(:fput)
    allow(seller).to receive(:pause)
    seller
  end

  # Answer each command with a game line, returning only the matched text the
  # way DRC.bput does: the first pattern that matches wins, '' on no match, and
  # string patterns are case-insensitive regexes rather than literals. An Array
  # of lines answers successive sends in turn, then nothing.
  #
  # @param replies [Hash{String=>String, Array<String>}] command => game line(s)
  # @return [Array<String>] the commands sent
  def stub_game(replies)
    commands = []
    queues = replies.transform_values { |reply| reply.is_a?(Array) ? reply.dup : reply }
    allow(DRC).to receive(:bput) do |command, *patterns|
      commands << command
      reply = queues[command]
      line = (reply.is_a?(Array) ? reply.shift : reply).to_s
      patterns.lazy.map { |pattern| line[pattern.is_a?(Regexp) ? pattern : /#{pattern}/i] }.find(&:itself).to_s
    end
    commands
  end

  def gets_sent(commands)
    commands.count('get pouch from my backpack')
  end

  describe '#sell_pouches' do
    context 'when the gem shop buys the pouch' do
      before do
        stub_game('get pouch from my backpack' => [get_line],
                  'appraise my pouch quick'    => appraise_line,
                  'sell pouch'                 => sale_line)
      end

      it 'throws the empty pouch away using the worn trashcan settings' do
        build_seller(worn_trashcan: 'shroud', worn_trashcan_verb: 'tap').sell_pouches

        expect(DRCI).to have_received(:dispose_trash).with('pouch', 'shroud', 'tap')
        expect(DRCI).not_to have_received(:put_away_item?)
      end

      it 'never puts the pouch in a hard-coded bucket' do
        seller = build_seller
        seller.sell_pouches

        expect(seller).not_to have_received(:fput).with(/bucket/)
      end

      it 'reports the sale against the appraised value' do
        build_seller.sell_pouches

        expect(messages).to include('***STATUS*** Pouch appraised at 1.0 plat Kronars, sold for 1.2 plat Kronars (23.45% bonus)')
      end
    end

    it 'sells every pouch in the container, then stops when there are none left' do
      commands = stub_game('get pouch from my backpack' => [get_line, get_line],
                           'appraise my pouch quick'    => appraise_line,
                           'sell pouch'                 => sale_line)

      build_seller.sell_pouches

      expect(commands.count('sell pouch')).to eq(2)
      expect(gets_sent(commands)).to eq(3)
      expect(DRCI).to have_received(:dispose_trash).twice
    end

    it 'stops once Trading passes the limit' do
      allow(DRSkill).to receive(:getxp).with('Trading').and_return(10, 31)
      commands = stub_game('get pouch from my backpack' => [get_line, get_line],
                           'appraise my pouch quick'    => appraise_line,
                           'sell pouch'                 => sale_line)

      build_seller.sell_pouches

      expect(commands.count('sell pouch')).to eq(1)
      expect(messages).to include(a_string_matching(/Trading mindstate is above 30/))
    end

    it 'stops when the empty pouch cannot be thrown away' do
      allow(DRCI).to receive(:dispose_trash).and_return(false)
      commands = stub_game('get pouch from my backpack' => [get_line, get_line],
                           'appraise my pouch quick'    => appraise_line,
                           'sell pouch'                 => sale_line)

      build_seller.sell_pouches

      expect(gets_sent(commands)).to eq(1)
      expect(messages).to include(a_string_matching(/Couldn't throw away the empty pouch -- check your hands/))
    end

    it 'throws nothing away and stops when the sold pouch is not in hand' do
      allow(DRCI).to receive(:in_hands?).with('pouch').and_return(false)
      commands = stub_game('get pouch from my backpack' => [get_line, get_line],
                           'appraise my pouch quick'    => appraise_line,
                           'sell pouch'                 => sale_line)

      build_seller.sell_pouches

      expect(DRCI).not_to have_received(:dispose_trash)
      expect(gets_sent(commands)).to eq(1)
      expect(messages).to include(a_string_matching(/isn't in your hand -- not throwing anything away/))
    end

    it 'waits for a hand update that trails the sale' do
      allow(DRCI).to receive(:in_hands?).with('pouch').and_return(false, false, true)
      stub_game('get pouch from my backpack' => [get_line],
                'appraise my pouch quick'    => appraise_line,
                'sell pouch'                 => sale_line)

      build_seller.sell_pouches

      expect(DRCI).to have_received(:dispose_trash).once
    end

    it 'still sells a pouch whose appraisal it could not read' do
      stub_game('get pouch from my backpack' => [get_line],
                'appraise my pouch quick'    => 'You cannot appraise that while it is moving.',
                'sell pouch'                 => sale_line)

      build_seller.sell_pouches

      expect(messages).to include('***STATUS*** Pouch sold for 1.2 plat Kronars (no appraisal)')
    end

    {
      'refuses it'        => "There's not a market for that around here.",
      'is not interested' => "The clerk says, \"I'm not interested in that.\"",
      'does not answer'   => ''
    }.each do |label, line|
      context "when the gem shop #{label}" do
        let!(:commands) do
          stub_game('get pouch from my backpack' => [get_line, get_line],
                    'appraise my pouch quick'    => appraise_line,
                    'sell pouch'                 => line)
        end

        it 'puts the pouch back instead of throwing it away' do
          build_seller.sell_pouches

          expect(DRCI).to have_received(:put_away_item?).with('pouch', 'backpack')
          expect(DRCI).not_to have_received(:dispose_trash)
          expect(messages).to include(a_string_matching(/didn't buy the pouch/))
        end

        it 'stops instead of fetching the next pouch' do
          build_seller.sell_pouches

          expect(gets_sent(commands)).to eq(1)
        end

        it 'says the same pouch will be tried first next time' do
          build_seller.sell_pouches

          expect(messages).to include(a_string_matching(/tried first again next time -- sell it by hand or move it out of your backpack/))
        end

        it 'says the pouch is still in hand with its gems when it will not go back' do
          allow(DRCI).to receive(:put_away_item?).and_return(false)

          build_seller.sell_pouches

          expect(messages).to include(a_string_matching(/won't go back in your backpack -- it's still in your hand with its gems/))
          expect(messages).not_to include(a_string_matching(/it's back in your/))
        end
      end
    end

    context 'when there is no pouch in hand to sell' do
      let!(:commands) do
        stub_game('get pouch from my backpack' => [get_line, get_line],
                  'appraise my pouch quick'    => appraise_line,
                  'sell pouch'                 => 'What were you referring to?')
      end

      before { allow(DRCI).to receive(:in_hands?).with('pouch').and_return(false) }

      it 'says so instead of claiming the pouch is still in hand, and stops' do
        build_seller.sell_pouches

        expect(DRCI).not_to have_received(:put_away_item?)
        expect(messages).to include(a_string_matching(/no pouch in your hand to put back/))
        expect(messages).not_to include(a_string_matching(/with its gems/))
        expect(gets_sent(commands)).to eq(1)
      end

      it 'waits for the hand update before deciding there is no pouch' do
        build_seller.sell_pouches

        expect(DRCI).to have_received(:in_hands?).with('pouch').exactly(3).times
      end
    end

    context 'when a pouch has nothing in it' do
      let!(:commands) do
        stub_game('get pouch from my backpack' => [get_line, get_line],
                  'appraise my pouch quick'    => [empty_line, appraise_line],
                  'sell pouch'                 => sale_line)
      end

      it 'moves it to a separate spare_gem_pouch_container and sells the next pouch' do
        build_seller(spare_container: 'haversack').sell_pouches

        expect(DRCI).to have_received(:put_away_item?).with('pouch', 'haversack')
        expect(commands.count('sell pouch')).to eq(1)
        expect(DRCI).to have_received(:dispose_trash).once
      end

      it 'stops when it cannot be moved to the spare container' do
        allow(DRCI).to receive(:put_away_item?).with('pouch', 'haversack').and_return(false)

        build_seller(spare_container: 'haversack').sell_pouches

        expect(gets_sent(commands)).to eq(1)
        expect(messages).to include(a_string_matching(/Couldn't put the empty pouch in your haversack/))
      end

      it 'throws it away when there is no spare_gem_pouch_container' do
        build_seller.sell_pouches

        expect(DRCI).to have_received(:dispose_trash).twice
        expect(commands.count('sell pouch')).to eq(1)
      end

      it 'puts it back and stops when the spare container is the sale container' do
        build_seller(spare_container: 'backpack').sell_pouches

        expect(DRCI).to have_received(:put_away_item?).with('pouch', 'backpack')
        expect(DRCI).not_to have_received(:dispose_trash)
        expect(gets_sent(commands)).to eq(1)
      end

      it 'never tries to sell it' do
        build_seller(spare_container: 'backpack').sell_pouches

        expect(commands).not_to include('sell pouch')
      end
    end
  end

  describe '#initialize' do
    before do
      $test_settings = OpenStruct.new(hometown: 'Crossing', sale_pouches_container: 'backpack',
                                      worn_trashcan: 'shroud', worn_trashcan_verb: 'tap')
      $test_data.town = { 'Crossing' => { 'gemshop' => { 'id' => 1234 } } }
      stub_game('get pouch from my backpack' => [get_line],
                'appraise my pouch quick'    => appraise_line,
                'sell pouch'                 => sale_line)
    end

    it 'walks to the gem shop, sells, and runs sell-loot' do
      expect { PouchSeller.new }.not_to raise_error

      expect(DRCT).to have_received(:walk_to).with(1234)
      expect(DRCI).to have_received(:dispose_trash).with('pouch', 'shroud', 'tap')
      expect(DRC).to have_received(:wait_for_script_to_complete).with('sell-loot')
    end

    it 'checks the container without taking anything out' do
      expect { PouchSeller.new }.not_to raise_error

      expect(DRCI).to have_received(:inside?).with('pouch', 'backpack')
    end

    context 'when there are no pouches to sell' do
      before { allow(DRCI).to receive(:inside?).and_return(false) }

      it 'skips the trip but still runs sell-loot' do
        expect { PouchSeller.new }.not_to raise_error

        expect(DRCT).not_to have_received(:walk_to)
        expect(DRC).to have_received(:wait_for_script_to_complete).with('sell-loot')
        expect(messages).to include(a_string_matching(/No pouches in your backpack/))
      end
    end

    context 'when Trading is already above the limit' do
      before { allow(DRSkill).to receive(:getxp).with('Trading').and_return(31) }

      it 'skips the trip but still runs sell-loot' do
        expect { PouchSeller.new }.not_to raise_error

        expect(DRCT).not_to have_received(:walk_to)
        expect(DRC).to have_received(:wait_for_script_to_complete).with('sell-loot')
      end
    end

    it 'defaults the limit to 30, selling at exactly 30' do
      allow(DRSkill).to receive(:getxp).with('Trading').and_return(30)

      expect { PouchSeller.new }.not_to raise_error

      expect(DRCT).to have_received(:walk_to).with(1234)
    end

    it 'takes the limit from sell_pouches_trading_limit' do
      $test_settings.sell_pouches_trading_limit = 16
      allow(DRSkill).to receive(:getxp).with('Trading').and_return(20)

      expect { PouchSeller.new }.not_to raise_error

      expect(DRCT).not_to have_received(:walk_to)
      expect(messages).to include(a_string_matching(/Trading mindstate is above 16/))
    end

    it 'exits without walking when the town has no gem shop' do
      $test_data.town = { 'Crossing' => { 'gemshop' => {} } }

      expect { PouchSeller.new }.to raise_error(SystemExit)

      expect(DRCT).not_to have_received(:walk_to)
    end
  end
end
