# frozen_string_literal: true

require_relative 'spec_helper'

# performance-monitor.lic starts with top-level code (the HAVE_GTK guard)
# before its class, so run_lic_entry cannot reach it. These examples run the
# whole real script instead, evaluated into a fresh runner object per example:
# the class, its constants and its top-level def land on the runner's
# singleton class, never on Object, and nothing carries over between examples.
#
# HAVE_GTK, Gtk and CharSettings are set as constants on the runner's
# singleton class, so no global constant is defined or reassigned. Gtk.queue
# does not yield, so no window is built. The script loops on script.gets?
# forever, so the reader raises StopRun on its first call. That stop also shows
# the run got past all the top-level code into the main loop.
#
# The runner records each pause instead of sleeping, and can make textsubs
# show up as running after a given number of them (as autostart starting it
# just after this script would). It also records respond on its own, apart
# from echo, so the textsubs hint is pinned to echo.
RSpec.describe 'performance-monitor.lic' do
  let(:path) { lic_path('performance-monitor.lic') }
  let(:stop_run) { Class.new(StandardError) }
  let(:custom_required) { [] }
  let(:started_if_available) { [] }
  let(:loop_reached) { [] }
  let(:pauses) { [] }
  let(:responded) { [] }
  # the number of pauses after which textsubs shows up as running; nil = never
  let(:textsubs_starts_after_pauses) { nil }

  before do
    $test_settings.performance_monitor_weapons = ['broadsword']
  end

  # A runner object that evaluates the script with inert GTK doubles.
  #
  # @param with_start_helper [Boolean] whether the runner responds to
  #   start_scripts_if_available, the lich-5 helper the script used to call
  #   when it was present (custom_require was the fallback)
  # @return [Object] the runner
  def build_runner(with_start_helper:)
    runner = Object.new
    gtk = Object.new
    gtk.define_singleton_method(:queue) { |&_block| nil }
    runner.singleton_class.const_set(:HAVE_GTK, true)
    runner.singleton_class.const_set(:Gtk, gtk)
    runner.singleton_class.const_set(:CharSettings, {})

    reached = loop_reached
    over = stop_run
    reader = Object.new
    reader.define_singleton_method(:gets?) do
      reached << true
      raise over
    end
    runner.define_singleton_method(:script) { reader }

    paused = pauses
    starts_after = textsubs_starts_after_pauses
    runner.define_singleton_method(:pause) do |seconds = 1|
      paused << seconds
      $running_scripts << 'textsubs' if paused.size == starts_after
    end
    said = responded
    runner.define_singleton_method(:respond) { |message = ''| said << message }

    required = custom_required
    runner.define_singleton_method(:custom_require) { proc { |names| required.concat(Array(names)) } }
    if with_start_helper
      started = started_if_available
      runner.define_singleton_method(:start_scripts_if_available) { |names| started.concat(Array(names)) }
    end
    runner
  end

  # Runs the whole script on a fresh runner until its first script.gets?.
  #
  # @param with_start_helper [Boolean] see build_runner
  # @return [Object] the runner the script ran on
  def run_script(with_start_helper:)
    runner = build_runner(with_start_helper: with_start_helper)
    expect { runner.instance_eval(File.read(path), path, 1) }.to raise_error(stop_run)
    runner
  end

  describe 'textsubs' do
    it 'does not start textsubs when lich provides start_scripts_if_available' do
      run_script(with_start_helper: true)

      expect(loop_reached).not_to be_empty
      expect(started_if_available).not_to include('textsubs')
      expect(custom_required).not_to include('textsubs')
      expect($started_scripts.map(&:first)).not_to include('textsubs')
    end

    it 'does not start textsubs through the custom_require fallback' do
      runner = run_script(with_start_helper: false)

      expect(runner).not_to respond_to(:start_scripts_if_available)
      expect(loop_reached).not_to be_empty
      expect(custom_required).not_to include('textsubs')
      expect($started_scripts.map(&:first)).not_to include('textsubs')
    end

    # The script used to start textsubs, so a player who relied on that is
    # told once, at launch, how to start it at login instead.
    describe 'the textsubs hint' do
      # @return [Array<String>] displayed messages that name ;autostart add textsubs
      def hints
        displayed_messages.grep(/;autostart add textsubs/)
      end

      it 'echoes once, after waiting five seconds, that textsubs is no longer started when it never runs' do
        run_script(with_start_helper: true)

        expect(pauses).to eq([0.5] * 10)
        expect(hints.size).to eq(1)
        expect(hints.first).to include('performance-monitor no longer starts textsubs')
        expect(responded).to be_empty
      end

      it 'echoes nothing about textsubs and does not wait when textsubs is already running' do
        $running_scripts << 'textsubs'

        run_script(with_start_helper: true)

        expect(loop_reached).not_to be_empty
        expect(pauses).to be_empty
        expect(displayed_messages.grep(/textsubs/)).to be_empty
      end

      context 'when autostart starts textsubs just after performance-monitor' do
        let(:textsubs_starts_after_pauses) { 3 }

        it 'stops waiting once textsubs runs and echoes nothing about textsubs' do
          run_script(with_start_helper: true)

          expect(loop_reached).not_to be_empty
          expect(pauses).to eq([0.5] * 3)
          expect(displayed_messages.grep(/textsubs/)).to be_empty
        end
      end
    end
  end

  # PerformanceFilter ranks each hit with its own (n/23) tag, then reads the
  # rank back to average damage over roundtime per weapon. The filter class is
  # the one the real script defined on the runner.
  describe 'PerformanceFilter' do
    let(:runner) { run_script(with_start_helper: true) }
    let(:filter) { runner.singleton_class.const_get(:PerformanceFilter).new }

    # Feeds one broadsword hit line, then a roundtime line, to the filter.
    #
    # @param damage [String] the damage phrase the hit line carries
    # @param seconds [Integer] the roundtime the roundtime line reports
    # @return [Array(String, Boolean)] the hit line as the filter left it, and
    #   whether the roundtime line completed a hit
    def hit_then_roundtime(damage, seconds: 3)
      hit = "< You slash your broadsword at a goblin.  The blade lands #{damage} to the goblin's chest.".b
      filter.process_line(hit)
      [hit, filter.process_line("Roundtime: #{seconds} sec.".b)]
    end

    describe 'devastating hit ranks' do
      it 'ranks a devastating hit 17 and averages that rank' do
        line, completed = hit_then_roundtime('a devastating hit')

        expect(line).to include('lands a devastating hit (17/23) to')
        expect(line).not_to include('18/23')
        expect(completed).to be(true)
        expect(filter.weapon_stats).to eq([{ weapon: 'broadsword', avgrt: 3.0, avgdps: 17 / 3.0 }])
      end

      it "ranks a devastating hit (That'll leave a mark!) 18 and averages that rank" do
        line, completed = hit_then_roundtime("a devastating hit (That'll leave a mark!)")

        expect(line).to include("lands a devastating hit (That'll leave a mark!) (18/23) to")
        expect(line).not_to include('17/23')
        expect(completed).to be(true)
        expect(filter.weapon_stats).to eq([{ weapon: 'broadsword', avgrt: 3.0, avgdps: 18 / 3.0 }])
      end
    end

    describe 'roundtime' do
      it 'reads every digit of a two-digit roundtime' do
        line, completed = hit_then_roundtime('a light hit', seconds: 12)

        expect(line).to include('lands a light hit (1/23) to')
        expect(completed).to be(true)
        expect(filter.weapon_stats).to eq([{ weapon: 'broadsword', avgrt: 12.0, avgdps: 1 / 12.0 }])
      end
    end

    describe 'weapon stats' do
      it 'leaves out a monitored weapon that has no hit with a roundtime yet' do
        $test_settings.performance_monitor_weapons = %w[broadsword scimitar]

        _line, completed = hit_then_roundtime('a good hit')

        expect(completed).to be(true)
        expect(filter.weapon_stats).to eq([{ weapon: 'broadsword', avgrt: 3.0, avgdps: 2 / 3.0 }])
      end

      it 'leaves out a weapon whose hit was followed by another weapon before any roundtime' do
        $test_settings.performance_monitor_weapons = %w[broadsword scimitar]
        filter.process_line('< You slash your scimitar at a goblin.  The blade lands a good hit to the goblin.'.b)

        hit_then_roundtime('a light hit')

        expect(filter.weapon_stats).to eq([{ weapon: 'broadsword', avgrt: 3.0, avgdps: 1 / 3.0 }])
      end
    end
  end
end
