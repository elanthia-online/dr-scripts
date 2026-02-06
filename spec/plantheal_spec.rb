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
  end

  # Helper: create a bare PlantHeal instance without running initialize
  def build_instance
    PlantHeal.allocate
  end

  describe '#validate_healing_spells!' do
    context 'when character knows Heal and Adaptive Curing' do
      it 'does not warn about HW or HS' do
        DRSpells._set_known_spells({ 'Heal' => true, 'Adaptive Curing' => true })
        instance = build_instance
        expect(DRC).not_to receive(:message)
        instance.send(:validate_healing_spells!)
      end
    end

    context 'when character knows Heal + Adaptive Curing + HW + HS' do
      it 'does not warn (Heal+AC gates the check)' do
        DRSpells._set_known_spells({ 'Heal' => true, 'Adaptive Curing' => true, 'Heal Wounds' => true, 'Heal Scars' => true })
        instance = build_instance
        expect(DRC).not_to receive(:message)
        instance.send(:validate_healing_spells!)
      end
    end

    context 'when character knows HW and HS but not Heal+AC' do
      it 'does not warn (HW + HS are sufficient)' do
        DRSpells._set_known_spells({ 'Heal Wounds' => true, 'Heal Scars' => true })
        instance = build_instance
        expect(DRC).not_to receive(:message)
        instance.send(:validate_healing_spells!)
      end
    end

    context 'when character knows nothing' do
      it 'warns about both HW and HS' do
        DRSpells._set_known_spells({})
        instance = build_instance
        expect(DRC).to receive(:message).with(/Heal Wounds \(HW\)/).once
        expect(DRC).to receive(:message).with(/Heal Scars \(HS\)/).once
        instance.send(:validate_healing_spells!)
      end
    end

    context 'when character knows HW but not HS' do
      it 'warns about HS only' do
        DRSpells._set_known_spells({ 'Heal Wounds' => true })
        instance = build_instance
        expect(DRC).not_to receive(:message).with(/Heal Wounds \(HW\)/)
        expect(DRC).to receive(:message).with(/Heal Scars \(HS\)/).once
        instance.send(:validate_healing_spells!)
      end
    end

    context 'when character knows HS but not HW' do
      it 'warns about HW only' do
        DRSpells._set_known_spells({ 'Heal Scars' => true })
        instance = build_instance
        expect(DRC).to receive(:message).with(/Heal Wounds \(HW\)/).once
        expect(DRC).not_to receive(:message).with(/Heal Scars \(HS\)/)
        instance.send(:validate_healing_spells!)
      end
    end

    context 'when character knows Heal only (without Adaptive Curing)' do
      it 'warns about both HW and HS (Heal alone is not sufficient)' do
        DRSpells._set_known_spells({ 'Heal' => true })
        instance = build_instance
        expect(DRC).to receive(:message).with(/Heal Wounds \(HW\)/).once
        expect(DRC).to receive(:message).with(/Heal Scars \(HS\)/).once
        instance.send(:validate_healing_spells!)
      end
    end

    context 'when character knows Adaptive Curing only (without Heal)' do
      it 'warns about both HW and HS (AC alone is not sufficient)' do
        DRSpells._set_known_spells({ 'Adaptive Curing' => true })
        instance = build_instance
        expect(DRC).to receive(:message).with(/Heal Wounds \(HW\)/).once
        expect(DRC).to receive(:message).with(/Heal Scars \(HS\)/).once
        instance.send(:validate_healing_spells!)
      end
    end

    context 'when character knows Heal (no AC) + HW but not HS' do
      it 'warns about HS only (falls through to HW/HS check)' do
        DRSpells._set_known_spells({ 'Heal' => true, 'Heal Wounds' => true })
        instance = build_instance
        expect(DRC).not_to receive(:message).with(/Heal Wounds \(HW\)/)
        expect(DRC).to receive(:message).with(/Heal Scars \(HS\)/).once
        instance.send(:validate_healing_spells!)
      end
    end

    context 'when character knows Heal (no AC) + HS but not HW' do
      it 'warns about HW only (falls through to HW/HS check)' do
        DRSpells._set_known_spells({ 'Heal' => true, 'Heal Scars' => true })
        instance = build_instance
        expect(DRC).to receive(:message).with(/Heal Wounds \(HW\)/).once
        expect(DRC).not_to receive(:message).with(/Heal Scars \(HS\)/)
        instance.send(:validate_healing_spells!)
      end
    end

    context 'warning message content' do
      it 'includes healme context in HW warning' do
        DRSpells._set_known_spells({})
        instance = build_instance
        expect(DRC).to receive(:message).with("**WARNING: You don't know Heal Wounds (HW)!** healme may not work properly.")
        expect(DRC).to receive(:message).with("**WARNING: You don't know Heal Scars (HS)!** healme may not work properly.")
        instance.send(:validate_healing_spells!)
      end
    end

    context 'when known_spells values are falsy (nil)' do
      it 'treats nil values as not known and warns' do
        DRSpells._set_known_spells({ 'Heal' => nil, 'Adaptive Curing' => nil })
        instance = build_instance
        expect(DRC).to receive(:message).with(/Heal Wounds \(HW\)/).once
        expect(DRC).to receive(:message).with(/Heal Scars \(HS\)/).once
        instance.send(:validate_healing_spells!)
      end
    end

    context 'when known_spells values are false' do
      it 'treats false values as not known and warns' do
        DRSpells._set_known_spells({ 'Heal' => false, 'Adaptive Curing' => false })
        instance = build_instance
        expect(DRC).to receive(:message).with(/Heal Wounds \(HW\)/).once
        expect(DRC).to receive(:message).with(/Heal Scars \(HS\)/).once
        instance.send(:validate_healing_spells!)
      end
    end
  end
end
