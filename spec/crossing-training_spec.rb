# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('crossing-training.lic', 'CrossingTraining')

RSpec.describe CrossingTraining do
  # cast_spell's moon-spell path: DRCMM.check_moonwatch says whether
  # moonwatch's moon data is available at all (false when moonwatch can't be
  # found, stops, or never publishes); DRCMM.set_moon_data picks a visible moon
  # for data['cast'], falls back to ambient light for Cage of Light, and
  # returns nil when no moon is usable.
  let(:outdoor_room) { 1234 }
  let(:settings) do
    OpenStruct.new(
      outdoor_room: outdoor_room,
      cambrinth_items: [{ 'name' => 'cambrinth armband', 'cap' => 32, 'stored' => true }],
      dedicated_camb_use: nil,
      cambrinth_invoke_exact_amount: nil,
      custom_spell_prep: nil
    )
  end
  let(:trainer) do
    described_class.allocate.tap { |t| t.instance_variable_set(:@settings, settings) }
  end
  let(:moon_spell) do
    { 'abbrev' => 'moonblade', 'name' => 'Moonblade', 'moon' => true, 'mana' => 5, 'cambrinth' => [[]] }
  end
  let(:cage_of_light) do
    { 'abbrev' => 'col', 'name' => 'Cage of Light', 'moon' => true, 'mana' => 5, 'cambrinth' => [[]] }
  end
  # Moons set_moon_data finds visible, one entry per call (the last repeats).
  let(:visible_moons_per_call) { [[]] }

  before(:each) do
    allow(DRCA).to receive(:check_discern) { |data, _settings| data }
    allow(DRCA).to receive(:prepare?).and_return(true)
    allow(DRCA).to receive(:cast?).and_return(true)
    allow(DRCA).to receive(:release_cyclics)
    allow(DRCA).to receive(:find_charge_invoke_stow)
    allow(DRC).to receive(:bput).with('weather', any_args).and_return('You glance up at the sky.')
    allow(DRCT).to receive(:walk_to).and_return(true)
    allow(trainer).to receive(:fput)

    calls = visible_moons_per_call.dup
    allow(DRCMM).to receive(:set_moon_data) do |data|
      moons = calls.size > 1 ? calls.shift : calls.first
      if moons.any?
        data['cast'] = "cast #{moons.first}"
        data
      elsif data['name'].casecmp?('cage of light')
        data['cast'] = 'cast ambient'
        data
      end
    end
  end

  describe '#cast_spell with a moon spell' do
    context 'when moonwatch data is unavailable (check_moonwatch returns false)' do
      before(:each) { allow(DRCMM).to receive(:check_moonwatch).and_return(false) }

      it 'does not check the weather or perceive the moons' do
        trainer.cast_spell(moon_spell, 'Augmentation')

        expect(DRC).not_to have_received(:bput).with('weather', any_args)
        expect(trainer).not_to have_received(:fput).with('perceive moons')
      end

      it 'does not walk even when the character is inside' do
        allow(DRC).to receive(:bput).with('weather', any_args).and_return('inside')

        trainer.cast_spell(moon_spell, 'Augmentation')

        expect(DRCT).not_to have_received(:walk_to)
      end

      it 'does not prepare or cast the spell' do
        trainer.cast_spell(moon_spell, 'Augmentation')

        expect(DRCA).not_to have_received(:prepare?)
        expect(DRCA).not_to have_received(:cast?)
      end

      it 'asks set_moon_data once, so its "no moon" message is printed once' do
        trainer.cast_spell(moon_spell, 'Augmentation')

        expect(DRCMM).to have_received(:set_moon_data).once
      end

      it 'checks moonwatch once' do
        trainer.cast_spell(moon_spell, 'Augmentation')

        expect(DRCMM).to have_received(:check_moonwatch).once
      end

      it 'still casts Cage of Light on ambient light, which needs no moon' do
        trainer.cast_spell(cage_of_light, 'Augmentation')

        expect(DRCA).to have_received(:prepare?).with('col', 5, nil, 'prepare', false, nil, false, nil)
        expect(DRCA).to have_received(:cast?).with('cast ambient', nil, nil, nil)
        expect(DRCT).not_to have_received(:walk_to)
        expect(trainer).not_to have_received(:fput).with('perceive moons')
      end

      context 'when moonwatch publishes between the check and the moon lookup' do
        let(:visible_moons_per_call) { [%w[xibar]] }

        it 'casts at the moon set_moon_data found' do
          trainer.cast_spell(moon_spell, 'Augmentation')

          expect(DRCA).to have_received(:cast?).with('cast xibar', nil, nil, nil)
        end
      end
    end

    context 'on a Lich whose check_moonwatch returns nil (no availability answer)' do
      before(:each) { allow(DRCMM).to receive(:check_moonwatch).and_return(nil) }

      context 'and no moon is up from inside' do
        let(:visible_moons_per_call) { [[], %w[katamba]] }

        before(:each) do
          allow(DRC).to receive(:bput).with('weather', any_args).and_return('inside')
        end

        it 'still goes to the outdoor room, perceives the moons and casts at the moon found then' do
          trainer.cast_spell(moon_spell, 'Augmentation')

          expect(DRCT).to have_received(:walk_to).with(outdoor_room)
          expect(trainer).to have_received(:fput).with('perceive moons')
          expect(DRCA).to have_received(:cast?).with('cast katamba', nil, nil, nil)
        end
      end

      context 'and a moon is up' do
        let(:visible_moons_per_call) { [%w[xibar]] }

        it 'casts at that moon' do
          trainer.cast_spell(moon_spell, 'Augmentation')

          expect(DRCA).to have_received(:cast?).with('cast xibar', nil, nil, nil)
        end
      end
    end

    context 'when moonwatch data is available' do
      before(:each) { allow(DRCMM).to receive(:check_moonwatch).and_return(true) }

      context 'and a moon is up' do
        let(:visible_moons_per_call) { [%w[katamba]] }

        it 'casts at that moon without going outside' do
          trainer.cast_spell(moon_spell, 'Augmentation')

          expect(DRCA).to have_received(:cast?).with('cast katamba', nil, nil, nil)
          expect(DRCT).not_to have_received(:walk_to)
          expect(trainer).not_to have_received(:fput).with('perceive moons')
        end

        it 'looks the moon up once' do
          trainer.cast_spell(moon_spell, 'Augmentation')

          expect(DRCMM).to have_received(:set_moon_data).once
        end
      end

      context 'and the moon sets between two lookups' do
        # A second lookup would find no moon; the first answer is the one used.
        let(:visible_moons_per_call) { [%w[yavash], []] }

        it 'casts at the moon from the first lookup' do
          trainer.cast_spell(moon_spell, 'Augmentation')

          expect(DRCA).to have_received(:cast?).with('cast yavash', nil, nil, nil)
        end
      end

      context 'and no moon is up from inside' do
        let(:visible_moons_per_call) { [[], %w[xibar]] }

        before(:each) do
          allow(DRC).to receive(:bput).with('weather', any_args).and_return('inside')
        end

        it 'goes to the outdoor room, perceives the moons and casts at the moon found then' do
          trainer.cast_spell(moon_spell, 'Augmentation')

          expect(DRCT).to have_received(:walk_to).with(outdoor_room)
          expect(trainer).to have_received(:fput).with('perceive moons')
          expect(DRCA).to have_received(:cast?).with('cast xibar', nil, nil, nil)
        end
      end

      context 'and no moon is up from outdoors' do
        let(:visible_moons_per_call) { [[], %w[xibar]] }

        it 'perceives the moons without walking' do
          trainer.cast_spell(moon_spell, 'Augmentation')

          expect(DRCT).not_to have_received(:walk_to)
          expect(trainer).to have_received(:fput).with('perceive moons')
          expect(DRCA).to have_received(:cast?).with('cast xibar', nil, nil, nil)
        end
      end

      context 'and still no moon after perceiving' do
        let(:visible_moons_per_call) { [[]] }

        it 'does not prepare or cast' do
          trainer.cast_spell(moon_spell, 'Augmentation')

          expect(trainer).to have_received(:fput).with('perceive moons')
          expect(DRCMM).to have_received(:set_moon_data).twice
          expect(DRCA).not_to have_received(:prepare?)
          expect(DRCA).not_to have_received(:cast?)
        end
      end
    end
  end

  describe '#cast_spell with a spell that needs no moon' do
    it 'does not check moonwatch' do
      allow(DRCMM).to receive(:check_moonwatch)

      trainer.cast_spell({ 'abbrev' => 'ease', 'mana' => 5, 'cambrinth' => [[]] }, 'Augmentation')

      expect(DRCMM).not_to have_received(:check_moonwatch)
      expect(DRCMM).not_to have_received(:set_moon_data)
      expect(DRCA).to have_received(:cast?)
    end
  end
end
