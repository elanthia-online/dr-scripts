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
  end
end
