# frozen_string_literal: true

require 'ostruct'
require 'timeout'

require_relative 'spec_helper'

load_lic_class('spin.lic', 'Spin')

# Game lines are real, from Mahtra's silk spin in Shard on 2026-11-04
# (spec/fixtures/spin/log_lines.json, cited "1104:<line>"). ReplayGame answers
# every DRC.bput and fput the script sends from those lines, so these examples
# run the real Spin code from its constructor, exactly as `;spin silk` does.
RSpec.describe Spin do
  def log(cite)
    ReplayGame.log(cite)
  end

  let(:game) { ReplayGame.new.install(self) }

  # A spin that never ends would hang the suite instead of failing it, and an
  # exit nothing expected would end the whole run with status 0 (spec_helper).
  around do |example|
    Timeout.timeout(10) { example.run }
  rescue SystemExit
    raise 'spin exited where the example expected it to carry on'
  end

  before do
    $test_settings = OpenStruct.new(
      hometown: 'Shard',
      crafting_container: 'duffel bag',
      crafting_items_in_container: [],
      outfitting_belt: { 'name' => "tailor's.toolbelt", 'items' => ['scissors'] }
    )
    $test_data = OpenStruct.new(
      crafting: { 'tailoring' => { 'Shard' => { 'stock-room' => 10_939, 'spinning-rooms' => [10_944], 'idle-room' => 19_333 } } }
    )
    $parsed_args = { 'material' => 'silk' }

    # The attendant hands over each bundle (1104:30058); DRCT.order_item
    # returns what its bput matched.
    allow(DRCT).to receive(:order_item) do
      $left_hand = 'silk fibers'
      'takes some coins from you'
    end
    allow(DRCM).to receive(:town_currency).with('Shard').and_return('dokoras')
    allow(DRCM).to receive(:convert_currency).and_return(135)
  end

  # The game's side of one whole silk spin, line for line as Mahtra's log has
  # it from the first cut to the stowed spool (1104:30060-30296).
  def script_silk_spin
    game.script('mark my fibers at 10', log('1104:30060'))
    game.script('cut my fibers with my scissors', log('1104:30068'))
    # What the game now says to the two commands the old cut handling sent.
    game.fallback('drop my other fibers', log('1104:30072'))
    game.fallback('get my fibers', log('1104:30091'))
    13.times { game.script('combine my fiber', log('1104:30101')) }
    game.script('put fiber on wheel', log('1104:30204'), after: ->(_) { $left_hand = nil })
    game.script('adjust wheel to heavy', log('1104:30206'), log('1104:30207'))
    game.script('spin wheel', log('1104:30215'), log('1104:30216'))
    game.script('spin wheel', log('1104:30218'), log('1104:30219'), log('1104:30220'))
    game.script('clean wheel', log('1104:30226'), log('1104:30227'))
    game.script('spin wheel', log('1104:30230'), log('1104:30231'), log('1104:30232'))
    game.script('turn wheel', log('1104:30244'), log('1104:30245'))
    game.script('spin wheel', log('1104:30254'), log('1104:30274'), log('1104:30275'))
    game.script('push wheel', log('1104:30281'), log('1104:30282'))
    # The spool is in hand once the reply has arrived (XML: <left exist="1958040"
    # noun="thread">silk thread</left> with the tie-off line).
    game.script('spin wheel', log('1104:30284'), log('1104:30285'), log('1104:30286'),
                after: ->(_) { $left_hand = 'silk thread' })
    game.script('stow my silk thread', log('1104:30296'))
  end

  describe 'cutting the first silk bundle down to 10 yards' do
    before { script_silk_spin }

    it 'goes straight on to the next bundle, because the game already put the excess away' do
      Spin.new

      cut = game.sent.index('cut my fibers with my scissors')
      expect(game.sent[cut + 1]).to eq('combine my fiber')
    end

    it 'never sends a DROP command' do
      Spin.new

      expect(game.sent.grep(/\Adrop\b/)).to be_empty
    end

    it 'does not send the old pick-up of the cut piece' do
      Spin.new

      expect(game.sent).not_to include('get my fibers')
    end

    it 'loses no time to unanswered commands (the old drop and get each waited out 15 seconds)' do
      Spin.new

      expect(game.diagnostics).to be_empty
    end

    it 'still buys 13 more bundles after the cut one, for 400 yards on the wheel' do
      Spin.new

      expect(DRCT).to have_received(:order_item).with(10_939, 1).exactly(14).times
      expect(game.sent.count('combine my fiber')).to eq(13)
    end
  end

  describe 'spinning until the spool is done' do
    before { script_silk_spin }

    it 'answers each wheel problem with its fix, then spins on' do
      Spin.new

      spin_commands = game.sent.drop_while { |command| command != 'spin wheel' }
      expect(spin_commands).to eq(
        ['spin wheel', 'spin wheel', 'clean wheel', 'spin wheel', 'turn wheel',
         'spin wheel', 'push wheel', 'spin wheel', 'stow my silk thread']
      )
    end

    it 'stops spinning once the spool is in hand and stows it' do
      Spin.new

      expect(game.sent.last).to eq('stow my silk thread')
      expect(game.sent.count('spin wheel')).to eq(5)
    end

    it 'keeps spinning when a background script puts something else in a hand' do
      # e.g. almanac getting its book mid-spin, as it did mid-weave (1104:30663)
      game.override('clean wheel', log('1104:30226'), log('1104:30227'), after: ->(_) { $right_hand = 'encyclopedic almanac' })

      Spin.new

      expect(game.sent.count('spin wheel')).to eq(5)
      expect(game.sent.last).to eq('stow my silk thread')
    end
  end

  describe 'starting with something in a hand' do
    before { $right_hand = 'cotton thread' }

    it 'empties the hands before buying anything, then spins the whole spool' do
      script_silk_spin
      expect(DRCI).to receive(:stow_hands).ordered do
        $right_hand = nil
        true
      end
      expect(DRCM).to receive(:ensure_copper_on_hand).ordered.and_return(true)

      Spin.new

      expect(game.sent.count('spin wheel')).to eq(5)
      expect(game.sent.last).to eq('stow my silk thread')
    end

    it 'stops before spending money when the hands cannot be emptied' do
      allow(DRCI).to receive(:stow_hands).and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: Could not empty your hands before buying fiber.')

      expect { Spin.new }.to raise_error(SystemExit)
      expect(DRCT).not_to have_received(:order_item)
      expect(game.sent).to be_empty
    end
  end

  describe 'when the game stops answering the wheel' do
    before do
      game.script('mark my fibers at 10', log('1104:30060'))
      game.script('cut my fibers with my scissors', log('1104:30068'))
      13.times { game.script('combine my fiber', log('1104:30101')) }
      game.script('put fiber on wheel', log('1104:30204'), after: ->(_) { $left_hand = nil })
      game.script('adjust wheel to heavy', log('1104:30206'), log('1104:30207'))
    end

    it 'stops with a message after three unanswered spins instead of spinning forever' do
      expect(Lich::Messaging).to receive(:msg).with('bold', "spin: The wheel did not answer 'spin wheel' 3 times in a row.")

      expect { Spin.new }.to raise_error(SystemExit)
      expect(game.sent.count('spin wheel')).to eq(3)
    end

    it 'starts the count again after a spin the game answers' do
      game.script('spin wheel')
      game.script('spin wheel')
      game.script('spin wheel', log('1104:30215'), log('1104:30216'))

      expect { Spin.new }.to raise_error(SystemExit)
      expect(game.sent.count('spin wheel')).to eq(6)
    end

    it 'stops after 100 commands when the spool never comes' do
      endless = ReplayGame.new(send_budget: 200).install(self)
      endless.script('mark my fibers at 10', log('1104:30060'))
      endless.script('cut my fibers with my scissors', log('1104:30068'))
      13.times { endless.script('combine my fiber', log('1104:30101')) }
      endless.script('put fiber on wheel', log('1104:30204'), after: ->(_) { $left_hand = nil })
      endless.script('adjust wheel to heavy', log('1104:30206'), log('1104:30207'))
      endless.fallback('spin wheel', log('1104:30215'), log('1104:30216'))
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: No spool after 100 commands to the wheel.')

      expect { Spin.new }.to raise_error(SystemExit)
      expect(endless.sent.count('spin wheel')).to eq(100)
    end
  end

  describe 'loading the wheel' do
    before do
      game.script('mark my fibers at 10', log('1104:30060'))
      game.script('cut my fibers with my scissors', log('1104:30068'))
      13.times { game.script('combine my fiber', log('1104:30101')) }
    end

    it 'stops without spinning when the fiber does not go on the wheel' do
      game.script('put fiber on wheel', log('1104:30072'))
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: Could not put the fiber on the wheel.')

      expect { Spin.new }.to raise_error(SystemExit)
      expect(game.sent).not_to include('adjust wheel to heavy', 'spin wheel')
    end

    it 'stops without spinning when the wheel cannot be set to the weight' do
      game.script('put fiber on wheel', log('1104:30204'), after: ->(_) { $left_hand = nil })
      game.script('adjust wheel to heavy', log('1104:30072'))
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: Could not set the wheel to heavy.')

      expect { Spin.new }.to raise_error(SystemExit)
      expect(game.sent).not_to include('spin wheel')
    end
  end

  describe 'spinning yarn' do
    before do
      $parsed_args = { 'material' => 'wool', 'weight' => 'yarn' }
      allow(DRCT).to receive(:order_item) do
        $left_hand = 'wool fibers'
        'takes some coins from you'
      end
      7.times { game.script('combine my fiber', log('1104:30101')) }
      # The lines are silk's; the game's yarn wording is not in any log.
      game.script('put fiber on wheel', log('1104:30204'), after: ->(_) { $left_hand = nil })
      game.script('adjust wheel to yarn', log('1104:30206'), log('1104:30207'))
      game.script('spin wheel', log('1104:30215'), log('1104:30216'), after: ->(_) { $left_hand = 'wool thread' })
      game.script('spin wheel', log('1104:30215'), log('1104:30216'), after: ->(_) { $left_hand = 'wool yarn' })
      game.script('stow my wool yarn', log('1104:30296'))
    end

    it 'waits for the yarn, not for thread' do
      Spin.new

      expect(game.sent.count('spin wheel')).to eq(2)
      expect(game.sent.last).to eq('stow my wool yarn')
    end
  end

  describe 'before buying anything' do
    it 'shops and spins in force_crafting_town when it is set' do
      $test_settings.force_crafting_town = 'Crossing'
      $test_data.crafting['tailoring']['Crossing'] = { 'stock-room' => 16_667 }
      allow(DRCM).to receive(:town_currency).with('Crossing').and_return('kronars')
      script_silk_spin
      expect(DRCC).to receive(:find_wheel).with('Crossing').and_return(true)

      Spin.new

      expect(DRCT).to have_received(:order_item).with(16_667, 1).exactly(14).times
    end

    it 'stops before touching money when the town has no stock room in the data' do
      $test_settings.hometown = 'Aesry'
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: No outfitting society stock room is known for Aesry.')
      expect(DRCM).not_to receive(:ensure_copper_on_hand)

      expect { Spin.new }.to raise_error(SystemExit)
      expect(DRCT).not_to have_received(:order_item)
    end

    it 'stops with a message, not a crash, when no hometown is set' do
      $test_settings.hometown = nil
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: No outfitting society stock room is known for your crafting town.')

      expect { Spin.new }.to raise_error(SystemExit)
    end

    it 'stops with the choices when the fiber is not one the shop sells' do
      $parsed_args = { 'material' => 'hemp' }
      expect(Lich::Messaging).to receive(:msg).with('bold', "spin: Unknown fiber 'hemp'. Choose one of: silk, cotton, linen, wool, burlap.")

      expect { Spin.new }.to raise_error(SystemExit)
    end

    it 'gets the scissors for the silk cut before spending money' do
      script_silk_spin
      expect(DRCC).to receive(:get_crafting_item).with('scissors', 'duffel bag', [], $test_settings.outfitting_belt, true).ordered.and_return(true)
      expect(DRCM).to receive(:ensure_copper_on_hand).ordered.and_return(true)

      Spin.new
    end
  end

  describe 'paying for the fiber' do
    it 'converts the kronar price to the town currency: 14 silk bundles are 1890 Dokoras in Shard (1104:30056)' do
      script_silk_spin
      expect(DRCM).to receive(:convert_currency).with(187, 'kronars', 'dokoras', 0).and_return(135)
      expect(DRCM).to receive(:ensure_copper_on_hand).with(1890, $test_settings, 'Shard').and_return(true)

      Spin.new
    end

    context 'with lich-5 v5.23.0 exchange rates (common-money.rb convert_currency, fee 0)' do
      before do
        rates = { 'dokoras' => 0.7216, 'lirums' => 0.8, 'kronars' => 1 }
        allow(DRCM).to receive(:convert_currency) { |amount, _from, to, fee| ((amount * rates.fetch(to)).ceil * (1 - fee)).floor }
        allow(DRCM).to receive(:ensure_copper_on_hand).and_return(false)
      end

      {
        ['Riverhaven', 'lirums', 'silk'] => 14 * 150,
        ['Shard', 'dokoras', 'linen']    => 8 * 121,
        ['Shard', 'dokoras', 'silk']     => 14 * 135
      }.each do |(town, currency, fiber), copper|
        it "asks for each #{fiber} bundle's rounded #{currency} price times the bundles: #{copper} in #{town}" do
          $test_settings.hometown = town
          $test_data.crafting['tailoring'][town] = { 'stock-room' => 1 }
          $parsed_args = { 'material' => fiber }
          allow(DRCM).to receive(:town_currency).with(town).and_return(currency)

          expect { Spin.new }.to raise_error(SystemExit)
          expect(DRCM).to have_received(:ensure_copper_on_hand).with(copper, $test_settings, town)
        end
      end
    end

    it 'stops before ordering when the money cannot be got' do
      allow(DRCM).to receive(:ensure_copper_on_hand).and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: Could not get 1890 copper dokoras for the fiber.')
      expect(DRCC).to receive(:stow_crafting_item).with('scissors', 'duffel bag', $test_settings.outfitting_belt)

      expect { Spin.new }.to raise_error(SystemExit)
      expect(DRCT).not_to have_received(:order_item)
    end

    it 'stops before banking when the scissors for the silk cut cannot be got' do
      allow(DRCC).to receive(:get_crafting_item).and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: Could not get your scissors for the silk cut.')
      expect(DRCM).not_to receive(:ensure_copper_on_hand)

      expect { Spin.new }.to raise_error(SystemExit)
      expect(DRCT).not_to have_received(:order_item)
    end

    it 'puts the scissors back when the first bundle is not sold' do
      allow(DRCT).to receive(:order_item).and_return(nil)
      expect(DRCC).to receive(:stow_crafting_item).with('scissors', 'duffel bag', $test_settings.outfitting_belt)

      expect { Spin.new }.to raise_error(SystemExit)
    end

    it 'does not try to put the scissors back again once the cut has put them away' do
      sold = 0
      allow(DRCT).to receive(:order_item) { (sold += 1) < 2 ? 'takes some coins from you' : nil }
      game.script('mark my fibers at 10', log('1104:30060'))
      game.script('cut my fibers with my scissors', log('1104:30068'))
      allow(DRCC).to receive(:stow_crafting_item).and_return(true)

      expect { Spin.new }.to raise_error(SystemExit)
      expect(DRCC).to have_received(:stow_crafting_item).once
    end
  end

  describe 'buying the bundles' do
    it 'stops at the first bundle the shop does not sell (DRCT.order_item returns nil when the coins run short)' do
      sold = 0
      allow(DRCT).to receive(:order_item) { (sold += 1) < 3 ? 'takes some coins from you' : nil }
      game.script('mark my fibers at 10', log('1104:30060'))
      game.script('cut my fibers with my scissors', log('1104:30068'))
      game.script('combine my fiber', log('1104:30101'))
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: The shop did not sell bundle 3 of 14; any bought so far are in your hands.')

      expect { Spin.new }.to raise_error(SystemExit)
      expect(DRCT).to have_received(:order_item).exactly(3).times
      expect(game.sent).not_to include('put fiber on wheel')
    end

    it 'stops when the order goes unanswered (DRCT.order_item returns the empty bput timeout)' do
      allow(DRCT).to receive(:order_item).and_return('')
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: The shop did not sell bundle 1 of 14; any bought so far are in your hands.')

      expect { Spin.new }.to raise_error(SystemExit)
      expect(DRCT).to have_received(:order_item).once
      expect(game.sent).to be_empty
    end

    it 'stops at an unanswered later order of an uncut fiber, before combining or spinning' do
      $parsed_args = { 'material' => 'cotton' }
      replies = ['takes some coins from you', '']
      allow(DRCT).to receive(:order_item) { replies.shift }
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: The shop did not sell bundle 2 of 8; any bought so far are in your hands.')

      expect { Spin.new }.to raise_error(SystemExit)
      expect(DRCT).to have_received(:order_item).twice
      expect(game.sent).not_to include('combine my fiber', 'put fiber on wheel')
    end

    it 'stops when the fiber cannot be marked for cutting' do
      game.script('mark my fibers at 10', log('1104:30072'))
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: Could not mark the fiber for cutting; it is in your hands.')
      expect(DRCC).to receive(:stow_crafting_item).with('scissors', 'duffel bag', $test_settings.outfitting_belt)

      expect { Spin.new }.to raise_error(SystemExit)
      expect(game.sent).not_to include('cut my fibers with my scissors')
    end

    it 'stops when the cut does not happen' do
      game.script('mark my fibers at 10', log('1104:30060'))
      game.script('cut my fibers with my scissors')
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: Could not cut the fiber; it is in your hands.')
      expect(DRCC).to receive(:stow_crafting_item).with('scissors', 'duffel bag', $test_settings.outfitting_belt)

      expect { Spin.new }.to raise_error(SystemExit)
      expect(DRCT).to have_received(:order_item).once
    end

    it 'stops when two bundles will not combine, instead of buying more into full hands' do
      game.script('mark my fibers at 10', log('1104:30060'))
      game.script('cut my fibers with my scissors', log('1104:30068'))
      game.script('combine my fiber', log('1104:30072'))
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: Could not combine the fiber bundles; they are in your hands.')

      expect { Spin.new }.to raise_error(SystemExit)
      expect(DRCT).to have_received(:order_item).twice
    end

    it 'combines only from the second bundle on when there is no cut' do
      $parsed_args = { 'material' => 'cotton' }
      7.times { game.script('combine my fiber', log('1104:30101')) }
      allow(DRCC).to receive(:find_wheel).and_return(false)
      expect(DRCC).not_to receive(:get_crafting_item)

      expect { Spin.new }.to raise_error(SystemExit)
      expect(game.sent.count('combine my fiber')).to eq(7)
    end
  end

  describe 'finding a wheel' do
    it 'stops with a message when no wheel can be reached, instead of walking out the door every 30 seconds' do
      game.script('mark my fibers at 10', log('1104:30060'))
      game.script('cut my fibers with my scissors', log('1104:30068'))
      13.times { game.script('combine my fiber', log('1104:30101')) }
      allow(DRCC).to receive(:find_wheel).and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: Could not reach a spinning wheel in Shard.')

      expect { Spin.new }.to raise_error(SystemExit)
      expect(game.sent).not_to include('put fiber on wheel')
    end
  end
end
