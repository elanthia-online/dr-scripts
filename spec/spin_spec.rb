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
end
