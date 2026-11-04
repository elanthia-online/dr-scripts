# frozen_string_literal: true

require 'ostruct'
require 'timeout'

require_relative 'spec_helper'

load_lic_class('weave-cloth.lic', 'WeaveCloth')

# Game lines are real, from Mahtra's weaving in Shard on 2026-11-04
# (spec/fixtures/*/log_lines.json, cited "1104:<line>"). ReplayGame answers
# every DRC.bput and fput the script sends from those lines, so these examples
# run the real WeaveCloth code from its constructor, exactly as `;weave-cloth`
# does.
RSpec.describe WeaveCloth do
  def log(cite)
    ReplayGame.log(cite)
  end

  let(:game) { ReplayGame.new.install(self) }

  # A weave that never ends would hang the suite instead of failing it, and an
  # exit nothing expected would end the whole run with status 0 (spec_helper).
  around do |example|
    Timeout.timeout(10) { example.run }
  rescue SystemExit
    raise 'weave-cloth exited where the example expected it to carry on'
  end

  # Mahtra's two heavy silk spools (XML: exist="1958040" and exist="1963477"),
  # as spin records them, oldest first.
  let(:silk_spools) do
    [{ 'id' => '1958040', 'fiber' => 'silk', 'weight' => 'heavy' },
     { 'id' => '1963477', 'fiber' => 'silk', 'weight' => 'heavy' }]
  end

  before do
    $test_settings = OpenStruct.new(hometown: 'Shard', crafting_container: 'duffel bag')
    $test_data = OpenStruct.new(crafting: { 'tailoring' => {
      'Shard'    => { 'loom-rooms' => [10_941, 10_942], 'idle-room' => 19_333 },
      'Crossing' => { 'loom-rooms' => [14_886], 'idle-room' => 16_661 }
    } })
    UserVars.spun_spools = silk_spools
    # DRCT walks to each loom room in turn and asks weave-cloth's predicate;
    # this one stands in a single room and asks once.
    allow(DRCT).to receive(:find_empty_room) { |_rooms, _idle, ready, *| ready.call(1) }
  end

  # The loom's side of the 19:03 weave in Mahtra's log (1104:30817-30860):
  # two weaves, a bunch, dust, two weaves, an unravel, and the cloth.
  def script_weave
    game.script('weave loom', log('1104:30817'), log('1104:30818'))
    game.script('weave loom', log('1104:30820'), log('1104:30821'), log('1104:30822'))
    game.script('turn loom', log('1104:30828'), log('1104:30829'))
    game.script('weave loom', log('1104:30832'), log('1104:30833'), log('1104:30834'))
    game.script('clean loom', log('1104:30840'), log('1104:30841'))
    game.script('weave loom', log('1104:30844'), log('1104:30845'))
    game.script('weave loom', log('1104:30847'), log('1104:30848'))
    game.script('weave loom', log('1104:30850'), log('1104:30851'), log('1104:30852'))
    # The cloth is in hand once the reply has arrived (XML: <left
    # exist="1976604" noun="cloth">silk cloth</left> with the snip line).
    game.script('push loom', log('1104:30858'), log('1104:30859'), log('1104:30860'),
                after: lambda { |_|
                  $left_hand = 'silk cloth'
                  $hand_ids['silk cloth'] = '1976604'
                })
    # The loom after the weave; no log looks at it then.
    game.fallback('look on loom', log('1104:30590'))
  end

  # An empty loom, then both spools loaded (1104:30799, 30803, 30815).
  def script_empty_loom_and_load(first: '1963477', second: '1958040')
    game.script('look on loom', log('1104:30590'))
    game.script("put ##{first} on loom", log('1104:30803'))
    game.script("put ##{second} on loom", log('1104:30815'))
  end

  describe 'finding a loom' do
    it "searches force_crafting_town's loom rooms when it is set, like spin and sew" do
      $test_settings.force_crafting_town = 'Crossing'
      expect(DRCT).to receive(:find_empty_room).with([14_886], 16_661, anything, 0, false, 5).and_return(false)

      expect { WeaveCloth.new }.to raise_error(SystemExit)
    end

    it "searches the hometown's loom rooms otherwise" do
      expect(DRCT).to receive(:find_empty_room).with([10_941, 10_942], 19_333, anything, 0, false, 5).and_return(false)

      expect { WeaveCloth.new }.to raise_error(SystemExit)
    end

    it 'stops with a message when no loom comes free in five passes' do
      allow(DRCT).to receive(:find_empty_room).and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Could not find a free loom in Shard.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent).to be_empty
    end

    it 'stops before walking when the town has no loom rooms in the data' do
      $test_settings.hometown = 'Aesry'
      expect(DRCT).not_to receive(:find_empty_room)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: No loom rooms are known for Aesry.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
    end

    it 'says "your crafting town" when no town is set' do
      $test_settings.hometown = nil
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: No loom rooms are known for your crafting town.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
    end

    it 'passes over a room where another player is, without touching its loom' do
      allow(DRRoom).to receive(:pcs).and_return(['Gilfoyle'])
      allow(DRCT).to receive(:find_empty_room) { |_rooms, _idle, ready, *| ready.call(1) }

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent).to be_empty
    end
  end

  describe 'choosing the spools' do
    before do
      script_empty_loom_and_load
      script_weave
    end

    it 'takes the two spools spin recorded, by id, newest first' do
      expect(DRCI).to receive(:get_item?).with('#1963477').ordered.and_return(true)
      expect(DRCI).to receive(:get_item?).with('#1958040').ordered.and_return(true)

      WeaveCloth.new
    end

    it 'never asks the game for "my thread", which took the cotton sewing thread (1104:30598)' do
      WeaveCloth.new

      expect(game.sent.grep(/\bmy thread\b/)).to be_empty
    end

    it 'loads exactly those two spools onto the loom' do
      WeaveCloth.new

      expect(game.sent.grep(/\Aput #\d+ on loom\z/)).to eq(['put #1963477 on loom', 'put #1958040 on loom'])
    end

    it 'never falls back to an older kind when the newest spool has no partner' do
      # e.g. a restock whose second linen spin failed must not weave the
      # player's silk instead
      UserVars.spun_spools = silk_spools + [{ 'id' => '1970000', 'fiber' => 'linen', 'weight' => 'heavy' }]
      expect(Lich::Messaging).to receive(:msg).with('bold', "weave-cloth: #{WeaveCloth::NEED_TWO_SPOOLS}")

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent).to be_empty
    end

    it 'does not pair two weights of one fiber' do
      UserVars.spun_spools = [silk_spools.first, { 'id' => '1963477', 'fiber' => 'silk', 'weight' => 'thin' }]
      expect(Lich::Messaging).to receive(:msg).with('bold', "weave-cloth: #{WeaveCloth::NEED_TWO_SPOOLS}")

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent).to be_empty
    end

    it 'leaves yarn out: it is for knitting' do
      UserVars.spun_spools = silk_spools.map { |spool| spool.merge('weight' => 'yarn') }

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent).to be_empty
    end

    it 'forgets both spools once they are woven' do
      WeaveCloth.new

      expect(UserVars.spun_spools).to eq([])
    end

    it 'keeps the spools it did not weave in the record' do
      older = { 'id' => '1900000', 'fiber' => 'silk', 'weight' => 'heavy' }
      UserVars.spun_spools = [older] + silk_spools

      WeaveCloth.new

      expect(UserVars.spun_spools).to eq([older])
    end
  end

  describe 'when a recorded spool cannot be got' do
    it 'takes the next one of the same thread, keeping the missing one recorded' do
      UserVars.spun_spools = [{ 'id' => '1900000', 'fiber' => 'silk', 'weight' => 'heavy' }] + silk_spools
      allow(DRCI).to receive(:get_item?) { |ref| ref != '#1958040' }
      script_empty_loom_and_load(first: '1963477', second: '1900000')
      script_weave

      WeaveCloth.new

      expect(UserVars.spun_spools.map { |spool| spool['id'] }).to eq(['1958040'])
      expect(game.sent.grep(/\Aput #\d+ on loom\z/)).to eq(['put #1963477 on loom', 'put #1900000 on loom'])
    end

    it 'puts the one it found back in the crafting container and stops when no second turns up' do
      game.script('look on loom', log('1104:30590'))
      allow(DRCI).to receive(:get_item?) { |ref| ref == '#1963477' }
      expect(DRCI).to receive(:put_away_item?).with('#1963477', 'duffel bag').and_return(true)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Could not get spool #1958040; it may be elsewhere.')
      expect(Lich::Messaging).to receive(:msg).with('bold', "weave-cloth: #{WeaveCloth::NEED_TWO_SPOOLS}")

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent.grep(/\Aput #\d+ on loom\z/)).to be_empty
      expect(UserVars.spun_spools.map { |spool| spool['id'] }).to eq(%w[1958040 1963477])
    end
  end

  describe 'with no spools recorded' do
    it 'stops before walking anywhere, saying how to get spools' do
      UserVars.spun_spools = nil
      expect(DRCC).not_to receive(:find_loom_room)
      expect(Lich::Messaging).to receive(:msg).with('bold', "weave-cloth: #{WeaveCloth::NEED_TWO_SPOOLS}")

      expect { WeaveCloth.new }.to raise_error(SystemExit)
    end

    it 'treats a record that is not a list as empty' do
      UserVars.spun_spools = 'junk'

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent).to be_empty
    end
  end

  describe 'spool ids given on the command line' do
    before { $parse_args_model = true }

    it 'weaves exactly the two spools named, with or without the #' do
      $script_vars = ArgParserModel.script_vars('#1958040 1963477')
      script_empty_loom_and_load(first: '1958040', second: '1963477')
      script_weave
      expect(DRCI).to receive(:get_item?).with('#1958040').ordered.and_return(true)
      expect(DRCI).to receive(:get_item?).with('#1963477').ordered.and_return(true)

      WeaveCloth.new
    end

    it 'refuses the same spool twice' do
      $script_vars = ArgParserModel.script_vars('1958040 #1958040')
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Give two different spool ids.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent).to be_empty
    end

    it 'does not accept one id alone' do
      $script_vars = ArgParserModel.script_vars('1958040')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent).to be_empty
    end
  end

  describe 'a loom that already holds thread' do
    let(:loaded_with_cotton) { ReplayGame.code('The loom is loaded with some cotton thread.', from: 'weave-cloth.lic@c2739670:6') }
    let(:nothing_to_pull) { ReplayGame.code('You see nothing to pull.', from: 'weave-cloth.lic@c2739670:8') }

    before do
      game.script('look on loom', loaded_with_cotton)
      # The pulled thread lands in a hand with its id (XML: <left
      # exist="1626431" noun="thread">cotton thread</left>, 1104:30752).
      game.script('pull loom', log('1104:30752'), after: lambda { |_|
        $left_hand = 'cotton thread'
        $hand_ids['cotton thread'] = '1626431'
      })
    end

    it 'puts its own thread, left by a run that stopped, back in the crafting container' do
      UserVars.spun_spools = [{ 'id' => '1626431', 'fiber' => 'cotton', 'weight' => 'heavy' }] + silk_spools
      game.script('pull loom', nothing_to_pull)
      game.script('put #1963477 on loom', log('1104:30803'))
      game.script('put #1958040 on loom', log('1104:30815'))
      script_weave
      allow(DRCI).to receive(:put_away_item?).and_return(true)

      WeaveCloth.new

      expect(DRCI).to have_received(:put_away_item?).with('#1626431', 'duffel bag')
    end

    it "puts anyone else's thread back on the loom and passes the room over, dropping nothing" do
      game.script('put #1626431 on loom', log('1104:30601'))
      expect(Lich::Messaging).to receive(:msg).with('plain', "weave-cloth: This loom holds someone else's cotton thread; left it there and looking for another.")
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Could not find a free loom in Shard.')
      expect(DRCI).not_to receive(:put_away_item?)
      expect(DRCI).not_to receive(:get_item?)

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent.grep(/\Adrop\b/)).to be_empty
    end

    it "weaves at the next loom room when this one holds someone else's thread" do
      allow(DRCT).to receive(:find_empty_room) { |rooms, _idle, ready, *| rooms.any? { ready.call(1) } }
      game.script('put #1626431 on loom', log('1104:30601'))
      script_empty_loom_and_load
      script_weave

      WeaveCloth.new

      expect(game.sent.grep(/\Aput #\d+ on loom\z/)).to eq(['put #1626431 on loom', 'put #1963477 on loom', 'put #1958040 on loom'])
    end

    it 'treats spools given by id as its own when a stopped run left them on the loom' do
      $parse_args_model = true
      $script_vars = ArgParserModel.script_vars('1626431 1958040')
      UserVars.spun_spools = nil
      game.script('pull loom', nothing_to_pull)
      game.script('put #1626431 on loom', log('1104:30803'))
      game.script('put #1958040 on loom', log('1104:30815'))
      script_weave
      allow(DRCI).to receive(:put_away_item?) do
        $left_hand = nil
        true
      end

      WeaveCloth.new

      expect(DRCI).to have_received(:put_away_item?).with('#1626431', 'duffel bag')
      expect(game.sent).to include('weave loom')
    end

    it "says the stranger's thread is in hand when the loom will not take it back" do
      game.script('put #1626431 on loom')
      expect(Lich::Messaging).to receive(:msg).with('bold', "weave-cloth: The loom holds someone else's cotton thread; it is in your hand.")

      expect { WeaveCloth.new }.to raise_error(SystemExit)
    end

    it 'takes both of its own threads off a full loom, then weaves' do
      UserVars.spun_spools = [{ 'id' => '1626431', 'fiber' => 'cotton', 'weight' => 'heavy' },
                              { 'id' => '1626432', 'fiber' => 'cotton', 'weight' => 'heavy' }] + silk_spools
      game.script('pull loom', log('1104:30752'), after: ->(_) { $hand_ids['cotton thread'] = '1626432' })
      game.script('pull loom', nothing_to_pull)
      game.script('put #1963477 on loom', log('1104:30803'))
      game.script('put #1958040 on loom', log('1104:30815'))
      script_weave
      allow(DRCI).to receive(:put_away_item?).and_return(true)

      WeaveCloth.new

      expect(DRCI).to have_received(:put_away_item?).with('#1626431', 'duffel bag')
      expect(DRCI).to have_received(:put_away_item?).with('#1626432', 'duffel bag')
      expect(game.sent.count('pull loom')).to eq(3)
    end

    it 'stops when the loom keeps giving thread past a full load' do
      UserVars.spun_spools = [{ 'id' => '1626431', 'fiber' => 'cotton', 'weight' => 'heavy' }] + silk_spools
      game.script('pull loom', log('1104:30752'))
      game.script('pull loom', log('1104:30752'))
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: The loom still holds thread after taking 3 off.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
    end
  end

  describe 'when the loom will not see or take the spools' do
    it 'stops when the look at the loom goes unanswered' do
      game.script('look on loom')
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Could not see whether the loom is loaded.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
    end

    it 'puts both spools back, the loaded one included, when the loom refuses the second (1104:30609)' do
      game.script('look on loom', log('1104:30590'))
      game.script('put #1963477 on loom', log('1104:30803'))
      game.script('put #1958040 on loom', log('1104:30609'))
      game.script('pull loom', log('1104:30752'), after: lambda { |_|
        $left_hand = 'silk thread'
        $hand_ids['silk thread'] = '1963477'
      })
      expect(DRCI).to receive(:put_away_item?).with('#1958040', 'duffel bag').ordered.and_return(true)
      expect(DRCI).to receive(:put_away_item?).with('#1963477', 'duffel bag').ordered.and_return(true)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: The loom will not take spool #1958040 with the other: a simple loom weaves two threads of one material. The spools are back in your bag.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent.grep(/\Adrop\b/)).to be_empty
      expect(game.sent).not_to include('weave loom')
    end

    it 'puts both spools back, the one still in hand included, when the loom does not answer the first' do
      game.script('look on loom', log('1104:30590'))
      game.script('put #1963477 on loom')
      expect(DRCI).to receive(:put_away_item?).with('#1963477', 'duffel bag').and_return(true)
      expect(DRCI).to receive(:put_away_item?).with('#1958040', 'duffel bag').and_return(true)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Could not put spool #1963477 on the loom. The spools are back in your bag.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent).not_to include('pull loom')
    end
  end

  describe 'weaving' do
    before { script_empty_loom_and_load }

    context 'the whole 16-yard heavy silk weave from the log' do
      before { script_weave }

      it 'answers each loom problem with its fix, then weaves on' do
        WeaveCloth.new

        weave_commands = game.sent.drop_while { |command| command != 'weave loom' }.take(9)
        expect(weave_commands).to eq(
          ['weave loom', 'weave loom', 'turn loom', 'weave loom', 'clean loom',
           'weave loom', 'weave loom', 'weave loom', 'push loom']
        )
      end

      it 'puts the cloth in the crafting container by its id, not in the stow container' do
        expect(DRCI).to receive(:put_away_item?).with('#1976604', 'duffel bag').and_return(true)

        WeaveCloth.new

        expect(game.sent.grep(/\Astow\b/)).to be_empty
      end

      it 'says where the cloth went' do
        expect(Lich::Messaging).to receive(:msg).with('plain', 'weave-cloth: Put the silk cloth (#1976604) in your duffel bag.')

        WeaveCloth.new
      end

      it 'stops with a message, the cloth in hand, when it will not go into the container' do
        allow(DRCI).to receive(:put_away_item?).and_return(false)
        expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Could not put the silk cloth (#1976604) in your duffel bag; it is in your hand.')

        expect { WeaveCloth.new }.to raise_error(SystemExit)
        expect(UserVars.spun_spools).to eq([])
      end

      it 'keeps weaving when a background script puts something else in a hand' do
        game.override('clean loom', log('1104:30840'), log('1104:30841'), after: ->(_) { $right_hand = 'encyclopedic almanac' })
        expect(DRCI).to receive(:put_away_item?).with('#1976604', 'duffel bag').and_return(true)

        WeaveCloth.new

        expect(game.sent).to include('push loom')
      end
    end

    it 'stops on "needs to have 2 sections of thread" instead of weaving forever, putting both spools back (1104:30615)' do
      game.script('weave loom', log('1104:30615'))
      game.script('pull loom', log('1104:30752'), after: lambda { |_|
        $left_hand = 'silk thread'
        $hand_ids['silk thread'] = '1963477'
      })
      game.script('pull loom', log('1104:30752'), after: lambda { |_|
        $right_hand = 'silk thread'
        $hand_ids['silk thread'] = '1958040'
      })
      expect(DRCI).to receive(:put_away_item?).with('#1963477', 'duffel bag').and_return(true)
      expect(DRCI).to receive(:put_away_item?).with('#1958040', 'duffel bag').and_return(true)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: The loom will not weave the spools: each needs 10 yards or more. The spools are back in your bag.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent.count('weave loom')).to eq(1)
      expect(UserVars.spun_spools).to eq(silk_spools)
    end

    it 'says how many spools are still on the loom when it cannot pull them back' do
      game.script('weave loom', log('1104:30615'))
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: The loom will not weave the spools: each needs 10 yards or more. 2 of 2 spools are still on the loom or in your hands.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent.count('pull loom')).to eq(2)
    end

    it 'stops with a message after three unanswered weaves, trying to pull the spools back' do
      expect(Lich::Messaging).to receive(:msg).with('bold', "weave-cloth: The loom did not answer 'weave loom' 3 times in a row. 2 of 2 spools are still on the loom or in your hands.")

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent.count('weave loom')).to eq(3)
      expect(game.sent).not_to include('stow my cloth')
    end

    it 'starts the count again after a weave the game answers' do
      game.script('weave loom')
      game.script('weave loom')
      game.script('weave loom', log('1104:30817'), log('1104:30818'))

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent.count('weave loom')).to eq(6)
    end

    it 'stops after 100 commands when the cloth never comes' do
      endless = ReplayGame.new(send_budget: 200).install(self)
      endless.script('look on loom', log('1104:30590'))
      endless.script('put #1963477 on loom', log('1104:30803'))
      endless.script('put #1958040 on loom', log('1104:30815'))
      endless.fallback('weave loom', log('1104:30817'), log('1104:30818'))
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: No cloth after 100 commands to the loom. 2 of 2 spools are still on the loom or in your hands.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(endless.sent.count('weave loom')).to eq(100)
    end
  end

  describe 'thread left on the loom after the weave' do
    let(:loaded_with_silk) { ReplayGame.code('The loom is loaded with some heavy silk thread.', from: 'weave-cloth.lic@c2739670:6') }
    let(:nothing_to_pull) { ReplayGame.code('You see nothing to pull.', from: 'weave-cloth.lic@c2739670:8') }

    before do
      script_empty_loom_and_load
      script_weave
      game.script('look on loom', loaded_with_silk)
      game.script('pull loom', log('1104:30752'), after: lambda { |_|
        $right_hand = 'silk thread'
        $hand_ids['silk thread'] = '1980000'
      })
      game.script('pull loom', nothing_to_pull)
    end

    it 'takes it into the crafting container and records it as a spool of the woven thread' do
      allow(DRCI).to receive(:put_away_item?).and_return(true)

      WeaveCloth.new

      expect(DRCI).to have_received(:put_away_item?).with('#1980000', 'duffel bag')
      expect(UserVars.spun_spools).to eq([{ 'id' => '1980000', 'fiber' => 'silk', 'weight' => 'heavy' }])
    end

    it 'takes it off before putting the cloth away, so a cloth that will not go in strands nothing' do
      allow(DRCI).to receive(:put_away_item?) { |ref, _bag| ref != '#1976604' }

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(DRCI).to have_received(:put_away_item?).with('#1980000', 'duffel bag').ordered
      expect(DRCI).to have_received(:put_away_item?).with('#1976604', 'duffel bag').ordered
      expect(UserVars.spun_spools).to eq([{ 'id' => '1980000', 'fiber' => 'silk', 'weight' => 'heavy' }])
    end

    it 'keeps the record to the newest 20 spools, as spin does' do
      UserVars.spun_spools = (1..20).map { |n| { 'id' => n.to_s, 'fiber' => 'linen', 'weight' => 'heavy' } } + silk_spools
      allow(DRCI).to receive(:put_away_item?).and_return(true)

      WeaveCloth.new

      expect(UserVars.spun_spools.size).to eq(20)
      expect(UserVars.spun_spools.last['id']).to eq('1980000')
    end

    it 'does not record it when the woven spools were given by id and not recorded' do
      UserVars.spun_spools = nil
      $parse_args_model = true
      $script_vars = ArgParserModel.script_vars('1963477 1958040')

      WeaveCloth.new

      expect(UserVars.spun_spools).to eq([])
    end
  end

  describe 'after the weave' do
    before do
      script_empty_loom_and_load
      script_weave
    end

    it 'takes two threads left on the loom, both into the crafting container and the record' do
      game.script('look on loom', ReplayGame.code('The loom is loaded with some heavy silk thread and some heavy silk thread.', from: 'weave-cloth.lic@c2739670:6'))
      game.script('pull loom', log('1104:30752'), after: lambda { |_|
        $right_hand = 'silk thread'
        $hand_ids['silk thread'] = '1980001'
      })
      game.script('pull loom', log('1104:30752'), after: ->(_) { $hand_ids['silk thread'] = '1980002' })
      allow(DRCI).to receive(:put_away_item?).and_return(true)

      WeaveCloth.new

      expect(UserVars.spun_spools.map { |spool| spool['id'] }).to eq(%w[1980001 1980002])
    end

    it 'still puts the cloth away when the look at the loom goes unanswered' do
      game.script('look on loom')
      allow(Lich::Messaging).to receive(:msg)
      expect(Lich::Messaging).to receive(:msg).with('plain', 'weave-cloth: Could not see whether thread is left on the loom.')
      expect(DRCI).to receive(:put_away_item?).with('#1976604', 'duffel bag').and_return(true)

      WeaveCloth.new
    end
  end

  describe 'round-2 review cases' do
    let(:loaded) { ReplayGame.code('The loom is loaded with some cotton thread and some heavy silk thread.', from: 'weave-cloth.lic@c2739670:6') }

    it "takes its own thread back even when someone else's came off the loom first" do
      UserVars.spun_spools = [{ 'id' => '1626499', 'fiber' => 'silk', 'weight' => 'heavy' }] + silk_spools
      game.script('look on loom', loaded)
      game.script('pull loom', log('1104:30752'), after: lambda { |_|
        $left_hand = 'cotton thread'
        $hand_ids['cotton thread'] = '1626431'
      })
      game.script('pull loom', log('1104:30752'), after: lambda { |_|
        $right_hand = 'silk thread'
        $hand_ids['silk thread'] = '1626499'
      })
      game.script('put #1626431 on loom', log('1104:30601'))
      allow(DRCI).to receive(:put_away_item?).and_return(true)

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(DRCI).to have_received(:put_away_item?).with('#1626499', 'duffel bag')
      expect(DRCI).not_to have_received(:put_away_item?).with('#1626431', anything)
    end

    it 'says how many spools are still out when putting them back fails' do
      game.script('look on loom', log('1104:30590'))
      game.script('put #1963477 on loom', log('1104:30803'))
      game.script('put #1958040 on loom', log('1104:30609'))
      game.script('pull loom', log('1104:30752'), after: lambda { |_|
        $left_hand = 'silk thread'
        $hand_ids['silk thread'] = '1963477'
      })
      allow(DRCI).to receive(:put_away_item?) { |ref, _| ref != '#1958040' }
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: The loom will not take spool #1958040 with the other: a simple loom weaves two threads of one material. 1 of 2 spools are still on the loom or in your hands.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(DRCI).to have_received(:put_away_item?).with('#1963477', 'duffel bag')
    end

    it 'stops before walking when the hands cannot be emptied' do
      allow(DRCI).to receive(:stow_hands).and_return(false)
      expect(DRCT).not_to receive(:find_empty_room)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Could not empty your hands.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
    end

    it 'uses a loom room shared only with group members' do
      allow(DRRoom).to receive(:pcs).and_return(['Ytterby'])
      allow(DRRoom).to receive(:group_members).and_return(['Ytterby'])
      script_empty_loom_and_load
      script_weave

      WeaveCloth.new

      expect(game.sent).to include('weave loom')
    end

    it 'takes a fiber with extra letters after it, as parse_args allows ("silks")' do
      $parse_args_model = true
      $script_vars = ArgParserModel.script_vars('silks')
      script_empty_loom_and_load
      script_weave

      WeaveCloth.new

      expect(game.sent.grep(/\Aput #\d+ on loom\z/)).to eq(['put #1963477 on loom', 'put #1958040 on loom'])
    end
  end

  # spin.lic writes the spool record and weave-cloth reads it; the two
  # scripts are separate files, so this pins them to one contract.
  describe 'the spool record shared with spin' do
    before { load_lic_class('spin.lic', 'Spin') }

    it 'uses the same UserVars key and cap as spin' do
      expect(WeaveCloth::SPOOL_RECORD).to eq(Spin::SPOOL_RECORD)
      expect(WeaveCloth::MAX_RECORDED_SPOOLS).to eq(Spin::MAX_RECORDED_SPOOLS)
    end

    it 'knows exactly the fibers spin spins' do
      expect(WeaveCloth::FIBERS).to eq(Spin::FIBERS.keys)
    end

    it 'pairs the spools spin records, newest first' do
      spin = Spin.allocate
      spin.instance_variable_set(:@fiber_name, 'silk')
      spin.instance_variable_set(:@weight, 'heavy')
      UserVars.spun_spools = nil
      spin.send(:record_spool, '1958040')
      spin.send(:record_spool, '1963477')

      expect(WeaveCloth.allocate.send(:recorded_pair)).to eq(%w[1963477 1958040])
    end
  end

  describe 'a pulled thread whose hand shows no id' do
    let(:loaded_with_cotton) { ReplayGame.code('The loom is loaded with some cotton thread.', from: 'weave-cloth.lic@c2739670:6') }

    it 'stops with the thread in hand rather than guess at it' do
      game.script('look on loom', loaded_with_cotton)
      game.script('pull loom', log('1104:30752'), after: ->(_) { $left_hand = 'cotton thread' })
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Pulled thread off the loom but cannot tell which; it is in your hand.')
      expect(DRCI).not_to receive(:put_away_item?)

      expect { WeaveCloth.new }.to raise_error(SystemExit)
    end

    it 'does not take a loom for empty when a pull answers but no thread shows in hand' do
      game.script('look on loom', loaded_with_cotton)
      game.script('pull loom', log('1104:30752'))
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Pulled thread off the loom but cannot tell which; it is in your hand.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent).not_to include('weave loom')
    end
  end

  describe 'stocking cloth (;weave-cloth silk 16)' do
    let(:got_cloth) { log('1104:30872') }
    let(:no_cloth) { log('1104:30604') }
    let(:combined) { log('1104:32641') }

    before do
      $parse_args_model = true
      $script_vars = ArgParserModel.script_vars('silk 16')
      UserVars.spun_spools = []
      new_spools = %w[1958040 1963477]
      allow(DRC).to receive(:wait_for_script_to_complete).with('spin', ['silk']) do
        UserVars.spun_spools = UserVars.spun_spools + [{ 'id' => new_spools.shift, 'fiber' => 'silk', 'weight' => 'heavy' }]
      end
      allow(DRCI).to receive(:put_away_item?) do
        $left_hand = nil
        $right_hand = nil
        true
      end
      allow(Lich::Messaging).to receive(:msg)
    end

    context 'with GameObj knowing the containers (the inventory feed answered)' do
      let(:pack) { OpenStruct.new(id: '1222003', noun: 'pack', name: "scuffed traveler's pack") }
      let(:duffel) { OpenStruct.new(id: '1222175', noun: 'bag', name: 'duffel bag') }

      # A carried item, as GameObj streams it into a container's contents.
      def carried(id, name, noun: 'cloth', inside: duffel)
        OpenStruct.new(id: id, noun: noun, name: name).tap { |item| ($containers[inside.id] ||= []) << item }
      end

      before do
        $worn_items = [duffel, pack]
        allow(Lich::Common::Inventory).to receive(:refresh).and_return(double('snapshot'))
      end

      it 'gets every carried piece of the heavy cloth by id, from any container, combines them, and puts the one piece in the crafting container' do
        carried('1976604', 'heavy silk cloth')
        carried('1999999', 'heavy silk cloth', inside: pack)
        allow(DRCI).to receive(:get_item?) do |ref|
          ref == '#1976604' ? $left_hand = 'silk cloth' : $right_hand = 'silk cloth'
          $hand_ids['silk cloth'] = '1976604'
          true
        end
        game.script('combine silk cloth with silk cloth', combined, after: ->(_) { $right_hand = nil })
        game.script('count my silk cloth', log('1104:30876'))

        WeaveCloth.new

        expect(DRCI).to have_received(:get_item?).with('#1976604').ordered
        expect(DRCI).to have_received(:get_item?).with('#1999999').ordered
        expect(DRCI).to have_received(:put_away_item?).with('#1976604', '#1222175')
        expect(SessionVars['weave_cloth_stock']).to eq('fiber' => 'silk', 'yards' => 16)
        expect(DRC).not_to have_received(:wait_for_script_to_complete)
      end

      it 'finds a piece inside a container inside a worn one' do
        pouch = carried('5', 'cloth pouch', noun: 'pouch', inside: pack)
        carried('1976604', 'heavy silk cloth', inside: pouch)
        allow(DRCI).to receive(:get_item?) do
          $left_hand = 'silk cloth'
          $hand_ids['silk cloth'] = '1976604'
          true
        end
        game.script('count my silk cloth', log('1104:30876'))

        WeaveCloth.new

        expect(DRCI).to have_received(:get_item?).with('#1976604')
      end

      it 'leaves out a chamois cloth, a worn cloth and cloth of another weight' do
        carried('1', 'chamois cloth')
        carried('4', 'fine silk cloth')
        $worn_items << OpenStruct.new(id: '2', noun: 'cloth', name: 'heavy silk cloth')
        allow(DRCI).to receive(:get_item?).and_return(true)
        allow(DRC).to receive(:wait_for_script_to_complete).with('spin', ['silk'])

        expect { WeaveCloth.new }.to raise_error(SystemExit)
        expect(DRCI).not_to have_received(:get_item?).with(/\A#[124]\z/)
        expect(SessionVars['weave_cloth_stock']).to eq('fiber' => 'silk', 'yards' => 0)
      end

      it 'does not fall back to names when GameObj knows there is no cloth' do
        allow(DRC).to receive(:wait_for_script_to_complete).with('spin', ['silk'])

        expect { WeaveCloth.new }.to raise_error(SystemExit)
        expect(game.sent).not_to include('get my silk cloth from my duffel bag')
      end

      it 'stops, saying where the cloth is, when a later piece cannot be got' do
        carried('1976604', 'heavy silk cloth')
        carried('1999999', 'heavy silk cloth')
        allow(DRCI).to receive(:get_item?) { |ref| ref == '#1976604' }
        expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Could not get the silk cloth #1999999; the rest is in your hand.')

        expect { WeaveCloth.new }.to raise_error(SystemExit)
      end
    end

    context 'without the inventory feed (Inventory.refresh answers nil)' do
      def cloth_comes_out(hand, id)
        game.script('get my silk cloth from my duffel bag', got_cloth, after: lambda { |_|
          hand == :left ? $left_hand = 'silk cloth' : $right_hand = 'silk cloth'
          $hand_ids['silk cloth'] = id
        })
      end

      it 'spins and weaves nothing when the crafting container already holds enough' do
        cloth_comes_out(:left, '1976604')
        game.script('get my silk cloth from my duffel bag', no_cloth)
        game.script('count my silk cloth', log('1104:30876'))

        WeaveCloth.new

        expect(DRC).not_to have_received(:wait_for_script_to_complete)
        expect(Lich::Messaging).to have_received(:msg).with('plain', 'weave-cloth: Your duffel bag holds 16 yards of heavy silk cloth.')
      end

      it 'spins two spools and weaves exactly those two, then counts the cloth it made' do
        game.script('get my silk cloth from my duffel bag', no_cloth)
        script_empty_loom_and_load(first: '1963477', second: '1958040')
        script_weave
        cloth_comes_out(:left, '1976604')
        game.script('get my silk cloth from my duffel bag', no_cloth)
        game.script('count my silk cloth', log('1104:30876'))

        WeaveCloth.new

        expect(DRC).to have_received(:wait_for_script_to_complete).with('spin', ['silk']).twice
        expect(game.sent.grep(/\Aput #\d+ on loom\z/)).to eq(['put #1963477 on loom', 'put #1958040 on loom'])
        expect(SessionVars['weave_cloth_stock']).to eq('fiber' => 'silk', 'yards' => 16)
      end

      it 'weaves only the spools spin just made, never older recorded ones' do
        UserVars.spun_spools = [{ 'id' => '1900000', 'fiber' => 'silk', 'weight' => 'heavy' }]
        game.script('get my silk cloth from my duffel bag', no_cloth)
        script_empty_loom_and_load(first: '1963477', second: '1958040')
        script_weave
        cloth_comes_out(:left, '1976604')
        game.script('get my silk cloth from my duffel bag', no_cloth)
        game.script('count my silk cloth', log('1104:30876'))
        allow(DRCI).to receive(:get_item?).and_return(true)

        WeaveCloth.new

        expect(DRCI).not_to have_received(:get_item?).with('#1900000')
      end

      it 'weaves two heavy spools a stopped run left recorded before spinning more (review on #7950)' do
        UserVars.spun_spools = [{ 'id' => '1900000', 'fiber' => 'linen', 'weight' => 'heavy' }] + silk_spools
        game.script('get my silk cloth from my duffel bag', no_cloth)
        script_empty_loom_and_load(first: '1963477', second: '1958040')
        script_weave
        cloth_comes_out(:left, '1976604')
        game.script('get my silk cloth from my duffel bag', no_cloth)
        game.script('count my silk cloth', log('1104:30876'))

        WeaveCloth.new

        expect(DRC).not_to have_received(:wait_for_script_to_complete)
        expect(game.sent.grep(/\Aput #\d+ on loom\z/)).to eq(['put #1963477 on loom', 'put #1958040 on loom'])
      end

      it 'forgets a recorded pair that is no longer on hand and spins a new one, instead of stopping every run (re-review on #7950)' do
        UserVars.spun_spools = [{ 'id' => '111', 'fiber' => 'silk', 'weight' => 'heavy' }, { 'id' => '222', 'fiber' => 'silk', 'weight' => 'heavy' }]
        allow(DRCI).to receive(:get_item?) { |ref| !%w[#111 #222].include?(ref) }
        game.script('get my silk cloth from my duffel bag', no_cloth)
        game.script('look on loom', log('1104:30590'))
        script_empty_loom_and_load(first: '1963477', second: '1958040')
        script_weave
        cloth_comes_out(:left, '1976604')
        game.script('get my silk cloth from my duffel bag', no_cloth)
        game.script('count my silk cloth', log('1104:30876'))
        expect(Lich::Messaging).to receive(:msg).with('plain', 'weave-cloth: Recorded spools #222, #111 are not on hand; forgot them and spinning a new pair.')

        WeaveCloth.new

        expect(DRC).to have_received(:wait_for_script_to_complete).with('spin', ['silk']).twice
        expect(game.sent.grep(/\Aput #\d+ on loom\z/)).to eq(['put #1963477 on loom', 'put #1958040 on loom'])
        expect(UserVars.spun_spools.map { |spool| spool['id'] }).not_to include('111', '222')
      end

      it 'spins for the batch when only one heavy spool of the fiber is recorded' do
        UserVars.spun_spools = [silk_spools.first, { 'id' => '1963477', 'fiber' => 'silk', 'weight' => 'thin' }]
        allow(DRC).to receive(:wait_for_script_to_complete).with('spin', ['silk'])
        game.script('get my silk cloth from my duffel bag', no_cloth)

        expect { WeaveCloth.new }.to raise_error(SystemExit)
        expect(DRC).to have_received(:wait_for_script_to_complete).with('spin', ['silk']).once
      end

      it 'does not start the second spin when the first made no spool' do
        allow(DRC).to receive(:wait_for_script_to_complete).with('spin', ['silk'])
        game.script('get my silk cloth from my duffel bag', no_cloth)
        expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: spin made 0 of 2 silk spools; stopping.')

        expect { WeaveCloth.new }.to raise_error(SystemExit)
        expect(DRC).to have_received(:wait_for_script_to_complete).once
      end

      it 'stops before weaving when the second spin makes no spool' do
        allow(DRC).to receive(:wait_for_script_to_complete).with('spin', ['silk']) do
          UserVars.spun_spools = [{ 'id' => '1958040', 'fiber' => 'silk', 'weight' => 'heavy' }] if UserVars.spun_spools.empty?
        end
        game.script('get my silk cloth from my duffel bag', no_cloth)
        expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: spin made 1 of 2 silk spools; stopping.')
        expect(DRCT).not_to receive(:find_empty_room)

        expect { WeaveCloth.new }.to raise_error(SystemExit)
      end

      it 'does not count a spool of another fiber recorded meanwhile' do
        allow(DRC).to receive(:wait_for_script_to_complete).with('spin', ['silk']) do
          UserVars.spun_spools = UserVars.spun_spools + [{ 'id' => '1', 'fiber' => 'linen', 'weight' => 'heavy' }]
        end
        game.script('get my silk cloth from my duffel bag', no_cloth)

        expect { WeaveCloth.new }.to raise_error(SystemExit)
        expect(DRC).to have_received(:wait_for_script_to_complete).once
      end

      it 'stops before buying more fiber when a batch adds no cloth, leaving the count for the caller' do
        $script_vars = ArgParserModel.script_vars('silk 40')
        game.script('get my silk cloth from my duffel bag', no_cloth)
        script_empty_loom_and_load(first: '1963477', second: '1958040')
        script_weave
        game.script('get my silk cloth from my duffel bag', no_cloth)
        expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Weaving added no silk cloth (0 yards on hand); stopping before buying more fiber.')

        expect { WeaveCloth.new }.to raise_error(SystemExit)
        expect(DRC).to have_received(:wait_for_script_to_complete).twice
        expect(SessionVars['weave_cloth_stock']).to eq('fiber' => 'silk', 'yards' => 0)
      end

      it 'combines two pieces with the command the game answers (1104:32641)' do
        cloth_comes_out(:left, '1976604')
        cloth_comes_out(:right, '1976605')
        game.script('combine silk cloth with silk cloth', combined, after: ->(_) { $right_hand = nil })
        game.script('get my silk cloth from my duffel bag', no_cloth)
        game.script('count my silk cloth', log('1104:30876'))

        WeaveCloth.new

        expect(game.sent.count('combine silk cloth with silk cloth')).to eq(1)
      end

      it 'stops, the pieces in hand, when two pieces will not combine' do
        cloth_comes_out(:left, '1976604')
        cloth_comes_out(:right, '1976605')
        game.script('combine silk cloth with silk cloth')
        expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Could not combine two pieces of silk cloth; they are in your hands.')

        expect { WeaveCloth.new }.to raise_error(SystemExit)
      end

      it 'stops when the cloth will not count' do
        cloth_comes_out(:left, '1976604')
        game.script('get my silk cloth from my duffel bag', no_cloth)
        game.script('count my silk cloth')
        expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Could not count the silk cloth; it is in your hand.')

        expect { WeaveCloth.new }.to raise_error(SystemExit)
      end
    end

    it 'stops before touching anything when the hands cannot be emptied' do
      allow(DRCI).to receive(:stow_hands).and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Could not empty your hands.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent).to be_empty
    end

    it 'refuses more than 1000 yards, more likely a spool id typed after the fiber' do
      $script_vars = ArgParserModel.script_vars('silk 1958040')
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: Ask for 1000 yards or fewer.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(DRCI).not_to have_received(:put_away_item?)
    end

    it "clears an earlier run's count when it starts" do
      SessionVars['weave_cloth_stock'] = { 'fiber' => 'silk', 'yards' => 99 }
      allow(DRCI).to receive(:stow_hands).and_return(false)

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(SessionVars['weave_cloth_stock']).to be_nil
    end
  end

  describe 'naming the crafting container' do
    before do
      script_empty_loom_and_load
      script_weave
    end

    it 'puts the cloth in the worn crafting container by its id, so a duffel bag being sewn cannot catch it' do
      $worn_items = [OpenStruct.new(name: 'duffel bag', noun: 'bag', id: '1222175')]
      expect(DRCI).to receive(:put_away_item?).with('#1976604', '#1222175').and_return(true)

      WeaveCloth.new
    end

    it 'names the container when it is not worn' do
      expect(DRCI).to receive(:put_away_item?).with('#1976604', 'duffel bag').and_return(true)

      WeaveCloth.new
    end

    it 'names the container when GameObj has not streamed the worn items yet (GameObj.inv is nil)' do
      $worn_items = nil
      expect(DRCI).to receive(:put_away_item?).with('#1976604', 'duffel bag').and_return(true)

      WeaveCloth.new
    end
  end

  # Every loom reply in Mahtra's four heavy silk weaves on 2026-11-04.
  describe 'the loom replies seen in game' do
    {
      '1104:30821' => 'turn loom',  # "Several weft threads bunch together..."
      '1104:30833' => 'clean loom', # "...dust and debris obstructing the pirn of the shuttle."
      '1104:30851' => 'push loom',  # "The cloth threads begin to unravel along the fell and need pushing together."
      '1104:33219' => 'push loom'   # "One side of the partially-woven cloth is uneven, and needs pushing together."
    }.each do |cite, fix|
      it "answers #{cite} with #{fix}" do
        line = log(cite).text
        expect(WeaveCloth::LOOM_FIXES.find { |problem, _| problem.match?(line) }&.last).to eq(fix)
      end
    end

    %w[1104:30817 1104:30832 1104:30844 1104:30847 1104:32031 1104:32605 1104:32027 1104:32038 1104:30840 1104:30858].each do |cite|
      it "takes the ordinary loom line #{cite} for no problem" do
        expect(WeaveCloth::LOOM_FIXES.keys.none? { |problem| problem.match?(log(cite).text) }).to be(true)
      end
    end

    it 'fixes a problem that arrives in the reply to a fix, then finishes (1104:32037-32044)' do
      script_empty_loom_and_load
      game.script('weave loom', log('1104:30832'), log('1104:30833'), log('1104:30834'))
      game.script('clean loom', log('1104:32038'), log('1104:32039'), log('1104:32040'))
      game.script('push loom', log('1104:32042'), log('1104:32043'), log('1104:32044'),
                  after: lambda { |_|
                    $left_hand = 'silk cloth'
                    $hand_ids['silk cloth'] = '1976604'
                  })
      game.fallback('look on loom', log('1104:30590'))

      WeaveCloth.new

      expect(game.sent.drop_while { |command| command != 'weave loom' }.take(3)).to eq(['weave loom', 'clean loom', 'push loom'])
    end
  end

  # Ids last only for a session: after a login every item has a new one.
  describe 'finding the spools by name after a login' do
    let(:duffel) { OpenStruct.new(id: '2135261', noun: 'bag', name: 'duffel bag') }

    def carried(id, name)
      OpenStruct.new(id: id, noun: 'thread', name: name).tap { |item| ($containers[duffel.id] ||= []) << item }
    end

    before do
      $worn_items = [duffel]
      allow(Lich::Common::Inventory).to receive(:refresh).and_return(double('snapshot'))
    end

    it 'weaves the carried spools under their new ids, dropping the ids recorded before the login' do
      carried('2200001', 'heavy silk thread')
      carried('2200002', 'heavy silk thread')
      script_empty_loom_and_load(first: '2200002', second: '2200001')
      script_weave

      WeaveCloth.new

      expect(game.sent.grep(/\Aput #\d+ on loom\z/)).to eq(['put #2200002 on loom', 'put #2200001 on loom'])
      expect(UserVars.spun_spools).to eq([])
    end

    it 'never takes the cotton sewing thread for a spool' do
      carried('2172610', 'cotton thread')
      carried('2200001', 'heavy silk thread')
      expect(Lich::Messaging).to receive(:msg).with('bold', "weave-cloth: #{WeaveCloth::NEED_TWO_SPOOLS}")

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(UserVars.spun_spools.map { |spool| spool['id'] }).to eq(['2200001'])
    end

    it 'keeps recorded spools still carried as the newest, and adds the others as older' do
      UserVars.spun_spools = [{ 'id' => '2200009', 'fiber' => 'silk', 'weight' => 'heavy' }]
      carried('2200001', 'heavy silk thread')
      carried('2200009', 'heavy silk thread')
      script_empty_loom_and_load(first: '2200009', second: '2200001')
      script_weave

      WeaveCloth.new

      expect(game.sent.grep(/\Aput #\d+ on loom\z/)).to eq(['put #2200009 on loom', 'put #2200001 on loom'])
    end

    it 'asks for the fiber when it carries unrecorded spools of several kinds' do
      UserVars.spun_spools = nil
      carried('1', 'heavy silk thread')
      carried('2', 'heavy silk thread')
      carried('3', 'heavy linen thread')
      carried('4', 'heavy linen thread')
      expect(Lich::Messaging).to receive(:msg).with('bold', 'weave-cloth: You carry spools of several kinds (heavy silk, heavy linen); name the fiber, e.g. ;weave-cloth silk.')

      expect { WeaveCloth.new }.to raise_error(SystemExit)
      expect(game.sent).to be_empty
    end

    it 'weaves the named fiber among several kinds' do
      UserVars.spun_spools = nil
      $parse_args_model = true
      $script_vars = ArgParserModel.script_vars('linen')
      carried('1', 'heavy silk thread')
      carried('3', 'heavy linen thread')
      carried('4', 'heavy linen thread')
      script_empty_loom_and_load(first: '4', second: '3')
      script_weave

      WeaveCloth.new

      expect(game.sent.grep(/\Aput #\d+ on loom\z/)).to eq(['put #4 on loom', 'put #3 on loom'])
    end

    it 'keeps the record as it is when the inventory feed does not answer' do
      allow(Lich::Common::Inventory).to receive(:refresh).and_return(nil)
      script_empty_loom_and_load
      script_weave

      WeaveCloth.new

      expect(game.sent.grep(/\Aput #\d+ on loom\z/)).to eq(['put #1963477 on loom', 'put #1958040 on loom'])
    end
  end
end
