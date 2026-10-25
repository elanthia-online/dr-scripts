# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('mine.lic', 'Mine')

# mine.lic reacts to game lines through Flags (danger, collapse, pinned,
# resource level, yiamura) and to the 'prospect danger' reply through
# DRC.bput. lich-5 tests every one of those patterns against every incoming
# line, and other players' speech, whispers and ESP arrive on lines of their
# own, so each pattern must only match the game's own line.
#
# These specs run the real Mine#initialize with the world stubbed: lines a
# command produces are fed through the registered Flags matchers the way
# lich-5's DRParser.check_events does, and DRC.bput replies are matched the
# way lich-5's DRC.bput matches them.
RSpec.describe Mine do
  let(:mine) { Mine.allocate }

  # Raised by the pause and bput guards so a script that would wait or loop
  # forever ends the example instead.
  let(:stuck) { Class.new(StandardError) }

  let(:small_level_line) { 'You are certain that a small quantity remains to be found.' }
  let(:collapse_line) { 'The entire wall of rock fractures at your blow and comes crashing down atop you!' }
  let(:rumble_line) { 'The ground rumbles ominously.' }
  let(:pinned_line) { 'You seem to be pinned in place by the rubble.' }
  let(:unpinned_line) { 'You finally manage to clear away enough rubble to move again.' }
  let(:no_danger_line) { 'You scan the area and find nothing of concern.' }
  let(:still_danger_line) { 'Unfortunately, you see no way to make this spot any safer.' }

  # Lines arriving while a command runs, keyed by command (or :collect for
  # the yiamura gatherer), one list per time the command is sent.
  let(:arrivals) { Hash.new { |hash, key| hash[key] = [] } }
  let(:bput_commands) { [] }
  let(:pauses) { [] }

  # Feed a server line through the registered Flags matchers, the way
  # lich-5's DRParser.check_events does for every downstream line.
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

  # lich-5 DRC.bput matching: Strings compile to /x/i, each line is tried
  # against every pattern in order, and the first match's text is returned.
  def model_bput(lines, patterns)
    regexes = patterns.flatten.map { |item| item.is_a?(Regexp) ? item : /#{item}/i }
    lines.each do |line|
      regexes.each do |regex|
        match = line.match(regex)
        return match.to_a.first if match
      end
    end
    ''
  end

  def esp_xml(text)
    %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>)
  end

  def say_xml(text)
    %(<preset id='speech'>Mallory says</preset>, "#{text}")
  end

  def whisper(text)
    %(Mallory whispers, "#{text}")
  end

  def player_lines(text)
    { 'ESP' => esp_xml(text), 'say' => say_xml(text), 'whisper' => whisper(text) }
  end

  before do
    $test_settings = OpenStruct.new(
      mining_skip_populated: false,
      mining_implement: +'shovel',
      forging_belt: nil,
      mining_buddy_vein_list: [],
      mine_use_packet: false,
      mining_ignored_stone_sizes: [],
      mining_ignored_deed_sizes: [],
      mining_attempt_timer: 0,
      crafting_container: 'backpack',
      crafting_items_in_container: [],
      mining_yiamura_resource_minimum: 1,
      forage_item: 'rock',
      adjustable_tongs: false
    )
    arrivals['prospect'] << [small_level_line]
    allow(DRC).to receive(:bput) do |command, *patterns|
      bput_commands << command
      raise stuck, "sent #{command.inspect} 50 times" if bput_commands.count(command) > 50

      lines = arrivals[command].shift || []
      lines.each { |line| deliver(line) }
      command == 'prospect danger' ? model_bput(lines, patterns) : 'Roundtime: 1 sec.'
    end
    allow(DRC).to receive(:collect) { (arrivals[:collect].shift || []).each { |line| deliver(line) } }
    allow(mine).to receive(:pause) do |seconds|
      pauses << seconds
      raise stuck, 'waited 20 times for the pinned flag' if pauses.count(5) > 20
    end
  end

  def run_mine
    mine.send(:initialize)
  end

  def sent
    messages = []
    messages << sent_messages.pop until sent_messages.empty?
    messages
  end

  describe 'resource level' do
    # Every level message the script knows, in a line of the game's shape
    # (exact wording is not in our logs), with the level resource_level gave
    # it before the anchors. A shovel mines 5 times per level.
    {
      'certain a scattering of resources'                 => 1,
      'scattering of resources (0/5) remains to be found' => 1,
      'enormous quantity remains to be found'             => 6,
      'enormous quantity (5/5) remains to be found'       => 6,
      'substantial quantity remains to be found'          => 5,
      'substantial quantity (4/5) remains to be found'    => 5,
      'good quantity remains to be found'                 => 4,
      'good quantity (3/5) remains to be found'           => 4,
      'decent quantity remains to be found'               => 3,
      'decent quantity (2/5) remains to be found'         => 3,
      'small quantity remains to be found'                => 2,
      'small quantity (1/5) remains to be found'          => 2
    }.each do |message, level|
      it "mines #{5 * level} times with a shovel for the game line containing '#{message}'" do
        arrivals['prospect'][0] = ["<pushBold/>You are certain that #{message}."]
        run_mine
        expect(bput_commands.count('mine')).to eq(5 * level)
      end
    end

    it 'mines the number of times the real level line gives' do
      run_mine
      expect(bput_commands.count('mine')).to eq(10)
    end

    player_shapes = %w[ESP say whisper]
    player_shapes.each do |shape|
      it "ignores a higher level in a #{shape} line after the real one" do
        arrivals['prospect'][0] << player_lines('an enormous quantity remains to be found')[shape]
        expect { run_mine }.not_to raise_error
        expect(bput_commands.count('mine')).to eq(10)
      end

      it "keeps mining when a #{shape} line has the level text in different case" do
        arrivals['prospect'][0] << player_lines('An ENORMOUS QUANTITY remains to be found')[shape]
        expect { run_mine }.not_to raise_error
        expect(bput_commands.count('mine')).to eq(10)
      end
    end
  end

  describe 'collapse (mine-exit)' do
    it 'logs out at the next danger check after the real collapse line' do
      arrivals['mine'] << [collapse_line]
      run_mine
      expect(sent).to include('exit')
    end

    %w[ESP say whisper].each do |shape|
      it "does not log out on a #{shape} line quoting the collapse message" do
        arrivals['mine'] << [player_lines('The entire wall of rock fractures at your blow and comes crashing down atop you')[shape]]
        expect { run_mine }.not_to raise_error
        expect(sent).not_to include('exit')
        expect(bput_commands.count('mine')).to eq(10)
      end
    end
  end

  describe 'danger (mine-danger and the prospect danger reply)' do
    it 'checks for danger after the real warning line and goes on once the area is clear' do
      arrivals['mine'] << [rumble_line]
      arrivals['prospect danger'] << [no_danger_line]
      run_mine
      expect(bput_commands.count('prospect danger')).to eq(1)
      expect(bput_commands.count('mine')).to eq(10)
    end

    it 'treats the real "shown a way to significantly reduce the danger" reply as cleared' do
      arrivals['mine'] << [rumble_line]
      arrivals['prospect danger'] << ['Your careful study has shown a way to significantly reduce the danger here.']
      run_mine
      expect(bput_commands.count('prospect danger')).to eq(1)
    end

    it 'leaves the node after ten real "Unfortunately" replies' do
      arrivals['mine'] << [rumble_line]
      10.times { arrivals['prospect danger'] << [still_danger_line] }
      expect { run_mine }.to raise_error(SystemExit)
      expect(bput_commands.count('prospect danger')).to eq(10)
    end

    %w[ESP say whisper].each do |shape|
      it "does not start a danger check on a #{shape} line quoting a warning" do
        arrivals['mine'] << [player_lines('The ground rumbles ominously')[shape]]
        expect { run_mine }.not_to raise_error
        expect(bput_commands).not_to include('prospect danger')
      end

      it "does not take a #{shape} 'find nothing of concern' as the danger being cleared" do
        arrivals['mine'] << [rumble_line]
        10.times { arrivals['prospect danger'] << [player_lines('I find nothing of concern')[shape], still_danger_line] }
        expect { run_mine }.to raise_error(SystemExit)
        expect(bput_commands.count('prospect danger')).to eq(10)
      end
    end
  end

  describe 'pinned (mine-pinned)' do
    it 'waits after the real pinned line until the real line saying it is clear' do
      arrivals['mine'] << [pinned_line]
      allow(mine).to receive(:pause) do |seconds|
        pauses << seconds
        deliver(unpinned_line) if seconds == 5
      end
      run_mine
      expect(pauses).to include(5)
      expect(bput_commands.count('mine')).to eq(10)
    end

    %w[ESP say whisper].each do |shape|
      it "does not wait on a #{shape} line quoting the pinned message" do
        arrivals['mine'] << [player_lines('You seem to be pinned in place')[shape]]
        expect { run_mine }.not_to raise_error
        expect(pauses).not_to include(5)
      end
    end
  end

  describe 'yiamura gatherer' do
    before do
      $parsed_args = OpenStruct.new(yiamura: true)
    end

    it 'ends the run when the real tether line arrives' do
      arrivals[:collect] << ['You sense the tether binding your yiamura fade away.']
      expect { run_mine }.to raise_error(SystemExit)
      expect(DRC).to have_received(:collect).once
    end

    it 'prospects again after the real yiamura-done line' do
      arrivals[:collect] << ['Your yiamura stills its flailing as it observes the area.']
      run_mine
      expect(DRC).to have_received(:collect).once
      expect(bput_commands.count('prospect')).to eq(2)
    end

    %w[ESP say whisper].each do |shape|
      it "keeps gathering on a #{shape} line quoting the tether message" do
        arrivals[:collect] << [player_lines('You sense the tether binding your yiamura fade')[shape]]
        expect { run_mine }.not_to raise_error
        expect(DRC).to have_received(:collect).exactly(40).times
      end

      it "does not re-prospect on a #{shape} line quoting the yiamura-done message" do
        arrivals[:collect] << [player_lines('it stills its flailing as it observes the area')[shape]]
        expect { run_mine }.not_to raise_error
        expect(DRC).to have_received(:collect).exactly(40).times
      end
    end
  end
end
