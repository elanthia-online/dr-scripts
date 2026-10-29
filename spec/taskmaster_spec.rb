# frozen_string_literal: true

require 'ostruct'
require 'yaml'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')

RSpec.describe TaskMaster do
  # The script's own stack map, so no example runs against a copy that has
  # drifted from it.
  let(:stackmap) { described_class::STACKMAP }
  let(:base_yaml) { YAML.unsafe_load_file(File.expand_path('../profiles/base.yaml', __dir__)) }

  # Turn-in replies as the game prints them (2025 Hollow Eve logs).
  let(:sack_handed) { 'Seamstress Zasele hands you a woven sack.' }
  let(:missed_give) { "What is it you're trying to give?" }

  before do
    allow(DRC).to receive(:message)
  end

  # A bare instance: initialize runs the whole script, so each example builds
  # one with allocate and injects only the state the method under test reads.
  # settings: becomes @settings; every other keyword sets the ivar of that
  # name, replacing the defaults below. settings is a keyword too, since Ruby
  # would read a braceless settings hash as ivar keywords.
  def build(settings: {}, **ivars)
    tm = described_class.allocate
    { settings: OpenStruct.new(settings), bag: 'duffel bag', bag_items: [], npc: 'zasele', rooms: [16_145], stackmap: stackmap }
      .merge(ivars)
      .each { |name, value| tm.instance_variable_set(:"@#{name}", value) }
    tm
  end

  # Game replies keyed by the start of the command that produces them. A reply
  # may be a lambda, called with the command and its matchers. Any other
  # command gets an empty reply.
  def game(responses)
    allow(DRC).to receive(:bput) do |command, *matchers|
      reply = responses.find { |prefix, _| command.start_with?(prefix) }&.last
      reply.respond_to?(:call) ? reply.call(command, *matchers) : reply.to_s
    end
  end

  # Zasele's task journal entry as TASK prints it (2025 Hollow Eve logs). With
  # no returned count the "So far" sentence is left out, as the game sometimes
  # prints it.
  def journal(item, target, returned = nil)
    entry = "Zasele wanted you to craft #{item} and indicated that #{target} would suffice."
    return entry if returned.nil?

    "#{entry}  So far, you have returned #{returned} to her.  Crafting instructions were provided for this item."
  end

  def more_needed(left)
    "Zasele holds up her fingers indicating #{left} more #{left == 1 ? 'is' : 'are'} needed."
  end

  # The give side of a turn-in of ropes: plays the give replies in order and
  # tracks the hand. A landed give empties it, a missed one leaves the item
  # there. The bag holds `banked` finished items, or any number when nil.
  # Returns the state; :gets counts the items taken out of the bag.
  def giving(responses, banked: nil)
    state = { holding: false, gets: 0 }
    allow(DRCI).to receive(:in_hands?) { state[:holding] }
    allow(DRCI).to receive(:get_item?) do
      next false if banked && state[:gets] >= banked

      state[:gets] += 1
      state[:holding] = true
    end
    game('give my rope to zasele' => lambda do |*|
      reply = responses.shift
      state[:holding] = false unless reply == missed_give
      reply
    end)
    state
  end

  describe 'settings' do
    describe '#configure_loot_filter' do
      it 'registers the slackbot with slack_username only when keepers are reported' do
        tm = build(settings: { task_slack_keepers: true, slack_username: 'someone' })
        expect(tm).to receive(:register_slackbot).with('someone')
        tm.send(:configure_loot_filter)
      end

      it 'leaves the slackbot alone otherwise' do
        tm = build(settings: { slack_username: 'someone' })
        expect(tm).not_to receive(:register_slackbot)
        tm.send(:configure_loot_filter)
      end

      it 'gets task_junk_list as an empty list and task_slack_keepers as false from base.yaml' do
        expect(base_yaml).to include('task_junk_list' => [], 'task_slack_keepers' => false)
      end

      it 'still sorts by the keep list and leaves Slack alone with the base.yaml defaults' do
        tm = build(settings: base_yaml.slice('task_keep_list', 'task_junk_list', 'task_slack_keepers'))
        expect(tm).not_to receive(:register_slackbot)
        tm.send(:configure_loot_filter)
        expect(tm.keeper?('In the woven sack you see a large agonite shard.')).to be(true)
        expect(tm.keeper?('In the woven sack you see some coral dye.')).to be(false)
      end
    end

    describe '#configure_boosts' do
      def boosted(settings = {})
        build(settings: settings).tap { |tm| tm.send(:configure_boosts) }
      end

      it 'uses no boosts by default' do
        tm = boosted
        expect(tm.instance_variable_get(:@boosts)).to eq([])
        expect(tm.instance_variable_get(:@boost)).to be(false)
      end

      it 'keeps task_use_boost meaning the task boost' do
        tm = boosted(task_use_boost: true)
        expect(tm.instance_variable_get(:@boosts)).to eq(['task'])
        expect(tm.instance_variable_get(:@boost)).to be(true)
      end

      it 'reads task_boosts, case-insensitively, without duplicating task' do
        tm = boosted(task_boosts: %w[Task HASTE], task_use_boost: true)
        expect(tm.instance_variable_get(:@boosts)).to eq(%w[task haste])
      end

      it 'keeps both defaults when task_boosts comes from base.yaml' do
        expect(base_yaml).to have_key('task_boosts')
        expect(boosted(task_boosts: base_yaml['task_boosts']).instance_variable_get(:@boosts)).to eq([])
        tm = boosted(task_boosts: base_yaml['task_boosts'], task_use_boost: true)
        expect(tm.instance_variable_get(:@boosts)).to eq(['task'])
        expect(tm.instance_variable_get(:@boost)).to be(true)
      end

      it 'can run haste without the task boost' do
        expect(boosted(task_boosts: ['haste']).instance_variable_get(:@boost)).to be(false)
      end
    end

    describe '#configure_copper' do
      def coppered(settings = {})
        build(settings: settings).tap { |tm| tm.send(:configure_copper) }
      end

      it 'defaults to a 20000 floor and a 110000 target' do
        tm = coppered
        expect(tm.instance_variable_get(:@copper_floor)).to eq(20_000)
        expect(tm.instance_variable_get(:@copper_target)).to eq(110_000)
      end

      it 'reads task_copper_floor and task_copper_target' do
        tm = coppered(task_copper_floor: 30_000, task_copper_target: 150_000)
        expect(tm.instance_variable_get(:@copper_floor)).to eq(30_000)
        expect(tm.instance_variable_get(:@copper_target)).to eq(150_000)
      end

      it 'gets the same floor and target from the base.yaml keys as from its own defaults' do
        expect(base_yaml).to include('task_copper_floor' => 20_000, 'task_copper_target' => 110_000)
        tm = coppered(base_yaml.slice('task_copper_floor', 'task_copper_target'))
        expect(tm.instance_variable_get(:@copper_floor)).to eq(20_000)
        expect(tm.instance_variable_get(:@copper_target)).to eq(110_000)
      end

      it 'never targets less than the floor, which would mean a bank trip every task' do
        expect(coppered(task_copper_floor: 50_000, task_copper_target: 10_000).instance_variable_get(:@copper_target)).to eq(50_000)
      end
    end

    describe '#cooldown_poll_seconds' do
      it 'defaults to 15 seconds' do
        expect(build.cooldown_poll_seconds).to eq(15)
      end

      it 'reads task_cooldown_poll' do
        expect(build(settings: { task_cooldown_poll: 5 }).cooldown_poll_seconds).to eq(5)
      end

      it 'never polls faster than every 3 seconds' do
        expect(build(settings: { task_cooldown_poll: 0 }).cooldown_poll_seconds).to eq(3)
        expect(build(settings: { task_cooldown_poll: -10 }).cooldown_poll_seconds).to eq(3)
      end

      it 'ships the same default in base.yaml' do
        expect(base_yaml['task_cooldown_poll']).to eq(15)
        expect(build(settings: { task_cooldown_poll: base_yaml['task_cooldown_poll'] }).cooldown_poll_seconds).to eq(15)
      end
    end
  end

  describe '#reconcile_hands' do
    let(:outfitting_belt) { { 'name' => 'tailor belt', 'items' => ['sewing needles', 'scissors'] } }

    # Hands as the game described them after Hollow Eve 2025 disconnects.
    # after_sew: the hands once sew has run, which is how the result is judged.
    def reconcile(right:, left:, npc: 'zasele', after_sew: nil)
      tm = build(settings: { outfitting_belt: outfitting_belt }, npc: npc, worn_trashcan: nil, worn_trashcan_verb: nil)
      hands = { right: right, left: left }
      allow(DRC).to receive(:right_hand) { hands[:right] }
      allow(DRC).to receive(:left_hand) { hands[:left] }
      allow(tm).to receive(:sort_sack)
      launched = []
      allow(DRC).to receive(:wait_for_script_to_complete) do |name, args|
        launched << [name, args]
        hands.merge!(after_sew) if after_sew
      end
      # As lich-5 matches a noun string (DRC::Item.from_text + short_regex):
      # no adjective, so the noun alone, /\bnetting/i.
      allow(DRCI).to receive(:in_hands?) { |noun| hands.values.compact.any? { |held| held =~ /\b#{noun}/i } }
      allow(DRCI).to receive(:dispose_trash)
      allow(DRCC).to receive(:stow_crafting_item)
      tm.reconcile_hands
      [tm, launched]
    end

    it 'finishes an unfinished sewn item with sew resume and bags it' do
      _, launched = reconcile(right: 'loimic serrated scissors', left: 'coil of unfinished burlap reinforced rope',
                              after_sew: { right: nil, left: 'coil of burlap reinforced rope' })
      expect(launched).to eq([['sew', %w[resume rope]]])
      expect(DRCC).to have_received(:stow_crafting_item).with('rope', 'duffel bag', nil)
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'finds the unfinished item in either hand' do
      _, launched = reconcile(right: 'wide unfinished rat-pelt leather straps', left: nil)
      expect(launched).to eq([['sew', %w[resume straps]]])
    end

    it 'sorts a reward sack held at start' do
      tm, = reconcile(right: 'woven sack', left: nil)
      expect(tm).to have_received(:sort_sack)
    end

    it 'leaves finished items, tools and empty hands alone' do
      _, launched = reconcile(right: 'slender agonite sewing needles', left: 'burlap reinforced netting')
      expect(launched).to be_empty
      _, launched = reconcile(right: nil, left: nil)
      expect(launched).to be_empty
    end

    it 'does not try to resume knitting, whose work does not show in the hand' do
      _, launched = reconcile(right: 'polished loimic knitting needles', left: nil)
      expect(launched).to be_empty
    end

    it 'only resumes tailoring, never another taskmaster\'s unfinished item' do
      _, launched = reconcile(right: 'unfinished bronze dagger', left: nil, npc: 'poltu')
      expect(launched).to be_empty
    end

    it 'throws away an item sew could not finish, stows the tool and carries on' do
      expect do
        reconcile(right: 'unfinished burlap reinforced netting', left: nil,
                  after_sew: { right: 'unfinished burlap reinforced netting', left: 'slender agonite sewing needles' })
      end.not_to raise_error
      expect(DRCC).not_to have_received(:stow_crafting_item).with('netting', anything, anything)
      expect(DRCI).to have_received(:dispose_trash).with('netting', nil, nil)
      expect(DRCC).to have_received(:stow_crafting_item).with('slender agonite sewing needles', 'duffel bag', outfitting_belt)
      expect(DRC).to have_received(:message).with(/could not finish/)
    end

    it 'bags nothing when the item left the hands during sew' do
      reconcile(right: 'wide unfinished rat-pelt leather straps', left: nil, after_sew: { right: nil, left: nil })
      expect(DRCC).not_to have_received(:stow_crafting_item)
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'leaves an unfinished item not made from the task stock alone, and says so' do
      ['unfinished bronze dagger', 'unfinished silk shirt'].each do |held|
        _, launched = reconcile(right: held, left: nil)
        expect(launched).to be_empty
        expect(DRCI).not_to have_received(:dispose_trash)
        expect(DRCC).not_to have_received(:stow_crafting_item)
        expect(DRC).to have_received(:message).with(/Leaving your #{held} alone/)
      end
    end

    it 'resumes the task piece and leaves the player\'s own unfinished item in the other hand' do
      _, launched = reconcile(right: 'unfinished silk shirt', left: 'coil of unfinished burlap reinforced rope',
                              after_sew: { left: 'coil of burlap reinforced rope' })
      expect(launched).to eq([['sew', %w[resume rope]]])
      expect(DRCC).to have_received(:stow_crafting_item).with('rope', 'duffel bag', nil)
      expect(DRCI).not_to have_received(:dispose_trash)
      expect(DRCC).not_to have_received(:stow_crafting_item).with(/shirt/, anything, anything)
    end
  end

  describe 'before each task' do
    describe '#top_up_copper' do
      def coppered
        build.tap { |tm| tm.send(:configure_copper) }
      end

      before do
        allow(DRCM).to receive(:ensure_copper_on_hand)
      end

      it 'does nothing but check wealth while at or above the floor' do
        tm = coppered
        allow(DRCM).to receive(:wealth).with('Crossing').and_return(20_000)
        expect(tm).not_to receive(:exchange_coins)
        tm.top_up_copper
        expect(DRCM).not_to have_received(:ensure_copper_on_hand)
      end

      it 'exchanges foreign coins and refills to the target once below the floor' do
        tm = coppered
        allow(DRCM).to receive(:wealth).and_return(19_999)
        expect(tm).to receive(:exchange_coins).ordered
        expect(DRCM).to receive(:ensure_copper_on_hand).with(110_000, anything, 'Crossing').ordered
        tm.top_up_copper
      end

      it 'treats an unreadable WEALTH reply (0) as broke and tops up' do
        tm = coppered
        allow(DRCM).to receive(:wealth).and_return(0)
        allow(tm).to receive(:exchange_coins)
        tm.top_up_copper
        expect(DRCM).to have_received(:ensure_copper_on_hand).with(110_000, anything, 'Crossing')
      end

      it 'makes one bank trip across many cheap tasks, not one per task' do
        tm = coppered
        on_hand = 110_000
        allow(DRCM).to receive(:wealth) { on_hand }
        trips = 0
        allow(tm).to receive(:exchange_coins) { trips += 1 }
        allow(DRCM).to receive(:ensure_copper_on_hand) { |amount, *_| on_hand = [on_hand, amount].max }
        14.times do
          tm.top_up_copper
          on_hand -= 8_000 # a typical Zasele task, fee included
        end
        expect(trips).to eq(1)
      end
    end

    describe '#refresh_haste' do
      # Boost replies as the game prints them (2025 Hollow Eve logs).
      let(:activated) { "You've activated the Minor Haste boost for an hour!" }
      let(:no_credits) { "You don't have enough credits for the Minor Haste boost.  You currently have 0 available but need 1." }

      def boosted(settings)
        build(settings: settings).tap { |tm| tm.send(:configure_boosts) }
      end

      def reply_with(text)
        allow(DRC).to receive(:bput).with('boost haste', any_args).and_return(text)
      end

      it 'sends nothing when haste is not configured' do
        tm = boosted(task_boosts: ['task'])
        expect(DRC).not_to receive(:bput)
        tm.refresh_haste
      end

      it 'activates haste and remembers it for an hour' do
        tm = boosted(task_boosts: ['haste'])
        reply_with(activated)
        tm.refresh_haste
        expect(UserVars.taskmaster_haste_expires).to be_within(5).of(Time.now.to_i + 3600)
      end

      it 'does not ask again while the hour is running, even from a new run' do
        UserVars.taskmaster_haste_expires = Time.now.to_i + 1800
        tm = boosted(task_boosts: ['haste'])
        expect(DRC).not_to receive(:bput)
        tm.refresh_haste
      end

      it 'asks again once the hour is up' do
        UserVars.taskmaster_haste_expires = Time.now.to_i - 1
        tm = boosted(task_boosts: ['haste'])
        reply_with(activated)
        tm.refresh_haste
        expect(DRC).to have_received(:bput).with('boost haste', any_args)
      end

      it 'leaves the expiry alone when out of credits, so the next task tries again' do
        tm = boosted(task_boosts: ['haste'])
        reply_with(no_credits)
        tm.refresh_haste
        expect(UserVars.taskmaster_haste_expires).to be_nil
      end

      it 'backs off for ten minutes after any other answer, such as haste already running' do
        tm = boosted(task_boosts: ['haste'])
        # The real wording for an already-running boost is not in the logs; any
        # other reply naming Minor Haste lands here.
        reply_with('You already have an active Minor Haste boost.')
        tm.refresh_haste
        expect(UserVars.taskmaster_haste_expires).to be_within(5).of(Time.now.to_i + 600)
      end

      it 'backs off the same way when the reply never arrives' do
        tm = boosted(task_boosts: ['haste'])
        reply_with('')
        tm.refresh_haste
        expect(UserVars.taskmaster_haste_expires).to be_within(5).of(Time.now.to_i + 600)
      end

      it 'ignores other players mentioning a boost while waiting for the reply' do
        tm = boosted(task_boosts: ['haste'])
        expect(DRC).to receive(:bput).with('boost haste', TaskMaster::HASTE_ACTIVATED, TaskMaster::HASTE_NO_CREDITS, /Minor Haste/).and_return(activated)
        tm.refresh_haste
      end
    end

    describe '#run_before_scripts' do
      def run(entries)
        tm = build(before_scripts: Array(entries))
        ran = []
        allow(DRC).to receive(:wait_for_script_to_complete) { |name, args| ran << [name, args] }
        tm.run_before_scripts
        ran
      end

      it 'runs each script to completion, in order' do
        expect(run(%w[restock buff])).to eq([['restock', []], ['buff', []]])
      end

      it 'passes arguments written after the script name' do
        expect(run(['buff crafting', 'sell-loot skip'])).to eq([['buff', ['crafting']], ['sell-loot', ['skip']]])
      end

      it 'runs nothing when the setting is missing' do
        expect(run(nil)).to eq([])
      end

      it 'runs nothing with the base.yaml default' do
        expect(base_yaml).to have_key('task_before_scripts')
        expect(run(base_yaml['task_before_scripts'])).to eq([])
      end

      it 'skips blank entries instead of starting a script with no name' do
        expect(run(['', '   ', nil, 'restock'])).to eq([['restock', []]])
      end
    end
  end

  describe 'finding the taskmaster' do
    # Zasele's search rooms, in the script's order.
    let(:rooms) { [16_145, 16_146, 16_148, 16_150, 16_153, 16_154, 16_147, 16_276, 16_277, 16_278, 16_290] }

    describe '#search_order' do
      let(:tm) { build }

      it 'keeps the list as it is with no last-seen room' do
        expect(tm.search_order(rooms, nil)).to eq(rooms)
      end

      it 'keeps the list as it is when the last-seen room is not one of the search rooms' do
        expect(tm.search_order(rooms, 12_345)).to eq(rooms)
      end

      it 'starts at the last-seen room and alternates outwards' do
        expect(tm.search_order(rooms, 16_150).first(5)).to eq([16_150, 16_153, 16_148, 16_154, 16_146])
      end

      it 'visits every room exactly once from any starting point' do
        rooms.each do |start|
          expect(tm.search_order(rooms, start)).to match_array(rooms)
        end
      end

      it 'handles the ends of the list' do
        expect(tm.search_order(rooms, rooms.last).first(3)).to eq([16_290, 16_278, 16_277])
        expect(tm.search_order(rooms, rooms.first).first(3)).to eq([16_145, 16_146, 16_148])
      end
    end

    describe '#find_npc' do
      # A small world: walking changes the current room, and Zasele is listed
      # among the NPCs only in her room. Returns the rooms walked to.
      def search(zasele_in:, start_in:)
        tm = build
        here = start_in
        walked = []
        allow(Room).to receive(:current) { OpenStruct.new(id: here) }
        allow(DRRoom).to receive(:npcs) { here == zasele_in ? ['Zasele'] : [] }
        allow(DRCT).to receive(:walk_to) do |room|
          walked << room
          here = room
        end
        tm.find_npc(rooms, 'zasele')
        walked
      end

      it 'remembers where the taskmaster was found' do
        search(zasele_in: 16_276, start_in: 16_936)
        expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_276)
      end

      it 'goes straight back to the last-seen room when she is still there' do
        UserVars.taskmaster_last_seen = { 'zasele' => 16_276 }
        expect(search(zasele_in: 16_276, start_in: 16_936)).to eq([16_276])
      end

      it 'finds her a room or two away from where she was last seen' do
        UserVars.taskmaster_last_seen = { 'zasele' => 16_276 }
        expect(search(zasele_in: 16_154, start_in: 16_936)).to eq([16_276, 16_277, 16_147, 16_278, 16_154])
      end

      it 'searches the whole list in its own order the first time' do
        expect(search(zasele_in: 16_150, start_in: 16_936)).to eq([16_145, 16_146, 16_148, 16_150])
      end

      it 'does not move, and still remembers the room, when she is already here' do
        expect(search(zasele_in: 16_153, start_in: 16_153)).to eq([])
        expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_153)
      end

      it 'keeps the old last-seen room when she cannot be found at all' do
        UserVars.taskmaster_last_seen = { 'zasele' => 16_150 }
        expect(search(zasele_in: 99_999, start_in: 16_936)).to match_array(rooms)
        expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_150)
      end

      it 'remembers each taskmaster separately' do
        UserVars.taskmaster_last_seen = { 'poltu' => 16_290 }
        search(zasele_in: 16_146, start_in: 16_936)
        expect(UserVars.taskmaster_last_seen).to eq('poltu' => 16_290, 'zasele' => 16_146)
      end
    end
  end

  describe 'reading a task' do
    # The rope task's instruction materials line (2025 Hollow Eve logs).
    let(:rope_materials) { '   (1) finished fabric cloth (4 yards)' }

    # An instance that can read a task: the taskmaster is always found.
    def reader(**ivars)
      tm = build(**ivars)
      allow(tm).to receive(:find_npc)
      allow(DRCI).to receive(:stow_hands)
      tm
    end

    describe '#get_task' do
      describe 'accepting a new task' do
        it 'parses it like a resume and puts its instructions in the crafting bag by name' do
          tm = reader
          game('ask zasele for task' => 'You may accept by typing ACCEPT TASK', 'accept task' => 'You can check your progress with the TASK verb',
               'task' => journal('a coil of reinforced cloth rope', 5, 0), 'read my rope instructions' => rope_materials)
          expect(DRCC).to receive(:stow_crafting_item).with('rope instructions', 'duffel bag', nil).ordered
          expect(DRCI).to receive(:stow_hands).ordered

          expect(tm.get_task).to eq(['rope', 5, 4, 'cloth', 'burlap'])
        end
      end

      describe 'while the taskmaster makes you wait' do
        # Waits once, then stops the recursion so only the pause is observed.
        def first_pause(tm, reply)
          allow(DRC).to receive(:bput).and_return(reply)
          pauses = []
          allow(tm).to receive(:pause) do |seconds|
            pauses << seconds
            raise StopIteration
          end
          expect { tm.get_task }.to raise_error(StopIteration)
          pauses.first
        end

        def polling(settings)
          reader(settings: settings, boost: false).tap { |tm| tm.instance_variable_set(:@cooldown_poll, tm.cooldown_poll_seconds) }
        end

        it 'waits the configured interval on a cooldown' do
          tm = polling(task_cooldown_poll: 5)
          expect(first_pause(tm, 'Seamstress Zasele says, "I am sorry, you must wait before I can give you a task."')).to eq(5)
        end

        it 'waits the configured interval after a recent cancel' do
          tm = polling(task_cooldown_poll: 6)
          expect(first_pause(tm, 'Seamstress Zasele is utterly ignoring you.')).to eq(6)
        end
      end
    end

    describe '#finish (resuming a task already in progress)' do
      it 'plans only the items still owed' do
        tm = reader
        game('task' => journal('a coil of reinforced cloth rope', 5, 4), 'read my rope instructions' => rope_materials)
        expect(tm.finish).to eq(['rope', 1, 4, 'cloth', 'burlap'])
      end

      it 'plans the full count when nothing has been returned yet' do
        tm = reader
        game('task' => journal('some reinforced cloth netting', 8, 0), 'read my netting instructions' => '   (1) finished fabric cloth (10 yards)')
        expect(tm.finish).to eq(['netting', 8, 10, 'cloth', 'burlap'])
      end

      it 'never plans a negative count' do
        tm = reader
        game('task' => journal('some wide leather straps', 5, 7), 'read my straps instructions' => '   (1) refined leather material (5 yards)')
        expect(tm.finish[1]).to eq(0)
      end

      it 'treats a journal entry without a returned count as nothing returned' do
        tm = reader
        game('task' => journal('a knitted outfit', 6), 'read my outfit instructions' => '   (1) refined fabric yarn (12 yards)')
        expect(tm.finish).to eq(['outfit', 6, 12, 'yarn', 'wool'])
      end

      it 'stops with a message when not on a task, instead of reading garbage' do
        tm = reader
        game('task' => 'You are not currently on a task.')
        expect { tm.finish }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/not on a task with zasele/)
      end

      it 'maps bone, metal and wood instructions to the stock the script buys' do
        tm = reader
        game('task' => journal('a bone bowl', 3, 1), 'read my bowl instructions' => '   (1) bone stack (6 volumes)')
        expect(tm.finish).to eq(['bowl', 2, 6, 'stack', 'deer'])
      end

      it 'reads stone instructions as one boulder per item' do
        tm = reader
        # No stone instructions in the logs at hand; this line is shaped to the
        # script's existing stone pattern.
        game('task' => journal('a stone idol', 2, 0), 'read my idol instructions' => '   (1) carved stone material (boulder)')
        expect(tm.finish).to eq(['idol', 2, 'boulder', 'stone', 'alabaster'])
      end

      # After a crash a character can log back in holding a tool and an unfinished
      # item; those still go to default stow, but only once the instructions are
      # in the crafting bag.
      it 'puts the instructions in the crafting bag by name, then stows anything else in hand' do
        tm = reader
        game('task' => journal('a coil of reinforced cloth rope', 5, 0), 'read my rope instructions' => rope_materials)
        expect(DRCC).to receive(:stow_crafting_item).with('rope instructions', 'duffel bag', nil).ordered
        expect(DRCI).to receive(:stow_hands).ordered

        tm.finish
      end

      it 'uses the task item noun, so leather straps instructions are named correctly' do
        tm = reader
        game('task' => journal('some wide leather straps', 6, 2), 'read my straps instructions' => '   (1) refined leather material (5 yards)')
        expect(DRCC).to receive(:stow_crafting_item).with('straps instructions', 'duffel bag', nil)

        tm.finish
      end
    end

    describe '#resume_task' do
      # Plays a resume: the journal says how many are owed, the bag holds some
      # finished items and maybe instructions with a number of uses left.
      # Returns what happened, in order.
      def resume(owed:, target: owed, banked: 0, uses: nil, foreign: false)
        tm = reader
        bag_items = banked
        given = 0
        events = []
        allow(tm).to receive(:tool_pickup)
        allow(tm).to receive(:refresh_haste) { events << :haste }
        allow(tm).to receive(:top_up_copper) { events << :copper }
        allow(tm).to receive(:sort_sack) { events << :sack }
        allow(tm).to receive(:fput)
        allow(tm).to receive(:zasele) { |item, count, *_| events << [:make, item, count] }
        allow(tm).to receive(:complete_task) { |item, count| events << [:complete, item, count] }
        allow(tm).to receive(:get_instructions) { events << :asked_for_instructions }
        allow(DRCC).to receive(:stow_crafting_item) { |name, *_| events << [:stowed, name] }
        allow(DRCI).to receive(:exists?).and_return(false)
        allow(DRCI).to receive(:get_item?) do |name, _bag|
          if name.end_with?('instructions')
            !uses.nil?
          elsif bag_items.positive?
            bag_items -= 1
            true
          else
            false
          end
        end
        uses_reply = if foreign
                       'You can\'t read the ink printed on the rope instructions.  They were written by or for someone else.'
                     else
                       "These instructions appear to be very fragile and will wear out quickly when studied.  They have only #{uses} uses remaining.\n#{rope_materials}"
                     end
        game('task'                      => journal('a coil of reinforced cloth rope', target, target - owed),
             'give my rope'              => lambda do |*|
               given += 1
               left = owed - given
               left.zero? ? sack_handed : more_needed(left)
             end,
             # The uses check and read_instructions' material read send the same
             # command; only the material read waits for the materials line alone.
             'read my rope instructions' => ->(_command, *matchers) { matchers == [described_class::INSTRUCTION_MATERIALS] ? rope_materials : uses_reply })
        expect { tm.resume_task }.to raise_error(SystemExit)
        events
      end

      it 'refreshes haste before making the items still owed' do
        events = resume(owed: 3, uses: 4)
        expect(events.index(:haste)).to be < events.index([:make, 'rope', 3])
      end

      it 'checks copper before buying for the items still owed' do
        events = resume(owed: 3, uses: 4)
        expect(events.index(:copper)).to be < events.index([:make, 'rope', 3])
      end

      it 'hands in finished items from the bag before making any' do
        events = resume(owed: 5, banked: 2, uses: 4)
        expect(events).to include([:make, 'rope', 3], [:complete, 'rope', 3])
      end

      it 'finishes the task from the bag alone when enough are banked, buying nothing' do
        expect(resume(owed: 3, banked: 3, uses: 4)).to eq([:sack])
      end

      it 'keeps the carried instructions when they have a use for every item owed' do
        events = resume(owed: 3, uses: 4)
        expect(events).not_to include(:asked_for_instructions)
        expect(events).to include([:make, 'rope', 3])
      end

      it 'asks for instructions when none are carried' do
        expect(resume(owed: 3, uses: nil)).to include(:asked_for_instructions)
      end

      it 'asks for instructions, after putting the old set away, when they have too few uses' do
        events = resume(owed: 3, uses: 2)
        expect(events.index([:stowed, 'rope instructions'])).to be < events.index(:asked_for_instructions)
      end

      it 'asks for instructions when the carried set is someone else\'s' do
        expect(resume(owed: 2, uses: 9, foreign: true)).to include(:asked_for_instructions)
      end

      it 'counts the items still owed after the banked ones are in' do
        expect(resume(owed: 6, target: 8, banked: 1, uses: 6)).to include([:make, 'rope', 5])
      end
    end

    describe '#turn_in_banked' do
      it 'puts back an item the taskmaster will not take and stops handing in' do
        tm = reader
        allow(DRCI).to receive(:get_item?).and_return(true)
        allow(DRC).to receive(:bput).and_return('Zasele shakes her head.')
        expect(DRCC).to receive(:stow_crafting_item).with('rope', 'duffel bag', nil)
        expect(tm.turn_in_banked('rope', 4)).to eq(4)
      end

      context 'when the taskmaster wanders off' do
        before do
          allow(DRCC).to receive(:stow_crafting_item)
        end

        it 'finds the taskmaster again and gives the item still in hand' do
          tm = reader
          state = giving([missed_give, more_needed(2), more_needed(1)], banked: 2)
          expect(tm.turn_in_banked('rope', 3)).to eq(1)
          expect(state[:gets]).to eq(2)
          expect(tm).to have_received(:find_npc).exactly(4).times
          expect(DRCC).not_to have_received(:stow_crafting_item)
        end

        it 'stops after repeated misses rather than looping forever' do
          tm = reader
          giving(Array.new(10, missed_give), banked: 2)
          expect { tm.turn_in_banked('rope', 3) }.to raise_error(SystemExit)
          expect(DRC).to have_received(:message).with(/after 5 tries/)
        end
      end
    end
  end

  describe 'making the items' do
    describe '#bradyn lumber tasks' do
      # Runs the real lumber branch down to the Rangu hand-off and reports which
      # tools were fetched for repair. Buying, shaping and disposal are not under
      # test, so they are stubbed out on the instance.
      def tools_sent_for_repair(settings)
        tm = build(settings: settings)
        allow(tm).to receive(:buy_stackables)
        allow(tm).to receive(:shape_item)
        allow(tm).to receive(:trash)
        fetched = []
        allow(DRCT).to receive(:walk_to)
        allow(DRCC).to receive(:get_crafting_item) { |tool, *_rest| fetched << tool }
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRC).to receive(:bput).and_return("There isn't a scratch on that")

        tm.bradyn('bowl', 2, 5, 'lumber', 'balsa')
        fetched
      end

      it 'repairs the shaping_tools that base.yaml defines' do
        expect(tools_sent_for_repair(shaping_tools: %w[shaper drawknife], engineering_belt: nil)).to eq(%w[shaper drawknife])
      end

      it 'falls back to the older engineering_tools key when shaping_tools is unset' do
        expect(tools_sent_for_repair(engineering_tools: ['rasp'], engineering_belt: nil)).to eq(['rasp'])
      end

      it 'prefers shaping_tools when both keys are set' do
        expect(tools_sent_for_repair(shaping_tools: ['shaper'], engineering_tools: ['rasp'], engineering_belt: nil)).to eq(['shaper'])
      end

      it 'repairs nothing, without raising, when neither key is set' do
        expect(tools_sent_for_repair(engineering_belt: nil)).to eq([])
      end
    end

    describe '#tailor_item' do
      let(:tailoring) { { 'tailoring' => { 'Crossing' => { 'tool-room' => 16666, 'stock-room' => 16667 } } } }

      # Runs the real tailor_item and records consumable checks and sew launches.
      def tailor(base, count: 6, marathon: false)
        tm = build(settings: { outfitting_belt: { 'name' => 'toolbelt', 'items' => [] } }, crafting_room: 16_936, marathon: marathon)
        allow(tm).to receive(:get_data).and_return(tailoring)
        allow(DRCT).to receive(:walk_to)
        checks = []
        allow(DRCC).to receive(:check_consumables) { |name, room, number, *rest| checks << [name, room, number, rest.last] }
        launches = []
        allow(DRC).to receive(:wait_for_script_to_complete) { |name, args| launches << [name, args] }
        tm.tailor_item('netting', count, base, 'burlap')
        [checks, launches]
      end

      it 'checks pins once for the whole task, enough for every item' do
        checks, = tailor('cloth', count: 8)
        expect(checks.count { |c| c.first == 'pins' }).to eq(1)
        expect(checks.find { |c| c.first == 'pins' }).to eq(['pins', 16666, 5, 29])
      end

      it 'checks thread once, from the stock room' do
        checks, = tailor('leather')
        expect(checks.select { |c| c.first == 'thread' }.map { |c| c[1..2] }).to eq([[16667, 6]])
      end

      it 'tells every sew run to skip its own consumable check' do
        _, launches = tailor('cloth', count: 3)
        expect(launches.size).to eq(3)
        expect(launches).to all(satisfy { |name, args| name == 'sew' && args.include?('skip') })
      end

      it 'skips pins and thread entirely for knitting' do
        checks, launches = tailor('yarn')
        expect(checks).to be_empty
        expect(launches.first.last).to include('knit', 'skip')
      end

      it 'behaves the same in marathon mode' do
        checks, launches = tailor('cloth', count: 2, marathon: true)
        expect(checks.map(&:first)).to eq(%w[pins thread])
        expect(launches).to all(satisfy { |_, args| args.include?('skip') })
      end
    end

    describe '#restock (marathon)' do
      # Stock prices and order numbers mirroring data/base-crafting.yaml.
      let(:stockdata) do
        { 'burlap' => { 'stock-value' => 437, 'stock-number' => 8 }, 'rat' => { 'stock-value' => 750, 'stock-number' => 2 },
          'yarn' => { 'stock-value' => 625, 'stock-number' => 13 }, 'thread' => { 'stock-value' => 971, 'stock-number' => 6 } }
      end

      # Runs the real restock with the script's own stack map and an empty bag,
      # recording every order placed.
      def restock_orders(tm = build(stockdata: stockdata))
        allow(tm).to receive(:get_data).and_return({ 'tailoring' => { 'Crossing' => { 'tool-room' => 16667 } } })
        allow(tm).to receive(:exchange_coins)
        allow(tm).to receive(:top_up_copper)
        allow(DRCC).to receive(:check_consumables)
        allow(DRCI).to receive(:exists?).and_return(false)
        allow(DRCT).to receive(:walk_to)
        orders = []
        allow(DRCT).to receive(:order_item) { |room, number| orders << [room, number] }
        allow(DRC).to receive(:bput).and_return('You combine')
        allow(DRCC).to receive(:stow_crafting_item)
        tm.restock
        orders
      end

      it 'restocks thread without tripping over a missing stack map entry' do
        expect { restock_orders }.not_to raise_error
      end

      it 'orders four spools of cotton thread from the tailoring supply room when none is carried' do
        expect(restock_orders.count([16667, 6])).to eq(4)
      end

      it 'still orders cloth, leather and yarn' do
        orders = restock_orders
        expect(orders.count([16667, 8])).to eq(10)
        expect(orders.count([16667, 2])).to eq(10)
        expect(orders.count([16667, 13])).to eq(4)
      end

      it 'keeps the float instead of depositing down to 5000 before buying' do
        tm = build(stockdata: stockdata)
        allow(DRCM).to receive(:deposit_coins)
        expect(tm).to receive(:top_up_copper)
        restock_orders(tm)
        expect(DRCM).not_to have_received(:deposit_coins)
      end
    end
  end

  describe 'turning in' do
    describe '#complete_task' do
      def finisher
        tm = build
        allow(tm).to receive(:find_npc)
        allow(tm).to receive(:sort_sack)
        allow(tm).to receive(:fput)
        tm
      end

      it 'fetches one item per accepted give' do
        tm = finisher
        state = giving([more_needed(1), sack_handed])
        tm.complete_task('rope', 2)
        expect(state[:gets]).to eq(2)
        expect(tm).to have_received(:sort_sack).with('rope')
      end

      it 'gives the item still in hand when the taskmaster wandered off, instead of fetching another' do
        tm = finisher
        state = giving([more_needed(1), missed_give, sack_handed])
        tm.complete_task('rope', 2)
        expect(state[:gets]).to eq(2)
        expect(tm).to have_received(:find_npc).exactly(3).times
        expect(tm).to have_received(:sort_sack).with('rope')
      end

      it 'stops after repeated misses rather than looping forever' do
        tm = finisher
        giving(Array.new(10, missed_give))
        expect { tm.complete_task('rope', 2) }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/after 5 tries/)
        expect(tm).not_to have_received(:sort_sack)
      end

      it 'resets the miss count after a give lands' do
        tm = finisher
        giving([missed_give, missed_give, missed_give, missed_give, more_needed(1), missed_give, missed_give, missed_give, missed_give, sack_handed])
        expect { tm.complete_task('rope', 2) }.not_to raise_error
        expect(tm).to have_received(:sort_sack)
      end

      it 'exits when the bag runs out of items' do
        tm = finisher
        allow(DRCI).to receive(:in_hands?).and_return(false)
        allow(DRCI).to receive(:get_item?).and_return(false)
        expect { tm.complete_task('rope', 2) }.to raise_error(SystemExit)
      end
    end

    describe '#keeper?' do
      def filtered(settings = {})
        build(settings: settings, lootbag: 'backpack').tap { |tm| tm.send(:configure_loot_filter) }
      end

      # Sack contents as LOOK prints them (2025 Hollow Eve logs).
      def sack(contents)
        "In the woven sack you see #{contents}."
      end

      context 'with only a keep list (the default)' do
        let(:tm) { filtered(task_keep_list: %w[agonite haledroth]) }

        it 'keeps listed prizes' do
          expect(tm.keeper?(sack('a large haledroth shard'))).to be(true)
        end

        it 'bins everything else' do
          expect(tm.keeper?(sack('some brown dye'))).to be(false)
        end
      end

      context 'with a junk list' do
        let(:tm) do
          filtered(task_keep_list: %w[agonite], task_junk_list: [/\bdye/, /(?<!crystal-bone)(?<!mammoth-bone) stack/, 'alabaster'])
        end

        it 'bins prizes matching a string entry' do
          expect(tm.keeper?(sack('a boulder alabaster deed'))).to be(false)
        end

        it 'bins prizes matching a regexp entry' do
          expect(tm.keeper?(sack('some coral dye'))).to be(false)
          expect(tm.keeper?(sack('a bear-bone stack'))).to be(false)
        end

        it 'keeps what a regexp entry deliberately excludes' do
          expect(tm.keeper?(sack('a mammoth-bone stack'))).to be(true)
        end

        it 'keeps a prize nobody has listed, which the keep list would have binned' do
          expect(tm.keeper?(sack('some punka leather'))).to be(true)
        end

        it 'ignores the keep list' do
          expect(tm.keeper?(sack('some agonite dye'))).to be(false)
        end
      end

      it 'falls back to the keep list when the junk list is empty' do
        expect(filtered(task_keep_list: %w[agonite], task_junk_list: []).keeper?(sack('some punka leather'))).to be(false)
      end

      it 'keeps nothing, without raising, when neither list is set' do
        expect(filtered.keeper?(sack('a large haledroth shard'))).to be(false)
      end

      it 'never keeps an empty or missing LOOK reply, in either mode' do
        expect(filtered(task_keep_list: %w[agonite]).keeper?('')).to be(false)
        expect(filtered(task_junk_list: ['dye']).keeper?('')).to be(false)
        expect(filtered(task_junk_list: ['dye']).keeper?(nil)).to be(false)
      end
    end

    describe '#sort_sack' do
      def filtered(settings)
        build(settings: settings, lootbag: 'backpack').tap { |tm| tm.send(:configure_loot_filter) }
      end

      def sort(tm, contents)
        allow(DRC).to receive(:bput).and_return('You pick up')
        allow(DRC).to receive(:bput).with('look in my sack', anything).and_return("In the woven sack you see #{contents}.")
        allow(DRCI).to receive(:put_away_item?)
        allow(DRCI).to receive(:dispose_trash)
        UserVars.taskmaster_sacks = { 'zasele' => [] }
        tm.sort_sack('rope')
      end

      it 'puts a keeper in the loot bag and pings Slack when asked to' do
        tm = filtered(task_junk_list: ['dye'], task_slack_keepers: true)
        expect(tm).to receive(:send_slackbot_message).with('Found a keeper: large haledroth shard')
        sort(tm, 'a large haledroth shard')
        expect(DRCI).to have_received(:put_away_item?).with('sack', 'backpack')
      end

      it 'does not ping Slack unless task_slack_keepers is set' do
        tm = filtered(task_junk_list: ['dye'])
        expect(tm).not_to receive(:send_slackbot_message)
        sort(tm, 'a large haledroth shard')
      end

      it 'bins junk without a Slack message' do
        tm = filtered(task_junk_list: ['dye'], task_slack_keepers: true)
        expect(tm).not_to receive(:send_slackbot_message)
        sort(tm, 'some coral dye')
        expect(DRCI).to have_received(:dispose_trash)
      end

      it 'strips the LOOK prefix from a keeper whose description has no leading article' do
        sort(filtered(task_junk_list: ['dye']), '3 haledroth shards')
        expect(DRC).to have_received(:message).with('Found a keeper: 3 haledroth shards')
      end
    end

    describe '#remember_sack' do
      it 'records each sack for loot_history' do
        UserVars.taskmaster_sacks = { 'zasele' => [] }
        build.remember_sack(' a large haledroth shard.')
        expect(UserVars.taskmaster_sacks['zasele']).to eq([' a large haledroth shard.'])
      end

      it 'keeps only the most recent 100 sacks' do
        UserVars.taskmaster_sacks = { 'zasele' => [] }
        tm = build
        150.times { |i| tm.remember_sack("sack #{i}") }
        history = UserVars.taskmaster_sacks['zasele']
        expect(history.size).to eq(100)
        expect(history.first).to eq('sack 50')
        expect(history.last).to eq('sack 149')
      end

      it 'trims an already oversized history from older runs on the next sack' do
        UserVars.taskmaster_sacks = { 'zasele' => Array.new(3_000) { |i| "old #{i}" } }
        build.remember_sack('new')
        expect(UserVars.taskmaster_sacks['zasele'].size).to eq(100)
        expect(UserVars.taskmaster_sacks['zasele'].last).to eq('new')
      end

      it 'starts a history for a taskmaster with none yet' do
        UserVars.taskmaster_sacks = nil
        build(npc: 'poltu').remember_sack('a bronze bar.')
        expect(UserVars.taskmaster_sacks).to eq('poltu' => ['a bronze bar.'])
      end
    end
  end
end
