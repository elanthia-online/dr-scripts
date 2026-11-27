# frozen_string_literal: true

require_relative 'spec_helper'

load_lic_class('raffle.lic', 'Raffle')

# Game lines, verbatim from raffle logs (Andreshlew's Grand Raffle, 2022-2025).
RAFFLE_TICKETS_OUT = 'Attendant Tizzeg places a roll of raffle tickets out on a small counter.'
RAFFLE_PICKS_OPEN = 'Raffle Attendant Tizzeg says, "Raffle picks are now available for the next drawing!"'
RAFFLE_PICKS_CLOSED = 'Raffle Attendant Tizzeg places a roll of raffle tickets in a small counter.'
RAFFLE_TEAR_OFF = 'You tear off a sky blue raffle ticket.'
RAFFLE_DRAWING_OVER = 'Raffle Attendant Tizzeg exclaims, "Congratulations to all our winners!  Please put your winning tickets on the counter to claim your prize.  ' \
                      'The next raffle will begin shortly."'
RAFFLE_LAST_DRAWING_OVER = 'Raffle Attendant Tizzeg exclaims, "Congratulations to all our winners!  Please put your winning tickets on the counter to claim your prize.  ' \
                           'That will be our last raffle for the evening.  Thank you for participating!"'
RAFFLE_CLAIM_WON = 'Raffle Attendant Tizzeg examines your ticket and exclaims, "Congratulations!"  She smiles broadly as she takes the ticket and hands you ' \
                   'a diamond-hide scroll tube lined in bluefire velvet.'
RAFFLE_CLAIM_LOST = 'Raffle Attendant Tizzeg examines your ticket but shakes her head, "I\'m sorry this isn\'t a winning ticket.  Better luck next time!"'

