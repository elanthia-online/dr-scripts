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
    # The cloth is in hand once the reply has arrived (XML: <left exist=...
    # noun="cloth">silk cloth</left> with the snip line).
    game.script('push loom', log('1104:30858'), log('1104:30859'), log('1104:30860'),
                after: ->(_) { $left_hand = 'silk cloth' })
    game.script('stow my cloth', log('1104:30870'))
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
      expect(DRCI).to receive(:put_away_item?).with('#1626431', 'duffel bag').and_return(true)

      WeaveCloth.new
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
end
