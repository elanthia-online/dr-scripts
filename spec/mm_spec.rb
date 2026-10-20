# frozen_string_literal: true

require 'ostruct'
require_relative 'spec_helper'

load_lic_class('mm.lic', 'MoonMagery')

RSpec.describe MoonMagery do
  let(:locate_data) { { 'abbrev' => 'locate', 'mana' => 5 } }
  let(:rift_data) { { 'abbrev' => 'RS', 'mana' => 30 } }
  let(:settings) do
    OpenStruct.new(waggle_sets: { 'locate' => { 'Locate' => locate_data }, 'rs' => { 'Riftal Summons' => rift_data } })
  end

  # moonwatch's published shape: a hash per moon plus the 'visible' list and,
  # in current versions, a 'running' marker (false once moonwatch has exited).
  def moons(visible:, timers: { 'katamba' => 30, 'yavash' => 20, 'xibar' => 10 }, running: true)
    data = timers.to_h { |moon, timer| [moon, { 'timer' => timer, 'visible' => visible.include?(moon) }] }
    data['visible'] = visible
    data['running'] = running unless running.nil?
    data
  end

  let(:unavailable_message) { 'Moon data is unavailable, so Rift cannot be cast' }
  let(:no_moons_message) { 'No moons available to cast Rift' }

  before do
    $test_settings = settings
    # A locate cast answers with one of the failure lines mm.lic flags, so a
    # run that gets as far as locate ends there ("Bob is not in-game").
    allow(DRCA).to receive(:cast_spell) do |data, _settings|
      Flags['locate-fail'] = ["There doesn't seem to be anyone by that name under the skies"] if data['abbrev'] == 'locate'
    end
  end

  # Runs the script the way Lich does for `;mm rift <person>`.
  def run_rift(person = 'bob')
    $parsed_args = { 'rift' => true, 'person' => person }
    MoonMagery.new
  end

  # A MoonMagery whose locate succeeds, so rift goes on to cast.
  def located_mm
    mm = MoonMagery.allocate
    mm.instance_variable_set(:@settings, settings)
    allow(mm).to receive(:locate?).and_return(1234)
    mm
  end

  describe 'rift when check_moonwatch returns false (moon data unavailable)' do
    before { allow(DRCMM).to receive(:check_moonwatch).and_return(false) }

    it 'casts nothing, not even locate, when saved timers still show a moon up' do
      UserVars.moons = moons(visible: %w[katamba], running: false)

      run_rift

      expect(DRCA).not_to have_received(:cast_spell)
      expect(displayed_messages).to include(unavailable_message)
      expect(displayed_messages).not_to include(no_moons_message)
    end

    it 'ignores saved timers without a running marker (older moonwatch data)' do
      UserVars.moons = moons(visible: %w[xibar yavash], running: nil)

      run_rift

      expect(DRCA).not_to have_received(:cast_spell)
      expect(displayed_messages).to include(unavailable_message)
    end

    it 'ignores saved timers that still say running (left by a crashed moonwatch)' do
      UserVars.moons = moons(visible: %w[katamba])

      run_rift

      expect(DRCA).not_to have_received(:cast_spell)
      expect(displayed_messages).to include(unavailable_message)
    end

    it 'reports the data as unavailable, not as no moons up, when the data was cleared' do
      UserVars.moons = {}

      run_rift

      expect(DRCA).not_to have_received(:cast_spell)
      expect(displayed_messages).to include(unavailable_message)
      expect(displayed_messages).not_to include(no_moons_message)
    end

    it 'does not read UserVars.moons at all' do
      allow(UserVars).to receive(:moons).and_raise('UserVars.moons read after check_moonwatch returned false')

      expect { located_mm.rift('bob') }.not_to raise_error
      expect(DRCA).not_to have_received(:cast_spell)
    end

    it 'checks moonwatch once' do
      UserVars.moons = moons(visible: %w[katamba])

      run_rift

      expect(DRCMM).to have_received(:check_moonwatch).once
    end

    it 'still removes its locate flag' do
      UserVars.moons = moons(visible: %w[katamba])

      run_rift

      expect(Flags['locate-fail']).to be_nil
    end
  end

  describe 'rift when check_moonwatch returns nil (older Lich)' do
    before { allow(DRCMM).to receive(:check_moonwatch).and_return(nil) }

    it 'goes on to locate when a moon is up' do
      UserVars.moons = moons(visible: %w[katamba])

      run_rift

      expect(DRCA).to have_received(:cast_spell).once.with(hash_including('abbrev' => 'locate', 'cast' => 'cast Bob'), settings)
      expect(displayed_messages).to include('Unable to rift Bob due to failed locate')
      expect(displayed_messages).not_to include(unavailable_message)
    end

    it 'casts Rift at the located person when a moon is up' do
      UserVars.moons = moons(visible: %w[yavash])

      located_mm.rift('bob')

      expect(DRCA).to have_received(:cast_spell).once.with(hash_including('abbrev' => 'RS', 'cast' => 'cast Bob'), settings)
    end

    it 'stops with the no-moons message when no moon is up' do
      UserVars.moons = moons(visible: [])

      located_mm.rift('bob')

      expect(DRCA).not_to have_received(:cast_spell)
      expect(displayed_messages).to include(no_moons_message)
      expect(displayed_messages).not_to include(unavailable_message)
    end
  end

  describe 'rift when check_moonwatch returns true' do
    before { allow(DRCMM).to receive(:check_moonwatch).and_return(true) }

    it 'casts Rift at the located person when a moon is up' do
      UserVars.moons = moons(visible: %w[xibar])

      located_mm.rift('bob')

      expect(DRCA).to have_received(:cast_spell).once.with(hash_including('abbrev' => 'RS', 'cast' => 'cast Bob'), settings)
      expect(displayed_messages).not_to include(unavailable_message)
    end

    it 'casts when the visible moon has 0 minutes left' do
      UserVars.moons = moons(visible: %w[katamba], timers: { 'katamba' => 0, 'yavash' => 20, 'xibar' => 10 })

      located_mm.rift('bob')

      expect(DRCA).to have_received(:cast_spell).once
    end

    it 'does not cast when the only visible moon has a negative timer' do
      UserVars.moons = moons(visible: %w[katamba], timers: { 'katamba' => -1, 'yavash' => 20, 'xibar' => 10 })

      located_mm.rift('bob')

      expect(DRCA).not_to have_received(:cast_spell)
      expect(displayed_messages).to include(no_moons_message)
    end

    it 'does not cast when moons are only rising (not in the visible list)' do
      UserVars.moons = moons(visible: [])

      run_rift

      expect(DRCA).not_to have_received(:cast_spell)
      expect(displayed_messages).to include(no_moons_message)
    end

    it 'does not cast Rift when locate fails' do
      UserVars.moons = moons(visible: %w[katamba])
      mm = located_mm
      allow(mm).to receive(:locate?).and_return(false)

      mm.rift('bob')

      expect(DRCA).not_to have_received(:cast_spell)
      expect(displayed_messages).to include('Unable to rift Bob due to failed locate')
    end
  end

  describe 'locate' do
    it 'does not check moonwatch' do
      allow(DRCMM).to receive(:check_moonwatch).and_return(false)
      $parsed_args = { 'locate' => true, 'person' => 'bob' }

      MoonMagery.new

      expect(DRCMM).not_to have_received(:check_moonwatch)
      expect(DRCA).to have_received(:cast_spell).once.with(hash_including('abbrev' => 'locate', 'cast' => 'cast Bob'), settings)
    end
  end
end
