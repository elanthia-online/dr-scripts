# frozen_string_literal: true

require 'yaml'

require_relative 'spec_helper'

load_lic_class('kiosk.lic', 'Kiosk')

# Raised by the fake game once a single example has sent more commands than any
# finite run of the code under test needs, so a retry or `until` loop that never
# ends fails the example instead of hanging the suite.
class KioskRunawayLoopError < StandardError; end

# The Prosperity in Absentia cast message, verbatim from the spell's Elanthipedia
# page (the first paragraph of its messaging field, which the game sends as one line).
KIOSK_PRIA_CAST_MESSAGE =
  'Your tessera grows cold, flickering in a complex undulating pattern, and extends a pair of ' \
  'opposingly oriented posts which shine hair-thin lances of green-orange light at an empty area ' \
  'of space nearby, growing a frosty crystal of Iridius which begins to expand.  The tessera ' \
  'continues to paint the crystal with zigzagging light, guiding its growth, and with the sound ' \
  'of shattering glass and a hiss of displaced air, a jaggedly dendritic crystalline kiosk ' \
  'unfolds from nothingness.'

# Verbatim from urbaj-dr's in-game transcripts on PR #7832
# (https://github.com/elanthia-online/dr-scripts/pull/7832#issuecomment-6525700418).
# The PERCEIVE line carries the game's current "Properity in Abstentia" typo.
KIOSK_REFRESH_MESSAGE = 'You gesture at a vitreous crystalline kiosk, which responds by briefly undulating with green-orange hues as the spell pattern is refreshed.'
KIOSK_PERCEIVE_MESSAGE = 'You sense your Properity in Abstentia spell within a monoclinic crystalline kiosk, which will last for about seven anlaen.  ' \
                         "It is deployed at [Grisgonda's, Appraisal Room], and has coin reserves."

# The tessera report from the same transcripts, as Lich::Util.issue_command
# returns it: from the line matching the start pattern through the end line.
# The markup line sits in the session section, and "Kronars in pouches/bundles"
# appear in both sections; the holdings are the second set.
KIOSK_REPORT = [
  'A flurry of glimmering geometries and abstract ratios flit across your field of view, describing key sales data:',
  "The crystalline kiosk is presently located at [Grisgonda's, Appraisal Room].",
  "During this kiosk's trading session, it has purchased the following:",
  '  No Kronars in pouches.',
  '  No Kronars in bundles.',
  '  The markup is set to 55%.',
  "Finally, your kiosk's current asset holdings are:",
  '  It has a total of 575 platinum, 8 gold, 8 silver, 5 bronze, and 5 copper Kronars on hand for purchases.',
  '  77 platinum, 6 gold, 8 silver, 5 bronze, and 3 copper Kronars in pouches.',
  '  No Kronars in bundles.',
  'The floating data fades with a friendly chime, leaving you blinking away a brief visual afterglow.'
].freeze

# The replies below are shaped to the phrases kiosk.lic matches, not copied
# from a log. Each keeps the matched phrase intact and adds the kind of
# surrounding text the game sends, so a too-loose or too-tight pattern shows.
KIOSK_NOT_OWNER = 'As you are not the owner of a jaggedly dendritic crystalline kiosk, you cannot do that.'
KIOSK_RUB_TO_POUCH = 'You rub the kiosk.  It is now set to pay out pouch sales.'
KIOSK_RUB_TO_BUNDLE = 'You rub the kiosk.  It is now set to pay out bundle sales.'
KIOSK_NOT_FOUND = 'I could not find what you were referring to.'

# kiosk_settings as profiles/base.yaml ships them. Profiles carry !ruby/regexp
# tags, so they load permissively, as the profile loader does.
KIOSK_BASE_SETTINGS = YAML.unsafe_load_file(File.join(__dir__, '..', 'profiles', 'base.yaml')).fetch('kiosk_settings').freeze

# The real town data, so bank lookups use real exchange rooms, fees and currencies.
KIOSK_TOWN_DATA = YAML.load_file(File.join(__dir__, '..', 'data', 'base-town.yaml'), aliases: true).freeze

