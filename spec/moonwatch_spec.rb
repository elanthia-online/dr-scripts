# frozen_string_literal: true

# Spec for moonwatch.lic -- the offline celestial prediction engine.
#
# moonwatch predicts moon/sun rise-set and the full Elanthian calendar from
# closed-form math anchored to a fixed epoch, self-correcting from observed
# events. The prediction math (DRTime, Moons) is pure and deterministic, which
# is where the bulk of these tests live. The stateful pieces (offset manager,
# logger, reset tracker, UI) are exercised through their public seams with the
# harness game stubs.
#
# Testing notes:
#   - .lic files cannot be required (top-level side effects), so the modules and
#     classes are eval'd out of the file via load_lic_module / load_lic_class.
#   - CharSettings is faithfully modelled with Lich's real per-(game,character)
#     scope key ("#{XMLData.game}:#{XMLData.name}") so the multi-instance offset
#     isolation guarantee is tested honestly, not assumed.
#   - UserVars is stubbed per-example (other specs define a fixed UserVars class;
#     stubbing avoids cross-spec contamination).

require 'ostruct'
require 'tmpdir'
require 'fileutils'

require_relative 'spec_helper'

# spec_helper owns the shared harness: it `load`s test/test_harness.rb and
# `include`s Harness exactly once (it is auto-required via .rspec). We must NOT
# re-`load` the harness here -- doing so re-executes its class bodies and would
# clobber other specs' harness reopenings (e.g. combat-trainer's DRSpells
# _reset). load_lic_class comes from spec_helper; we only add a `module` variant.
def load_lic_module(filename, module_name)
  return if Object.const_defined?(module_name)

  filepath = File.join(File.dirname(__FILE__), '..', filename)
  lines = File.readlines(filepath)

  start_idx = lines.index { |l| l =~ /^module\s+#{module_name}\b/ }
  raise "Could not find 'module #{module_name}' in #{filename}" unless start_idx

  end_idx = (start_idx + 1...lines.size).find { |i| lines[i] =~ /^end\s*$/ }
  raise "Could not find matching end for 'module #{module_name}' in #{filename}" unless end_idx

  eval(lines[start_idx..end_idx].join, TOPLEVEL_BINDING, filepath, start_idx + 1)
end

# --- collaborators (contamination-proof) ----------------------------------

module Lich
  module Messaging
    def self.msg(*_args); end
  end
end unless defined?(Lich::Messaging)

# Faithful model of Lich's CharSettings: scoped by "#{XMLData.game}:#{XMLData.name}"
# (see lib/common/settings/charsettings.rb). This is what makes the offsets
# per-instance-and-per-character with no extra work in the script.
module CharSettings
  @@_store = Hash.new { |h, k| h[k] = {} }

  def self._reset
    @@_store = Hash.new { |h, k| h[k] = {} }
  end

  def self._scope
    "#{XMLData.game}:#{XMLData.name}"
  end

  def self.[](key)
    @@_store[_scope][key]
  end

  def self.[]=(key, value)
    @@_store[_scope][key] = value
  end
end unless defined?(CharSettings)

# Minimal UserVars fallback for standalone runs; moons/sun/calendar are stubbed
# per-example in the UI describe.
class UserVars
end unless defined?(UserVars)

$frontend = nil
$lich_dir = Dir.mktmpdir('moonwatch-spec')
FileUtils.mkdir_p(File.join($lich_dir, 'data'))

load_lic_module('moonwatch.lic', 'DRTime')
load_lic_module('moonwatch.lic', 'Moons')
load_lic_module('moonwatch.lic', 'MoonwatchInstance')
load_lic_module('moonwatch.lic', 'MoonwatchMessaging')
load_lic_module('moonwatch.lic', 'MoonwatchAlias')
load_lic_class('moonwatch.lic', 'MoonwatchOffsetManager')
load_lic_class('moonwatch.lic', 'MoonwatchLogger')
load_lic_class('moonwatch.lic', 'ServerResetTracker')
load_lic_class('moonwatch.lic', 'MoonwatchUI')

RSpec.describe 'moonwatch.lic' do
  # A recent server_time landing on day-of-year 307, year 455.
  let(:now) { 1_773_000_000 }
  let(:epoch) { DRTime::CALENDAR_EPOCH } # 1_688_607_948, start of day 0 year 446

  before(:each) do
    reset_data
    CharSettings._reset
    XMLData.game = 'DR'
    XMLData.name = 'TestChar'
    XMLData.server_time = now
    $mw_msgs = []
    allow(Lich::Messaging).to receive(:msg) { |type, message| $mw_msgs << [type, message] }
  end

  # =========================================================================
  # DRTime -- calendar and sun math
  # =========================================================================
  describe DRTime do
    describe '.calculate_date' do
      it 'returns the epoch as day 0, year 446, all-zero units' do
        d = DRTime.calculate_date(epoch)
        expect(d).to eq(year: 446, month: 1, day: 1, day_of_year: 0,
                        anlas: 0, rois: 0, seconds_in_day: 0)
      end

      it 'computes a mid-year date from a recent server_time' do
        d = DRTime.calculate_date(now)
        expect(d[:year]).to eq(455)
        expect(d[:day_of_year]).to eq(307)
        expect(d[:month]).to eq(8)
        expect(d[:day]).to eq(28)
      end

      it 'maps day_of_year to month/day (month 1-indexed, day 1-indexed)' do
        d = DRTime.calculate_date(epoch + 40 * DRTime::SECONDS_PER_DAY) # day 40
        expect(d[:day_of_year]).to eq(40)
        expect(d[:month]).to eq(2)
        expect(d[:day]).to eq(1)
      end

      it 'wraps the year at day 400 (year boundary)' do
        d = DRTime.calculate_date(epoch + 400 * DRTime::SECONDS_PER_DAY)
        expect(d[:year]).to eq(447)
        expect(d[:day_of_year]).to eq(0)
      end

      it 'handles the last second before midnight' do
        d = DRTime.calculate_date(epoch + DRTime::SECONDS_PER_DAY - 1)
        expect(d[:day_of_year]).to eq(0)
        expect(d[:seconds_in_day]).to eq(21_599)
        expect(d[:anlas]).to eq(11)
        expect(d[:rois]).to eq(29)
      end

      it 'is robust to timestamps before the epoch (floored division)' do
        d = DRTime.calculate_date(epoch - 1)
        expect(d[:year]).to eq(445)
        expect(d[:day_of_year]).to eq(399)
        expect(d[:seconds_in_day]).to eq(21_599)
      end

      it 'applies the offset argument' do
        base = DRTime.calculate_date(epoch)
        shifted = DRTime.calculate_date(epoch, 60)
        expect(shifted[:rois]).to eq(base[:rois] + 1)
      end
    end

    describe '.sun_times_for_day' do
      it 'reads the empirical table for an in-range integer day' do
        expect(DRTime.sun_times_for_day(100)).to eq(rise: 5400, set: 16_200)
      end

      it 'gives the shortest day at the winter solstice (day 0)' do
        sun = DRTime.sun_times_for_day(0)
        expect(sun[:set] - sun[:rise]).to eq(7200)
      end

      it 'gives the longest day at the summer solstice (day 200)' do
        sun = DRTime.sun_times_for_day(200)
        expect(sun[:set] - sun[:rise]).to eq(14_400)
      end

      it 'covers the last table index (day 399)' do
        expect(DRTime.sun_times_for_day(399)).to eq(rise: 7200, set: 14_400)
      end

      it 'falls back to the cosine model for an out-of-range day' do
        # 400 is outside the 0..399 table; must not raise, must be sane.
        sun = DRTime.sun_times_for_day(400)
        expect(sun[:rise]).to be_a(Integer)
        expect(sun[:set]).to eq(DRTime::ROIS_PER_DAY * 60 - sun[:rise])
      end

      it 'falls back for a non-integer day (table lookup guarded on Integer)' do
        sun = DRTime.sun_times_for_day(50.5)
        expect(sun[:rise] + sun[:set]).to eq(DRTime::ROIS_PER_DAY * 60)
      end
    end

    describe '.calculate_sun_position' do
      it 'reports time until set when the sun is up' do
        gt = epoch + 100 * DRTime::SECONDS_PER_DAY + 6000 # day 100, after rise 5400
        res = DRTime.calculate_sun_position(gt)
        expect(res[:visible]).to be true
        expect(res[:event]).to eq('set')
        expect(res[:seconds]).to eq(16_200 - 6000)
      end

      it 'reports time until rise when before sunrise' do
        gt = epoch + 100 * DRTime::SECONDS_PER_DAY + 1000 # before rise 5400
        res = DRTime.calculate_sun_position(gt)
        expect(res[:visible]).to be false
        expect(res[:event]).to eq('rise')
        expect(res[:seconds]).to eq(5400 - 1000)
      end

      it 'rolls to tomorrow sunrise when after sunset' do
        gt = epoch + 100 * DRTime::SECONDS_PER_DAY + 17_000 # after set 16200
        res = DRTime.calculate_sun_position(gt)
        expect(res[:visible]).to be false
        expect(res[:event]).to eq('rise')
        # remaining today + tomorrow's rise
        remaining = DRTime::SECONDS_PER_DAY - 17_000
        tomorrow_rise = DRTime.sun_times_for_day(101)[:rise]
        expect(res[:seconds]).to eq(remaining + tomorrow_rise)
      end
    end

    describe '.season' do
      {
        0 => 'winter', 49 => 'winter', 50 => 'spring', 149 => 'spring',
        150 => 'summer', 249 => 'summer', 250 => 'fall', 349 => 'fall',
        350 => 'winter', 399 => 'winter'
      }.each do |day, expected|
        it "maps day #{day} to #{expected}" do
          expect(DRTime.season(day)).to eq(expected)
        end
      end
    end

    describe '.time_of_day' do
      it 'reports night at the start of the day' do
        expect(DRTime.time_of_day(0, 100)).to eq('night')
      end

      it 'reports midday at the exact half-day mark' do
        expect(DRTime.time_of_day(10_800, 100)).to eq('midday')
      end

      it 'returns a descriptive string across the whole day without raising' do
        (0...DRTime::SECONDS_PER_DAY).step(900) do |s|
          expect(DRTime.time_of_day(s, 100)).to be_a(String)
        end
      end

      it 'does not raise at the degenerate winter solstice day length' do
        [0, 3600, 7200, 9000, 10_800, 14_400, 21_000].each do |s|
          expect(DRTime.time_of_day(s, 0)).to be_a(String)
        end
      end
    end

    describe '.year_name' do
      it 'maps year 446 in the 7-year cycle' do
        expect(DRTime.year_name(446)).to eq('Year of the Emerald Dolphin')
      end

      it 'wraps a year that is a multiple of 7 to cycle slot 7' do
        expect(DRTime.year_name(448)).to eq('Year of the Silver Unicorn') # 448 % 7 == 0 -> 7
      end

      it 'rolls to the start of the cycle' do
        expect(DRTime.year_name(449)).to eq('Year of the Bronze Wyvern') # 449 % 7 == 1
      end
    end

    describe '.anlas_name' do
      it 'names midnight and dawn' do
        expect(DRTime.anlas_name(0)).to eq('Anduwen')
        expect(DRTime.anlas_name(6)).to eq("Dergati's Bane")
      end

      it 'returns Unknown for an out-of-range index' do
        expect(DRTime.anlas_name(99)).to eq('Unknown')
      end
    end

    describe '.month_name' do
      it 'names the first and last month' do
        expect(DRTime.month_name(1)).to eq('Akroeg the Ram')
        expect(DRTime.month_name(10)).to eq('Nissa the Maiden')
      end

      it 'returns Unknown for index 0 (nil placeholder) and out-of-range' do
        expect(DRTime.month_name(0)).to eq('Unknown')
        expect(DRTime.month_name(11)).to eq('Unknown')
      end
    end
  end

  # =========================================================================
  # Moons -- Bresenham tick positions and lunar phase
  # =========================================================================
  describe Moons do
    let(:xibar) { Moons::CONSTANTS['xibar'] }

    describe '.nearest_tick' do
      it 'rounds down below the half-tick and up at/after it' do
        expect(Moons.nearest_tick(29)).to eq(0)
        expect(Moons.nearest_tick(30)).to eq(60)
        expect(Moons.nearest_tick(89)).to eq(60)
        expect(Moons.nearest_tick(90)).to eq(120)
      end

      it 'accepts fractional (Float) true times' do
        expect(Moons.nearest_tick(119.9)).to eq(120)
      end
    end

    describe '.calculate_position' do
      it 'reports the moon up and counting to set at its epoch (position 0)' do
        res = Moons.calculate_position('xibar', xibar[:epoch], 0)
        expect(res[:visible]).to be true
        expect(res[:event]).to eq('set')
        expect(res[:t]).to eq(0.0)
        expect(res[:seconds]).to be >= 0
      end

      it 'reports the moon down and counting to rise past its visible window' do
        res = Moons.calculate_position('xibar', xibar[:epoch] + xibar[:visible] + 100, 0)
        expect(res[:visible]).to be false
        expect(res[:event]).to eq('rise')
      end

      it 'clamps the arc progress t into 0..1' do
        %w[katamba xibar yavash].each do |moon|
          (0..20).each do |k|
            t = Moons.calculate_position(moon, xibar[:epoch] + k * 1000, 0)[:t]
            expect(t).to be_between(0.0, 1.0).inclusive
          end
        end
      end

      it 'never returns a negative countdown' do
        (0..30).each do |k|
          res = Moons.calculate_position('yavash', now + k * 700, 0)
          expect(res[:seconds]).to be >= 0
        end
      end

      it 'shifts the phase when an offset is applied' do
        base = Moons.calculate_position('katamba', now, 0)
        shifted = Moons.calculate_position('katamba', now, 600)
        expect(shifted[:seconds]).not_to eq(base[:seconds])
      end

      it 'raises for an unknown moon (fetch)' do
        expect { Moons.calculate_position('luna', now, 0) }.to raise_error(KeyError)
      end
    end

    describe '.format_duration' do
      it 'formats hours and minutes' do
        expect(Moons.format_duration(7200)).to eq('2h 0m')
      end

      it 'formats minutes and seconds' do
        expect(Moons.format_duration(150)).to eq('2m 30s')
      end

      it 'formats seconds only' do
        expect(Moons.format_duration(45)).to eq('45s')
      end

      it 'formats zero' do
        expect(Moons.format_duration(0)).to eq('0s')
      end
    end

    describe '.phase' do
      it 'returns a full phase hash with an index in 0..7' do
        p = Moons.phase('xibar', now)
        expect(p[:index]).to be_between(0, 7).inclusive
        expect(Moons::PHASE_NAMES).to include(p[:name])
        expect(p[:name]).to eq(Moons::PHASE_NAMES[p[:index]])
      end

      it 'wraps next_index around the 8-phase cycle' do
        %w[katamba xibar yavash].each do |moon|
          p = Moons.phase(moon, now)
          expect(p[:next_index]).to eq((p[:index] + 1) % 8)
          expect(p[:next_name]).to eq(Moons::PHASE_NAMES[p[:next_index]])
        end
      end

      it 'keeps angles within 0..359' do
        p = Moons.phase('katamba', now)
        expect(p[:orbital_angle]).to be_between(0, 359).inclusive
        expect(p[:phase_angle]).to be_between(0, 359).inclusive
      end

      it 'reports a positive countdown to the next phase boundary' do
        %w[katamba xibar yavash].each do |moon|
          expect(Moons.phase(moon, now)[:seconds_to_next]).to be > 0
        end
      end

      it 'raises for an unknown moon' do
        expect { Moons.phase('luna', now) }.to raise_error(KeyError)
      end
    end
  end

  # =========================================================================
  # MoonwatchMessaging
  # =========================================================================
  describe MoonwatchMessaging do
    describe '.debug' do
      it 'emits a plain prefixed message when debug is enabled' do
        MoonwatchMessaging.debug('hi', true)
        expect($mw_msgs).to include(['plain', 'moonwatch: hi'])
      end

      it 'stays silent when debug is disabled' do
        MoonwatchMessaging.debug('hi', false)
        expect($mw_msgs).to be_empty
      end
    end

    describe '.info' do
      it 'emits a plain prefixed message' do
        MoonwatchMessaging.info('started')
        expect($mw_msgs).to include(['plain', 'moonwatch: started'])
      end
    end

    describe '.error' do
      it 'emits a bold prefixed message' do
        MoonwatchMessaging.error('boom')
        expect($mw_msgs).to include(['bold', 'moonwatch: boom'])
      end
    end
  end

  # =========================================================================
  # MoonwatchInstance -- multi-instance awareness
  # =========================================================================
  describe MoonwatchInstance do
    describe '.prime?' do
      it 'is true only for DR' do
        expect(MoonwatchInstance.prime?('DR')).to be true
        %w[DRX DRF DRT GS3 nonsense].each do |g|
          expect(MoonwatchInstance.prime?(g)).to be false
        end
        expect(MoonwatchInstance.prime?(nil)).to be false
      end
    end

    describe '.display_name' do
      it 'names every known instance' do
        expect(MoonwatchInstance.display_name('DR')).to eq('Prime')
        expect(MoonwatchInstance.display_name('DRX')).to eq('Platinum')
        expect(MoonwatchInstance.display_name('DRF')).to eq('Fallen')
        expect(MoonwatchInstance.display_name('DRT')).to eq('Test')
      end

      it 'falls back to the raw code for an unknown instance' do
        expect(MoonwatchInstance.display_name('GS3')).to eq('GS3')
        expect(MoonwatchInstance.display_name(nil)).to eq('')
      end
    end

    describe '.calibration_notice' do
      it 'is nil (silent) on Prime' do
        expect(MoonwatchInstance.calibration_notice('DR')).to be_nil
      end

      it 'names the instance and mentions self-calibration on non-Prime' do
        %w[DRX DRF DRT].each do |g|
          notice = MoonwatchInstance.calibration_notice(g)
          expect(notice).to include(MoonwatchInstance.display_name(g))
          expect(notice).to match(/self-calibrate/i)
        end
      end
    end
  end

  # =========================================================================
  # MoonwatchOffsetManager -- persistence, self-correction, multi-instance
  # =========================================================================
  describe MoonwatchOffsetManager do
    subject(:manager) { described_class.new(debug_enabled: true) }

    describe '#initialize' do
      it 'defaults all offsets to zero when CharSettings is empty' do
        expect(manager.moon_offset('katamba')).to eq(0)
        expect(manager.moon_offset('xibar')).to eq(0)
        expect(manager.moon_offset('yavash')).to eq(0)
        expect(manager.sun_offset).to eq(0)
      end

      it 'loads persisted offsets from CharSettings' do
        CharSettings['katamba_offset'] = 123
        CharSettings['sun_offset'] = -45
        m = described_class.new
        expect(m.moon_offset('katamba')).to eq(123)
        expect(m.sun_offset).to eq(-45)
      end
    end

    describe '#moon_offset' do
      it 'returns 0 for an unknown moon' do
        expect(manager.moon_offset('luna')).to eq(0)
      end
    end

    describe '#sun_offset' do
      it 'returns the current sun offset' do
        CharSettings['sun_offset'] = 7
        expect(described_class.new.sun_offset).to eq(7)
      end
    end

    describe '#correct_moon_offset' do
      let(:xibar) { Moons::CONSTANTS['xibar'] }

      it 'applies a full correction on a visibility mismatch' do
        gt = xibar[:epoch] + xibar[:visible] + 100 # model says hidden
        predicted = Moons.calculate_position('xibar', gt, 0)
        manager.correct_moon_offset('xibar', true, gt) # observed rise
        expect(manager.moon_offset('xibar')).to eq(predicted[:seconds])
      end

      it 'leaves the offset unchanged when the tick prediction was correct' do
        gt = xibar[:epoch] # position 0, within half a tick of predicted rise tick
        manager.correct_moon_offset('xibar', true, gt)
        expect(manager.moon_offset('xibar')).to eq(0)
        expect($mw_msgs.map(&:last).join).to match(/tick OK/)
      end

      it 'realigns via drift correction when the tick was wrong' do
        gt = xibar[:epoch] + 200 # visible matches, but 200s off the rise tick
        manager.correct_moon_offset('xibar', true, gt)
        expect(manager.moon_offset('xibar')).to eq(-200)
      end

      it 'auto-resets an offset that exceeds the epoch-mismatch threshold' do
        CharSettings['xibar_offset'] = MoonwatchOffsetManager::MOON_OFFSET_THRESHOLD + 5000
        m = described_class.new(debug_enabled: true)
        # any correction path ends by checking the threshold
        m.correct_moon_offset('xibar', true, xibar[:epoch])
        expect(m.moon_offset('xibar')).to eq(0)
      end
    end

    describe '#correct_sun_offset' do
      it 'applies a full correction on a visibility mismatch' do
        gt = epoch + 100 * DRTime::SECONDS_PER_DAY + 1000 # model: before rise (hidden)
        predicted = DRTime.calculate_sun_position(gt, 0)
        manager.correct_sun_offset(true, gt) # observed rise
        expect(manager.sun_offset).to eq(predicted[:seconds])
      end

      it 'corrects drift when visibility matches but timing is off' do
        gt = epoch + 100 * DRTime::SECONDS_PER_DAY + 6000 # up; rise was 5400
        manager.correct_sun_offset(true, gt)
        expect(manager.sun_offset).to eq(-(6000 - 5400))
      end

      it 'leaves the offset unchanged when the event lands exactly on prediction' do
        gt = epoch + 100 * DRTime::SECONDS_PER_DAY + 5400 # exactly at rise
        manager.correct_sun_offset(true, gt)
        expect(manager.sun_offset).to eq(0)
      end

      it 'auto-resets a sun offset beyond the threshold' do
        CharSettings['sun_offset'] = MoonwatchOffsetManager::SUN_OFFSET_THRESHOLD + 1000
        m = described_class.new
        m.send(:check_sun_offset_threshold)
        expect(m.sun_offset).to eq(0)
      end
    end

    describe '#reset_all_offsets' do
      it 'zeros every moon and the sun and persists' do
        CharSettings['katamba_offset'] = 500
        CharSettings['sun_offset'] = 500
        m = described_class.new
        m.reset_all_offsets
        expect(m.moon_offset('katamba')).to eq(0)
        expect(m.sun_offset).to eq(0)
        expect(CharSettings['katamba_offset']).to eq(0)
        expect(CharSettings['sun_offset']).to eq(0)
      end
    end

    describe '#log_current_offsets' do
      it 'emits moon and sun offset debug lines' do
        manager.log_current_offsets
        joined = $mw_msgs.map(&:last).join("\n")
        expect(joined).to match(/moon offsets:/)
        expect(joined).to match(/sun offset:/)
      end
    end

    describe '#calculate_moon_drift (private)' do
      it 'is the raw position for a rise (should be 0)' do
        expect(manager.send(:calculate_moon_drift, true, 200, 10_482)).to eq(200)
      end

      it 'is position minus visible duration for a set' do
        expect(manager.send(:calculate_moon_drift, false, 11_000, 10_482)).to eq(518)
      end
    end

    describe '#apply_moon_correction (private)' do
      it 'accumulates the offset and persists to CharSettings' do
        manager.send(:apply_moon_correction, 'xibar', 50, 'test')
        expect(manager.moon_offset('xibar')).to eq(50)
        expect(CharSettings['xibar_offset']).to eq(50)
      end
    end

    describe '#check_moon_offset_threshold (private)' do
      it 'resets only when abs(offset) exceeds the threshold' do
        manager.send(:apply_moon_correction, 'xibar', 100, 'ok')
        manager.send(:check_moon_offset_threshold, 'xibar')
        expect(manager.moon_offset('xibar')).to eq(100) # under threshold, kept

        manager.send(:apply_moon_correction, 'xibar',
                     MoonwatchOffsetManager::MOON_OFFSET_THRESHOLD, 'big')
        manager.send(:check_moon_offset_threshold, 'xibar')
        expect(manager.moon_offset('xibar')).to eq(0)
      end
    end

    describe '#apply_sun_correction (private)' do
      it 'accumulates the sun offset and persists' do
        manager.send(:apply_sun_correction, -30, 'drift')
        expect(manager.sun_offset).to eq(-30)
        expect(CharSettings['sun_offset']).to eq(-30)
      end
    end

    describe '#check_sun_offset_threshold (private)' do
      it 'resets a runaway sun offset to zero' do
        manager.send(:apply_sun_correction, MoonwatchOffsetManager::SUN_OFFSET_THRESHOLD + 1, 'x')
        manager.send(:check_sun_offset_threshold)
        expect(manager.sun_offset).to eq(0)
      end
    end

    describe 'multi-instance isolation (headline guarantee)' do
      it 'keeps offsets separate per game instance via CharSettings scope' do
        XMLData.game = 'DR'
        prime = described_class.new
        prime.send(:apply_moon_correction, 'katamba', 111, 'prime')

        XMLData.game = 'DRX' # Platinum: fresh scope
        plat = described_class.new
        expect(plat.moon_offset('katamba')).to eq(0)
        plat.send(:apply_moon_correction, 'katamba', 222, 'plat')

        XMLData.game = 'DR' # back to Prime: original value intact
        expect(described_class.new.moon_offset('katamba')).to eq(111)

        XMLData.game = 'DRX'
        expect(described_class.new.moon_offset('katamba')).to eq(222)
      end

      it 'also isolates by character within one instance' do
        XMLData.game = 'DRX'
        XMLData.name = 'CharA'
        described_class.new.send(:apply_moon_correction, 'xibar', 77, 'a')
        XMLData.name = 'CharB'
        expect(described_class.new.moon_offset('xibar')).to eq(0)
      end

      it 'produces identical predictions across instances for the same inputs' do
        # Periods are game-code constants (validated against the DR client), so
        # the math is instance-independent; only the persisted offset differs.
        XMLData.game = 'DR'
        prime = Moons.calculate_position('katamba', now, 0)
        XMLData.game = 'DRX'
        plat = Moons.calculate_position('katamba', now, 0)
        expect(plat).to eq(prime)
      end
    end
  end

  # =========================================================================
  # MoonwatchLogger -- CSV calibration logging
  # =========================================================================
  describe MoonwatchLogger do
    let(:char) { 'SpecChar' }
    let(:data_dir) { MoonwatchLogger::DATA_DIR }
    subject(:logger) { described_class.new(enabled: true, debug_enabled: true, character_name: char) }

    before { FileUtils.rm_f(Dir.glob(File.join(data_dir, '*'))) }

    def moon_csv
      File.join(data_dir, "moonwatch_events_#{char}.csv")
    end

    def sun_csv
      File.join(data_dir, "sunwatch_events_#{char}.csv")
    end

    def phase_csv
      File.join(data_dir, "moonphase_events_#{char}.csv")
    end

    describe '#initialize' do
      it 'defaults the character name from XMLData.name' do
        XMLData.name = 'Derived'
        l = described_class.new(enabled: false, debug_enabled: false)
        expect(l.instance_variable_get(:@character_name)).to eq('Derived')
      end
    end

    describe '#log_moon_event' do
      let(:date) { DRTime.calculate_date(now) }

      it 'writes a header and one data row when enabled' do
        logger.log_moon_event('xibar', true, now, date, 0, 100)
        expect(File.exist?(moon_csv)).to be true
        lines = File.readlines(moon_csv)
        expect(lines.first).to match(/server_time,moon,event/)
        expect(lines.last).to match(/xibar,rise/)
      end

      it 'writes nothing when disabled' do
        described_class.new(enabled: false, debug_enabled: false, character_name: char)
                       .log_moon_event('xibar', true, now, date, 0, 100)
        expect(File.exist?(moon_csv)).to be false
      end

      it 'deduplicates the same event within the dedup interval' do
        logger.log_moon_event('xibar', true, now, date, 0, 100)
        logger.log_moon_event('xibar', true, now + 5, date, 0, 100)
        expect(File.readlines(moon_csv).size).to eq(2) # header + one row
      end

      it 'rejects an outlier cycle interval' do
        logger.log_moon_event('xibar', true, now, date, 0, 100)
        short = now + (Moons::CONSTANTS['xibar'][:cycle] * 0.4).to_i # too short a cycle
        logger.log_moon_event('xibar', true, short, DRTime.calculate_date(short), 0, 100)
        expect(File.readlines(moon_csv).size).to eq(2) # second rejected
      end
    end

    describe '#log_sun_event' do
      let(:date) { DRTime.calculate_date(now) }

      it 'writes a sun row with the drift column when enabled' do
        logger.log_sun_event(true, now, date, 0, 100)
        expect(File.exist?(sun_csv)).to be true
        expect(File.readlines(sun_csv).first).to match(/expected_day_length,\s*|drift/)
      end

      it 'rejects an outlier day interval' do
        logger.log_sun_event(true, now, date, 0, 100)
        short = now + 5000 # < 10_800 min day interval
        logger.log_sun_event(true, short, DRTime.calculate_date(short), 0, 100)
        expect(File.readlines(sun_csv).size).to eq(2)
      end
    end

    describe '#log_phase_observation' do
      it 'writes observed vs computed phase' do
        logger.log_phase_observation('katamba', 'a growing crescent of light', now)
        expect(File.exist?(phase_csv)).to be true
        row = File.readlines(phase_csv).last
        expect(row).to include('growing crescent')
        expect(row).to include(Moons.phase('katamba', now)[:name])
      end
    end

    describe '#duplicate_event? (private)' do
      it 'is false the first time and true within the interval' do
        expect(logger.send(:duplicate_event?, 'k_rise', now)).to be false
        expect(logger.send(:duplicate_event?, 'k_rise', now + 10)).to be true
        expect(logger.send(:duplicate_event?, 'k_rise', now + 100)).to be false
      end
    end

    describe '#calculate_moon_intervals (private)' do
      it 'is nil-filled with no prior events' do
        intervals = logger.send(:calculate_moon_intervals, 'xibar', true, now)
        expect(intervals[:cycle]).to be_nil
      end

      it 'measures the cycle from the last like event' do
        logger.instance_variable_get(:@last_moon_events)['xibar'][:rise] = now - 20_000
        intervals = logger.send(:calculate_moon_intervals, 'xibar', true, now)
        expect(intervals[:cycle]).to eq(20_000)
      end
    end

    describe '#valid_moon_interval? (private)' do
      it 'accepts values within 0.5x..1.5x of the cycle and rejects outliers' do
        cycle = Moons::CONSTANTS['xibar'][:cycle]
        expect(logger.send(:valid_moon_interval?, 'xibar', cycle)).to be true
        expect(logger.send(:valid_moon_interval?, 'xibar', cycle * 0.4)).to be false
        expect(logger.send(:valid_moon_interval?, 'xibar', cycle * 1.6)).to be false
      end
    end

    describe '#calculate_sun_intervals (private)' do
      it 'measures the day length from the last rise on a set' do
        logger.instance_variable_get(:@last_sun_events)[:rise] = now - 12_000
        intervals = logger.send(:calculate_sun_intervals, false, now)
        expect(intervals[:day_length]).to eq(12_000)
      end
    end

    describe '#valid_sun_interval? (private)' do
      it 'accepts a plausible day interval and rejects outliers' do
        expect(logger.send(:valid_sun_interval?, 21_600)).to be true
        expect(logger.send(:valid_sun_interval?, 5000)).to be false
        expect(logger.send(:valid_sun_interval?, 40_000)).to be false
      end
    end

    describe '#write_moon_csv / #ensure_moon_csv_header (private)' do
      it 'creates the header exactly once' do
        logger.send(:ensure_moon_csv_header, moon_csv)
        logger.send(:ensure_moon_csv_header, moon_csv)
        expect(File.readlines(moon_csv).size).to eq(1)
      end

      it 'appends a data row via write_moon_csv' do
        date = DRTime.calculate_date(now)
        logger.send(:write_moon_csv, 'yavash', :set, now, date,
                    { cycle: 21_000, visible_dur: nil, hidden_dur: 10_000 }, 0, 50)
        expect(File.readlines(moon_csv).last).to match(/yavash,set/)
      end
    end

    describe '#write_sun_csv / #ensure_sun_csv_header (private)' do
      it 'creates the sun header once' do
        logger.send(:ensure_sun_csv_header, sun_csv)
        logger.send(:ensure_sun_csv_header, sun_csv)
        expect(File.readlines(sun_csv).size).to eq(1)
      end
    end

    describe '#write_phase_csv / #ensure_phase_csv_header (private)' do
      it 'creates the phase header once' do
        logger.send(:ensure_phase_csv_header, phase_csv)
        logger.send(:ensure_phase_csv_header, phase_csv)
        expect(File.readlines(phase_csv).size).to eq(1)
      end
    end

    describe '#log_moon_debug / #log_sun_debug (private)' do
      it 'emit debug lines only when debug is enabled' do
        date = DRTime.calculate_date(now)
        logger.send(:log_moon_debug, 'xibar', :rise, date, 0, 100, { cycle: 20_800 })
        logger.send(:log_sun_debug, :rise, date, 0, 100, { day_interval: 21_600 }, 5)
        expect($mw_msgs.map(&:last).join("\n")).to match(/logged xibar rise/)
        expect($mw_msgs.map(&:last).join("\n")).to match(/logged sun rise/)
      end
    end
  end

  # =========================================================================
  # ServerResetTracker
  # =========================================================================
  describe ServerResetTracker do
    let(:char) { 'ResetChar' }
    let(:data_dir) { ServerResetTracker::DATA_DIR }
    subject(:tracker) { described_class.new(debug_enabled: true, character_name: char) }

    before { FileUtils.rm_f(Dir.glob(File.join(data_dir, '*'))) }

    def reset_csv
      File.join(data_dir, "server_resets_#{char}.csv")
    end

    describe '#initialize' do
      it 'starts with blank last-event tracking when CharSettings is empty' do
        expect(tracker.instance_variable_get(:@last_moon_events).values).to all(be_nil)
      end

      it 'restores persisted last-event times' do
        CharSettings['last_moon_events'] = { 'katamba' => 123, 'xibar' => nil, 'yavash' => nil }
        t = described_class.new(debug_enabled: false, character_name: char)
        expect(t.instance_variable_get(:@last_moon_events)['katamba']).to eq(123)
      end
    end

    describe '#log_shutdown' do
      it 'snapshots offsets to CharSettings and writes a shutdown row' do
        offsets = { 'katamba' => 10, 'xibar' => 20, 'yavash' => 30 }
        tracker.log_shutdown(now, offsets)
        expect(tracker.pre_shutdown_offsets).to eq(offsets)
        expect(CharSettings['pre_shutdown_offsets']).to eq(offsets)
        expect(File.readlines(reset_csv).last).to match(/shutdown/)
      end
    end

    describe '#check_for_restart' do
      it 'returns false on the first observed event (nothing to compare)' do
        expect(tracker.check_for_restart('katamba', now, 0, {})).to be false
      end

      it 'returns false for a normal gap' do
        tracker.check_for_restart('katamba', now, 0, {})
        expect(tracker.check_for_restart('katamba', now + 21_000, 0, {})).to be false
      end

      it 'detects a restart when the gap exceeds the threshold' do
        tracker.check_for_restart('katamba', now, 0, {})
        big = now + ServerResetTracker::GAP_THRESHOLD_SECONDS + 60
        expect(tracker.check_for_restart('katamba', big, 0, { 'katamba' => 0 })).to be true
        expect(File.readlines(reset_csv).map { |l| l }.join).to match(/restart_detected/)
      end
    end

    describe '#pre_shutdown_offsets' do
      it 'is nil before any shutdown' do
        expect(tracker.pre_shutdown_offsets).to be_nil
      end
    end

    describe '#record_phase_shift' do
      it 'logs the shift and clears the snapshot once all moons re-observe' do
        tracker.log_shutdown(now, { 'katamba' => 100 })
        tracker.record_phase_shift('katamba', 175, now + 100) # shift +75 -> alert
        expect(File.readlines(reset_csv).join).to match(/phase_shift/)
        expect(tracker.pre_shutdown_offsets).to be_nil # only moon cleared -> snapshot empty
        expect($mw_msgs.map(&:last).join).to match(/phase shift/i)
      end

      it 'is a no-op when the moon was not in the pre-shutdown snapshot' do
        expect { tracker.record_phase_shift('xibar', 5, now) }.not_to raise_error
        expect(File.exist?(reset_csv)).to be false
      end
    end

    describe '#log_restart / #write_csv / #ensure_csv_header (private)' do
      it 'writes the header once and a restart row' do
        tracker.send(:ensure_csv_header, reset_csv)
        tracker.send(:ensure_csv_header, reset_csv)
        expect(File.readlines(reset_csv).size).to eq(1)
        tracker.send(:log_restart, 'yavash', now, 30_000, 0, { 'yavash' => 0 })
        expect(File.readlines(reset_csv).last).to match(/restart_detected/)
      end
    end
  end

  # =========================================================================
  # MoonwatchUI
  # =========================================================================
  describe MoonwatchUI do
    let(:offset_manager) { MoonwatchOffsetManager.new }

    before do
      @moons = { 'katamba' => {}, 'yavash' => {}, 'xibar' => {}, 'visible' => [] }
      @sun = {}
      @calendar = {}
      allow(UserVars).to receive(:moons).and_return(@moons)
      allow(UserVars).to receive(:sun).and_return(@sun)
      allow(UserVars).to receive(:calendar).and_return(@calendar)
    end

    describe '#initialize / #setup_window (private)' do
      it 'does not emit window XML when the window is disabled' do
        described_class.new(window_enabled: false)
        expect($respond_messages).to be_empty
      end

      it 'emits streamWindow setup XML when the window is enabled' do
        described_class.new(window_enabled: true)
        expect($respond_messages.join).to match(/streamWindow/)
        expect($respond_messages.join).to match(/exposeStream/)
      end
    end

    describe '#update_moon_vars' do
      it 'populates per-moon UserVars and the visible list' do
        ui = described_class.new(window_enabled: false)
        ui.update_moon_vars(offset_manager, now)
        Moons::MOON_NAMES.each do |moon|
          expect(@moons[moon]).to include('visible', 'timer', 'phase', 'pretty', 'short', 't')
        end
        expect(@moons['visible']).to all(satisfy { |m| Moons::MOON_NAMES.include?(m) })
      end
    end

    describe '#update_sun_and_calendar_vars' do
      it 'populates sun and full calendar UserVars' do
        ui = described_class.new(window_enabled: false)
        ui.update_sun_and_calendar_vars(0, now)
        expect(@sun).to include('day', 'night', 'visible', 'timer', 'season', 'time_of_day', 'pretty')
        expect(@calendar['date_string']).to match(/\A\d{3,}-\d{2}-\d{2} \d{2}:\d{2}\z/)
        expect(@calendar['year']).to eq(455)
        expect(@calendar['month_name']).to be_a(String)
      end
    end

    describe '#update_window' do
      it 'emits stream XML on first refresh and caches identical content' do
        ui = described_class.new(window_enabled: true)
        ui.update_moon_vars(offset_manager, now)
        $respond_messages.clear
        ui.update_window
        expect($respond_messages.join).to match(/pushStream/)
        $respond_messages.clear
        ui.update_window # unchanged within the refresh interval -> cached, silent
        expect($respond_messages).to be_empty
      end

      it 'is silent when the window is disabled' do
        ui = described_class.new(window_enabled: false)
        ui.update_moon_vars(offset_manager, now)
        $respond_messages.clear
        ui.update_window
        expect($respond_messages).to be_empty
      end
    end

    describe '#log_initial_status' do
      it 'emits nothing when debug is off' do
        ui = described_class.new(window_enabled: false)
        ui.update_moon_vars(offset_manager, now)
        ui.update_sun_and_calendar_vars(0, now)
        ui.log_initial_status(false)
        expect($mw_msgs).to be_empty
      end

      it 'emits sun, calendar, and per-moon lines when debug is on' do
        ui = described_class.new(window_enabled: false)
        ui.update_moon_vars(offset_manager, now)
        ui.update_sun_and_calendar_vars(0, now)
        ui.log_initial_status(true)
        joined = $mw_msgs.map(&:last).join("\n")
        expect(joined).to match(/sun visible=/)
        expect(joined).to match(/calendar:/)
      end
    end

    describe '.set_running' do
      it 'marks all three UserVars structures as running without dropping keys' do
        @moons['katamba']['pretty'] = 'katamba is up for 30 minutes'
        described_class.set_running(true)
        expect(@moons['running']).to be true
        expect(@sun['running']).to be true
        expect(@calendar['running']).to be true
        # existing keys are untouched (non-destructive)
        expect(@moons['katamba']['pretty']).to eq('katamba is up for 30 minutes')
      end

      it 'marks stale (false) on exit without dropping keys' do
        @moons['katamba']['pretty'] = 'katamba is up for 30 minutes'
        described_class.set_running(false)
        expect(@moons['running']).to be false
        expect(@sun['running']).to be false
        expect(@calendar['running']).to be false
        expect(@moons['katamba']['pretty']).to eq('katamba is up for 30 minutes')
      end
    end
  end

  # =========================================================================
  # MoonwatchAlias -- the self-aware 'moon' quick-status alias
  # =========================================================================
  describe MoonwatchAlias do
    describe '.body' do
      let(:body) { described_class.body(';') }

      it 'gates on Script.running? so a dead moonwatch is detected' do
        expect(body).to include("Script.running?('moonwatch')")
      end

      it 'reads all three moon pretty strings when running' do
        expect(body).to include("UserVars.moons['katamba']['pretty']")
        expect(body).to include("UserVars.moons['yavash']['pretty']")
        expect(body).to include("UserVars.moons['xibar']['pretty']")
      end

      it 'prompts the user to start moonwatch when not running' do
        expect(body).to include('moonwatch is not running - start it with ;moonwatch')
      end

      it 'leaves interpolation for invocation time (not resolved at build time)' do
        # The pretty reads must survive as literal #{...} so eq interpolates them
        # when the alias fires, not when we build the string here.
        expect(body).to include('#{UserVars.moons')
      end

      it 'honors a non-default lich char' do
        expect(described_class.body('.')).to include('.eq ')
        expect(described_class.body('.')).to include('start it with .moonwatch')
      end
    end

    describe '.command' do
      it 'wraps the body in a global alias-add command' do
        cmd = described_class.command(';')
        expect(cmd).to start_with(';alias add --global moon = ;eq ')
        expect(cmd).to include(described_class.body(';'))
      end
    end

    describe '.should_resync?' do
      it 'is false when the user never opted in' do
        expect(described_class.should_resync?(enabled: nil, stored_version: nil)).to be false
        expect(described_class.should_resync?(enabled: false, stored_version: 0)).to be false
      end

      it 'is true when enabled but no version has been recorded yet' do
        expect(described_class.should_resync?(enabled: true, stored_version: nil)).to be true
      end

      it 'is true when enabled and the stored version is behind' do
        expect(described_class.should_resync?(enabled: true, stored_version: MoonwatchAlias::VERSION - 1)).to be true
      end

      it 'is false when enabled and already at the current version' do
        expect(described_class.should_resync?(enabled: true, stored_version: MoonwatchAlias::VERSION)).to be false
      end
    end

    describe '.install' do
      it 'records opt-in and the current body version in CharSettings' do
        described_class.install(';')
        expect(CharSettings['moon_alias_enabled']).to be true
        expect(CharSettings['moon_alias_version']).to eq(MoonwatchAlias::VERSION)
      end

      it 'emits the alias-add command upstream' do
        captured = []
        UpstreamHook.add('moonwatch_spec_capture', proc { |s| captured << s; s })
        described_class.install(';')
        UpstreamHook.remove('moonwatch_spec_capture')
        expect(captured.join).to include('alias add --global moon = ')
      end
    end

    describe '.resync' do
      it 'installs when a previously-enabled alias is behind' do
        CharSettings['moon_alias_enabled'] = true
        CharSettings['moon_alias_version'] = MoonwatchAlias::VERSION - 1
        described_class.resync(';')
        expect(CharSettings['moon_alias_version']).to eq(MoonwatchAlias::VERSION)
      end

      it 'does nothing when the user never opted in' do
        captured = []
        UpstreamHook.add('moonwatch_spec_capture', proc { |s| captured << s; s })
        described_class.resync(';')
        UpstreamHook.remove('moonwatch_spec_capture')
        expect(captured).to be_empty
        expect(CharSettings['moon_alias_enabled']).to be_nil
      end
    end
  end
end
