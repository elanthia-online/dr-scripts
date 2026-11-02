# frozen_string_literal: true

require 'ostruct'
require 'yaml'

require_relative 'spec_helper'

load_lic_class('find-darkbox.lic', 'FindDarkbox')

# Each `play darkbox` delivers that play's server lines the way lich-5 does:
# into the reget buffer ($server_buffer, read by the harness copy of lich-5's
# reget, which strips tags) and through every registered Flags matcher, as
# DRParser.check_events does for each downstream line. What the play leaves in
# the right hand is set after its lines. When the scripted plays run out, the
# next play ends the run.
#
# Game lines and held-item names are copied from a real three-session log of
# 154 plays (Andreshlew, Hollow Eve 2026). Other players' lines keep the game's
# wording with the name replaced.
#
# The Flags and reget checks walk to the bank, stop the run, clear the saved
# Darkbox room or run heal-remedy (which uses up herbs and remedies), so each
# must match only the game's own line and not another player's speech, ESP or
# whisper that contains the same words.
RSpec.describe FindDarkbox do
  let(:end_of_run) { Class.new(StandardError) }
  let(:settings) do
    OpenStruct.new(
      hollow_eve_junk: [],
      darkbox_stop_on_wounded: false,
      he_use_herbs_remedies: true,
      hollow_eve_loot_container: 'sack',
      worn_trashcan: nil,
      worn_trashcan_verb: nil
    )
  end
  let(:override) { false }
  let(:walks) { [] }
  let(:sent) { [] }
  # Server lines per `play darkbox`, in order.
  let(:plays) { [] }
  # What lands in the right hand per `play darkbox`, in order (nil: nothing).
  let(:loot) { [] }
  # Server lines that arrive while heal-remedy runs.
  let(:during_heal) { [] }
  # Blocks registered with before_dying, which Lich runs when the script ends.
  let(:cleanups) { [] }

  let(:paid_line) { 'You count out 200 Kronars and drop the coins into a slot in the side of the Darkbox where they vanish without a sound.' }
  let(:peer_line) { 'Peering into the Darkbox to spot a shiny bauble to grab or a writhing creature to avoid, you see neither.  So you plunge your hand into the darkness and hope for the best....' }
  let(:found_nothing_line) { 'You fish around in the unseen depths of the Darkbox but you find nothing and remove your hand in disappointment.' }
  let(:crushed_line) { 'Before your hand is completely free of the Darkbox a hissing creature darts from the depths of the box and crushes your hand!' }
  let(:gone_line) { 'Without warning, the Darkbox simply vanishes.' }
  let(:no_money_line) { "You try to play the Darkbox, but realize you don't have the 200 Kronars required.  How depressing." }
  let(:wounded_line) { 'Your injury increases the difficulty of the game, but you press on.' }
  let(:no_darkbox_line) { 'What type of song did you want to play?' }
  let(:wounds_line) { 'You try to play the Darkbox, but your wounds make it impossible.' }
  let(:what_were_line) { 'What were you referring to?' }
  let(:try_line) { 'You try, but you cannot get through.' }

  before do
    allow(DRCT).to receive(:walk_to) { |id| walks << id }
    allow(DRC).to receive(:message)
    allow(DRC).to receive(:bput).and_return('The clerk counts out')
    allow(DRC).to receive(:wait_for_script_to_complete) { during_heal.each { |line| receive_line(line) } }
    allow(DRCI).to receive(:dispose_trash) { $right_hand = nil }
    allow(DRCI).to receive(:put_away_item?) do
      $right_hand = nil
      true
    end
    DRRoom.room_objs = ['the Darkbox']
  end

  # The script reads its settings when built, so examples change `settings`
  # first and the instance is built and stubbed on first use.
  def darkbox
    @darkbox ||= described_class.new(settings, override: override).tap do |instance|
      allow(instance).to receive(:pause)
      allow(instance).to receive(:before_dying) { |&cleanup| cleanups << cleanup }
      allow(instance).to receive(:fput) do |command|
        sent << command
        next unless command == 'play darkbox'

        raise end_of_run if plays.empty?

        plays.shift.each { |line| receive_line(line) }
        $right_hand = loot.shift
      end
    end
  end

  # Feed a server line to reget and through the registered Flags matchers,
  # the way Lich's DRParser.check_events does for every downstream line.
  def receive_line(line)
    $server_buffer << line
    Flags.matchers.each do |key, regexes|
      regexes.each do |regex|
        if (match = line.match(regex))
          Flags[key] = match
          break
        end
      end
    end
  end

  def run_darkbox
    darkbox.run
    :finished
  rescue end_of_run
    :played_on
  rescue SystemExit
    :exited
  end

  def play_count
    sent.count('play darkbox')
  end

  def found_nothing
    [paid_line, peer_line, found_nothing_line, 'Roundtime: 8 sec.']
  end

  def found(description)
    [paid_line, peer_line, 'And you find something!', "As you remove your hand from the Darkbox you see #{description} in your grasp!", 'Roundtime: 12 sec.']
  end

  def esp(text)
    %([General][Mallory] "#{text}")
  end

  def esp_xml(text)
    %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>)
  end

  def say(text)
    %(Mallory says, "#{text}")
  end

  def say_xml(text)
    %(<preset id='speech'>Mallory says</preset>, "#{text}")
  end

  def whisper(text)
    %(Mallory whispers, "#{text}")
  end

  def player_lines(text)
    [esp(text), esp_xml(text), say(text), say_xml(text), whisper(text)]
  end

  describe 'finding the Darkbox' do
    # The Darkbox stands in `darkbox_room`; walking anywhere updates the
    # current room and what is in it.
    let(:darkbox_room) { 16_159 }
    let(:current_room) { [4_444] }

    before do
      DRRoom.room_objs = []
      allow(DRCT).to receive(:walk_to) do |id|
        walks << id
        current_room[0] = id
        DRRoom.room_objs = id == darkbox_room ? ['the Darkbox'] : ['a bucket of viscous gloop']
      end
      allow(Room).to receive(:current) { OpenStruct.new(id: current_room[0]) }
      plays << found_nothing
    end

    # Session 1 of the log: the last Darkbox room was 16241 and the Darkbox
    # had moved to 16159, so the search went round the far end first.
    it 'searches from the last Darkbox room onwards, wrapping round' do
      UserVars.last_darkbox = 16_241
      run_darkbox
      expect(walks).to eq([16_241, 16_242, 16_244, 16_248, 16_249, 16_263, 16_264, 16_267, 16_268,
                           16_318, 16_256, 16_257, 16_150, 16_153, 16_154, 16_276, 16_277, 16_278,
                           16_290, 16_291, 16_292, 16_293, 16_294, 16_295, 16_296, 16_159])
    end

    it 'remembers the room it found the Darkbox in' do
      UserVars.last_darkbox = 16_241
      run_darkbox
      expect(UserVars.last_darkbox).to eq(16_159)
    end

    it 'searches from the first room when the last Darkbox room is not one of them' do
      UserVars.last_darkbox = 1
      run_darkbox
      expect(walks.first(3)).to eq([16_150, 16_153, 16_154])
      expect(walks.last).to eq(16_159)
    end

    it 'does not walk when the Darkbox is already here' do
      DRRoom.room_objs = ['the Darkbox']
      run_darkbox
      expect(walks).to be_empty
    end

    it 'waits before walking when the last move was refused' do
      $server_buffer << try_line
      run_darkbox
      expect(darkbox).to have_received(:pause).with(20).at_least(:once)
    end

    it 'does not wait before walking when only a player said the words' do
      $server_buffer.concat(player_lines('You try, but'))
      run_darkbox
      expect(darkbox).not_to have_received(:pause).with(20)
    end
  end

  describe 'playing' do
    it 'stops the song before anything else' do
      plays << found_nothing
      run_darkbox
      expect(sent.first).to eq('stop play')
    end

    it 'keeps playing round after round while nothing stops it' do
      3.times { plays << found_nothing }
      expect(run_darkbox).to eq(:played_on)
      expect(play_count).to eq(4)
    end

    it 'stands up first when not standing' do
      allow(darkbox).to receive(:checkstanding).and_return(false)
      plays << found_nothing
      run_darkbox
      expect(sent.first(3)).to eq(['stop play', 'stand', 'play darkbox'])
    end

    it 'forgets the Darkbox room and goes to the exit room when the Darkbox vanishes' do
      plays << found_nothing + [gone_line]
      expect(run_darkbox).to eq(:finished)
      expect(UserVars.last_darkbox).to be_nil
      expect(walks).to eq([16_150])
      expect(play_count).to eq(1)
    end

    it 'still sees the vanish line behind a leading tag' do
      plays << ["<pushBold/>#{gone_line}"]
      expect(run_darkbox).to eq(:finished)
      expect(UserVars.last_darkbox).to be_nil
    end

    it 'stops the script when there is no Darkbox to play' do
      plays << [no_darkbox_line]
      expect(run_darkbox).to eq(:exited)
      expect(DRC).to have_received(:message).with('*** Darkbox not found in any of the rooms! ***')
    end

    it 'removes its flags when it finishes' do
      plays << [gone_line]
      run_darkbox
      cleanups.each(&:call)
      expect(Flags.matchers.keys).not_to include(*described_class::FLAGS.keys)
    end

    # Lich only runs before_dying blocks registered before the script ends,
    # so one registered after the play loop never ran for an exit or a kill
    # and the matchers stayed live for the rest of the session.
    it 'removes its flags when it exits for want of a Darkbox' do
      plays << [no_darkbox_line]
      expect(run_darkbox).to eq(:exited)
      cleanups.each(&:call)
      expect(Flags.matchers.keys).not_to include(*described_class::FLAGS.keys)
    end

    it 'arranges to remove its flags before adding them' do
      allow(Flags).to receive(:add).and_wrap_original do |original, *args|
        raise 'flag added before cleanup was registered' if cleanups.empty?

        original.call(*args)
      end
      plays << found_nothing
      expect(run_darkbox).to eq(:played_on)
    end
  end

  describe 'running out of Kronars' do
    it 'goes to the bank and back to the Darkbox room' do
      plays << [no_money_line]
      expect(run_darkbox).to eq(:played_on)
      expect(walks).to eq([16_315, 1])
      expect(DRC).to have_received(:bput).with('withdraw 3 platinum', any_args)
      expect(sent).to include('balance')
    end

    it 'stops the script when the bank will not lend' do
      allow(DRC).to receive(:bput).and_return('we are not lending money at this time')
      plays << [no_money_line]
      expect(run_darkbox).to eq(:exited)
      expect(walks).to eq([16_315])
    end
  end

  describe 'wounds' do
    it 'stops playing when wounded and the setting is on' do
      settings.darkbox_stop_on_wounded = true
      plays << [wounded_line]
      expect(run_darkbox).to eq(:finished)
      expect(play_count).to eq(1)
    end

    it 'plays on when wounded and the setting is off' do
      plays << [wounded_line]
      expect(run_darkbox).to eq(:played_on)
    end

    it 'stops playing when wounds stop the game and herbs and remedies are off' do
      settings.he_use_herbs_remedies = false
      plays << [wounds_line]
      expect(run_darkbox).to eq(:finished)
      expect(DRC).not_to have_received(:wait_for_script_to_complete)
    end

    it 'runs heal-remedy, waits for it to work and plays on' do
      plays << [wounds_line]
      expect(run_darkbox).to eq(:played_on)
      expect(DRC).to have_received(:wait_for_script_to_complete).with('heal-remedy', ['quick'])
      expect(darkbox).to have_received(:pause).with(65)
    end

    context 'with override' do
      let(:override) { true }

      it 'tells heal-remedy to use remedies' do
        plays << [wounds_line]
        run_darkbox
        expect(DRC).to have_received(:wait_for_script_to_complete).with('heal-remedy', %w[quick override])
      end
    end

    it 'stops playing when heal-remedy runs out of herbs' do
      plays << [wounds_line]
      during_heal << what_were_line
      expect(run_darkbox).to eq(:finished)
      expect(DRC).to have_received(:message).with('*** Out of herbs or remedies! Seek out more or an Empath! ***')
    end
  end

  describe 'prizes' do
    before do
      settings.hollow_eve_junk = %w[peach coin flowers rope cambrinth\ peach]
    end

    def play_into_hand(item)
      plays << found(item)
      loot << item
    end

    it 'stores a pearl whose colour is a junk word' do
      play_into_hand('peach pearl')
      run_darkbox
      expect(DRCI).to have_received(:put_away_item?).with('peach pearl', 'sack')
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'trashes an item whose noun is a junk word' do
      play_into_hand('fuzzy peach')
      run_darkbox
      expect(DRCI).to have_received(:dispose_trash).with('fuzzy peach', nil, nil)
    end

    it 'trashes an item matching a two-word junk entry' do
      play_into_hand('cambrinth peach')
      run_darkbox
      expect(DRCI).to have_received(:dispose_trash).with('cambrinth peach', nil, nil)
    end

    it 'stores an item whose noun only starts with a junk word' do
      play_into_hand('copper coinpurse')
      run_darkbox
      expect(DRCI).to have_received(:put_away_item?).with('copper coinpurse', 'sack')
    end

    it 'trashes into the worn trashcan when one is set' do
      settings.worn_trashcan = 'gloop'
      settings.worn_trashcan_verb = 'pat'
      play_into_hand('fuzzy peach')
      run_darkbox
      expect(DRCI).to have_received(:dispose_trash).with('fuzzy peach', 'gloop', 'pat')
    end

    it 'coils a rope before storing it' do
      settings.hollow_eve_junk = []
      play_into_hand('braided rope')
      run_darkbox
      expect(sent).to include('coil my braided rope')
      expect(DRCI).to have_received(:put_away_item?).with('braided rope', 'sack')
    end

    it 'stops the script when a prize will not fit' do
      allow(DRCI).to receive(:put_away_item?).and_return(false)
      play_into_hand('peach pearl')
      expect(run_darkbox).to eq(:exited)
      expect(DRC).to have_received(:message).with('*** The item is either too big to fit or no more room in the container(s)! ***')
    end

    # Every prize the logged sessions got, by the name DRC.right_hand gave it,
    # with the base hollow_eve_junk list. All but the pearl were handled this
    # way in the log; the pearl was trashed.
    {
      'torn sharkskin'        => :trash,
      'black surcoat'         => :trash,
      'chartreuse pants'      => :trash,
      'brown kelp'            => :trash,
      'copper coin'           => :trash,
      'wooden strawberry'     => :trash,
      'peach pearl'           => :store,
      'lambswool cape'        => :trash,
      'brown onyx'            => :store,
      'badger-bone stack'     => :store,
      'cambrinth coyote'      => :trash,
      'green rockweed'        => :trash,
      'jadice flowers'        => :trash,
      'leather patch'         => :trash,
      'cheese crackers'       => :trash,
      'brown-scale leather'   => :store,
      'amber trousers'        => :trash,
      'spider-shaped ocarina' => :trash,
      'banana bread'          => :store
    }.each do |item, outcome|
      it "#{outcome == :trash ? 'trashes' : 'stores'} a #{item} with the base junk list" do
        settings.hollow_eve_junk = YAML.unsafe_load_file(File.join(__dir__, '..', 'profiles', 'base.yaml'))['hollow_eve_junk']
        play_into_hand(item)
        run_darkbox
        if outcome == :trash
          expect(DRCI).to have_received(:dispose_trash).with(item, nil, nil)
        else
          expect(DRCI).to have_received(:put_away_item?).with(item, 'sack')
        end
      end
    end
  end

  # Log line 1090: the creature crushed the hand holding some jadice flowers
  # and they fell after roundtime, once the hands had been checked. The script
  # never picked them up, and the game then refused to let the character walk
  # away from them.
  describe 'a prize the crushed hand drops' do
    let(:dropped_flowers) { found('some jadice flowers') + [crushed_line, 'That hurt!', 'Roundtime: 15 sec.', 'Your jadice flowers falls to your feet.'] }

    before do
      settings.hollow_eve_junk = ['flowers']
      allow(DRCI).to receive(:lift?) do
        $right_hand = 'jadice flowers'
        true
      end
    end

    it 'is picked up and handled before the next play' do
      plays << dropped_flowers
      plays << found_nothing
      run_darkbox
      expect(DRCI).to have_received(:lift?).with('jadice flowers').ordered
      expect(DRCI).to have_received(:dispose_trash).with('jadice flowers', nil, nil).ordered
      expect(play_count).to eq(3)
    end

    it 'is picked up when the drop line comes in behind a tag' do
      plays << found('some jadice flowers') + ['<pushBold/>Your jadice flowers falls to your feet.']
      run_darkbox
      expect(DRCI).to have_received(:lift?).with('jadice flowers')
    end

    it 'is picked up before walking away when the Darkbox vanishes' do
      allow(DRCI).to receive(:lift?) do
        expect(walks).to be_empty
        $right_hand = 'jadice flowers'
        true
      end
      plays << dropped_flowers + [gone_line]
      expect(run_darkbox).to eq(:finished)
      expect(DRCI).to have_received(:lift?).once
      expect(walks).to eq([16_150])
    end

    it 'is reported and play goes on when it cannot be picked up' do
      allow(DRCI).to receive(:lift?).and_return(false)
      plays << dropped_flowers
      expect(run_darkbox).to eq(:played_on)
      expect(DRC).to have_received(:message).with('*** Could not pick up the jadice flowers you dropped. ***')
    end

    it 'is not looked for when another player drops theirs' do
      plays << found_nothing + ["Mallory's cambrinth viper falls to her feet."]
      run_darkbox
      expect(DRCI).not_to have_received(:lift?)
    end

    it 'is not looked for when a player only says the words' do
      plays << found_nothing + player_lines('Your jadice flowers falls to your feet.')
      run_darkbox
      expect(DRCI).not_to have_received(:lift?)
    end
  end

  describe 'held items' do
    # Playing a song leaves the instrument in hand, and 'ocarina' is in the
    # base junk list.
    before do
      settings.hollow_eve_junk = ['ocarina']
      $left_hand = 'spider-shaped ocarina'
    end

    it 'leaves alone an item held before the first play' do
      plays << found_nothing
      run_darkbox
      expect(DRCI).not_to have_received(:dispose_trash)
      expect(DRCI).not_to have_received(:put_away_item?)
    end

    it 'handles a prize in the other hand and leaves the held item alone' do
      plays << found('a large peach pearl')
      loot << 'peach pearl'
      run_darkbox
      expect(DRCI).to have_received(:put_away_item?).with('peach pearl', 'sack').once
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'handles a prize named like the held item' do
      plays << found('a carved spider-shaped ocarina')
      loot << 'spider-shaped ocarina'
      run_darkbox
      expect(DRCI).to have_received(:dispose_trash).with('spider-shaped ocarina', nil, nil).once
    end
  end

  describe 'with player lines carrying the same words' do
    it 'keeps the Darkbox room and keeps playing' do
      plays << player_lines(gone_line)
      expect(run_darkbox).to eq(:played_on)
      expect(UserVars.last_darkbox).to eq(1)
      expect(walks).to be_empty
      expect(play_count).to eq(2)
    end

    it 'does not go to the bank' do
      plays << player_lines(no_money_line)
      expect(run_darkbox).to eq(:played_on)
      expect(walks).to be_empty
      expect(DRC).not_to have_received(:bput)
    end

    it 'keeps playing when wounded-stop is on' do
      settings.darkbox_stop_on_wounded = true
      plays << player_lines(wounded_line)
      expect(run_darkbox).to eq(:played_on)
      expect(play_count).to eq(2)
    end

    it 'does not stop the script as if there were no Darkbox' do
      plays << player_lines(no_darkbox_line)
      expect(run_darkbox).to eq(:played_on)
      expect(DRC).not_to have_received(:message)
    end

    it 'does not run heal-remedy' do
      plays << player_lines('your wounds make it impossible')
      expect(run_darkbox).to eq(:played_on)
      expect(DRC).not_to have_received(:wait_for_script_to_complete)
    end

    it 'keeps playing after heal-remedy when only a player says the item is missing' do
      plays << [wounds_line]
      during_heal.concat(player_lines(what_were_line))
      expect(run_darkbox).to eq(:played_on)
      expect(darkbox).to have_received(:pause).with(65)
      expect(DRC).not_to have_received(:message)
    end
  end
end
