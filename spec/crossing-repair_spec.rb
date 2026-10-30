require 'ostruct'

require_relative 'spec_helper'

load_lic_class('crossing-repair.lic', 'CrossingRepair')

RSpec.describe CrossingRepair do
  let(:repair) { CrossingRepair.allocate }
  let(:equipment_manager) { double('EquipmentManager', get_item?: true, empty_hands: true) }
  let(:granzer) { { 'name' => 'Granzer', 'id' => 2_102_051 } }
  let(:mortar) { OpenStruct.new(short_name: 'mortar') }
  let(:bowl) { OpenStruct.new(short_name: 'bowl') }

  # Game responses keyed by command; anything unlisted times out ('').
  let(:responses) { {} }

  before do
    repair.instance_variable_set(:@equipment_manager, equipment_manager)
    allow(DRC).to receive(:bput) { |command, *_matches| responses.fetch(command, '') }
    allow(DRC).to receive(:message)
    allow(DRCT).to receive(:walk_to).and_return(true)
    $right_hand = nil
    $left_hand = nil
  end

  after do
    $right_hand = nil
    $left_hand = nil
  end

  describe '#repair' do
    it 'reports failure when an undamaged item cannot be put back' do
      responses['give my mortar to Granzer'] = "I will not repair something that isn't broken"
      allow(equipment_manager).to receive(:empty_hands).and_return(false)

      expect(repair.repair('Granzer', mortar)).to be false
    end

    it 'continues past an item the character does not have' do
      allow(equipment_manager).to receive(:get_item?).and_return(false)

      expect(repair.repair('Granzer', mortar)).to be true
    end

    it 'reports failure when the repair ticket cannot be stowed' do
      responses['give my mortar to Granzer'] = 'Just give it to me again'
      responses['give Granzer'] = "Please don't lose this ticket!"
      $right_hand = 'marble mortar'
      allow(DRCI).to receive(:stow_item?).with('ticket').and_return(false)

      expect(repair.repair('Granzer', mortar)).to be false
    end

    it 'gives the item again when the repairer asks for agreement (Fang Cove wording)' do
      responses['give my mortar to Granzer'] = 'If you agree, give it to me again'
      responses['give Granzer'] = "Please don't lose this ticket!"
      $right_hand = 'marble mortar'
      allow(DRCI).to receive(:stow_item?).with('ticket').and_return(true)
      allow(repair).to receive(:fput)

      expect(repair.repair('Granzer', mortar)).to be true
      expect(DRC).to have_received(:bput).with('give Granzer', any_args)
      expect(equipment_manager).not_to have_received(:empty_hands)
    end

    it 'tries to clear its hands when the give gets no recognised response' do
      expect(equipment_manager).to receive(:empty_hands).and_return(false)

      expect(repair.repair('Granzer', mortar)).to be false
    end
  end

  describe '#repair_at' do
    it 'stops handing in items after the first one that cannot be put away' do
      responses['give my mortar to Granzer'] = "I will not repair something that isn't broken"
      allow(equipment_manager).to receive(:empty_hands).and_return(false)

      expect(repair.repair_at('Granzer', 2_102_051, [mortar, bowl])).to be false
      expect(equipment_manager).not_to have_received(:get_item?).with(bowl)
    end

    it 'succeeds when there is nothing to repair' do
      expect(repair.repair_at('Granzer', 2_102_051, [])).to be true
    end
  end

  describe '#repair_handler' do
    let(:settings) { OpenStruct.new }

    before do
      allow(repair).to receive(:repair_prep).and_return({ granzer => [mortar, bowl] })
      allow(repair).to receive(:repair_at).and_return(false)
      allow(DRCM).to receive(:deposit_coins)
      allow(repair).to receive(:tickets_left?)
      $right_hand = 'marble mortar'
    end

    it 'exits without banking or collecting tickets once an item is stuck in hand' do
      expect { repair.repair_handler('Shard', settings) }.to raise_error(SystemExit)
      expect(DRCM).not_to have_received(:deposit_coins)
      expect(repair).not_to have_received(:tickets_left?)
      expect(DRC).to have_received(:message).with(/Could not put away marble mortar/)
    end
  end

  describe '#tickets_left?' do
    it 'stops when there is no free hand to pick up a ticket' do
      responses['get my Granzer ticket'] = 'You need a free hand'
      $right_hand = 'marble mortar'
      $left_hand = 'deep bowl'

      expect(repair.tickets_left?(granzer)).to be false
      expect(DRCT).not_to have_received(:walk_to)
      expect(DRC).to have_received(:message).with(/holding marble mortar and deep bowl/)
    end

    it 'stops when getting a ticket gets no response' do
      expect(repair.tickets_left?(granzer)).to be false
      expect(DRCT).not_to have_received(:walk_to)
    end

    it 'stops when the ticket cannot be handed over' do
      responses['get my Granzer ticket'] = 'You get'

      expect(repair.tickets_left?(granzer)).to be false
    end

    it 'stops when the returned item cannot be put away' do
      responses['get my Granzer ticket'] = 'You get'
      responses['give my ticket to Granzer'] = 'takes your ticket'
      allow(equipment_manager).to receive(:empty_hands).and_return(false)

      expect(repair.tickets_left?(granzer)).to be false
    end

    it 'keeps going after a ticket is redeemed and the item put away' do
      responses['get my Granzer ticket'] = 'You get'
      responses['give my ticket to Granzer'] = 'takes your ticket'

      expect(repair.tickets_left?(granzer)).to be true
      expect(DRCT).to have_received(:walk_to).with(2_102_051)
    end

    it 'is done when there are no tickets left' do
      responses['get my Granzer ticket'] = 'What were you referring'

      expect(repair.tickets_left?(granzer)).to be false
    end
  end
end
