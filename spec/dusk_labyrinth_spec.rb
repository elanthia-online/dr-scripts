# frozen_string_literal: true

require 'ostruct'

load_lic_class('dusk-labyrinth.lic', 'DuskLab')

RSpec.describe DuskLab do
  let(:lab) { DuskLab.allocate }

  # Runs the real initialize so the real Flags.add calls register, but stops
  # before the maze loop by reporting the run as already done.
  def register_flags(pet_noun: 'kitten')
    $test_settings = OpenStruct.new(duskruin: { 'labyrinth' => { 'pet_noun' => pet_noun } })
    allow(DRCI).to receive(:stow_hands)
    allow(lab).to receive(:done?).and_return(true)
    lab.send(:initialize)
    allow(lab).to receive(:done?).and_call_original
  end

  # Feed a server line through the registered Flags matchers, the way
  # Lich's DRParser.check_events does for every downstream line.
  def deliver(line)
    Flags.matchers.each do |key, regexes|
      regexes.each do |regex|
        if (match = line.match(regex))
          Flags[key] = match
          break
        end
      end
    end
  end

  # Raw XML shapes of other players' text, as Flags see them.
  def player_shapes(text)
    [
      %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
      %([General][Mallory] "#{text}"),
      %(<preset id='speech'>Mallory says</preset>, "#{text}"),
      %(Mallory says, "#{text}"),
      %(<pushStream id="whispers"/><preset id="whisper">Mallory whispers,</preset> "#{text}"<popStream/>),
      %(Mallory whispers, "#{text}")
    ]
  end

  game_lines = {
    'five-minute-warning' => 'You only have about 5 minutes left in the labyrinth!',
    'done'                => 'A surly Dwarf stomps in and glowers at you in the dim gloom.',
    'no-pet'              => 'A small kitten scurries north!',
    'pet'                 => 'You notice a small kitten scurrying around the area.',
    'caught'              => 'You pick them both up, claiming your new pet.',
    'maze-shuffled'       => 'The walls shift around you and you are no longer certain of your directions.'
  }.freeze

  describe 'flag matchers' do
    before { register_flags }

    game_lines.each do |key, line|
      context "'#{key}'" do
        it 'fires on the game line' do
          deliver(line)
          expect(Flags[key]).to be_truthy
        end

        it 'fires on the game line behind a leading tag' do
          deliver("<pushBold/>#{line}<popBold/>")
          expect(Flags[key]).to be_truthy
        end

        it "ignores other players' ESP, speech and whispers carrying the same text" do
          player_shapes(line).each { |shape| deliver(shape) }
          expect(Flags[key]).to be(false)
        end
      end
    end

    it 'still captures the direction the pet ran' do
      deliver('A small kitten scurries northeast!')
      expect(Flags['no-pet'][:pet_dir]).to eq('northeast')
    end

    it 'only hears the configured pet noun' do
      deliver('A small puppy scurries north!')
      deliver('You notice a small puppy scurrying around the area.')
      expect(Flags['no-pet']).to be(false)
      expect(Flags['pet']).to be(false)
    end
  end

  describe '#done?' do
    before { register_flags }

    it 'does not end the run when a player repeats the dwarf line' do
      player_shapes(game_lines['done']).each { |shape| deliver(shape) }
      expect(lab.done?).to be_falsey
    end

    it 'ends the run on the game line' do
      deliver(game_lines['done'])
      expect(lab.done?).to be_truthy
    end
  end

  describe '#main' do
    before do
      register_flags
      allow(lab).to receive(:search)
      allow(lab).to receive(:stow_loot)
      allow(lab).to receive(:wander)
      allow(lab).to receive(:wander_randomly)
    end

    # Each player line arrives first; `then_heard` is the game line that
    # arrives while main waits for the room check.
    def run_room(spoofed:, then_heard:)
      player_shapes(spoofed).each { |shape| deliver(shape) }
      allow(lab).to receive(:pause) { deliver(then_heard) }
      lab.main(nil)
    end

    it 'does not reset the maze map when a player repeats the reshuffle line' do
      run_room(spoofed: game_lines['maze-shuffled'], then_heard: game_lines['no-pet'])
      expect(lab).not_to have_received(:wander_randomly)
      expect(lab).to have_received(:wander)
    end

    it 'resets the maze map on the game reshuffle line' do
      deliver(game_lines['maze-shuffled'])
      lab.main(nil)
      expect(lab).to have_received(:wander_randomly)
      expect(Flags['maze-shuffled']).to be(false)
    end

    it 'does not switch to loot searching when a player repeats the five-minute warning' do
      run_room(spoofed: game_lines['five-minute-warning'], then_heard: game_lines['no-pet'])
      expect(lab).not_to have_received(:search)
      expect(lab).to have_received(:wander)
    end

    it 'searches an empty room for loot after the real five-minute warning' do
      deliver(game_lines['five-minute-warning'])
      deliver(game_lines['no-pet'])
      lab.main(nil)
      expect(lab).to have_received(:search)
    end

    it 'does not search for a pet a player only claims to see' do
      run_room(spoofed: game_lines['pet'], then_heard: game_lines['no-pet'])
      expect(lab).not_to have_received(:search)
    end

    it 'does not skip a room with a pet when a player claims it ran off' do
      run_room(spoofed: game_lines['no-pet'], then_heard: game_lines['pet'])
      expect(lab).to have_received(:search)
    end

    it 'keeps hunting a revisited room when a player claims the pet was caught' do
      lab.instance_variable_set(:@forward_move, 'n')
      lab.instance_variable_set(:@previous_room, { 'exits' => { 'n' => { 'count' => 2 } } })
      player_shapes(game_lines['caught']).each { |shape| deliver(shape) }
      lab.main(nil)
      expect(lab).to have_received(:wander)
      expect(lab).not_to have_received(:search)
    end
  end
end