RSpec.describe Raffle do
  let(:raffle) { described_class.new('Mahtra') }
  let(:ticket) { 'sky blue raffle ticket' }

  def hold_ticket(hand: :right, id: '4242')
    $hand_ids = { ticket => id }
    hand == :right ? $right_hand = ticket : $left_hand = ticket
  end

  before do
    allow(DRC).to receive(:message)
    allow(DRC).to receive(:bput)
    allow(DRCI).to receive(:dispose_trash)
  end

  describe 'taking a ticket' do
    it 'tears one off the counter when a new roll goes out' do
      allow(DRC).to receive(:bput).with('get ticket on counter', any_args) do
        hold_ticket
        RAFFLE_TEAR_OFF
      end

      raffle.handle(RAFFLE_TICKETS_OUT)

      expect(DRC).to have_received(:bput).with('get ticket on counter', any_args).once
      expect(DRC).not_to have_received(:message).with(/could not take/)
    end

    it 'takes only one ticket when both announcements of the same roll arrive' do
      raffle.handle(RAFFLE_TICKETS_OUT)
      raffle.handle(RAFFLE_PICKS_OPEN)

      expect(DRC).to have_received(:bput).with('get ticket on counter', any_args).once
    end

    it 'also starts on the picks-open announcement alone' do
      raffle.handle(RAFFLE_PICKS_OPEN)

      expect(DRC).to have_received(:bput).with('get ticket on counter', any_args)
    end

    it 'does not take another while already holding a raffle ticket' do
      hold_ticket(hand: :left)

      raffle.handle(RAFFLE_TICKETS_OUT)

      expect(DRC).not_to have_received(:bput)
      expect(DRC).to have_received(:message).with(/already holding/)
    end

    it 'says so instead of trying when both hands are full' do
      $right_hand = 'steel broadsword'
      $left_hand = 'target shield'

      raffle.handle(RAFFLE_TICKETS_OUT)

      expect(DRC).not_to have_received(:bput)
      expect(DRC).to have_received(:message).with(/both hands are full \(steel broadsword, target shield\)/)
    end

    it 'reports a failed get' do
      allow(DRC).to receive(:bput).with('get ticket on counter', any_args).and_return('What were you referring to?')

      raffle.handle(RAFFLE_TICKETS_OUT)

      expect(DRC).to have_received(:message).with(/could not take a raffle ticket/)
    end

    it 'ignores the picks-closed line, which also mentions the roll and the counter' do
      raffle.handle(RAFFLE_PICKS_CLOSED)

      expect(DRC).not_to have_received(:bput)
    end

    it 'ignores another player quoting the new-roll announcements' do
      raffle.handle(%(Gnara says, "#{RAFFLE_TICKETS_OUT}"))
      raffle.handle(%([General][Gnara] #{RAFFLE_PICKS_OPEN}))

      expect(DRC).not_to have_received(:bput)
    end

    it 'takes a ticket again in the next drawing' do
      raffle.handle(RAFFLE_TICKETS_OUT)
      raffle.handle(RAFFLE_DRAWING_OVER)
      raffle.handle(RAFFLE_TICKETS_OUT)

      expect(DRC).to have_received(:bput).with('get ticket on counter', any_args).twice
    end
  end

  describe 'the result board' do
    it 'tells you when your name is drawn' do
      hold_ticket

      raffle.handle("Mahtra's name appears on the result board!")

      expect(DRC).to have_received(:message).with(/your name is on the result board!/)
    end

    it 'warns when your name is drawn and no raffle ticket is in hand' do
      raffle.handle("Mahtra's name appears on the result board!")

      expect(DRC).to have_received(:message).with(/aren't holding a raffle ticket/)
    end

    it "ignores another character's name" do
      raffle.handle("Gnela's name appears on the result board!")

      expect(DRC).not_to have_received(:message)
    end

    it 'ignores a longer name that ends in yours' do
      raffle.handle("Bigmahtra's name appears on the result board!")
      raffle.handle("XMahtra's name appears on the result board!")

      expect(DRC).not_to have_received(:message)
    end

    it 'ignores another player saying your name is on the board' do
      raffle.handle(%(Gnara says, "Mahtra's name appears on the result board!"))

      expect(DRC).not_to have_received(:message)
    end
  end

  describe 'when the drawing ends' do
    it 'hands the ticket in by its id and reports the prize' do
      hold_ticket(id: '777')
      allow(DRC).to receive(:bput).with('put #777 on counter', any_args).and_return(RAFFLE_CLAIM_WON)

      expect(raffle.handle(RAFFLE_DRAWING_OVER)).to be_nil

      expect(DRC).to have_received(:message).with("raffle: you won a diamond-hide scroll tube lined in bluefire velvet! It's in your hand.")
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'throws a losing ticket away by its id' do
      hold_ticket(id: '777')
      allow(DRC).to receive(:bput).with('put #777 on counter', any_args).and_return(RAFFLE_CLAIM_LOST)

      raffle.handle(RAFFLE_DRAWING_OVER)

      expect(DRCI).to have_received(:dispose_trash).with('#777')
    end

    it 'falls back to the raffle ticket by name when the hand has no id' do
      $right_hand = ticket
      allow(DRC).to receive(:bput).with('put my raffle ticket on counter', any_args).and_return(RAFFLE_CLAIM_LOST)

      raffle.handle(RAFFLE_DRAWING_OVER)

      expect(DRCI).to have_received(:dispose_trash).with('raffle ticket')
    end

    it 'never hands in or throws away a different ticket' do
      $right_hand = 'battered repair ticket'
      $hand_ids = { 'battered repair ticket' => '55' }

      raffle.handle(RAFFLE_DRAWING_OVER)

      expect(DRC).not_to have_received(:bput)
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'keeps the ticket and says so when the reply is not recognised' do
      hold_ticket
      allow(DRC).to receive(:bput).and_return('')

      raffle.handle(RAFFLE_DRAWING_OVER)

      expect(DRCI).not_to have_received(:dispose_trash)
      expect(DRC).to have_received(:message).with(/could not hand the ticket in/)
    end

    it 'warns when your name was drawn but no raffle ticket is in hand' do
      raffle.handle("Mahtra's name appears on the result board!")
      raffle.handle(RAFFLE_DRAWING_OVER)

      expect(DRC).to have_received(:message).with(/your name was drawn/)
    end

    it 'does not repeat that warning in a later drawing you did not win' do
      raffle.handle("Mahtra's name appears on the result board!")
      raffle.handle(RAFFLE_DRAWING_OVER)
      raffle.handle(RAFFLE_DRAWING_OVER)

      expect(DRC).to have_received(:message).with(/your name was drawn/).once
    end

    it 'ignores another player quoting the end-of-drawing line' do
      hold_ticket
      raffle.handle(%(Gnara says, "#{RAFFLE_DRAWING_OVER}"))
      raffle.handle(%([General][Gnara] #{RAFFLE_LAST_DRAWING_OVER}))
      raffle.handle(%(Gnara exclaims, "Congratulations to all our winners!"))

      expect(DRC).not_to have_received(:bput)
    end

    it 'settles the ticket and stops after the last raffle of the evening' do
      hold_ticket(id: '777')
      allow(DRC).to receive(:bput).and_return(RAFFLE_CLAIM_LOST)

      expect(raffle.handle(RAFFLE_LAST_DRAWING_OVER)).to eq(:done)

      expect(DRCI).to have_received(:dispose_trash).with('#777')
      expect(DRC).to have_received(:message).with(/last raffle of the evening/)
    end

    it 'keeps running after an ordinary drawing' do
      expect(raffle.handle(RAFFLE_DRAWING_OVER)).to be_nil
    end
  end

  describe '#run' do
    it 'reads game lines until the last drawing is settled' do
      lines = [nil, RAFFLE_TICKETS_OUT, RAFFLE_LAST_DRAWING_OVER, 'never read']
      allow(raffle).to receive(:get) { lines.shift }

      raffle.run

      expect(lines).to eq(['never read'])
    end
  end
end
