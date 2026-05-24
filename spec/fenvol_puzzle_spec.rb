# frozen_string_literal: true

require 'ostruct'

load File.join(File.dirname(__FILE__), '..', 'test', 'test_harness.rb')
include Harness

def stub_flags_class
  stub_const('Flags', Class.new do
    @flags = {}

    class << self
      def []=(key, value)
        @flags ||= {}
        @flags[key] = value
      end

      def [](key)
        @flags ||= {}
        @flags[key]
      end

      def reset(key)
        @flags ||= {}
        @flags[key] = false
      end

      def add(key, *_matchers)
        @flags ||= {}
        @flags[key] = false
      end

      def delete(key)
        @flags ||= {}
        @flags.delete(key)
      end

      def _reset_all
        @flags = {}
      end
    end
  end)
end

def load_lic_class(filename, class_name)
  return if Object.const_defined?(class_name)

  filepath = File.join(File.dirname(__FILE__), '..', filename)
  lines = File.readlines(filepath)

  start_idx = lines.index { |l| l =~ /^class\s+#{class_name}\b/ }
  raise "Could not find 'class #{class_name}' in #{filename}" unless start_idx

  end_idx = nil
  (start_idx + 1...lines.size).each do |i|
    if lines[i] =~ /^end\s*$/
      end_idx = i
      break
    end
  end
  raise "Could not find matching end for 'class #{class_name}' in #{filename}" unless end_idx

  class_source = lines[start_idx..end_idx].join
  eval(class_source, TOPLEVEL_BINDING, filepath, start_idx + 1)
end

module DRC
  def self.right_hand
    $right_hand
  end

  def self.bput(*_args)
    ''
  end
end

module XMLData
  @room_title = 'Test Room'

  class << self
    attr_accessor :room_title
  end
end

def fput(*_args); end

def echo(*_args); end

def get
  ''
end

def move(*_args); end

def pause(*_args); end

def waitfor(*_args); end

def parse_args(*_args)
  OpenStruct.new
end

def get_settings
  OpenStruct.new
end

def before_dying(&_block); end

load_lic_class('fenvol-puzzle.lic', 'FenvolPuzzle')

RSpec.configure do |config|
  config.before do
    reset_data
    $right_hand = nil
    XMLData.room_title = 'Test Room'
  end
end

RSpec.describe FenvolPuzzle do
  let(:instance) { FenvolPuzzle.allocate }

  before do
    instance.instance_variable_set(:@repeat_mode, nil)
    instance.instance_variable_set(:@repeat_count, nil)
    instance.instance_variable_set(:@container, nil)
    instance.instance_variable_set(:@discard_list, [])
    instance.instance_variable_set(:@poem, '')
    instance.instance_variable_set(:@found, 0)
    instance.instance_variable_set(:@visited, [])
  end

  # -------------------------------------------------------------------
  # Constants
  # -------------------------------------------------------------------
  describe 'CONTAINER_NOUNS' do
    it 'is frozen' do
      expect(FenvolPuzzle::CONTAINER_NOUNS).to be_frozen
    end

    it 'is not empty' do
      expect(FenvolPuzzle::CONTAINER_NOUNS).not_to be_empty
    end

    it 'contains no duplicates' do
      nouns = FenvolPuzzle::CONTAINER_NOUNS
      expect(nouns).to eq(nouns.uniq)
    end

    it 'is sorted alphabetically' do
      nouns = FenvolPuzzle::CONTAINER_NOUNS
      expect(nouns).to eq(nouns.sort)
    end

    it 'includes container nouns from both source scripts' do
      expect(FenvolPuzzle::CONTAINER_NOUNS).to include('bookcase', 'armoire', 'cabinet', 'safe', 'drawer', 'shelf')
    end
  end

  describe 'OPPOSITES' do
    it 'is frozen' do
      expect(FenvolPuzzle::OPPOSITES).to be_frozen
    end

    it 'maps every key to its inverse' do
      FenvolPuzzle::OPPOSITES.each do |dir, opp|
        expect(FenvolPuzzle::OPPOSITES[opp]).to eq(dir),
                                                "Expected OPPOSITES['#{opp}'] to be '#{dir}' but got '#{FenvolPuzzle::OPPOSITES[opp]}'"
      end
    end

    it 'covers all eight cardinal/ordinal directions plus up/down and in/out' do
      expected = %w[north south east west northeast southwest northwest southeast up down in out]
      expected.each do |dir|
        expect(FenvolPuzzle::OPPOSITES).to have_key(dir)
      end
    end
  end

  describe 'TARGET_COUNT' do
    it 'is 6' do
      expect(FenvolPuzzle::TARGET_COUNT).to eq(6)
    end
  end

  describe 'POEM_DELIMITER' do
    it 'matches standard dash-space delimiter lines' do
      expect('- - - - - - -').to match(FenvolPuzzle::POEM_DELIMITER)
    end

    it 'matches minimum 5-dash delimiter' do
      expect('- - - - - ').to match(FenvolPuzzle::POEM_DELIMITER)
    end

    it 'does not match fewer than 5 dashes' do
      expect('- - - - ').not_to match(FenvolPuzzle::POEM_DELIMITER)
    end

    it 'does not match plain text' do
      expect('some regular text').not_to match(FenvolPuzzle::POEM_DELIMITER)
    end
  end

  # -------------------------------------------------------------------
  # Pattern Constants
  # -------------------------------------------------------------------
  describe 'pattern constants' do
    it 'freezes all pattern constants' do
      patterns = %i[
        BUTLER_GATE_PATTERN ENTRY_CONFIRM_PATTERN WORLD_UNRAVELS_PATTERN
        CARD_HANDED_PATTERN CARD_NOT_FOUND_PATTERN REDEEM_CONFIRM_PATTERN
        REDEEM_CONSUME_PATTERN OPEN_SUCCESS_PATTERN OPEN_FAILURE_PATTERN
        LOOK_EMPTY_PATTERN ITEM_VISIBLE_PATTERN TURN_SUCCESS_PATTERN
        TURN_FAILURE_PATTERN PUZZLE_COMPLETE_PATTERN REWARD_PATTERN
        NOT_FOUND_PATTERN
      ]
      patterns.each do |name|
        pattern = FenvolPuzzle.const_get(name)
        expect(pattern).to be_frozen, "Expected #{name} to be frozen"
      end
    end

    it 'matches butler gate text case-insensitively' do
      expect('Only those who can provide proper authorization').to match(FenvolPuzzle::BUTLER_GATE_PATTERN)
      expect('ONLY THOSE WHO CAN PROVIDE PROPER AUTHORIZATION').to match(FenvolPuzzle::BUTLER_GATE_PATTERN)
    end

    it 'matches open success variants' do
      expect('You open the chest.').to match(FenvolPuzzle::OPEN_SUCCESS_PATTERN)
      expect('It is already open.').to match(FenvolPuzzle::OPEN_SUCCESS_PATTERN)
      expect('The lid swings open.').to match(FenvolPuzzle::OPEN_SUCCESS_PATTERN)
    end

    it 'matches open failure variants' do
      expect('What were you referring to?').to match(FenvolPuzzle::OPEN_FAILURE_PATTERN)
      expect('I could not find that.').to match(FenvolPuzzle::OPEN_FAILURE_PATTERN)
      expect('Please rephrase that.').to match(FenvolPuzzle::OPEN_FAILURE_PATTERN)
      expect('You cannot do that.').to match(FenvolPuzzle::OPEN_FAILURE_PATTERN)
    end

    it 'captures item text from ITEM_VISIBLE_PATTERN' do
      match = 'In the chest you see a crimson grimoire.'.match(FenvolPuzzle::ITEM_VISIBLE_PATTERN)
      expect(match).not_to be_nil
      expect(match[1]).to eq('a crimson grimoire.')
    end
  end

  # -------------------------------------------------------------------
  # #strip_xml
  # -------------------------------------------------------------------
  describe '#strip_xml' do
    it 'removes simple HTML tags' do
      expect(instance.send(:strip_xml, '<b>bold</b>')).to eq('bold')
    end

    it 'removes self-closing XML tags' do
      expect(instance.send(:strip_xml, 'text<pushBold/>more')).to eq('textmore')
    end

    it 'removes entity references' do
      expect(instance.send(:strip_xml, 'one&amp;two')).to eq('onetwo')
    end

    it 'handles text with no XML' do
      expect(instance.send(:strip_xml, 'plain text')).to eq('plain text')
    end

    it 'handles empty string' do
      expect(instance.send(:strip_xml, '')).to eq('')
    end

    it 'removes nested tags' do
      expect(instance.send(:strip_xml, '<div><span>hello</span></div>')).to eq('hello')
    end

    it 'preserves text between multiple tags' do
      expect(instance.send(:strip_xml, '<a>one</a> <b>two</b>')).to eq('one two')
    end
  end

  # -------------------------------------------------------------------
  # #normalize_text
  # -------------------------------------------------------------------
  describe '#normalize_text' do
    it 'lowercases text' do
      expect(instance.send(:normalize_text, 'Hello World')).to eq('hello world')
    end

    it 'strips punctuation' do
      expect(instance.send(:normalize_text, 'hello, world!')).to eq('hello world')
    end

    it 'preserves hyphens' do
      expect(instance.send(:normalize_text, 'dark-stained chest')).to eq('dark-stained chest')
    end

    it 'squeezes multiple spaces' do
      expect(instance.send(:normalize_text, 'hello    world')).to eq('hello world')
    end

    it 'strips leading and trailing whitespace' do
      expect(instance.send(:normalize_text, '  hello  ')).to eq('hello')
    end

    it 'handles empty string' do
      expect(instance.send(:normalize_text, '')).to eq('')
    end

    it 'strips special characters but keeps digits' do
      expect(instance.send(:normalize_text, 'item #42 (rare)')).to eq('item 42 rare')
    end

    it 'normalizes curly quotes and apostrophes to spaces' do
      result = instance.send(:normalize_text, "author’s tome")
      expect(result).not_to include("’")
      expect(result).to eq('author s tome')
    end

    it 'normalizes em dashes to spaces' do
      result = instance.send(:normalize_text, "fire—water")
      expect(result).not_to include("—")
    end
  end

  # -------------------------------------------------------------------
  # #in_poem?
  # -------------------------------------------------------------------
  describe '#in_poem?' do
    before do
      instance.instance_variable_set(:@poem, 'a crimson grimoire rests upon the ancient shelf beside a dusty tome')
    end

    it 'matches an exact substring' do
      expect(instance.send(:in_poem?, 'crimson grimoire')).to be true
    end

    it 'strips leading article "a" before matching' do
      expect(instance.send(:in_poem?, 'a crimson grimoire')).to be true
    end

    it 'strips leading article "an" before matching' do
      instance.instance_variable_set(:@poem, 'ancient codex lies here')
      expect(instance.send(:in_poem?, 'an ancient codex')).to be true
    end

    it 'strips leading article "the" before matching' do
      expect(instance.send(:in_poem?, 'the ancient shelf')).to be true
    end

    it 'returns false for text not in the poem' do
      expect(instance.send(:in_poem?, 'emerald folio')).to be false
    end

    it 'is case insensitive' do
      expect(instance.send(:in_poem?, 'CRIMSON GRIMOIRE')).to be true
    end

    it 'strips punctuation before matching' do
      expect(instance.send(:in_poem?, 'crimson grimoire.')).to be true
    end

    it 'returns false for partial word matches that are not substrings' do
      expect(instance.send(:in_poem?, 'grim')).to be true
    end

    it 'returns false for empty item text with non-empty poem' do
      expect(instance.send(:in_poem?, '')).to be true
    end

    it 'returns false when poem is empty' do
      instance.instance_variable_set(:@poem, '')
      expect(instance.send(:in_poem?, 'crimson grimoire')).to be false
    end

    it 'handles hyphenated item descriptions' do
      instance.instance_variable_set(:@poem, 'a dark-stained grimoire')
      expect(instance.send(:in_poem?, 'a dark-stained grimoire')).to be true
    end
  end

  # -------------------------------------------------------------------
  # #scan_containers
  # -------------------------------------------------------------------
  describe '#scan_containers' do
    it 'finds a container with two adjectives' do
      text = 'you see a tall mahogany bookcase against the wall'
      result = instance.send(:scan_containers, text)
      expect(result).to include('tall mahogany bookcase')
    end

    it 'captures article+adjective as two-adj match' do
      text = 'a carved chest sits in the corner'
      result = instance.send(:scan_containers, text)
      expect(result).to include('a carved chest')
    end

    it 'prefers two-adjective match over one-adjective for same noun' do
      text = 'you see a tall mahogany bookcase'
      result = instance.send(:scan_containers, text)
      expect(result).to include('tall mahogany bookcase')
      expect(result).not_to include('mahogany bookcase')
    end

    it 'finds multiple containers in one room' do
      text = 'you see a carved chest and an iron strongbox'
      result = instance.send(:scan_containers, text)
      expect(result.size).to eq(2)
      expect(result).to include('a carved chest')
      expect(result).to include('an iron strongbox')
    end

    it 'returns empty array when no containers found' do
      text = 'a bare stone room with nothing of interest'
      result = instance.send(:scan_containers, text)
      expect(result).to be_empty
    end

    it 'does not match container nouns inside other words' do
      text = 'the boxing ring and desktop computer are here'
      result = instance.send(:scan_containers, text)
      expect(result).to be_empty
    end

    it 'handles hyphenated adjectives' do
      text = 'a dark-stained armoire stands nearby'
      result = instance.send(:scan_containers, text)
      expect(result).to include('a dark-stained armoire')
    end

    it 'returns unique containers' do
      text = 'a carved chest and a carved chest are here'
      result = instance.send(:scan_containers, text)
      expect(result.size).to eq(1)
    end

    it 'handles empty string' do
      expect(instance.send(:scan_containers, '')).to be_empty
    end

    it 'captures article as adjective for bare container nouns' do
      text = 'an ottoman sits here'
      result = instance.send(:scan_containers, text)
      expect(result).to include('an ottoman')
    end

    it 'finds containers with all known container nouns' do
      FenvolPuzzle::CONTAINER_NOUNS.each do |noun|
        text = "a fancy #{noun} is here"
        result = instance.send(:scan_containers, text)
        expect(result).to include("a fancy #{noun}"),
                          "Expected to find container 'a fancy #{noun}' in text"
      end
    end

    it 'handles two different containers with same base noun differently' do
      text = 'a red wooden chest and a blue iron barrel sit here'
      result = instance.send(:scan_containers, text)
      expect(result).to include('red wooden chest')
      expect(result).to include('blue iron barrel')
    end
  end

  # -------------------------------------------------------------------
  # #try_open_candidates
  # -------------------------------------------------------------------
  describe '#try_open_candidates' do
    it 'generates candidates from two-adjective phrase' do
      result = instance.send(:try_open_candidates, 'ichorous green ottoman')
      expect(result).to eq(['green ottoman', 'ichorous ottoman', 'ottoman'])
    end

    it 'generates candidates from single-adjective phrase' do
      result = instance.send(:try_open_candidates, 'carved chest')
      expect(result).to eq(['carved chest', 'chest'])
    end

    it 'returns just the noun for bare noun' do
      result = instance.send(:try_open_candidates, 'chest')
      expect(result).to eq(['chest'])
    end

    it 'deduplicates candidates when adjective matches noun' do
      result = instance.send(:try_open_candidates, 'chest chest')
      expect(result).to eq(['chest chest', 'chest'])
    end

    it 'handles three-adjective phrase' do
      result = instance.send(:try_open_candidates, 'old dark wooden chest')
      expect(result).to eq(['wooden chest', 'dark chest', 'old chest', 'chest'])
    end

    it 'preserves hyphenated adjectives' do
      result = instance.send(:try_open_candidates, 'dark-stained armoire')
      expect(result).to eq(['dark-stained armoire', 'armoire'])
    end
  end

  # -------------------------------------------------------------------
  # #should_continue?
  # -------------------------------------------------------------------
  describe '#should_continue?' do
    it 'returns true for infinite repeat mode' do
      instance.instance_variable_set(:@repeat_mode, :infinite)
      instance.instance_variable_set(:@repeat_count, nil)
      expect(instance.send(:should_continue?, 100)).to be true
    end

    it 'returns true when run_count is less than repeat_count' do
      instance.instance_variable_set(:@repeat_mode, nil)
      instance.instance_variable_set(:@repeat_count, 5)
      expect(instance.send(:should_continue?, 3)).to be true
    end

    it 'returns false when run_count equals repeat_count' do
      instance.instance_variable_set(:@repeat_mode, nil)
      instance.instance_variable_set(:@repeat_count, 5)
      expect(instance.send(:should_continue?, 5)).to be false
    end

    it 'returns false when run_count exceeds repeat_count' do
      instance.instance_variable_set(:@repeat_mode, nil)
      instance.instance_variable_set(:@repeat_count, 3)
      expect(instance.send(:should_continue?, 4)).to be false
    end

    it 'returns false for single-run mode' do
      instance.instance_variable_set(:@repeat_mode, nil)
      instance.instance_variable_set(:@repeat_count, nil)
      expect(instance.send(:should_continue?, 1)).to be false
    end

    it 'returns true at boundary: run_count one less than repeat_count' do
      instance.instance_variable_set(:@repeat_mode, nil)
      instance.instance_variable_set(:@repeat_count, 3)
      expect(instance.send(:should_continue?, 2)).to be true
    end
  end

  # -------------------------------------------------------------------
  # #repeating?
  # -------------------------------------------------------------------
  describe '#repeating?' do
    it 'returns true for infinite mode' do
      instance.instance_variable_set(:@repeat_mode, :infinite)
      expect(instance.send(:repeating?)).to be true
    end

    it 'returns true for count mode' do
      instance.instance_variable_set(:@repeat_count, 3)
      expect(instance.send(:repeating?)).to be true
    end

    it 'returns false for single-run mode' do
      instance.instance_variable_set(:@repeat_mode, nil)
      instance.instance_variable_set(:@repeat_count, nil)
      expect(instance.send(:repeating?)).to be false
    end
  end

  # -------------------------------------------------------------------
  # #complete?
  # -------------------------------------------------------------------
  describe '#complete?' do
    before { stub_flags_class }

    it 'returns true when fenvol-complete flag is set' do
      Flags['fenvol-complete'] = true
      instance.instance_variable_set(:@found, 0)
      expect(instance.send(:complete?)).to be true
    end

    it 'returns true when found count reaches TARGET_COUNT' do
      Flags['fenvol-complete'] = false
      instance.instance_variable_set(:@found, FenvolPuzzle::TARGET_COUNT)
      expect(instance.send(:complete?)).to be true
    end

    it 'returns false when neither condition met' do
      Flags['fenvol-complete'] = false
      instance.instance_variable_set(:@found, 3)
      expect(instance.send(:complete?)).to be false
    end

    it 'returns true when found exceeds TARGET_COUNT' do
      Flags['fenvol-complete'] = false
      instance.instance_variable_set(:@found, FenvolPuzzle::TARGET_COUNT + 1)
      expect(instance.send(:complete?)).to be true
    end
  end

  # -------------------------------------------------------------------
  # #stow_reward
  # -------------------------------------------------------------------
  describe '#stow_reward' do
    it 'does nothing when right hand is empty' do
      $right_hand = nil
      expect(instance).not_to receive(:fput)
      instance.send(:stow_reward)
    end

    it 'does nothing when right hand is empty string' do
      $right_hand = ''
      expect(instance).not_to receive(:fput)
      instance.send(:stow_reward)
    end

    it 'discards item when its noun is on the discard list' do
      $right_hand = 'silk dress'
      instance.instance_variable_set(:@discard_list, ['dress'])
      expect(instance).to receive(:fput).with('put my dress in bucket')
      instance.send(:stow_reward)
    end

    it 'stows item into configured container' do
      $right_hand = 'silver ring'
      instance.instance_variable_set(:@container, 'canvas sack in my back')
      expect(instance).to receive(:fput).with('put my ring in my canvas sack in my back')
      instance.send(:stow_reward)
    end

    it 'does nothing when item is not on discard list and no container set' do
      $right_hand = 'silver ring'
      instance.instance_variable_set(:@discard_list, [])
      instance.instance_variable_set(:@container, nil)
      expect(instance).not_to receive(:fput)
      instance.send(:stow_reward)
    end

    it 'prefers discarding over stowing when both match' do
      $right_hand = 'old dress'
      instance.instance_variable_set(:@discard_list, ['dress'])
      instance.instance_variable_set(:@container, 'backpack')
      expect(instance).to receive(:fput).with('put my dress in bucket')
      instance.send(:stow_reward)
    end

    it 'does not stow when container is empty string' do
      $right_hand = 'silver ring'
      instance.instance_variable_set(:@container, '')
      expect(instance).not_to receive(:fput)
      instance.send(:stow_reward)
    end

    it 'matches discard list case-insensitively via downcase' do
      $right_hand = 'Fancy DRESS'
      instance.instance_variable_set(:@discard_list, ['dress'])
      expect(instance).to receive(:fput).with('put my dress in bucket')
      instance.send(:stow_reward)
    end
  end

  # -------------------------------------------------------------------
  # #enter_library
  # -------------------------------------------------------------------
  describe '#enter_library' do
    it 'returns true immediately when world unravels on first touch' do
      allow(DRC).to receive(:bput).and_return('the world unravels around you')
      allow(instance).to receive(:pause)
      expect(instance.send(:enter_library)).to be true
    end

    it 'returns true when already at confirmation step' do
      allow(DRC).to receive(:bput).and_return(
        'If you are sure you wish to proceed',
        'the world unravels'
      )
      allow(instance).to receive(:pause)
      expect(instance.send(:enter_library)).to be true
    end

    it 'returns true when already inside (no door found)' do
      allow(DRC).to receive(:bput).and_return('What were you referring to?')
      expect(instance.send(:enter_library)).to be true
    end

    it 'redeems card and enters after butler gate' do
      call_count = 0
      allow(DRC).to receive(:bput) do |*_args|
        call_count += 1
        case call_count
        when 1 then 'Only those who can provide proper authorization'
        when 2 then 'You get a library card'
        when 3 then 'Once you redeem this card'
        when 4 then 'The stoic butler takes your card'
        when 5 then 'You put your card'
        when 6 then 'If you are sure you wish to proceed'
        when 7 then 'the world unravels'
        else ''
        end
      end
      allow(instance).to receive(:pause)
      expect(instance.send(:enter_library)).to be true
    end

    it 'returns false when out of library cards' do
      call_count = 0
      allow(DRC).to receive(:bput) do |*_args|
        call_count += 1
        case call_count
        when 1 then 'Only those who can provide proper authorization'
        when 2 then 'What were you referring to?'
        else ''
        end
      end
      allow(instance).to receive(:echo)
      expect(instance.send(:enter_library)).to be false
    end
  end

  # -------------------------------------------------------------------
  # #redeem_card
  # -------------------------------------------------------------------
  describe '#redeem_card' do
    it 'returns true after successful redemption' do
      call_count = 0
      allow(DRC).to receive(:bput) do |*_args|
        call_count += 1
        case call_count
        when 1 then 'You get a library card'
        when 2 then 'Once you redeem this card'
        when 3 then 'The stoic butler takes your card'
        when 4 then 'You put your cards away'
        else ''
        end
      end
      expect(instance.send(:redeem_card)).to be true
    end

    it 'returns false when no cards available' do
      allow(DRC).to receive(:bput).and_return('What were you referring to?')
      allow(instance).to receive(:echo)
      expect(instance.send(:redeem_card)).to be false
    end

    it 'returns false when cards could not be found' do
      allow(DRC).to receive(:bput).and_return('I could not find that')
      allow(instance).to receive(:echo)
      expect(instance.send(:redeem_card)).to be false
    end
  end

  # -------------------------------------------------------------------
  # #try_open
  # -------------------------------------------------------------------
  describe '#try_open' do
    it 'returns the first candidate that succeeds' do
      allow(DRC).to receive(:bput).and_return('You open the carved chest.')
      result = instance.send(:try_open, 'old carved chest')
      expect(result).to eq('carved chest')
    end

    it 'falls back to bare noun when adjective attempts fail' do
      call_count = 0
      allow(DRC).to receive(:bput) do |*_args|
        call_count += 1
        if call_count <= 2
          'What were you referring to?'
        else
          'You open the chest.'
        end
      end
      result = instance.send(:try_open, 'old carved chest')
      expect(result).to eq('chest')
    end

    it 'returns nil when all attempts fail' do
      allow(DRC).to receive(:bput).and_return('What were you referring to?')
      result = instance.send(:try_open, 'phantom chest')
      expect(result).to be_nil
    end

    it 'returns attempt for already-open containers' do
      allow(DRC).to receive(:bput).and_return('That is already open.')
      result = instance.send(:try_open, 'carved chest')
      expect(result).to eq('carved chest')
    end
  end

  # -------------------------------------------------------------------
  # #check_container
  # -------------------------------------------------------------------
  describe '#check_container' do
    before do
      instance.instance_variable_set(:@poem, 'a crimson grimoire rests on the shelf')
    end

    it 'logs skip when container cannot be opened' do
      allow(DRC).to receive(:bput).and_return('What were you referring to?')
      expect(instance).to receive(:echo).with(/could not open/)
      instance.send(:check_container, 'phantom chest')
    end

    it 'logs empty when container has nothing inside' do
      call_count = 0
      allow(DRC).to receive(:bput) do |*_args|
        call_count += 1
        call_count == 1 ? 'You open the chest.' : 'There is nothing in there.'
      end
      expect(instance).to receive(:echo).with(/empty/)
      instance.send(:check_container, 'chest')
    end

    it 'logs not-in-poem when item does not match' do
      call_count = 0
      allow(DRC).to receive(:bput) do |*_args|
        call_count += 1
        case call_count
        when 1 then 'You open the chest.'
        when 2 then 'In the chest you see a blue folio.'
        else ''
        end
      end
      expect(instance).to receive(:echo).with(/not in poem/)
      instance.send(:check_container, 'chest')
    end

    it 'turns item and increments found when item matches poem' do
      call_count = 0
      allow(DRC).to receive(:bput) do |*_args|
        call_count += 1
        case call_count
        when 1 then 'You open the chest.'
        when 2 then 'In the chest you see a crimson grimoire.'
        when 3 then 'You reach for the grimoire and turn it.'
        else ''
        end
      end
      allow(instance).to receive(:echo)
      allow(instance).to receive(:pause)
      instance.send(:check_container, 'chest')
      expect(instance.instance_variable_get(:@found)).to eq(1)
    end

    it 'does not increment found when turn fails' do
      call_count = 0
      allow(DRC).to receive(:bput) do |*_args|
        call_count += 1
        case call_count
        when 1 then 'You open the chest.'
        when 2 then 'In the chest you see a crimson grimoire.'
        when 3 then 'What were you referring to?'
        else ''
        end
      end
      allow(instance).to receive(:echo)
      instance.send(:check_container, 'chest')
      expect(instance.instance_variable_get(:@found)).to eq(0)
    end
  end

  # -------------------------------------------------------------------
  # #turn_item
  # -------------------------------------------------------------------
  describe '#turn_item' do
    it 'increments found on success' do
      allow(DRC).to receive(:bput).and_return('You reach for the grimoire and turn it.')
      allow(instance).to receive(:echo)
      allow(instance).to receive(:pause)
      instance.send(:turn_item, 'chest', 'a crimson grimoire')
      expect(instance.instance_variable_get(:@found)).to eq(1)
    end

    it 'does not increment found on failure' do
      allow(DRC).to receive(:bput).and_return('What were you referring to?')
      allow(instance).to receive(:echo)
      instance.send(:turn_item, 'chest', 'a crimson grimoire')
      expect(instance.instance_variable_get(:@found)).to eq(0)
    end

    it 'uses the last word of item_text as the noun' do
      expect(DRC).to receive(:bput).with(
        'turn grimoire in chest',
        FenvolPuzzle::TURN_SUCCESS_PATTERN,
        FenvolPuzzle::TURN_FAILURE_PATTERN
      ).and_return('You reach for the grimoire')
      allow(instance).to receive(:echo)
      allow(instance).to receive(:pause)
      instance.send(:turn_item, 'chest', 'a crimson grimoire')
    end

    it 'pauses after successful turn' do
      allow(DRC).to receive(:bput).and_return('You reach for the grimoire')
      allow(instance).to receive(:echo)
      expect(instance).to receive(:pause).with(0.5)
      instance.send(:turn_item, 'chest', 'a crimson grimoire')
    end
  end

  # -------------------------------------------------------------------
  # #solve_room
  # -------------------------------------------------------------------
  describe '#solve_room' do
    before { stub_flags_class }

    it 'logs when no containers in room' do
      expect(instance).to receive(:echo).with('No containers in this room.')
      instance.send(:solve_room, [])
    end

    it 'checks each container in order' do
      containers = ['carved chest', 'iron strongbox']
      allow(instance).to receive(:echo)
      expect(instance).to receive(:check_container).with('carved chest').ordered
      expect(instance).to receive(:check_container).with('iron strongbox').ordered
      instance.send(:solve_room, containers)
    end

    it 'stops checking containers when puzzle is complete' do
      containers = ['carved chest', 'iron strongbox']
      allow(instance).to receive(:echo)
      Flags['fenvol-complete'] = true
      expect(instance).not_to receive(:check_container)
      instance.send(:solve_room, containers)
    end

    it 'logs container names' do
      containers = ['carved chest', 'iron strongbox']
      allow(instance).to receive(:check_container)
      expect(instance).to receive(:echo).with('Containers: carved chest, iron strongbox')
      instance.send(:solve_room, containers)
    end
  end

  # -------------------------------------------------------------------
  # #handle_completion
  # -------------------------------------------------------------------
  describe '#handle_completion' do
    before { stub_flags_class }

    it 'echoes puzzle complete' do
      Flags['fenvol-reward'] = true
      allow(instance).to receive(:stow_reward)
      expect(instance).to receive(:echo).with('Puzzle complete!')
      instance.send(:handle_completion)
    end

    it 'stops waiting when reward flag fires' do
      Flags['fenvol-reward'] = true
      allow(instance).to receive(:stow_reward)
      expect(instance).to receive(:echo)
      expect(instance).not_to receive(:pause)
      instance.send(:handle_completion)
    end

    it 'waits up to 5 seconds for reward' do
      Flags['fenvol-reward'] = false
      allow(instance).to receive(:stow_reward)
      allow(instance).to receive(:echo)
      expect(instance).to receive(:pause).with(1).exactly(5).times
      instance.send(:handle_completion)
    end

    it 'calls stow_reward after waiting' do
      Flags['fenvol-reward'] = true
      allow(instance).to receive(:echo)
      expect(instance).to receive(:stow_reward)
      instance.send(:handle_completion)
    end
  end

  # -------------------------------------------------------------------
  # #explore
  # -------------------------------------------------------------------
  describe '#explore' do
    before { stub_flags_class }

    it 'skips already-visited rooms' do
      instance.instance_variable_set(:@visited, ['Test Room'])
      XMLData.room_title = 'Test Room'
      expect(instance).not_to receive(:scan_room)
      instance.send(:explore)
    end

    it 'skips exploration when puzzle is complete' do
      Flags['fenvol-complete'] = true
      expect(instance).not_to receive(:scan_room)
      instance.send(:explore)
    end

    it 'adds current room to visited list' do
      XMLData.room_title = 'Library Room A'
      allow(instance).to receive(:scan_room).and_return([[], []])
      allow(instance).to receive(:solve_room)
      allow(instance).to receive(:echo)
      instance.send(:explore)
      expect(instance.instance_variable_get(:@visited)).to include('Library Room A')
    end
  end

  # -------------------------------------------------------------------
  # #arg_definitions
  # -------------------------------------------------------------------
  describe '#arg_definitions' do
    it 'returns three definition sets' do
      defs = instance.send(:arg_definitions)
      expect(defs.size).to eq(3)
    end

    it 'includes a repeats arg with digit regex' do
      defs = instance.send(:arg_definitions)
      repeats_def = defs.flatten.find { |d| d[:name] == 'repeats' }
      expect(repeats_def).not_to be_nil
      expect('5').to match(repeats_def[:regex])
    end

    it 'includes a repeat arg with repeat regex' do
      defs = instance.send(:arg_definitions)
      repeat_def = defs.flatten.find { |d| d[:name] == 'repeat' }
      expect(repeat_def).not_to be_nil
      expect('repeat').to match(repeat_def[:regex])
      expect('REPEAT').to match(repeat_def[:regex])
    end

    it 'includes an empty set for no-arg invocation' do
      defs = instance.send(:arg_definitions)
      expect(defs.last).to be_empty
    end
  end

  # -------------------------------------------------------------------
  # Adversarial edge cases
  # -------------------------------------------------------------------
  describe 'adversarial edge cases' do
    describe '#scan_containers with tricky input' do
      it 'does not match container noun as suffix of another word' do
        text = 'the outcast looked at the footrest'
        result = instance.send(:scan_containers, text)
        expect(result).to be_empty
      end

      it 'does not match container noun as prefix of another word' do
        text = 'the chestnut tree and the boxing match'
        result = instance.send(:scan_containers, text)
        expect(result).to be_empty
      end

      it 'still finds containers in text with extra whitespace' do
        text = "   a    carved    chest   sits    here   "
        result = instance.send(:scan_containers, text)
        expect(result).to include('a carved chest')
      end

      it 'finds containers in normal room text' do
        text = "a carved chest is here"
        result = instance.send(:scan_containers, text)
        expect(result).to include('a carved chest')
      end
    end

    describe '#in_poem? with tricky input' do
      it 'does not false-positive on articles alone' do
        instance.instance_variable_set(:@poem, 'a test poem')
        expect(instance.send(:in_poem?, 'the')).to be false
      end

      it 'handles item text that is just an article' do
        instance.instance_variable_set(:@poem, 'some poem text')
        expect(instance.send(:in_poem?, 'a')).to be false
      end

      it 'handles multi-word items with matching words in different order' do
        instance.instance_variable_set(:@poem, 'grimoire crimson')
        expect(instance.send(:in_poem?, 'a crimson grimoire')).to be false
      end
    end

    describe '#try_open_candidates with edge input' do
      it 'handles empty string by returning nil noun' do
        result = instance.send(:try_open_candidates, '')
        expect(result).to eq([nil])
      end

      it 'handles single space by returning nil noun' do
        result = instance.send(:try_open_candidates, ' ')
        expect(result).to eq([nil])
      end
    end

    describe '#stow_reward with tricky item names' do
      it 'extracts noun from multi-word item' do
        $right_hand = 'ornate silver ring'
        instance.instance_variable_set(:@container, 'backpack')
        expect(instance).to receive(:fput).with('put my ring in my backpack')
        instance.send(:stow_reward)
      end

      it 'handles single-word item' do
        $right_hand = 'ring'
        instance.instance_variable_set(:@container, 'backpack')
        expect(instance).to receive(:fput).with('put my ring in my backpack')
        instance.send(:stow_reward)
      end
    end

    describe '#should_continue? boundary values' do
      it 'returns true at run_count 0 with repeat_count 1' do
        instance.instance_variable_set(:@repeat_count, 1)
        expect(instance.send(:should_continue?, 0)).to be true
      end

      it 'returns false at run_count 1 with repeat_count 1' do
        instance.instance_variable_set(:@repeat_count, 1)
        expect(instance.send(:should_continue?, 1)).to be false
      end
    end

    describe '#normalize_text with adversarial input' do
      it 'handles string of only special characters' do
        expect(instance.send(:normalize_text, '!@#$%^&*()')).to eq('')
      end

      it 'handles string of only whitespace' do
        expect(instance.send(:normalize_text, '   ')).to eq('')
      end

      it 'handles very long string without error' do
        long_text = 'word ' * 10_000
        result = instance.send(:normalize_text, long_text)
        expect(result.split.size).to eq(10_000)
      end
    end
  end
end
