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

    def retreat; end

    def message(*_args); end
  end
end

module DRCI
  class << self
    def get_item_if_not_held?(*_args)
      true
    end

    def in_hands?(*_args)
      true
    end

    def exists?(*_args)
      true
    end

    def put_away_item?(*_args)
      true
    end
  end
end

class UserVars
  @data = {}

  class << self
    def method_missing(name, *args)
      if name.to_s.end_with?('=')
        @data[name.to_s.chomp('=').to_sym] = args.first
      else
        @data[name.to_sym]
      end
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end

    def _reset
      @data = {}
    end
  end
end unless defined?(UserVars)

$debug_mode_ct = false

load_lic_class('combat-trainer.lic', 'TrainerProcess')

RSpec.configure do |config|
  config.before(:each) do
    reset_data
    UserVars._reset
    $ALMANAC = nil
    $right_hand = nil
    $left_hand = nil
  end
end

RSpec.describe TrainerProcess do
  def build_trainer(**overrides)
    instance = TrainerProcess.allocate
    defaults = {
      almanac: 'almanac',
      almanac_skills: [],
      almanac_priority_skills: [],
      equipment_manager: double('EquipmentManager')
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  def build_game_state(**attrs)
    defaults = {
      currently_whirlwinding: false,
      npcs: []
    }
    state = double('GameState', defaults.merge(attrs))
    allow(state).to receive(:sheath_whirlwind_offhand)
    allow(state).to receive(:wield_whirlwind_offhand)
    allow(state).to receive(:engage_slow)
    state
  end

  describe '#use_almanac' do
    before(:each) do
      allow(DRC).to receive(:retreat)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      allow(DRCI).to receive(:get_item_if_not_held?).and_return(true)
      allow(DRCI).to receive(:in_hands?).and_return(true)
      allow(DRCI).to receive(:exists?).and_return(true)
      allow(DRCI).to receive(:put_away_item?).and_return(true)
      UserVars.almanac_last_use = Time.now - 700
    end

    # -----------------------------------------------------------------
    # Early return guards
    # -----------------------------------------------------------------
    context 'when @almanac is nil' do
      it 'returns immediately without any game commands' do
        trainer = build_trainer(almanac: nil)
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).not_to have_received(:retreat)
        expect(DRCI).not_to have_received(:get_item_if_not_held?)
      end
    end

    context 'when cooldown has not elapsed' do
      it 'returns immediately without any game commands' do
        trainer = build_trainer
        game_state = build_game_state
        UserVars.almanac_last_use = Time.now

        trainer.send(:use_almanac, game_state)

        expect(DRC).not_to have_received(:retreat)
        expect(DRCI).not_to have_received(:get_item_if_not_held?)
      end
    end

    context 'when left hand is full and not whirlwinding' do
      it 'returns immediately' do
        $left_hand = 'sword'
        trainer = build_trainer
        game_state = build_game_state(currently_whirlwinding: false)

        trainer.send(:use_almanac, game_state)

        expect(DRC).not_to have_received(:retreat)
      end
    end

    # -----------------------------------------------------------------
    # Almanac script delegation
    # -----------------------------------------------------------------
    context 'when almanac script is running' do
      before(:each) do
        allow(Script).to receive(:running?).with('almanac').and_return(true)
      end

      it 'delegates to $ALMANAC.use_almanac' do
        almanac_script = double('AlmanacScript')
        $ALMANAC = almanac_script
        allow(almanac_script).to receive(:use_almanac).and_return(:ok)

        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(almanac_script).to have_received(:use_almanac)
        expect(DRCI).not_to have_received(:get_item_if_not_held?)
      end

      it 'disables almanac when script returns :not_found' do
        almanac_script = double('AlmanacScript')
        $ALMANAC = almanac_script
        allow(almanac_script).to receive(:use_almanac).and_return(:not_found)

        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(trainer.instance_variable_get(:@almanac)).to be_nil
      end

      it 're-wields whirlwind offhand after delegation' do
        almanac_script = double('AlmanacScript')
        $ALMANAC = almanac_script
        allow(almanac_script).to receive(:use_almanac).and_return(:ok)

        trainer = build_trainer
        game_state = build_game_state(currently_whirlwinding: true)

        trainer.send(:use_almanac, game_state)

        expect(game_state).to have_received(:wield_whirlwind_offhand)
      end
    end

    # -----------------------------------------------------------------
    # Successful almanac usage (inline, no almanac script)
    # -----------------------------------------------------------------
    context 'when almanac is retrieved successfully' do
      before(:each) do
        allow(Script).to receive(:running?).with('almanac').and_return(false)
      end

      it 'retreats and engages slow before getting the almanac' do
        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).to have_received(:retreat).ordered
        expect(game_state).to have_received(:engage_slow).ordered
      end

      it 'studies the almanac and puts it away' do
        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).to have_received(:bput).with('study my almanac', anything, anything, anything)
        expect(DRCI).to have_received(:put_away_item?).with('almanac')
      end

      it 'updates the cooldown timer' do
        trainer = build_trainer
        game_state = build_game_state
        before_time = Time.now

        trainer.send(:use_almanac, game_state)

        expect(UserVars.almanac_last_use).to be >= before_time
      end

      it 'does not turn the almanac when no training_skill is set' do
        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).not_to have_received(:bput).with(/^turn almanac/, anything, anything)
      end

      it 'turns the almanac to the training skill when almanac_skills are configured' do
        allow(DRSkill).to receive(:getxp).and_return(5)
        allow(DRSkill).to receive(:getrank).and_return(100)

        trainer = build_trainer(almanac_skills: ['Scholarship'])
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).to have_received(:bput).with('turn almanac to Scholarship', 'You turn', 'You attempt to turn')
      end

      it 'prefers priority skills over regular almanac skills' do
        allow(DRSkill).to receive(:getxp).and_return(5)
        allow(DRSkill).to receive(:getrank).and_return(100)

        trainer = build_trainer(
          almanac_skills: ['Scholarship'],
          almanac_priority_skills: ['Tactics']
        )
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).to have_received(:bput).with('turn almanac to Tactics', 'You turn', 'You attempt to turn')
      end

      it 're-wields whirlwind offhand after studying' do
        trainer = build_trainer
        game_state = build_game_state(currently_whirlwinding: true)

        trainer.send(:use_almanac, game_state)

        expect(game_state).to have_received(:wield_whirlwind_offhand)
      end

      it 'sheaths whirlwind offhand before getting the almanac' do
        trainer = build_trainer
        game_state = build_game_state(currently_whirlwinding: true)

        trainer.send(:use_almanac, game_state)

        expect(game_state).to have_received(:sheath_whirlwind_offhand)
      end
    end

    # -----------------------------------------------------------------
    # Almanac not found -- disables for the hunt
    # -----------------------------------------------------------------
    context 'when almanac is not found in inventory' do
      before(:each) do
        allow(Script).to receive(:running?).with('almanac').and_return(false)
        allow(DRCI).to receive(:get_item_if_not_held?).and_return(false)
        allow(DRCI).to receive(:in_hands?).and_return(false)
        allow(DRCI).to receive(:exists?).and_return(false)
      end

      it 'disables almanac usage for the rest of the hunt' do
        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(trainer.instance_variable_get(:@almanac)).to be_nil
      end

      it 'does not attempt to study or stow' do
        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).not_to have_received(:bput).with(/study/, anything, anything, anything)
        expect(DRCI).not_to have_received(:put_away_item?)
      end

      it 'does not update the cooldown timer' do
        trainer = build_trainer
        game_state = build_game_state
        UserVars.almanac_last_use = Time.now - 700
        old_time = UserVars.almanac_last_use

        trainer.send(:use_almanac, game_state)

        expect(UserVars.almanac_last_use).to eq(old_time)
      end

      it 're-wields whirlwind offhand even on failure' do
        trainer = build_trainer
        game_state = build_game_state(currently_whirlwinding: true)

        trainer.send(:use_almanac, game_state)

        expect(game_state).to have_received(:wield_whirlwind_offhand)
      end
    end

    # -----------------------------------------------------------------
    # Hands full -- almanac exists but could not be retrieved
    # -----------------------------------------------------------------
    context 'when hands are full but almanac exists' do
      before(:each) do
        allow(Script).to receive(:running?).with('almanac').and_return(false)
        allow(DRCI).to receive(:get_item_if_not_held?).and_return(false)
        allow(DRCI).to receive(:in_hands?).and_return(false)
        allow(DRCI).to receive(:exists?).and_return(true)
      end

      it 'does not disable almanac usage' do
        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(trainer.instance_variable_get(:@almanac)).to eq('almanac')
      end

      it 'returns without studying or stowing' do
        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).not_to have_received(:bput).with(/study/, anything, anything, anything)
        expect(DRCI).not_to have_received(:put_away_item?)
      end
    end

    # -----------------------------------------------------------------
    # Skill selection edge cases
    # -----------------------------------------------------------------
    context 'when all almanac_skills are at mindstate 18+' do
      before(:each) do
        allow(Script).to receive(:running?).with('almanac').and_return(false)
        allow(DRSkill).to receive(:getxp).and_return(18)
        allow(DRSkill).to receive(:getrank).and_return(100)
      end

      it 'falls back to skill_with_lowest_mindstate' do
        skill_data = double('SkillData', name: 'Forging', exp: 1, rank: 50)
        allow(DRSkill).to receive(:list).and_return([skill_data])

        trainer = build_trainer(almanac_skills: ['Scholarship'])
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).to have_received(:bput).with('turn almanac to Forging', 'You turn', 'You attempt to turn')
      end
    end
  end
end
