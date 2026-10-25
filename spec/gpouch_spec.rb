# frozen_string_literal: true

require_relative 'spec_helper'

load_lic_class('gpouch.lic', 'GivePouches')

RSpec.describe GivePouches do
  let(:accept_reply) { "You accept Ytterby's offer and are now holding a gem pouch." }
  let(:commands) { [] }

  before do
    Flags._reset
    allow(DRCI).to receive(:dispose_trash)
  end

  # Instantiate without running initialize, setting only what hand_over reads.
  def build_giver(sell: nil)
    giver = GivePouches.allocate
    giver.instance_variable_set(:@sell, sell)
    giver.instance_variable_set(:@worn_trashcan, 'bin')
    giver.instance_variable_set(:@worn_trashcan_verb, 'put')
    allow(giver).to receive(:pause)
    giver
  end

  # Answer each command the way lich-5 DRC.bput does: the first pattern that
  # matches the game's line wins, and bput returns the matched text (not the
  # pattern). The give is accepted and tipped as soon as it's offered.
  def model_game(accept: accept_reply)
    replies = {
      'give pouch to Ytterby' => 'You offer your gem pouch to Ytterby, who has 30 seconds to accept the offer.',
      'accept tip'            => 'You accept the tip and slip the coins into your pocket.',
      'accept'                => accept
    }
    allow(DRC).to receive(:bput) do |command, *patterns|
      commands << command
      if command.start_with?('give pouch')
        Flags['give-accepted'] = true
        Flags['pouch-sold'] = true
      end
      line = replies.fetch(command)
      patterns.lazy.map { |pattern| line.match(pattern.is_a?(Regexp) ? pattern : /#{pattern}/i)&.to_a&.first }.find(&:itself).to_s
    end
  end

  describe '#hand_over' do
    it 'throws the pouch away after accepting it back' do
      model_game
      build_giver.hand_over('Ytterby')

      expect(commands).to eq(['give pouch to Ytterby', 'accept tip', 'accept'])
      expect(DRCI).to have_received(:dispose_trash).with('pouch', 'bin', 'put')
    end

    it 'keeps nothing to throw away when there is no offer to accept' do
      model_game(accept: 'You have no offers to accept.')
      build_giver.hand_over('Ytterby')

      expect(commands.last).to eq('accept')
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'neither accepts nor throws away when selling' do
      model_game
      build_giver(sell: 'sell').hand_over('Ytterby')

      expect(commands).to eq(['give pouch to Ytterby', 'accept tip'])
      expect(DRCI).not_to have_received(:dispose_trash)
    end
  end
end
