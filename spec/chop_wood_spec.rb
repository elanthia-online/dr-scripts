# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('chop-wood.lic', 'ChopWood')

# chop-wood.lic reacts to the forest warnings through the 'chop-danger' Flag,
# to the 'watch forest danger' reply and to the 'get my packet' reply through
# DRC.bput. lich-5 tests every one of those patterns against every incoming
# line, and other players' speech, whispers and ESP arrive on lines of their
# own, so each pattern must only match the game's own line.
#
# These specs run the real ChopWood#initialize with the world stubbed: lines a
# command produces are fed through the registered Flags matchers the way
# lich-5's DRParser.check_events does, and DRC.bput replies are matched the
# way lich-5's DRC.bput matches them.
RSpec.describe ChopWood do
  let(:chopper) { ChopWood.allocate }
  let(:equipment) { double('EquipmentManager', empty_hands: nil, wield_weapon: nil) }

  # Raised by the bput guard so a script that would loop forever ends the
  # example instead.
  let(:stuck) { Class.new(StandardError) }

  let(:no_trees_line) { 'Despite thoroughly exploring the area you fail to find any trees to chop.' }
  let(:chopped_line) { 'You chop at the tree.  Roundtime: 5 sec.' }
  let(:no_danger_line) { 'You scan the area and find nothing of concern.' }
  let(:still_danger_line) { 'Unfortunately, you see no way to make this spot any safer.' }
  let(:reduced_danger_line) { 'Your careful study has shown a way to significantly reduce the danger here.' }
  let(:got_packet_line) { 'You get a packet of deeds from inside your backpack.' }
  let(:no_packet_line) { 'What were you referring to?' }

  let(:warnings) do
    ['You notice an unusual smell drifting through the area',
     'A monotonous buzzing sound fills the air',
     'A loud cracking sound resonates from somewhere closeby']
  end

  # Lines arriving while a command runs, keyed by command, one list per time
  # the command is sent. A command with nothing queued gets its default.
  let(:arrivals) { Hash.new { |hash, key| hash[key] = [] } }
  let(:default_arrivals) do
    {
      'chop tree'            => [no_trees_line],
      'watch forest careful' => ['Your analysis has revealed no additional trees.'],
      'watch forest danger'  => [no_danger_line]
    }
  end
  let(:bput_commands) { [] }

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

  # bput reads stripped text, so its player lines carry no XML.
  def esp(text)
    %([General][Mallory] "#{text}")
  end

  def say(text)
    %(Mallory says, "#{text}")
  end

  def player_lines(text)
    { 'ESP' => esp_xml(text), 'say' => say_xml(text), 'whisper' => whisper(text) }
  end

  def player_text_lines(text)
    { 'ESP' => esp(text), 'say' => say(text), 'whisper' => whisper(text) }
  end

  before do
    $test_settings = OpenStruct.new(
      lumber_implement: 'axe',
      lumber_buddy_tree_list: [],
      lumber_use_packet: false
    )
    allow(EquipmentManager).to receive(:new).and_return(equipment)
    allow(DRC).to receive(:bput) do |command, *patterns|
      bput_commands << command
      raise stuck, "sent #{command.inspect} 50 times" if bput_commands.count(command) > 50

      lines = arrivals[command].shift || default_arrivals[command] || []
      lines.each { |line| deliver(line) }
      model_bput(lines, patterns)
    end
    allow(chopper).to receive(:pause)
  end

  def run_chop_wood
    chopper.send(:initialize)
  end

  describe 'forest warnings (chop-danger)' do
    it 'checks for danger after each real warning line' do
      warnings.each do |warning|
        arrivals['chop tree'] << ["#{warning}.", chopped_line]
      end
      run_chop_wood
      expect(bput_commands.count('watch forest danger')).to eq(3)
      expect(bput_commands.count('chop tree')).to eq(4)
    end

    it 'checks for danger after a real warning line wrapped in tags' do
      arrivals['chop tree'] << ["<pushBold/>#{warnings.last}.<popBold/>", chopped_line]
      run_chop_wood
      expect(bput_commands.count('watch forest danger')).to eq(1)
    end

    %w[ESP say whisper].each do |shape|
      it "does not check for danger on a #{shape} line quoting a warning" do
        warnings.each do |warning|
          arrivals['chop tree'] << [player_lines(warning)[shape], chopped_line]
        end
        run_chop_wood
        expect(bput_commands).not_to include('watch forest danger')
        expect(bput_commands.count('chop tree')).to eq(4)
      end
    end
  end

  describe "the 'watch forest danger' reply" do
    before do
      arrivals['chop tree'] << ["#{warnings.first}.", chopped_line]
    end

    it 'goes on once the real reply says the area is clear' do
      run_chop_wood
      expect(bput_commands.count('watch forest danger')).to eq(1)
    end

    it "treats the real 'shown a way to ... reduce the danger' reply as cleared" do
      arrivals['watch forest danger'] << [reduced_danger_line]
      run_chop_wood
      expect(bput_commands.count('watch forest danger')).to eq(1)
    end

    it "keeps watching after each real 'Unfortunately' reply" do
      2.times { arrivals['watch forest danger'] << [still_danger_line] }
      run_chop_wood
      expect(bput_commands.count('watch forest danger')).to eq(3)
    end

    %w[ESP say whisper].each do |shape|
      it "does not take a #{shape} 'find nothing of concern' as the danger being cleared" do
        arrivals['watch forest danger'] << [player_text_lines('I find nothing of concern here')[shape], still_danger_line]
        run_chop_wood
        expect(bput_commands.count('watch forest danger')).to eq(2)
      end

      it "does not take a #{shape} 'reduce the danger' line as the danger being cleared" do
        arrivals['watch forest danger'] << [player_text_lines("you've shown a way to really reduce the danger")[shape], still_danger_line]
        run_chop_wood
        expect(bput_commands.count('watch forest danger')).to eq(2)
      end

      it "does not watch again on a #{shape} 'Unfortunately' before the real clear reply" do
        arrivals['watch forest danger'] << [player_text_lines('Unfortunately I lost my axe')[shape], no_danger_line]
        run_chop_wood
        expect(bput_commands.count('watch forest danger')).to eq(1)
      end
    end
  end

  describe "the packet check ('get my packet')" do
    before do
      $test_settings.lumber_buddy_tree_list = ['oak']
      $test_settings.lumber_use_packet = true
      DRRoom.room_objs = ['some oak lumber']
    end

    it 'pushes the lumber with the packet on the real get line' do
      arrivals['get my packet'] << [got_packet_line]
      run_chop_wood
      expect(bput_commands).to include('push oak lumber with my packet')
      expect(bput_commands).not_to include('stow lumber')
    end

    it 'stows the lumber by hand when the real reply says there is no packet' do
      arrivals['get my packet'] << [no_packet_line]
      run_chop_wood
      expect(bput_commands).to include('stow lumber')
      expect(bput_commands).not_to include('push oak lumber with my packet')
    end

    %w[ESP say whisper].each do |shape|
      it "does not take a #{shape} 'You get' line as having the packet" do
        arrivals['get my packet'] << [player_text_lines('You get it?')[shape], no_packet_line]
        run_chop_wood
        expect(bput_commands).to include('stow lumber')
        expect(bput_commands).not_to include('push oak lumber with my packet')
      end

      it "does not take a #{shape} 'What were you referring to' as having no packet" do
        arrivals['get my packet'] << [player_text_lines('What were you referring to?')[shape], got_packet_line]
        run_chop_wood
        expect(bput_commands).to include('push oak lumber with my packet')
        expect(bput_commands).not_to include('stow lumber')
      end
    end
  end
end
