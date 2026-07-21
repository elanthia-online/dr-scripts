require_relative 'spec_helper'

# Droughtmans#initialize depends on the full Lich runtime (parse_args,
# get_settings, walking into the maze, the infinite main_loop), so we extract the
# class with load_lic_class and exercise individual methods on bare-allocated
# instances (Droughtmans.allocate) with state injected via instance_variable_set.
#
# The focus is the deterministic navigation logic and the safety branches the
# fork historically got wrong (the wave -> exit footgun, rope-trap routing, the
# release-invisibility grab, and the non-fatal pass redemption). Every example is
# self-contained and reads top-to-bottom (DAMP).
load_lic_class('droughtmans.lic', 'Droughtmans')

RSpec.describe Droughtmans do
  let(:bot) { Droughtmans.allocate }

  # ===========================================================================
  # Compass direction tables (pure constants -- catch a single typo'd entry)
  # ===========================================================================
  describe 'direction tables' do
    it 'reverses every direction back to itself (involution)' do
      Droughtmans::REVERSE_DIRECTION_MAP.each do |dir, reversed|
        expect(Droughtmans::REVERSE_DIRECTION_MAP[reversed]).to eq(dir)
      end
    end

    it 'covers all eight compass points in every rotation table' do
      eight = %w[n ne e se s sw w nw].sort
      expect(Droughtmans::REVERSE_DIRECTION_MAP.keys.sort).to eq(eight)
      expect(Droughtmans::CLOCKWISE_MAP.keys.sort).to eq(eight)
      expect(Droughtmans::COUNTER_CLOCKWISE_MAP.keys.sort).to eq(eight)
    end

    it 'makes clockwise and counter-clockwise exact inverses of each other' do
      Droughtmans::CLOCKWISE_MAP.each do |dir, cw|
        expect(Droughtmans::COUNTER_CLOCKWISE_MAP[cw]).to eq(dir)
      end
    end

    it 'only ever rotates to a real compass point (values are a full permutation)' do
      eight = %w[n ne e se s sw w nw].sort
      expect(Droughtmans::CLOCKWISE_MAP.values.sort).to eq(eight)
      expect(Droughtmans::COUNTER_CLOCKWISE_MAP.values.sort).to eq(eight)
    end
  end

  # ===========================================================================
  # get_next_move: wall-following selection with a defensive fallback
  # ===========================================================================
  describe '#get_next_move' do
    before { bot.instance_variable_set(:@current_direction_map, Droughtmans::CLOCKWISE_MAP) }

    it 'turns toward the first reachable wall-follow direction' do
      # last_dir 'n' -> reverse 's' -> clockwise 'sw'; 'sw' is available, so take it.
      expect(bot.get_next_move('n', %w[sw w])).to eq('sw')
    end

    it 'keeps rotating clockwise until it finds an available exit' do
      # From 'sw' it rotates sw -> w -> nw -> n; only 'n' is open here.
      expect(bot.get_next_move('n', %w[n])).to eq('n')
    end

    it 'honors the counter-clockwise table when that hand is selected' do
      bot.instance_variable_set(:@current_direction_map, Droughtmans::COUNTER_CLOCKWISE_MAP)
      # last_dir 'n' -> reverse 's' -> counter-clockwise 'se'.
      expect(bot.get_next_move('n', %w[se e])).to eq('se')
    end

    it 'falls back to n rather than looping forever when nothing is reachable' do
      expect(bot.get_next_move('n', [])).to eq('n')
    end
  end

  # ===========================================================================
  # detect_loop?: recognizing a walked square
  # ===========================================================================
  describe '#detect_loop?' do
    it 'is true for a known four-move loop square' do
      bot.instance_variable_set(:@move_history_short, %w[e s w n])
      expect(bot.detect_loop?).to be(true)
    end

    it 'is false with fewer than four moves recorded (boundary)' do
      bot.instance_variable_set(:@move_history_short, %w[e s w])
      expect(bot.detect_loop?).to be(false)
    end

    it 'is false for a near-miss that is not an actual loop' do
      bot.instance_variable_set(:@move_history_short, %w[e s w s])
      expect(bot.detect_loop?).to be(false)
    end

    it 'considers only the four most recent moves when history is longer' do
      bot.instance_variable_set(:@move_history_short, %w[e s w n ne nw])
      expect(bot.detect_loop?).to be(true)
    end
  end

  # ===========================================================================
  # record_move_history: dual histories + loop arming
  # ===========================================================================
  describe '#record_move_history' do
    before do
      bot.instance_variable_set(:@backtrack_to_white_door, false)
      bot.instance_variable_set(:@reverse_dir, false)
      bot.instance_variable_set(:@next_move, 'pending')
      bot.instance_variable_set(:@move_history_since_init, [])
    end

    it 'records a fresh move onto both histories and clears the pending move' do
      bot.instance_variable_set(:@move_history_short, [])
      bot.record_move_history('e')

      expect(bot.instance_variable_get(:@move_history_short)).to eq(%w[e])
      expect(bot.instance_variable_get(:@move_history_since_init)).to eq(%w[e])
      expect(bot.instance_variable_get(:@last_successful_move)).to eq('e')
      expect(bot.instance_variable_get(:@next_move)).to eq('')
    end

    it 'caps the short history at four, dropping the oldest move' do
      bot.instance_variable_set(:@move_history_short, %w[a b c d])
      bot.record_move_history('e')

      expect(bot.instance_variable_get(:@move_history_short)).to eq(%w[e a b c])
    end

    it 'arms reverse mode when capping produces a loop square' do
      # Four already recorded, so the >3 branch runs: pop x, push e -> [e s w n].
      bot.instance_variable_set(:@move_history_short, %w[s w n x])
      bot.record_move_history('e')

      expect(bot.instance_variable_get(:@move_history_short)).to eq(%w[e s w n])
      expect(bot.instance_variable_get(:@reverse_dir)).to be(true)
    end

    it 'does NOT arm reverse when the loop only appears at exactly four moves' do
      # count is 3 at entry, so the else branch runs and detect_loop? is skipped,
      # even though the result [e s w n] is a loop square.
      bot.instance_variable_set(:@move_history_short, %w[s w n])
      bot.record_move_history('e')

      expect(bot.instance_variable_get(:@move_history_short)).to eq(%w[e s w n])
      expect(bot.instance_variable_get(:@reverse_dir)).to be(false)
    end

    it 'skips the backtrack history while backtracking to the white door' do
      bot.instance_variable_set(:@move_history_short, [])
      bot.instance_variable_set(:@move_history_since_init, %w[old])
      bot.instance_variable_set(:@backtrack_to_white_door, true)
      bot.record_move_history('e')

      expect(bot.instance_variable_get(:@move_history_since_init)).to eq(%w[old])
    end
  end

  # ===========================================================================
  # parse_exits: long-direction text -> short directions
  # ===========================================================================
  describe '#parse_exits' do
    it 'maps a comma-separated exit list to short directions' do
      expect(bot.parse_exits('north, southeast, out')).to eq(%w[n se out])
    end

    it 'handles a single exit' do
      expect(bot.parse_exits('west')).to eq(%w[w])
    end

    it 'yields nil for an unknown direction token (documents the SHORTDIR gap)' do
      expect(bot.parse_exits('north, sideways')).to eq(['n', nil])
    end
  end

  # ===========================================================================
  # wave: the stale-target footgun and the drop-key branch
  # ===========================================================================
  describe '#wave' do
    it 'does not kill the script when the target is not actually present' do
      DRRoom.npcs = %w[goblin]
      allow(DRC).to receive(:bput).and_return('I could not find')

      expect { bot.wave('second goblin') }.not_to raise_error
    end

    it 'treats "Wave at what?" as a skip, never an exit' do
      DRRoom.npcs = %w[goblin]
      allow(DRC).to receive(:bput).and_return('Wave at what?')

      expect { bot.wave('goblin') }.not_to raise_error
    end

    it 'exits only when the wand itself is gone (command not understood)' do
      allow(DRC).to receive(:bput).and_return('I do not understand')

      expect { bot.wave('goblin') }.to raise_error(SystemExit)
    end

    it 'clears the nemesis when a wave makes the holder drop the golden key' do
      bot.instance_variable_set(:@nemesis, 'Bandit')
      DRRoom.room_objs = [] # nothing to actually pick up
      allow(DRC).to receive(:bput).and_return('drops his golden key')

      bot.wave('Bandit')

      expect(bot.instance_variable_get(:@nemesis)).to be_nil
    end

    it 'removes a successfully frozen npc from the room list' do
      DRRoom.npcs = %w[goblin troll]
      allow(DRC).to receive(:bput).and_return('Roundtime: 3 sec.')

      bot.wave('goblin')

      expect(DRRoom.npcs).to eq(%w[troll])
    end
  end

  # ===========================================================================
  # get_key: release invisibility before grabbing, and guard clauses
  # ===========================================================================
  describe '#get_key' do
    it 'does nothing (and does not release invisibility) when already held' do
      allow(DRCI).to receive(:in_hands?).with('golden key').and_return(true)
      expect(DRC).not_to receive(:release_invisibility)
      expect(DRCI).not_to receive(:get_item_unsafe)

      bot.get_key
    end

    it 'does nothing when the key is not in the room' do
      allow(DRCI).to receive(:in_hands?).with('golden key').and_return(false)
      DRRoom.room_objs = []
      expect(DRCI).not_to receive(:get_item_unsafe)

      bot.get_key
    end

    it 'releases invisibility before grabbing a key that is on the floor' do
      allow(DRCI).to receive(:in_hands?).with('golden key').and_return(false)
      DRRoom.room_objs = ['golden key']
      expect(DRC).to receive(:release_invisibility)
      expect(DRCI).to receive(:get_item_unsafe).with('golden key')

      bot.get_key
    end
  end

  # ===========================================================================
  # zap_nemesis: boundary conditions around nil and friendly nemeses
  # ===========================================================================
  describe '#zap_nemesis' do
    it 'is a no-op when there is no nemesis' do
      bot.instance_variable_set(:@nemesis, nil)
      bot.instance_variable_set(:@friends, [])
      expect(bot).not_to receive(:wave)

      bot.zap_nemesis
    end

    it 'never waves at a nemesis who is on the friends list' do
      bot.instance_variable_set(:@nemesis, 'Bob')
      bot.instance_variable_set(:@friends, %w[Bob])
      expect(bot).not_to receive(:wave)
      expect(bot).not_to receive(:get_key)

      bot.zap_nemesis
    end

    it 'waves at a non-friend nemesis who is present without the key' do
      bot.instance_variable_set(:@nemesis, 'Bob')
      bot.instance_variable_set(:@friends, %w[Alice])
      allow(bot).to receive(:get_key)
      allow(bot).to receive(:have_key?).and_return(false)
      DRRoom.pcs = %w[Bob]
      expect(bot).to receive(:wave).with('Bob')

      bot.zap_nemesis
    end
  end

  # ===========================================================================
  # check_key_holders: must not skip a PC while pruning the live room list
  # ===========================================================================
  describe '#check_key_holders' do
    it 'checks every player even as each is removed from the live pcs list' do
      DRRoom.pcs = %w[Alice Bob]
      bot.instance_variable_set(:@nemesis, nil)
      allow(DRC).to receive(:bput).and_return('He is holding a golden key and a wand')
      allow(bot).to receive(:wave)

      bot.check_key_holders

      # Iterating the live array while deleting would skip Bob after Alice.
      expect(bot).to have_received(:wave).with('Alice')
      expect(bot).to have_received(:wave).with('Bob')
      expect(DRRoom.pcs).to be_empty
    end
  end

  # ===========================================================================
  # pull_rope: restored trap routing (and the injury short-circuit)
  # ===========================================================================
  describe '#pull_rope' do
    before do
      bot.instance_variable_set(:@norope, false)
      bot.instance_variable_set(:@nemesis, nil)
      DRRoom.room_objs = ['rope']
    end

    it 'does not pull at all while injured' do
      bot.instance_variable_set(:@norope, true)
      expect(DRC).not_to receive(:bput)

      bot.pull_rope('rope')
    end

    it 'tends wounds when the rope springs the crossbow trap' do
      allow(DRC).to receive(:bput).and_return('With the grinding sound of stone moving against stone an opening appears in the wall next to you')
      expect(DRC).to receive(:wait_for_script_to_complete).with('tendme')

      bot.pull_rope('rope')
    end

    it 're-dowses after a tarzan-rope maze reset' do
      allow(DRC).to receive(:bput).and_return('A gentle breeze begins to blow through the area')
      expect(bot).to receive(:search_wand)

      bot.pull_rope('rope')
    end

    it 'grabs the key and clears the nemesis when the rope drops it' do
      bot.instance_variable_set(:@nemesis, 'Bob')
      allow(DRC).to receive(:bput).and_return('A golden key falls to the floor with a loud CLANK')
      allow(bot).to receive(:get_key)

      bot.pull_rope('rope')

      expect(bot).to have_received(:get_key)
      expect(bot.instance_variable_get(:@nemesis)).to be_nil
    end

    it 'forgets the rope after pulling so it is not re-pulled this tick' do
      allow(DRC).to receive(:bput).and_return('A loud CLICK echoes from above')

      bot.pull_rope('rope')

      expect(DRRoom.room_objs).not_to include('rope')
    end
  end

  # ===========================================================================
  # redeem_pass_if_present: non-fatal when no pass (regression vs the old exit)
  # ===========================================================================
  describe '#redeem_pass_if_present' do
    it 'does nothing and never exits when no pass is carried' do
      allow(DRCI).to receive(:get_item?).with('pass').and_return(false)
      expect(DRC).not_to receive(:bput)

      expect { bot.redeem_pass_if_present }.not_to raise_error
    end

    it 'redeems the pass twice when one is carried' do
      allow(DRCI).to receive(:get_item?).with('pass').and_return(true)
      allow(DRCI).to receive(:in_hands?).with('pass').and_return(false)
      expect(DRC).to receive(:bput).with('redeem my pass', anything, anything).twice

      bot.redeem_pass_if_present
    end
  end

  # ===========================================================================
  # change_direction_map: toggling the wall-follow hand
  # ===========================================================================
  describe '#change_direction_map' do
    it 'flips clockwise to counter-clockwise' do
      bot.instance_variable_set(:@current_direction_map, Droughtmans::CLOCKWISE_MAP)
      bot.change_direction_map
      expect(bot.instance_variable_get(:@current_direction_map)).to be(Droughtmans::COUNTER_CLOCKWISE_MAP)
    end

    it 'flips counter-clockwise back to clockwise' do
      bot.instance_variable_set(:@current_direction_map, Droughtmans::COUNTER_CLOCKWISE_MAP)
      bot.change_direction_map
      expect(bot.instance_variable_get(:@current_direction_map)).to be(Droughtmans::CLOCKWISE_MAP)
    end
  end
end
