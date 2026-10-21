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

  describe '#assert_that_hunting_info_escort_zones_are_reachable' do
    let(:instance) { build }

    before do
      $test_data[:hunting] = OpenStruct.new(escort_zones: { 'ship' => {}, 'boat' => {} }, hunting_zones: { 'rats' => [1], 'goblins' => [2] })
    end

    def check(zones, custom = {})
      instance.assert_that_hunting_info_escort_zones_are_reachable(OpenStruct.new(hunting_info: [{ zone: zones }], custom_hunting_zones: custom))
    end

    it 'warns when a leading escort zone hides the rest of the list' do
      check(%w[ship rats])
      expect($warn_msgs.first).to include('ship is an escort zone listed first').and include('never uses rats')
    end

    it 'warns when a second escort zone can never be used' do
      check(%w[rats ship boat])
      expect($warn_msgs.first).to include('only the first escort zone (ship)').and include('boat never will be')
    end

    it 'does not warn for one escort zone as the fallback, or on its own' do
      check(%w[rats goblins ship])
      check('ship')
      check(%w[rats goblins])
      expect($warn_msgs).to be_empty
    end

    it 'treats a custom zone named like an escort zone as the custom zone' do
      check(%w[ship rats], { 'ship' => [5] })
      expect($warn_msgs).to be_empty
    end
  end
end
