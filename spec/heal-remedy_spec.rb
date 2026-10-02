# frozen_string_literal: true

require 'ostruct'
require_relative 'spec_helper'

HealRemedyMethods = load_lic_methods(
  'heal-remedy.lic',
  'wounds',
  'remedy_apply_wounds',
  'remedy_apply_scars',
  'remedy_apply_general_scar',
  'herb_apply_wounds',
  'herb_apply_scars',
  'drink_remedy?',
  'eat_remedy?',
  'inhale_remedy?'
)

RSpec.describe 'heal-remedy.lic' do
  let(:test_class) do
    Class.new do
      include HealRemedyMethods

      attr_accessor :settings, :override_mode, :wounds_applied, :remedy_container,
                    :drink_remedy_success_patterns, :drink_remedy_eat_patterns,
                    :remedy_inhale_patterns, :remedy_failure_patterns,
                    :eat_remedy_success_patterns, :eat_remedy_drink_patterns

      def initialize
        @settings = OpenStruct.new(herbs: true, remedy_container: 'apron')
        @remedy_container = 'apron'
        @override_mode = false
        @wounds_applied = false
        @drink_remedy_success_patterns = [/You drink/, /You take a drink/]
        @remedy_inhale_patterns = [/^You'd be better off trying to inhale/]
        @drink_remedy_eat_patterns = [/can't drink/]
        @remedy_failure_patterns = [/Drink what?/, /you referring to?/]
        @eat_remedy_success_patterns = [/You eat/]
        @eat_remedy_drink_patterns = [/^You'd be better off trying to drink/, /you should try drinking that?/]
      end

      def pause(_seconds = 0); end
    end
  end

  let(:runner) { test_class.new }
  let(:wound_struct) { Struct.new(:body_part) }

  before do
    $debug_mode_hr = false
    $heal_level = 0
    $quick_mode = true
    $nohands_mode = false
    $remedies = {
      'remedies' => {
        'external' => {
          'limbs' => ['jadice salve', 'yelith potion']
        },
        'scars'    => {
          'limbs'   => ['blocil ointment', 'nuloe draught'],
          'general' => ['dioica ointment', 'belradi draught']
        }
      }
    }

    allow(DRCH).to receive(:check_health).and_return(
      'wounds' => { 1 => [wound_struct.new('Right Arm')] }
    )
    allow(DRC).to receive(:message)
    allow(DRC).to receive(:bput).and_return('You')
    allow(DRCI).to receive(:get_item?).and_return(true)
    allow(DRCI).to receive(:put_away_item?).and_return(true)
  end

  after do
    $debug_mode_hr = nil
    $heal_level = nil
    $quick_mode = nil
    $nohands_mode = nil
    $remedies = nil
  end

  describe '#wounds routing with override' do
    context 'when herbs is true and override_mode is true' do
      it 'routes to remedy_apply_wounds and remedy_apply_scars instead of herb functions' do
        runner.override_mode = true
        expect(runner).to receive(:remedy_apply_wounds).with('limbs').and_call_original
        expect(runner).to receive(:remedy_apply_scars).with('limbs').and_call_original
        expect(runner).not_to receive(:herb_apply_wounds)
        expect(runner).not_to receive(:herb_apply_scars)

        runner.wounds
      end
    end

    context 'when herbs is true and override_mode is false' do
      it 'routes to herb_apply_wounds and herb_apply_scars' do
        runner.override_mode = false
        expect(runner).to receive(:herb_apply_wounds).with('limbs')
        expect(runner).not_to receive(:remedy_apply_wounds)

        runner.wounds
      end
    end

    context 'when herbs is false regardless of override_mode' do
      it 'routes to remedy_apply_wounds' do
        runner.settings.herbs = false
        runner.override_mode = false
        expect(runner).to receive(:remedy_apply_wounds).with('limbs').and_call_original
        expect(runner).not_to receive(:herb_apply_wounds)

        runner.wounds
      end
    end
  end

  describe '#remedy_apply_wounds' do
    context 'when $nohands_mode is false' do
      it 'gets rubbable remedies into hand and drinks potions from container' do
        $nohands_mode = false
        expect(DRCI).to receive(:get_item?).with('jadice salve', 'apron').and_return(true)
        expect(DRC).to receive(:bput).with('rub my jadice salve', 'You')
        expect(DRCI).to receive(:put_away_item?).with('jadice salve', 'apron')

        expect(runner).to receive(:drink_remedy?).with('yelith potion').and_return(true)
        expect(DRCI).not_to receive(:get_item?).with('yelith potion', any_args)

        runner.remedy_apply_wounds('limbs')
      end
    end

    context 'when $nohands_mode is true' do
      it 'skips salves that require hands and drinks potions without getting them' do
        $nohands_mode = true
        expect(DRCI).not_to receive(:get_item?).with('jadice salve', any_args)
        expect(runner).to receive(:drink_remedy?).with('yelith potion').and_return(true)

        runner.remedy_apply_wounds('limbs')
      end
    end

    context 'when an elixir is configured for wounds' do
      it 'eats the elixir directly without getting it into hand' do
        $remedies['remedies']['external']['limbs'] = ['hulij elixir']
        expect(runner).to receive(:eat_remedy?).with('hulij elixir').and_return(true)
        expect(DRCI).not_to receive(:get_item?).with('hulij elixir', any_args)

        runner.remedy_apply_wounds('limbs')
      end
    end
  end

  describe '#remedy_apply_scars' do
    context 'when $nohands_mode is true' do
      it 'skips scar ointments that require hands and drinks draughts' do
        $nohands_mode = true
        expect(DRCI).not_to receive(:get_item?).with('blocil ointment', any_args)
        expect(runner).to receive(:drink_remedy?).with('nuloe draught').and_return(true)

        runner.remedy_apply_scars('limbs')
      end
    end

    context 'when an elixir is configured for scars' do
      it 'eats the elixir directly without getting it into hand' do
        $remedies['remedies']['scars']['limbs'] = ['hulij elixir']
        expect(runner).to receive(:eat_remedy?).with('hulij elixir').and_return(true)
        expect(DRCI).not_to receive(:get_item?).with('hulij elixir', any_args)

        runner.remedy_apply_scars('limbs')
      end
    end

    context 'when the area-specific scar remedy is missing' do
      it 'falls back to the general scar remedies' do
        $nohands_mode = true
        $remedies['remedies']['scars']['limbs'] = ['nuloe draught']
        allow(DRC).to receive(:bput).with('drink my nuloe draught', any_args).and_return('Drink what?')
        expect(DRC).to receive(:bput).with('drink my belradi draught', any_args).and_return('You drink')

        runner.remedy_apply_scars('limbs')

        expect(runner.wounds_applied).to be(true)
      end
    end
  end

  describe 'when no remedy could be used' do
    it 'leaves wounds_applied false so the scar pass is skipped' do
      $nohands_mode = true
      allow(DRC).to receive(:bput).with('drink my yelith potion', any_args).and_return('Drink what?')

      runner.remedy_apply_wounds('limbs')

      expect(runner.wounds_applied).to be(false)
    end
  end
end
