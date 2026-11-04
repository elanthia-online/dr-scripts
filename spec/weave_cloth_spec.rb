# frozen_string_literal: true

require 'ostruct'
require 'timeout'

require_relative 'spec_helper'

load_lic_class('weave-cloth.lic', 'WeaveCloth')

# Game lines are real, from Mahtra's weaving in Shard on 2026-11-04
# (spec/fixtures/*/log_lines.json, cited "1104:<line>"). ReplayGame answers
# every DRC.bput and fput the script sends from those lines, so these examples
# run the real WeaveCloth code from its constructor, exactly as `;weave-cloth`
# does.
RSpec.describe WeaveCloth do
  def log(cite)
    ReplayGame.log(cite)
  end

  let(:game) { ReplayGame.new.install(self) }

  # A weave that never ends would hang the suite instead of failing it, and an
  # exit nothing expected would end the whole run with status 0 (spec_helper).
  around do |example|
    Timeout.timeout(10) { example.run }
  rescue SystemExit
    raise 'weave-cloth exited where the example expected it to carry on'
  end

  before do
    $test_settings = OpenStruct.new(hometown: 'Shard', crafting_container: 'duffel bag')
  end

  describe 'finding a loom' do
    it 'looks in force_crafting_town when it is set, like spin and sew' do
      $test_settings.force_crafting_town = 'Crossing'
      expect(DRCC).to receive(:find_loom_room).with('Crossing').and_return(false)

      expect { WeaveCloth.new }.to raise_error(SystemExit)
    end

    it 'looks in the hometown otherwise' do
      expect(DRCC).to receive(:find_loom_room).with('Shard').and_return(false)

      expect { WeaveCloth.new }.to raise_error(SystemExit)
    end

    it 'stops with a message, sending nothing, when no loom can be reached' do
      allow(DRCC).to receive(:find_loom_room).and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Could not reach a loom in Shard.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent).to be_empty
    end

    it 'says "your crafting town" when no town is set' do
      $test_settings.hometown = nil
      allow(DRCC).to receive(:find_loom_room).and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Could not reach a loom in your crafting town.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
    end
  end
end
