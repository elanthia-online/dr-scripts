# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('magic-training.lic', 'MagicTraining')

RSpec.describe MagicTraining do
  # A planet spell (it has stats) and an ordinary one, as base-spells enriches them.
  let(:spheres) { { 'abbrev' => 'IOTS', 'skill' => 'Augmentation', 'ritual' => true, 'stats' => %w[Discipline Agility Wisdom] } }
  let(:shield) { { 'abbrev' => 'MAF', 'skill' => 'Warding', 'mana' => 5 } }
  let(:settings) do
    OpenStruct.new(
      magic_training_room: 1234,
      magic_exp_training_max_threshold: 32,
      training_spells: { 'Augmentation' => spheres, 'Warding' => shield },
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
    # A planet spell's lookup reads telescope_name and telescope_storage from settings.
    it 'passes settings to the astral lookup' do
      expect(DRCMM).to receive(:update_astral_data).with(spheres, settings).and_return(spheres)
      expect(DRCMM).to receive(:update_astral_data).with(shield, settings).and_return(shield)

      expect(magic_training.train_magics?(%w[Augmentation Warding])).to be(true)
    end

    it 'casts a spell whose astral lookup succeeds' do
      allow(DRCMM).to receive(:update_astral_data) { |data, _settings| data }

      magic_training.train_magics?(%w[Augmentation])

      expect(DRCA).to have_received(:cast_spells).with({ spell_name: spheres }, settings, anything)
    end

    it 'skips a spell whose astral lookup fails, and still casts the others' do
      allow(DRCMM).to receive(:update_astral_data) { |data, _settings| data == spheres ? nil : data }

      expect(magic_training.train_magics?(%w[Augmentation Warding])).to be(true)

      expect(DRCA).to have_received(:cast_spells).once
      expect(DRCA).to have_received(:cast_spells).with({ spell_name: shield }, settings, anything)
    end

    it 'reports nothing left to train when the only spell cannot be cast now' do
      allow(DRCMM).to receive(:update_astral_data).and_return(nil)

      expect(magic_training.train_magics?(%w[Augmentation])).to be(false)
      expect(DRCA).not_to have_received(:cast_spells)
    end

    # The planet lookup gets the telescope and centers it on every planet, so a
    # skill that is already trained up must not trigger it.
    it 'does no astral lookup for a skill already over the learning threshold' do
      DRSkill._set_xp('Augmentation', 33)
      allow(DRCMM).to receive(:update_astral_data) { |data, _settings| data }

      magic_training.train_magics?(%w[Augmentation Warding])

      expect(DRCMM).not_to have_received(:update_astral_data).with(spheres, anything)
      expect(DRCMM).to have_received(:update_astral_data).with(shield, settings)
      expect(DRCA).to have_received(:cast_spells).once
    end

    it 'does no astral lookup for a skill not chosen to train' do
      allow(DRCMM).to receive(:update_astral_data) { |data, _settings| data }

      magic_training.train_magics?(%w[Warding])

      expect(DRCMM).not_to have_received(:update_astral_data).with(spheres, anything)
    end
  end
end
