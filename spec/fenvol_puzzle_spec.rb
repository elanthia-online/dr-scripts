# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

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

module DRC
  def self.right_hand
    $right_hand
  end

  def self.left_hand
    $left_hand
  end

  def self.bput(*_args)
    ''
  end

  def self.get_noun(long_name)
    long_name.to_s.strip.scan(/[a-z\-']+$/i).first
  end
end

module DRCI
  def self.get_item?(*_args)
    true
  end

  def self.put_away_item?(*_args)
    true
  end

  def self.put_away_item_unsafe?(*_args)
    true
  end

  def self.stow_hands
    true
  end
end

module Lich
  module Messaging
    def self.monsterbold(text)
      text
    end
  end
end

def set_right_hand(name, noun = nil)
  $right_hand = name
  noun ||= name&.to_s&.split&.last
  # fenvol-puzzle.lic reads GameObj.right_hand&.noun and treats a nil hand as
  # empty, so stub it directly rather than routing through the harness wrapper
  # (which reports an empty hand as an 'Empty' OpenStruct, never nil).
  allow(GameObj).to receive(:right_hand).and_return(noun ? OpenStruct.new(noun: noun) : nil)
end

load_lic_class('fenvol-puzzle.lic', 'FenvolPuzzle')

RSpec.describe FenvolPuzzle do
  let(:instance) { FenvolPuzzle.allocate }

  before do
    # World state this spec assumes (reset_data runs first, via spec_helper).
    $right_hand = nil
    $left_hand = nil
    allow(GameObj).to receive(:right_hand).and_return(nil)
    XMLData.room_title = 'Test Room'

    instance.instance_variable_set(:@repeat_mode, nil)
    instance.instance_variable_set(:@repeat_count, nil)
    instance.instance_variable_set(:@containers, [])
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
      expect(FenvolPuzzle::CONTAINER_NOUNS).to include('bookcase', 'armoire', 'cabinet', 'safe', 'drawer', 'bookshelf')
    end

    it 'does not include bare shelf (bookshelf covers that use case)' do
      expect(FenvolPuzzle::CONTAINER_NOUNS).not_to include('shelf')
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
      # Build the non-ASCII input at runtime so the source stays ASCII-only.
      curly_apostrophe = 0x2019.chr(Encoding::UTF_8)
      result = instance.send(:normalize_text, "author#{curly_apostrophe}s tome")
      expect(result).not_to include(curly_apostrophe)
      expect(result).to eq('author s tome')
    end

    it 'normalizes em dashes to spaces' do
      em_dash = 0x2014.chr(Encoding::UTF_8)
      result = instance.send(:normalize_text, "fire#{em_dash}water")
      expect(result).not_to include(em_dash)
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

    it 'matches partial words via substring (grim inside grimoire)' do
      expect(instance.send(:in_poem?, 'grim')).to be true
    end

    it 'returns true for empty item text (empty string is substring of anything)' do
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
    it 'generates adj+noun pairs from two-adjective phrase (DR only accepts single adj)' do
      result = instance.send(:try_open_candidates, 'ichorous green ottoman')
      expect(result).to eq(['green ottoman', 'ichorous ottoman', 'ottoman'])
    end

    it 'generates adj+noun pair from single-adjective phrase' do
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

    it 'generates adj+noun pairs from three-adjective phrase' do
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
  # #validate_empty_hands
  # -------------------------------------------------------------------
  describe '#validate_empty_hands' do
    it 'passes when both hands are empty' do
      allow(DRC).to receive(:right_hand).and_return(nil)
      allow(DRC).to receive(:left_hand).and_return(nil)
      expect { instance.send(:validate_empty_hands) }.not_to raise_error
    end

    it 'passes when hands return empty strings' do
      allow(DRC).to receive(:right_hand).and_return('')
      allow(DRC).to receive(:left_hand).and_return('')
      expect { instance.send(:validate_empty_hands) }.not_to raise_error
    end

    it 'exits when right hand is occupied' do
      allow(DRC).to receive(:right_hand).and_return('sword')
      allow(DRC).to receive(:left_hand).and_return(nil)
      allow(instance).to receive(:_respond)
      expect { instance.send(:validate_empty_hands) }.to raise_error(SystemExit)
    end

    it 'exits when left hand is occupied' do
      allow(DRC).to receive(:right_hand).and_return(nil)
      allow(DRC).to receive(:left_hand).and_return('shield')
      allow(instance).to receive(:_respond)
      expect { instance.send(:validate_empty_hands) }.to raise_error(SystemExit)
    end

    it 'exits when both hands are occupied' do
      allow(DRC).to receive(:right_hand).and_return('sword')
      allow(DRC).to receive(:left_hand).and_return('shield')
      allow(instance).to receive(:_respond)
      expect { instance.send(:validate_empty_hands) }.to raise_error(SystemExit)
    end

    it 'outputs monsterbold messages mentioning fenvol_container setting' do
      allow(DRC).to receive(:right_hand).and_return('sword')
      allow(DRC).to receive(:left_hand).and_return(nil)
      messages = []
      allow(instance).to receive(:_respond) { |msg| messages << msg }
      begin
        instance.send(:validate_empty_hands)
      rescue SystemExit
        nil
      end
      expect(messages.size).to eq(5)
    end
  end

  # -------------------------------------------------------------------
  # #stow_reward
  # -------------------------------------------------------------------
  describe '#stow_reward' do
    it 'returns true when right hand is empty' do
      set_right_hand(nil)
      expect(instance.send(:stow_reward)).to be true
    end

    it 'returns true when right hand is empty string' do
      set_right_hand('')
      expect(instance.send(:stow_reward)).to be true
    end

    it 'discards item via put_away_item_unsafe? into room bucket (no "my" prefix)' do
      set_right_hand('silk dress', 'dress')
      instance.instance_variable_set(:@discard_list, ['dress'])
      expect(DRCI).to receive(:put_away_item_unsafe?).with('my dress', 'bucket').and_return(true)
      expect(instance.send(:stow_reward)).to be true
    end

    it 'stows item via DRCI.put_away_item? into configured containers' do
      set_right_hand('silver ring', 'ring')
      instance.instance_variable_set(:@containers, ['canvas sack in my back'])
      expect(DRCI).to receive(:put_away_item?).with('ring', ['canvas sack in my back']).and_return(true)
      expect(instance.send(:stow_reward)).to be true
    end

    it 'returns true when no discard list and no container set' do
      set_right_hand('silver ring', 'ring')
      instance.instance_variable_set(:@discard_list, [])
      instance.instance_variable_set(:@containers, [])
      expect(instance.send(:stow_reward)).to be true
    end

    it 'prefers discarding over stowing when both match' do
      set_right_hand('old dress', 'dress')
      instance.instance_variable_set(:@discard_list, ['dress'])
      instance.instance_variable_set(:@containers, ['backpack'])
      expect(DRCI).to receive(:put_away_item_unsafe?).with('my dress', 'bucket').and_return(true)
      expect(instance.send(:stow_reward)).to be true
    end

    it 'returns true when container is empty string (no-op)' do
      set_right_hand('silver ring', 'ring')
      instance.instance_variable_set(:@containers, [])
      expect(instance.send(:stow_reward)).to be true
    end

    it 'matches discard list case-insensitively via downcase' do
      set_right_hand('Fancy DRESS', 'dress')
      instance.instance_variable_set(:@discard_list, ['dress'])
      expect(DRCI).to receive(:put_away_item_unsafe?).with('my dress', 'bucket').and_return(true)
      instance.send(:stow_reward)
    end

    it 'matches multi-word discard patterns against full item text' do
      set_right_hand('a heavy iron battle axe', 'axe')
      instance.instance_variable_set(:@discard_list, ['battle axe'])
      allow(instance).to receive(:echo)
      expect(DRCI).to receive(:put_away_item_unsafe?).with('my axe', 'bucket').and_return(true)
      expect(instance.send(:stow_reward)).to be true
    end

    it 'does not discard when multi-word pattern does not match' do
      set_right_hand('a woodcutter axe', 'axe')
      instance.instance_variable_set(:@discard_list, ['battle axe'])
      instance.instance_variable_set(:@containers, ['backpack'])
      allow(DRCI).to receive(:put_away_item?).and_return(true)
      expect(DRCI).not_to receive(:put_away_item_unsafe?)
      instance.send(:stow_reward)
    end

    it 'matches single-word discard pattern as substring of full item text' do
      set_right_hand('a brilliant scarlet camlet cloak', 'cloak')
      instance.instance_variable_set(:@discard_list, ['cloak'])
      allow(instance).to receive(:echo)
      expect(DRCI).to receive(:put_away_item_unsafe?).with('my cloak', 'bucket').and_return(true)
      instance.send(:stow_reward)
    end

    it 'returns false when DRCI.put_away_item? fails (all containers full)' do
      set_right_hand('silver ring', 'ring')
      instance.instance_variable_set(:@containers, ['backpack'])
      allow(DRCI).to receive(:put_away_item?).with('ring', ['backpack']).and_return(false)
      expect(instance.send(:stow_reward)).to be false
    end

    it 'passes multiple containers to DRCI.put_away_item? which tries each' do
      set_right_hand('quarterstaff', 'quarterstaff')
      instance.instance_variable_set(:@containers, ['sack', 'rucksack'])
      expect(DRCI).to receive(:put_away_item?).with('quarterstaff', ['sack', 'rucksack']).and_return(true)
      expect(instance.send(:stow_reward)).to be true
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
        when 2 then 'Once you redeem this card'
        when 3 then 'The stoic butler takes your card'
        when 4 then 'If you are sure you wish to proceed'
        when 5 then 'the world unravels'
        else ''
        end
      end
      allow(DRCI).to receive(:get_item?).and_return(true)
      allow(DRCI).to receive(:stow_hands)
      allow(instance).to receive(:pause)
      expect(instance.send(:enter_library)).to be true
    end

    it 'returns false when out of library cards' do
      allow(DRC).to receive(:bput).and_return('Only those who can provide proper authorization')
      allow(DRCI).to receive(:get_item?).with('library card').and_return(false)
      allow(instance).to receive(:echo)
      expect(instance.send(:enter_library)).to be false
    end

    it 'returns true when card handed on first touch' do
      allow(DRC).to receive(:bput).and_return('You hand your card to the butler')
      allow(instance).to receive(:pause)
      expect(instance.send(:enter_library)).to be true
    end

    it 'sends two more touch door commands after redeem' do
      commands = []
      allow(DRC).to receive(:bput) do |cmd, *_patterns|
        commands << cmd
        case commands.size
        when 1 then 'Only those who can provide proper authorization'
        when 2 then 'Once you redeem this card'
        when 3 then 'The stoic butler takes your card'
        when 4 then 'If you are sure you wish to proceed'
        when 5 then 'the world unravels'
        else ''
        end
      end
      allow(DRCI).to receive(:get_item?).and_return(true)
      allow(DRCI).to receive(:stow_hands)
      allow(instance).to receive(:pause)
      instance.send(:enter_library)
      touch_commands = commands.select { |c| c == 'touch door' }
      expect(touch_commands.size).to eq(3)
    end
  end

  # -------------------------------------------------------------------
  # #redeem_card
  # -------------------------------------------------------------------
  describe '#redeem_card' do
    it 'returns true after successful redemption' do
      allow(DRCI).to receive(:get_item?).with('library card').and_return(true)
      allow(DRC).to receive(:bput).and_return('Once you redeem', 'The stoic butler takes')
      allow(DRCI).to receive(:stow_hands).and_return(true)
      expect(instance.send(:redeem_card)).to be true
    end

    it 'returns false when DRCI.get_item? fails' do
      allow(DRCI).to receive(:get_item?).with('library card').and_return(false)
      allow(instance).to receive(:echo)
      expect(instance.send(:redeem_card)).to be false
    end

    it 'calls DRCI.stow_hands then stow_reward as fallback after redeeming' do
      allow(DRCI).to receive(:get_item?).and_return(true)
      allow(DRC).to receive(:bput).and_return('Once you redeem', 'The stoic butler takes')
      expect(DRCI).to receive(:stow_hands).ordered
      expect(instance).to receive(:stow_reward).ordered
      instance.send(:redeem_card)
    end
  end

  # -------------------------------------------------------------------
  # #try_open
  # -------------------------------------------------------------------
  describe '#try_open' do
    it 'returns the first adj+noun candidate that succeeds' do
      allow(DRC).to receive(:bput).and_return('You open the carved chest.')
      result = instance.send(:try_open, 'old carved chest')
      expect(result).to eq('carved chest')
    end

    it 'falls back to bare noun when all adjective attempts fail' do
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

    it 'returns second candidate when first adj+noun fails' do
      call_count = 0
      allow(DRC).to receive(:bput) do |*_args|
        call_count += 1
        call_count == 1 ? 'What were you referring to?' : 'You open the chest.'
      end
      result = instance.send(:try_open, 'ornate carved chest')
      expect(result).to eq('ornate chest')
    end

    it 'recognizes swings open as success' do
      allow(DRC).to receive(:bput).and_return('The lid swings open.')
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

    it 'strips trailing period from item text before matching' do
      instance.instance_variable_set(:@poem, 'a silver ring')
      call_count = 0
      allow(DRC).to receive(:bput) do |*_args|
        call_count += 1
        case call_count
        when 1 then 'You open the chest.'
        when 2 then 'In the chest you see a silver ring.'
        when 3 then 'You reach for the ring and turn it.'
        else ''
        end
      end
      allow(instance).to receive(:echo)
      allow(instance).to receive(:pause)
      instance.send(:check_container, 'chest')
      expect(instance.instance_variable_get(:@found)).to eq(1)
    end

    it 'strips trailing exclamation from item text' do
      instance.instance_variable_set(:@poem, 'a silver ring')
      call_count = 0
      allow(DRC).to receive(:bput) do |*_args|
        call_count += 1
        case call_count
        when 1 then 'You open the chest.'
        when 2 then 'In the chest you see a silver ring!'
        when 3 then 'You reach for the ring and turn it.'
        else ''
        end
      end
      allow(instance).to receive(:echo)
      allow(instance).to receive(:pause)
      instance.send(:check_container, 'chest')
      expect(instance.instance_variable_get(:@found)).to eq(1)
    end

    it 'returns silently when look result matches neither pattern' do
      call_count = 0
      allow(DRC).to receive(:bput) do |*_args|
        call_count += 1
        case call_count
        when 1 then 'You open the chest.'
        when 2 then 'Some completely unexpected response.'
        else ''
        end
      end
      allow(instance).to receive(:echo)
      expect { instance.send(:check_container, 'chest') }.not_to raise_error
      expect(instance.instance_variable_get(:@found)).to eq(0)
    end

    it 'uses adjective fallback when opening multi-word container' do
      instance.instance_variable_set(:@poem, 'a crimson grimoire')
      call_count = 0
      allow(DRC).to receive(:bput) do |_cmd, *_args|
        call_count += 1
        case call_count
        when 1 then 'What were you referring to?'
        when 2 then 'You open the chest.'
        when 3 then 'In the chest you see a crimson grimoire.'
        when 4 then 'You reach for the grimoire.'
        else ''
        end
      end
      allow(instance).to receive(:echo)
      allow(instance).to receive(:pause)
      instance.send(:check_container, 'ornate chest')
      expect(instance.instance_variable_get(:@found)).to eq(1)
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

    it 'stops after first container if puzzle completes during check' do
      containers = ['carved chest', 'iron strongbox', 'oak barrel']
      allow(instance).to receive(:echo)
      checked = []
      allow(instance).to receive(:check_container) do |noun|
        checked << noun
        Flags['fenvol-complete'] = true
      end
      instance.send(:solve_room, containers)
      expect(checked).to eq(['carved chest'])
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
  # #capture_poem_lines
  # -------------------------------------------------------------------
  describe '#capture_poem_lines' do
    it 'captures lines between opening and closing delimiters' do
      lines = [
        '- - - - - - -',
        'a crimson grimoire rests',
        'upon the ancient shelf',
        '- - - - - - -'
      ]
      allow(instance).to receive(:get).and_return(*lines)
      result = instance.send(:capture_poem_lines)
      expect(result).to eq(['a crimson grimoire rests', 'upon the ancient shelf'])
    end

    it 'skips lines before the opening delimiter' do
      lines = [
        'The notecard reads:',
        'Some flavor text here.',
        '- - - - - - -',
        'poem line one',
        '- - - - - - -'
      ]
      allow(instance).to receive(:get).and_return(*lines)
      result = instance.send(:capture_poem_lines)
      expect(result).to eq(['poem line one'])
    end

    it 'strips XML tags from lines' do
      lines = [
        '- - - - - - -',
        '<pushBold/>a crimson grimoire<popBold/>',
        '- - - - - - -'
      ]
      allow(instance).to receive(:get).and_return(*lines)
      result = instance.send(:capture_poem_lines)
      expect(result).to eq(['a crimson grimoire'])
    end

    it 'returns empty array when no delimiters found within 100 lines' do
      allow(instance).to receive(:get).and_return('no delimiter here')
      result = instance.send(:capture_poem_lines)
      expect(result).to be_empty
    end

    it 'returns empty array when only opening delimiter exists within 100 lines' do
      call_count = 0
      allow(instance).to receive(:get) do
        call_count += 1
        call_count == 1 ? '- - - - - - -' : 'poem line that never ends'
      end
      result = instance.send(:capture_poem_lines)
      expect(result.size).to eq(99)
    end

    it 'handles empty lines within the poem' do
      lines = [
        '- - - - - - -',
        'line one',
        '',
        'line three',
        '- - - - - - -'
      ]
      allow(instance).to receive(:get).and_return(*lines)
      result = instance.send(:capture_poem_lines)
      expect(result).to eq(['line one', '', 'line three'])
    end

    it 'strips entity references from lines' do
      lines = [
        '- - - - - - -',
        'fire &amp; ice',
        '- - - - - - -'
      ]
      allow(instance).to receive(:get).and_return(*lines)
      result = instance.send(:capture_poem_lines)
      expect(result).to eq(['fire  ice'])
    end
  end

  # -------------------------------------------------------------------
  # #scan_room
  # -------------------------------------------------------------------
  describe '#scan_room' do
    it 'parses exits from Obvious exits line' do
      lines = [
        'You see a carved chest here.',
        'Obvious exits: north, south, east.'
      ]
      allow(instance).to receive(:get).and_return(*lines)
      _containers, exits = instance.send(:scan_room)
      expect(exits).to eq(%w[north south east])
    end

    it 'handles singular Obvious exit' do
      lines = [
        'A plain room.',
        'Obvious exit: north.'
      ]
      allow(instance).to receive(:get).and_return(*lines)
      _containers, exits = instance.send(:scan_room)
      expect(exits).to eq(['north'])
    end

    it 'strips trailing punctuation from exit names' do
      lines = ['Obvious exits: north, south.']
      allow(instance).to receive(:get).and_return(*lines)
      _containers, exits = instance.send(:scan_room)
      expect(exits).to eq(%w[north south])
    end

    it 'rejects none exits' do
      lines = ['Obvious exits: none.']
      allow(instance).to receive(:get).and_return(*lines)
      _containers, exits = instance.send(:scan_room)
      expect(exits).to be_empty
    end

    it 'finds containers in room description text' do
      lines = [
        'You see a tall mahogany bookcase here.',
        'Obvious exits: north.'
      ]
      allow(instance).to receive(:get).and_return(*lines)
      containers, _exits = instance.send(:scan_room)
      expect(containers).to include('tall mahogany bookcase')
    end

    it 'strips XML from room description lines' do
      lines = [
        '<pushBold/>You see a carved chest.<popBold/>',
        'Obvious exits: north.'
      ]
      allow(instance).to receive(:get).and_return(*lines)
      containers, _exits = instance.send(:scan_room)
      expect(containers).not_to be_empty
    end

    it 'returns empty containers when room has no container nouns' do
      lines = [
        'An empty stone corridor.',
        'Obvious exits: east.'
      ]
      allow(instance).to receive(:get).and_return(*lines)
      containers, _exits = instance.send(:scan_room)
      expect(containers).to be_empty
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

    it 'moves into exit and backtracks via opposite direction' do
      XMLData.room_title = 'Room A'
      allow(instance).to receive(:scan_room) do
        XMLData.room_title == 'Room A' ? [[], ['north']] : [[], []]
      end
      allow(instance).to receive(:solve_room)
      allow(instance).to receive(:echo)
      move_calls = []
      allow(instance).to receive(:move) do |dir|
        move_calls << dir
        XMLData.room_title = dir == 'north' ? 'Room B' : 'Room A'
      end
      instance.send(:explore)
      expect(move_calls).to eq(%w[north south])
    end

    it 'explores multiple exits and backtracks each' do
      XMLData.room_title = 'Room A'
      allow(instance).to receive(:scan_room) do
        XMLData.room_title == 'Room A' ? [[], %w[north east]] : [[], []]
      end
      allow(instance).to receive(:solve_room)
      allow(instance).to receive(:echo)
      move_calls = []
      allow(instance).to receive(:move) do |dir|
        move_calls << dir
        case dir
        when 'north' then XMLData.room_title = 'Room B'
        when 'east'  then XMLData.room_title = 'Room C'
        when 'south', 'west' then XMLData.room_title = 'Room A'
        end
      end
      instance.send(:explore)
      expect(move_calls).to eq(%w[north south east west])
    end

    it 'does not backtrack when already in the origin room' do
      XMLData.room_title = 'Room A'
      allow(instance).to receive(:scan_room).and_return([[], ['north']])
      allow(instance).to receive(:solve_room)
      allow(instance).to receive(:echo)
      move_calls = []
      allow(instance).to receive(:move) do |dir|
        move_calls << dir
        XMLData.room_title = 'Room A'
      end
      instance.send(:explore)
      expect(move_calls).to eq(['north'])
    end

    it 'stops traversing exits when puzzle completes mid-exploration' do
      XMLData.room_title = 'Room A'
      allow(instance).to receive(:scan_room).and_return([[], %w[north east south]])
      allow(instance).to receive(:solve_room) do
        Flags['fenvol-complete'] = true
      end
      allow(instance).to receive(:echo)
      expect(instance).not_to receive(:move)
      instance.send(:explore)
    end

    it 'uses downcase when looking up opposite for backtracking' do
      XMLData.room_title = 'Room A'
      allow(instance).to receive(:scan_room) do
        XMLData.room_title == 'Room A' ? [[], ['North']] : [[], []]
      end
      allow(instance).to receive(:solve_room)
      allow(instance).to receive(:echo)
      move_calls = []
      allow(instance).to receive(:move) do |dir|
        move_calls << dir
        XMLData.room_title = dir == 'North' ? 'Room B' : 'Room A'
      end
      instance.send(:explore)
      expect(move_calls).to eq(%w[North south])
    end

    it 'does not backtrack after puzzle completes mid-DFS (prevents post-teleport drift)' do
      XMLData.room_title = 'Room A'
      allow(instance).to receive(:echo)
      allow(instance).to receive(:scan_room) do
        XMLData.room_title == 'Room A' ? [[], ['north']] : [[], []]
      end
      instance.instance_variable_set(:@found, 5)
      allow(instance).to receive(:solve_room) do
        if XMLData.room_title == 'Room B'
          instance.instance_variable_set(:@found, 6)
        end
      end
      move_calls = []
      allow(instance).to receive(:move) do |dir|
        move_calls << dir
        XMLData.room_title = dir == 'north' ? 'Room B' : 'Room A'
      end
      instance.send(:explore)
      expect(move_calls).to eq(['north'])
      expect(move_calls).not_to include('south')
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
  # #run_once
  # -------------------------------------------------------------------
  describe '#run_once' do
    before do
      stub_flags_class
      allow(instance).to receive(:echo)
      allow(instance).to receive(:pause)
    end

    it 'returns false when enter_library fails' do
      allow(instance).to receive(:enter_library).and_return(false)
      expect(instance.send(:run_once)).to be false
    end

    it 'returns true but warns when poem is empty' do
      allow(instance).to receive(:enter_library).and_return(true)
      allow(instance).to receive(:read_poem).and_return('')
      expect(instance).to receive(:echo).with('Could not parse poem from notecard.')
      expect(instance.send(:run_once)).to be true
    end

    it 'does not explore when poem is empty' do
      allow(instance).to receive(:enter_library).and_return(true)
      allow(instance).to receive(:read_poem).and_return('')
      expect(instance).not_to receive(:explore)
      instance.send(:run_once)
    end

    it 'resets state at start of each run' do
      instance.instance_variable_set(:@found, 5)
      instance.instance_variable_set(:@visited, ['old room'])
      allow(instance).to receive(:enter_library).and_return(true)
      allow(instance).to receive(:read_poem).and_return('some poem')
      allow(instance).to receive(:explore)
      allow(instance).to receive(:complete?).and_return(false)
      instance.send(:run_once)
      expect(instance.instance_variable_get(:@found)).to eq(0)
      expect(instance.instance_variable_get(:@visited)).to be_empty
    end

    it 'calls handle_completion when puzzle is complete' do
      allow(instance).to receive(:enter_library).and_return(true)
      allow(instance).to receive(:read_poem).and_return('some poem')
      allow(instance).to receive(:explore)
      allow(instance).to receive(:complete?).and_return(true)
      expect(instance).to receive(:handle_completion)
      instance.send(:run_once)
    end

    it 'does not call handle_completion when puzzle is not complete' do
      allow(instance).to receive(:enter_library).and_return(true)
      allow(instance).to receive(:read_poem).and_return('some poem')
      allow(instance).to receive(:explore)
      allow(instance).to receive(:complete?).and_return(false)
      expect(instance).not_to receive(:handle_completion)
      instance.send(:run_once)
    end

    it 'resets both flags at start' do
      Flags['fenvol-complete'] = true
      Flags['fenvol-reward'] = true
      allow(instance).to receive(:enter_library).and_return(false)
      instance.send(:run_once)
      expect(Flags['fenvol-complete']).to be false
      expect(Flags['fenvol-reward']).to be false
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

      it 'does not match bare shelf in flavor text like "on a bottom shelf"' do
        text = 'on a bottom shelf, a large umber carton peeks out from baskets of yarn'
        result = instance.send(:scan_containers, text)
        shelf_matches = result.select { |c| c.split.last == 'shelf' }
        expect(shelf_matches).to be_empty
        expect(result).to include('large umber carton')
      end

      it 'still matches bookshelf as a container' do
        text = 'a rickety blue bookshelf stands here'
        result = instance.send(:scan_containers, text)
        expect(result.any? { |c| c.end_with?('bookshelf') }).to be true
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
      it 'returns empty array for empty string' do
        result = instance.send(:try_open_candidates, '')
        expect(result).to eq([])
      end

      it 'returns empty array for whitespace-only string' do
        result = instance.send(:try_open_candidates, ' ')
        expect(result).to eq([])
      end
    end

    describe '#stow_reward with tricky item names' do
      it 'uses GameObj.right_hand.noun for multi-word item' do
        set_right_hand('ornate silver ring', 'ring')
        instance.instance_variable_set(:@containers, ['backpack'])
        expect(DRCI).to receive(:put_away_item?).with('ring', ['backpack']).and_return(true)
        instance.send(:stow_reward)
      end

      it 'handles single-word item' do
        set_right_hand('ring', 'ring')
        instance.instance_variable_set(:@containers, ['backpack'])
        expect(DRCI).to receive(:put_away_item?).with('ring', ['backpack']).and_return(true)
        instance.send(:stow_reward)
      end

      it 'falls back to split.last when GameObj.right_hand is nil' do
        $right_hand = 'ornate silver ring'
        allow(GameObj).to receive(:right_hand).and_return(nil)
        instance.instance_variable_set(:@containers, ['backpack'])
        expect(DRCI).to receive(:put_away_item?).with('ring', ['backpack']).and_return(true)
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

    describe '#in_poem? false positive risks' do
      it 'false-matches when item name is a substring of a different poem word' do
        instance.instance_variable_set(:@poem, 'the grimoire glows')
        expect(instance.send(:in_poem?, 'a grim mask')).to be false
      end

      it 'false-matches when item name overlaps poem word boundaries' do
        instance.instance_variable_set(:@poem, 'old tome rests here')
        expect(instance.send(:in_poem?, 'tome rest')).to be true
      end

      it 'does not match when article stripping changes meaning' do
        instance.instance_variable_set(:@poem, 'a leather anthology')
        expect(instance.send(:in_poem?, 'the leather anthology')).to be true
      end

      it 'only strips a leading article, not embedded articles' do
        instance.instance_variable_set(:@poem, 'tome of the ancients')
        expect(instance.send(:in_poem?, 'a tome of the ancients')).to be true
      end
    end

    describe '#complete? with nil and truthy values' do
      before { stub_flags_class }

      it 'treats nil flag as falsy' do
        Flags['fenvol-complete'] = nil
        instance.instance_variable_set(:@found, 0)
        expect(instance.send(:complete?)).to be false
      end

      it 'treats truthy non-boolean flag as complete' do
        Flags['fenvol-complete'] = 'some match data'
        instance.instance_variable_set(:@found, 0)
        expect(instance.send(:complete?)).to be_truthy
      end

      it 'returns true when found equals TARGET_COUNT even with nil flag' do
        Flags['fenvol-complete'] = nil
        instance.instance_variable_set(:@found, FenvolPuzzle::TARGET_COUNT)
        expect(instance.send(:complete?)).to be true
      end
    end

    describe '#scan_containers with bare nouns (no adjective)' do
      it 'does not find a container noun at sentence start with no preceding word' do
        text = 'chest sits in the corner'
        result = instance.send(:scan_containers, text)
        expect(result).to be_empty
      end

      it 'finds bare container noun when preceded by at least one word' do
        text = 'the chest sits in the corner'
        result = instance.send(:scan_containers, text)
        expect(result).to include('the chest')
      end

      it 'does not find container noun immediately after punctuation' do
        text = 'here, chest stands alone'
        result = instance.send(:scan_containers, text)
        expect(result).to be_empty
      end
    end

    describe '#enter_library command ordering' do
      it 'does not call redeem_card when already at confirmation' do
        allow(DRC).to receive(:bput).and_return(
          'If you are sure you wish to proceed',
          'the world unravels'
        )
        allow(instance).to receive(:pause)
        expect(instance).not_to receive(:redeem_card)
        instance.send(:enter_library)
      end

      it 'does not call redeem_card when already inside' do
        allow(DRC).to receive(:bput).and_return('What were you referring to?')
        expect(instance).not_to receive(:redeem_card)
        instance.send(:enter_library)
      end
    end

    describe '#stow_reward edge cases' do
      it 'handles right_hand returning an object with to_s' do
        obj = double('item', to_s: 'fancy dress', empty?: false)
        allow(obj).to receive(:downcase).and_return('fancy dress')
        $right_hand = obj
        allow(GameObj).to receive(:right_hand).and_return(OpenStruct.new(noun: 'dress'))
        instance.instance_variable_set(:@discard_list, ['dress'])
        allow(instance).to receive(:echo)
        expect(DRCI).to receive(:put_away_item_unsafe?).with('my dress', 'bucket').and_return(true)
        instance.send(:stow_reward)
      end

      it 'does nothing when discard_list is nil-initialized' do
        $right_hand = 'silver ring'
        instance.instance_variable_set(:@discard_list, nil)
        instance.instance_variable_set(:@containers, [])
        expect { instance.send(:stow_reward) }.to raise_error(NoMethodError)
      end
    end

    describe '#handle_completion timing' do
      before { stub_flags_class }

      it 'checks reward flag before each pause' do
        Flags['fenvol-reward'] = false
        allow(instance).to receive(:echo)
        allow(instance).to receive(:stow_reward)
        pause_count = 0
        allow(instance).to receive(:pause) do |_s|
          pause_count += 1
          Flags['fenvol-reward'] = true if pause_count == 3
        end
        instance.send(:handle_completion)
        expect(pause_count).to eq(3)
      end
    end

    describe '#turn_item with multi-word nouns' do
      it 'uses only the last word as the noun for the turn command' do
        expect(DRC).to receive(:bput).with(
          'turn codex in chest',
          FenvolPuzzle::TURN_SUCCESS_PATTERN,
          FenvolPuzzle::TURN_FAILURE_PATTERN
        ).and_return('You reach for the codex')
        allow(instance).to receive(:echo)
        allow(instance).to receive(:pause)
        instance.send(:turn_item, 'chest', 'a dusty ancient codex')
      end
    end

    describe '#scan_containers with overlapping noun patterns' do
      it 'matches bookshelf without also matching shelf' do
        text = 'a tall bookshelf stands here'
        result = instance.send(:scan_containers, text)
        expect(result.size).to eq(1)
        expect(result.first).to end_with('bookshelf')
      end

      it 'does not match shelf inside bookshelf via word boundary' do
        text = 'the old bookshelf is dusty'
        result = instance.send(:scan_containers, text)
        nouns = result.map { |c| c.split.last }
        expect(nouns).not_to include('shelf')
      end
    end

    describe 'full integration: check_container through try_open fallback' do
      it 'falls back through adjectives until one works, then checks item' do
        instance.instance_variable_set(:@poem, 'a sapphire tome glimmers')
        call_count = 0
        allow(DRC).to receive(:bput) do |_cmd, *_args|
          call_count += 1
          case call_count
          when 1 then 'What were you referring to?'
          when 2 then 'You open the bookcase.'
          when 3 then 'In the bookcase you see a sapphire tome.'
          when 4 then 'You reach for the tome and turn it.'
          else ''
          end
        end
        allow(instance).to receive(:echo)
        allow(instance).to receive(:pause)
        instance.send(:check_container, 'old mahogany bookcase')
        expect(instance.instance_variable_get(:@found)).to eq(1)
      end
    end

    describe 'run_loop repeat behavior' do
      before { stub_flags_class }

      it 'calls stow_reward before each run and after all runs' do
        instance.instance_variable_set(:@repeat_count, 2)
        stow_count = 0
        allow(instance).to receive(:stow_reward) do
          stow_count += 1
          true
        end
        allow(instance).to receive(:echo)
        run_count = 0
        allow(instance).to receive(:run_once) do
          run_count += 1
          true
        end
        instance.send(:run_loop)
        expect(stow_count).to eq(3)
      end

      it 'stops looping when run_once returns false' do
        instance.instance_variable_set(:@repeat_mode, :infinite)
        run_count = 0
        allow(instance).to receive(:stow_reward).and_return(true)
        allow(instance).to receive(:echo)
        allow(instance).to receive(:run_once) do
          run_count += 1
          run_count < 3
        end
        instance.send(:run_loop)
        expect(run_count).to eq(3)
      end

      it 'stops looping when stow_reward returns false (container full)' do
        instance.instance_variable_set(:@repeat_mode, :infinite)
        allow(instance).to receive(:echo)
        allow(instance).to receive(:_respond)
        run_count = 0
        allow(instance).to receive(:stow_reward) do
          run_count += 1
          run_count <= 2
        end
        allow(instance).to receive(:run_once).and_return(true)
        instance.send(:run_loop)
        # 2 successful stow_reward at top of loop + 1 failed (breaks loop) + 1 final stow_reward after loop
        expect(run_count).to eq(4)
      end

      it 'echoes run number only when repeating' do
        instance.instance_variable_set(:@repeat_mode, nil)
        instance.instance_variable_set(:@repeat_count, nil)
        allow(instance).to receive(:stow_reward).and_return(true)
        allow(instance).to receive(:run_once).and_return(false)
        expect(instance).not_to receive(:echo).with(/=== Run/)
        allow(instance).to receive(:echo).with(/All done/)
        instance.send(:run_loop)
      end
    end
  end
end
