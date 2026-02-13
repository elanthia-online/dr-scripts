require 'ostruct'

# Load test harness which provides mock game objects
load File.join(File.dirname(__FILE__), '..', 'test', 'test_harness.rb')
include Harness

# Extract and eval a class from a .lic file without executing top-level code
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

# Minimal stub modules for game interaction.
module DRC
  def self.message(*_args); end

  def self.wait_for_script_to_complete(*_args); end
end

module DRCT
  def self.walk_to(*_args); end
end

module DRCH
  def self.check_health
    $mock_health || { 'score' => 0 }
  end
end

# Add known_spells support to test harness DRSpells
module Harness
  class DRSpells
    def self._set_known_spells(val)
      @@_data_store['known_spells'] = val
    end

    def self.known_spells
      @@_data_store['known_spells'] || {}
    end
  end
end

# PlantHeal class body checks DRStats.empath? at load time
DRStats.guild = 'Empath'
load_lic_class('plantheal.lic', 'PlantHeal')

RSpec.describe PlantHeal do
  before(:each) do
    reset_data
    $mock_health = nil
  end

  # Helper: create a bare PlantHeal instance without running initialize
  def build_instance(**overrides)
    instance = PlantHeal.allocate
    overrides.each { |k, v| instance.instance_variable_set(:"@#{k}", v) }
    instance
  end

  # ---------------------------------------------------------------------------
  # validate_healing_spells!
  # ---------------------------------------------------------------------------

  describe '#validate_healing_spells!' do
    context 'waggle healing path (Heal+AC known)' do
      it 'sets @waggle_healing to true when Heal and AC known and Heal in waggle' do
        DRSpells._set_known_spells({ 'Heal' => true, 'Adaptive Curing' => true })
        instance = build_instance(ev_waggle: { 'Heal' => {}, "Embrace of the Vela'Tohr" => {} })
        expect(DRC).not_to receive(:message)
        instance.send(:validate_healing_spells!)
        expect(instance.instance_variable_get(:@waggle_healing)).to be true
      end

      it 'sets @waggle_healing to true when Heal and AC known and Regenerate in waggle' do
        DRSpells._set_known_spells({ 'Heal' => true, 'Adaptive Curing' => true })
        instance = build_instance(ev_waggle: { 'Regenerate' => {}, "Embrace of the Vela'Tohr" => {} })
        expect(DRC).not_to receive(:message)
        instance.send(:validate_healing_spells!)
        expect(instance.instance_variable_get(:@waggle_healing)).to be true
      end

      it 'exits when Heal+AC known but neither Heal nor Regenerate in waggle' do
        DRSpells._set_known_spells({ 'Heal' => true, 'Adaptive Curing' => true })
        instance = build_instance(ev_waggle: { "Embrace of the Vela'Tohr" => {} })
        expect(DRC).to receive(:message).with(/neither Heal nor Regenerate is in your plantheal waggle_set/)
        expect(DRC).to receive(:message).with(/Add a Heal or Regenerate entry/)
        expect { instance.send(:validate_healing_spells!) }.to raise_error(SystemExit)
      end

      it 'accepts both Heal and Regenerate in waggle' do
        DRSpells._set_known_spells({ 'Heal' => true, 'Adaptive Curing' => true })
        instance = build_instance(ev_waggle: { 'Heal' => {}, 'Regenerate' => {}, "Embrace of the Vela'Tohr" => {} })
        expect(DRC).not_to receive(:message)
        instance.send(:validate_healing_spells!)
        expect(instance.instance_variable_get(:@waggle_healing)).to be true
      end
    end

    context 'healme path (no Heal+AC)' do
      it 'sets @waggle_healing to false and warns about missing HW and HS' do
        DRSpells._set_known_spells({})
        instance = build_instance(ev_waggle: { "Embrace of the Vela'Tohr" => {} })
        expect(DRC).to receive(:message).with(/Heal Wounds \(HW\)/).once
        expect(DRC).to receive(:message).with(/Heal Scars \(HS\)/).once
        instance.send(:validate_healing_spells!)
        expect(instance.instance_variable_get(:@waggle_healing)).to be false
      end

      it 'does not warn when HW and HS are known' do
        DRSpells._set_known_spells({ 'Heal Wounds' => true, 'Heal Scars' => true })
        instance = build_instance(ev_waggle: { "Embrace of the Vela'Tohr" => {} })
        expect(DRC).not_to receive(:message)
        instance.send(:validate_healing_spells!)
        expect(instance.instance_variable_get(:@waggle_healing)).to be false
      end

      it 'warns about HS only when HW is known' do
        DRSpells._set_known_spells({ 'Heal Wounds' => true })
        instance = build_instance(ev_waggle: { "Embrace of the Vela'Tohr" => {} })
        expect(DRC).not_to receive(:message).with(/Heal Wounds \(HW\)/)
        expect(DRC).to receive(:message).with(/Heal Scars \(HS\)/).once
        instance.send(:validate_healing_spells!)
      end

      it 'warns about HW only when HS is known' do
        DRSpells._set_known_spells({ 'Heal Scars' => true })
        instance = build_instance(ev_waggle: { "Embrace of the Vela'Tohr" => {} })
        expect(DRC).to receive(:message).with(/Heal Wounds \(HW\)/).once
        expect(DRC).not_to receive(:message).with(/Heal Scars \(HS\)/)
        instance.send(:validate_healing_spells!)
      end

      it 'warns when Heal is known but not AC (Heal alone insufficient)' do
        DRSpells._set_known_spells({ 'Heal' => true })
        instance = build_instance(ev_waggle: { "Embrace of the Vela'Tohr" => {} })
        expect(DRC).to receive(:message).with(/Heal Wounds \(HW\)/).once
        expect(DRC).to receive(:message).with(/Heal Scars \(HS\)/).once
        instance.send(:validate_healing_spells!)
        expect(instance.instance_variable_get(:@waggle_healing)).to be false
      end

      it 'warns when AC is known but not Heal' do
        DRSpells._set_known_spells({ 'Adaptive Curing' => true })
        instance = build_instance(ev_waggle: { "Embrace of the Vela'Tohr" => {} })
        expect(DRC).to receive(:message).with(/Heal Wounds \(HW\)/).once
        expect(DRC).to receive(:message).with(/Heal Scars \(HS\)/).once
        instance.send(:validate_healing_spells!)
        expect(instance.instance_variable_get(:@waggle_healing)).to be false
      end

      it 'treats nil known_spells values as not known' do
        DRSpells._set_known_spells({ 'Heal' => nil, 'Adaptive Curing' => nil })
        instance = build_instance(ev_waggle: { "Embrace of the Vela'Tohr" => {} })
        expect(DRC).to receive(:message).with(/Heal Wounds \(HW\)/).once
        expect(DRC).to receive(:message).with(/Heal Scars \(HS\)/).once
        instance.send(:validate_healing_spells!)
        expect(instance.instance_variable_get(:@waggle_healing)).to be false
      end

      it 'treats false known_spells values as not known' do
        DRSpells._set_known_spells({ 'Heal' => false, 'Adaptive Curing' => false })
        instance = build_instance(ev_waggle: { "Embrace of the Vela'Tohr" => {} })
        expect(DRC).to receive(:message).with(/Heal Wounds \(HW\)/).once
        expect(DRC).to receive(:message).with(/Heal Scars \(HS\)/).once
        instance.send(:validate_healing_spells!)
        expect(instance.instance_variable_get(:@waggle_healing)).to be false
      end
    end

    context 'warning message content' do
      it 'includes exact HW warning text' do
        DRSpells._set_known_spells({})
        instance = build_instance(ev_waggle: { "Embrace of the Vela'Tohr" => {} })
        expect(DRC).to receive(:message).with("**WARNING: You don't know Heal Wounds (HW)!** healme may not work properly.")
        expect(DRC).to receive(:message).with("**WARNING: You don't know Heal Scars (HS)!** healme may not work properly.")
        instance.send(:validate_healing_spells!)
      end

      it 'includes exact waggle exit text' do
        DRSpells._set_known_spells({ 'Heal' => true, 'Adaptive Curing' => true })
        instance = build_instance(ev_waggle: { "Embrace of the Vela'Tohr" => {} })
        expect(DRC).to receive(:message).with("**EXIT: You know Heal+AC but neither Heal nor Regenerate is in your plantheal waggle_set!**")
        expect(DRC).to receive(:message).with("   Add a Heal or Regenerate entry to waggle_sets.plantheal so the script can keep healing spells active.")
        expect { instance.send(:validate_healing_spells!) }.to raise_error(SystemExit)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # ensure_healing_spells
  # ---------------------------------------------------------------------------

  describe '#ensure_healing_spells' do
    context 'waggle healing path' do
      it 'does nothing when Heal is active' do
        DRSpells._set_active_spells({ 'Heal' => 300 })
        instance = build_instance(waggle_healing: true)
        expect(DRC).not_to receive(:wait_for_script_to_complete)
        instance.send(:ensure_healing_spells)
      end

      it 'does nothing when Regenerate is active' do
        DRSpells._set_active_spells({ 'Regenerate' => 300 })
        instance = build_instance(waggle_healing: true)
        expect(DRC).not_to receive(:wait_for_script_to_complete)
        instance.send(:ensure_healing_spells)
      end

      it 'calls buff plantheal when neither Heal nor Regenerate is active' do
        DRSpells._set_active_spells({})
        instance = build_instance(waggle_healing: true)
        expect(DRC).to receive(:wait_for_script_to_complete).with('buff', ['plantheal'])
        instance.send(:ensure_healing_spells)
      end
    end

    context 'healme path' do
      it 'does nothing (returns immediately)' do
        DRSpells._set_active_spells({})
        instance = build_instance(waggle_healing: false)
        expect(DRC).not_to receive(:wait_for_script_to_complete)
        instance.send(:ensure_healing_spells)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # heal_now
  # ---------------------------------------------------------------------------

  describe '#heal_now' do
    context 'waggle healing path' do
      it 'calls ensure_healing_spells and wait_for_passive_healing' do
        instance = build_instance(waggle_healing: true, healingroom: 1234)
        expect(instance).to receive(:ensure_healing_spells)
        expect(instance).to receive(:wait_for_passive_healing)
        expect(DRCT).not_to receive(:walk_to)
        expect(DRC).not_to receive(:wait_for_script_to_complete).with('healme')
        instance.send(:heal_now)
      end
    end

    context 'healme path' do
      it 'walks to healing room and runs healme' do
        instance = build_instance(waggle_healing: false, healingroom: 1234)
        expect(DRCT).to receive(:walk_to).with(1234)
        expect(DRC).to receive(:wait_for_script_to_complete).with('healme')
        instance.send(:heal_now)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # heal_between_hugs
  # ---------------------------------------------------------------------------

  describe '#heal_between_hugs' do
    context 'waggle healing path' do
      it 'heals in place without walking to healing room' do
        $mock_health = { 'score' => 5 }
        instance = build_instance(waggle_healing: true, healingroom: 1234, plantroom: 5678)
        expect(instance).to receive(:ensure_healing_spells)
        expect(instance).to receive(:wait_for_passive_healing)
        expect(DRCT).not_to receive(:walk_to)
        instance.send(:heal_between_hugs)
      end
    end

    context 'healme path' do
      it 'walks to healing room, runs healme, walks back to plant room' do
        $mock_health = { 'score' => 5 }
        instance = build_instance(waggle_healing: false, healingroom: 1234, plantroom: 5678)
        expect(DRCT).to receive(:walk_to).with(1234).ordered
        expect(DRC).to receive(:wait_for_script_to_complete).with('healme').ordered
        expect(DRCT).to receive(:walk_to).with(5678).ordered
        instance.send(:heal_between_hugs)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # wait_for_passive_healing
  # ---------------------------------------------------------------------------

  describe '#wait_for_passive_healing' do
    it 'returns immediately when wound score is 0' do
      $mock_health = { 'score' => 0 }
      instance = build_instance(healingroom: 1234)
      expect(instance).not_to receive(:pause)
      instance.send(:wait_for_passive_healing)
    end

    it 'polls until wound score reaches 0' do
      call_count = 0
      allow(DRCH).to receive(:check_health) do
        call_count += 1
        { 'score' => call_count >= 3 ? 0 : 5 }
      end
      instance = build_instance(healingroom: 1234)
      allow(instance).to receive(:pause)
      instance.send(:wait_for_passive_healing)
      expect(call_count).to eq(3)
    end

    it 'falls back to healme after timeout' do
      $mock_health = { 'score' => 5 }
      instance = build_instance(healingroom: 1234)
      allow(instance).to receive(:pause)
      expect(DRC).to receive(:message).with(/Still wounded after.*passive healing.*healme as fallback/)
      expect(DRCT).to receive(:walk_to).with(1234)
      expect(DRC).to receive(:wait_for_script_to_complete).with('healme')
      instance.send(:wait_for_passive_healing)
    end

    it 'uses PASSIVE_HEAL_POLL_INTERVAL for pause duration' do
      call_count = 0
      allow(DRCH).to receive(:check_health) do
        call_count += 1
        { 'score' => call_count >= 2 ? 0 : 5 }
      end
      instance = build_instance(healingroom: 1234)
      expect(instance).to receive(:pause).with(PlantHeal::PASSIVE_HEAL_POLL_INTERVAL).once
      instance.send(:wait_for_passive_healing)
    end
  end

  # ---------------------------------------------------------------------------
  # display_mode_message
  # ---------------------------------------------------------------------------

  describe '#display_mode_message' do
    context 'waggle healing mode' do
      it 'displays waggle healing message' do
        instance = build_instance(waggle_healing: true, heal_past_ml: false, hug_count: 3, threshold: 24)
        expect(DRC).to receive(:message).with(/Healing via Heal\/Regenerate \(waggle\)/)
        expect(DRC).to receive(:message).with(/Will stop at FIRST of: 3 total hugs OR empathy mindstate 24/)
        instance.send(:display_mode_message)
      end
    end

    context 'healme mode' do
      it 'displays healme script message' do
        instance = build_instance(waggle_healing: false, heal_past_ml: false, hug_count: 5, threshold: 30)
        expect(DRC).to receive(:message).with(/Healing via healme script \(HW\/HS\)/)
        expect(DRC).to receive(:message).with(/Will stop at FIRST of: 5 total hugs OR empathy mindstate 30/)
        instance.send(:display_mode_message)
      end
    end

    context 'heal_past_ml mode' do
      it 'displays heal_past_ml ON messages' do
        instance = build_instance(waggle_healing: true, heal_past_ml: true, hug_count: 3, threshold: 24)
        expect(DRC).to receive(:message).with(/Healing via Heal\/Regenerate \(waggle\)/)
        expect(DRC).to receive(:message).with(/heal_past_ml is ON/)
        expect(DRC).to receive(:message).with(/Will cycle until the plant is FULLY HEALED/)
        expect(DRC).to receive(:message).with(/To stop at a threshold/)
        expect(DRC).to receive(:message).with(/To stop after N hugs/)
        instance.send(:display_mode_message)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # load_settings
  # ---------------------------------------------------------------------------

  describe '#load_settings' do
    let(:instance) { PlantHeal.allocate }

    it 'returns default values when plantheal_settings is empty' do
      settings = OpenStruct.new(plantheal_settings: {})
      result = instance.send(:load_settings, settings)
      expect(result[:hug_count]).to eq(3)
      expect(result[:empathy_threshold]).to eq(24)
      expect(result[:heal_past_ml]).to eq(false)
      expect(result[:ev_cast_mana]).to eq(600)
      expect(result[:ev_extra_wait]).to eq(15)
    end

    it 'returns default values when plantheal_settings is nil' do
      settings = OpenStruct.new(plantheal_settings: nil)
      result = instance.send(:load_settings, settings)
      expect(result[:hug_count]).to eq(3)
      expect(result[:empathy_threshold]).to eq(24)
    end

    it 'uses configured values from plantheal_settings' do
      settings = OpenStruct.new(plantheal_settings: {
        'hug_count'         => 10,
        'empathy_threshold' => 30,
        'heal_past_ml'      => true,
        'plant_room'        => 1234,
        'healing_room'      => 5678,
        'ev_cast_mana'      => 800,
        'ev_extra_wait'     => 20,
        'focus_container'   => 'backpack'
      })
      result = instance.send(:load_settings, settings)
      expect(result[:hug_count]).to eq(10)
      expect(result[:empathy_threshold]).to eq(30)
      expect(result[:heal_past_ml]).to eq(true)
      expect(result[:plant_room]).to eq(1234)
      expect(result[:healing_room]).to eq(5678)
      expect(result[:ev_cast_mana]).to eq(800)
      expect(result[:ev_extra_wait]).to eq(20)
      expect(result[:focus_container]).to eq('backpack')
    end

    it 'migrates legacy plant_total_touch_count to hug_count' do
      settings = OpenStruct.new(
        plantheal_settings: {},
        plant_total_touch_count: 7
      )
      expect(DRC).to receive(:message).with(/Deprecated setting 'plant_total_touch_count'.*hug_count/)
      result = instance.send(:load_settings, settings)
      expect(result[:hug_count]).to eq(7)
    end

    it 'migrates legacy plant_custom_room to plant_room' do
      settings = OpenStruct.new(
        plantheal_settings: {},
        plant_custom_room: 999
      )
      expect(DRC).to receive(:message).with(/Deprecated setting 'plant_custom_room'.*plant_room/)
      result = instance.send(:load_settings, settings)
      expect(result[:plant_room]).to eq(999)
    end

    it 'migrates legacy plant_heal_past_ML to heal_past_ml' do
      settings = OpenStruct.new(
        plantheal_settings: {},
        plant_heal_past_ML: true
      )
      expect(DRC).to receive(:message).with(/Deprecated setting 'plant_heal_past_ML'.*heal_past_ml/)
      result = instance.send(:load_settings, settings)
      expect(result[:heal_past_ml]).to eq(true)
    end

    it 'does not migrate legacy settings when new settings exist' do
      settings = OpenStruct.new(
        plantheal_settings: { 'hug_count' => 5 },
        plant_total_touch_count: 10
      )
      expect(DRC).not_to receive(:message).with(/Deprecated/)
      result = instance.send(:load_settings, settings)
      expect(result[:hug_count]).to eq(5)
    end

    it 'converts heal_past_ml string values to boolean' do
      %w[true 1 yes y].each do |val|
        settings = OpenStruct.new(plantheal_settings: { 'heal_past_ml' => val })
        result = instance.send(:load_settings, settings)
        expect(result[:heal_past_ml]).to eq(true), "Expected '#{val}' to be true"
      end

      %w[false 0 no n].each do |val|
        settings = OpenStruct.new(plantheal_settings: { 'heal_past_ml' => val })
        result = instance.send(:load_settings, settings)
        expect(result[:heal_past_ml]).to eq(false), "Expected '#{val}' to be false"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # HugResult struct
  # ---------------------------------------------------------------------------

  describe 'HugResult' do
    it 'returns true for zero? when hugs is 0' do
      result = PlantHeal::HugResult.new(0, :no_plant)
      expect(result.zero?).to be true
    end

    it 'returns false for zero? when hugs is positive' do
      result = PlantHeal::HugResult.new(1, :ok)
      expect(result.zero?).to be false
    end

    it 'stores hugs count' do
      result = PlantHeal::HugResult.new(5, :ok)
      expect(result.hugs).to eq(5)
    end

    it 'stores reason symbol' do
      result = PlantHeal::HugResult.new(0, :fully_healed)
      expect(result.reason).to eq(:fully_healed)
    end

    it 'supports all valid reason symbols' do
      %i[ok no_plant fully_healed stopped_early].each do |reason|
        result = PlantHeal::HugResult.new(0, reason)
        expect(result.reason).to eq(reason)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # validate_ev_waggle!
  # ---------------------------------------------------------------------------

  describe '#validate_ev_waggle!' do
    it 'exits when ev_waggle is nil' do
      instance = build_instance(ev_waggle: nil)
      expect(DRC).to receive(:message).with(/waggle_set 'plantheal' is required/)
      expect { instance.send(:validate_ev_waggle!) }.to raise_error(SystemExit)
    end

    it 'exits when EV spell key is missing from waggle' do
      instance = build_instance(ev_waggle: { 'Heal' => {} })
      expect(DRC).to receive(:message).with(/must contain an 'Embrace of the Vela'Tohr' spell entry/)
      expect(DRC).to receive(:message).with(/Found keys: Heal/)
      expect { instance.send(:validate_ev_waggle!) }.to raise_error(SystemExit)
    end

    it 'does not exit when EV spell key is present' do
      instance = build_instance(ev_waggle: { "Embrace of the Vela'Tohr" => {} })
      expect(DRC).not_to receive(:message)
      expect { instance.send(:validate_ev_waggle!) }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  describe 'constants' do
    it 'defines PASSIVE_HEAL_POLL_INTERVAL as 5' do
      expect(PlantHeal::PASSIVE_HEAL_POLL_INTERVAL).to eq(5)
    end

    it 'defines PASSIVE_HEAL_MAX_WAIT as 120' do
      expect(PlantHeal::PASSIVE_HEAL_MAX_WAIT).to eq(120)
    end

    it 'defines EV_SPELL_KEY' do
      expect(PlantHeal::EV_SPELL_KEY).to eq("Embrace of the Vela'Tohr")
    end

    it 'defines MAX_BACKFIRE_RETRIES as 2' do
      expect(PlantHeal::MAX_BACKFIRE_RETRIES).to eq(2)
    end

    it 'defines MAX_HUG_RETRIES as 3' do
      expect(PlantHeal::MAX_HUG_RETRIES).to eq(3)
    end

    it 'defines PLANT_NOUNS regex matching plant forms' do
      %w[plant thicket bush briar shrub thornbush].each do |form|
        expect("a vela'tohr #{form}").to match(PlantHeal::PLANT_NOUNS)
      end
    end

    it 'defines NO_HEAL_NEEDED regex' do
      expect('The plant has no need of healing.').to match(PlantHeal::NO_HEAL_NEEDED)
    end

    it 'defines HUG_APPRECIATES regex' do
      expect('The plant appreciates the sentiment').to match(PlantHeal::HUG_APPRECIATES)
    end
  end

  # ---------------------------------------------------------------------------
  # ev_spell_data
  # ---------------------------------------------------------------------------

  describe '#ev_spell_data' do
    it 'returns nil when ev_waggle is nil' do
      instance = build_instance(ev_waggle: nil)
      expect(instance.send(:ev_spell_data)).to be_nil
    end

    it 'returns EV spell hash from waggle' do
      ev_data = { 'mana' => 40, 'focus' => 'orb' }
      instance = build_instance(ev_waggle: { "Embrace of the Vela'Tohr" => ev_data })
      expect(instance.send(:ev_spell_data)).to eq(ev_data)
    end
  end

  # ---------------------------------------------------------------------------
  # to_bool helper
  # ---------------------------------------------------------------------------

  describe '#to_bool' do
    let(:instance) { PlantHeal.allocate }

    it 'returns default when val is nil' do
      expect(instance.send(:to_bool, nil, true)).to eq(true)
      expect(instance.send(:to_bool, nil, false)).to eq(false)
    end

    it 'returns true for truthy strings' do
      %w[true TRUE True 1 yes YES Yes y Y].each do |val|
        expect(instance.send(:to_bool, val, false)).to eq(true), "Expected '#{val}' to be true"
      end
    end

    it 'returns false for non-truthy strings' do
      %w[false FALSE 0 no NO n N nope anything].each do |val|
        expect(instance.send(:to_bool, val, true)).to eq(false), "Expected '#{val}' to be false"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # hug_plant_once retry behavior
  # ---------------------------------------------------------------------------

  describe '#hug_plant_once' do
    # Mock DRRoom for plant_noun_in_room
    before(:each) do
      stub_const('DRRoom', Class.new do
        def self.room_objs
          $mock_room_objs || []
        end
      end)
    end

    it 'returns stopped_early when retries exhausted' do
      instance = build_instance(
        total_hugs: 0,
        hug_count: 3,
        threshold: 24,
        heal_past_ml: false
      )
      $mock_room_objs = ["an ethereal vela'tohr thicket"]
      expect(DRC).to receive(:message).with(/Max hug retries reached/)
      result = instance.send(:hug_plant_once, 0)
      expect(result.zero?).to be true
      expect(result.reason).to eq(:stopped_early)
    end

    it 'retries after HUG_APPRECIATES response' do
      instance = build_instance(
        total_hugs: 0,
        hug_count: 3,
        threshold: 24,
        heal_past_ml: false,
        waggle_healing: false,
        manual_ev: false
      )
      $mock_room_objs = ["an ethereal vela'tohr thicket"]

      # First call: appreciates, second call: Roundtime
      call_count = 0
      allow(DRC).to receive(:bput) do |cmd, *_patterns|
        if cmd.start_with?('hug')
          call_count += 1
          call_count == 1 ? 'appreciates the sentiment' : 'Roundtime: 3 sec.'
        end
      end

      # Stub methods that would normally run
      allow(instance).to receive(:bleeding?).and_return(false)
      allow(instance).to receive(:pre_hug_check).and_return('thicket')
      allow(instance).to receive(:release_and_recast_ev)
      allow(DRSkill).to receive(:getxp).and_return(0)
      allow(DRC).to receive(:message)

      result = instance.send(:hug_plant_once, 3)
      expect(result.hugs).to eq(1)
      expect(result.reason).to eq(:ok)
      expect(call_count).to eq(2)
    end

    it 'retries after "no empathic bond" response' do
      instance = build_instance(
        total_hugs: 0,
        hug_count: 3,
        threshold: 24,
        heal_past_ml: false,
        waggle_healing: false,
        manual_ev: false
      )
      $mock_room_objs = ["an ethereal vela'tohr thicket"]

      # First call: no bond, second call: Roundtime
      call_count = 0
      allow(DRC).to receive(:bput) do |cmd, *_patterns|
        if cmd.start_with?('hug')
          call_count += 1
          call_count == 1 ? 'you have no empathic bond' : 'Roundtime: 3 sec.'
        end
      end

      allow(instance).to receive(:bleeding?).and_return(false)
      allow(instance).to receive(:pre_hug_check).and_return('thicket')
      allow(instance).to receive(:release_and_recast_ev)
      allow(DRSkill).to receive(:getxp).and_return(0)
      allow(DRC).to receive(:message)

      result = instance.send(:hug_plant_once, 3)
      expect(result.hugs).to eq(1)
      expect(result.reason).to eq(:ok)
      expect(call_count).to eq(2)
    end

    it 'decrements retry counter on each retry' do
      instance = build_instance(
        total_hugs: 0,
        hug_count: 3,
        threshold: 24,
        heal_past_ml: false,
        waggle_healing: false,
        manual_ev: false
      )
      $mock_room_objs = ["an ethereal vela'tohr thicket"]

      # Always return appreciates to force retry until exhausted
      allow(DRC).to receive(:bput) do |cmd, *_patterns|
        cmd.start_with?('hug') ? 'appreciates the sentiment' : nil
      end

      allow(instance).to receive(:bleeding?).and_return(false)
      allow(instance).to receive(:pre_hug_check).and_return('thicket')
      allow(instance).to receive(:release_and_recast_ev)
      allow(DRSkill).to receive(:getxp).and_return(0)
      allow(DRC).to receive(:message)

      result = instance.send(:hug_plant_once, 2)
      expect(result.zero?).to be true
      expect(result.reason).to eq(:stopped_early)
    end
  end
end
