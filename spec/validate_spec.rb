# frozen_string_literal: true

require_relative 'spec_helper'

# Load the DRYamlValidator class (the trailing DRYamlValidator.new is not
# executed; load_lic_class extracts only the class body).
load_lic_class('validate.lic', 'DRYamlValidator')

RSpec.describe DRYamlValidator do
  # Build a bare instance with the counters #warn/#error touch, rather than
  # driving the full #initialize workflow (which scans profiles on disk).
  def build
    instance = DRYamlValidator.allocate
    instance.instance_variable_set(:@warning_count, 0)
    instance.instance_variable_set(:@error_count, 0)
    instance
  end

  before do
    # Mirrors data/base-theurgy.yaml: Crossing has favor altars (incl. Hodierna),
    # Fang Cove exists but has no favor_altars key.
    $test_data[:theurgy] = {
      'Crossing'  => { 'favor_altars' => { 'Hodierna' => { 'id' => 5850 }, 'Meraud' => { 'id' => 5852 } } },
      'Fang Cove' => { 'Alamhif' => { 'id' => 8347 } }
    }
  end

  describe '#assert_that_hometown_has_altar_if_using_altars' do
    let(:instance) { build }

    def settings(overrides = {})
      OpenStruct.new({ use_favor_altars: true, favor_goal: 100, favor_god: 'Hodierna', hometown: 'Crossing' }.merge(overrides))
    end

    it 'does not warn when the resolved town has an altar for the favor_god' do
      instance.assert_that_hometown_has_altar_if_using_altars(settings)
      expect($warn_msgs).to be_empty
    end

    it 'resolves fang_cove_override_town for a Fang Cove character' do
      instance.assert_that_hometown_has_altar_if_using_altars(
        settings(hometown: 'Fang Cove', fang_cove_override_town: 'Crossing')
      )
      expect($warn_msgs).to be_empty
    end

    it 'prefers favor_town over fang_cove_override_town and hometown' do
      instance.assert_that_hometown_has_altar_if_using_altars(
        settings(hometown: 'Fang Cove', fang_cove_override_town: 'Riverhaven', favor_town: 'Crossing')
      )
      expect($warn_msgs).to be_empty
    end

    it 'warns (without crashing) when the favor town has no altars at all' do
      instance.assert_that_hometown_has_altar_if_using_altars(settings(hometown: 'Fang Cove'))
      expect($warn_msgs.join).to include('Fang Cove')
    end

    it 'warns when the resolved town lacks an altar for the favor_god' do
      instance.assert_that_hometown_has_altar_if_using_altars(settings(favor_god: 'Kertigen'))
      expect($warn_msgs.join).to include('Kertigen')
    end

    it 'skips the check when favor altars are not in use' do
      instance.assert_that_hometown_has_altar_if_using_altars(settings(use_favor_altars: false, hometown: 'Fang Cove'))
      expect($warn_msgs).to be_empty
    end
  end

  describe '#assert_that_stop_on_high_threshold_does_not_hide_skillset_thresholds' do
    let(:instance) { build }

    def settings(overrides = {})
      OpenStruct.new({
        stop_on_high_threshold: 32,
        armor_exp_training_max_threshold: 32, weapon_exp_training_max_threshold: 32,
        magic_exp_training_max_threshold: 32, survival_exp_training_max_threshold: 32,
        lore_exp_training_max_threshold: 32,
        hunting_info: [{ :zone => 'rats', 'stop_on' => ['Small Edged', 'Arcana'] }]
      }.merge(overrides))
    end

    def check(overrides = {})
      instance.assert_that_stop_on_high_threshold_does_not_hide_skillset_thresholds(settings(overrides))
    end

    it 'does not warn with the base.yaml defaults (every threshold 32)' do
      check
      expect($warn_msgs).to be_empty
    end

    it 'warns for each overridden threshold of a skillset a stop_on skill belongs to' do
      check(magic_exp_training_max_threshold: 10, weapon_exp_training_max_threshold: 20)
      expect($warn_msgs.size).to eq(2)
      expect($warn_msgs.join).to include('stop_on_high_threshold (32) overrides magic_exp_training_max_threshold (10)')
      expect($warn_msgs.join).to include('weapon_exp_training_max_threshold (20)')
    end

    it 'does not warn about a skillset no stop_on skill belongs to (e.g. magic set for combat-trainer)' do
      check(magic_exp_training_max_threshold: 8, hunting_info: [{ :zone => 'rats', 'stop_on' => ['Small Edged', 'Skinning'] }])
      expect($warn_msgs).to be_empty
    end

    it 'checks stop_on skills from every hunt, including nested lists' do
      check(lore_exp_training_max_threshold: 20,
            hunting_info: [{ :zone => 'rats', 'stop_on' => ['Small Edged'] }, { :zone => 'goblins', 'stop_on' => [['Tactics']] }])
      expect($warn_msgs.size).to eq(1)
      expect($warn_msgs.first).to include('lore_exp_training_max_threshold (20)')
    end

    it 'does not warn when stop_on_high_threshold is blank or false, since the per-skillset values apply' do
      check(stop_on_high_threshold: nil, magic_exp_training_max_threshold: 10)
      check(stop_on_high_threshold: false, magic_exp_training_max_threshold: 10)
      expect($warn_msgs).to be_empty
    end

    it 'does not warn when no hunt has stop_on skills' do
      check(magic_exp_training_max_threshold: 10, hunting_info: [{ :zone => 'rats', :duration => 30 }, { :zone => 'rats', 'stop_on' => [] }])
      expect($warn_msgs).to be_empty
    end

    it 'does not warn when there is no hunting_info' do
      check(magic_exp_training_max_threshold: 10, hunting_info: nil)
      expect($warn_msgs).to be_empty
    end
  end

  describe '#assert_that_prehunt_buffing_room_exists_without_waggle_set' do
    let(:instance) { build }

    def check(overrides)
      instance.assert_that_prehunt_buffing_room_exists_without_waggle_set(OpenStruct.new({ waggle_sets: {} }.merge(overrides)))
    end

    it 'warns about buffing in place for the default prehunt_buffs set with no room' do
      check(waggle_sets: { 'prehunt_buffs' => {} })
      expect($warn_msgs.first).to include('prehunt_buffs waggle set')
    end

    it 'checks the set named by prehunt_buff_waggle' do
      check(prehunt_buff_waggle: 'before_hunt', waggle_sets: { 'before_hunt' => {} })
      expect($warn_msgs.first).to include('before_hunt waggle set')
    end

    it 'does not warn about an unused prehunt_buffs set when prehunt_buff_waggle names another' do
      check(prehunt_buff_waggle: 'before_hunt', waggle_sets: { 'prehunt_buffs' => {} })
      expect($warn_msgs).to be_empty
    end

    it 'does not warn (or raise) when waggle_sets is blank, as base.yaml ships it' do
      check(waggle_sets: nil)
      expect($warn_msgs).to be_empty
    end

    it 'does not warn when a room is set, including the deprecated prehunt_buffs room' do
      check(waggle_sets: { 'prehunt_buffs' => {} }, prehunt_buffing_room: 1234)
      check(waggle_sets: { 'prehunt_buffs' => {} }, prehunt_buffs: 1234)
      expect($warn_msgs).to be_empty
    end
  end

  describe '#assert_that_prehunt_buff_waggle_set_exists' do
    let(:instance) { build }

    def check(overrides)
      instance.assert_that_prehunt_buff_waggle_set_exists(OpenStruct.new({ waggle_sets: {} }.merge(overrides)))
    end

    it 'warns when prehunt_buff_waggle names a set that does not exist' do
      check(prehunt_buff_waggle: 'before_hunt', waggle_sets: { 'other' => {} })
      expect($warn_msgs.first).to include('prehunt_buff_waggle is before_hunt')
    end

    it 'warns when waggle_sets is blank too' do
      check(prehunt_buff_waggle: 'before_hunt', waggle_sets: nil)
      expect($warn_msgs.size).to eq(1)
    end

    it 'does not warn when the named set exists' do
      check(prehunt_buff_waggle: 'before_hunt', waggle_sets: { 'before_hunt' => {} })
      expect($warn_msgs).to be_empty
    end

    it 'does not warn for the default prehunt_buffs name, since prehunt buffs are optional' do
      check(prehunt_buff_waggle: 'prehunt_buffs')
      check(prehunt_buff_waggle: nil)
      expect($warn_msgs).to be_empty
    end
  end
end
