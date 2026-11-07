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
RSpec.describe 'performance-monitor.lic' do
  let(:path) { lic_path('performance-monitor.lic') }
  let(:stop_run) { Class.new(StandardError) }
  let(:custom_required) { [] }
  let(:started_if_available) { [] }
  let(:loop_reached) { [] }

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
  # @return [void]
  def run_script(with_start_helper:)
    runner = build_runner(with_start_helper: with_start_helper)
    expect { runner.instance_eval(File.read(path), path, 1) }.to raise_error(stop_run)
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
      run_script(with_start_helper: false)

      expect(loop_reached).not_to be_empty
      expect(custom_required).not_to include('textsubs')
      expect(started_if_available).to be_empty
      expect($started_scripts.map(&:first)).not_to include('textsubs')
    end
  end
end
