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

  # A spin that never ends would hang the suite instead of failing it.
  around do |example|
    Timeout.timeout(10) { example.run }
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

    # The attendant hands over each bundle (1104:30058).
    allow(DRCT).to receive(:order_item) { $left_hand = 'silk fibers' }
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
      allow(DRCT).to receive(:order_item) { $left_hand = 'wool fibers' }
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
end
