# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('bescort.lic', 'Bescort')

RSpec.describe Bescort do
  let(:equipment_manager) { instance_double(Harness::EquipmentManager, empty_hands: nil) }
  let(:gear_sets) { { 'standard' => ['steel shield'], 'swimming' => ['seal cloak'] } }
  let(:flying_mount) { nil }
  let(:bescort) do
    described_class.allocate.tap do |b|
      b.instance_variable_set(:@settings, OpenStruct.new(gear_sets: gear_sets))
      b.instance_variable_set(:@equipment_manager, equipment_manager)
      b.instance_variable_set(:@flying_mount, flying_mount)
    end
  end

  before(:each) do
    reset_data
    allow(DRC).to receive(:message)
    allow(DRC).to receive(:bput).and_return('')
    allow(DRCT).to receive(:walk_to)
    allow(DRCMM).to receive(:check_moonwatch).and_return(true)
  end

  # Records every gear set worn, answering each with the given result.
  def wear_sets_returning(results)
    worn = []
    allow(equipment_manager).to receive(:wear_equipment_set?) do |set_name|
      worn << set_name
      results.fetch(set_name)
    end
    worn
  end

  describe '#wear_swimming_gear?' do
    context 'when the swimming set is configured' do
      it 'is true when the swimming set was worn' do
        worn = wear_sets_returning('swimming' => true)
        expect(bescort.send(:wear_swimming_gear?)).to be(true)
        expect(worn).to eq(['swimming'])
      end

      it 'is true when wearing the swimming set failed, since standard gear may already be off' do
        worn = wear_sets_returning('swimming' => false)
        expect(bescort.send(:wear_swimming_gear?)).to be(true)
        expect(worn).to eq(['swimming'])
      end

      it 'is true when wear_equipment_set? returns nil' do
        wear_sets_returning('swimming' => nil)
        expect(bescort.send(:wear_swimming_gear?)).to be(true)
      end

      context 'as an empty list' do
        let(:gear_sets) { { 'standard' => ['steel shield'], 'swimming' => [] } }

        it 'is true, since wearing an empty set takes everything else off' do
          wear_sets_returning('swimming' => true)
          expect(bescort.send(:wear_swimming_gear?)).to be(true)
        end
      end
    end

    context 'when the swimming set is not configured' do
      [
        ['no gear_sets at all', nil],
        ['gear_sets without a swimming key', { 'standard' => ['steel shield'] }],
        ['a swimming key with no value', { 'standard' => ['steel shield'], 'swimming' => nil }]
      ].each do |label, sets|
        context "with #{label}" do
          let(:gear_sets) { sets }

          it 'still asks for the swimming set (which reports it missing) and is false' do
            worn = wear_sets_returning('swimming' => false)
            expect(bescort.send(:wear_swimming_gear?)).to be(false)
            expect(worn).to eq(['swimming'])
          end
        end
      end
    end

    context 'with a flying mount' do
      let(:flying_mount) { 'broom' }

      it 'is false and changes no gear' do
        expect(equipment_manager).not_to receive(:wear_equipment_set?)
        expect(bescort.send(:wear_swimming_gear?)).to be(false)
      end
    end
  end

  describe '#cave_trolls' do
    before do
      allow(bescort).to receive(:manual_go2)
      allow(bescort).to receive(:move)
      allow(bescort).to receive(:swim)
      allow(bescort).to receive(:use_flying_mount)
    end

    it 'puts the standard set back on after a swim whose swimming set failed' do
      worn = wear_sets_returning('swimming' => false, 'standard' => true)
      bescort.send(:cave_trolls, 'enter')
      expect(worn).to eq(%w[swimming standard])
    end

    it 'puts the standard set back on after a successful change' do
      worn = wear_sets_returning('swimming' => true, 'standard' => true)
      bescort.send(:cave_trolls, 'exit')
      expect(worn).to eq(%w[swimming standard])
    end

    it 'puts the standard set back on before leaving the stream' do
      calls = []
      allow(equipment_manager).to receive(:wear_equipment_set?) do |set_name|
        calls << "wear #{set_name}"
        set_name == 'standard'
      end
      allow(bescort).to receive(:swim) { |dir| calls << "swim #{dir}" }
      allow(bescort).to receive(:move) { |command| calls << command }
      bescort.send(:cave_trolls, 'enter')
      expect(calls).to eq(['go stream bank', 'wear swimming', 'swim southeast', 'swim southeast', 'swim southeast',
                           'wear standard', 'go stream bank'])
    end

    context 'without a swimming set' do
      let(:gear_sets) { { 'standard' => ['steel shield'] } }

      it 'leaves the worn gear alone afterwards' do
        worn = wear_sets_returning('swimming' => false)
        bescort.send(:cave_trolls, 'enter')
        expect(worn).to eq(['swimming'])
      end
    end

    context 'with a flying mount' do
      let(:flying_mount) { 'broom' }

      it 'changes no gear' do
        expect(equipment_manager).not_to receive(:wear_equipment_set?)
        bescort.send(:cave_trolls, 'enter')
      end
    end
  end

  describe '#segoltha' do
    before do
      allow(bescort).to receive(:move)
      allow(bescort).to receive(:echo)
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: 19_373))
      # No exit to swim toward: the swim loop ends at once.
      allow(XMLData).to receive(:room_exits).and_return(%w[east up out])
    end

    it 'puts the standard set back on after a swim whose swimming set failed' do
      worn = wear_sets_returning('swimming' => false, 'standard' => true)
      bescort.send(:segoltha, 'north')
      expect(worn).to eq(%w[swimming standard])
    end

    context 'without a swimming set' do
      let(:gear_sets) { nil }

      it 'leaves the worn gear alone afterwards' do
        worn = wear_sets_returning('swimming' => false)
        bescort.send(:segoltha, 'north')
        expect(worn).to eq(['swimming'])
      end
    end

    it 'puts the standard set back on after the swim loop, not before' do
      calls = []
      allow(equipment_manager).to receive(:wear_equipment_set?) do |set_name|
        calls << "wear #{set_name}"
        true
      end
      allow(XMLData).to receive(:room_exits) do
        calls << 'exits'
        %w[east up out]
      end
      bescort.send(:segoltha, 'north')
      expect(calls.first).to eq('wear swimming')
      expect(calls.last).to eq('wear standard')
      expect(calls).to include('exits')
    end

    context 'when not at the start room' do
      before { allow(Room).to receive(:current).and_return(OpenStruct.new(id: 1)) }

      it 'exits without changing gear, so there is nothing to put back' do
        expect(bescort).to receive(:echo).with(/Must start bescort in room 19373/)
        expect(equipment_manager).not_to receive(:wear_equipment_set?)
        expect { bescort.send(:segoltha, 'north') }.to raise_error(SystemExit)
      end
    end

    context 'with a mode that is not a direction' do
      it 'exits without emptying hands or changing gear' do
        expect(equipment_manager).not_to receive(:empty_hands)
        expect(equipment_manager).not_to receive(:wear_equipment_set?)
        expect { bescort.send(:segoltha, 'east') }.to raise_error(SystemExit)
      end
    end

    context 'with a flying mount' do
      let(:flying_mount) { 'broom' }

      it 'empties hands and mounts without changing gear or checking the start room' do
        allow(Room).to receive(:current).and_return(OpenStruct.new(id: 1))
        expect(equipment_manager).to receive(:empty_hands).ordered
        expect(bescort).to receive(:use_flying_mount).with('broom', 'mount', 'skim').ordered
        expect(bescort).to receive(:use_flying_mount).with('broom', 'dismount').ordered
        expect(equipment_manager).not_to receive(:wear_equipment_set?)
        bescort.send(:segoltha, 'north')
      end
    end
  end

  describe '#sun_up?' do
    it 'is true by day' do
      UserVars.sun = { 'running' => true, 'day' => true }
      expect(bescort.send(:sun_up?)).to be(true)
    end

    it 'is false by night' do
      UserVars.sun = { 'running' => true, 'day' => false }
      expect(bescort.send(:sun_up?)).to be(false)
    end

    it 'accepts data from a moonwatch without the running key' do
      UserVars.sun = { 'day' => false }
      expect(bescort.send(:sun_up?)).to be(false)
    end

    it 'accepts a check_moonwatch that returns nil (lich versions before it returned a result)' do
      allow(DRCMM).to receive(:check_moonwatch).and_return(nil)
      UserVars.sun = { 'running' => true, 'day' => true }
      expect(bescort.send(:sun_up?)).to be(true)
    end

    it 'is nil without reading the sun data when check_moonwatch returns false' do
      allow(DRCMM).to receive(:check_moonwatch).and_return(false)
      expect(UserVars).not_to receive(:sun)
      expect(bescort.send(:sun_up?)).to be_nil
    end

    it 'waits for a freshly started moonwatch to write the sun data' do
      states = [nil, {}, { 'running' => true }, { 'running' => true, 'day' => false }]
      allow(UserVars).to receive(:sun) { states.length > 1 ? states.shift : states.first }
      expect(bescort).to receive(:pause).with(described_class::SUN_DATA_POLL_INTERVAL).exactly(3).times
      expect(bescort.send(:sun_up?)).to be(false)
    end

    [
      ['never written', nil],
      ['an empty hash', {}],
      ['left over from a stopped moonwatch', { 'running' => false, 'day' => true }],
      ['a day that is not true or false', { 'running' => true, 'day' => 'yes' }],
      ['a day that is missing', { 'running' => true, 'timer' => 12 }]
    ].each do |label, sun|
      it "gives up after a bounded wait when the sun data is #{label}" do
        UserVars.sun = sun
        polls = (described_class::SUN_DATA_TIMEOUT / described_class::SUN_DATA_POLL_INTERVAL).ceil
        expect(bescort).to receive(:pause).with(described_class::SUN_DATA_POLL_INTERVAL).exactly(polls).times
        expect(bescort.send(:sun_up?)).to be_nil
      end
    end
  end

  describe '#coffin' do
    # Game replies for one solve with the boar image: the black wheel shows
    # the dark image on the second look, the white wheel the light image at once.
    let(:replies) { { 'look sunlight' => 'boar', 'look starlight' => 'boar' } }

    before do
      allow(bescort).to receive(:pause)
      allow(equipment_manager).to receive(:empty_hands)
      black_looks = 0
      allow(DRC).to receive(:bput) do |command, *matches|
        case command
        when 'look wooden wheel'
          if matches.include?('berserking barbarian')
            black_looks += 1
            black_looks > 1 ? 'berserking barbarian' : 'grimacing woman'
          else
            'longbow'
          end
        when 'pull iron lever' then 'Roundtime'
        else replies.fetch(command, '')
        end
      end
    end

    context 'when moonwatch cannot provide its data' do
      before { allow(DRCMM).to receive(:check_moonwatch).and_return(false) }

      it 'stops with a message before walking anywhere' do
        expect(DRCT).not_to receive(:walk_to)
        expect(DRC).to receive(:message).with(/moonwatch has not said whether the sun is up/)
        expect { bescort.send(:coffin) }.to raise_error(SystemExit)
      end
    end

    context 'when the sun data never arrives' do
      it 'stops with a message before walking anywhere' do
        UserVars.sun = {}
        expect(DRCT).not_to receive(:walk_to)
        expect(DRC).to receive(:message).with(/moonwatch has not said whether the sun is up/)
        expect { bescort.send(:coffin) }.to raise_error(SystemExit)
      end
    end

    it 'looks at the sunlight by day and solves the puzzle' do
      UserVars.sun = { 'running' => true, 'day' => true }
      bescort.send(:coffin)
      expect(DRC).to have_received(:bput).with('look sunlight', any_args)
      expect(DRC).to have_received(:bput).with('pull rope', any_args).once
      expect(DRC).to have_received(:bput).with('go coffin', any_args)
    end

    it 'looks at the starlight by night' do
      UserVars.sun = { 'running' => true, 'day' => false }
      bescort.send(:coffin)
      expect(DRC).to have_received(:bput).with('look starlight', any_args)
      expect(DRC).not_to have_received(:bput).with('look sunlight', any_args)
    end

    it 'matches the image whatever its case' do
      UserVars.sun = { 'running' => true, 'day' => true }
      replies['look sunlight'] = 'Boar'
      bescort.send(:coffin)
      expect(DRC).to have_received(:bput).with('go coffin', any_args)
    end

    [
      ['the look finds nothing', 'I could not find what'],
      ['the look gets no matching reply', '']
    ].each do |label, reply|
      it "stops instead of turning the wheels forever when #{label}" do
        UserVars.sun = { 'running' => true, 'day' => true }
        replies['look sunlight'] = reply
        expect(DRC).to receive(:message).with(/found no image when looking at the sunlight/)
        expect { bescort.send(:coffin) }.to raise_error(SystemExit)
        expect(DRC).not_to have_received(:bput).with('look wooden wheel', any_args)
        expect(DRC).not_to have_received(:bput).with('pull rope', any_args)
      end
    end
  end
end
