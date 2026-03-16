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
    def bput(*_args); end
    def collect(*_args); end
    def forage?(*_args); end
    def retreat(*_args); end
    def wait_for_script_to_complete(*_args); end
    def message(_msg); end
  end
end unless defined?(DRC)

DRC.define_singleton_method(:collect) { |*_args| } unless DRC.respond_to?(:collect)
DRC.define_singleton_method(:forage?) { |*_args| } unless DRC.respond_to?(:forage?)
DRC.define_singleton_method(:retreat) { |*_args| } unless DRC.respond_to?(:retreat)

module DRCI
  class << self
    def in_hands?(_item); false; end
    def dispose_trash(*_args); end
  end
end unless defined?(DRCI)

DRCI.define_singleton_method(:dispose_trash) { |*_args| } unless DRCI.respond_to?(:dispose_trash)

module DRCA
  class << self
    def crafting_magic_routine(*_args); end
  end
end unless defined?(DRCA)

module DRCT
  class << self
    def walk_to(_room_id); end
  end
end unless defined?(DRCT)

Harness::DRSkill.define_singleton_method(:_xp_store) { @_xp_store ||= {} }
Harness::DRSkill.define_singleton_method(:_set_xp) { |skillname, val| _xp_store[skillname] = val }
Harness::DRSkill.define_singleton_method(:_reset_xp) { @_xp_store = {} }
Harness::DRSkill.define_singleton_method(:getxp) { |skillname| _xp_store[skillname] || 0 }

load_lic_class('outdoorsmanship.lic', 'Outdoorsmanship')