RSpec.describe Kiosk do
  # A fresh copy per example, so a spec that doesn't care about a value runs
  # against the shipped default and one that changes a value changes only its own.
  let(:kiosk_settings) { KIOSK_BASE_SETTINGS.dup }

  let(:town_data) { KIOSK_TOWN_DATA }

  let(:settings) do
    OpenStruct.new(
      kiosk_settings: kiosk_settings,
      tessera_noun: 'tessera',
      full_pouch_container: 'haversack',
      waggle_sets: { 'kiosk' => { 'Prosperity in Absentia' => { 'abbrev' => 'PRIA', 'recast' => 1 } } }
    )
  end

  # Every command the script sent through DRC.bput, in order.
  let(:commands) { [] }

  # What the game answers to each command; see #game_replies.
  let(:game) { ->(_command) {} }

  # Commands beyond any finite run of the code under test.
  let(:runaway_limit) { 60 }

  # Builds a Kiosk as #initialize would leave it, without running the script.
  #
  # @param overrides [Hash{Symbol => Object}] instance variables to replace, e.g. my_kiosk: 'second kiosk'
  # @return [Kiosk]
  def build_kiosk(**overrides)
    instance = Kiosk.allocate
    {
      settings: settings,
      town_data: town_data,
      kiosk_settings: kiosk_settings,
      debug: false,
      kiosk_room: kiosk_settings['cast_room'],
      kiosk_noun: kiosk_settings['kiosk_noun'],
      my_kiosk: nil,
      tessera: 'tessera',
      failed_attempt: false
    }.merge(overrides).each { |name, value| instance.instance_variable_set(:"@#{name}", value) }
    instance
  end

  # Routes DRC.bput through a fake game that honours bput's contract: it returns
  # the text matched by the first pattern that matches the game's reply, or ''
  # when nothing matches (bput's timeout result). The reply comes from the
  # block, which receives the command and returns a line, or nil for silence.
  #
  # @yieldparam command [String] the command the script sent
  # @yieldreturn [String, nil] the game's reply
  # @return [void]
  def game_replies(&reply)
    allow(DRC).to receive(:bput) do |command, *patterns|
      commands << command
      raise KioskRunawayLoopError, "#{commands.size} commands: #{commands.last(6).inspect}" if commands.size > runaway_limit

      line = reply.call(command).to_s
      matched = patterns.lazy.map { |pattern| line[pattern.is_a?(Regexp) ? pattern : /#{pattern}/i] }.find(&:itself)
      matched || ''
    end
  end

  # Drains what the script sent with fput (the harness queues it).
  #
  # @return [Array<String>] the fput commands, oldest first
  def fput_commands
    Array.new(sent_messages.size) { sent_messages.pop }
  end

  # Puts kiosks (by long name) into the room as DRRoom.room_objs reports them:
  # leading articles stripped, other objects interleaved.
  #
  # @param objects [Array<String>]
  # @return [void]
  def room_holds(*objects)
    DRRoom.room_objs = objects
  end

  # @param minutes [Integer, nil] minutes left on PRIA, or nil for no kiosk spell
  # @return [void]
  def pria_active(minutes)
    DRSpells._set_active_spells(minutes.nil? ? {} : { 'Prosperity in Absentia' => minutes })
  end

  # Converts coin amounts the way lich-5's DRCM.convert_to_copper does; the
  # harness double ignores the denomination.
  #
  # @return [void]
  def real_coin_values
    values = { 'platinum' => 10_000, 'gold' => 1000, 'silver' => 100, 'bronze' => 10, 'copper' => 1 }
    allow(DRCM).to receive(:convert_to_copper) { |amount, denom| (amount.to_f * values.fetch(denom.downcase)).to_i }
  end

  before do
    pria_active(120)
    game_replies { |_command| nil }
  end

  describe '#initialize' do
    let(:report) { { 'on_hand_amount' => 1, 'pouch_amount' => 2, 'bundle_amount' => 3, 'markup' => 15 } }

    before do
      DRStats.guild = 'Trader'
      $test_settings = settings
      $test_data = OpenStruct.new(town: town_data)
    end

    # The blocks #initialize registers with before_dying.
    let(:exit_hooks) { [] }

    # Runs #initialize with the five steps stubbed, so only its own logic runs.
    # before_dying is captured on the instance, since a spec elsewhere redefines
    # the top-level one.
    #
    # @return [Kiosk]
    def run_initialize
      instance = Kiosk.allocate
      allow(instance).to receive(:before_dying) { |&hook| exit_hooks << hook }
      %i[create_kiosk ensure_markup refill_kiosk withdraw_kiosk].each { |step| allow(instance).to receive(step) }
      allow(instance).to receive(:gather_report).and_return(report)
      instance.send(:initialize)
      instance
    end

    it 'exits with a message for a character who is not a Trader' do
      DRStats.guild = 'Empath'
      expect(DRC).to receive(:message).with(/Must be a Trader/)
      expect { run_initialize }.to raise_error(SystemExit)
    end

    ['', '   ', nil].each do |blank|
      it "exits with a message when bank_town is #{blank.inspect}" do
        kiosk_settings['bank_town'] = blank
        expect(DRC).to receive(:message).with(/bank_town is required/)
        expect { run_initialize }.to raise_error(SystemExit)
      end
    end

    it 'casts, reads the report, then fixes markup, refills and withdraws from that report, and stows the tessera' do
      instance = Kiosk.allocate
      expect(instance).to receive(:create_kiosk).ordered
      expect(instance).to receive(:gather_report).ordered.and_return(report)
      expect(instance).to receive(:ensure_markup).with(15).ordered
      expect(instance).to receive(:refill_kiosk).with(1).ordered
      expect(instance).to receive(:withdraw_kiosk).with(2, 3).ordered
      expect(DRCI).to receive(:put_away_item?).with('tessera').ordered

      instance.send(:initialize)
    end

    it 'exits naming every setting a partial kiosk_settings block leaves out' do
      # A kiosk_settings block in a character file replaces base.yaml's whole block.
      settings.kiosk_settings = { 'bank_town' => 'Crossing', 'markup' => 20 }
      expect(DRC).to receive(:message)
        .with(/missing cast_room, target_deposit, minimum_refill, minimum_pouch_withdrawal, minimum_bundle_withdrawal/)
      expect { run_initialize }.to raise_error(SystemExit)
    end

    it 'accepts a block that leaves out only the optional settings' do
      %w[markup debug kiosk_noun].each { |optional| kiosk_settings.delete(optional) }
      expect { run_initialize }.not_to raise_error
    end

    it 'exits with the bank_town message when kiosk_settings is empty' do
      settings.kiosk_settings = nil
      expect(DRC).to receive(:message).with(/bank_town is required/)
      expect { run_initialize }.to raise_error(SystemExit)
    end

    describe 'cleanup when the script ends' do
      it 'puts the tessera away if it is still in hand, e.g. after an early exit' do
        run_initialize
        allow(DRCI).to receive(:in_hands?).with('tessera').and_return(true)
        expect(DRCI).to receive(:put_away_item?).with('tessera')
        exit_hooks.each(&:call)
      end

      it 'leaves the tessera alone once it has been put away' do
        run_initialize
        allow(DRCI).to receive(:in_hands?).with('tessera').and_return(false)
        expect(DRCI).not_to receive(:put_away_item?)
        exit_hooks.each(&:call)
      end

      it 'removes the kiosk-desc flag' do
        run_initialize
        exit_hooks.each(&:call)
        expect(Flags.matchers).not_to have_key('kiosk-desc')
      end
    end

    it 'falls back to the noun "kiosk" when kiosk_noun is unset' do
      kiosk_settings.delete('kiosk_noun')
      expect(run_initialize.instance_variable_get(:@kiosk_noun)).to eq('kiosk')
    end

    describe 'the kiosk-desc flag that captures the kiosk long name' do
      let(:matcher) do
        run_initialize
        Flags.matchers['kiosk-desc'].first
      end

      it 'captures the long name from the real cast message' do
        expect(matcher.match(KIOSK_PRIA_CAST_MESSAGE)[1]).to eq('jaggedly dendritic crystalline kiosk')
      end

      it 'captures the long name from the real refresh message' do
        expect(matcher.match(KIOSK_REFRESH_MESSAGE)[2]).to eq('vitreous crystalline kiosk')
      end

      it 'captures the long name from the real PERCEIVE line, typo and all' do
        expect(matcher.match(KIOSK_PERCEIVE_MESSAGE)[3]).to eq('monoclinic crystalline kiosk')
      end

      it 'still captures it once the game corrects the spell name' do
        corrected = KIOSK_PERCEIVE_MESSAGE.sub('Properity in Abstentia', 'Prosperity in Absentia')
        expect(matcher.match(corrected)[3]).to eq('monoclinic crystalline kiosk')
      end

      it "stops the PERCEIVE capture at the kiosk, not at the deployment room's comma" do
        expect(matcher.match(KIOSK_PERCEIVE_MESSAGE)[3]).not_to include('Grisgonda')
      end

      it 'keeps an "and" inside the long name, for identify_my_kiosk to trim' do
        line = KIOSK_PRIA_CAST_MESSAGE.sub('jaggedly dendritic', 'spindly and acicular')
        expect(matcher.match(line)[1]).to eq('spindly and acicular crystalline kiosk')
      end

      it "ignores someone else's kiosk being looked at" do
        expect(matcher.match('You see a jaggedly dendritic crystalline kiosk.')).to be_nil
      end
    end
  end

  describe '#target_markup' do
    {
      0     => 0,
      60    => 60,
      0.6   => 60,  # a fraction is read as a percentage
      0.05  => 5,
      -0.05 => -5,
      '45'  => 45,  # YAML can hand over a string
      38    => 35,  # rounds down, never up
      39.9  => 35,
      -7    => -10, # rounds down, so a negative markup moves away from zero
      1     => 0,   # 1 is a whole percentage, not 100%
      100   => 80,  # the game's ceiling
      0.95  => 80,
      -50   => -10, # the game's floor
      nil   => 0
    }.each do |setting, expected|
      it "turns a markup setting of #{setting.inspect} into #{expected}" do
        kiosk_settings['markup'] = setting
        expect(build_kiosk.target_markup).to eq(expected)
      end
    end

    it 'always returns a multiple of 5 inside -10..80' do
      (-200..200).step(0.37).each do |raw|
        kiosk_settings['markup'] = raw
        result = build_kiosk.target_markup
        expect(result % 5).to eq(0), "markup #{raw} gave #{result}"
        expect(result).to be_between(-10, 80)
      end
    end
  end

  describe '#ensure_markup' do
    subject(:kiosk) { build_kiosk(my_kiosk: 'first kiosk') }

    before { kiosk_settings['markup'] = 25 }

    # A kiosk whose markup moves 5 points per PULL/PUSH, the way the game steps it.
    #
    # @param start [Integer] the kiosk's markup before the first command
    # @return [void]
    def kiosk_markup_starts_at(start)
      markup = start
      game_replies do |command|
        markup += 5 if command.start_with?('pull')
        markup -= 5 if command.start_with?('push')
        "You adjust the kiosk.  The markup is now set to #{markup}%."
      end
    end

    it 'leaves the kiosk alone when the markup setting is absent' do
      kiosk_settings.delete('markup')
      expect(DRCT).not_to receive(:walk_to)
      kiosk.ensure_markup(40)
      expect(commands).to be_empty
    end

    it 'still enforces a markup setting of 0, which Ruby treats as set' do
      kiosk_settings['markup'] = 0
      kiosk_markup_starts_at(10)
      kiosk.ensure_markup(10)
      expect(commands).to eq(['push first kiosk', 'push first kiosk'])
    end

    it 'warns and changes nothing when the report had no markup line' do
      expect(DRC).to receive(:message).with(/Couldn't read the markup/)
      expect(DRCT).not_to receive(:walk_to)
      kiosk.ensure_markup(nil)
      expect(commands).to be_empty
    end

    it 'sends nothing when the kiosk already has the target markup' do
      expect(DRCT).not_to receive(:walk_to)
      kiosk.ensure_markup(25)
      expect(commands).to be_empty
    end

    it 'pulls one step at a time up to the target' do
      kiosk_markup_starts_at(0)
      kiosk.ensure_markup(0)
      expect(commands).to eq(['pull first kiosk'] * 5)
    end

    it 'pushes down to a negative target' do
      kiosk_settings['markup'] = -10
      kiosk_markup_starts_at(15)
      kiosk.ensure_markup(15)
      expect(commands).to eq(['push first kiosk'] * 5)
    end

    it 'trusts the markup the game reports over its own count' do
      replies = ['The markup is now set to 20%.', 'The markup is now set to 25%.']
      game_replies { |_command| replies.shift }
      kiosk.ensure_markup(0) # the report said 0, the kiosk was really at 15
      expect(commands).to eq(['pull first kiosk', 'pull first kiosk'])
    end

    it 'walks to the kiosk before adjusting it' do
      kiosk_markup_starts_at(20)
      expect(DRCT).to receive(:walk_to).with(kiosk_settings['cast_room']).ordered
      kiosk.ensure_markup(20)
    end

    it 'finds the kiosk first when it has not been identified yet' do
      instance = build_kiosk
      expect(instance).to receive(:require_my_kiosk).with(no_args).and_return('third kiosk')
      kiosk_markup_starts_at(20)
      instance.ensure_markup(20)
      expect(commands).to eq(['pull third kiosk'])
    end

    it 're-finds the kiosk when its ordinal shifted, then repeats the same step on it' do
      markup = 20
      game_replies do |command|
        next KIOSK_NOT_OWNER if command == 'pull first kiosk'

        markup += 5
        "The markup is now set to #{markup}%."
      end
      expect(kiosk).to receive(:require_my_kiosk).with(true).and_return('second kiosk')
      kiosk.ensure_markup(20)
      expect(commands).to eq(['pull first kiosk', 'pull second kiosk'])
    end

    it 'exits instead of retrying forever when the kiosk cannot be re-found' do
      game_replies { |_command| KIOSK_NOT_OWNER }
      expect(kiosk).to receive(:identify_my_kiosk).with(true).and_return(nil)
      expect { kiosk.ensure_markup(20) }.to raise_error(SystemExit)
      expect(commands).to eq(['pull first kiosk'])
    end

    # Without the guard this loops for good under Lich: its NilClass patch turns
    # the failed match into nil, nil[1] into nil and nil.to_i into 0.
    it 'stops when the markup stops moving, e.g. at a cap below the target' do
      kiosk_settings['markup'] = 80
      game_replies { |_command| 'The markup is now set to 50%.' }
      expect(DRC).to receive(:message).with(/went from 50% to 50% instead of toward 80%/)
      kiosk.ensure_markup(45)
      expect(commands).to eq(['pull first kiosk', 'pull first kiosk'])
    end

    it 'stops instead of see-sawing when a step overshoots the target' do
      markup = 20
      game_replies do |command|
        markup += command.start_with?('pull') ? 10 : -10
        "The markup is now set to #{markup}%."
      end
      expect(DRC).to receive(:message).with(/went from 20% to 30% instead of toward 25%/)
      kiosk.ensure_markup(20)
      expect(commands).to eq(['pull first kiosk'])
    end

    it 'stops with a message when the kiosk stops answering (e.g. it expired mid-run)' do
      game_replies { |_command| KIOSK_NOT_FOUND }
      expect(DRC).to receive(:message).with(/didn't answer PULL, so I'm leaving the markup at 20%/)
      kiosk.ensure_markup(20)
      expect(commands).to eq(['pull first kiosk'])
    end
  end

  describe '#identify_my_kiosk' do
    subject(:kiosk) { build_kiosk }

    # The game for a room where only the named kiosks are ours.
    #
    # @param ours [Array<String>] "ordinal kiosk" names we own
    # @return [void]
    def we_own(*ours)
      mode = 'pouch'
      game_replies do |command|
        target = command.delete_prefix('rub ')
        next KIOSK_NOT_OWNER unless ours.include?(target)

        mode = mode == 'pouch' ? 'bundle' : 'pouch'
        mode == 'pouch' ? KIOSK_RUB_TO_POUCH : KIOSK_RUB_TO_BUNDLE
      end
    end

    it 'returns the kiosk it already found without touching the game' do
      cached = build_kiosk(my_kiosk: 'second kiosk')
      expect(DRCT).not_to receive(:walk_to)
      expect(cached.identify_my_kiosk).to eq('second kiosk')
      expect(commands).to be_empty
    end

    it 'searches again when forced, even with a kiosk on record' do
      room_holds('jaggedly dendritic crystalline kiosk')
      we_own('first kiosk')
      expect(build_kiosk(my_kiosk: 'second kiosk').identify_my_kiosk(true)).to eq('first kiosk')
    end

    it 'casts a kiosk first when PRIA is not up' do
      pria_active(nil)
      expect(kiosk).to receive(:create_kiosk) { pria_active(180) }
      kiosk.identify_my_kiosk
    end

    it 'walks to cast_room before reading the room' do
      expect(DRCT).to receive(:walk_to).with(kiosk_settings['cast_room'])
      kiosk.identify_my_kiosk
    end

    it 'learns the long name from the flag and clears the flag' do
      Flags.add('kiosk-desc', /, an? (.+?) unfolds from nothingness/)
      Flags['kiosk-desc'] = KIOSK_PRIA_CAST_MESSAGE.match(Flags.matchers['kiosk-desc'].first)
      room_holds('jaggedly dendritic crystalline kiosk')
      we_own('first kiosk')

      kiosk.identify_my_kiosk

      expect(SessionVars.kiosk_name).to eq('jaggedly dendritic crystalline kiosk')
      expect(Flags['kiosk-desc']).to be(false)
    end

    it 'counts the ordinal among kiosks only, skipping other room objects' do
      SessionVars.kiosk_name = 'jaggedly dendritic crystalline kiosk'
      room_holds('wooden bench', 'heptagonally symmetrical crystalline kiosk', 'Trader Ilsa', 'jaggedly dendritic crystalline kiosk')
      we_own('second kiosk')
      expect(kiosk.identify_my_kiosk).to eq('second kiosk')
    end

    it 'only tries kiosks with our long name when it is known' do
      SessionVars.kiosk_name = 'jaggedly dendritic crystalline kiosk'
      room_holds('heptagonally symmetrical crystalline kiosk', 'jaggedly dendritic crystalline kiosk', 'jaggedly dendritic crystalline kiosk')
      we_own('third kiosk')

      expect(kiosk.identify_my_kiosk).to eq('third kiosk')
      expect(commands).not_to include('rub first kiosk')
    end

    it 'tries every kiosk in order when the long name is not known' do
      room_holds('heptagonally symmetrical crystalline kiosk', 'jaggedly dendritic crystalline kiosk')
      we_own('second kiosk')
      expect(kiosk.identify_my_kiosk).to eq('second kiosk')
      expect(commands.first).to eq('rub first kiosk')
    end

    it 'matches a long name containing "and" against the half the room parser keeps' do
      SessionVars.kiosk_name = 'spindly and acicular crystalline kiosk'
      room_holds('spindly', 'acicular crystalline kiosk')
      we_own('first kiosk')
      expect(kiosk.identify_my_kiosk).to eq('first kiosk')
    end

    it 'rubs our kiosk twice so its payout mode ends where it started' do
      room_holds('jaggedly dendritic crystalline kiosk')
      we_own('first kiosk')
      kiosk.identify_my_kiosk
      expect(commands).to eq(['rub first kiosk', 'rub first kiosk'])
    end

    it "rubs someone else's kiosk only once" do
      room_holds('heptagonally symmetrical crystalline kiosk', 'jaggedly dendritic crystalline kiosk')
      we_own('second kiosk')
      kiosk.identify_my_kiosk
      expect(commands.count('rub first kiosk')).to eq(1)
    end

    it "returns nil when the only kiosk in the room is someone else's" do
      room_holds('jaggedly dendritic crystalline kiosk')
      we_own
      expect(kiosk.identify_my_kiosk).to be_nil
    end

    it 'returns nil without a command when no kiosk matches' do
      SessionVars.kiosk_name = 'jaggedly dendritic crystalline kiosk'
      room_holds('heptagonally symmetrical crystalline kiosk', 'wooden bench')
      expect(kiosk.identify_my_kiosk).to be_nil
      expect(commands).to be_empty
    end

    it 'uses a customised kiosk noun for both matching and ordinals' do
      kiosk_settings['kiosk_noun'] = 'booth'
      room_holds('crystalline kiosk', 'gilded crystalline booth')
      we_own('first booth')
      expect(build_kiosk.identify_my_kiosk).to eq('first booth')
    end

    it 'does not claim a kiosk that never answered the rub' do
      room_holds('jaggedly dendritic crystalline kiosk')
      game_replies { |_command| KIOSK_NOT_FOUND }
      expect(kiosk.identify_my_kiosk).to be_nil
    end
  end

  describe '#require_my_kiosk' do
    subject(:kiosk) { build_kiosk }

    it 'returns the kiosk identify_my_kiosk found' do
      allow(kiosk).to receive(:identify_my_kiosk).with(false).and_return('second kiosk')
      expect(kiosk.require_my_kiosk).to eq('second kiosk')
    end

    it 'passes force through' do
      expect(kiosk).to receive(:identify_my_kiosk).with(true).and_return('first kiosk')
      kiosk.require_my_kiosk(true)
    end

    it 'exits with a message naming cast_room when no kiosk is ours' do
      allow(kiosk).to receive(:identify_my_kiosk).and_return(nil)
      expect(DRC).to receive(:message).with(/in room #{kiosk_settings['cast_room']}/)
      expect { kiosk.require_my_kiosk }.to raise_error(SystemExit)
    end
  end

  describe '#create_kiosk' do
    subject(:kiosk) { build_kiosk(my_kiosk: 'second kiosk') }

    before { allow(DRCA).to receive(:do_buffs) { pria_active(180) } }

    it 'does nothing while PRIA has more than recast minutes left' do
      pria_active(2)
      expect(DRCT).not_to receive(:walk_to)
      expect(DRCA).not_to receive(:do_buffs)
      kiosk.create_kiosk
    end

    it 'refreshes at exactly recast minutes, keeping the kiosk on record' do
      pria_active(1)
      expect(DRCA).to receive(:do_buffs).with(settings, 'kiosk')
      kiosk.create_kiosk
      expect(kiosk.instance_variable_get(:@my_kiosk)).to eq('second kiosk')
    end

    it 'casts a new kiosk when PRIA is down, forgetting the old one' do
      pria_active(nil)
      kiosk.create_kiosk
      expect(kiosk.instance_variable_get(:@my_kiosk)).to be_nil
    end

    it "forgets the old kiosk's long name on a new cast, so a missed announcement can't hide the new one" do
      pria_active(nil)
      SessionVars.kiosk_name = 'vitreous crystalline kiosk'
      kiosk.create_kiosk
      expect(SessionVars.kiosk_name).to be_nil
    end

    it 'keeps the long name on a refresh, which is the same kiosk' do
      pria_active(1)
      SessionVars.kiosk_name = 'vitreous crystalline kiosk'
      kiosk.create_kiosk
      expect(SessionVars.kiosk_name).to eq('vitreous crystalline kiosk')
    end

    it 'recasts after a failed attempt even with PRIA up' do
      failed = build_kiosk(failed_attempt: true)
      expect(DRCA).to receive(:do_buffs)
      failed.create_kiosk
    end

    it 'goes to cast_room, takes out the tessera, clears the flag, casts, then perceives' do
      pria_active(nil)
      Flags.add('kiosk-desc', /x/)
      Flags['kiosk-desc'] = 'a stale match from an earlier cast'
      expect(DRCT).to receive(:walk_to).with(kiosk_settings['cast_room']).ordered
      expect(DRCI).to receive(:get_item_if_not_held?).with('tessera').ordered
      expect(DRCA).to receive(:do_buffs).ordered do
        expect(Flags['kiosk-desc']).to be(false)
        pria_active(180)
      end

      kiosk.create_kiosk

      expect(fput_commands).to eq(['perceive self'])
    end

    it 'exits with a message when the cast did not take' do
      pria_active(nil)
      allow(DRCA).to receive(:do_buffs)
      expect(DRC).to receive(:message).with(/Unable to cast Prosperity in Absentia/)
      expect { kiosk.create_kiosk }.to raise_error(SystemExit)
    end
  end

  describe '#parse_coins' do
    subject(:kiosk) { build_kiosk }

    before { real_coin_values }

    it 'adds every denomination of the real on-hand line into coppers' do
      line = '  It has a total of 575 platinum, 8 gold, 8 silver, 5 bronze, and 5 copper Kronars on hand for purchases.'
      expect(kiosk.parse_coins(line)).to eq(5_758_855)
    end

    it 'reads amounts with thousands separators' do
      expect(kiosk.parse_coins('  1,250 platinum, 6 gold, 8 silver, 5 bronze, and 3 copper Kronars in pouches.')).to eq(12_506_853)
    end

    it 'ignores case in the denomination' do
      expect(kiosk.parse_coins('3 Platinum and 4 GOLD')).to eq(34_000)
    end

    it 'is zero for a "No Kronars" line' do
      expect(kiosk.parse_coins('No Kronars in pouches.')).to eq(0)
    end

    it 'is zero for a missing line' do
      expect(kiosk.parse_coins(nil)).to eq(0)
    end

    it 'is zero for a line with no coins in it' do
      expect(kiosk.parse_coins('Kronars on hand:')).to eq(0)
    end
  end

  describe '#gather_report' do
    subject(:kiosk) { build_kiosk }

    before do
      real_coin_values
      allow(Lich::Util).to receive(:issue_command).and_return(KIOSK_REPORT.dup)
    end

    it 'asks the tessera for its report between the start and end lines, without XML' do
      expect(Lich::Util).to receive(:issue_command).with(
        'ask my tessera about report', /key sales data:$/, /The floating data fades with a friendly chime/, usexml: false
      ).and_return(KIOSK_REPORT.dup)
      kiosk.gather_report
    end

    it 'gets the tessera in hand first' do
      expect(DRCI).to receive(:get_item_if_not_held?).with('tessera').ordered.and_return(true)
      expect(Lich::Util).to receive(:issue_command).ordered.and_return(KIOSK_REPORT.dup)
      kiosk.gather_report
    end

    it 'reads holdings from the holdings section, not the session purchases above it' do
      expect(kiosk.gather_report).to include(
        'on_hand_amount' => 5_758_855,
        'pouch_amount'   => 776_853,
        'bundle_amount'  => 0
      )
    end

    it 'reads the markup as an Integer' do
      expect(kiosk.gather_report['markup']).to eq(55)
    end

    it 'reads a negative markup' do
      report = KIOSK_REPORT.map { |line| line.sub('set to 55%', 'set to -10%') }
      allow(Lich::Util).to receive(:issue_command).and_return(report)
      expect(kiosk.gather_report['markup']).to eq(-10)
    end

    it 'reports no markup, rather than 0, when the line is missing' do
      allow(Lich::Util).to receive(:issue_command).and_return(KIOSK_REPORT.grep_v(/markup/))
      expect(kiosk.gather_report['markup']).to be_nil
    end

    it 'reads the bundle holdings, not the empty session line above them' do
      report = KIOSK_REPORT.dup
      report[report.rindex('  No Kronars in bundles.')] = '  60 platinum, 4 gold, 2 silver, 1 bronze, and 9 copper Kronars in bundles.'
      allow(Lich::Util).to receive(:issue_command).and_return(report)
      expect(kiosk.gather_report['bundle_amount']).to eq(604_219)
    end

    it "exits without asking when the tessera can't be got in hand" do
      allow(DRCI).to receive(:get_item_if_not_held?).with('tessera').and_return(false)
      expect(DRC).to receive(:message).with(/Couldn't get your tessera in hand/)
      expect(Lich::Util).not_to receive(:issue_command)
      expect { kiosk.gather_report }.to raise_error(SystemExit)
    end

    context 'when the tessera gives no report' do
      before { allow(kiosk).to receive(:create_kiosk) }

      it 'asks once more before releasing a working kiosk over one missed reply' do
        allow(Lich::Util).to receive(:issue_command).and_return([], KIOSK_REPORT.dup)
        expect(kiosk).not_to receive(:create_kiosk)

        expect(kiosk.gather_report['markup']).to eq(55)
        expect(fput_commands).not_to include('release PRIA')
      end

      it 'treats a report cut off before its end line as missing, not as an empty kiosk' do
        allow(Lich::Util).to receive(:issue_command).and_return(KIOSK_REPORT.first(6), KIOSK_REPORT.dup)
        expect(kiosk.gather_report['on_hand_amount']).to eq(5_758_855)
        expect(fput_commands).not_to include('release PRIA')
      end

      it 'releases PRIA and recasts after two missed replies, then reads the new kiosk' do
        allow(Lich::Util).to receive(:issue_command).and_return([], [], KIOSK_REPORT.dup)
        expect(kiosk).to receive(:create_kiosk).once

        expect(kiosk.gather_report['markup']).to eq(55)
        expect(fput_commands).to eq(['release PRIA', 'perceive self'])
      end

      it 'exits when the recast kiosk gives no report either, having released PRIA only once' do
        allow(Lich::Util).to receive(:issue_command).and_return([])
        expect(DRC).to receive(:message).with(/Unable to gather a report/)

        expect { kiosk.gather_report }.to raise_error(SystemExit)
        expect(fput_commands.count('release PRIA')).to eq(1)
        expect(Lich::Util).to have_received(:issue_command).exactly(4).times
      end
    end
  end

  describe '#find_kiosk_bank' do
    it "describes bank_town's exchange from the town data" do
      expect(build_kiosk.find_kiosk_bank).to eq(
        'town' => 'Crossing', 'id' => 1902, 'fee' => 0.05, 'currency' => 'kronars'
      )
    end

    it 'resolves a short town name through DRC.get_town_name' do
      kiosk_settings['bank_town'] = ' riverhaven '
      expect(DRC).to receive(:get_town_name).with('riverhaven').and_return('Riverhaven')
      expect(build_kiosk.find_kiosk_bank).to include('town' => 'Riverhaven', 'currency' => 'lirums', 'fee' => 0.07)
    end

    it 'uses the name as written when get_town_name does not know it' do
      kiosk_settings['bank_town'] = 'Shard'
      allow(DRC).to receive(:get_town_name).and_return(nil)
      expect(build_kiosk.find_kiosk_bank).to include('town' => 'Shard', 'currency' => 'dokoras')
    end

    it 'exits with a message for a town it does not know' do
      kiosk_settings['bank_town'] = 'Atlantis'
      allow(DRC).to receive(:get_town_name).and_return(nil)
      expect(DRC).to receive(:message).with(/bank_town 'Atlantis' isn't a recognized town/)
      expect { build_kiosk.find_kiosk_bank }.to raise_error(SystemExit)
    end
  end

  describe '#ensure_kronars_on_hand' do
    subject(:kiosk) { build_kiosk }

    before { allow(DRCM).to receive(:check_wealth).with('Kronars').and_return(1_000_000) }

    it 'is true without a bank trip when enough Kronars are already carried' do
      expect(DRCM).not_to receive(:ensure_copper_on_hand)
      expect(DRCT).not_to receive(:walk_to)
      expect(kiosk.ensure_kronars_on_hand(1_000_000)).to be(true)
    end

    context 'with a Kronar bank_town' do
      [true, false].each do |withdrew|
        it "returns #{withdrew} when the withdrawal #{withdrew ? 'works' : 'fails'}" do
          expect(DRCM).to receive(:ensure_copper_on_hand).with(5_000_000, settings, 'Crossing').and_return(withdrew)
          expect(kiosk.ensure_kronars_on_hand(5_000_000)).to be(withdrew)
        end
      end
    end

    context 'with a lirum bank_town' do
      before do
        kiosk_settings['bank_town'] = 'Riverhaven'
        allow(DRCM).to receive(:convert_currency).and_return(123_456)
        game_replies { |_command| 'After collecting a modest fee, the money-changer hands you your Kronars.' }
      end

      it "asks for enough lirums to cover what's missing after Riverhaven's fee" do
        expect(DRCM).to receive(:convert_currency).with(4_000_000, 'lirums', 'kronars', -0.07).and_return(123_456)
        kiosk.ensure_kronars_on_hand(5_000_000)
      end

      it 'withdraws platinum and the rest as copper, in lirums, from Riverhaven' do
        expect(DRCM).to receive(:withdraw_exact_amount?).with('12 platinum lirums', settings, 'Riverhaven').ordered.and_return(true)
        expect(DRCM).to receive(:withdraw_exact_amount?).with('3456 copper lirums', settings, 'Riverhaven').ordered.and_return(true)
        kiosk.ensure_kronars_on_hand(5_000_000)
      end

      it 'exchanges exactly what it withdrew at the Riverhaven exchange, then reports success' do
        expect(DRCT).to receive(:walk_to).with(7954)
        expect(kiosk.ensure_kronars_on_hand(5_000_000)).to be(true)
        expect(commands).to eq(['exchange 12 platinum lirums to Kronars', 'exchange 3456 copper lirums to Kronars'])
      end

      it 'leaves out a zero copper part' do
        allow(DRCM).to receive(:convert_currency).and_return(120_000)
        kiosk.ensure_kronars_on_hand(5_000_000)
        expect(commands).to eq(['exchange 12 platinum lirums to Kronars'])
      end

      it 'leaves out a zero platinum part' do
        allow(DRCM).to receive(:convert_currency).and_return(9_999)
        kiosk.ensure_kronars_on_hand(5_000_000)
        expect(commands).to eq(['exchange 9999 copper lirums to Kronars'])
      end

      it 'exits without exchanging when a withdrawal fails' do
        allow(DRCM).to receive(:withdraw_exact_amount?).and_return(true, false)
        expect(DRC).to receive(:message).with(/Failed to withdraw/)
        expect { kiosk.ensure_kronars_on_hand(5_000_000) }.to raise_error(SystemExit)
        expect(commands).to be_empty
      end

      it 'stops withdrawing at the first failure' do
        expect(DRCM).to receive(:withdraw_exact_amount?).once.and_return(false)
        expect { kiosk.ensure_kronars_on_hand(5_000_000) }.to raise_error(SystemExit)
      end

      it "exits when the money-changer says we don't have that many" do
        game_replies { |_command| "You don't have that many lirums." }
        expect(DRC).to receive(:message).with(/out of money/)
        expect { kiosk.ensure_kronars_on_hand(5_000_000) }.to raise_error(SystemExit)
        expect(commands.size).to eq(1)
      end
    end
  end

  describe '#refill_kiosk' do
    subject(:kiosk) { build_kiosk(my_kiosk: 'first kiosk') }

    before do
      allow(kiosk).to receive(:ensure_kronars_on_hand).and_return(true)
      game_replies { |_command| 'The tessera swiftly rearranges itself as you poke the kiosk.' }
    end

    it 'does nothing at or above minimum_refill' do
      expect(kiosk).not_to receive(:ensure_kronars_on_hand)
      kiosk.refill_kiosk(kiosk_settings['minimum_refill'])
      expect(commands).to be_empty
    end

    it 'fetches the shortfall to target_deposit, then pokes the kiosk twice' do
      expect(kiosk).to receive(:ensure_kronars_on_hand).with(kiosk_settings['target_deposit'] - 1_000).and_return(true)
      kiosk.refill_kiosk(1_000)
      expect(commands).to eq(['poke first kiosk', 'poke first kiosk'])
    end

    it 'warns and skips the deposit when the Kronars could not be fetched' do
      allow(kiosk).to receive(:ensure_kronars_on_hand).and_return(false)
      expect(DRC).to receive(:message).with(/Couldn't get enough Kronars.*Crossing/)
      expect(DRCT).not_to receive(:walk_to)
      kiosk.refill_kiosk(0)
      expect(commands).to be_empty
    end

    it 'treats a nil from ensure_kronars_on_hand as a failure' do
      allow(kiosk).to receive(:ensure_kronars_on_hand).and_return(nil)
      kiosk.refill_kiosk(0)
      expect(commands).to be_empty
    end

    it 'finds the kiosk first when it has not been identified yet' do
      instance = build_kiosk
      allow(instance).to receive(:ensure_kronars_on_hand).and_return(true)
      expect(instance).to receive(:require_my_kiosk).with(no_args).and_return('third kiosk')
      instance.refill_kiosk(0)
      expect(commands).to eq(['poke third kiosk', 'poke third kiosk'])
    end

    it 're-finds the kiosk when its ordinal shifted and pokes the new one twice' do
      game_replies { |command| command == 'poke first kiosk' ? KIOSK_NOT_OWNER : 'pulses with soft light and chimes merrily' }
      expect(kiosk).to receive(:require_my_kiosk).with(true).and_return('second kiosk')
      kiosk.refill_kiosk(0)
      expect(commands).to eq(['poke first kiosk', 'poke second kiosk', 'poke second kiosk'])
    end

    it "exits instead of poking forever when the only kiosk left is someone else's" do
      room_holds('jaggedly dendritic crystalline kiosk')
      game_replies { |_command| KIOSK_NOT_OWNER }
      expect { kiosk.refill_kiosk(0) }.to raise_error(SystemExit)
      expect(commands.count { |command| command.start_with?('poke') }).to eq(1)
    end

    it 'sends two pokes and stops when the kiosk does not answer' do
      game_replies { |_command| KIOSK_NOT_FOUND }
      kiosk.refill_kiosk(0)
      expect(commands).to eq(['poke first kiosk', 'poke first kiosk'])
    end
  end

  describe '#withdraw_kiosk' do
    subject(:kiosk) { build_kiosk(my_kiosk: 'first kiosk') }

    let(:pouch_minimum) { kiosk_settings['minimum_pouch_withdrawal'] }
    let(:bundle_minimum) { kiosk_settings['minimum_bundle_withdrawal'] }

    # Our kiosk: RUB flips the payout mode, TAP pays out.
    #
    # @param mode [String] 'pouch' or 'bundle', the payout mode before the first rub
    # @return [void]
    def kiosk_pays_out(mode)
      game_replies do |command|
        if command.start_with?('rub')
          mode = mode == 'pouch' ? 'bundle' : 'pouch'
          mode == 'pouch' ? KIOSK_RUB_TO_POUCH : KIOSK_RUB_TO_BUNDLE
        elsif command.start_with?('tap')
          "A crystalline gem pouch drops into your hand.  The sale has been processed and recorded to your tessera-ledger.  (#{mode})"
        end
      end
    end

    it 'does nothing below both minimums' do
      expect(DRCT).not_to receive(:walk_to)
      kiosk.withdraw_kiosk(pouch_minimum - 1, bundle_minimum - 1)
      expect(commands).to be_empty
    end

    it 'takes the pouch at exactly the minimum, switching the payout to pouches first' do
      kiosk_pays_out('pouch')
      expect(DRCI).to receive(:put_away_item?).with('gem pouch', 'haversack')
      kiosk.withdraw_kiosk(pouch_minimum, 0)
      expect(commands).to eq(['rub first kiosk', 'rub first kiosk', 'tap first kiosk'])
    end

    it 'takes the bundle when only bundles are over the minimum' do
      kiosk_pays_out('pouch')
      expect(DRCI).to receive(:put_away_item?).with('bundle', 'haversack')
      kiosk.withdraw_kiosk(0, bundle_minimum)
      expect(commands).to eq(['rub first kiosk', 'tap first kiosk'])
    end

    it 'takes the pouch, then the bundle' do
      kiosk_pays_out('bundle')
      expect(DRCI).to receive(:put_away_item?).with('gem pouch', 'haversack').ordered
      expect(DRCI).to receive(:put_away_item?).with('bundle', 'haversack').ordered
      kiosk.withdraw_kiosk(pouch_minimum, bundle_minimum)
      expect(commands).to eq(['rub first kiosk', 'tap first kiosk', 'rub first kiosk', 'tap first kiosk'])
    end

    it 'finds the kiosk first when it has not been identified yet' do
      instance = build_kiosk
      expect(instance).to receive(:require_my_kiosk).with(no_args).and_return('second kiosk')
      kiosk_pays_out('pouch')
      instance.withdraw_kiosk(0, bundle_minimum)
      expect(commands.first).to eq('rub second kiosk')
    end

    it 'does not tap a second pouch when the ordinal shifts during the bundle' do
      mode = 'bundle'
      shifted = false
      game_replies do |command|
        if command == 'rub first kiosk' && mode == 'pouch'
          shifted = true
          next KIOSK_NOT_OWNER
        end
        next 'recorded: been processed and recorded to your tessera-ledger' if command.start_with?('tap')

        mode = mode == 'pouch' ? 'bundle' : 'pouch'
        mode == 'pouch' ? KIOSK_RUB_TO_POUCH : KIOSK_RUB_TO_BUNDLE
      end
      allow(kiosk).to receive(:require_my_kiosk).with(true).and_return('second kiosk')

      kiosk.withdraw_kiosk(pouch_minimum, bundle_minimum)

      expect(shifted).to be(true)
      expect(commands.count { |command| command.start_with?('tap') }).to eq(2)
      expect(commands.last).to eq('tap second kiosk')
    end

    it "exits instead of rubbing forever when the only kiosk left is someone else's" do
      room_holds('jaggedly dendritic crystalline kiosk')
      game_replies { |_command| KIOSK_NOT_OWNER }
      expect { kiosk.withdraw_kiosk(pouch_minimum, 0) }.to raise_error(SystemExit)
      expect(commands.size).to be < runaway_limit
    end

    it 'stops with a message when the kiosk stops answering (e.g. it expired during the bank trip)' do
      game_replies { |_command| KIOSK_NOT_FOUND }
      expect(DRC).to receive(:message).with(/didn't answer RUB/)
      expect(DRCI).not_to receive(:put_away_item?)
      kiosk.withdraw_kiosk(pouch_minimum, bundle_minimum)
      expect(commands).to eq(['rub first kiosk'])
    end
  end

  describe 'kiosk_settings in profiles/base.yaml' do
    it 'sets every key the script reads' do
      script_keys = File.read(File.join(__dir__, '..', 'kiosk.lic')).scan(/@kiosk_settings\['(\w+)'\]/).flatten.uniq
      expect(kiosk_settings.keys).to include(*script_keys)
    end

    it 'passes the bank_town check' do
      expect(kiosk_settings['bank_town'].to_s.strip).not_to be_empty
    end

    it "deposits no more than the kiosk's 1000 platinum limit" do
      expect(kiosk_settings['target_deposit']).to be <= 10_000_000
    end

    it 'refills below the deposit target, so a refill adds coins' do
      expect(kiosk_settings['minimum_refill']).to be < kiosk_settings['target_deposit']
    end
  end
end
