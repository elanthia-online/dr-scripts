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
      $right_hand = 'marble mortar'

      expect(repair.repair_at('Granzer', 2_102_051, [mortar, bowl])).to be false
      expect(equipment_manager).not_to have_received(:get_item?).with(bowl)
    end

    it 'keeps going when the hands are empty although the put-away reported failure' do
      responses['give my mortar to Granzer'] = "I will not repair something that isn't broken"
      responses['give my bowl to Granzer'] = "I will not repair something that isn't broken"
      allow(equipment_manager).to receive(:empty_hands).and_return(false)

      expect(repair.repair_at('Granzer', 2_102_051, [mortar, bowl])).to be true
      expect(equipment_manager).to have_received(:get_item?).with(bowl)
    end

    it 'succeeds when there is nothing to repair' do
      expect(repair.repair_at('Granzer', 2_102_051, [])).to be true
    end
  end

  describe '#repair_handler' do
    let(:settings) { OpenStruct.new }
    let(:ragge) { { 'name' => 'Ragge', 'id' => 2_102_052 } }
    let(:last_repair) { Time.at(0) }

    # repair_at leaving an item in hand, the way a failed put-away does.
    def stuck_in_hand(item)
      $right_hand = item
      false
    end

    before do
      allow(repair).to receive(:repair_prep).and_return({ granzer => [mortar], ragge => [bowl] })
      allow(DRCM).to receive(:deposit_coins)
      UserVars.repair_timer_snap = last_repair
    end

    it 'stops before banking or walking when its hands cannot be emptied at the start' do
      $right_hand = 'marble mortar'

      expect { repair.repair_handler('Shard', settings) }.to raise_error(SystemExit)
      expect(repair).not_to have_received(:repair_prep)
      expect(DRCT).not_to have_received(:walk_to)
      expect(DRC).to have_received(:message).with(/Could not put away marble mortar before repairing/)
      expect(UserVars.repair_timer_snap).to eq(last_repair)
    end

    it 'exits without banking or collecting tickets once an item is stuck in hand' do
      allow(repair).to receive(:repair_at) { stuck_in_hand('marble mortar') }
      allow(repair).to receive(:tickets_left?)

      expect { repair.repair_handler('Shard', settings) }.to raise_error(SystemExit)
      expect(DRCM).not_to have_received(:deposit_coins)
      expect(repair).not_to have_received(:tickets_left?)
      expect(DRC).to have_received(:message).with(/Could not put away marble mortar/)
      expect(UserVars.repair_timer_snap).to eq(last_repair)
    end

    it 'stops at the second repairer when only its item is stuck' do
      allow(repair).to receive(:repair_at).with('Granzer', 2_102_051, [mortar]).and_return(true)
      allow(repair).to receive(:repair_at).with('Ragge', 2_102_052, [bowl]) { stuck_in_hand('deep bowl') }
      allow(repair).to receive(:tickets_left?)

      expect { repair.repair_handler('Shard', settings) }.to raise_error(SystemExit)
      expect(repair).to have_received(:repair_at).with('Granzer', 2_102_051, [mortar])
      expect(repair).not_to have_received(:tickets_left?)
      expect(DRC).to have_received(:message).with(/Could not put away deep bowl/)
    end

    it 'does not reset the repair timer when tickets cannot be collected' do
      allow(repair).to receive(:repair_at) do
        $left_hand = 'deep bowl'
        stuck_in_hand('marble mortar') || true
      end
      responses['get my Ragge ticket'] = 'You need a free hand'

      expect { repair.repair_handler('Shard', settings) }.to raise_error(SystemExit)
      expect(UserVars.repair_timer_snap).to eq(last_repair)
      expect(DRC).not_to have_received(:bput).with('get my Granzer ticket', any_args)
    end

    it 'collects every ticket from both repairers and resets the repair timer' do
      allow(repair).to receive(:repair_at).and_return(true)
      tickets = { 'Granzer' => 1, 'Ragge' => 2 }
      allow(DRC).to receive(:bput) do |command, *_matches|
        name = command[/^get my (\w+) ticket$/, 1]
        if name
          tickets[name].positive? ? 'You get' : 'What were you referring'
        elsif (name = command[/^give my ticket to (\w+)$/, 1])
          tickets[name] -= 1
          'takes your ticket'
        else
          ''
        end
      end

      expect { repair.repair_handler('Shard', settings) }.not_to raise_error
      expect(tickets).to eq({ 'Granzer' => 0, 'Ragge' => 0 })
      expect(UserVars.repair_timer_snap).not_to eq(last_repair)
    end

    it 'names the town in the rerun command when one was given' do
      repair.instance_variable_set(:@town_arg, 'river')
      allow(repair).to receive(:repair_at) { stuck_in_hand('marble mortar') }

      expect { repair.repair_handler('Riverhaven', settings) }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with(/;crossing-repair river force/)
    end

    it 'leaves the town out of the rerun command when none was given' do
      allow(repair).to receive(:repair_at) { stuck_in_hand('marble mortar') }

      expect { repair.repair_handler('Shard', settings) }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with(/;crossing-repair force/)
    end
  end

  describe '#tickets_left?' do
    it 'stops the run when there is no free hand to pick up a ticket' do
      responses['get my Granzer ticket'] = 'You need a free hand'
      $right_hand = 'marble mortar'
      $left_hand = 'deep bowl'

      expect { repair.tickets_left?(granzer) }.to raise_error(SystemExit)
      expect(DRCT).not_to have_received(:walk_to)
      expect(DRC).to have_received(:message).with(/holding marble mortar and deep bowl/)
    end

    it 'stops the run, saying so, when getting a ticket gets no response' do
      expect { repair.tickets_left?(granzer) }.to raise_error(SystemExit)
      expect(DRCT).not_to have_received(:walk_to)
      expect(DRC).to have_received(:message).with(/No response getting your Granzer ticket/)
    end

    it 'blames the repairer, not the hands, when the ticket is not taken' do
      responses['get my Granzer ticket'] = 'You get'
      $right_hand = 'Granzer ticket'

      expect { repair.tickets_left?(granzer) }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with(/Could not hand in your Granzer ticket \(holding Granzer ticket\)/)
      expect(DRC).not_to have_received(:message).with(/Could not put away/)
      expect(equipment_manager).not_to have_received(:empty_hands)
    end

    it 'stops the run when the returned item cannot be put away' do
      responses['get my Granzer ticket'] = 'You get'
      responses['give my ticket to Granzer'] = 'takes your ticket'
      allow(equipment_manager).to receive(:empty_hands).and_return(false)
      $right_hand = 'marble mortar'

      expect { repair.tickets_left?(granzer) }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with(/Could not put away marble mortar/)
    end

    it 'keeps going when the returned item is put away although the stow reported failure' do
      responses['get my Granzer ticket'] = 'You get'
      responses['give my ticket to Granzer'] = 'takes your ticket'
      allow(equipment_manager).to receive(:empty_hands).and_return(false)

      result = nil
      expect { result = repair.tickets_left?(granzer) }.not_to raise_error
      expect(result).to be true
    end

    it 'says "an item" rather than nothing when the hands read empty' do
      responses['get my Granzer ticket'] = 'You need a free hand'

      expect { repair.tickets_left?(granzer) }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with(/No free hand to get your Granzer ticket \(holding an item\)/)
    end

    it 'keeps going after a ticket is redeemed and the item put away' do
      responses['get my Granzer ticket'] = 'You get'
      responses['give my ticket to Granzer'] = 'takes your ticket'

      result = nil
      expect { result = repair.tickets_left?(granzer) }.not_to raise_error
      expect(result).to be true
      expect(DRCT).to have_received(:walk_to).with(2_102_051)
    end

    it 'is done, quietly, when there are no tickets left' do
      responses['get my Granzer ticket'] = 'What were you referring'

      result = nil
      expect { result = repair.tickets_left?(granzer) }.not_to raise_error
      expect(result).to be false
      expect(DRC).not_to have_received(:message)
    end
  end

  describe '#turn_in_ticket' do
    before do
      allow(repair).to receive(:fput)
      allow(repair).to receive(:pause)
    end

    it 'is taken when the repairer takes the ticket' do
      responses['give my ticket to Granzer'] = 'takes your ticket'

      expect(repair.turn_in_ticket('Granzer')).to be true
    end

    it 'gives again without naming the ticket when asked to' do
      responses['give my ticket to Granzer'] = "You don't need to specify the object"
      responses['give Granzer'] = 'You hand'
      $right_hand = 'Granzer ticket'

      expect(repair.turn_in_ticket('Granzer')).to be true
      expect(repair).not_to have_received(:fput)
    end

    it 'swaps the ticket to the right hand before giving again' do
      responses['give my ticket to Granzer'] = "You don't need to specify the object"
      responses['give Granzer'] = 'You hand'
      $left_hand = 'Granzer ticket'

      expect(repair.turn_in_ticket('Granzer')).to be true
      expect(repair).to have_received(:fput).with('swap')
    end

    it 'waits and tries again while the repair is not finished' do
      replies = ['almost done', 'takes your ticket']
      allow(DRC).to receive(:bput).with('give my ticket to Granzer', any_args) { replies.shift }

      expect(repair.turn_in_ticket('Granzer')).to be true
      expect(repair).to have_received(:pause).with(30).once
    end

    it 'is not taken when the give gets no response' do
      expect(repair.turn_in_ticket('Granzer')).to be false
    end
  end
end