RSpec.describe Outdoorsmanship do
  before(:each) do
    reset_data
    Harness::DRSkill._reset_xp

    allow(DRC).to receive(:collect)
    allow(DRC).to receive(:forage?)
    allow(DRC).to receive(:retreat)
    allow(DRC).to receive(:bput)
    allow(DRCI).to receive(:in_hands?).and_return(false)
    allow(DRCI).to receive(:dispose_trash)
    allow(DRCA).to receive(:crafting_magic_routine)
  end

  # Helper to build an Outdoorsmanship instance without calling initialize
  def build_outdoorsmanship(overrides = {})
    defaults = {
      settings: OpenStruct.new(crafting_training_spells: []),
      training_spells: [],
      skill_name: 'Outdoorsmanship',
      end_exp: 34,
      targetxp: 3,
      forage_item: 'rock',
      train_method: 'collect',
      skip_magic: true,
      worn_trashcan: nil,
      worn_trashcan_verb: nil
    }
    described_class.allocate.tap do |o|
      defaults.merge(overrides).each do |key, value|
        o.instance_variable_set(:"@#{key}", value)
      end
    end
  end

  describe '#train_outdoorsmanship' do
    context 'when collecting' do
      let(:outdoorsmanship) { build_outdoorsmanship(train_method: 'collect') }

      before { Harness::DRSkill._set_xp('Outdoorsmanship', 0) }

      it 'terminates after targetxp collect attempts when XP stays low' do
        expect(DRC).to receive(:collect).with('rock').exactly(3).times
        outdoorsmanship.train_outdoorsmanship
      end

      it 'stops collecting early when XP reaches the target' do
        call_count = 0
        allow(DRC).to receive(:collect) do
          call_count += 1
          Harness::DRSkill._set_xp('Outdoorsmanship', 34) if call_count == 2
        end
        outdoorsmanship.train_outdoorsmanship
        expect(call_count).to eq(2)
      end

      it 'passes forage_item directly to collect without local alias' do
        obj = build_outdoorsmanship(train_method: 'collect', forage_item: 'jadice flower')
        expect(DRC).to receive(:collect).with('jadice flower').exactly(3).times
        obj.train_outdoorsmanship
      end
    end

    context 'when foraging' do
      let(:outdoorsmanship) { build_outdoorsmanship(train_method: 'forage') }

      before { Harness::DRSkill._set_xp('Outdoorsmanship', 0) }

      it 'terminates after targetxp forage attempts' do
        expect(DRC).to receive(:forage?).with('rock').exactly(3).times
        outdoorsmanship.train_outdoorsmanship
      end

      it 'disposes foraged items found in hands' do
        allow(DRCI).to receive(:in_hands?).with('rock').and_return(true)
        expect(DRCI).to receive(:dispose_trash).with('rock', nil, nil).exactly(3).times
        outdoorsmanship.train_outdoorsmanship
      end

      it 'skips disposal when item is not in hands' do
        allow(DRCI).to receive(:in_hands?).with('rock').and_return(false)
        expect(DRCI).not_to receive(:dispose_trash)
        outdoorsmanship.train_outdoorsmanship
      end
    end

    context 'combat retreat' do
      before { Harness::DRSkill._set_xp('Outdoorsmanship', 0) }

      it 'retreats before each forage attempt' do
        obj = build_outdoorsmanship(train_method: 'forage', targetxp: 2)
        expect(DRC).to receive(:retreat).exactly(2).times.ordered
        allow(DRC).to receive(:forage?)
        obj.train_outdoorsmanship
      end

      it 'retreats before each collect attempt' do
        obj = build_outdoorsmanship(train_method: 'collect', targetxp: 2)
        expect(DRC).to receive(:retreat).exactly(2).times.ordered
        allow(DRC).to receive(:collect)
        obj.train_outdoorsmanship
      end

      it 'retreats before crafting magic routine, not after' do
        obj = build_outdoorsmanship(train_method: 'collect', targetxp: 1, skip_magic: false)
        call_order = []
        allow(DRC).to receive(:retreat) { call_order << :retreat }
        allow(DRCA).to receive(:crafting_magic_routine) { call_order << :magic }
        allow(DRC).to receive(:collect) { call_order << :collect }
        obj.train_outdoorsmanship
        expect(call_order).to eq([:retreat, :magic, :collect])
      end
    end

    context 'XP cap behavior' do
      it 'caps end_exp at MINDSTATE_CAP when start_exp + targetxp exceeds it' do
        Harness::DRSkill._set_xp('Outdoorsmanship', 30)
        obj = build_outdoorsmanship(
          train_method: 'collect',
          targetxp: 10,
          end_exp: [30 + 10, Outdoorsmanship::MINDSTATE_CAP].min
        )
        expect(obj.instance_variable_get(:@end_exp)).to eq(34)
      end

      it 'stops when XP reaches end_exp even if attempts remain' do
        Harness::DRSkill._set_xp('Outdoorsmanship', 32)
        obj = build_outdoorsmanship(train_method: 'collect', targetxp: 10, end_exp: 34)
        call_count = 0
        allow(DRC).to receive(:collect) do
          call_count += 1
          Harness::DRSkill._set_xp('Outdoorsmanship', 34)
        end
        obj.train_outdoorsmanship
        expect(call_count).to eq(1)
      end
    end

    context 'perception mode' do
      it 'checks Perception XP instead of Outdoorsmanship' do
        Harness::DRSkill._set_xp('Perception', 0)
        Harness::DRSkill._set_xp('Outdoorsmanship', 34) # would stop if checking wrong skill
        obj = build_outdoorsmanship(train_method: 'collect', skill_name: 'Perception', targetxp: 2)
        expect(DRC).to receive(:collect).exactly(2).times
        obj.train_outdoorsmanship
      end
    end

    context 'magic integration' do
      before { Harness::DRSkill._set_xp('Outdoorsmanship', 0) }

      it 'calls crafting_magic_routine each iteration when magic enabled' do
        obj = build_outdoorsmanship(train_method: 'collect', skip_magic: false, targetxp: 3)
        expect(DRCA).to receive(:crafting_magic_routine).exactly(3).times
        obj.train_outdoorsmanship
      end

      it 'skips crafting_magic_routine when skip_magic is true' do
        obj = build_outdoorsmanship(train_method: 'collect', skip_magic: true, targetxp: 3)
        expect(DRCA).not_to receive(:crafting_magic_routine)
        obj.train_outdoorsmanship
      end

      it 'calls magic_cleanup at the end when magic enabled' do
        obj = build_outdoorsmanship(
          train_method: 'collect',
          skip_magic: false,
          targetxp: 1,
          training_spells: ['spell']
        )
        expect(DRC).to receive(:bput).with('release spell', anything, anything)
        expect(DRC).to receive(:bput).with('release mana', anything, anything)
        obj.train_outdoorsmanship
      end
    end
  end

  describe '#magic_cleanup' do
    it 'skips releasing when skip_magic is true' do
      obj = build_outdoorsmanship(skip_magic: true, training_spells: ['spell'])
      expect(DRC).not_to receive(:bput)
      obj.magic_cleanup
    end

    it 'skips releasing when training_spells is empty' do
      obj = build_outdoorsmanship(skip_magic: false, training_spells: [])
      expect(DRC).not_to receive(:bput)
      obj.magic_cleanup
    end

    it 'releases spell and mana when magic was used' do
      obj = build_outdoorsmanship(skip_magic: false, training_spells: ['spell'])
      expect(DRC).to receive(:bput).with('release spell', anything, anything)
      expect(DRC).to receive(:bput).with('release mana', anything, anything)
      obj.magic_cleanup
    end
  end

  describe '#validate_settings' do
    it 'does not exit when outdoors_room is nil' do
      obj = build_outdoorsmanship(outdoors_room: nil, forage_item: 'rock')
      expect { obj.validate_settings }.not_to raise_error
    end

    it 'exits with message when forage_item is nil' do
      obj = build_outdoorsmanship(outdoors_room: 1234, forage_item: nil)
      expect(DRC).to receive(:message).with(/forage_item/)
      expect { obj.validate_settings }.to raise_error(SystemExit)
    end

    it 'exits with message when targetxp is zero' do
      obj = build_outdoorsmanship(outdoors_room: 1234, forage_item: 'rock', targetxp: 0)
      expect(DRC).to receive(:message).with(/mindstate goal must be positive/)
      expect { obj.validate_settings }.to raise_error(SystemExit)
    end

    it 'exits with message when targetxp is negative' do
      obj = build_outdoorsmanship(outdoors_room: 1234, forage_item: 'rock', targetxp: -1)
      expect(DRC).to receive(:message).with(/mindstate goal must be positive/)
      expect { obj.validate_settings }.to raise_error(SystemExit)
    end

    it 'does not exit when all settings are valid' do
      obj = build_outdoorsmanship(outdoors_room: 1234, forage_item: 'rock', targetxp: 3)
      expect { obj.validate_settings }.not_to raise_error
    end
  end

  describe '#validate_settings — already at cap' do
    it 'exits with message when skill XP already at end_exp' do
      Harness::DRSkill._set_xp('Outdoorsmanship', 34)
      obj = build_outdoorsmanship(end_exp: 34, outdoors_room: 1234, forage_item: 'rock')
      expect(DRC).to receive(:message).with(/already at/)
      expect { obj.validate_settings }.to raise_error(SystemExit)
    end

    it 'exits before walking or buffing' do
      Harness::DRSkill._set_xp('Outdoorsmanship', 34)
      obj = build_outdoorsmanship(end_exp: 34, outdoors_room: 1234, forage_item: 'rock')
      allow(DRC).to receive(:message)
      expect(DRCT).not_to receive(:walk_to)
      expect(DRC).not_to receive(:collect)
      expect { obj.validate_settings }.to raise_error(SystemExit)
    end
  end

  describe 'constants' do
    it 'defines MINDSTATE_CAP as 34' do
      expect(Outdoorsmanship::MINDSTATE_CAP).to eq(34)
    end

    it 'defines FORAGE_RANK_THRESHOLD as 20' do
      expect(Outdoorsmanship::FORAGE_RANK_THRESHOLD).to eq(20)
    end
  end
end
