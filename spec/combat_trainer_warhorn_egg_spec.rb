# frozen_string_literal: true

require 'ostruct'

load File.join(File.dirname(__FILE__), '..', 'test', 'test_harness.rb')
include Harness

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
  class << self
    def right_hand
      $right_hand
    end

    def left_hand
      $left_hand
    end

    def bput(*_args)
      'Roundtime'
    end

    def message(*_args); end

    def retreat; end
  end
end

module DRCI
  class << self
    def get_item?(*_args)
      true
    end

    def stow_item?(*_args)
      true
    end

    def remove_item?(*_args)
      true
    end

    def wear_item?(*_args)
      true
    end

    def wearing?(*_args)
      false
    end
  end
end

module UserVars
  class << self
    attr_accessor :warhorn
  end
  self.warhorn = {}
end unless defined?(UserVars)

$debug_mode_ct = false

load_lic_class('combat-trainer.lic', 'AbilityProcess')

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end
end

# Build an AbilityProcess via allocate to bypass initialize (avoids game I/O).
def build_ability_process(**overrides)
  instance = AbilityProcess.allocate
  defaults = {
    warhorn_nouns: [],
    egg_count: 0,
    warhorn_or_egg: [],
    warhorn_items: [],
    egg_ids: [],
    item_cooldowns: {},
    warhorn_cooldown: 1200
  }
  defaults.merge(overrides).each do |k, v|
    instance.instance_variable_set(:"@#{k}", v)
  end
  instance
end

def build_game_state(**attrs)
  defaults = {
    currently_whirlwinding: false
  }
  state = double('GameState', defaults.merge(attrs))
  allow(state).to receive(:sheath_whirlwind_offhand)
  allow(state).to receive(:wield_whirlwind_offhand)
  state
end

def stub_right_hand_with_id(id)
  hand = OpenStruct.new(name: 'item', noun: 'item', id: id)
  allow(GameObj).to receive(:right_hand).and_return(hand)
end

