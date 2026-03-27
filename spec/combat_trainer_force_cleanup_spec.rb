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
  end
end

module DRCI
  class << self
    def lower_item?(*_args)
      true
    end

    def get_item?(*_args)
      true
    end

    def dispose_trash(*_args); end

    def wear_item?(*_args)
      true
    end

    def fill_gem_pouch_with_container(*_args); end

    def count_all_boxes(*_args)
      0
    end
  end
end

module DRCMM
  class << self
    def wear_moon_weapon?
      false
    end

    def hold_moon_weapon?
      false
    end
  end
end

module DRCS
  class << self
    def break_summoned_weapon(*_args); end
  end
end

$debug_mode_ct = false

load_lic_class('combat-trainer.lic', 'GameState')

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end
end

# ===========================================================================
# GameState#force_cleanup specs
#
# Validates that force_cleanup advances the cleanup state machine past the
# 'kill' phase, and is a no-op in all other states. This is the safety net
# for when finishing the last mob takes too long (e.g. ranged weapons with
# long aim cycles in multi-mob areas).
# ===========================================================================
RSpec.describe GameState do
  def build_game_state(**overrides)
    instance = GameState.allocate
    defaults = {
      clean_up_step: nil,
      skip_last_kill: false,
      stop_on_bleeding: false
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  describe '#force_cleanup' do
    context 'when in the kill phase' do
      it 'advances to clear_magic' do
        gs = build_game_state(clean_up_step: 'kill')

        gs.force_cleanup

        expect(gs.finish_killing?).to be false
        expect(gs.finish_spell_casting?).to be true
      end

      it 'is idempotent -- calling twice stays at clear_magic' do
        gs = build_game_state(clean_up_step: 'kill')

        gs.force_cleanup
        gs.force_cleanup

        expect(gs.finish_spell_casting?).to be true
      end
    end

    # ------------------------------------------------------------------
    # Adversarial: force_cleanup must not disrupt cleanup states that have
    # already progressed past 'kill'. A bug here could skip stowing or
    # cause the state machine to regress.
    # ------------------------------------------------------------------
    shared_examples 'no-op for non-kill phase' do |phase, description|
      context "when in the #{description} phase (#{phase.inspect})" do
        it 'does not change the cleanup step' do
          gs = build_game_state(clean_up_step: phase)

          gs.force_cleanup

          expect(gs.instance_variable_get(:@clean_up_step)).to eq(phase)
        end
      end
    end

    include_examples 'no-op for non-kill phase', nil, 'not yet cleaning up'
    include_examples 'no-op for non-kill phase', 'clear_magic', 'clear_magic'
    include_examples 'no-op for non-kill phase', 'dismiss_pet', 'dismiss_pet'
    include_examples 'no-op for non-kill phase', 'stow', 'stow'
    include_examples 'no-op for non-kill phase', 'done', 'done'

    # ------------------------------------------------------------------
    # Adversarial: garbage or unexpected values must not be treated as
    # 'kill'. The guard is an equality check, not a pattern match.
    # ------------------------------------------------------------------
    context 'when clean_up_step has an unexpected value' do
      it 'does not change the cleanup step' do
        gs = build_game_state(clean_up_step: 'bogus')

        gs.force_cleanup

        expect(gs.instance_variable_get(:@clean_up_step)).to eq('bogus')
      end
    end
  end

  # ===========================================================================
  # next_clean_up_step interaction with force_cleanup
  #
  # Validates that the normal state machine and force_cleanup compose
  # correctly -- force_cleanup mid-kill should allow normal progression
  # to resume from clear_magic onward.
  # ===========================================================================
  describe '#next_clean_up_step after force_cleanup' do
    it 'resumes normal progression from clear_magic through done' do
      gs = build_game_state(clean_up_step: 'kill')

      gs.force_cleanup
      expect(gs.finish_spell_casting?).to be true

      gs.next_clean_up_step
      expect(gs.dismiss_pet?).to be true

      gs.next_clean_up_step
      expect(gs.stowing?).to be true

      gs.next_clean_up_step
      expect(gs.done_cleaning_up?).to be true
    end
  end

  # ===========================================================================
  # next_clean_up_step with skip_last_kill
  #
  # When skip_last_kill is true, next_clean_up_step skips 'kill' entirely.
  # force_cleanup should never be needed, but if called on the resulting
  # 'clear_magic' state it must be a no-op.
  # ===========================================================================
  describe '#next_clean_up_step with skip_last_kill' do
    it 'skips kill and goes directly to clear_magic' do
      gs = build_game_state(skip_last_kill: true)

      gs.next_clean_up_step

      expect(gs.finish_killing?).to be false
      expect(gs.finish_spell_casting?).to be true
    end

    it 'force_cleanup is a no-op when skip_last_kill already skipped kill' do
      gs = build_game_state(skip_last_kill: true)

      gs.next_clean_up_step
      gs.force_cleanup

      expect(gs.finish_spell_casting?).to be true
    end
  end

  # ===========================================================================
  # Predicate consistency
  #
  # Validates that the predicates agree with the state after force_cleanup.
  # A mismatch here could cause the main loop to get stuck or skip steps.
  # ===========================================================================
  describe 'predicate consistency after force_cleanup' do
    it 'cleaning_up? remains true' do
      gs = build_game_state(clean_up_step: 'kill')

      gs.force_cleanup

      expect(gs.cleaning_up?).to be true
    end

    it 'done_cleaning_up? is false' do
      gs = build_game_state(clean_up_step: 'kill')

      gs.force_cleanup

      expect(gs.done_cleaning_up?).to be false
    end

    it 'finish_killing? is false' do
      gs = build_game_state(clean_up_step: 'kill')

      gs.force_cleanup

      expect(gs.finish_killing?).to be false
    end

    it 'stowing? is false' do
      gs = build_game_state(clean_up_step: 'kill')

      gs.force_cleanup

      expect(gs.stowing?).to be false
    end
  end
end
