require_relative 'spec_helper'

# SigilHarvest's initialize method interacts heavily with the game environment
# (DRC.bput, get_settings, parse_args, etc.), so we cannot call .new directly.
# Instead, we allocate a bare instance and inject the minimum instance variables
# needed to test each pure-logic method in isolation.
#
# This approach keeps tests fast, deterministic, and focused on the algorithm
# logic rather than game I/O plumbing.

RSpec.describe SigilHarvest do
  # Allocate a bare instance without calling initialize, then inject the
  # instance variables and lookup tables that the methods under test depend on.
  let(:harvester) { SigilHarvest.allocate }

  before(:each) do
    # Core lookup tables (copied from SigilHarvest#initialize)
    harvester.instance_variable_set(:@action_difficulty, {
      "trivial" => 1, "straightforward" => 2, "formidable" => 3,
      "challenging" => 4, "difficult" => 5
    })
    harvester.instance_variable_set(:@action_cost, {
      "taxing" => 1, "disrupting" => 1, "destroying" => 1
    })

    # Sensible defaults for minigame resource levels
    harvester.instance_variable_set(:@sanity_lvl, 10)
    harvester.instance_variable_set(:@resolve_lvl, 10)
    harvester.instance_variable_set(:@focus_lvl, 10)

    # Defaults for iteration and precision tracking
    harvester.instance_variable_set(:@num_iterations, 0)
    harvester.instance_variable_set(:@sigil_precision, 0)
    harvester.instance_variable_set(:@danger_lvl, 0)
    harvester.instance_variable_set(:@num_aspect_repairs, 0)
    harvester.instance_variable_set(:@actually_scribed, false)
    harvester.instance_variable_set(:@debug, false)

    # Time tracking
    harvester.instance_variable_set(:@start_time, Time.now)
    harvester.instance_variable_set(:@time_limit, 30)
  end

  # ---------------------------------------------------------------------------
  # Helper: build an action hash matching the parsed structure from sigil_info
  # ---------------------------------------------------------------------------
  def make_action(difficulty:, resource: 'sanity', impact: 1, verb: 'FOCUS', aspect: 'precision', target: 'sigil')
    risk = difficulty.to_i + impact.to_i
    {
      "difficulty" => difficulty,
      "resource"   => resource,
      "impact"     => impact,
      "verb"       => verb,
      "target"     => target,
      "aspect"     => aspect,
      "risk"       => risk
    }
  end

  # ===========================================================================
  # precision_action_viable?
  # ===========================================================================
  describe '#precision_action_viable?' do
    # The method signature: precision_action_viable?(action, contest_stat, precision)
    # It uses action['difficulty'] and computes margin = contest_stat - difficulty.

    context 'EXP-18: trivial difficulty filter' do
      it 'returns false when difficulty is 1 (trivial), even with high margin' do
        action = make_action(difficulty: 1)
        result = harvester.send(:precision_action_viable?, action, 10, 90)
        expect(result).to be false
      end

      it 'returns false when difficulty is 0 (below trivial)' do
        action = make_action(difficulty: 0)
        result = harvester.send(:precision_action_viable?, action, 10, 90)
        expect(result).to be false
      end
    end

    context 'Path 1: comfortable margin (margin > 1)' do
      it 'returns true for straightforward (2) with margin of 2' do
        # stat=4, difficulty=2 -> margin=2 > 1
        action = make_action(difficulty: 2)
        result = harvester.send(:precision_action_viable?, action, 4, 90)
        expect(result).to be true
      end

      it 'returns true for formidable (3) with margin of 3' do
        # stat=6, difficulty=3 -> margin=3 > 1
        action = make_action(difficulty: 3)
        result = harvester.send(:precision_action_viable?, action, 6, 90)
        expect(result).to be true
      end

      it 'returns true for difficult (5) with margin of 5' do
        # stat=10, difficulty=5 -> margin=5 > 1
        action = make_action(difficulty: 5)
        result = harvester.send(:precision_action_viable?, action, 10, 90)
        expect(result).to be true
      end
    end

    context 'Path 2: tight margin (margin > 0) with challenging+ difficulty (> 2)' do
      it 'returns true for challenging (4) with margin of 1' do
        # stat=5, difficulty=4 -> margin=1 > 0, difficulty=4 > 2
        action = make_action(difficulty: 4)
        result = harvester.send(:precision_action_viable?, action, 5, 90)
        expect(result).to be true
      end

      it 'returns true for formidable (3) with margin of 1' do
        # stat=4, difficulty=3 -> margin=1 > 0, difficulty=3 > 2
        action = make_action(difficulty: 3)
        result = harvester.send(:precision_action_viable?, action, 4, 90)
        expect(result).to be true
      end

      it 'returns true for difficult (5) with margin of 1' do
        # stat=6, difficulty=5 -> margin=1 > 0, difficulty=5 > 2
        action = make_action(difficulty: 5)
        result = harvester.send(:precision_action_viable?, action, 6, 90)
        expect(result).to be true
      end

      it 'returns false for straightforward (2) with margin of 1 -- difficulty not > 2' do
        # stat=3, difficulty=2 -> margin=1 > 0, but difficulty=2 is NOT > 2
        # Path 1 requires margin > 1 (fails: margin=1)
        # Path 2 requires difficulty > 2 (fails: difficulty=2)
        action = make_action(difficulty: 2)
        result = harvester.send(:precision_action_viable?, action, 3, 90)
        expect(result).to be false
      end
    end

    context 'EXP-12: margin == 0 is always rejected' do
      it 'returns false for challenging (4) with margin of 0' do
        # stat=4, difficulty=4 -> margin=0
        # Both paths require margin > 0, so this fails
        action = make_action(difficulty: 4)
        result = harvester.send(:precision_action_viable?, action, 4, 90)
        expect(result).to be false
      end

      it 'returns false for difficult (5) with margin of 0' do
        action = make_action(difficulty: 5)
        result = harvester.send(:precision_action_viable?, action, 5, 90)
        expect(result).to be false
      end

      it 'returns false for formidable (3) with margin of 0' do
        action = make_action(difficulty: 3)
        result = harvester.send(:precision_action_viable?, action, 3, 90)
        expect(result).to be false
      end
    end

    context 'negative margin (stat < difficulty)' do
      it 'returns false when stat is well below difficulty' do
        # stat=2, difficulty=5 -> margin=-3
        action = make_action(difficulty: 5)
        result = harvester.send(:precision_action_viable?, action, 2, 90)
        expect(result).to be false
      end

      it 'returns false for straightforward with negative margin' do
        # stat=1, difficulty=2 -> margin=-1
        action = make_action(difficulty: 2)
        result = harvester.send(:precision_action_viable?, action, 1, 90)
        expect(result).to be false
      end
    end

    context 'boundary: margin exactly 1' do
      it 'returns false for straightforward (2) -- margin=1, not > 1, difficulty not > 2' do
        action = make_action(difficulty: 2)
        result = harvester.send(:precision_action_viable?, action, 3, 90)
        expect(result).to be false
      end

      it 'returns true for formidable (3) -- margin=1, difficulty > 2' do
        action = make_action(difficulty: 3)
        result = harvester.send(:precision_action_viable?, action, 4, 90)
        expect(result).to be true
      end
    end

    context 'boundary: margin exactly 2' do
      it 'returns true for straightforward (2) -- margin=2 > 1' do
        action = make_action(difficulty: 2)
        result = harvester.send(:precision_action_viable?, action, 4, 90)
        expect(result).to be true
      end

      it 'returns true for difficult (5) -- margin=2 > 1' do
        action = make_action(difficulty: 5)
        result = harvester.send(:precision_action_viable?, action, 7, 90)
        expect(result).to be true
      end
    end

    context 'precision parameter is unused by the method' do
      # precision_action_viable? receives precision but does not use it.
      # Verify behavior is identical regardless of the precision value.
      it 'returns same result for different precision values' do
        action = make_action(difficulty: 3)
        result_low  = harvester.send(:precision_action_viable?, action, 6, 50)
        result_high = harvester.send(:precision_action_viable?, action, 6, 200)
        expect(result_low).to eq(result_high)
      end
    end
  end

  # ===========================================================================
  # contest_stat_for
  # ===========================================================================
  describe '#contest_stat_for' do
    before(:each) do
      harvester.instance_variable_set(:@sanity_lvl, 8)
      harvester.instance_variable_set(:@resolve_lvl, 12)
      harvester.instance_variable_set(:@focus_lvl, 5)
    end

    it 'returns @sanity_lvl for "sanity"' do
      expect(harvester.send(:contest_stat_for, 'sanity')).to eq(8)
    end

    it 'returns @resolve_lvl for "resolve"' do
      expect(harvester.send(:contest_stat_for, 'resolve')).to eq(12)
    end

    it 'returns @focus_lvl for "focus"' do
      expect(harvester.send(:contest_stat_for, 'focus')).to eq(5)
    end

    it 'returns 0 for an unknown resource' do
      expect(harvester.send(:contest_stat_for, 'mana')).to eq(0)
    end

    it 'returns 0 for nil resource' do
      expect(harvester.send(:contest_stat_for, nil)).to eq(0)
    end

    it 'returns 0 for empty string' do
      expect(harvester.send(:contest_stat_for, '')).to eq(0)
    end

    context 'when instance variable is nil' do
      it 'returns 0 for sanity when @sanity_lvl is nil' do
        harvester.instance_variable_set(:@sanity_lvl, nil)
        expect(harvester.send(:contest_stat_for, 'sanity')).to eq(0)
      end

      it 'returns 0 for resolve when @resolve_lvl is nil' do
        harvester.instance_variable_set(:@resolve_lvl, nil)
        expect(harvester.send(:contest_stat_for, 'resolve')).to eq(0)
      end

      it 'returns 0 for focus when @focus_lvl is nil' do
        harvester.instance_variable_set(:@focus_lvl, nil)
        expect(harvester.send(:contest_stat_for, 'focus')).to eq(0)
      end
    end
  end

  # ===========================================================================
  # format_techniques
  # ===========================================================================
  describe '#format_techniques' do
    it 'returns "none" for nil input' do
      expect(harvester.send(:format_techniques, nil)).to eq('none')
    end

    it 'returns "none" for empty array' do
      expect(harvester.send(:format_techniques, [])).to eq('none')
    end

    it 'strips " Sigil Comprehension" suffix from a single technique' do
      techniques = ['Awakened Sigil Comprehension']
      expect(harvester.send(:format_techniques, techniques)).to eq('Awakened')
    end

    it 'strips " Sigil Comprehension" suffix and joins multiple techniques' do
      techniques = ['Awakened Sigil Comprehension', 'Illuminated Sigil Comprehension']
      expect(harvester.send(:format_techniques, techniques)).to eq('Awakened, Illuminated')
    end

    it 'handles techniques that do not have the suffix' do
      techniques = ['Some Other Technique']
      expect(harvester.send(:format_techniques, techniques)).to eq('Some Other Technique')
    end

    it 'handles mix of suffixed and non-suffixed techniques' do
      techniques = ['Awakened Sigil Comprehension', 'Custom Technique']
      expect(harvester.send(:format_techniques, techniques)).to eq('Awakened, Custom Technique')
    end

    it 'handles a single technique without the suffix' do
      techniques = ['Mastery']
      expect(harvester.send(:format_techniques, techniques)).to eq('Mastery')
    end
  end

  # ===========================================================================
  # time_expired?
  # ===========================================================================
  describe '#time_expired?' do
    it 'returns false when well under the time limit' do
      harvester.instance_variable_set(:@start_time, Time.now)
      harvester.instance_variable_set(:@time_limit, 30)
      expect(harvester.send(:time_expired?)).to be false
    end

    it 'returns true when elapsed time equals the time limit' do
      harvester.instance_variable_set(:@start_time, Time.now - (30 * 60))
      harvester.instance_variable_set(:@time_limit, 30)
      expect(harvester.send(:time_expired?)).to be true
    end

    it 'returns true when elapsed time exceeds the time limit' do
      harvester.instance_variable_set(:@start_time, Time.now - (45 * 60))
      harvester.instance_variable_set(:@time_limit, 30)
      expect(harvester.send(:time_expired?)).to be true
    end

    it 'returns false with 1 minute remaining' do
      harvester.instance_variable_set(:@start_time, Time.now - (29 * 60))
      harvester.instance_variable_set(:@time_limit, 30)
      expect(harvester.send(:time_expired?)).to be false
    end

    it 'uses time_limit in minutes, not seconds' do
      # 5 minutes elapsed, 10 minute limit -> not expired
      harvester.instance_variable_set(:@start_time, Time.now - (5 * 60))
      harvester.instance_variable_set(:@time_limit, 10)
      expect(harvester.send(:time_expired?)).to be false
    end
  end

  # ===========================================================================
  # select_repair_action
  # ===========================================================================
  describe '#select_repair_action' do
    # Method signature:
    #   select_repair_action(action, contest_stat, precision, repair_target, current_repair)
    # Yields the selected repair action if it qualifies.
    #
    # Guard conditions (all must pass):
    #   1. action['difficulty'] <= 3
    #   2. repair_target has a "difficulty" key
    #   3. (contest_stat - action['difficulty']) >= 2
    #   4. @sigil_precision >= (precision - 15)
    #   5. action['aspect'] == repair_target['resource']
    # Then:
    #   - If current_repair has a "difficulty" key, yield only if current_repair['risk'] > action['risk']
    #   - Otherwise, yield unconditionally (first viable repair found)

    let(:repair_target) do
      # A precision action we want to repair: it consumes 'sanity' and is hard
      make_action(difficulty: 4, resource: 'sanity', aspect: 'precision')
    end

    let(:valid_repair_action) do
      # An action whose aspect matches the repair_target's resource ('sanity'),
      # difficulty is low (2), and the stat margin is comfortable
      make_action(difficulty: 2, resource: 'focus', aspect: 'sanity', verb: 'MEDITATE')
    end

    before(:each) do
      # Precision is close enough to target (within 15)
      harvester.instance_variable_set(:@sigil_precision, 80)
    end

    context 'when all guard conditions are met and no current repair exists' do
      it 'yields the action' do
        yielded = nil
        harvester.send(:select_repair_action, valid_repair_action, 10, 90, repair_target, {}) do |selected|
          yielded = selected
        end
        expect(yielded).to eq(valid_repair_action)
      end
    end

    context 'guard: difficulty must be <= 3' do
      it 'does not yield when action difficulty is 4' do
        hard_action = make_action(difficulty: 4, resource: 'focus', aspect: 'sanity')
        yielded = nil
        harvester.send(:select_repair_action, hard_action, 10, 90, repair_target, {}) do |selected|
          yielded = selected
        end
        expect(yielded).to be_nil
      end

      it 'does not yield when action difficulty is 5' do
        hard_action = make_action(difficulty: 5, resource: 'focus', aspect: 'sanity')
        yielded = nil
        harvester.send(:select_repair_action, hard_action, 10, 90, repair_target, {}) do |selected|
          yielded = selected
        end
        expect(yielded).to be_nil
      end

      it 'yields when action difficulty is exactly 3' do
        ok_action = make_action(difficulty: 3, resource: 'focus', aspect: 'sanity')
        yielded = nil
        harvester.send(:select_repair_action, ok_action, 10, 90, repair_target, {}) do |selected|
          yielded = selected
        end
        expect(yielded).to eq(ok_action)
      end
    end

    context 'guard: repair_target must have "difficulty" key' do
      it 'does not yield when repair_target is empty hash' do
        yielded = nil
        harvester.send(:select_repair_action, valid_repair_action, 10, 90, {}, {}) do |selected|
          yielded = selected
        end
        expect(yielded).to be_nil
      end
    end

    context 'guard: stat margin must be >= 2' do
      it 'does not yield when margin is 1 (stat=3, difficulty=2)' do
        yielded = nil
        harvester.send(:select_repair_action, valid_repair_action, 3, 90, repair_target, {}) do |selected|
          yielded = selected
        end
        expect(yielded).to be_nil
      end

      it 'does not yield when margin is 0 (stat=2, difficulty=2)' do
        yielded = nil
        harvester.send(:select_repair_action, valid_repair_action, 2, 90, repair_target, {}) do |selected|
          yielded = selected
        end
        expect(yielded).to be_nil
      end

      it 'yields when margin is exactly 2 (stat=4, difficulty=2)' do
        yielded = nil
        harvester.send(:select_repair_action, valid_repair_action, 4, 90, repair_target, {}) do |selected|
          yielded = selected
        end
        expect(yielded).to eq(valid_repair_action)
      end
    end

    context 'guard: precision must be within 15 of target' do
      it 'does not yield when precision is too far from target' do
        # @sigil_precision=70, precision=90 -> 70 >= 75 is false
        harvester.instance_variable_set(:@sigil_precision, 70)
        yielded = nil
        harvester.send(:select_repair_action, valid_repair_action, 10, 90, repair_target, {}) do |selected|
          yielded = selected
        end
        expect(yielded).to be_nil
      end

      it 'yields when precision is exactly 15 below target' do
        # @sigil_precision=75, precision=90 -> 75 >= 75 is true
        harvester.instance_variable_set(:@sigil_precision, 75)
        yielded = nil
        harvester.send(:select_repair_action, valid_repair_action, 10, 90, repair_target, {}) do |selected|
          yielded = selected
        end
        expect(yielded).to eq(valid_repair_action)
      end

      it 'does not yield when precision is 16 below target' do
        # @sigil_precision=74, precision=90 -> 74 >= 75 is false
        harvester.instance_variable_set(:@sigil_precision, 74)
        yielded = nil
        harvester.send(:select_repair_action, valid_repair_action, 10, 90, repair_target, {}) do |selected|
          yielded = selected
        end
        expect(yielded).to be_nil
      end
    end

    context 'guard: action aspect must match repair_target resource' do
      it 'does not yield when aspect does not match resource' do
        wrong_aspect = make_action(difficulty: 2, resource: 'focus', aspect: 'resolve')
        yielded = nil
        harvester.send(:select_repair_action, wrong_aspect, 10, 90, repair_target, {}) do |selected|
          yielded = selected
        end
        expect(yielded).to be_nil
      end
    end

    context 'when a current repair already exists' do
      it 'yields if new action has lower risk than current repair' do
        # current_repair has risk=5, new action has risk=3
        current = make_action(difficulty: 3, resource: 'focus', aspect: 'sanity')
        current['risk'] = 5
        low_risk_action = make_action(difficulty: 2, resource: 'focus', aspect: 'sanity')
        low_risk_action['risk'] = 3

        yielded = nil
        harvester.send(:select_repair_action, low_risk_action, 10, 90, repair_target, current) do |selected|
          yielded = selected
        end
        expect(yielded).to eq(low_risk_action)
      end

      it 'does not yield if new action has equal risk to current repair' do
        current = make_action(difficulty: 2, resource: 'focus', aspect: 'sanity')
        current['risk'] = 3
        equal_risk_action = make_action(difficulty: 2, resource: 'focus', aspect: 'sanity')
        equal_risk_action['risk'] = 3

        yielded = nil
        harvester.send(:select_repair_action, equal_risk_action, 10, 90, repair_target, current) do |selected|
          yielded = selected
        end
        expect(yielded).to be_nil
      end

      it 'does not yield if new action has higher risk than current repair' do
        current = make_action(difficulty: 2, resource: 'focus', aspect: 'sanity')
        current['risk'] = 3
        high_risk_action = make_action(difficulty: 3, resource: 'focus', aspect: 'sanity')
        high_risk_action['risk'] = 5

        yielded = nil
        harvester.send(:select_repair_action, high_risk_action, 10, 90, repair_target, current) do |selected|
          yielded = selected
        end
        expect(yielded).to be_nil
      end
    end
  end

  # ===========================================================================
  # improve_sigil -- bail-out checks and action selection logic
  # ===========================================================================
  describe '#improve_sigil' do
    # We stub sigil_info and scribe_sigils to isolate the decision logic.
    # sigil_info returns true (success) by default unless overridden.
    # scribe_sigils is stubbed as a no-op.
    #
    # We also need @args.precision for debug messages and bail-out checks,
    # and @sigil_improvement to feed the action selection loop.

    before(:each) do
      # Provide @args with precision
      args = OpenStruct.new(precision: '90')
      harvester.instance_variable_set(:@args, args)

      # Default: no improvement actions available (empty menu)
      harvester.instance_variable_set(:@sigil_improvement, [])

      # Stub methods that interact with the game
      allow(harvester).to receive(:waitrt?)
      allow(harvester).to receive(:sigil_info).and_return(true)
      allow(harvester).to receive(:scribe_sigils)

      # Stub DRC.message to suppress output
      drc = double('DRC')
      allow(drc).to receive(:message)
      stub_const('DRC', drc)
    end

    # -----------------------------------------------------------------------
    # Iteration cap
    # -----------------------------------------------------------------------
    context 'iteration cap at 15' do
      it 'returns false when iterations >= 15 and precision far from target' do
        harvester.instance_variable_set(:@num_iterations, 15)
        harvester.instance_variable_set(:@sigil_precision, 50)
        expect(harvester.send(:improve_sigil, 90)).to be false
      end

      it 'returns false when iterations >= 15 even with high precision, and calls scribe_sigils' do
        harvester.instance_variable_set(:@num_iterations, 15)
        harvester.instance_variable_set(:@sigil_precision, 87) # >= 90 - 5 = 85
        expect(harvester).to receive(:scribe_sigils)
        expect(harvester.send(:improve_sigil, 90)).to be false
      end

      it 'does not scribe when iterations >= 15 and precision below threshold' do
        harvester.instance_variable_set(:@num_iterations, 15)
        harvester.instance_variable_set(:@sigil_precision, 84) # < 90 - 5 = 85
        expect(harvester).not_to receive(:scribe_sigils)
        harvester.send(:improve_sigil, 90)
      end

      it 'returns false at exactly 15 iterations' do
        harvester.instance_variable_set(:@num_iterations, 15)
        harvester.instance_variable_set(:@sigil_precision, 40)
        expect(harvester.send(:improve_sigil, 90)).to be false
      end

      it 'does not hit iteration cap at 14 iterations' do
        harvester.instance_variable_set(:@num_iterations, 14)
        harvester.instance_variable_set(:@sigil_precision, 40)
        # At 14 iterations, precision 40, target 90:
        # Move budget: (14 - 14) * 13 = 0 < (90 - 40 - 5) = 45 -> fails move budget
        expect(harvester.send(:improve_sigil, 90)).to be false
      end

      it 'scribes at iteration cap when precision is exactly at threshold (target - 5)' do
        harvester.instance_variable_set(:@num_iterations, 16)
        harvester.instance_variable_set(:@sigil_precision, 85) # exactly 90 - 5
        expect(harvester).to receive(:scribe_sigils)
        harvester.send(:improve_sigil, 90)
      end
    end

    # -----------------------------------------------------------------------
    # Move budget check
    # -----------------------------------------------------------------------
    context 'move budget check: (14 - iterations) * 13 < (precision - sigil_precision - 5)' do
      it 'returns false when remaining moves cannot reach target' do
        # (14 - 10) * 13 = 52 < (90 - 20 - 5) = 65 -> insufficient
        harvester.instance_variable_set(:@num_iterations, 10)
        harvester.instance_variable_set(:@sigil_precision, 20)
        expect(harvester.send(:improve_sigil, 90)).to be false
      end

      it 'does not bail when remaining moves can reach target' do
        # (14 - 5) * 13 = 117 < (90 - 20 - 5) = 65 -> 117 not < 65, passes
        harvester.instance_variable_set(:@num_iterations, 5)
        harvester.instance_variable_set(:@sigil_precision, 20)
        # Will continue past move budget check; sigil_info returns true
        result = harvester.send(:improve_sigil, 90)
        expect(result).to be true
      end

      it 'returns false at the exact boundary where budget is insufficient' do
        # (14 - 10) * 13 = 52 < (90 - 32 - 5) = 53 -> 52 < 53, fails
        harvester.instance_variable_set(:@num_iterations, 10)
        harvester.instance_variable_set(:@sigil_precision, 32)
        expect(harvester.send(:improve_sigil, 90)).to be false
      end

      it 'passes at the exact boundary where budget is just sufficient' do
        # (14 - 10) * 13 = 52 < (90 - 33 - 5) = 52 -> 52 < 52 is false, passes
        harvester.instance_variable_set(:@num_iterations, 10)
        harvester.instance_variable_set(:@sigil_precision, 33)
        # Passes move budget, continues to action selection
        result = harvester.send(:improve_sigil, 90)
        expect(result).to be true
      end

      it 'always passes move budget on iteration 0 for reasonable targets' do
        # (14 - 0) * 13 = 182 < (90 - 0 - 5) = 85 -> 182 not < 85, passes
        harvester.instance_variable_set(:@num_iterations, 0)
        harvester.instance_variable_set(:@sigil_precision, 0)
        result = harvester.send(:improve_sigil, 90)
        expect(result).to be true
      end
    end

    # -----------------------------------------------------------------------
    # Scribe trigger: precision >= target
    # -----------------------------------------------------------------------
    context 'scribe trigger when precision reaches target' do
      it 'calls scribe_sigils and returns false when precision == target' do
        harvester.instance_variable_set(:@num_iterations, 5)
        harvester.instance_variable_set(:@sigil_precision, 90)
        expect(harvester).to receive(:scribe_sigils)
        expect(harvester.send(:improve_sigil, 90)).to be false
      end

      it 'calls scribe_sigils and returns false when precision exceeds target' do
        harvester.instance_variable_set(:@num_iterations, 5)
        harvester.instance_variable_set(:@sigil_precision, 95)
        expect(harvester).to receive(:scribe_sigils)
        expect(harvester.send(:improve_sigil, 90)).to be false
      end

      it 'does not scribe when precision is 1 below target' do
        harvester.instance_variable_set(:@num_iterations, 5)
        harvester.instance_variable_set(:@sigil_precision, 89)
        expect(harvester).not_to receive(:scribe_sigils)
        harvester.send(:improve_sigil, 90)
      end
    end

    # -----------------------------------------------------------------------
    # Action selection: difficulty preference
    # -----------------------------------------------------------------------
    context 'action selection prefers higher difficulty' do
      it 'selects the higher difficulty action over a lower difficulty one' do
        low_diff = make_action(difficulty: 2, resource: 'sanity', verb: 'STUDY')
        high_diff = make_action(difficulty: 4, resource: 'resolve', verb: 'FOCUS')

        harvester.instance_variable_set(:@sigil_improvement, [low_diff, high_diff])
        harvester.instance_variable_set(:@num_iterations, 3)
        harvester.instance_variable_set(:@sigil_precision, 50)
        harvester.instance_variable_set(:@sanity_lvl, 10)
        harvester.instance_variable_set(:@resolve_lvl, 10)

        expect(harvester).to receive(:sigil_info).with('FOCUS').and_return(true)
        harvester.send(:improve_sigil, 90)
      end

      it 'selects the first action when both have equal difficulty' do
        action_a = make_action(difficulty: 3, resource: 'sanity', impact: 1, verb: 'STUDY')
        action_b = make_action(difficulty: 3, resource: 'resolve', impact: 1, verb: 'FOCUS')

        # With equal difficulty AND equal impact, the tiebreaker is resource level.
        # Since sanity and resolve are both 10, the first one found is kept.
        harvester.instance_variable_set(:@sigil_improvement, [action_a, action_b])
        harvester.instance_variable_set(:@num_iterations, 3)
        harvester.instance_variable_set(:@sigil_precision, 50)

        expect(harvester).to receive(:sigil_info).with('STUDY').and_return(true)
        harvester.send(:improve_sigil, 90)
      end
    end

    # -----------------------------------------------------------------------
    # Action selection: cost tiebreaker
    # -----------------------------------------------------------------------
    context 'action selection breaks ties by lower cost' do
      it 'selects the lower-cost action when difficulty is equal' do
        expensive = make_action(difficulty: 3, resource: 'sanity', impact: 3, verb: 'CHANNEL')
        cheap = make_action(difficulty: 3, resource: 'sanity', impact: 1, verb: 'STUDY')

        harvester.instance_variable_set(:@sigil_improvement, [expensive, cheap])
        harvester.instance_variable_set(:@num_iterations, 3)
        harvester.instance_variable_set(:@sigil_precision, 50)

        expect(harvester).to receive(:sigil_info).with('STUDY').and_return(true)
        harvester.send(:improve_sigil, 90)
      end
    end

    # -----------------------------------------------------------------------
    # EXP-17: Resource-aware tiebreaker
    # -----------------------------------------------------------------------
    context 'EXP-17: resource-aware tiebreaker on equal difficulty and cost' do
      it 'prefers the action draining the most-available resource' do
        # Both difficulty=3, impact=1. sanity_action drains sanity (level 12),
        # focus_action drains focus (level 5). Prefer sanity_action (higher stat).
        sanity_action = make_action(difficulty: 3, resource: 'sanity', impact: 1, verb: 'STUDY')
        focus_action  = make_action(difficulty: 3, resource: 'focus', impact: 1, verb: 'FOCUS')

        harvester.instance_variable_set(:@sanity_lvl, 12)
        harvester.instance_variable_set(:@focus_lvl, 5)
        harvester.instance_variable_set(:@sigil_improvement, [focus_action, sanity_action])
        harvester.instance_variable_set(:@num_iterations, 3)
        harvester.instance_variable_set(:@sigil_precision, 50)

        expect(harvester).to receive(:sigil_info).with('STUDY').and_return(true)
        harvester.send(:improve_sigil, 90)
      end

      it 'keeps the first action when both drain equally-available resources' do
        action_a = make_action(difficulty: 3, resource: 'sanity', impact: 1, verb: 'STUDY')
        action_b = make_action(difficulty: 3, resource: 'resolve', impact: 1, verb: 'FOCUS')

        # Both resources at level 10 -> no swap on tiebreaker, first one kept
        harvester.instance_variable_set(:@sanity_lvl, 10)
        harvester.instance_variable_set(:@resolve_lvl, 10)
        harvester.instance_variable_set(:@sigil_improvement, [action_a, action_b])
        harvester.instance_variable_set(:@num_iterations, 3)
        harvester.instance_variable_set(:@sigil_precision, 50)

        expect(harvester).to receive(:sigil_info).with('STUDY').and_return(true)
        harvester.send(:improve_sigil, 90)
      end
    end

    # -----------------------------------------------------------------------
    # EXP-6: ACTION verb filter
    # -----------------------------------------------------------------------
    context 'EXP-6: ACTION verb is filtered out' do
      it 'skips actions with verb ACTION even when they are high difficulty' do
        action_verb = make_action(difficulty: 5, resource: 'sanity', verb: 'ACTION')
        normal_verb = make_action(difficulty: 3, resource: 'resolve', verb: 'FOCUS')

        harvester.instance_variable_set(:@sigil_improvement, [action_verb, normal_verb])
        harvester.instance_variable_set(:@num_iterations, 3)
        harvester.instance_variable_set(:@sigil_precision, 50)

        expect(harvester).to receive(:sigil_info).with('FOCUS').and_return(true)
        harvester.send(:improve_sigil, 90)
      end

      it 'filters ACTION verb case-insensitively' do
        # The code compares x['verb'].upcase != 'ACTION', so 'action' also filtered
        action_lower = make_action(difficulty: 5, resource: 'sanity', verb: 'action')
        normal = make_action(difficulty: 3, resource: 'resolve', verb: 'FOCUS')

        harvester.instance_variable_set(:@sigil_improvement, [action_lower, normal])
        harvester.instance_variable_set(:@num_iterations, 3)
        harvester.instance_variable_set(:@sigil_precision, 50)

        expect(harvester).to receive(:sigil_info).with('FOCUS').and_return(true)
        harvester.send(:improve_sigil, 90)
      end
    end

    # -----------------------------------------------------------------------
    # Non-precision actions are ignored for precision selection
    # -----------------------------------------------------------------------
    context 'non-precision aspect actions are not selected as precision actions' do
      it 'does not select repair-aspect actions for precision improvement' do
        repair_action = make_action(difficulty: 5, resource: 'sanity', aspect: 'sanity', verb: 'REPAIR')
        precision_action = make_action(difficulty: 2, resource: 'resolve', aspect: 'precision', verb: 'STUDY')

        harvester.instance_variable_set(:@sigil_improvement, [repair_action, precision_action])
        harvester.instance_variable_set(:@num_iterations, 3)
        harvester.instance_variable_set(:@sigil_precision, 50)

        expect(harvester).to receive(:sigil_info).with('STUDY').and_return(true)
        harvester.send(:improve_sigil, 90)
      end
    end

    # -----------------------------------------------------------------------
    # Fallback to sigil_info('improve') when no action selected
    # -----------------------------------------------------------------------
    context 'no viable action: falls back to refresh' do
      it 'calls sigil_info with "improve" when no precision action is available' do
        # Empty improvement list -> no actions selected
        harvester.instance_variable_set(:@sigil_improvement, [])
        harvester.instance_variable_set(:@num_iterations, 3)
        harvester.instance_variable_set(:@sigil_precision, 50)

        expect(harvester).to receive(:sigil_info).with('improve').and_return(true)
        harvester.send(:improve_sigil, 90)
      end
    end

    # -----------------------------------------------------------------------
    # sigil_info returning false causes improve_sigil to return false
    # -----------------------------------------------------------------------
    context 'sigil_info failure propagation' do
      it 'returns false when sigil_info returns false (mishap)' do
        harvester.instance_variable_set(:@sigil_improvement, [])
        harvester.instance_variable_set(:@num_iterations, 3)
        harvester.instance_variable_set(:@sigil_precision, 50)

        allow(harvester).to receive(:sigil_info).and_return(false)
        expect(harvester.send(:improve_sigil, 90)).to be false
      end
    end

    # -----------------------------------------------------------------------
    # Phase 4: Repair fallback when no precision action is available
    # -----------------------------------------------------------------------
    context 'Phase 4: aspect repair fallback' do
      # Phase 1 identifies repair targets (precision actions with stat margin < 2, difficulty >= 3)
      # Phase 4 applies repair when no precision action was selected

      it 'applies repair action when no precision action found and repair is available' do
        # A precision action that is too hard (stat margin < 2)
        hard_precision = make_action(difficulty: 4, resource: 'sanity', aspect: 'precision', verb: 'HARD')
        # A repair action that can help
        repair = make_action(difficulty: 2, resource: 'focus', aspect: 'sanity', verb: 'MEDITATE')

        harvester.instance_variable_set(:@sanity_lvl, 4) # margin to hard_precision: 4-4=0 < 2
        harvester.instance_variable_set(:@focus_lvl, 10) # margin to repair: 10-2=8 >= 2
        harvester.instance_variable_set(:@sigil_improvement, [hard_precision, repair])
        harvester.instance_variable_set(:@num_iterations, 3)
        harvester.instance_variable_set(:@sigil_precision, 80) # within 15 of 90
        harvester.instance_variable_set(:@danger_lvl, 5) # <= 18

        expect(harvester).to receive(:sigil_info).with('MEDITATE').and_return(true)
        harvester.send(:improve_sigil, 90)
      end

      it 'does not apply repair when danger level exceeds 18' do
        hard_precision = make_action(difficulty: 4, resource: 'sanity', aspect: 'precision', verb: 'HARD')
        repair = make_action(difficulty: 2, resource: 'focus', aspect: 'sanity', verb: 'MEDITATE')

        harvester.instance_variable_set(:@sanity_lvl, 4)
        harvester.instance_variable_set(:@focus_lvl, 10)
        harvester.instance_variable_set(:@sigil_improvement, [hard_precision, repair])
        harvester.instance_variable_set(:@num_iterations, 3)
        harvester.instance_variable_set(:@sigil_precision, 80)
        harvester.instance_variable_set(:@danger_lvl, 19) # > 18

        # Falls through to refresh because repair is blocked
        expect(harvester).to receive(:sigil_info).with('improve').and_return(true)
        harvester.send(:improve_sigil, 90)
      end

      it 'repair_override bypasses the repair cap when select_repair_action finds a candidate' do
        # When select_repair_action yields a valid repair, repair_override = true,
        # which bypasses the @num_aspect_repairs < 2 cap. This is the designed behavior:
        # the cap only blocks repairs when NO fresh repair candidate was found in this
        # iteration (repair_override stays false).
        hard_precision = make_action(difficulty: 4, resource: 'sanity', aspect: 'precision', verb: 'HARD')
        repair = make_action(difficulty: 2, resource: 'focus', aspect: 'sanity', verb: 'MEDITATE')

        harvester.instance_variable_set(:@sanity_lvl, 4)
        harvester.instance_variable_set(:@focus_lvl, 10)
        harvester.instance_variable_set(:@sigil_improvement, [hard_precision, repair])
        harvester.instance_variable_set(:@num_iterations, 3)
        harvester.instance_variable_set(:@sigil_precision, 80)
        harvester.instance_variable_set(:@num_aspect_repairs, 5) # well past cap

        # repair_override is true because select_repair_action yields the repair,
        # so the cap is bypassed and the repair action is executed
        expect(harvester).to receive(:sigil_info).with('MEDITATE').and_return(true)
        harvester.send(:improve_sigil, 90)
      end

      it 'does not apply repair when no repair candidate was found (no repair_override, cap hit)' do
        # When no best_repair_aspect or second_best_repair_aspect is identified
        # (no hard precision actions), select_repair_action never yields, so
        # repair_override stays false and aspect_repair stays empty.
        # With @num_aspect_repairs >= 2, Phase 4 is blocked.
        easy_precision = make_action(difficulty: 2, resource: 'sanity', aspect: 'precision', verb: 'STUDY')
        repair_like = make_action(difficulty: 2, resource: 'focus', aspect: 'sanity', verb: 'MEDITATE')

        # sanity=10: margin to easy_precision is 10-2=8 >= 2, so easy_precision is NOT flagged
        # as a repair candidate (it IS viable as a precision action).
        # But easy_precision has difficulty=2 which is < 3, so it won't enter Phase 1's
        # best_repair_aspect either.
        harvester.instance_variable_set(:@sanity_lvl, 10)
        harvester.instance_variable_set(:@focus_lvl, 10)
        harvester.instance_variable_set(:@sigil_improvement, [easy_precision, repair_like])
        harvester.instance_variable_set(:@num_iterations, 3)
        harvester.instance_variable_set(:@sigil_precision, 50)

        # easy_precision is viable for precision improvement (margin > 1, difficulty >= 2),
        # so it gets selected as sigil_action, and Phase 4 repair fallback is skipped entirely.
        expect(harvester).to receive(:sigil_info).with('STUDY').and_return(true)
        harvester.send(:improve_sigil, 90)
      end
    end
  end

  # ===========================================================================
  # Action cost and difficulty lookup tables
  # ===========================================================================
  describe 'lookup tables' do
    describe '@action_difficulty' do
      it 'maps trivial to 1' do
        table = harvester.instance_variable_get(:@action_difficulty)
        expect(table['trivial']).to eq(1)
      end

      it 'maps straightforward to 2' do
        table = harvester.instance_variable_get(:@action_difficulty)
        expect(table['straightforward']).to eq(2)
      end

      it 'maps formidable to 3' do
        table = harvester.instance_variable_get(:@action_difficulty)
        expect(table['formidable']).to eq(3)
      end

      it 'maps challenging to 4' do
        table = harvester.instance_variable_get(:@action_difficulty)
        expect(table['challenging']).to eq(4)
      end

      it 'maps difficult to 5' do
        table = harvester.instance_variable_get(:@action_difficulty)
        expect(table['difficult']).to eq(5)
      end
    end

    describe '@action_cost (EXP-14r equalization)' do
      it 'maps taxing to 1' do
        table = harvester.instance_variable_get(:@action_cost)
        expect(table['taxing']).to eq(1)
      end

      it 'maps disrupting to 1' do
        table = harvester.instance_variable_get(:@action_cost)
        expect(table['disrupting']).to eq(1)
      end

      it 'maps destroying to 1' do
        table = harvester.instance_variable_get(:@action_cost)
        expect(table['destroying']).to eq(1)
      end

      it 'has all costs equal (EXP-14r confirmed neutral)' do
        table = harvester.instance_variable_get(:@action_cost)
        expect(table.values.uniq.length).to eq(1)
      end
    end
  end

  # ===========================================================================
  # elapsed_minutes and sigil_elapsed_minutes
  # ===========================================================================
  describe '#elapsed_minutes' do
    it 'returns elapsed time in minutes' do
      harvester.instance_variable_set(:@start_time, Time.now - 120)
      result = harvester.send(:elapsed_minutes)
      expect(result).to be_within(0.2).of(2.0)
    end

    it 'returns 0.0 when just started' do
      harvester.instance_variable_set(:@start_time, Time.now)
      result = harvester.send(:elapsed_minutes)
      expect(result).to be_within(0.1).of(0.0)
    end
  end

  describe '#sigil_elapsed_minutes' do
    it 'returns elapsed time since sigil start' do
      harvester.instance_variable_set(:@sigil_start_time, Time.now - 60)
      result = harvester.send(:sigil_elapsed_minutes)
      expect(result).to be_within(0.2).of(1.0)
    end

    it 'falls back to @start_time when @sigil_start_time is nil' do
      harvester.instance_variable_set(:@sigil_start_time, nil)
      harvester.instance_variable_set(:@start_time, Time.now - 300)
      result = harvester.send(:sigil_elapsed_minutes)
      expect(result).to be_within(0.2).of(5.0)
    end
  end

  # ===========================================================================
  # Integration-level decision scenarios
  # ===========================================================================
  describe 'decision scenarios' do
    before(:each) do
      args = OpenStruct.new(precision: '90')
      harvester.instance_variable_set(:@args, args)
      harvester.instance_variable_set(:@sigil_improvement, [])

      allow(harvester).to receive(:waitrt?)
      allow(harvester).to receive(:sigil_info).and_return(true)
      allow(harvester).to receive(:scribe_sigils)

      drc = double('DRC')
      allow(drc).to receive(:message)
      stub_const('DRC', drc)
    end

    it 'scenario: fresh start with good actions -- selects highest difficulty' do
      actions = [
        make_action(difficulty: 2, resource: 'sanity', verb: 'STUDY'),
        make_action(difficulty: 4, resource: 'resolve', verb: 'CONCENTRATE'),
        make_action(difficulty: 3, resource: 'focus', verb: 'FOCUS')
      ]
      harvester.instance_variable_set(:@sigil_improvement, actions)
      harvester.instance_variable_set(:@num_iterations, 0)
      harvester.instance_variable_set(:@sigil_precision, 13)

      expect(harvester).to receive(:sigil_info).with('CONCENTRATE').and_return(true)
      harvester.send(:improve_sigil, 90)
    end

    it 'scenario: only trivial actions available -- refreshes' do
      actions = [
        make_action(difficulty: 1, resource: 'sanity', verb: 'STUDY'),
        make_action(difficulty: 1, resource: 'resolve', verb: 'FOCUS')
      ]
      harvester.instance_variable_set(:@sigil_improvement, actions)
      harvester.instance_variable_set(:@num_iterations, 3)
      harvester.instance_variable_set(:@sigil_precision, 50)

      # No viable precision action -> falls back to improve
      expect(harvester).to receive(:sigil_info).with('improve').and_return(true)
      harvester.send(:improve_sigil, 90)
    end

    it 'scenario: all actions are ACTION verb -- refreshes' do
      actions = [
        make_action(difficulty: 4, resource: 'sanity', verb: 'ACTION'),
        make_action(difficulty: 3, resource: 'resolve', verb: 'ACTION')
      ]
      harvester.instance_variable_set(:@sigil_improvement, actions)
      harvester.instance_variable_set(:@num_iterations, 3)
      harvester.instance_variable_set(:@sigil_precision, 50)

      expect(harvester).to receive(:sigil_info).with('improve').and_return(true)
      harvester.send(:improve_sigil, 90)
    end

    it 'scenario: late game, precision near target, scribes' do
      harvester.instance_variable_set(:@sigil_improvement, [])
      harvester.instance_variable_set(:@num_iterations, 10)
      harvester.instance_variable_set(:@sigil_precision, 92) # >= 90

      expect(harvester).to receive(:scribe_sigils)
      result = harvester.send(:improve_sigil, 90)
      expect(result).to be false
    end

    it 'scenario: low resources but viable action exists -- continues' do
      action = make_action(difficulty: 3, resource: 'sanity', verb: 'STUDY')
      harvester.instance_variable_set(:@sigil_improvement, [action])
      harvester.instance_variable_set(:@num_iterations, 5)
      harvester.instance_variable_set(:@sigil_precision, 60)
      harvester.instance_variable_set(:@sanity_lvl, 6) # margin = 6-3 = 3 > 1
      harvester.instance_variable_set(:@resolve_lvl, 2)
      harvester.instance_variable_set(:@focus_lvl, 2)

      expect(harvester).to receive(:sigil_info).with('STUDY').and_return(true)
      result = harvester.send(:improve_sigil, 90)
      expect(result).to be true
    end

    it 'scenario: stat margins too tight for all actions -- refreshes' do
      actions = [
        make_action(difficulty: 4, resource: 'sanity', verb: 'STUDY'),
        make_action(difficulty: 5, resource: 'resolve', verb: 'FOCUS')
      ]
      harvester.instance_variable_set(:@sigil_improvement, actions)
      harvester.instance_variable_set(:@num_iterations, 3)
      harvester.instance_variable_set(:@sigil_precision, 50)
      # sanity=4, difficulty=4 -> margin=0 (rejected)
      # resolve=5, difficulty=5 -> margin=0 (rejected)
      harvester.instance_variable_set(:@sanity_lvl, 4)
      harvester.instance_variable_set(:@resolve_lvl, 5)

      expect(harvester).to receive(:sigil_info).with('improve').and_return(true)
      harvester.send(:improve_sigil, 90)
    end

    it 'scenario: mixed viable and non-viable actions -- selects best viable' do
      actions = [
        make_action(difficulty: 5, resource: 'sanity', verb: 'HARD'),    # margin=0, rejected
        make_action(difficulty: 4, resource: 'resolve', verb: 'MEDIUM'), # margin=1, difficulty>2, accepted (path 2)
        make_action(difficulty: 2, resource: 'focus', verb: 'EASY')      # margin=8, accepted (path 1)
      ]
      harvester.instance_variable_set(:@sigil_improvement, actions)
      harvester.instance_variable_set(:@num_iterations, 3)
      harvester.instance_variable_set(:@sigil_precision, 50)
      harvester.instance_variable_set(:@sanity_lvl, 5) # margin to diff 5 = 0
      harvester.instance_variable_set(:@resolve_lvl, 5)  # margin to diff 4 = 1
      harvester.instance_variable_set(:@focus_lvl, 10)   # margin to diff 2 = 8

      # MEDIUM (difficulty 4) beats EASY (difficulty 2) because higher difficulty wins
      expect(harvester).to receive(:sigil_info).with('MEDIUM').and_return(true)
      harvester.send(:improve_sigil, 90)
    end
  end

  # ===========================================================================
  # C1 fix: @actually_scribed flag
  # ===========================================================================
  describe '@actually_scribed flag (C1 fix)' do
    it 'starts as false' do
      expect(harvester.instance_variable_get(:@actually_scribed)).to be false
    end

    # The flag is set to true inside scribe_sigils. This ensures that
    # harvest_sigil reports SCRIBED only when scribing actually occurred,
    # not when precision happened to be high at the time of a mishap.
  end

  # ===========================================================================
  # VERSION constant
  # ===========================================================================
  describe 'VERSION' do
    it 'is defined as a string' do
      expect(SigilHarvest::VERSION).to be_a(String)
    end

    it 'follows semantic versioning format' do
      expect(SigilHarvest::VERSION).to match(/^\d+\.\d+\.\d+$/)
    end
  end

  # ===========================================================================
  # precision_action_viable? -- comprehensive edge-case matrix
  # ===========================================================================
  describe '#precision_action_viable? -- full decision matrix' do
    # Test every meaningful combination of (difficulty, margin) to ensure
    # the two-path logic is fully covered. This table acts as a regression
    # guard for any future changes to the viability function.
    #
    # difficulty: 1=trivial, 2=straightforward, 3=formidable, 4=challenging, 5=difficult
    # margin: stat - difficulty
    # Expected result based on the two paths:
    #   Path 1: margin > 1 AND difficulty >= 2  -> true
    #   Path 2: margin > 0 AND difficulty > 2   -> true
    #   EXP-18: difficulty < 2                   -> false
    #   Otherwise: false

    [
      # [difficulty, margin, expected, description]
      [1, -1, false, 'trivial, negative margin'],
      [1,  0, false, 'trivial, zero margin'],
      [1,  1, false, 'trivial, margin 1'],
      [1,  2, false, 'trivial, margin 2 -- still rejected by EXP-18'],
      [1,  5, false, 'trivial, high margin -- still rejected by EXP-18'],
      [2, -1, false, 'straightforward, negative margin'],
      [2,  0, false, 'straightforward, zero margin'],
      [2,  1, false, 'straightforward, margin 1 -- path 1 fails (not > 1), path 2 fails (diff not > 2)'],
      [2,  2, true,  'straightforward, margin 2 -- path 1 accepts'],
      [2,  5, true,  'straightforward, margin 5 -- path 1 accepts'],
      [3, -1, false, 'formidable, negative margin'],
      [3,  0, false, 'formidable, zero margin'],
      [3,  1, true,  'formidable, margin 1 -- path 2 accepts (difficulty > 2)'],
      [3,  2, true,  'formidable, margin 2 -- path 1 accepts'],
      [4, -1, false, 'challenging, negative margin'],
      [4,  0, false, 'challenging, zero margin'],
      [4,  1, true,  'challenging, margin 1 -- path 2 accepts'],
      [4,  2, true,  'challenging, margin 2 -- path 1 accepts'],
      [5, -1, false, 'difficult, negative margin'],
      [5,  0, false, 'difficult, zero margin'],
      [5,  1, true,  'difficult, margin 1 -- path 2 accepts'],
      [5,  2, true,  'difficult, margin 2 -- path 1 accepts'],
      [5,  5, true,  'difficult, margin 5 -- path 1 accepts'],
    ].each do |difficulty, margin, expected, description|
      it "returns #{expected} for #{description}" do
        action = make_action(difficulty: difficulty)
        stat = difficulty + margin
        result = harvester.send(:precision_action_viable?, action, stat, 90)
        expect(result).to eq(expected)
      end
    end
  end
end
