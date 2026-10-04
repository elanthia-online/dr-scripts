# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('magic-training.lic', 'MagicTraining')

RSpec.describe MagicTraining do
  # Spells as base-spells enriches them: a planet spell (it has stats), a moon
  # spell, and an ordinary one. In Lich only the moon lookup returns nil on
  # failure (no moon up); a failed planet lookup still returns a truthy value.
  let(:spheres) { { 'abbrev' => 'IOTS', 'skill' => 'Augmentation', 'ritual' => true, 'stats' => %w[Discipline Agility Wisdom] } }
  let(:moonbeam) { { 'abbrev' => 'FM', 'skill' => 'Utility', 'mana' => 1, 'moon' => true } }
  let(:shield) { { 'abbrev' => 'MAF', 'skill' => 'Warding', 'mana' => 5 } }
  let(:settings) do
    OpenStruct.new(
      magic_training_room: 1234,
      magic_exp_training_max_threshold: 32,
      training_spells: { 'Augmentation' => spheres, 'Utility' => moonbeam, 'Warding' => shield },
      telescope_name: 'telescope',
      telescope_storage: { 'container' => 'backpack' }
    )
  end

  # Instantiate without running initialize, which parses args and loops until done.
  let(:magic_training) do
    instance = MagicTraining.allocate
    allow(instance).to receive(:check_health)
    instance
  end

  before do
    $test_settings = settings
    allow(DRCA).to receive(:cast_spells)
  end

  describe '#train_magics?' do
    it 'passes settings to the astral lookup' do
      expect(DRCMM).to receive(:update_astral_data).with(moonbeam, settings).and_return(moonbeam)
      expect(DRCMM).to receive(:update_astral_data).with(shield, settings).and_return(shield)

      expect(magic_training.train_magics?(%w[Utility Warding])).to be(true)
    end

    # DRCA.cast_spell finds the planet itself before casting, so a lookup here
    # would only sweep the telescope a second time.
    it 'leaves the planet lookup to the cast and casts a planet spell' do
      allow(DRCMM).to receive(:update_astral_data) { |data, _settings| data }

      expect(magic_training.train_magics?(%w[Augmentation])).to be(true)

      expect(DRCMM).not_to have_received(:update_astral_data).with(spheres, anything)
      expect(DRCA).to have_received(:cast_spells).with({ spell_name: spheres }, settings, anything)
    end

    it 'casts a moon spell while a moon is up' do
      allow(DRCMM).to receive(:update_astral_data) { |data, _settings| data }

      magic_training.train_magics?(%w[Utility])

      expect(DRCA).to have_received(:cast_spells).with({ spell_name: moonbeam }, settings, anything)
    end

    it 'skips a moon spell while no moon is up, and still casts the others' do
      allow(DRCMM).to receive(:update_astral_data) { |data, _settings| data == moonbeam ? nil : data }

      expect(magic_training.train_magics?(%w[Utility Warding])).to be(true)

      expect(DRCA).to have_received(:cast_spells).once
      expect(DRCA).to have_received(:cast_spells).with({ spell_name: shield }, settings, anything)
    end

    it 'reports nothing left to train when the only spell is a moon spell and no moon is up' do
      allow(DRCMM).to receive(:update_astral_data).and_return(nil)

      expect(magic_training.train_magics?(%w[Utility])).to be(false)
      expect(DRCA).not_to have_received(:cast_spells)
    end

    it 'does no astral lookup for a skill already over the learning threshold' do
      DRSkill._set_xp('Utility', 33)
      allow(DRCMM).to receive(:update_astral_data) { |data, _settings| data }

      magic_training.train_magics?(%w[Utility Warding])

      expect(DRCMM).not_to have_received(:update_astral_data).with(moonbeam, anything)
      expect(DRCMM).to have_received(:update_astral_data).with(shield, settings)
      expect(DRCA).to have_received(:cast_spells).once
    end

    it 'does no astral lookup for a skill not chosen to train' do
      allow(DRCMM).to receive(:update_astral_data) { |data, _settings| data }

      magic_training.train_magics?(%w[Warding])

      expect(DRCMM).not_to have_received(:update_astral_data).with(moonbeam, anything)
    end
  end
end
