# frozen_string_literal: true

require 'ostruct'

load_lic_class('theurgy.lic', 'TheurgyActions')
load_lic_class('theurgy.lic', 'Theurgy')

RSpec.describe TheurgyActions do
  # Other players' speech, whispers and ESP reach the same matchers as game
  # output; these check theurgy only acts on the game's own lines.
  describe 'game lines vs. player text' do
    let(:actions) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@communes, [{ name: 'eluned' }, { name: 'tamsine' }, { name: 'truffenyi' }, { name: 'kertigen' }])
        a.instance_variable_set(:@data, { 'altar' => { 'id' => 1 }, 'bath' => { 'id' => 2 } })
        a.instance_variable_set(:@theurgy_supply_container, 'bag')
        a.instance_variable_set(:@water_holder, 'chalice')
        a.instance_variable_set(:@flint_lighter, 'flint')
      end
    end

    # Raw server forms, as Flags see them (lich-5 DRParser.check_events).
    def raw_player_lines(text)
      [%(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
       %(<preset id='speech'>Mallory says</preset>, "#{text}"),
       %(<preset id='speech'>Mallory whispers</preset>, "#{text}")]
    end

    # Stripped forms, as bput and waitfor see them.
    def player_lines(text)
      [%([General][Mallory] "#{text}"), %(Mallory says, "#{text}"), %(Mallory whispers, "#{text}")]
    end

    # Feed a server line through the registered Flags matchers, the way
    # lich-5's DRParser.check_events does for every downstream line.
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

    # lich-5 DRC.bput: Strings become /x/i; the first line that matches any
    # pattern ends the wait and bput returns the matched text.
    def lich_bput(patterns, lines)
      regexes = patterns.map { |p| p.is_a?(Regexp) ? p : /#{p}/i }
      lines.each do |line|
        regexes.each do |regex|
          match = line.match(regex)
          return match.to_a.first if match
        end
      end
      nil
    end

    describe 'commune cooldown flags' do
      before do
        theurgy = Theurgy.allocate
        allow(theurgy).to receive(:pray)
        allow(TheurgyActions).to receive(:new)
          .and_return(double('actions', buy_supplies: nil, rituals_remain?: false, roll_prayer_mat: nil))
        theurgy.send(:initialize)
      end

      def ready
        { commune: actions.send(:can_commune?) }.merge(
          actions.instance_variable_get(:@communes).to_h { |c| [c[:name], actions.commune_ready?(c)] }
        )
      end

      all_ready = { commune: true, 'eluned' => true, 'tamsine' => true, 'truffenyi' => true, 'kertigen' => true }
      cooldown_lines = {
        'You will not be able to open another divine conduit yet.'                            => { commune: false },
        'You stop as you realize that you have attempted a commune too recently in the past.' => { commune: false },
        'You grind some dirt in your fist, allowing the particles to slowly trickle out.'     => { commune: false, 'eluned' => false },
        'The waters of Eluned are still in your thoughts.'                                    => { 'eluned' => false },
        'You feel warmth spread throughout your body.'                                        => { commune: false, 'tamsine' => false },
        'You have been recently enlightened by Tamsine.'                                      => { 'tamsine' => false },
        'The power of Truffenyi has answered your prayer.'                                    => { commune: false, 'truffenyi' => false },
        "You are still captivated by Truffenyi's favor."                                      => { 'truffenyi' => false },
        'The thick smell of ozone fills your nostrils.'                                       => { commune: false, 'kertigen' => false },
        "The sounds of Kertigen's forge still ring in your ears."                             => { 'kertigen' => false }
      }

      cooldown_lines.each do |line, changes|
        it "puts communes on cooldown on the game line '#{line[0, 40]}...'" do
          deliver(line)
          expect(ready).to eq(all_ready.merge(changes))
        end

        it "still matches '#{line[0, 40]}...' after a leading tag" do
          deliver("<pushBold/>#{line}")
          expect(ready).to eq(all_ready.merge(changes))
        end

        it "ignores '#{line[0, 40]}...' in other players' ESP, speech and whispers" do
          raw_player_lines(line).each { |l| deliver(l) }
          expect(ready).to eq(all_ready)
        end
      end

      it 'clears the shared cooldown on the game line saying communes are ready again' do
        deliver('You will not be able to open another divine conduit yet.')
        deliver('You feel fully prepared to seek assistance from the Immortals once again.')
        expect(ready[:commune]).to be(true)
      end

      it "keeps the shared cooldown when a player repeats the 'fully prepared' line" do
        deliver('You will not be able to open another divine conduit yet.')
        raw_player_lines('You feel fully prepared to seek assistance from the Immortals once again.').each { |l| deliver(l) }
        expect(ready[:commune]).to be(false)
      end
    end

    describe "Glythtide's Gift offering for Truffenyi" do
      let(:heard) { [] }

      before do
        DRSpells._set_known_spells({ "Glythtide's Gift" => true })
        allow(DRCI).to receive(:inside?).and_return(false)
        allow(actions).to receive(:complete_or_interrupt_research)
        allow(actions).to receive(:continue_research)
        allow(actions).to receive(:pause)
        allow(DRCA).to receive(:cast_spell) { heard.each { |l| deliver(l) } }
        allow(DRC).to receive(:bput).and_return('The power of Truffenyi has answered your prayer')
        allow(DRC).to receive(:right_hand).and_return('goblet of blackberry stout')
      end

      chuckle = 'You hear a distant but hearty chuckle as a goblet of blackberry stout appears in your right hand!'

      it 'communes and drops the conjured drink named in the game line' do
        heard << chuckle
        expect(actions.commune_truffenyi).to be(false)
        expect(DRC).to have_received(:bput).with('commune truffenyi', any_args)
        expect(DRC).to have_received(:bput).with('drop stout', any_args)
      end

      it 'still reads the drink after a leading tag' do
        heard << "<pushBold/>#{chuckle}"
        actions.commune_truffenyi
        expect(DRC).to have_received(:bput).with('drop stout', any_args)
      end

      it 'does not commune when the game says both hands are full' do
        heard << 'Both your hands are full!'
        expect(actions.commune_truffenyi).to be(false)
        expect(DRC).not_to have_received(:bput).with('commune truffenyi', any_args)
      end

      it "does not take a drink named in other players' ESP, speech or whispers" do
        heard.concat(raw_player_lines('You hear a distant but hearty chuckle as a sword appears in your right hand!'))
        expect(actions.commune_truffenyi).to be(false)
        expect(DRC).not_to have_received(:bput).with('commune truffenyi', any_args)
        expect(DRC).not_to have_received(:bput).with('drop sword', any_args)
      end
    end

    # lich-5 waitfor joins its strings into /x/i and returns the first line
    # that matches. Here each wait gets player lines carrying the text first,
    # then the game line; the wait must end on the game line.
    describe 'waits for ritual messages' do
      let(:waited) { [] }

      def wait_through(text, game_line)
        feed = player_lines(text) + [game_line]
        allow(actions).to receive(:waitfor) do |*strings|
          regex = /#{strings.flatten.join('|')}/i
          waited << feed.find { |line| line =~ regex }
        end
      end

      before do
        allow(actions).to receive(:safe_walk_to)
        allow(actions).to receive(:pause)
      end

      it 'waits for the game line on the stairway, the sigil study and the relief' do
        allow(actions).to receive(:get_data).and_return(OpenStruct.new(spell_data: {}))
        allow(DRC).to receive(:bput).with('pull candle', any_args).and_return('You grasp hold of the silver candlestick and pull it back')
        allow(DRC).to receive(:bput).with('study wall', any_args).and_return('Turning your attention to the sigils')
        feed = {}
        ['Four beautifully detailed figures', 'as your understanding of the sigils gradually slips away.',
         'A low relief has been carefully carved'].each do |text|
          feed[text] = player_lines(text) + ["#{text} (game line)"]
        end
        allow(actions).to receive(:waitfor) do |*strings|
          regex = /#{strings.flatten.join('|')}/i
          waited << feed.values.flatten.find { |line| line =~ regex }
        end
        expect(actions.study_wall).to be(true)
        expect(waited).to eq(['Four beautifully detailed figures (game line)',
                              'as your understanding of the sigils gradually slips away. (game line)',
                              'A low relief has been carefully carved (game line)'])
      end

      it 'waits for the game line when a bead detaches' do
        allow(actions).to receive(:get_prayer_chain?).and_return(true)
        allow(actions).to receive(:count_prayer_beads).and_return(3)
        allow(actions).to receive(:replace_prayer_chain)
        wait_through('suddenly detaches from your prayer bead chain', 'A bead suddenly detaches from your prayer bead chain.')
        actions.meditate_bead
        expect(waited).to eq(['A bead suddenly detaches from your prayer bead chain.'])
      end

      it 'waits for the game line after the bath' do
        wait_through('You wake up once more, blinking dazedly.', 'You wake up once more, blinking dazedly.')
        actions.bathe
        expect(waited).to eq(['You wake up once more, blinking dazedly.'])
      end

      it 'waits for the game line when cleaning the altar' do
        allow(actions).to receive(:holy_water?).and_return(true)
        wait_through('You finish your job', 'You finish your job.')
        actions.clean_altar
        expect(waited).to eq(['You finish your job.'])
      end

      it 'waits for the game line when invoking the parchment' do
        allow(DRCI).to receive(:inside?).and_return(true)
        wait_through('You conclude', 'You conclude your recitation.')
        actions.embarass_myself
        expect(waited).to eq(['You conclude your recitation.'])
      end
    end

    describe 'item replies' do
      def sent
        Array.new(sent_messages.size) { sent_messages.pop }
      end

      # Each command gets a player line first, then the game's reply.
      def replies(map)
        allow(DRC).to receive(:bput) do |command, *patterns|
          player, game = map.fetch(command)
          lich_bput(patterns, [player, game].compact)
        end
      end

      it 'keeps the prayer chain the game handed over when a player says "What were you referring to?"' do
        replies('get prayer chain' => ['Mallory says, "What were you referring to?"', 'You get a prayer chain from inside your bag.'])
        expect(actions.get_prayer_chain?).to be(true)
        expect(sent).not_to include('remove my prayer chain')
      end

      it 'removes the worn chain on the game reply' do
        replies('get prayer chain' => [nil, 'The prayer chain is already in your inventory.'])
        expect(actions.get_prayer_chain?).to be(true)
        expect(sent).to include('remove my prayer chain')
      end

      it "does not remove the chain when a player whispers 'already in your inventory'" do
        replies('get prayer chain' => ['Mallory whispers, "it is already in your inventory"', 'You get a prayer chain from inside your bag.'])
        actions.get_prayer_chain?
        expect(sent).not_to include('remove my prayer chain')
      end

      it 'does not pray with a badge it did not get when a player thinks "You get"' do
        replies('remove pilgrim badge' => [nil, 'Remove what?'],
                'get badge'            => ['[General][Mallory] "You get used to it."', 'What were you referring to?'])
        expect(actions.pray_badge).to be(false)
        expect(sent).not_to include('pray pilgrim badge')
      end

      it 'prays with the badge the game handed over' do
        replies('remove pilgrim badge' => [nil, 'Remove what?'],
                'get badge'            => [nil, 'You get a pilgrim badge from inside your bag.'])
        allow(actions).to receive(:waitrt?)
        expect(actions.pray_badge).to be(true)
        expect(sent).to include('pray pilgrim badge')
      end

      it 'ends the incense waits on the game replies, not on player speech' do
        allow(actions).to receive(:walk_to_altar_or_prayer_mat)
        allow(actions).to receive(:pause)
        allow(DRCI).to receive(:exists?).and_return(false)
        seen = {}
        allow(DRC).to receive(:bput) do |command, *patterns|
          seen[command] = patterns
          'bursts into flames'
        end
        actions.incense
        game = { 'get flint'                  => 'You get a piece of black flint from inside your bag.',
                 'lower my incense to ground' => 'You lower some incense to the ground.',
                 'get my incense'             => 'You pick up some incense.' }
        game.each do |command, reply|
          expect(lich_bput(seen.fetch(command), [reply])).not_to be_nil, command
          player_lines('you get the idea, you lower it and you put it back').each do |line|
            expect(lich_bput(seen.fetch(command), [line])).to be_nil, "#{command}: #{line}"
          end
        end
      end
    end
  end

  describe '#sirese_seed invasion check' do
    let(:ignored_npcs) { %w[cat leopard] }
    let(:actions) do
      described_class.allocate.tap do |a|
        a.instance_variable_set(:@settings, OpenStruct.new(ignored_npcs: ignored_npcs))
        a.instance_variable_set(:@data, { 'gather_sirese' => { 'id' => 1 }, 'plant_sirese' => { 'id' => 2 } })
        a.instance_variable_set(:@water_holder, 'chalice')
        a.instance_variable_set(:@theurgy_supply_container, 'bag')
      end
    end

    before do
      allow(actions).to receive(:holy_water?).and_return(true)
      allow(actions).to receive(:safe_walk_to)
      allow(DRC).to receive(:bput).and_return('You find a tiny')
    end

    # An unexpected exit must fail the example, not end the whole run.
    def gathers_seed
      result = nil
      expect { result = actions.sirese_seed }.not_to raise_error
      expect(result).to be(true)
      expect(DRC).to have_received(:bput).with('gather seed', any_args)
    end

    def aborts_on_invasion
      expect { actions.sirese_seed }.to raise_error(SystemExit)
      expect(DRC).not_to have_received(:bput).with('gather seed', any_args)
    end

    it 'gathers in an empty room' do
      DRRoom.npcs = []
      gathers_seed
    end

    it 'gathers when two creatures share an ignored noun' do
      DRRoom.npcs = %w[cat cat]
      gathers_seed
    end

    it 'aborts when an unignored creature shares the room with duplicate ignored ones' do
      DRRoom.npcs = %w[cat cat moradu]
      aborts_on_invasion
    end

    # Which creatures a full-name entry names is DRRoom.unignored_npcs's rule
    # (lich-5, tested there); these stub it and check the check passes the
    # configured list through and acts on what comes back.
    context 'with a full-name ignore entry' do
      let(:ignored_npcs) { ['spectral white leopard'] }

      it 'gathers when DRRoom.unignored_npcs drops the only creature, the named pet' do
        DRRoom.npcs = ['leopard']
        allow(DRRoom).to receive(:unignored_npcs).and_return([])
        gathers_seed
        expect(DRRoom).to have_received(:unignored_npcs).with(['spectral white leopard'])
      end

      it 'aborts when DRRoom.unignored_npcs keeps a wild creature with the same noun' do
        DRRoom.npcs = %w[leopard leopard]
        allow(DRRoom).to receive(:unignored_npcs).with(['spectral white leopard']).and_return(['leopard'])
        aborts_on_invasion
      end
    end

    context 'when ignored_npcs is nil' do
      let(:ignored_npcs) { nil }

      it 'gathers in an empty room' do
        DRRoom.npcs = []
        gathers_seed
      end

      it 'aborts when any creature is present' do
        DRRoom.npcs = ['cat']
        aborts_on_invasion
      end
    end
  end
end
