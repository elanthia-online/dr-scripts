# frozen_string_literal: true

require_relative 'spec_helper'

# wild-monitor.lic is class-less: top-level code in an endless loop that reacts
# to Flags. These specs run the real file in a fresh object whose pause/fput
# play a short game: lines are fed through the registered Flags matchers the way
# lich-5 DRParser.check_events does, and the run ends after the surge harness.
RSpec.describe 'wild-monitor.lic' do
  # Ends the script's endless loop.
  let(:run_over) { Class.new(StandardError) }

  # The corpus holds no copy of these messages, so they use the matchers' words.
  let(:wild_start_line) { 'Excruciating pain sets your nervous system afire!  Something is wrong with your mana attunement and you must weaken it!' }
  let(:wild_end_line) { 'Your attunement to the caustic mana streams is severed at last.' }
  let(:surge_line) { 'A swirling vortex of brilliant light spins across the area.' }

  let(:sent) { [] }
  let(:warnings) { [] }
  let(:unpaused) { [] }

  before do
    reset_data
    $test_settings = OpenStruct.new(wild_mana_amount: 200)
    $running_scripts = []
    DRStats.mana = 0
    allow(DRC).to receive(:message) { |text| warnings << text }
    allow(DRC).to receive(:safe_unpause_list) { |list| unpaused << list }
  end

  def deliver(line)
    Flags.matchers.each do |key, regexes|
      regexes.each do |regex|
        if (match = line.match(regex))
          Flags[key] = match
          break
        end
      end
    end
  end

  # Plays the game for one run of the script. With `wild_first`, a wild surge
  # comes and goes before the mana surge. Pausing the other scripts fails
  # (another script holds the pause lock) until `lock_free_after` one-second
  # pauses into the mana surge, and `wild_lock_free_after` into the wild surge.
  def run_script(wild_first:, lock_free_after:, wild_lock_free_after: 100)
    state = { phase: wild_first ? :before_wild : :before_surge, wild_pauses: 0, surge_pauses: 0 }
    over = run_over
    spec = self
    allow(DRC).to receive(:safe_pause_list) do
      free = state[:phase] == :wild ? state[:wild_pauses] >= wild_lock_free_after : state[:surge_pauses] >= lock_free_after
      free ? ['hunting-buddy'] : false
    end
    runner = Object.new
    runner.define_singleton_method(:pause) do |seconds = 1|
      case state[:phase]
      when :before_wild
        spec.deliver(spec.wild_start_line)
        state[:phase] = :wild
      when :wild
        state[:wild_pauses] += 1 if seconds == 1
        spec.deliver(spec.wild_end_line) if seconds == 5
      when :before_surge
        spec.deliver(spec.surge_line)
        state[:phase] = :surge
      when :surge
        state[:surge_pauses] += 1
      when :done
        raise over
      end
    end
    runner.define_singleton_method(:fput) do |message|
      spec.sent << message
      state[:phase] = :before_surge if message == 'release mana'
      state[:phase] = :done if message == 'harness surge'
    end
    path = lic_path('wild-monitor.lic')
    runner.instance_eval(File.read(path), path, 1)
  rescue run_over
    nil
  end

  describe 'mana surge' do
    it 'pauses the other scripts and harnesses the surge' do
      run_script(wild_first: false, lock_free_after: 0)

      expect(sent).to eq(['harness surge'])
      expect(unpaused).to eq([['hunting-buddy']])
      expect(warnings).to be_empty
    end

    it 'keeps trying to pause the other scripts when the first try fails' do
      run_script(wild_first: false, lock_free_after: 3)

      expect(sent).to eq(['harness surge'])
      expect(unpaused).to eq([['hunting-buddy']])
      expect(warnings).to be_empty
    end

    it 'keeps trying to pause after a wild surge that could not pause anything' do
      run_script(wild_first: true, lock_free_after: 3)

      expect(sent).to eq(['release mana', 'harness surge'])
      expect(unpaused).to eq([false, ['hunting-buddy']])
      expect(warnings.size).to eq(1)
    end

    it 'gets its own ten tries after a wild surge that needed some' do
      run_script(wild_first: true, wild_lock_free_after: 6, lock_free_after: 6)

      expect(sent).to eq(['release mana', 'harness surge'])
      expect(unpaused).to eq([['hunting-buddy'], ['hunting-buddy']])
      expect(warnings).to be_empty
    end

    it 'warns and still harnesses when the scripts never pause' do
      run_script(wild_first: false, lock_free_after: 100)

      expect(sent).to eq(['harness surge'])
      expect(unpaused).to eq([false])
      expect(warnings).to eq(['*** WARNING: UNABLE TO PAUSE OTHER SCRIPTS! WILD-MONITOR WILL ATTEMPT TO PROCEED ***'])
    end
  end
end
