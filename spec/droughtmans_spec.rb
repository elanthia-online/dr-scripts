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

  # ===========================================================================
  # dispose_empty_package: never trash a package that still holds loot
  # ===========================================================================
  describe '#dispose_empty_package' do
    before do
      bot.instance_variable_set(:@worn_trashcan, 'backpack')
      bot.instance_variable_set(:@worn_trashcan_verb, 'stuff')
      bot.instance_variable_set(:@loot_container, 'canvas sack')
    end

    it 'trashes the wrapper only once the loot transfer has emptied it' do
      allow(DRCI).to receive(:get_item_list).with('package', 'look').and_return([])
      allow(DRCI).to receive(:put_away_item?)
      expect(DRCI).to receive(:dispose_trash).with('package', 'backpack', 'stuff')

      bot.dispose_empty_package

      expect(DRCI).not_to have_received(:put_away_item?)
    end

    it 'keeps a package that still holds loot instead of trashing it' do
      allow(DRCI).to receive(:get_item_list).with('package', 'look').and_return(['leaves'])
      allow(DRCI).to receive(:in_hands?).with('package').and_return(false)
      allow(DRCI).to receive(:dispose_trash)
      allow(DRCI).to receive(:put_away_item?)
      expect(DRC).to receive(:message).with(/still holds loot/)

      bot.dispose_empty_package

      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'does not re-stow a kept package that has already been put away' do
      allow(DRCI).to receive(:get_item_list).with('package', 'look').and_return(['leaves'])
      allow(DRCI).to receive(:in_hands?).with('package').and_return(false)
      allow(DRCI).to receive(:dispose_trash)
      allow(DRC).to receive(:message)
      expect(DRCI).not_to receive(:put_away_item?)

      bot.dispose_empty_package
    end

    it 'stows a kept package that is still in hand' do
      allow(DRCI).to receive(:get_item_list).with('package', 'look').and_return(['leaves'])
      allow(DRCI).to receive(:in_hands?).with('package').and_return(true)
      allow(DRCI).to receive(:dispose_trash)
      allow(DRC).to receive(:message)
      expect(DRCI).to receive(:put_away_item?).with('package')

      bot.dispose_empty_package
    end

    it 'never trashes a package whose contents could not be read (nil)' do
      allow(DRCI).to receive(:get_item_list).with('package', 'look').and_return(nil)
      allow(DRCI).to receive(:put_away_item?)
      expect(DRCI).not_to receive(:dispose_trash)

      bot.dispose_empty_package
    end
  end

  # ===========================================================================
  # fetch_loot_container_if_needed: only chase the dwarf's sack for the default
  # ===========================================================================
  describe '#fetch_loot_container_if_needed' do
    it 'asks the compound dwarf for a canvas sack when using the default container' do
      bot.instance_variable_set(:@loot_container, 'canvas sack')
      expect(bot).to receive(:get_sack)

      bot.fetch_loot_container_if_needed
    end

    it 'does not fetch a sack when a custom loot container is configured' do
      bot.instance_variable_set(:@loot_container, 'worn backpack')
      expect(bot).not_to receive(:get_sack)

      bot.fetch_loot_container_if_needed
    end
  end

  # ===========================================================================
  # parse_configuration: the configurable loot destination and step pacing
  # ===========================================================================
  describe '#parse_configuration (loot container)' do
    before { allow(UserVars).to receive(:droughtmans_debug).and_return(nil) }

    it 'defaults the loot container to a canvas sack when unset' do
      $test_settings = OpenStruct.new
      bot.parse_configuration
      expect(bot.instance_variable_get(:@loot_container)).to eq('canvas sack')
    end

    it 'honors a configured droughtmans_loot_container override' do
      $test_settings = OpenStruct.new(droughtmans_loot_container: 'worn backpack')
      bot.parse_configuration
      expect(bot.instance_variable_get(:@loot_container)).to eq('worn backpack')
    end
  end

  describe '#parse_configuration (step delay)' do
    before { allow(UserVars).to receive(:droughtmans_debug).and_return(nil) }

    it 'defaults the step delay to 0 (unthrottled) when unset' do
      $test_settings = OpenStruct.new
      bot.parse_configuration
      expect(bot.instance_variable_get(:@step_delay)).to eq(0.0)
    end

    it 'coerces a configured droughtmans_step_delay to a float' do
      $test_settings = OpenStruct.new(droughtmans_step_delay: 2)
      bot.parse_configuration
      expect(bot.instance_variable_get(:@step_delay)).to eq(2.0)
    end

    it 'accepts a fractional step delay' do
      $test_settings = OpenStruct.new(droughtmans_step_delay: 0.5)
      bot.parse_configuration
      expect(bot.instance_variable_get(:@step_delay)).to eq(0.5)
    end
  end

  # ===========================================================================
  # throttle_movement: opt-in pacing so the solver stops falling every few rooms
  # ===========================================================================
  describe '#throttle_movement' do
    it 'pauses for the configured delay when one is set' do
      bot.instance_variable_set(:@step_delay, 1.5)
      expect(bot).to receive(:pause).with(1.5)

      bot.throttle_movement
    end

    it 'does not pause at all when the delay is zero (default)' do
      bot.instance_variable_set(:@step_delay, 0.0)
      expect(bot).not_to receive(:pause)

      bot.throttle_movement
    end

    it 'does not pause on a negative (misconfigured) delay' do
      bot.instance_variable_set(:@step_delay, -1.0)
      expect(bot).not_to receive(:pause)

      bot.throttle_movement
    end
  end

  # ===========================================================================
  # do_move: pacing is applied end-to-end only on a genuinely successful step
  # ===========================================================================
  describe '#do_move pacing' do
    before do
      bot.instance_variable_set(:@wandercounter, 0)
      bot.instance_variable_set(:@move_history_short, [])
      bot.instance_variable_set(:@move_history_since_init, [])
      bot.instance_variable_set(:@backtrack_to_white_door, false)
      bot.instance_variable_set(:@reverse_dir, false)
      bot.instance_variable_set(:@next_move, '')
      bot.instance_variable_set(:@nemesis, nil)
      bot.instance_variable_set(:@step_delay, 2.0)
      DRRoom.room_objs = []
      DRRoom.npcs = []
      allow(DRCI).to receive(:in_hands?).and_return(false)
    end

    it 'paces a successful step by the configured delay' do
      allow(DRC).to receive(:bput).and_return('Obvious paths: north, south.')
      expect(bot).to receive(:pause).with(2.0)

      bot.do_move('n')
    end

    it 'does not pace a failed step (no matching move response)' do
      allow(DRC).to receive(:bput).and_return('You slam into a wall.')
      expect(bot).not_to receive(:pause)

      bot.do_move('n')
    end
  end

  # ===========================================================================
  # relight_room / handle_dark_room: shared wand-relight behavior
  # ===========================================================================
  describe '#relight_room' do
    it 'shakes the wand for light' do
      expect(bot).to receive(:fput).with('shake wand')

      bot.relight_room
    end
  end

  describe '#handle_dark_room' do
    it 'relights the room when the dark-room flag is set' do
      allow(Flags).to receive(:[]).with('dark-room').and_return(true)
      expect(bot).to receive(:relight_room)

      bot.handle_dark_room
    end

    it 'does nothing when the room is not dark' do
      allow(Flags).to receive(:[]).with('dark-room').and_return(nil)
      expect(bot).not_to receive(:relight_room)

      bot.handle_dark_room
    end
  end

  # ===========================================================================
  # handle_doors: colored-door traversal, plus the dark-room hang fix
  # ===========================================================================
  describe '#handle_doors' do
    before do
      # wandercounter > 40 forces an attempt regardless of the anti-repeat guard.
      bot.instance_variable_set(:@wandercounter, 41)
      bot.instance_variable_set(:@last_door_entered, 'green door')
      DRRoom.room_objs = ['green door']
      allow(DRCI).to receive(:in_hands?).and_return(false)
    end

    it 'reinitializes the map after stepping through a colored door' do
      allow(DRC).to receive(:bput).and_return('Obvious exits: north, south.')
      expect(bot).to receive(:init_maze)

      bot.handle_doors

      expect(DRRoom.room_objs).not_to include('green door')
    end

    it 'relights and skips (never hangs) when the colored-door room is dark' do
      allow(DRC).to receive(:bput).and_return("It's pitch dark and you can't see a thing!")
      expect(bot).to receive(:relight_room)
      expect(bot).not_to receive(:init_maze)

      bot.handle_doors
    end

    it 'does not reinitialize when the door refuses entry' do
      allow(DRC).to receive(:bput).and_return("You can't go there.")
      expect(bot).not_to receive(:init_maze)

      bot.handle_doors
    end

    it 'does nothing before enough rooms have been explored (wandercounter <= 15)' do
      bot.instance_variable_set(:@wandercounter, 10)
      expect(DRC).not_to receive(:bput)

      bot.handle_doors
    end

    it 'does nothing when no colored door is present' do
      DRRoom.room_objs = ['rope']
      expect(DRC).not_to receive(:bput)

      bot.handle_doors
    end

    it 'avoids re-entering the same colored door until wandering further' do
      # Same door as last entered, and not yet past the wandercounter-40 threshold.
      bot.instance_variable_set(:@wandercounter, 20)
      bot.instance_variable_set(:@last_door_entered, 'green door')
      expect(DRC).not_to receive(:bput)

      bot.handle_doors
    end
  end

  # ===========================================================================
  # handle_key_or_search: wand rivals BEFORE pulling the key-dropping rope
  # ===========================================================================
  describe '#handle_key_or_search (rope branch)' do
    before do
      bot.instance_variable_set(:@nemesis, nil)
      bot.instance_variable_set(:@whitedoorseen, -1)
      DRRoom.pcs = []
      DRRoom.room_objs = ['rope']
      allow(DRCI).to receive(:in_hands?).and_return(false) # no key in hand
    end

    it 'freezes rivals in the room BEFORE pulling the rope' do
      expect(bot).to receive(:check_for_npcs).ordered
      expect(bot).to receive(:pull_rope).with('rope').ordered

      bot.handle_key_or_search
    end

    it 'does not wand the room when there is no rope to pull' do
      DRRoom.room_objs = []
      expect(bot).not_to receive(:check_for_npcs)
      expect(bot).not_to receive(:pull_rope)

      bot.handle_key_or_search
    end

    it 'skips pulling (and wanding) entirely while a nemesis is set' do
      bot.instance_variable_set(:@nemesis, 'Cherisse')
      expect(bot).not_to receive(:check_for_npcs)
      expect(bot).not_to receive(:pull_rope)

      bot.handle_key_or_search
    end
  end

  # ===========================================================================
  # handle_lever: wand rivals BEFORE pulling (mirrors the rope guard)
  # ===========================================================================
  describe '#handle_lever' do
    it 'freezes rivals in the room BEFORE pulling the lever' do
      DRRoom.room_objs = ['blue lever']
      allow(bot).to receive(:fput)
      expect(bot).to receive(:check_for_npcs).ordered
      expect(bot).to receive(:fput).with('Pull blue lever').ordered

      bot.handle_lever
    end

    it 'does not wand the room when there is no lever to pull' do
      DRRoom.room_objs = ['rope']
      expect(bot).not_to receive(:check_for_npcs)
      expect(bot).not_to receive(:fput)

      bot.handle_lever
    end

    it 'forgets the lever after pulling so it is not re-pulled this tick' do
      DRRoom.room_objs = ['blue lever']
      allow(bot).to receive(:check_for_npcs)
      allow(bot).to receive(:fput)

      bot.handle_lever

      expect(DRRoom.room_objs).not_to include('blue lever')
    end
  end

  # ===========================================================================
  # run_tick: one pass of the main loop -- rivals frozen before any action
  # ===========================================================================
  describe '#run_tick' do
    before do
      # Neutralize every per-tick collaborator; each example asserts only the
      # ordering/branch it cares about.
      %i[
        waitrt? handle_package_if_held ensure_wand absorb_unfrozen_npcs
        handle_dark_room zap_nemesis check_for_npcs track_white_door
        handle_key_or_search handle_lever set_or_unset_nemesis handle_doors
        handle_reposition maintain_khri_buffs maybe_change_direction
        wander backtrack
      ].each { |m| allow(bot).to receive(m) }
      allow(DRC).to receive(:fix_standing)
      bot.instance_variable_set(:@backtrack_to_white_door, false)
    end

    it 'freezes rivals BEFORE acting on the room (key/rope, lever, doors)' do
      expect(bot).to receive(:check_for_npcs).ordered
      expect(bot).to receive(:handle_key_or_search).ordered
      expect(bot).to receive(:handle_lever).ordered
      expect(bot).to receive(:handle_doors).ordered

      bot.run_tick
    end

    it 'freezes rivals after resolving the nemesis (so a fresh nemesis is set first)' do
      expect(bot).to receive(:zap_nemesis).ordered
      expect(bot).to receive(:check_for_npcs).ordered

      bot.run_tick
    end

    it 'wanders when not backtracking to the white door' do
      bot.instance_variable_set(:@backtrack_to_white_door, false)
      expect(bot).to receive(:wander)
      expect(bot).not_to receive(:backtrack)

      bot.run_tick
    end

    it 'backtracks (not wanders) when armed for the white door' do
      bot.instance_variable_set(:@backtrack_to_white_door, true)
      expect(bot).to receive(:backtrack)
      expect(bot).not_to receive(:wander)

      bot.run_tick
    end
  end

  # ===========================================================================
  # leave_winners_circle: step out only when actually in the circle
  # ===========================================================================
  describe '#leave_winners_circle' do
    it 'walks out of the oval twice when standing in the winner\'s circle' do
      DRRoom.title = "Droughtman's Maze, Winner's Circle"
      expect(bot).to receive(:fput).with('go oval').twice

      bot.leave_winners_circle
    end

    it 'does nothing when the cash-in happened outside the winner\'s circle' do
      DRRoom.title = "Droughtman's Compound, The Maze"
      expect(bot).not_to receive(:fput)

      bot.leave_winners_circle
    end
  end
end
