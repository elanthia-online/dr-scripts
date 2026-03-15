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
    def wait_for_script_to_complete(*_args); end
    def message(_msg); end
  end
end unless defined?(DRC)

module DRCT
  class << self
    def walk_to(_room_id); end
  end
end unless defined?(DRCT)

Harness::DRSkill.define_singleton_method(:_xp_store) { @_xp_store ||= {} }
Harness::DRSkill.define_singleton_method(:_set_xp) { |skillname, val| _xp_store[skillname] = val }
Harness::DRSkill.define_singleton_method(:_reset_xp) { @_xp_store = {} }
Harness::DRSkill.define_singleton_method(:getxp) { |skillname| _xp_store[skillname] || 0 }

load_lic_class('athletics.lic', 'Athletics')

RSpec.describe Athletics do
  before(:each) do
    reset_data
    Harness::DRSkill._reset_xp

    allow(DRC).to receive(:wait_for_script_to_complete)
    allow(DRC).to receive(:bput)
    allow(DRCT).to receive(:walk_to)
  end

  describe '#outdoorsmanship_waiting' do
    let(:athletics) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@outdoorsmanship_rooms, [])
        a.instance_variable_set(:@settings, OpenStruct.new(held_athletics_items: []))
      end
    end

    context 'when skip_magic is enabled' do
      before do
        athletics.instance_variable_set(:@skip_magic, true)
      end

      it 'forwards skip_magic to the outdoorsmanship script' do
        expect(DRC).to receive(:wait_for_script_to_complete).with(
          'outdoorsmanship',
          [4, "room=#{Room.current.id}", 'rock', 'skip_magic']
        )
        athletics.outdoorsmanship_waiting(4)
      end
    end

    context 'when skip_magic is not set' do
      before do
        athletics.instance_variable_set(:@skip_magic, nil)
      end

      it 'passes an empty string for the skip_magic argument' do
        expect(DRC).to receive(:wait_for_script_to_complete).with(
          'outdoorsmanship',
          [3, "room=#{Room.current.id}", 'rock', '']
        )
        athletics.outdoorsmanship_waiting(3)
      end
    end

    context 'with outdoorsmanship rooms configured' do
      before do
        athletics.instance_variable_set(:@skip_magic, nil)
        athletics.instance_variable_set(:@outdoorsmanship_rooms, [5678, 9012])
      end

      it 'walks to a random room before starting outdoorsmanship' do
        expect(DRCT).to receive(:walk_to).with(satisfy { |id| [5678, 9012].include?(id) })
        athletics.outdoorsmanship_waiting(4)
      end
    end

    context 'with no outdoorsmanship rooms configured' do
      before do
        athletics.instance_variable_set(:@skip_magic, nil)
        athletics.instance_variable_set(:@outdoorsmanship_rooms, [])
      end

      it 'does not walk to a room before starting outdoorsmanship' do
        expect(DRCT).not_to receive(:walk_to)
        athletics.outdoorsmanship_waiting(4)
      end
    end
  end

  describe '#done_training?' do
    let(:athletics) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@end_exp, 29)
      end
    end

    context 'when Athletics XP is below the target' do
      before { Harness::DRSkill._set_xp('Athletics', 15) }

      it 'returns false' do
        expect(athletics.done_training?).to be false
      end
    end

    context 'when Athletics XP meets the target' do
      before { Harness::DRSkill._set_xp('Athletics', 29) }

      it 'returns true' do
        expect(athletics.done_training?).to be true
      end
    end

    context 'when Athletics XP exceeds the target' do
      before { Harness::DRSkill._set_xp('Athletics', 34) }

      it 'returns true' do
        expect(athletics.done_training?).to be true
      end
    end
  end
end
