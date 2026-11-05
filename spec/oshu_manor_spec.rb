# frozen_string_literal: true

load_lic_class('oshu_manor.lic', 'Oshu')

RSpec.describe Oshu do
  let(:ignored_npcs) { %w[cat leopard] }
  let(:oshu) do
    described_class.allocate.tap { |o| o.instance_variable_set(:@ignored_npcs, ignored_npcs) }
  end

  # Other players' ESP, speech and whispers carrying the same text, raw and stripped.
  def player_lines(text)
    {
      'ESP'       => %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
      'say'       => %(<preset id='speech'>Mallory says</preset>, "#{text}"),
      'whisper'   => %(Mallory whispers, "#{text}"),
      'plain ESP' => %([General][Mallory] "#{text}"),
      'plain say' => %(Mallory says, "#{text}")
    }
  end

  describe 'puzzle flags' do
    let(:real_lines) do
      {
        'allready'   => "The gargoyle head doesn't budge.",
        'blasted'    => 'The blast catches you fully and sends you careening northward through the air!',
        'head-reset' => 'A stone gargoyle head suddenly makes a series of loud grinding noises.'
      }
    end

    # Feed a server line through the registered Flags matchers, the way
    # Lich's DRParser.check_events does for every downstream line.
    def deliver(line)
      Flags.matchers.each do |key, regexes|
        regexes.each do |regex|
          if (match = line.match(regex))
            Flags[key] = match
            break
          end
        end
      end
    end

    before do
      # initialize registers the flags, then starts digging (stubbed here).
      $test_settings = OpenStruct.new(ignored_npcs: [])
      allow(oshu).to receive(:grave_digger)
      oshu.send(:initialize)
      allow(oshu).to receive(:move)
      allow(oshu).to receive(:pause)
      allow(oshu).to receive(:gtfo)
      allow(oshu).to receive(:head_game)
      allow(DRC).to receive(:fix_standing)
    end

    describe "'blasted'" do
      it 'stands and walks back south on the real blast' do
        deliver(real_lines['blasted'])
        oshu.wait_and_check
        expect(oshu).to have_received(:move).with('south')
      end

      it 'still matches after leading tags or another sentence' do
        deliver("<pushBold/>#{real_lines['blasted']}<popBold/>")
        expect(Flags['blasted']).to be_truthy
        Flags.reset('blasted')
        deliver("A gout of flame erupts from the gargoyle's mouth!  #{real_lines['blasted']}")
        expect(Flags['blasted']).to be_truthy
      end

      it 'stays put when another player repeats it' do
        player_lines(real_lines['blasted']).each_value { |line| deliver(line) }
        oshu.wait_and_check
        expect(oshu).not_to have_received(:move)
      end
    end

    describe "'head-reset'" do
      it 'restarts the head puzzle on the real reset' do
        deliver(real_lines['head-reset'])
        oshu.wait_and_check
        expect(oshu).to have_received(:head_game)
      end

      it 'carries on when another player repeats it' do
        player_lines(real_lines['head-reset']).each_value { |line| deliver(line) }
        oshu.wait_and_check
        expect(oshu).not_to have_received(:head_game)
      end
    end

    describe "'allready'" do
      before do
        allow(DRC).to receive(:bput).with('turn head', any_args).and_return('Roundtime')
        $server_buffer = ['You grab the gargoyle head and wrestle it around until it points at the word "Fire."']
      end

      it 'leaves the manor when the head no longer turns' do
        deliver(real_lines['allready'])
        oshu.head_turner('Fire')
        expect(oshu).to have_received(:gtfo)
      end

      it 'keeps turning the head when another player repeats it' do
        player_lines(real_lines['allready']).each_value { |line| deliver(line) }
        oshu.head_turner('Fire')
        expect(oshu).not_to have_received(:gtfo)
        expect(DRC).to have_received(:bput).with('turn head', any_args).once
      end
    end
  end

  describe 'reading the game text' do
    let(:fire_look) { 'Peering closely, you see the crooked nose of the gargoyle head is pointed towards the word "Fire."' }
    let(:turned_to_fire) { 'You grab the gargoyle head and wrestle it around until it points at the word "Fire."' }

    # reget and waitfor see the stripped text.
    def stripped_player_lines(text)
      player_lines(text).values_at('plain ESP', 'plain say', 'whisper')
    end

    before do
      allow(oshu).to receive(:pause)
      allow(oshu).to receive(:fput)
      allow(oshu).to receive(:wait_and_check)
      allow(oshu).to receive(:gtfo)
      allow(DRC).to receive(:bput).and_return('Roundtime')
    end

    describe 'the dig-out wait' do
      # lich-5 waitfor: reads lines until one matches the joined patterns.
      let(:incoming) { [] }

      before do
        oshu.instance_variable_set(:@graves, [2334])
        oshu.instance_variable_set(:@critter, OpenStruct.new(worm: true))
        allow(Room).to receive(:current).and_return(OpenStruct.new(id: 2334))
        allow(DRC).to receive(:bput).with('dig grave', any_args).and_return('You use your bare hands')
        allow(oshu).to receive(:waitfor) do |*strings|
          regex = /#{strings.flatten.join('|')}/i
          incoming.shift until incoming.empty? || incoming.first =~ regex
          incoming.shift
        end
      end

      it 'stands up only once the game says the dig is through' do
        incoming.push(*stripped_player_lines('You dig to the surface'), 'You dig to the surface and pull yourself free.')
        expect(DRC).to receive(:fix_standing) { expect(incoming).to be_empty }
        oshu.grave_digger
      end
    end

    describe 'the head direction' do
      before { allow(oshu).to receive(:head_turner) }

      it 'skips turning to Fire when the head already points there' do
        $server_buffer = [fire_look]
        oshu.head_game
        expect(oshu).not_to have_received(:head_turner).with('Fire')
      end

      it "turns to Fire when only another player's text says it points there" do
        $server_buffer = stripped_player_lines(fire_look)
        oshu.head_game
        expect(oshu).to have_received(:head_turner).with('Fire')
      end
    end

    describe 'turning the head' do
      it 'stops once the game says the head points at the word' do
        $server_buffer = [turned_to_fire]
        oshu.head_turner('Fire')
        expect(DRC).to have_received(:bput).with('turn head', any_args).once
      end

      it "keeps turning while only another player's text says it does" do
        replies = [*stripped_player_lines(turned_to_fire), turned_to_fire]
        allow(DRC).to receive(:bput).with('turn head', any_args) do
          $server_buffer = [replies.shift]
          'Roundtime'
        end
        oshu.head_turner('Fire')
        expect(DRC).to have_received(:bput).with('turn head', any_args).exactly(4).times
      end
    end
  end

  describe '#safe_to_dig?' do
    it 'is safe in an empty room' do
      DRRoom.npcs = []
      expect(oshu.safe_to_dig?).to be(true)
    end

    it 'is safe when two creatures share an ignored noun' do
      DRRoom.npcs = %w[cat cat]
      expect(oshu.safe_to_dig?).to be(true)
    end

    it 'is unsafe when an unignored creature shares the room with duplicate ignored ones' do
      DRRoom.npcs = %w[cat cat worm]
      expect(oshu.safe_to_dig?).to be(false)
    end

    # Which creatures a full-name entry names is DRRoom.unignored_npcs's rule
    # (lich-5, tested there); these stub it and check safe_to_dig? passes the
    # configured list through and acts on what comes back.
    context 'with a full-name ignore entry' do
      let(:ignored_npcs) { ['spectral white leopard'] }

      it 'is safe when DRRoom.unignored_npcs drops the only creature, the named pet' do
        DRRoom.npcs = ['leopard']
        allow(DRRoom).to receive(:unignored_npcs).and_return([])
        expect(oshu.safe_to_dig?).to be(true)
        expect(DRRoom).to have_received(:unignored_npcs).with(['spectral white leopard'])
      end

      it 'is unsafe when DRRoom.unignored_npcs keeps a wild creature with the same noun' do
        DRRoom.npcs = %w[leopard leopard]
        allow(DRRoom).to receive(:unignored_npcs).with(['spectral white leopard']).and_return(['leopard'])
        expect(oshu.safe_to_dig?).to be(false)
      end
    end

    context 'when ignored_npcs is nil' do
      let(:ignored_npcs) { nil }

      it 'is safe in an empty room' do
        DRRoom.npcs = []
        expect(oshu.safe_to_dig?).to be(true)
      end

      it 'is unsafe when any creature is present' do
        DRRoom.npcs = ['worm']
        expect(oshu.safe_to_dig?).to be(false)
      end
    end
  end
end
