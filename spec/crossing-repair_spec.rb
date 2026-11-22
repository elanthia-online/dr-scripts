require 'fileutils'
require 'ostruct'
require 'tmpdir'

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

    it 'collects the tickets already out, then stops without banking, once an item is stuck in hand' do
      allow(repair).to receive(:repair_at) { stuck_in_hand('marble mortar') }
      allow(repair).to receive(:tickets_left?).and_return(false)

      expect { repair.repair_handler('Shard', settings) }.to raise_error(SystemExit)
      expect(DRCM).not_to have_received(:deposit_coins)
      expect(repair).to have_received(:tickets_left?).with(ragge).ordered
      expect(repair).to have_received(:tickets_left?).with(granzer).ordered
      expect(DRC).to have_received(:message).with(/Could not put away marble mortar/)
      expect(UserVars.repair_timer_snap).to eq(last_repair)
    end

    it 'stops at the second repairer when only its item is stuck, after collecting the tickets' do
      allow(repair).to receive(:repair_at).with('Granzer', 2_102_051, [mortar]).and_return(true)
      allow(repair).to receive(:repair_at).with('Ragge', 2_102_052, [bowl]) { stuck_in_hand('deep bowl') }
      allow(repair).to receive(:tickets_left?).and_return(false)

      expect { repair.repair_handler('Shard', settings) }.to raise_error(SystemExit)
      expect(repair).to have_received(:repair_at).with('Granzer', 2_102_051, [mortar])
      expect(repair).to have_received(:tickets_left?).with(granzer)
      expect(DRC).to have_received(:message).with(/Could not put away deep bowl/)
    end

    # Kythkani, 2026-11-23 03:24: the pestle came back from Catrox and would not go in the
    # full pack, and the run stopped with the mortar's ticket never handed in.
    it 'hands in the other tickets with the stuck item in one hand, and names what is still in hand' do
      allow(repair).to receive(:repair_prep).and_return({ granzer => [mortar] })
      # The mortar went in for repair from the duffel bag; then the pestle stuck in hand.
      allow(repair).to receive(:repair_at) do
        repair.instance_variable_get(:@origins)['mortar'] = 'duffel bag'
        stuck_in_hand('grooved pestle')
      end
      tickets = 1
      allow(DRC).to receive(:bput) do |command, *_matches|
        case command
        when 'get my Granzer ticket'
          next 'What were you referring' if tickets.zero?

          $left_hand = 'Granzer ticket'
          'You get'
        when 'give my ticket to Granzer'
          tickets -= 1
          $left_hand = 'stone mortar'
          'takes your ticket'
        else
          ''
        end
      end
      # The full pack takes neither; the mortar goes back where it was got from.
      allow(equipment_manager).to receive(:empty_hands).and_return(false)
      allow(DRCI).to receive(:put_away_item?) do |noun, container|
        next false unless noun == 'mortar' && container == 'duffel bag'

        $left_hand = nil
        true
      end

      expect { repair.repair_handler('Crossing', settings) }.to raise_error(SystemExit)
      expect(tickets).to eq(0)
      expect($left_hand).to be_nil
      expect(DRC).to have_received(:message).with('Could not put away grooved pestle. Stopping repair.')
      expect(DRC).not_to have_received(:message).with(/Still carrying/)
      expect(UserVars.repair_timer_snap).to eq(last_repair)
    end

    it 'adds its flag for where items come from, and deletes it even when it stops' do
      allow(repair).to receive(:repair_at) { stuck_in_hand('marble mortar') }
      allow(repair).to receive(:tickets_left?).and_return(false)

      expect { repair.repair_handler('Shard', settings) }.to raise_error(SystemExit)
      expect(Flags.matchers).not_to have_key(CrossingRepair::GOT_FROM_FLAG)
      expect(Flags.flags).not_to have_key(CrossingRepair::GOT_FROM_FLAG)
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

    # The ticket goes into a free hand and the item comes back in its place.
    def ticket_brings_back(item)
      allow(DRC).to receive(:bput) do |command, *_matches|
        case command
        when 'get my Granzer ticket' then 'You get'
        when 'give my ticket to Granzer'
          $right_hand ? ($left_hand = item) : ($right_hand = item)
          'takes your ticket'
        else ''
        end
      end
    end

    it 'stops the run when the returned item cannot be put away' do
      ticket_brings_back('marble mortar')
      allow(equipment_manager).to receive(:empty_hands).and_return(false)

      expect { repair.tickets_left?(granzer) }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with(/Could not put away marble mortar/)
    end

    it 'puts the returned item back where it was got from when the gear container will not take it' do
      ticket_brings_back('marble mortar')
      allow(equipment_manager).to receive(:empty_hands).and_return(false)
      repair.instance_variable_set(:@origins, { 'mortar' => 'duffel bag' })
      allow(DRCI).to receive(:put_away_item?).with('mortar', 'duffel bag') do
        $right_hand = nil
        true
      end

      result = nil
      expect { result = repair.tickets_left?(granzer) }.not_to raise_error
      expect(result).to be true
      expect(DRCI).to have_received(:put_away_item?).with('mortar', 'duffel bag')
    end

    it 'keeps going with an item already stuck in the other hand once the returned item is put away' do
      $right_hand = 'grooved pestle'
      ticket_brings_back('marble mortar')
      # empty_hands fails on the pestle but puts the mortar away.
      allow(equipment_manager).to receive(:empty_hands) do
        $left_hand = nil
        false
      end

      result = nil
      expect { result = repair.tickets_left?(granzer) }.not_to raise_error
      expect(result).to be true
    end

    it 'stops, naming both, when the returned item stays in hand next to a stuck one' do
      $right_hand = 'grooved pestle'
      ticket_brings_back('marble mortar')
      allow(equipment_manager).to receive(:empty_hands).and_return(false)

      expect { repair.tickets_left?(granzer) }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with(/Could not put away grooved pestle and marble mortar/)
    end

    it 'gets a ticket with an item stuck in one hand' do
      $right_hand = 'grooved pestle'
      responses['get my Granzer ticket'] = 'What were you referring'

      result = nil
      expect { result = repair.tickets_left?(granzer) }.not_to raise_error
      expect(result).to be false
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

  describe 'where an item was got from' do
    before { repair.instance_variable_set(:@origins, {}) }

    it 'reads the container from the game line (Kythkani, 2026-11-23)' do
      line = 'You get a polished belzune stone mortar from inside your duffel bag.'
      expect(line[CrossingRepair::GOT_FROM, :container]).to eq('duffel bag')
    end

    it 'reads it when the line still carries object links' do
      line = %(You get <a exist="1" noun="mortar">a polished belzune stone mortar</a> from inside your <a exist="2" noun="bag">duffel bag</a>.)
      expect(line[CrossingRepair::GOT_FROM, :container]).to eq('duffel bag')
    end

    it 'reads a container with an apostrophe' do
      line = "You get a loimic grooved pestle from inside your traveler's pack."
      expect(line[CrossingRepair::GOT_FROM, :container]).to eq("traveler's pack")
    end

    it 'does not take a line that is not a get from a container' do
      expect('You get the feeling you are being watched.').not_to match(CrossingRepair::GOT_FROM)
      expect('Tejat gets a grey stone mortar from inside his watersilk knapsack.').not_to match(CrossingRepair::GOT_FROM)
    end

    it 'notes the container the get came from' do
      Flags[CrossingRepair::GOT_FROM_FLAG] = 'You get a stick from inside your duffel bag.'.match(CrossingRepair::GOT_FROM)
      repair.note_origin('stick')
      expect(repair.instance_variable_get(:@origins)).to eq({ 'stick' => 'duffel bag' })
    end

    it 'notes nothing when the get said nothing about a container' do
      Flags[CrossingRepair::GOT_FROM_FLAG] = false
      repair.note_origin('stick')
      expect(repair.instance_variable_get(:@origins)).to eq({})
    end

    # Kythkani, 2026-11-23: every pass after 03:24 got the mixing stick from the duffel bag,
    # heard "There isn't a scratch on that", could not put it in the full pack and stopped.
    it 'puts an undamaged item back where it was got from when the gear container will not take it' do
      stick = OpenStruct.new(short_name: 'mixing.stick', name: 'stick')
      allow(equipment_manager).to receive(:get_item?) do
        Flags[CrossingRepair::GOT_FROM_FLAG] = 'You get a grooved agonite mixing stick from inside your duffel bag.'.match(CrossingRepair::GOT_FROM)
        true
      end
      allow(equipment_manager).to receive(:empty_hands).and_return(false)
      allow(DRCI).to receive(:put_away_item?).and_return(true)
      responses['give my mixing.stick to Catrox'] = "There isn't a scratch on that"

      expect(repair.repair('Catrox', stick)).to be true
      expect(DRCI).to have_received(:put_away_item?).with('stick', 'duffel bag')
    end

    it 'does not guess a container when it does not know where the item came from' do
      stick = OpenStruct.new(short_name: 'mixing.stick', name: 'stick')
      allow(equipment_manager).to receive(:empty_hands).and_return(false)
      allow(DRCI).to receive(:put_away_item?)
      responses['give my mixing.stick to Catrox'] = "There isn't a scratch on that"

      expect(repair.repair('Catrox', stick)).to be false
      expect(DRCI).not_to have_received(:put_away_item?)
    end

    it 'leaves an item the gear container takes where the settings keep it' do
      stick = OpenStruct.new(short_name: 'mixing.stick', name: 'stick')
      repair.instance_variable_set(:@origins, { 'stick' => 'duffel bag' })
      allow(DRCI).to receive(:put_away_item?)
      responses['give my mixing.stick to Catrox'] = "There isn't a scratch on that"

      expect(repair.repair('Catrox', stick)).to be true
      expect(DRCI).not_to have_received(:put_away_item?)
    end
  end

  describe '#stop_repair' do
    let(:catrox) { { 'name' => 'Catrox', 'id' => 19_093 } }

    it 'names each ticket still carried and what it is for' do
      repair.instance_variable_set(:@repairers, [catrox])
      responses['look at my first Catrox ticket'] = 'Looking at the Catrox ticket you see it is for a polished belzune stone mortar.  You recall that your mortar should be ready by now.'
      responses['look at my second Catrox ticket'] = 'Looking at the Catrox ticket you see it is for a loimic grooved pestle.  You recall that your pestle should be ready any moment now.'
      responses['look at my third Catrox ticket'] = 'I could not find what you were referring to.'

      expect { repair.stop_repair('Could not put away grooved pestle.') }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('Still carrying Catrox ticket for polished belzune stone mortar; Catrox ticket for loimic grooved pestle.')
    end

    it 'says nothing about tickets when none is carried' do
      repair.instance_variable_set(:@repairers, [catrox])
      responses['look at my first Catrox ticket'] = 'What were you referring to?'

      expect { repair.stop_repair('Could not put away grooved pestle.') }.to raise_error(SystemExit)
      expect(DRC).not_to have_received(:message).with(/Still carrying/)
    end

    it 'says there may be more tickets past the last ordinal it looks at' do
      repair.instance_variable_set(:@repairers, [catrox])
      CrossingRepair::TICKET_ORDINALS.each do |ordinal|
        responses["look at my #{ordinal} Catrox ticket"] = 'Looking at the Catrox ticket you see it is for a loimic slender awl.  You recall that your awl should be ready by now.'
      end

      expect { repair.stop_repair('Could not put away grooved pestle.') }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with(/(Catrox ticket for loimic slender awl; ){10}possibly more Catrox tickets\./)
    end

    it 'looks at no tickets before the repairers are known' do
      expect { repair.stop_repair('Could not put away grooved pestle before repairing.') }.to raise_error(SystemExit)
      expect(DRC).not_to have_received(:bput)
    end

    it 'stops looking when a look gets no answer' do
      repair.instance_variable_set(:@repairers, [catrox])

      expect { repair.stop_repair('Could not put away grooved pestle.') }.to raise_error(SystemExit)
      expect(DRC).to have_received(:bput).with('look at my first Catrox ticket', any_args).once
      expect(DRC).not_to have_received(:bput).with('look at my second Catrox ticket', any_args)
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

    it "waits and tries again when Verrys says the repair isn't ready" do
      # The first reply is Verrys's real game line, matched against the script's own
      # match list the way bput does; the retry is then handed in.
      not_ready = %(The Crafty Lady Verrys shakes her head.  "That's not ready yet, sir.  Check your ticket for the estimated time, and please be patient.")
      replies = [->(matches) { matches.find { |match| not_ready =~ /#{match}/i } || '' }, ->(_matches) { 'You hand' }]
      allow(DRC).to receive(:bput).with('give my ticket to Verrys', any_args) { |_command, *matches| replies.shift.call(matches) }

      expect(repair.turn_in_ticket('Verrys')).to be true
      expect(repair).to have_received(:pause).with(30).once
    end

    it 'is not taken when the give gets no response' do
      expect(repair.turn_in_ticket('Granzer')).to be false
    end
  end
end

# Words after the town name settings files (args.flex), as in combat-trainer:
# `crossing-repair Crossing task` reads <Character>-task.yaml as well, so a
# profile can carry its own repair_timer.
RSpec.describe 'CrossingRepair settings files named on the command line' do
  # Setup file alone, and setup merged with Testchar-task.yaml, as Lich's
  # get_settings returns them. The harness get_settings ignores its argument,
  # so the stub below answers by file list: a spec passes only if the script
  # asks for the files the command line named.
  let(:setup_timer) { 10_800 }
  let(:task_timer) { 43_200 }
  let(:profiles_dir) { File.join(script_dir, 'profiles') }
  let(:script_dir) { Dir.mktmpdir('crossing-repair-profiles') }

  around do |example|
    saved = $HOMETOWN_REGEX
    $HOMETOWN_REGEX = /^(crossing|riverhaven|shard)$/i
    example.run
  ensure
    $HOMETOWN_REGEX = saved
  end

  before do
    reset_data
    $settings_called_with = nil
    $parse_args_model = true
    stub_const('SCRIPT_DIR', script_dir)
    FileUtils.mkdir_p(profiles_dir)
    File.write(File.join(profiles_dir, 'Testchar-task.yaml'), "repair_timer: #{task_timer}\n")
    allow(DRC).to receive(:message)
    allow_any_instance_of(CrossingRepair).to receive(:repair_handler)
    allow_any_instance_of(CrossingRepair).to receive(:start_script)
    allow_any_instance_of(CrossingRepair).to receive(:get_settings) do |_repair, files|
      $settings_called_with = files
      timer = files == ['task'] ? task_timer : setup_timer
      OpenStruct.new(repair_timer: timer, sell_loot_money_on_hand: '3 silver', hometown: 'Crossing', instrument: 'zills')
    end
    allow(EquipmentManager).to receive(:new).and_return(double('EquipmentManager', wear_equipment_set?: true, empty_hands: true))
    $test_data = OpenStruct.new(town: { 'Crossing' => {} })
    UserVars.repair_timer_snap = Time.now - (4 * 3600)
  end

  after { FileUtils.rm_rf(script_dir) }

  it 'reads the settings files named after the town' do
    $script_vars = ArgParserModel.script_vars('Crossing task')

    expect { CrossingRepair.new }.to raise_error(SystemExit)

    expect($settings_called_with).to eq(['task'])
  end

  it 'still takes the town, force and debug words as arguments, not as settings files' do
    $script_vars = ArgParserModel.script_vars('Crossing force debug task')

    CrossingRepair.new

    expect($settings_called_with).to eq(['task'])
  end

  it 'reads only the setup file when no settings file is named' do
    $script_vars = ArgParserModel.script_vars('Crossing')

    CrossingRepair.new

    expect($settings_called_with).to eq([])
  end

  # Same snap time (4 hours ago) in both: the setup file's 3-hour timer has run
  # out, the task file's 12-hour one has not.
  it "skips the repair while the named file's repair_timer has not run out" do
    $script_vars = ArgParserModel.script_vars('Crossing task')
    expect_any_instance_of(CrossingRepair).not_to receive(:repair_handler)

    expect { CrossingRepair.new }.to raise_error(SystemExit)
    expect($settings_called_with).to eq(['task'])
  end

  it "repairs on the setup file's timer when no settings file is named" do
    $script_vars = ArgParserModel.script_vars('Crossing')

    repair = CrossingRepair.new

    expect(repair).to have_received(:repair_handler)
  end

  it "repairs once the named file's shorter repair_timer has run out" do
    allow_any_instance_of(CrossingRepair).to receive(:get_settings) do |_repair, files|
      $settings_called_with = files
      OpenStruct.new(repair_timer: files == ['task'] ? 3600 : 43_200, sell_loot_money_on_hand: '3 silver', hometown: 'Crossing', instrument: 'zills')
    end
    $script_vars = ArgParserModel.script_vars('Crossing task')

    repair = CrossingRepair.new

    expect(repair).to have_received(:repair_handler)
    expect($settings_called_with).to eq(['task'])
  end

  # The comment above the unrecognized-town check: a player who named a town may
  # be far from home, and a typo must not walk them off to the default town.
  describe 'a word that names no settings file' do
    it 'stops without repairing when the town is mistyped' do
      $script_vars = ArgParserModel.script_vars('Crosing')
      expect_any_instance_of(CrossingRepair).not_to receive(:repair_handler)

      expect { CrossingRepair.new }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('Not a town or a settings file: Crosing')
      expect($settings_called_with).to be_nil
    end

    it 'stops when the settings file name is mistyped after a town' do
      $script_vars = ArgParserModel.script_vars('Crossing tsak')

      expect { CrossingRepair.new }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('Not a town or a settings file: tsak')
      expect($settings_called_with).to be_nil
    end

    it 'names every unknown word but not the ones that exist' do
      $script_vars = ArgParserModel.script_vars('task foo bar')

      expect { CrossingRepair.new }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('Not a town or a settings file: foo, bar')
    end

    it 'finds the file in the game-instance profile directory Lich uses' do
      instance_dir = File.join(script_dir, 'data', 'DRX')
      FileUtils.mkdir_p(instance_dir)
      File.write(File.join(instance_dir, 'Testchar-hunt.yaml'), "repair_timer: 3600\n")
      stub_const('DATA_DIR', File.join(script_dir, 'data'))
      XMLData.game = 'DRX'
      $script_vars = ArgParserModel.script_vars('Crossing hunt')

      CrossingRepair.new

      expect($settings_called_with).to eq(['hunt'])
    end
  end
end
