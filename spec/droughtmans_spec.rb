require_relative 'spec_helper'

# Droughtmans#initialize depends on the full Lich runtime (parse_args,
# get_settings, walking into the maze, the infinite run loop), so we extract the
# class with load_lic_class and exercise individual methods on bare-allocated
# instances (Droughtmans.allocate) with state injected via instance_variable_set.
#
# The focus is the deterministic navigation/dowsing logic and the safety
# branches that matter most: the wave -> exit footgun, keyholder-only wanding,
# the never-trash-a-non-empty-package guarantee, pass-is-money stow safety,
# drag-aware key recovery, and dead-reckoning move selection. Every example is
# self-contained and reads top-to-bottom (DAMP).
load_lic_class('droughtmans.lic', 'Droughtmans')

RSpec.describe Droughtmans do
  let(:bot) { Droughtmans.allocate }

  # Route Flags through a plain hash so examples can arm/clear game events.
  def stub_flags(store)
    allow(Flags).to receive(:[]) { |k| store[k] }
    allow(Flags).to receive(:reset) { |k| store.delete(k) }
    allow(Flags).to receive(:add)
    allow(Flags).to receive(:delete)
  end

  before do
    # Actions fired by nearly every method; neutralize them by default.
    allow(DRC).to receive(:release_invisibility)
    allow(DRC).to receive(:fix_standing)
  end

  # ===========================================================================
  # Compass direction tables (pure constants -- catch a single typo'd entry)
  # ===========================================================================
  describe 'direction tables' do
    it 'reverses every direction back to itself (involution)' do
      Droughtmans::REVERSE_DIRECTION.each do |dir, reversed|
        expect(Droughtmans::REVERSE_DIRECTION[reversed]).to eq(dir)
      end
    end

    it 'covers all eight compass points in the reverse and offset tables' do
      eight = Droughtmans::DIRECTIONS.sort
      expect(Droughtmans::REVERSE_DIRECTION.keys.sort).to eq(eight)
      expect(Droughtmans::DIR_OFFSETS.keys.sort).to eq(eight)
    end

    it 'gives opposite directions negated grid offsets' do
      Droughtmans::REVERSE_DIRECTION.each do |dir, reversed|
        fwd = Droughtmans::DIR_OFFSETS[dir]
        rev = Droughtmans::DIR_OFFSETS[reversed]
        expect(rev).to eq([-fwd[0], -fwd[1]])
      end
    end
  end

  # ===========================================================================
  # Pure grid math
  # ===========================================================================
  describe '#chebyshev' do
    it 'is the chessboard distance (max of the axis deltas)' do
      expect(bot.chebyshev([0, 0], [3, 1])).to eq(3)
      expect(bot.chebyshev([0, 0], [-2, -5])).to eq(5)
      expect(bot.chebyshev([2, 2], [2, 2])).to eq(0)
    end
  end

  describe '#next_pos' do
    it 'applies the direction offset to the current position' do
      bot.instance_variable_set(:@pos, [4, 4])
      expect(bot.next_pos('north')).to eq([4, 5])
      expect(bot.next_pos('southwest')).to eq([3, 3])
    end

    it 'stays put for an unknown direction (defensive [0,0] offset)' do
      bot.instance_variable_set(:@pos, [1, 1])
      expect(bot.next_pos('out')).to eq([1, 1])
    end
  end

  describe '#record_position' do
    it 'advances the position, marks it visited, and bumps the counters' do
      bot.instance_variable_set(:@pos, [0, 0])
      bot.instance_variable_set(:@visited, Hash.new(0))
      bot.instance_variable_set(:@section_move_count, 4)
      bot.instance_variable_set(:@moves_since_rest, 4)

      bot.record_position('east')

      expect(bot.instance_variable_get(:@pos)).to eq([1, 0])
      expect(bot.instance_variable_get(:@visited)[[1, 0]]).to eq(1)
      expect(bot.instance_variable_get(:@last_direction)).to eq('east')
      expect(bot.instance_variable_get(:@section_move_count)).to eq(5)
      expect(bot.instance_variable_get(:@moves_since_rest)).to eq(5)
    end
  end

  # ===========================================================================
  # Dowse bearing math
  # ===========================================================================
  describe '#compass_preferences' do
    it 'lists the diagonal satisfying both axes first, then each single axis' do
      expect(bot.compass_preferences(%w[north east])).to eq(%w[northeast north east])
    end

    it 'returns just the single axis when only one is present' do
      expect(bot.compass_preferences(%w[north])).to eq(%w[north])
    end

    it 'is empty for no compass words' do
      expect(bot.compass_preferences([])).to eq([])
    end
  end

  describe '#hint_directions' do
    it 'is empty without a dowse hint' do
      bot.instance_variable_set(:@dowse_hint, nil)
      expect(bot.hint_directions).to eq([])
    end

    it 'expands the stored bearing into best-first directions' do
      bot.instance_variable_set(:@dowse_hint, { dirs: %w[south west] })
      expect(bot.hint_directions).to eq(%w[southwest south west])
    end
  end

  describe '#direction_toward' do
    before { bot.instance_variable_set(:@pos, [0, 0]) }

    it 'picks the exit that reduces distance to the target' do
      bot.instance_variable_set(:@visited, Hash.new(0))
      expect(bot.direction_toward([3, 0], %w[east west])).to eq('east')
    end

    it 'returns nil when no exit makes progress' do
      bot.instance_variable_set(:@visited, Hash.new(0))
      expect(bot.direction_toward([3, 0], %w[west])).to be_nil
    end

    it 'breaks ties toward the less-visited room' do
      visited = Hash.new(0)
      visited[[1, 1]] = 5 # northeast destination already worn
      bot.instance_variable_set(:@visited, visited)
      # Target due north of us: from [0, 0] both northeast -> [1, 1] and
      # northwest -> [-1, 1] cut the Chebyshev distance to [0, 3] to 2 equally --
      # a genuine tie that must break toward the less-visited northwest room.
      expect(bot.direction_toward([0, 3], %w[northeast northwest])).to eq('northwest')
    end
  end

  # ===========================================================================
  # read_dowse_results: turning the vision text into steering state
  # ===========================================================================
  describe '#read_dowse_results' do
    before do
      bot.instance_variable_set(:@whitelist, [])
      bot.instance_variable_set(:@searched_quadrants, [])
      bot.instance_variable_set(:@no_attack, [])
      bot.instance_variable_set(:@dowse_hint, nil)
    end

    it 'derives the quadrant from the center bearing (opposite corner)' do
      stub_flags('dm-dowse-center' => { where: 'far to the north and east' })
      bot.read_dowse_results
      expect(bot.instance_variable_get(:@current_quadrant)).to eq(:southwest)
      expect(bot.instance_variable_get(:@center_hint)).to eq(dirs: %w[north east], range: :far)
    end

    it 'whitelists a named holder and stores the key bearing' do
      stub_flags('dm-dowse-key' => { holder: 'bob', where: ' to the north' })
      bot.read_dowse_results
      expect(bot.instance_variable_get(:@whitelist)).to include('Bob')
      expect(bot.instance_variable_get(:@dowse_hint)).to eq(dirs: %w[north])
      expect(bot.instance_variable_get(:@key_in_play)).to be(true)
    end

    it 'never whitelists a no_attack friend even when the vision names them' do
      bot.instance_variable_set(:@no_attack, ['Bob'])
      stub_flags('dm-dowse-key' => { holder: 'bob', where: ' to the north' })
      bot.read_dowse_results
      expect(bot.instance_variable_get(:@whitelist)).to be_empty
    end

    it 'clears the bearing and key state when there is no key vision' do
      bot.instance_variable_set(:@dowse_hint, { dirs: %w[north] })
      bot.instance_variable_set(:@key_in_play, true)
      stub_flags({})
      bot.read_dowse_results
      expect(bot.instance_variable_get(:@dowse_hint)).to be_nil
      expect(bot.instance_variable_get(:@key_in_play)).to be(false)
    end
  end

  # ===========================================================================
  # process_flags: event ordering and state updates
  # ===========================================================================
  describe '#process_flags' do
    before do
      bot.instance_variable_set(:@whitelist, [])
      bot.instance_variable_set(:@looked, {})
      bot.instance_variable_set(:@dowse_hint, nil)
      bot.instance_variable_set(:@pos, [0, 0])
      bot.instance_variable_set(:@visited, Hash.new(0))
      bot.instance_variable_set(:@blocked, {})
      bot.instance_variable_set(:@known_frozen, {})
    end

    it 'handles a prevail by dropping the winner and invalidating key intel' do
      bot.instance_variable_set(:@whitelist, %w[Bob])
      bot.instance_variable_set(:@looked, 'Bob' => Time.now)
      bot.instance_variable_set(:@dowse_hint, { dirs: %w[north] })
      bot.instance_variable_set(:@key_in_play, true)
      stub_flags('dm-prevailed' => { who: 'bob' })

      bot.process_flags

      expect(bot.instance_variable_get(:@whitelist)).to be_empty
      expect(bot.instance_variable_get(:@key_in_play)).to be(false)
      expect(bot.instance_variable_get(:@dowse_hint)).to be_nil
    end

    it 'whitelists a fresh key finder and clears stale suspects' do
      allow(bot).to receive(:have_key?).and_return(false)
      bot.instance_variable_set(:@whitelist, %w[Stale])
      stub_flags('dm-key-found' => { who: 'carol' })

      bot.process_flags

      expect(bot.instance_variable_get(:@whitelist)).to eq(%w[Carol])
      expect(bot.instance_variable_get(:@key_in_play)).to be(true)
      expect(bot.instance_variable_get(:@dowse_wanted)).to be(true)
    end

    it 'applies a drag to the position BEFORE recovering a key dropped in the same RT' do
      allow(bot).to receive(:recover_dropped_key)
      stub_flags('dm-key-dropped' => true, 'dm-dragged' => { dir: 'north' })

      bot.process_flags

      # The drag moved us north first, so recovery reasons from the new room.
      expect(bot.instance_variable_get(:@pos)).to eq([0, 1])
      expect(bot).to have_received(:recover_dropped_key).with(be_truthy, 'north')
    end

    it 'marks a risen wall blocked at the current position' do
      stub_flags('dm-wall-rises' => { dir: 'east' })
      bot.process_flags
      expect(bot.instance_variable_get(:@blocked)[[[0, 0], 'east']]).to be(true)
    end
  end

  # ===========================================================================
  # Movement selection (dead-reckoning, visited-aware)
  # ===========================================================================
  describe '#key_return_direction' do
    before do
      allow(bot).to receive(:have_key?).and_return(true)
      bot.instance_variable_set(:@pos, [0, 0])
      bot.instance_variable_set(:@visited, Hash.new(0))
      bot.instance_variable_set(:@center_hint, nil)
    end

    it 'heads toward the remembered white door when one is known' do
      bot.instance_variable_set(:@white_door_pos, [2, 0])
      expect(bot.key_return_direction(%w[east west])).to eq('east')
    end

    it 'falls back to the center bearing when no white door is remembered' do
      bot.instance_variable_set(:@white_door_pos, nil)
      bot.instance_variable_set(:@center_hint, { dirs: %w[north], range: :bit })
      expect(bot.key_return_direction(%w[north south])).to eq('north')
    end

    it 'returns nil (defer to exploration) when keyless' do
      allow(bot).to receive(:have_key?).and_return(false)
      bot.instance_variable_set(:@white_door_pos, [2, 0])
      expect(bot.key_return_direction(%w[east])).to be_nil
    end
  end

  describe '#bearing_direction' do
    before do
      bot.instance_variable_set(:@pos, [0, 0])
      bot.instance_variable_set(:@visited, Hash.new(0))
    end

    it 'follows the dowse bearing onto a matching exit' do
      bot.instance_variable_set(:@dowse_hint, { dirs: %w[north] })
      expect(bot.bearing_direction(%w[north south])).to eq('north')
    end

    it 'declines the bearing when it only leads into worn-out rooms' do
      visited = Hash.new(0)
      visited[[0, 1]] = 9 # the bearing (north) is heavily revisited
      visited[[0, -1]] = 0
      bot.instance_variable_set(:@visited, visited)
      bot.instance_variable_set(:@dowse_hint, { dirs: %w[north] })
      expect(bot.bearing_direction(%w[north south])).to be_nil
    end
  end

  describe '#move_random' do
    before do
      bot.instance_variable_set(:@pos, [0, 0])
      bot.instance_variable_set(:@visited, Hash.new(0))
      bot.instance_variable_set(:@rest_interval, 0)
      bot.instance_variable_set(:@last_direction, nil)
      allow(bot).to receive(:key_return_direction).and_return(nil)
      allow(bot).to receive(:bearing_direction).and_return(nil)
      allow(bot).to receive(:do_move)
    end

    it 'prefers the least-visited destination' do
      visited = Hash.new(0)
      visited[[1, 0]] = 3  # east worn
      visited[[0, 1]] = 0  # north fresh
      bot.instance_variable_set(:@visited, visited)
      allow(bot).to receive(:available_exits).and_return(%w[east north])
      bot.move_random
      expect(bot).to have_received(:do_move).with('north')
    end

    it 'avoids immediately doubling back when another equal choice exists' do
      bot.instance_variable_set(:@last_direction, 'north') # we arrived going north
      bot.instance_variable_set(:@visited, Hash.new(0))
      allow(bot).to receive(:available_exits).and_return(%w[south east])
      bot.move_random
      # south == reverse of north; with east equally fresh it must not be chosen.
      expect(bot).to have_received(:do_move).with('east')
    end
  end

  describe '#do_move' do
    before do
      bot.instance_variable_set(:@pos, [0, 0])
      bot.instance_variable_set(:@visited, Hash.new(0))
      bot.instance_variable_set(:@section_move_count, 0)
      bot.instance_variable_set(:@moves_since_rest, 0)
      bot.instance_variable_set(:@blocked, {})
      bot.instance_variable_set(:@step_delay, 0)
      bot.instance_variable_set(:@key_step_delay, 0)
      bot.instance_variable_set(:@last_direction, nil)
      allow(bot).to receive(:get_key)
      allow(bot).to receive(:freeze_npcs)
      allow(bot).to receive(:have_key?).and_return(false)
      stub_flags({})
    end

    it 'records the new position on a successful arrival' do
      allow(DRC).to receive(:bput).and_return('Obvious paths: north, south.')
      bot.do_move('north')
      expect(bot.instance_variable_get(:@pos)).to eq([0, 1])
    end

    it 'marks the exit blocked when the game refuses it' do
      allow(DRC).to receive(:bput).and_return("You can't go there.")
      bot.do_move('north')
      expect(bot.instance_variable_get(:@blocked)[[[0, 0], 'north']]).to be(true)
      expect(bot.instance_variable_get(:@pos)).to eq([0, 0])
    end

    it 'bails out at the recursion guard' do
      expect(DRC).not_to receive(:bput)
      bot.do_move('north', 5)
    end
  end

  # ===========================================================================
  # colored-door budgeting
  # ===========================================================================
  describe '#colored_door_budget' do
    before do
      bot.instance_variable_set(:@section_moves, 24)
      bot.instance_variable_set(:@searched_quadrants, [])
      bot.instance_variable_set(:@current_quadrant, nil)
      bot.instance_variable_set(:@white_door_quadrant, nil)
      bot.instance_variable_set(:@center_hint, nil)
    end

    it 'is the full section budget while searching a fresh quadrant keyless' do
      allow(bot).to receive(:have_key?).and_return(false)
      expect(bot.colored_door_budget).to eq(24)
    end

    it 'is zero with the key when the exit is known to be in another quadrant' do
      allow(bot).to receive(:have_key?).and_return(true)
      bot.instance_variable_set(:@current_quadrant, :northeast)
      bot.instance_variable_set(:@white_door_quadrant, :southwest)
      expect(bot.colored_door_budget).to eq(0)
    end

    it 'is zero with the key when the center bearing says the exit is far' do
      allow(bot).to receive(:have_key?).and_return(true)
      bot.instance_variable_set(:@center_hint, { dirs: %w[north], range: :far })
      expect(bot.colored_door_budget).to eq(0)
    end
  end

  # ===========================================================================
  # Player wanding: keyholder-only policy
  # ===========================================================================
  describe '#scan_players' do
    before do
      allow(bot).to receive(:in_maze?).and_return(true)
      allow(bot).to receive(:have_key?).and_return(false)
      bot.instance_variable_set(:@whitelist, [])
      bot.instance_variable_set(:@no_attack, [])
      bot.instance_variable_set(:@looked, {})
      DRRoom.pcs = []
    end

    it 'waves a whitelisted holder without a verifying look' do
      DRRoom.pcs = ['Bob']
      bot.instance_variable_set(:@whitelist, %w[Bob])
      allow(bot).to receive(:wave)
      bot.scan_players
      expect(bot).to have_received(:wave).with('Bob', is_keyholder: true)
    end

    it 'never wands a friend on the no_attack list' do
      DRRoom.pcs = ['Bob']
      bot.instance_variable_set(:@whitelist, %w[Bob])
      bot.instance_variable_set(:@no_attack, %w[Bob])
      expect(bot).not_to receive(:wave)
      bot.scan_players
    end

    it 'does nothing while carrying the key (run for the door, do not fight)' do
      allow(bot).to receive(:have_key?).and_return(true)
      DRRoom.pcs = ['Bob']
      bot.instance_variable_set(:@whitelist, %w[Bob])
      expect(bot).not_to receive(:wave)
      bot.scan_players
    end
  end

  describe '#check_player_for_key' do
    before do
      bot.instance_variable_set(:@whitelist, [])
      bot.instance_variable_set(:@looked, {})
      DRRoom.pcs = ['Bob']
    end

    it 'whitelists and attacks a LOOK-confirmed key holder' do
      allow(DRC).to receive(:bput).and_return('He is holding a golden key.')
      allow(bot).to receive(:wave)
      bot.check_player_for_key('Bob')
      expect(bot.instance_variable_get(:@whitelist)).to include('Bob')
      expect(bot).to have_received(:wave).with('Bob', is_keyholder: true)
    end

    it 'prunes a whitelisted suspect that a LOOK shows is not holding it' do
      bot.instance_variable_set(:@whitelist, %w[Bob])
      allow(DRC).to receive(:bput).and_return('He is wearing some leathers.')
      bot.check_player_for_key('Bob')
      expect(bot.instance_variable_get(:@whitelist)).not_to include('Bob')
    end

    it 'rate-limits repeat looks at the same player' do
      bot.instance_variable_set(:@looked, 'Bob' => Time.now)
      expect(DRC).not_to receive(:bput)
      bot.check_player_for_key('Bob')
    end
  end

  # ===========================================================================
  # wave: the historical footguns
  # ===========================================================================
  describe '#wave' do
    before do
      bot.instance_variable_set(:@pos, [0, 0])
      bot.instance_variable_set(:@known_frozen, {})
      bot.instance_variable_set(:@whitelist, [])
      stub_flags({})
    end

    it 'stops the whole script only when the wand is gone (wave not understood)' do
      allow(DRC).to receive(:bput).and_return('I do not understand what you are trying to do.')
      expect { bot.wave('guard') }.to raise_error(SystemExit)
    end

    it 'recovers from a reflected wave and prunes the bad suspect' do
      bot.instance_variable_set(:@whitelist, %w[Bob])
      allow(DRC).to receive(:bput).and_return('The wand circles around Bob and returns to you, freezing you in place.')
      allow(bot).to receive(:wait_for_self_thaw)
      bot.wave('Bob')
      expect(bot.instance_variable_get(:@whitelist)).not_to include('Bob')
      expect(bot).to have_received(:wait_for_self_thaw)
    end

    it 'grabs the key when a wave makes the holder drop it' do
      allow(DRC).to receive(:bput).and_return('Bob drops his golden key!')
      allow(bot).to receive(:get_key)
      bot.wave('Bob', is_keyholder: true)
      expect(bot).to have_received(:get_key)
    end

    it 'records a successful freeze in the known-frozen ledger' do
      allow(DRC).to receive(:bput).and_return('You wave an icy blue wand at the guard.')
      bot.wave('guard')
      expect(bot.instance_variable_get(:@known_frozen)).to have_key([[0, 0], 'guard'])
    end

    it 'camps a confirmed holder found already frozen' do
      allow(DRC).to receive(:bput).and_return('The guard is already frozen.')
      allow(bot).to receive(:camp_frozen_keyholder)
      bot.wave('Bob', is_keyholder: true)
      expect(bot).to have_received(:camp_frozen_keyholder).with('Bob')
    end
  end

  # ===========================================================================
  # freeze_npcs: ordinals + the known-frozen ledger
  # ===========================================================================
  describe '#freeze_npcs' do
    before do
      allow(bot).to receive(:in_maze?).and_return(true)
      bot.instance_variable_set(:@pos, [0, 0])
      bot.instance_variable_set(:@known_frozen, {})
    end

    it 'waves duplicate maze mobs by ordinal (warrior, second warrior)' do
      DRRoom.npcs = %w[warrior warrior]
      allow(bot).to receive(:wave)
      bot.freeze_npcs
      expect(bot).to have_received(:wave).with('warrior')
      expect(bot).to have_received(:wave).with('second warrior')
    end

    it 'only freezes recognized maze mobs, not incidental creatures' do
      DRRoom.npcs = %w[squirrel]
      expect(bot).not_to receive(:wave)
      bot.freeze_npcs
    end

    it 'skips a mob confirmed frozen within the TTL' do
      DRRoom.npcs = %w[warrior]
      bot.instance_variable_set(:@known_frozen, [[0, 0], 'warrior'] => Time.now)
      expect(bot).not_to receive(:wave)
      bot.freeze_npcs
    end

    it 'ignores the ledger for the hard pre-move safety sweep' do
      DRRoom.npcs = %w[warrior]
      bot.instance_variable_set(:@known_frozen, [[0, 0], 'warrior'] => Time.now)
      allow(bot).to receive(:wave)
      bot.freeze_npcs(ignore_ledger: true)
      expect(bot).to have_received(:wave).with('warrior')
    end
  end

  # ===========================================================================
  # Key recovery
  # ===========================================================================
  describe '#recover_dropped_key' do
    before do
      stub_flags({})
      allow(bot).to receive(:grab_key)
    end

    it 'backtracks the reverse of a drag to reclaim a swept-away key' do
      allow(bot).to receive(:have_key?).and_return(true)
      allow(bot).to receive(:do_move)
      bot.recover_dropped_key(true, 'north')
      expect(bot).to have_received(:do_move).with('south')
      expect(bot).to have_received(:grab_key)
    end

    it 'chases the new holder when a plain drop was snatched by someone else' do
      allow(bot).to receive(:have_key?).and_return(false)
      allow(bot).to receive(:get_key)
      allow(bot).to receive(:process_flags)
      allow(bot).to receive(:scan_players)
      bot.recover_dropped_key(false, nil)
      expect(bot).to have_received(:scan_players)
    end
  end

  # ===========================================================================
  # Looting safety
  # ===========================================================================
  describe '#noun_candidates' do
    it 'takes the last word of a plain "adjective noun" phrase' do
      expect(bot.noun_candidates('a sturdy backpack').first).to eq('backpack')
    end

    it 'takes the head noun before a preposition, not the trailing pronoun' do
      phrase = 'a circle of colorful wool with a wool rug on it'
      expect(bot.noun_candidates(phrase)).to eq(%w[circle])
    end

    it 'drops pronoun stopwords entirely' do
      expect(bot.noun_candidates('them')).to eq([])
    end
  end

  describe '#trash?' do
    it 'matches a configured trash substring case-insensitively' do
      bot.instance_variable_set(:@trash, %w[blouse])
      expect(bot.trash?('a lacy Blouse')).to be_truthy
    end

    it 'is false with nothing configured' do
      bot.instance_variable_set(:@trash, [])
      expect(bot.trash?('a lacy blouse')).to be(false)
    end
  end

  describe '#stash_or_trash' do
    before do
      bot.instance_variable_set(:@trash, [])
      bot.instance_variable_set(:@loot_containers, %w[backpack])
      allow(DRCI).to receive(:stow_item?)
      allow(DRCI).to receive(:put_away_item?).and_return(true)
    end

    it 'always stows a pass personally, never through a droppable container' do
      bot.stash_or_trash('a copper pass')
      expect(DRCI).to have_received(:stow_item?).with('pass')
      expect(DRCI).not_to have_received(:put_away_item?)
    end

    it 'drops a trash-listed item' do
      bot.instance_variable_set(:@trash, %w[blouse])
      allow(bot).to receive(:fput)
      bot.stash_or_trash('a lacy blouse')
      expect(bot).to have_received(:fput).with('drop my blouse')
    end

    it 'routes winnings into the first loot container that accepts them' do
      bot.stash_or_trash('a shimmering gem')
      expect(DRCI).to have_received(:put_away_item?).with('gem', 'backpack')
    end

    it 'stows personally when no container accepts the item' do
      allow(DRCI).to receive(:put_away_item?).and_return(false)
      bot.stash_or_trash('a shimmering gem')
      expect(DRCI).to have_received(:stow_item?).with('gem')
    end
  end

  describe '#dispose_package' do
    it 'refuses to dispose of a package that still holds loot and stops the script' do
      allow(DRCI).to receive(:in_hands?).with('package').and_return(true)
      allow(DRCI).to receive(:stow_item?)
      allow(bot).to receive(:grab_from_package).and_return(false)
      allow(DRC).to receive(:bput) do |cmd, *_|
        cmd == 'look in my package' ? 'In the runner package you see a gemstone.' : ''
      end
      expect { bot.dispose_package }.to raise_error(SystemExit)
    end

    it 'is a no-op when the package is not in hand' do
      allow(DRCI).to receive(:in_hands?).with('package').and_return(false)
      expect(DRC).not_to receive(:bput)
      bot.dispose_package
    end
  end

  # ===========================================================================
  # Pass redemption: non-fatal missing pass, fatal out-of-passes
  # ===========================================================================
  describe '#redeem_pass' do
    before do
      bot.instance_variable_set(:@pass_adjective, nil)
      bot.instance_variable_set(:@multiplier, false)
      allow(bot).to receive(:cast_buffs)
      allow(bot).to receive(:fput)
    end

    it 'stops cleanly when there is no pass left to get (out of passes)' do
      allow(DRC).to receive(:bput).and_return('What were you referring to?')
      expect { bot.redeem_pass }.to raise_error(SystemExit)
    end

    it 'carries on when a pass is in hand but REDEEM finds none (existing access)' do
      allow(DRCI).to receive(:in_hands?).and_return(false)
      allow(bot).to receive(:echo)
      # The GET succeeds (we hold a pass), but REDEEM comes back "What were you
      # referring to?" -- non-fatal: rely on existing access and finish normally.
      allow(DRC).to receive(:bput) do |cmd, *_|
        cmd.start_with?('get my') ? 'You get a copper pass.' : 'What were you referring to?'
      end
      expect { bot.redeem_pass }.not_to raise_error
      expect(bot).to have_received(:echo).with(/No pass in hand to redeem/)
    end
  end

  describe '#out_of_passes' do
    it 'stops the script' do
      expect { bot.out_of_passes }.to raise_error(SystemExit)
    end
  end

  # ===========================================================================
  # Small state helpers
  # ===========================================================================
  describe '#lurk_here?' do
    it 'lurks only when camping is explicitly enabled (no auto-ambush)' do
      bot.instance_variable_set(:@camp, false)
      expect(bot.lurk_here?).to be(false)
      bot.instance_variable_set(:@camp, true)
      expect(bot.lurk_here?).to be(true)
    end
  end

  describe '#tend_trap_wounds' do
    it 'clears the injured latch when HEALTH shows no bleeding parts' do
      bot.instance_variable_set(:@injured, true)
      allow(DRC).to receive(:bput).and_return('You have no significant injuries.')
      bot.tend_trap_wounds
      expect(bot.instance_variable_get(:@injured)).to be(false)
    end

    it 'tends each named bleeding part and lifts the latch on success' do
      bot.instance_variable_set(:@injured, true)
      allow(DRC).to receive(:bput) do |cmd, *_|
        cmd == 'health' ? 'You have a deep wound to the right arm.' : 'You are able to stop the bleeding.'
      end
      bot.tend_trap_wounds
      expect(DRC).to have_received(:bput).with('tend my right arm', any_args)
      expect(bot.instance_variable_get(:@injured)).to be(false)
    end
  end
end