# ===========================================================================
# AbilityProcess warhorn/egg discovery and usage
# ===========================================================================
RSpec.describe AbilityProcess do
  before(:each) do
    allow(DRC).to receive(:bput).and_return('Roundtime')
    allow(DRC).to receive(:message)
  end

  # ===========================================================================
  # #discover_egg
  # ===========================================================================
  describe '#discover_egg' do
    it 'records the game ID when egg is found' do
      instance = build_ability_process
      stub_right_hand_with_id('12345')
      allow(DRCI).to receive(:get_item?).with('egg').and_return(true)
      allow(DRCI).to receive(:stow_item?).and_return(true)

      instance.send(:discover_egg, 'egg')

      expect(instance.instance_variable_get(:@egg_ids)).to eq(['12345'])
    end

    it 'stows by game ID after discovery' do
      instance = build_ability_process
      stub_right_hand_with_id('12345')
      allow(DRCI).to receive(:get_item?).with('egg').and_return(true)
      allow(DRCI).to receive(:stow_item?).and_return(true)

      instance.send(:discover_egg, 'egg')

      expect(DRCI).to have_received(:stow_item?).with('#12345')
    end

    it 'warns and does not record when egg is not found' do
      instance = build_ability_process
      allow(DRCI).to receive(:get_item?).with('second egg').and_return(false)

      instance.send(:discover_egg, 'second egg')

      expect(instance.instance_variable_get(:@egg_ids)).to be_empty
      expect(DRC).to have_received(:message).with(/Could not find 'second egg'/)
    end
  end

  # ===========================================================================
  # #discover_warhorn
  # ===========================================================================
  describe '#discover_warhorn' do
    it 'records worn warhorn when remove succeeds' do
      instance = build_ability_process
      stub_right_hand_with_id('99')
      allow(DRCI).to receive(:remove_item?).with('warhorn').and_return(true)
      allow(DRCI).to receive(:wear_item?).and_return(true)

      instance.send(:discover_warhorn, 'warhorn')

      items = instance.instance_variable_get(:@warhorn_items)
      expect(items).to eq([{ id: '99', worn: true }])
    end

    it 're-wears a worn warhorn after discovery' do
      instance = build_ability_process
      stub_right_hand_with_id('99')
      allow(DRCI).to receive(:remove_item?).with('warhorn').and_return(true)
      allow(DRCI).to receive(:wear_item?).and_return(true)

      instance.send(:discover_warhorn, 'warhorn')

      expect(DRCI).to have_received(:wear_item?).with('#99')
    end

    it 'records stowed warhorn when remove fails but get succeeds' do
      instance = build_ability_process
      stub_right_hand_with_id('50')
      allow(DRCI).to receive(:remove_item?).with('horn').and_return(false)
      allow(DRCI).to receive(:get_item?).with('horn').and_return(true)
      allow(DRCI).to receive(:stow_item?).and_return(true)

      instance.send(:discover_warhorn, 'horn')

      items = instance.instance_variable_get(:@warhorn_items)
      expect(items).to eq([{ id: '50', worn: false }])
    end

    it 'warns when warhorn is not found at all' do
      instance = build_ability_process
      allow(DRCI).to receive(:remove_item?).with('horn').and_return(false)
      allow(DRCI).to receive(:get_item?).with('horn').and_return(false)

      instance.send(:discover_warhorn, 'horn')

      expect(instance.instance_variable_get(:@warhorn_items)).to be_empty
      expect(DRC).to have_received(:message).with(/Could not find warhorn 'horn'/)
    end
  end

  # ===========================================================================
  # #set_warhorn_or_egg
  # ===========================================================================
  describe '#set_warhorn_or_egg' do
    it 'builds rotation with both egg and warhorn when both are found' do
      instance = build_ability_process(egg_count: 1, warhorn_nouns: ['warhorn'])
      stub_right_hand_with_id('10')
      allow(DRCI).to receive(:get_item?).and_return(true)
      allow(DRCI).to receive(:stow_item?).and_return(true)
      allow(DRCI).to receive(:remove_item?).and_return(true)
      allow(DRCI).to receive(:wear_item?).and_return(true)

      instance.send(:set_warhorn_or_egg)

      expect(instance.instance_variable_get(:@warhorn_or_egg)).to eq(%w[egg warhorn])
    end

    it 'builds rotation with only egg when no warhorns configured' do
      instance = build_ability_process(egg_count: 1, warhorn_nouns: [])
      stub_right_hand_with_id('10')
      allow(DRCI).to receive(:get_item?).and_return(true)
      allow(DRCI).to receive(:stow_item?).and_return(true)

      instance.send(:set_warhorn_or_egg)

      expect(instance.instance_variable_get(:@warhorn_or_egg)).to eq(['egg'])
    end

    it 'warns when no items are found at all' do
      instance = build_ability_process(egg_count: 1, warhorn_nouns: ['warhorn'])
      allow(DRCI).to receive(:get_item?).and_return(false)
      allow(DRCI).to receive(:remove_item?).and_return(false)

      instance.send(:set_warhorn_or_egg)

      expect(instance.instance_variable_get(:@warhorn_or_egg)).to be_empty
      expect(DRC).to have_received(:message).with(/No eggs or warhorns found/)
    end

    it 'warns when fewer eggs found than configured' do
      call_count = 0
      instance = build_ability_process(egg_count: 2, warhorn_nouns: [])
      allow(DRCI).to receive(:get_item?) do |_arg|
        call_count += 1
        if call_count == 1
          stub_right_hand_with_id('10')
          true
        else
          false
        end
      end
      allow(DRCI).to receive(:stow_item?).and_return(true)

      instance.send(:set_warhorn_or_egg)

      expect(DRC).to have_received(:message).with(/wanted 2 egg.*only found 1/)
    end
  end

  # ===========================================================================
  # #use_warhorn_or_egg -- room effect gate
  # ===========================================================================
  describe '#use_warhorn_or_egg' do
    it 'skips when room effect is still active (< 600s)' do
      UserVars.warhorn = { "last_warhorn_or_egg" => Time.now - 300 }
      instance = build_ability_process(warhorn_or_egg: ['egg'], egg_ids: ['10'])
      game_state = build_game_state

      instance.send(:use_warhorn_or_egg, game_state)

      expect(DRC).not_to have_received(:bput).with(/invoke/, anything, anything, anything, anything, anything)
    end

    it 'attempts use when room effect has expired (>= 600s)' do
      UserVars.warhorn = { "last_warhorn_or_egg" => Time.now - 601 }
      instance = build_ability_process(
        warhorn_or_egg: ['egg'],
        egg_ids: ['10'],
        item_cooldowns: {}
      )
      game_state = build_game_state
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('light envelops the area briefly')

      instance.send(:use_warhorn_or_egg, game_state)

      expect(DRC).to have_received(:bput).with("invoke #10", anything, anything, anything, anything, anything)
    end

    it 'rotates the type after each call' do
      UserVars.warhorn = { "last_warhorn_or_egg" => Time.now - 601 }
      instance = build_ability_process(
        warhorn_or_egg: %w[egg warhorn],
        egg_ids: ['10'],
        warhorn_items: [{ id: '20', worn: false }],
        item_cooldowns: {}
      )
      game_state = build_game_state
      allow(DRC).to receive(:bput).and_return('light envelops the area briefly')

      instance.send(:use_warhorn_or_egg, game_state)

      expect(instance.instance_variable_get(:@warhorn_or_egg)).to eq(%w[warhorn egg])
    end
  end

  # ===========================================================================
  # #use_egg? -- per-item cooldown and error handling
  # ===========================================================================
  describe '#use_egg?' do
    it 'returns true on successful invocation' do
      instance = build_ability_process(egg_ids: ['10'], item_cooldowns: {})
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('light envelops the area briefly')

      expect(instance.send(:use_egg?)).to be true
    end

    it 'records cooldown timestamp on success' do
      instance = build_ability_process(egg_ids: ['10'], item_cooldowns: {})
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('light envelops the area briefly')

      instance.send(:use_egg?)

      cooldowns = instance.instance_variable_get(:@item_cooldowns)
      expect(cooldowns['10']).to be_within(2).of(Time.now)
    end

    it 'skips egg on cooldown and tries the next one' do
      instance = build_ability_process(
        egg_ids: %w[10 20],
        item_cooldowns: { '10' => Time.now }
      )
      allow(DRC).to receive(:bput).with("invoke #20", anything, anything, anything, anything, anything)
                                  .and_return('light envelops the area briefly')

      expect(instance.send(:use_egg?)).to be true
      expect(DRC).not_to have_received(:bput).with("invoke #10", anything, anything, anything, anything, anything)
    end

    it 'returns false and removes egg type when area inhibits' do
      rotation = %w[egg warhorn]
      instance = build_ability_process(
        egg_ids: ['10'],
        item_cooldowns: {},
        warhorn_or_egg: rotation
      )
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('Something about the area inhibits')

      result = instance.send(:use_egg?)

      expect(result).to be false
      expect(rotation).not_to include('egg')
    end

    it 'removes a missing egg from the list and tries remaining' do
      instance = build_ability_process(
        egg_ids: %w[10 20],
        item_cooldowns: {},
        warhorn_or_egg: ['egg']
      )
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('Invoke what?')
      allow(DRC).to receive(:bput).with("invoke #20", anything, anything, anything, anything, anything)
                                  .and_return('light envelops the area briefly')

      expect(instance.send(:use_egg?)).to be true
      expect(instance.instance_variable_get(:@egg_ids)).to eq(['20'])
    end

    it 'returns false when all eggs are missing' do
      instance = build_ability_process(
        egg_ids: ['10'],
        item_cooldowns: {},
        warhorn_or_egg: ['egg']
      )
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('Invoke what?')

      expect(instance.send(:use_egg?)).to be false
    end

    it 'sets a 60s retry cooldown when egg is dim/sluggish' do
      instance = build_ability_process(egg_ids: ['10'], item_cooldowns: {})
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('The red light within the egg is dim and moves about sluggishly')

      instance.send(:use_egg?)

      cooldown = instance.instance_variable_get(:@item_cooldowns)['10']
      expect(cooldown).to be_within(2).of(Time.now - 900 + 60)
    end

    it 'returns false when hidden and cannot use egg' do
      instance = build_ability_process(egg_ids: ['10'], item_cooldowns: {})
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('You cannot stay hidden while using the egg.')

      expect(instance.send(:use_egg?)).to be false
    end

    it 'returns false when egg_ids is empty' do
      instance = build_ability_process(egg_ids: [], item_cooldowns: {})

      expect(instance.send(:use_egg?)).to be false
    end

    it 'returns false when all eggs are on cooldown' do
      instance = build_ability_process(
        egg_ids: %w[10 20],
        item_cooldowns: { '10' => Time.now, '20' => Time.now }
      )

      expect(instance.send(:use_egg?)).to be false
    end
  end

  # ===========================================================================
  # #use_warhorn? -- per-item cooldown and error handling
  # ===========================================================================
  describe '#use_warhorn?' do
    let(:game_state) { build_game_state }

    it 'returns true on successful exhale' do
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: false }],
        item_cooldowns: {}
      )
      allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                  .and_return('You get a silver warhorn.')
      allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                  .and_return('You sound a series of bursts from the')
      allow(instance).to receive(:waitrt?)
      allow(DRC).to receive(:bput).with("stow #20", anything, anything, anything, anything)
                                  .and_return('You put')

      expect(instance.send(:use_warhorn?, game_state)).to be true
    end

    it 'uses remove verb for worn warhorns' do
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: true }],
        item_cooldowns: {}
      )
      allow(DRC).to receive(:bput).with("remove #20", anything, anything, anything, anything, anything, anything)
                                  .and_return('You remove a silver warhorn.')
      allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                  .and_return('You sound a series of bursts from the')
      allow(instance).to receive(:waitrt?)
      allow(DRC).to receive(:bput).with("wear #20", anything, anything, anything, anything)
                                  .and_return('You attach')

      expect(instance.send(:use_warhorn?, game_state)).to be true
      expect(DRC).to have_received(:bput).with("remove #20", anything, anything, anything, anything, anything, anything)
    end

    it 'skips warhorn on cooldown and tries the next one' do
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: false }, { id: '30', worn: false }],
        item_cooldowns: { '20' => Time.now }
      )
      allow(DRC).to receive(:bput).with("get #30", anything, anything, anything, anything, anything, anything)
                                  .and_return('You get')
      allow(DRC).to receive(:bput).with("exhale #30 lure", anything, anything, anything, anything)
                                  .and_return('You sound a series of bursts from the')
      allow(instance).to receive(:waitrt?)
      allow(DRC).to receive(:bput).with("stow #30", anything, anything, anything, anything)
                                  .and_return('You put')

      expect(instance.send(:use_warhorn?, game_state)).to be true
      expect(DRC).not_to have_received(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
    end

    it 'sets a 60s retry cooldown when lungs are tired' do
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: false }],
        item_cooldowns: {},
        warhorn_cooldown: 1200
      )
      allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                  .and_return('You get')
      allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                  .and_return('Your lungs are tired from having sounded a')
      allow(DRC).to receive(:bput).with("stow #20", anything, anything, anything, anything)
                                  .and_return('You put')

      instance.send(:use_warhorn?, game_state)

      cooldown = instance.instance_variable_get(:@item_cooldowns)['20']
      expect(cooldown).to be_within(2).of(Time.now - 1200 + 60)
    end

    it 'returns false and removes warhorn type when area inhibits' do
      rotation = %w[warhorn egg]
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: false }],
        item_cooldowns: {},
        warhorn_or_egg: rotation
      )
      allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                  .and_return('You get')
      allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                  .and_return('Something about the area inhibits')
      allow(DRC).to receive(:bput).with("stow #20", anything, anything, anything, anything)
                                  .and_return('You put')

      result = instance.send(:use_warhorn?, game_state)

      expect(result).to be false
      expect(rotation).not_to include('warhorn')
    end

    it 'removes a missing warhorn from the list and tries remaining' do
      item1 = { id: '20', worn: false }
      item2 = { id: '30', worn: false }
      instance = build_ability_process(
        warhorn_items: [item1, item2],
        item_cooldowns: {}
      )
      allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                  .and_return('What were you referring to')
      allow(DRC).to receive(:bput).with("get #30", anything, anything, anything, anything, anything, anything)
                                  .and_return('You get')
      allow(DRC).to receive(:bput).with("exhale #30 lure", anything, anything, anything, anything)
                                  .and_return('You sound a series of bursts from the')
      allow(instance).to receive(:waitrt?)
      allow(DRC).to receive(:bput).with("stow #30", anything, anything, anything, anything)
                                  .and_return('You put')

      expect(instance.send(:use_warhorn?, game_state)).to be true
      expect(instance.instance_variable_get(:@warhorn_items)).not_to include(item1)
    end

    it 'returns false when hands are full' do
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: false }],
        item_cooldowns: {}
      )
      allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                  .and_return('You need a free hand')

      expect(instance.send(:use_warhorn?, game_state)).to be false
    end

    it 'returns false when all warhorns are on cooldown' do
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: false }, { id: '30', worn: false }],
        item_cooldowns: { '20' => Time.now, '30' => Time.now }
      )

      expect(instance.send(:use_warhorn?, game_state)).to be false
    end

    it 'returns false and removes warhorn type when player cannot use warhorns' do
      rotation = %w[warhorn egg]
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: false }],
        item_cooldowns: {},
        warhorn_or_egg: rotation
      )
      allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                  .and_return('You get')
      allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                  .and_return('not accomplishing much and looking rather silly')
      allow(DRC).to receive(:bput).with("stow #20", anything, anything, anything, anything)
                                  .and_return('You put')

      result = instance.send(:use_warhorn?, game_state)

      expect(result).to be false
      expect(rotation).not_to include('warhorn')
    end

    it 'wields whirlwind offhand when all warhorns exhausted' do
      instance = build_ability_process(
        warhorn_items: [],
        item_cooldowns: {}
      )

      instance.send(:use_warhorn?, game_state)

      expect(game_state).to have_received(:wield_whirlwind_offhand)
    end
  end

  # ===========================================================================
  # #stow_warhorn_item
  # ===========================================================================
  describe '#stow_warhorn_item' do
    it 'uses stow for non-worn items' do
      instance = build_ability_process
      allow(DRC).to receive(:bput).and_return('You put')

      instance.send(:stow_warhorn_item, { id: '20', worn: false })

      expect(DRC).to have_received(:bput).with('stow #20', anything, anything, anything, anything)
    end

    it 'uses wear for worn items' do
      instance = build_ability_process
      allow(DRC).to receive(:bput).and_return('You attach')

      instance.send(:stow_warhorn_item, { id: '20', worn: true })

      expect(DRC).to have_received(:bput).with('wear #20', anything, anything, anything, anything)
    end
  end

  # ===========================================================================
  # Bad YAML config parsing -- tests the case expressions in initialize
  # that produce @warhorn_nouns and @egg_count from raw settings values.
  #
  # We can't call initialize (needs full game I/O), so we replicate the
  # case expressions inline and verify the derived values fed to downstream
  # methods behave correctly.
  # ===========================================================================
  describe 'bad YAML config edge cases' do
    # Replicate the warhorn case expression from initialize
    def warhorn_nouns_from(raw)
      case raw
      when Array then raw
      when String then [raw]
      when true then ['warhorn']
      else []
      end
    end

    # Replicate the egg case expression from initialize
    def egg_count_from(raw)
      case raw
      when Integer then raw
      when true, String then 1
      else 0
      end
    end

    # Replicate the guard that decides whether to call set_warhorn_or_egg
    def should_setup?(nouns, count)
      !(nouns.empty? && count < 1)
    end

    # =========================================================================
    # warhorn config parsing
    # =========================================================================
    describe 'warhorn config parsing' do
      it 'treats integer 42 as no warhorns' do
        nouns = warhorn_nouns_from(42)
        expect(nouns).to eq([])
      end

      it 'treats false as no warhorns' do
        nouns = warhorn_nouns_from(false)
        expect(nouns).to eq([])
      end

      it 'treats nil as no warhorns' do
        nouns = warhorn_nouns_from(nil)
        expect(nouns).to eq([])
      end

      it 'wraps a single string in an array' do
        nouns = warhorn_nouns_from('silver warhorn')
        expect(nouns).to eq(['silver warhorn'])
      end

      it 'passes an array through unchanged' do
        nouns = warhorn_nouns_from(%w[warhorn horn])
        expect(nouns).to eq(%w[warhorn horn])
      end

      it 'treats true as default warhorn noun' do
        nouns = warhorn_nouns_from(true)
        expect(nouns).to eq(['warhorn'])
      end

      it 'passes an empty array through (no warhorns)' do
        nouns = warhorn_nouns_from([])
        expect(nouns).to eq([])
      end

      it 'passes an array with non-string elements through without filtering' do
        nouns = warhorn_nouns_from([true, 42, 'warhorn'])
        expect(nouns).to eq([true, 42, 'warhorn'])
      end
    end

    # =========================================================================
    # egg config parsing
    # =========================================================================
    describe 'egg config parsing' do
      it 'treats integer 0 as zero eggs' do
        expect(egg_count_from(0)).to eq(0)
      end

      it 'treats negative integer as negative count' do
        expect(egg_count_from(-1)).to eq(-1)
      end

      it 'treats integer 2 as two eggs' do
        expect(egg_count_from(2)).to eq(2)
      end

      it 'treats integer 3 as three (even though only 2 ordinals supported)' do
        expect(egg_count_from(3)).to eq(3)
      end

      it 'treats true as 1 egg' do
        expect(egg_count_from(true)).to eq(1)
      end

      it 'treats a string as 1 egg' do
        expect(egg_count_from('yes')).to eq(1)
      end

      it 'treats false as 0 eggs' do
        expect(egg_count_from(false)).to eq(0)
      end

      it 'treats nil as 0 eggs' do
        expect(egg_count_from(nil)).to eq(0)
      end

      it 'treats an array as 0 eggs' do
        expect(egg_count_from([1, 2])).to eq(0)
      end

      it 'treats a hash as 0 eggs' do
        expect(egg_count_from({ count: 2 })).to eq(0)
      end

      it 'treats float 1.5 as 0 eggs (not Integer)' do
        expect(egg_count_from(1.5)).to eq(0)
      end
    end

    # =========================================================================
    # setup guard -- should set_warhorn_or_egg be called?
    # =========================================================================
    describe 'setup guard' do
      it 'skips setup when both empty/zero' do
        expect(should_setup?([], 0)).to be false
      end

      it 'runs setup when warhorn nouns present but egg_count is 0' do
        expect(should_setup?(['warhorn'], 0)).to be true
      end

      it 'runs setup when egg_count is 1 but no warhorn nouns' do
        expect(should_setup?([], 1)).to be true
      end

      it 'runs setup when both present' do
        expect(should_setup?(['warhorn'], 2)).to be true
      end

      it 'runs setup when egg_count is negative (will discover 0 eggs)' do
        expect(should_setup?([], -1)).to be false
      end
    end

    # =========================================================================
    # set_warhorn_or_egg with bad config-derived values
    # =========================================================================
    describe 'set_warhorn_or_egg with degenerate configs' do
      it 'handles egg_count 0 with warhorn_nouns present (warhorn only)' do
        instance = build_ability_process(egg_count: 0, warhorn_nouns: ['warhorn'])
        stub_right_hand_with_id('10')
        allow(DRCI).to receive(:remove_item?).and_return(true)
        allow(DRCI).to receive(:wear_item?).and_return(true)

        instance.send(:set_warhorn_or_egg)

        expect(instance.instance_variable_get(:@warhorn_or_egg)).to eq(['warhorn'])
        expect(instance.instance_variable_get(:@egg_ids)).to be_empty
      end

      it 'handles warhorn_nouns with non-string elements gracefully' do
        instance = build_ability_process(egg_count: 0, warhorn_nouns: [true, 42])
        allow(DRCI).to receive(:remove_item?).and_return(false)
        allow(DRCI).to receive(:get_item?).and_return(false)

        instance.send(:set_warhorn_or_egg)

        expect(instance.instance_variable_get(:@warhorn_or_egg)).to be_empty
        expect(DRC).to have_received(:message).with(/No eggs or warhorns found/)
      end

      it 'handles egg_count 3 (only discovers first 2, skips unsupported ordinal)' do
        instance = build_ability_process(egg_count: 3, warhorn_nouns: [])
        call_count = 0
        allow(DRCI).to receive(:get_item?) do |_arg|
          call_count += 1
          stub_right_hand_with_id("e#{call_count}")
          true
        end
        allow(DRCI).to receive(:stow_item?).and_return(true)

        instance.send(:set_warhorn_or_egg)

        # Only 2 ordinals are supported ("egg" and "second egg")
        expect(instance.instance_variable_get(:@egg_ids).size).to eq(2)
        expect(DRC).to have_received(:message).with(/wanted 3 egg.*only found 2/)
      end

      it 'handles empty warhorn_nouns array (no discovery attempted)' do
        instance = build_ability_process(egg_count: 1, warhorn_nouns: [])
        stub_right_hand_with_id('10')
        allow(DRCI).to receive(:get_item?).and_return(true)
        allow(DRCI).to receive(:stow_item?).and_return(true)

        instance.send(:set_warhorn_or_egg)

        expect(instance.instance_variable_get(:@warhorn_items)).to be_empty
        expect(instance.instance_variable_get(:@warhorn_or_egg)).to eq(['egg'])
      end
    end

    # =========================================================================
    # use methods with zero/negative warhorn_cooldown
    # =========================================================================
    describe 'warhorn_cooldown edge cases' do
      let(:game_state) { build_game_state }

      it 'warhorn_cooldown 0 means cooldown expires immediately' do
        instance = build_ability_process(
          warhorn_items: [{ id: '20', worn: false }],
          item_cooldowns: { '20' => Time.now - 1 },
          warhorn_cooldown: 0
        )
        allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                    .and_return('You get')
        allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                    .and_return('You sound a series of bursts from the')
        allow(instance).to receive(:waitrt?)
        allow(DRC).to receive(:bput).with("stow #20", anything, anything, anything, anything)
                                    .and_return('You put')

        expect(instance.send(:use_warhorn?, game_state)).to be true
      end

      it 'negative warhorn_cooldown means cooldown is always expired' do
        instance = build_ability_process(
          warhorn_items: [{ id: '20', worn: false }],
          item_cooldowns: { '20' => Time.now },
          warhorn_cooldown: -500
        )
        allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                    .and_return('You get')
        allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                    .and_return('You sound a series of bursts from the')
        allow(instance).to receive(:waitrt?)
        allow(DRC).to receive(:bput).with("stow #20", anything, anything, anything, anything)
                                    .and_return('You put')

        expect(instance.send(:use_warhorn?, game_state)).to be true
      end

      it 'lungs-tired retry with cooldown 0 sets retry ~60s from now' do
        instance = build_ability_process(
          warhorn_items: [{ id: '20', worn: false }],
          item_cooldowns: {},
          warhorn_cooldown: 0
        )
        allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                    .and_return('You get')
        allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                    .and_return('Your lungs are tired from having sounded a')
        allow(DRC).to receive(:bput).with("stow #20", anything, anything, anything, anything)
                                    .and_return('You put')

        instance.send(:use_warhorn?, game_state)

        cooldown = instance.instance_variable_get(:@item_cooldowns)['20']
        # Time.now - 0 + 60 = ~60s from now
        expect(cooldown).to be_within(2).of(Time.now + 60)
      end
    end

    # =========================================================================
    # Concurrent removal of all items during use
    # =========================================================================
    describe 'all items vanish during use' do
      let(:game_state) { build_game_state }

      it 'handles all eggs disappearing one by one' do
        instance = build_ability_process(
          egg_ids: %w[10 20 30],
          item_cooldowns: {},
          warhorn_or_egg: ['egg']
        )
        allow(DRC).to receive(:bput).with(/invoke #/, anything, anything, anything, anything, anything)
                                    .and_return('Invoke what?')

        expect(instance.send(:use_egg?)).to be false
        expect(instance.instance_variable_get(:@egg_ids)).to be_empty
      end

      it 'handles all warhorns disappearing one by one' do
        instance = build_ability_process(
          warhorn_items: [
            { id: '20', worn: false },
            { id: '30', worn: false },
            { id: '40', worn: false }
          ],
          item_cooldowns: {}
        )
        allow(DRC).to receive(:bput).with(/get #/, anything, anything, anything, anything, anything, anything)
                                    .and_return('What were you referring to')

        expect(instance.send(:use_warhorn?, game_state)).to be false
        expect(instance.instance_variable_get(:@warhorn_items)).to be_empty
      end
    end

    # =========================================================================
    # Mixed success/failure across multiple items
    # =========================================================================
    describe 'mixed item states' do
      it 'first egg cooldown, second egg missing, third egg succeeds' do
        instance = build_ability_process(
          egg_ids: %w[10 20 30],
          item_cooldowns: { '10' => Time.now },
          warhorn_or_egg: ['egg']
        )
        allow(DRC).to receive(:bput).with("invoke #20", anything, anything, anything, anything, anything)
                                    .and_return('Invoke what?')
        allow(DRC).to receive(:bput).with("invoke #30", anything, anything, anything, anything, anything)
                                    .and_return('light envelops the area briefly')

        expect(instance.send(:use_egg?)).to be true
        expect(instance.instance_variable_get(:@egg_ids)).to eq(%w[10 30])
      end

      it 'first warhorn cooldown, second warhorn lungs-tired, all exhausted' do
        instance = build_ability_process(
          warhorn_items: [
            { id: '20', worn: false },
            { id: '30', worn: false }
          ],
          item_cooldowns: { '20' => Time.now },
          warhorn_cooldown: 1200
        )
        allow(DRC).to receive(:bput).with("get #30", anything, anything, anything, anything, anything, anything)
                                    .and_return('You get')
        allow(DRC).to receive(:bput).with("exhale #30 lure", anything, anything, anything, anything)
                                    .and_return('Your lungs are tired from having sounded a')
        allow(DRC).to receive(:bput).with("stow #30", anything, anything, anything, anything)
                                    .and_return('You put')

        game_state = build_game_state
        expect(instance.send(:use_warhorn?, game_state)).to be false
        expect(instance.instance_variable_get(:@item_cooldowns)['30']).not_to be_nil
      end
    end
  end
end
