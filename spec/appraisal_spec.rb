# frozen_string_literal: true

require_relative 'spec_helper'

# Appraisal#initialize depends on the full Lich runtime (parse_args, EquipmentManager,
# get_settings, and it immediately runs the training tasks), so -- following the
# taisidon/smoke pattern -- we extract the class with load_lic_class and exercise its
# seams on bare-allocated instances (Appraisal.allocate).
#
# Coverage focuses on the gem-kit feature added in PR #7404, which ships with no
# in-game test and relies on game-message parsing:
#   - pouch_name: label assembly from adjective + noun.
#   - classify_pouch: the appraise -> open -> re-appraise -> route decision, including
#     the reopen-reclassify fix (a closed pouch must still be routed by value/emptiness
#     after it is opened, not silently left in the default container).
#   - count_kit_pouches: scraping the highest pouch index out of RUMMAGE output.
#   - train_appraisal_with_kit_pouches: the TURN-to-slot / PULL loop ordering and the
#     skip-on-failed-pull guard.
load_lic_class('appraisal.lic', 'Appraisal')

describe Appraisal do
  let(:appraisal) { Appraisal.allocate }

  # Route DRC.bput by the command that was issued. Values may be a scalar (returned
  # every time) or an Array (shifted per call, so the same command can echo different
  # results on successive invocations -- e.g. appraise before and after opening).
  def stub_bput_by_command(responses)
    allow(DRC).to receive(:bput) do |command, *_patterns|
      key = responses.keys.find { |prefix| command.start_with?(prefix) }
      raise "unexpected bput command in test: #{command.inspect}" unless key

      value = responses[key]
      value.is_a?(Array) ? value.shift : value
    end
  end

  describe '#pouch_name' do
    it 'joins adjective and noun' do
      expect(appraisal.pouch_name('deep', 'gem pouch')).to eq('deep gem pouch')
    end

    it 'drops a nil adjective' do
      expect(appraisal.pouch_name(nil, 'gem pouch')).to eq('gem pouch')
    end

    it 'drops an empty-string adjective' do
      expect(appraisal.pouch_name('', 'gem pouch')).to eq('gem pouch')
    end
  end

  describe '#classify_pouch' do
    before { appraisal.instance_variable_set(:@count, false) }

    it 'leaves a full, high-value pouch in the default container (returns nil)' do
      stub_bput_by_command('appraise my' => 'The pouch is worth a total of about 5000 dokoras.')

      result = appraisal.classify_pouch('gem pouch', 1000, 'lowbox', 'sparebox')

      expect(result).to be_nil
    end

    it 'routes a low-value pouch to the low_value container' do
      stub_bput_by_command('appraise my' => 'The pouch is worth a total of about 500 dokoras.')

      result = appraisal.classify_pouch('gem pouch', 1000, 'lowbox', 'sparebox')

      expect(result).to eq('lowbox')
    end

    it 'routes an empty pouch to the spare container when one is defined' do
      stub_bput_by_command('appraise my' => "There doesn't appear to be anything in the pouch.")

      result = appraisal.classify_pouch('gem pouch', 1000, 'lowbox', 'sparebox')

      expect(result).to eq('sparebox')
    end

    it 'leaves an empty pouch in the default container when no spare is defined (returns nil)' do
      stub_bput_by_command('appraise my' => "There doesn't appear to be anything in the pouch.")

      result = appraisal.classify_pouch('gem pouch', 1000, 'lowbox', '')

      expect(result).to be_nil
    end

    it 'leaves a pouch with an unrecognized appraise result in the default container (returns nil)' do
      stub_bput_by_command('appraise my' => 'You glance around, confused.')

      result = appraisal.classify_pouch('gem pouch', 1000, 'lowbox', 'sparebox')

      expect(result).to be_nil
    end

    # Regression guard for the CodeRabbit finding: when the first appraise reports the
    # pouch must be opened, the SECOND appraise result must drive routing. Before the
    # fix the reopened result was discarded and a low-value pouch fell through to the
    # default container.
    it 'reclassifies after opening a closed pouch and routes it by the reopened value' do
      stub_bput_by_command(
        'appraise my' => [
          "You'll need to open the pouch to examine its contents.",
          'The pouch is worth a total of about 500 dokoras.'
        ],
        'open my'     => 'You open your gem pouch.',
        'close my'    => 'You close your gem pouch.'
      )

      result = appraisal.classify_pouch('gem pouch', 1000, 'lowbox', 'sparebox')

      expect(result).to eq('lowbox')
    end

    it 'closes a pouch it had to open' do
      stub_bput_by_command(
        'appraise my' => [
          "You'll need to open the pouch to examine its contents.",
          'The pouch is worth a total of about 5000 dokoras.'
        ],
        'open my'     => 'You open your gem pouch.',
        'close my'    => 'You close your gem pouch.'
      )

      appraisal.classify_pouch('gem pouch', 1000, 'lowbox', 'sparebox')

      expect(DRC).to have_received(:bput).with(a_string_starting_with('close my'), anything, anything)
    end

    it 'does not close a pouch that was already open' do
      stub_bput_by_command('appraise my' => 'The pouch is worth a total of about 5000 dokoras.')

      appraisal.classify_pouch('gem pouch', 1000, 'lowbox', 'sparebox')

      expect(DRC).not_to have_received(:bput).with(a_string_starting_with('close my'), anything, anything)
    end

    context 'when counting is enabled' do
      before { appraisal.instance_variable_set(:@count, true) }

      it 'routes a high-value but not-full pouch to the low_value container' do
        stub_bput_by_command(
          'appraise my' => 'The pouch is worth a total of about 5000 dokoras.',
          'count my'    => 'You sort through the contents of the pouch and find 300 gems in it.'
        )

        result = appraisal.classify_pouch('gem pouch', 1000, 'lowbox', 'sparebox')

        expect(result).to eq('lowbox')
      end

      it 'leaves a high-value, full pouch in the default container (returns nil)' do
        stub_bput_by_command(
          'appraise my' => 'The pouch is worth a total of about 5000 dokoras.',
          'count my'    => 'You sort through the contents of the pouch and find 500 gems in it.'
        )

        result = appraisal.classify_pouch('gem pouch', 1000, 'lowbox', 'sparebox')

        expect(result).to be_nil
      end
    end
  end

  describe '#count_kit_pouches' do
    it 'returns the highest pouch index listed in the rummage output' do
      $history = [
        'Rummaging through your gem kit you find it contains:',
        '  1. a gem pouch',
        '  2. a gem pouch',
        '  3. a gem pouch',
        'Roundtime: 5 sec.'
      ]

      expect(appraisal.count_kit_pouches('gem kit')).to eq(3)
    end

    it 'returns the highest index even when the listing is out of order' do
      $history = [
        'Rummaging through your gem kit you find it contains:',
        '  2. a gem pouch',
        '  1. a gem pouch',
        '  3. a gem pouch',
        'Roundtime: 5 sec.'
      ]

      expect(appraisal.count_kit_pouches('gem kit')).to eq(3)
    end

    it 'returns 0 for an empty kit' do
      $history = [
        'Rummaging through your gem kit you find it contains:',
        'Roundtime: 5 sec.'
      ]

      expect(appraisal.count_kit_pouches('gem kit')).to eq(0)
    end

    it 'returns 0 when the target is not a container' do
      $history = ["That isn't a container."]

      expect(appraisal.count_kit_pouches('gem kit')).to eq(0)
    end

    it 'ignores numbered lines that appear before the listing header' do
      $history = [
        '  9. a decoy line before the header',
        'Rummaging through your gem kit you find it contains:',
        '  1. a gem pouch',
        '  2. a gem pouch',
        'Roundtime: 5 sec.'
      ]

      expect(appraisal.count_kit_pouches('gem kit')).to eq(2)
    end
  end

  describe '#train_appraisal_with_kit_pouches' do
    before do
      DRSkill._set_xp('Appraisal', 0)
      allow(appraisal).to receive(:count_kit_pouches).and_return(2)
      allow(appraisal).to receive(:classify_pouch).and_return('lowbox')
      allow(DRCI).to receive(:put_away_item?).and_return(true)
    end

    it 'iterates kit slots from highest to lowest, pulling and putting away each pouch' do
      stub_bput_by_command(
        'turn my' => 'You turn the gem kit to a new setting.',
        'pull my' => 'You get a gem pouch from your gem kit.'
      )

      appraisal.train_appraisal_with_kit_pouches('gem kit', 'sparebox', 'lowbox', 1000, 'deep', 'gem pouch')

      expect(DRC).to have_received(:bput).with('turn my gem kit to 2', any_args).ordered
      expect(DRC).to have_received(:bput).with('turn my gem kit to 1', any_args).ordered
      expect(DRCI).to have_received(:put_away_item?).with('deep gem pouch', 'lowbox').twice
    end

    it 'skips a slot when the pull does not yield a pouch' do
      stub_bput_by_command(
        'turn my' => 'You turn the gem kit to a new setting.',
        'pull my' => 'The gem kit is empty.'
      )

      appraisal.train_appraisal_with_kit_pouches('gem kit', 'sparebox', 'lowbox', 1000, 'deep', 'gem pouch')

      expect(appraisal).not_to have_received(:classify_pouch)
      expect(DRCI).not_to have_received(:put_away_item?)
    end

    it 'does nothing when the kit is empty' do
      allow(appraisal).to receive(:count_kit_pouches).and_return(0)

      appraisal.train_appraisal_with_kit_pouches('gem kit', 'sparebox', 'lowbox', 1000, 'deep', 'gem pouch')

      expect(appraisal).not_to have_received(:classify_pouch)
    end

    it 'does nothing when no gem_kit_name is configured' do
      appraisal.train_appraisal_with_kit_pouches('', 'sparebox', 'lowbox', 1000, 'deep', 'gem pouch')

      expect(appraisal).not_to have_received(:count_kit_pouches)
    end
  end
end
