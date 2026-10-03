# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('sell-pouches.lic', 'PouchSeller')

RSpec.describe PouchSeller do
  let(:messages) { [] }
  let(:full_appraisal) { 'You glance at the pouch and estimate the gems are worth a total of about 10,000 Kronars.' }
  let(:sale_line) { 'The clerk counts out the gems and hands you 12,345 Kronars.' }
  let(:appraisals) do
    {
      full: full_appraisal,
      empty: "There doesn't appear to be anything in the pouch.",
      closed: "You'll need to open the gem pouch to examine its contents.",
      odd: "You can't appraise the pouch."
    }
  end
  let(:report) do
    '***STATUS*** Pouch appraised at 1 platinum Kronars, sold for 1 platinum, 2 gold, 3 silver, 4 bronze, 5 copper Kronars (23.45% bonus)'
  end

  before do
    allow(DRC).to receive(:message) { |text| messages << text }
    allow(DRC).to receive(:wait_for_script_to_complete)
    allow(DRCI).to receive(:inside?).and_return(true)
    allow(DRCI).to receive(:in_hands?).with('pouch').and_return(true)
    allow(DRCT).to receive(:walk_to)
    allow(DRSkill).to receive(:getxp).with('Trading').and_return(10)
    allow(DRCM).to receive(:minimize_coins).with(10_000).and_return(['1 platinum'])
    allow(DRCM).to receive(:minimize_coins).with(12_345).and_return(['1 platinum', '2 gold', '3 silver', '4 bronze', '5 copper'])
  end

  # Instantiate without running initialize, setting only what the loop reads.
  def build_seller(**ivars)
    seller = PouchSeller.allocate
    defaults = { pouch_container: 'backpack', gemshop: 1234, trading_limit: 30,
                 worn_trashcan: nil, worn_trashcan_verb: nil }
    defaults.merge(ivars).each { |k, v| seller.instance_variable_set(:"@#{k}", v) }
    allow(seller).to receive(:fput)
    allow(seller).to receive(:pause)
    seller
  end

  # Model sale_pouches_container as an ordered list of pouches, answering each
  # command with the matched text the way DRC.bput does (first pattern wins, ''
  # on no match, string patterns as case-insensitive regexes). GET takes the
  # pouch at the ordinal's position, a put-back goes to the front as PUT does in
  # game, and a sold pouch leaves when it's thrown away.
  #
  # Pouch kinds: :full sells; :empty is empty; :closed must be opened first and
  # is then :full; :odd answers the appraisal with a line the script can't read,
  # and :silent doesn't answer at all.
  #
  # @return [Hash] :pouches (what's left in the container) and :commands (sent)
  def model_container(*pouches, sale: sale_line, opens: true)
    state = { pouches: pouches, held: nil, commands: [] }
    allow(DRC).to receive(:bput) do |command, *patterns|
      state[:commands] << command
      raise 'more than 200 commands: the loop is not ending' if state[:commands].size > 200

      line = game_line(state, command, sale)
      patterns.lazy.map { |pattern| line[pattern.is_a?(Regexp) ? pattern : /#{pattern}/i] }.find(&:itself).to_s
    end
    allow(DRCI).to receive(:open_container?).with('my pouch') do
      state[:held] = :full if opens
      opens
    end
    allow(DRCI).to receive(:put_away_item?).with('pouch', 'backpack') do
      state[:pouches].unshift(state[:held])
      state[:held] = nil
      true
    end
    allow(DRCI).to receive(:dispose_trash) do
      state[:held] = nil
      true
    end
    state
  end

  def game_line(state, command, sale)
    case command
    when /^get (\w+) pouch from my backpack$/
      state[:held] = state[:pouches].delete_at($ORDINALS.index(Regexp.last_match(1)))
      state[:held] ? 'You get a gem pouch from inside your leather backpack.' : 'What were you referring to?'
    when 'appraise my pouch quick'
      appraisals.fetch(state[:held], '')
    when 'sell pouch'
      sale
    else
      ''
    end
  end

  def gets_sent(state)
    state[:commands].grep(/^get \w+ pouch from my backpack$/)
  end

  def sales(state)
    state[:commands].count('sell pouch')
  end

  describe '#sell_pouches' do
    context 'when the gem shop buys the pouch' do
      let!(:state) { model_container(:full) }

      it 'throws the empty pouch away using the worn trashcan settings' do
        build_seller(worn_trashcan: 'shroud', worn_trashcan_verb: 'tap').sell_pouches

        expect(DRCI).to have_received(:dispose_trash).with('pouch', 'shroud', 'tap')
        expect(state[:pouches]).to be_empty
      end

      it 'never puts the pouch in a hard-coded bucket' do
        seller = build_seller
        seller.sell_pouches

        expect(seller).not_to have_received(:fput).with(/bucket/)
      end

      it 'reports the sale in coins against the appraised value' do
        build_seller.sell_pouches

        expect(messages).to include(report)
      end

      it 'walks to the gem shop and buffs before selling' do
        build_seller.sell_pouches

        expect(DRCT).to have_received(:walk_to).with(1234)
        expect(DRC).to have_received(:wait_for_script_to_complete).with('buff', ['test-script'])
      end
    end

    context 'when the pouch is worth less than a platinum' do
      let(:full_appraisal) { 'You glance at the pouch and estimate the gems are worth a total of about 450 Kronars.' }
      let(:sale_line) { 'The clerk counts out the gems and hands you 540 Kronars.' }

      it 'reports the amounts in coins rather than rounding them to zero' do
        allow(DRCM).to receive(:minimize_coins).with(450).and_return(['4 silver', '5 bronze'])
        allow(DRCM).to receive(:minimize_coins).with(540).and_return(['5 silver', '4 bronze'])
        model_container(:full)

        build_seller.sell_pouches

        expect(messages).to include('***STATUS*** Pouch appraised at 4 silver, 5 bronze Kronars, sold for 5 silver, 4 bronze Kronars (20.0% bonus)')
      end
    end

    it 'sells every full pouch and leaves the empties where they are' do
      state = model_container(:empty, :empty, :full)

      build_seller.sell_pouches

      expect(sales(state)).to eq(1)
      expect(DRCI).to have_received(:dispose_trash).once
      expect(state[:pouches]).to eq(%i[empty empty])
      expect(messages).to include('***STATUS*** Pouch is empty -- leaving it in your backpack.')
    end

    it 'keeps going past an empty pouch between full ones' do
      state = model_container(:full, :empty, :full)

      build_seller.sell_pouches

      expect(sales(state)).to eq(2)
      expect(state[:pouches]).to eq(%i[empty])
    end

    it 'fetches past the pouches it has skipped by ordinal' do
      state = model_container(:empty, :full)

      build_seller.sell_pouches

      expect(gets_sent(state)).to eq(['get first pouch from my backpack',
                                      'get second pouch from my backpack',
                                      'get second pouch from my backpack'])
    end

    it 'stops once it has skipped as many pouches as there are ordinals' do
      empties = [:empty] * ($ORDINALS.size + 2)
      state = model_container(*empties, :full)

      build_seller.sell_pouches

      expect(gets_sent(state).size).to eq($ORDINALS.size)
      expect(sales(state)).to eq(0)
      expect(messages).to include("***STATUS*** Skipped #{$ORDINALS.size} pouches in your backpack -- stopping.")
    end

    it 'does not walk to the gem shop when nothing in the container can be sold' do
      state = model_container(:empty, :odd)

      build_seller.sell_pouches

      expect(DRCT).not_to have_received(:walk_to)
      expect(sales(state)).to eq(0)
    end

    it 'walks to the gem shop only once for several sales' do
      state = model_container(:empty, :full, :full)

      build_seller.sell_pouches

      expect(sales(state)).to eq(2)
      expect(DRCT).to have_received(:walk_to).once
    end

    it 'opens a closed pouch, appraises it again and sells it' do
      state = model_container(:closed)

      build_seller.sell_pouches

      expect(DRCI).to have_received(:open_container?).with('my pouch')
      expect(sales(state)).to eq(1)
      expect(messages).to include(report)
    end

    it 'skips a closed pouch it cannot open' do
      state = model_container(:closed, :full, opens: false)

      build_seller.sell_pouches

      expect(messages).to include("***STATUS*** Couldn't open the pouch to appraise it.")
      expect(sales(state)).to eq(1)
      expect(state[:pouches]).to eq(%i[closed])
    end

    it 'skips a pouch whose appraisal it cannot read instead of selling it' do
      state = model_container(:odd, :full)

      build_seller.sell_pouches

      expect(sales(state)).to eq(1)
      expect(state[:pouches]).to eq(%i[odd])
      expect(messages).to include(a_string_matching(/Could not read the appraisal: You can.t appraise/))
      expect(messages).to include("***STATUS*** Couldn't appraise the pouch -- leaving it in your backpack.")
    end

    it 'says there was no reply when the appraisal times out' do
      model_container(:silent)

      build_seller.sell_pouches

      expect(messages).to include('***STATUS*** Could not read the appraisal: no reply')
    end

    it 'stops when a skipped pouch will not go back' do
      state = model_container(:empty, :full)
      allow(DRCI).to receive(:put_away_item?).with('pouch', 'backpack').and_return(false)

      build_seller.sell_pouches

      expect(sales(state)).to eq(0)
      expect(messages).to include(a_string_matching(/Pouch is empty, and it won't go back in your backpack -- it's still in your hand/))
    end

    it 'stops once Trading passes the limit' do
      allow(DRSkill).to receive(:getxp).with('Trading').and_return(10, 31)
      state = model_container(:full, :full)

      build_seller.sell_pouches

      expect(sales(state)).to eq(1)
      expect(messages).to include(a_string_matching(/Trading mindstate is above 30/))
    end

    it 'stops when the empty pouch cannot be thrown away' do
      state = model_container(:full, :full)
      allow(DRCI).to receive(:dispose_trash).and_return(false)

      build_seller.sell_pouches

      expect(gets_sent(state).size).to eq(1)
      expect(messages).to include(a_string_matching(/Couldn't throw away the empty pouch -- check your hands/))
    end

    it 'throws nothing away and stops when the sold pouch is not in hand' do
      allow(DRCI).to receive(:in_hands?).with('pouch').and_return(false)
      state = model_container(:full, :full)

      build_seller.sell_pouches

      expect(DRCI).not_to have_received(:dispose_trash)
      expect(gets_sent(state).size).to eq(1)
      expect(messages).to include(a_string_matching(/isn't in your hand -- not throwing anything away/))
    end

    it 'waits for a hand update that trails the sale' do
      allow(DRCI).to receive(:in_hands?).with('pouch').and_return(false, false, true)
      model_container(:full)

      build_seller.sell_pouches

      expect(DRCI).to have_received(:dispose_trash).once
    end

    {
      'refuses it'        => "There's not a market for that around here.",
      'is not interested' => "The clerk says, \"I'm not interested in that.\"",
      'does not answer'   => ''
    }.each do |label, line|
      context "when the gem shop #{label}" do
        let!(:state) { model_container(:full, :full, sale: line) }

        it 'puts the pouch back instead of throwing it away, and stops' do
          build_seller.sell_pouches

          expect(DRCI).not_to have_received(:dispose_trash)
          expect(state[:pouches]).to eq(%i[full full])
          expect(gets_sent(state).size).to eq(1)
        end

        it 'says the same pouch will be tried first next time' do
          build_seller.sell_pouches

          expect(messages).to include(a_string_matching(/tried first again next time -- sell it by hand or move it out of your backpack/))
        end

        it 'says the pouch is still in hand with its gems when it will not go back' do
          allow(DRCI).to receive(:put_away_item?).with('pouch', 'backpack').and_return(false)

          build_seller.sell_pouches

          expect(messages).to include(a_string_matching(/won't go back in your backpack -- it's still in your hand with its gems/))
          expect(messages).not_to include(a_string_matching(/it's back in your/))
        end
      end
    end

    context 'when there is no pouch in hand to sell' do
      let!(:state) { model_container(:full, :full, sale: 'What were you referring to?') }

      before { allow(DRCI).to receive(:in_hands?).with('pouch').and_return(false) }

      it 'says so instead of claiming the pouch is still in hand, and stops' do
        build_seller.sell_pouches

        expect(DRCI).not_to have_received(:put_away_item?)
        expect(messages).to include(a_string_matching(/no pouch in your hand to put back/))
        expect(messages).not_to include(a_string_matching(/with its gems/))
        expect(gets_sent(state).size).to eq(1)
      end

      it 'waits for the hand update before deciding there is no pouch' do
        build_seller.sell_pouches

        expect(DRCI).to have_received(:in_hands?).with('pouch').exactly(3).times
      end
    end
  end

  describe '#initialize' do
    before do
      $test_settings = OpenStruct.new(hometown: 'Crossing', sale_pouches_container: 'backpack',
                                      worn_trashcan: 'shroud', worn_trashcan_verb: 'tap')
      $test_data.town = { 'Crossing' => { 'gemshop' => { 'id' => 1234 } } }
      model_container(:full)
    end

    it 'walks to the gem shop, sells, and runs sell-loot' do
      expect { PouchSeller.new }.not_to raise_error

      expect(DRCT).to have_received(:walk_to).with(1234)
      expect(DRCI).to have_received(:dispose_trash).with('pouch', 'shroud', 'tap')
      expect(DRC).to have_received(:wait_for_script_to_complete).with('sell-loot')
    end

    it 'stays home when the container holds only pouches it will not sell' do
      model_container(:empty, :odd)

      expect { PouchSeller.new }.not_to raise_error

      expect(DRCT).not_to have_received(:walk_to)
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

    context 'when sale_pouches_container is not set' do
      before { $test_settings.sale_pouches_container = nil }

      it 'says so, checks nothing, and still runs sell-loot' do
        expect { PouchSeller.new }.not_to raise_error

        expect(messages).to include('***STATUS*** sale_pouches_container is not set -- nothing to sell.')
        expect(DRCI).not_to have_received(:inside?)
        expect(DRC).to have_received(:wait_for_script_to_complete).with('sell-loot')
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
