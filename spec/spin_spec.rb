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
    $hand_ids['silk thread'] = '1958040'
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
         'spin wheel', 'push wheel', 'spin wheel']
      )
    end

    it 'stops spinning once the spool is in hand' do
      Spin.new

      expect(game.sent.last).to eq('spin wheel')
      expect(game.sent.count('spin wheel')).to eq(5)
    end

    it 'keeps spinning when a background script puts something else in a hand' do
      # e.g. almanac getting its book mid-spin, as it did mid-weave (1104:30663)
      game.override('clean wheel', log('1104:30226'), log('1104:30227'), after: ->(_) { $right_hand = 'encyclopedic almanac' })

      expect(DRCI).to receive(:put_away_item?).with('#1958040', 'duffel bag').and_return(true)

      Spin.new

      expect(game.sent.count('spin wheel')).to eq(5)
    end

    it 'keeps spinning when the thing put in a hand only ends in "thread" (a quiver wrapped with silver thread)' do
      # Made-up hand text: this quiver (noun quiver) is real, but the noun
      # corpus has it only as room and container text. A DR hand shows a
      # short 'adj noun' form, so no log shows a hand reading like this. It
      # parts the noun from the text's last word, which the check once read.
      quiver = 'soft white thigh quiver of snow leopard fur artfully wrapped with silver thread'
      $hand_nouns[quiver] = 'quiver'
      $hand_ids[quiver] = '7001'
      game.override('clean wheel', log('1104:30226'), log('1104:30227'), after: ->(_) { $right_hand = quiver })

      expect(DRCI).to receive(:put_away_item?).with('#1958040', 'duffel bag').and_return(true)

      Spin.new

      expect(game.sent.count('spin wheel')).to eq(5)
      expect(UserVars.spun_spools.map { |spool| spool['id'] }).to eq(['1958040'])
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
      expect(DRCI).to receive(:put_away_item?).with('#1958040', 'duffel bag').and_return(true)

      Spin.new

      expect(game.sent.count('spin wheel')).to eq(5)
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
      $hand_ids['wool thread'] = '111'
      $hand_ids['wool yarn'] = '222'
    end

    it 'waits for the yarn, not for thread' do
      expect(DRCI).to receive(:put_away_item?).with('#222', 'duffel bag').and_return(true)

      Spin.new

      expect(game.sent.count('spin wheel')).to eq(2)
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
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: Could not get your scissors to cut the silk fiber.')
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

  describe 'storing the spool' do
    before { script_silk_spin }

    it 'puts the spool in the crafting container by its id, not in the stow container by name' do
      expect(DRCI).to receive(:put_away_item?).with('#1958040', 'duffel bag').and_return(true)

      Spin.new

      expect(game.sent.grep(/\Astow\b/)).to be_empty
    end

    it 'records the spool so weave-cloth can load exactly it' do
      Spin.new

      expect(UserVars.spun_spools).to eq([{ 'id' => '1958040', 'fiber' => 'silk', 'weight' => 'heavy' }])
    end

    it 'adds each new spool after the ones already recorded' do
      UserVars.spun_spools = [{ 'id' => '1950000', 'fiber' => 'silk', 'weight' => 'heavy' }]

      Spin.new

      expect(UserVars.spun_spools.map { |spool| spool['id'] }).to eq(%w[1950000 1958040])
    end

    it 'does not record the same spool twice' do
      UserVars.spun_spools = [{ 'id' => '1958040', 'fiber' => 'silk', 'weight' => 'heavy' }]

      Spin.new

      expect(UserVars.spun_spools.size).to eq(1)
    end

    it 'forgets the oldest spools past 20' do
      UserVars.spun_spools = (1..20).map { |n| { 'id' => n.to_s, 'fiber' => 'silk', 'weight' => 'heavy' } }

      Spin.new

      expect(UserVars.spun_spools.size).to eq(20)
      expect(UserVars.spun_spools.first['id']).to eq('2')
      expect(UserVars.spun_spools.last['id']).to eq('1958040')
    end

    it 'drops recorded entries that have no id, so they cannot crowd out real spools' do
      UserVars.spun_spools = [{ 'fiber' => 'silk' }, 'junk', { 'id' => '1950000', 'fiber' => 'silk', 'weight' => 'heavy' }]

      Spin.new

      expect(UserVars.spun_spools.map { |spool| spool['id'] }).to eq(%w[1950000 1958040])
    end

    it 'starts a fresh record when the stored one is not a list' do
      UserVars.spun_spools = { 'id' => 'junk' }

      Spin.new

      expect(UserVars.spun_spools).to eq([{ 'id' => '1958040', 'fiber' => 'silk', 'weight' => 'heavy' }])
    end

    it 'keeps the spool recorded and says so when it will not go into the container' do
      allow(DRCI).to receive(:put_away_item?).and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: Could not put the silk thread (#1958040) in your duffel bag; it is in your hand.')

      expect { Spin.new }.to raise_error(SystemExit)
      expect(UserVars.spun_spools.map { |spool| spool['id'] }).to eq(['1958040'])
    end

    it 'puts a spool with no id away by name and does not record it' do
      $hand_ids.clear
      expect(DRCI).to receive(:put_away_item?).with('silk thread', 'duffel bag').and_return(true)

      Spin.new

      expect(UserVars.spun_spools).to be_nil
    end

    it 'records the weight the spool was spun at' do
      $parsed_args = { 'material' => 'silk', 'weight' => 'thin' }
      game.alias_command('adjust wheel to thin', as: 'adjust wheel to heavy')

      Spin.new

      expect(UserVars.spun_spools.last['weight']).to eq('thin')
    end
  end

  describe 'when the crafting container refuses the scissors' do
    before { script_silk_spin }

    # DRCC.stow_crafting_item answers "You can't put that there" by putting
    # the scissors in your "other" bag and returning false; the spool still
    # belongs in the crafting container.
    it 'still puts the spool in the crafting container' do
      allow(DRCC).to receive(:stow_crafting_item).with('scissors', 'duffel bag', anything).and_return(false)
      expect(DRCI).to receive(:put_away_item?).with('#1958040', 'duffel bag').and_return(true)

      Spin.new
    end
  end

  describe 'its fiber table' do
    it 'offers exactly the fibers it knows how to buy' do
      material = Spin::ARG_DEFINITIONS.first.find { |arg| arg[:name] == 'material' }

      expect(material[:options]).to eq(Spin::FIBERS.keys)
    end

    it 'cuts only fiber whose bundles overshoot the wheel (silk: 10 + 13 x 30 = 400 yards)' do
      expect(Spin::FIBERS.select { |_, fiber| fiber[:cut_first_to] }.keys).to eq(['silk'])
      expect(Spin::FIBERS['silk'][:cut_first_to] + ((Spin::FIBERS['silk'][:bundles] - 1) * 30)).to eq(400)
    end
  end

  describe 'naming the crafting container' do
    before { script_silk_spin }

    it 'puts the spool in the worn crafting container by its id, so a duffel bag being sewn cannot catch it' do
      $worn_items = [OpenStruct.new(name: 'duffel bag', noun: 'bag', id: '1222175'),
                     OpenStruct.new(name: "scuffed traveler's pack", noun: 'pack', id: '1222003')]
      expect(DRCI).to receive(:put_away_item?).with('#1958040', '#1222175').and_return(true)

      Spin.new
    end

    it 'names the container when it is not worn' do
      $worn_items = [OpenStruct.new(name: "scuffed traveler's pack", noun: 'pack', id: '1222003')]
      expect(DRCI).to receive(:put_away_item?).with('#1958040', 'duffel bag').and_return(true)

      Spin.new
    end

    it 'names the container when GameObj has not streamed the worn items yet (GameObj.inv is nil)' do
      $worn_items = nil
      expect(DRCI).to receive(:put_away_item?).with('#1958040', 'duffel bag').and_return(true)

      Spin.new
    end

    it 'does not take a worn item whose name only contains the container name' do
      $worn_items = [OpenStruct.new(name: 'duffel bag strap', noun: 'strap', id: '1')]
      expect(DRCI).to receive(:put_away_item?).with('#1958040', 'duffel bag').and_return(true)

      Spin.new
    end

    # A real worn duffel bag (noun bag) whose name goes on past the setting
    # (noun corpus); the old check wanted the name to end in 'duffel bag'.
    let(:camlet_bag) { OpenStruct.new(name: 'deep black camlet duffel bag set with a crimson windsteel medallion', noun: 'bag', id: '1222175') }

    it 'puts the spool by id in the worn duffel bag whose name goes on past the setting' do
      $worn_items = [camlet_bag, OpenStruct.new(name: "scuffed traveler's pack", noun: 'pack', id: '1222003')]
      expect(DRCI).to receive(:put_away_item?).with('#1958040', '#1222175').and_return(true)

      Spin.new
    end

    it 'still finds that duffel bag by id when a duffel bag strap is worn too' do
      $worn_items = [OpenStruct.new(name: 'duffel bag strap', noun: 'strap', id: '1'), camlet_bag]
      expect(DRCI).to receive(:put_away_item?).with('#1958040', '#1222175').and_return(true)

      Spin.new
    end

    it 'names the container, for the game to choose, when two worn duffel bags fit the setting' do
      $worn_items = [OpenStruct.new(name: 'duffel bag', noun: 'bag', id: '750671'), camlet_bag]
      expect(DRCI).to receive(:put_away_item?).with('#1958040', 'duffel bag').and_return(true)

      Spin.new
    end

    it 'does not take a worn item whose noun is a setting word but whose name splits the setting' do
      $worn_items = [OpenStruct.new(name: 'duffel strap bag', noun: 'bag', id: '1')]
      expect(DRCI).to receive(:put_away_item?).with('#1958040', 'duffel bag').and_return(true)

      Spin.new
    end

    # Real worn items (noun corpus) and a real setting: Moza's sample profile
    # has crafting_container: shadows (profiles/Samples/Thief/Moza-setup.yaml).
    # The web's name ends in 'shadows' but its noun is web; the old check took
    # it for the container.
    it 'puts the spool in the worn shadows, not the web of shadows, when the setting is "shadows"' do
      $test_settings.crafting_container = 'shadows'
      $worn_items = [OpenStruct.new(name: 'writhing web of shadows', noun: 'web', id: '12'),
                     OpenStruct.new(name: 'some dark encompassing shadows of twilight dreamweave', noun: 'shadows', id: '11')]
      expect(DRCI).to receive(:put_away_item?).with('#1958040', '#11').and_return(true)

      Spin.new
    end

    # The noun may be any word of the setting, not only its last: a setting
    # that gives the camlet bag's full name still finds it by its noun, bag.
    it "finds the worn duffel bag by id when the setting is the bag's full name" do
      $test_settings.crafting_container = camlet_bag.name
      $worn_items = [camlet_bag, OpenStruct.new(name: "scuffed traveler's pack", noun: 'pack', id: '1222003')]
      expect(DRCI).to receive(:put_away_item?).with('#1958040', '#1222175').and_return(true)

      Spin.new
    end

    it 'reads a setting written in the adj.noun form, "duffel.bag"' do
      $test_settings.crafting_container = 'duffel.bag'
      $worn_items = [camlet_bag]
      expect(DRCI).to receive(:put_away_item?).with('#1958040', '#1222175').and_return(true)

      Spin.new
    end

    it 'reads a setting written in capitals, "Duffel Bag"' do
      $test_settings.crafting_container = 'Duffel Bag'
      $worn_items = [camlet_bag]
      expect(DRCI).to receive(:put_away_item?).with('#1958040', '#1222175').and_return(true)

      Spin.new
    end

    it 'does not count a worn item GameObj gives no id, so the one with an id is still named by it' do
      $worn_items = [OpenStruct.new(name: 'duffel bag', noun: 'bag', id: nil), camlet_bag]
      expect(DRCI).to receive(:put_away_item?).with('#1958040', '#1222175').and_return(true)

      Spin.new
    end

    it 'does not take a worn item where the setting is only part of a longer word' do
      # Made up: no logged item has such a name; each holds 'duffel bag' only
      # inside a longer word, before or after.
      $worn_items = [OpenStruct.new(name: 'duffel baggage bag', noun: 'bag', id: '2'),
                     OpenStruct.new(name: 'superduffel bag', noun: 'bag', id: '3'),
                     camlet_bag]
      expect(DRCI).to receive(:put_away_item?).with('#1958040', '#1222175').and_return(true)

      Spin.new
    end

    it 'gives no container when there is no crafting_container setting' do
      spin = Spin.allocate
      spin.instance_variable_set(:@bag, nil)

      expect(spin.send(:crafting_container_ref)).to be_nil
    end
  end

  # GameObj gives each hand the game's noun (XML noun=); the hand's text is
  # only a short form of the name, so the helpers go by the noun.
  describe 'telling what a hand holds' do
    let(:spin) { Spin.allocate.tap { |instance| instance.instance_variable_set(:@product, 'thread') } }

    it 'takes a hand whose noun is thread for the spool even when its text ends in another word' do
      # No log shows such a hand; the text is made up to separate noun from tail.
      $left_hand = 'silk thread with a frayed end'
      $hand_nouns[$left_hand] = 'thread'

      expect(spin.send(:spool_in_hand)&.name).to eq('silk thread with a frayed end')
    end

    it 'does not take a quiver wrapped with silver thread for the spool' do
      # Made-up hand text, as above: no logged hand shows the full name.
      $right_hand = 'soft white thigh quiver of snow leopard fur artfully wrapped with silver thread'
      $hand_nouns[$right_hand] = 'quiver'

      expect(spin.send(:spool_in_hand)).to be_nil
    end

    it 'takes yarn, not thread, when spinning yarn' do
      spin.instance_variable_set(:@product, 'yarn')
      $left_hand = 'wool thread'
      $right_hand = 'wool yarn'

      expect(spin.send(:spool_in_hand)&.name).to eq('wool yarn')
    end

    it 'finds and counts fiber in hand by its noun, whatever its text ends in' do
      # Made up, as above: no logged fiber hand ends in anything but 'fibers'.
      $left_hand = 'silk fibers in a loose bundle'
      $hand_nouns[$left_hand] = 'fibers'
      $right_hand = 'silk fibers'

      expect(spin.send(:held_fiber)&.name).to eq('silk fibers in a loose bundle')
      expect(spin.send(:hands_holding_fiber)).to eq(2)
    end

    it 'does not count a hand whose text ends in "fibers" when its noun is something else' do
      # Made up: no logged item has such a name.
      $left_hand = 'pouch of loose fibers'
      $hand_nouns[$left_hand] = 'pouch'

      expect(spin.send(:held_fiber)).to be_nil
      expect(spin.send(:hands_holding_fiber)).to eq(0)
    end
  end

  # Every wheel reply in Mahtra's seven silk spins on 2026-11-04 (1104 log).
  describe 'the wheel replies seen in game' do
    {
      '1104:30219' => 'clean wheel', # "...dull shade from grime..."
      '1104:30231' => 'turn wheel',  # "A counter-twist in the fiber strand..."
      '1104:31649' => 'turn wheel',  # "Individual strands of the fiber begin twisting apart unevenly."
      '1104:30274' => 'push wheel',  # "...begins to slide down the wheel..."
      '1104:30507' => 'push wheel'   # "One half of the fiber bundle begins to slip from the wheel and bunch together."
    }.each do |cite, fix|
      it "answers #{cite} with #{fix}" do
        line = log(cite).text
        expect(Spin::WHEEL_FIXES.find { |problem, _| problem.match?(line) }&.last).to eq(fix)
      end
    end

    %w[1104:30215 1104:30230 1104:30254 1104:30484 1104:31648].each do |cite|
      it "takes the ordinary spin line #{cite} for no problem" do
        expect(Spin::WHEEL_FIXES.keys.none? { |problem| problem.match?(log(cite).text) }).to be(true)
      end
    end

    it 'fixes a problem that arrives in its own reply, then spins on (1104:30505-30508)' do
      game.script('mark my fibers at 10', log('1104:30060'))
      game.script('cut my fibers with my scissors', log('1104:30068'))
      13.times { game.script('combine my fiber', log('1104:30101')) }
      game.script('put fiber on wheel', log('1104:30204'), after: ->(_) { $left_hand = nil })
      game.script('adjust wheel to heavy', log('1104:30206'), log('1104:30207'))
      game.script('spin wheel', log('1104:30506'), log('1104:30507'), log('1104:30508'))
      game.script('push wheel', log('1104:30281'), log('1104:30282'))
      game.script('spin wheel', log('1104:31648'), log('1104:31649'), log('1104:31650'))
      game.script('turn wheel', log('1104:30244'), log('1104:30245'))
      game.script('spin wheel', log('1104:30284'), log('1104:30285'), log('1104:30286'),
                  after: ->(_) { $left_hand = 'silk thread' })
      $hand_ids['silk thread'] = '1958040'

      Spin.new

      expect(game.sent.drop_while { |command| command != 'spin wheel' }).to eq(['spin wheel', 'push wheel', 'spin wheel', 'turn wheel', 'spin wheel'])
    end
  end

  # Each silk spin cuts a 30-yard bundle down to 10 and the game puts the
  # other 20 in a container; those leftovers are used before buying more.
  describe 'reusing leftover fiber' do
    let(:pack) { OpenStruct.new(id: '2135058', noun: 'pack', name: "scuffed traveler's pack") }
    let(:twenty) { log('2052:11197') } # "You count out 20 yards of material there."
    let(:thirty) { ReplayGame.code('You count out 30 yards of material there.', from: 'the 2052:11197 wording, for a fresh 30-yard silk bundle (1104:30058)') }

    # Leftover bundles of silk fiber in the pack, as GameObj streams them.
    def leftovers(*ids)
      $containers[pack.id] = ids.map { |id| OpenStruct.new(id: id, noun: 'fibers', name: 'silk fibers') }
      ids.each { |id| game.script("count ##{id}", twenty) }
    end

    before do
      $worn_items = [pack]
      sold = 0
      allow(DRCT).to receive(:order_item) do
        sold += 1
        $left_hand = 'silk fibers'
        $hand_ids['silk fibers'] = "300#{sold}"
        'takes some coins from you'
      end
      # A leftover comes out into whichever hand is free.
      allow(DRCI).to receive(:get_item?) do
        $left_hand ? $right_hand = 'silk fibers' : $left_hand = 'silk fibers'
        true
      end
      game.fallback('combine my fiber', log('1104:30101'), after: ->(_) { $right_hand = nil })
      game.script('put fiber on wheel', log('1104:30204'), after: ->(_) { $left_hand = nil })
      game.script('adjust wheel to heavy', log('1104:30206'), log('1104:30207'))
      game.script('spin wheel', log('1104:30284'), log('1104:30285'), log('1104:30286'), after: lambda { |_|
        $left_hand = 'silk thread'
        $hand_ids['silk thread'] = '1958040'
      })
    end

    it 'uses 160 yards of leftovers and buys only 8 bundles to fill the wheel' do
      leftovers(*%w[2135081 2135082 2135083 2135084 2135085 2135086 2135089 2135090])
      game.script('count #3001', thirty)

      Spin.new

      expect(DRCT).to have_received(:order_item).exactly(8).times
      expect(DRCI).to have_received(:get_item?).exactly(8).times
      expect(game.sent.grep(/\A(mark|cut) /)).to be_empty # 160 + 8 x 30 = 400 exactly
      expect(game.sent.count('combine my fiber')).to eq(15)
    end

    it 'cuts the first bought bundle by id so leftovers and bundles make exactly 400 yards' do
      leftovers('2135081')
      game.script('count #3001', thirty)
      game.script('mark #3001 at 20', ReplayGame.code('You count out 20 yards of the fibers and mark it for cutting.', from: 'the 2052:11228 wording, marked at 20'))
      game.script('cut #3001 with my scissors', log('2052:11233'))

      Spin.new

      expect(DRCT).to have_received(:order_item).exactly(13).times # 20 + 20 + 12 x 30
      expect(game.sent).to include('mark #3001 at 20', 'cut #3001 with my scissors')
    end

    it 'gets the scissors out before any money is spent, and puts them back before handling the leftovers' do
      leftovers('2135081')
      game.script('count #3001', thirty)
      game.script('mark #3001 at 20', log('2052:11228'))
      game.script('cut #3001 with my scissors', log('2052:11233'))
      expect(DRCC).to receive(:get_crafting_item).with('scissors', 'duffel bag', [], anything, true).ordered.and_return(true)
      expect(DRCM).to receive(:ensure_copper_on_hand).ordered.and_return(true)
      expect(DRCC).to receive(:stow_crafting_item).with('scissors', 'duffel bag', anything).ordered.and_return(true)
      expect(DRCI).to receive(:get_item?).with('#2135081').ordered.and_return(true)

      Spin.new
    end

    it 'buys nothing when the leftovers already fill the wheel, and takes no more than fits' do
      ids = (1..21).map { |n| "21350#{format('%02d', n)}" }
      leftovers(*ids)
      expect(DRCC).not_to receive(:get_crafting_item)

      expect(DRCM).not_to receive(:ensure_copper_on_hand)

      Spin.new

      expect(DRCT).not_to have_received(:order_item)
      expect(DRCI).to have_received(:get_item?).exactly(20).times
      expect(game.sent.count('combine my fiber')).to eq(19)
      expect(game.sent.grep(/\Acount #/).size).to eq(20) # stops counting once the wheel is full
    end

    it 'leaves out a leftover whose count goes unanswered' do
      $containers[pack.id] = [OpenStruct.new(id: '2135081', noun: 'fibers', name: 'silk fibers')]
      game.script('count #2135081')
      game.script('mark my fibers at 10', log('1104:30060'))
      game.script('cut my fibers with my scissors', log('1104:30068'))

      Spin.new

      expect(DRCT).to have_received(:order_item).exactly(14).times
      expect(DRCI).not_to have_received(:get_item?)
    end

    it 'uses a leftover bundle whose name goes on past "fibers"' do
      # Made up: every logged fibers name ends in 'fibers' (noun corpus). The
      # bundle is known by its noun, fibers, with 'silk' right before it.
      $containers[pack.id] = [OpenStruct.new(id: '2135081', noun: 'fibers', name: 'silk fibers tied with a strip of twine')]
      game.script('count #2135081', twenty)
      game.script('count #3001', thirty)
      game.script('mark #3001 at 20', log('2052:11228'))
      game.script('cut #3001 with my scissors', log('2052:11233'))

      Spin.new

      expect(DRCI).to have_received(:get_item?).with('#2135081')
      expect(DRCT).to have_received(:order_item).exactly(13).times
    end

    it 'ignores fiber of another material' do
      $containers[pack.id] = [OpenStruct.new(id: '9', noun: 'fibers', name: 'wool fibers')]
      game.script('mark my fibers at 10', log('1104:30060'))
      game.script('cut my fibers with my scissors', log('1104:30068'))

      Spin.new

      expect(game.sent).not_to include('count #9')
    end

    it 'stops, the fiber in hand, when the bought bundle will not count' do
      leftovers('2135081')
      game.script('count #3001')
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: Could not count the bundle bought; it is in your hands.')
      expect(DRCC).to receive(:stow_crafting_item).with('scissors', 'duffel bag', anything)

      expect { Spin.new }.to raise_error(SystemExit)
    end

    it 'finds no leftovers when GameObj has not streamed the worn items (GameObj.inv is nil), and buys a full wheel' do
      $worn_items = nil
      game.script('mark my fibers at 10', log('1104:30060'))
      game.script('cut my fibers with my scissors', log('1104:30068'))

      Spin.new

      expect(DRCT).to have_received(:order_item).exactly(14).times
    end
  end

  # Review of #7958, and the independent review of the leftover layer.
  describe 'leftover fiber: scissors, coins and the rest' do
    let(:pack) { OpenStruct.new(id: '2135058', noun: 'pack', name: "scuffed traveler's pack") }
    let(:twenty) { log('2052:11197') }
    let(:fifty) { ReplayGame.code('You count out 50 yards of material there.', from: 'the 2052:11197 wording, for a 50-yard bundle') }

    before do
      $worn_items = [pack]
      sold = 0
      allow(DRCT).to receive(:order_item) do
        sold += 1
        $left_hand = "#{$parsed_args['material']} fibers"
        $hand_ids[$left_hand] = "300#{sold}"
        'takes some coins from you'
      end
      allow(DRCI).to receive(:get_item?) do
        $right_hand = "#{$parsed_args['material']} fibers"
        true
      end
      game.fallback('combine my fiber', log('1104:30101'), after: ->(_) { $right_hand = nil })
      game.script('put fiber on wheel', log('1104:30204'), after: ->(_) { $left_hand = nil })
      game.fallback('adjust wheel to heavy', log('1104:30206'), log('1104:30207'))
      game.script('spin wheel', log('1104:30284'), log('1104:30285'), log('1104:30286'), after: lambda { |_|
        $left_hand = "#{$parsed_args['material']} thread"
        $hand_ids[$left_hand] = '1958040'
      })
    end

    it 'spins a cotton wheel without scissors, setting the leftovers aside and saying so' do
      $parsed_args = { 'material' => 'cotton' }
      $containers[pack.id] = [OpenStruct.new(id: '9', noun: 'fibers', name: 'cotton fibers')]
      game.script('count #9', twenty)
      allow(DRCC).to receive(:get_crafting_item).and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: Could not get your scissors, so the leftover cotton fibers wait for another spin.')
      allow(Lich::Messaging).to receive(:msg).with('plain', anything)

      Spin.new

      expect(DRCT).to have_received(:order_item).exactly(8).times
      expect(DRCI).not_to have_received(:get_item?)
    end

    it 'still stops a silk spin without scissors, naming the fiber' do
      $containers[pack.id] = [OpenStruct.new(id: '9', noun: 'fibers', name: 'silk fibers')]
      game.script('count #9', twenty)
      allow(DRCC).to receive(:get_crafting_item).and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: Could not get your scissors to cut the silk fiber.')

      expect { Spin.new }.to raise_error(SystemExit)
      expect(DRCT).not_to have_received(:order_item)
    end

    it 'asks for the coins of the extra bundles when the shop sells smaller bundles than FIBERS expects' do
      $parsed_args = { 'material' => 'silk' }
      $containers[pack.id] = [OpenStruct.new(id: '9', noun: 'fibers', name: 'silk fibers')]
      game.script('count #9', twenty)
      game.script('count #3001', ReplayGame.code('You count out 20 yards of material there.', from: 'the 2052:11197 wording, for a 20-yard bundle'))
      allow(DRCM).to receive(:convert_currency).and_return(135)
      expect(DRCM).to receive(:ensure_copper_on_hand).with(14 * 135, anything, 'Shard').ordered.and_return(true)
      expect(DRCM).to receive(:ensure_copper_on_hand).with(18 * 135, anything, 'Shard').ordered.and_return(true)

      Spin.new

      expect(DRCT).to have_received(:order_item).exactly(19).times # 20 + 19 x 20 = 400
    end

    it 'finds leftovers inside a container inside a worn one, after asking the feed to fill GameObj' do
      $parsed_args = { 'material' => 'silk' }
      pouch = OpenStruct.new(id: '7', noun: 'pouch', name: 'cloth pouch')
      $containers[pack.id] = [pouch]
      $containers[pouch.id] = [OpenStruct.new(id: '9', noun: 'fibers', name: 'silk fibers')]
      game.script('count #9', twenty)
      game.script('count #3001', ReplayGame.code('You count out 30 yards of material there.', from: 'the 2052:11197 wording, for a 30-yard bundle'))
      game.script('mark #3001 at 20', ReplayGame.code('You count out 20 yards of the fibers and mark it for cutting.', from: 'the 2052:11228 wording, marked at 20'))
      game.script('cut #3001 with my scissors', log('2052:11233'))
      expect(Lich::Common::Inventory).to receive(:refresh).at_least(:once)

      Spin.new

      expect(DRCI).to have_received(:get_item?).with('#9')
    end

    it 'stops with a message when a leftover cannot be got' do
      $parsed_args = { 'material' => 'silk' }
      $containers[pack.id] = [OpenStruct.new(id: '9', noun: 'fibers', name: 'silk fibers')]
      game.script('count #9', twenty)
      game.script('count #3001', ReplayGame.code('You count out 30 yards of material there.', from: 'the 2052:11197 wording, for a 30-yard bundle'))
      game.script('mark #3001 at 20', ReplayGame.code('You count out 20 yards of the fibers and mark it for cutting.', from: 'the 2052:11228 wording, marked at 20'))
      game.script('cut #3001 with my scissors', log('2052:11233'))
      allow(DRCI).to receive(:get_item?).and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'spin: Could not get your leftover silk fibers #9.')

      expect { Spin.new }.to raise_error(SystemExit)
    end

    it 'puts the scissors back after the full-wheel cut' do
      $parsed_args = { 'material' => 'silk' }
      game.script('mark my fibers at 10', log('1104:30060'))
      game.script('cut my fibers with my scissors', log('1104:30068'))
      expect(DRCC).to receive(:stow_crafting_item).with('scissors', 'duffel bag', anything).once.and_return(true)

      Spin.new
    end
  end

  # spin.lic and weave-cloth.lic each read what is carried and name the
  # crafting container; they are separate files, so this holds the two
  # copies to the same answers.
  describe 'the helpers shared in kind with weave-cloth' do
    before { load_lic_class('weave-cloth.lic', 'WeaveCloth') }

    let(:spin) { Spin.allocate.tap { |instance| instance.instance_variable_set(:@bag, 'duffel bag') } }
    let(:weave) { WeaveCloth.allocate.tap { |instance| instance.instance_variable_set(:@bag, 'duffel bag') } }

    it 'reads the same carried items, nested containers and hands included' do
      bag = OpenStruct.new(id: '1', noun: 'bag', name: 'duffel bag')
      pouch = OpenStruct.new(id: '2', noun: 'pouch', name: 'cloth pouch')
      $worn_items = [bag]
      $containers = { '1' => [pouch, OpenStruct.new(id: '3', noun: 'thread', name: 'some heavy silk thread')], '2' => [OpenStruct.new(id: '4', noun: 'fibers', name: 'some silk fibers')] }
      $left_hand = 'silk cloth'
      $hand_ids['silk cloth'] = '5'

      expect(spin.send(:carried_items).map(&:id).sort).to eq(weave.send(:carried_items).map(&:id).sort)
      expect(spin.send(:carried_items).map(&:id).sort).to eq(%w[1 2 3 4 5])
    end

    it 'names the crafting container the same way: by id when worn, by name otherwise, nil-safe' do
      [[OpenStruct.new(id: '1', noun: 'bag', name: 'duffel bag')], [], nil].each do |worn|
        $worn_items = worn
        expect(spin.send(:crafting_container_ref)).to eq(weave.send(:crafting_container_ref))
      end
    end
  end
end
