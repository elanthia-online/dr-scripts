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

  describe 'hometown while a task runs' do
    # $HOMETOWN is the global dependency's shift_hometown sets; lich-5 applies
    # it to hometown in every get_settings call, so sew and restock follow it.
    # Entries from lich-5's HOMETOWN_REGEX_MAP (drvariables.rb), which
    # DRC.get_town_name matches against to return the canonical name.
    town_regex_map = {
      'Crossing'   => /^(cross(ing)?)$/i,
      'Riverhaven' => /^(river|haven|riverhaven)$/i,
      'Shard'      => /^(shard)$/i
    }

    let(:messages) { [] }

    before do
      $HOMETOWN = nil
      described_class.saved_hometown = nil
      allow(DRC).to receive(:get_town_name) { |text| town_regex_map.select { |_town, re| re =~ text }.keys.first }
      allow(DRC).to receive(:message) { |text| messages << text }
    end

    after do
      $HOMETOWN = nil
      described_class.saved_hometown = nil
    end

    it 'leaves hometown alone when task_hometown is unset, as base.yaml ships it' do
      tm = build(task_hometown: base_yaml['task_hometown'])
      tm.shift_to_task_hometown
      expect($HOMETOWN).to be_nil
      expect(described_class.saved_hometown).to be_nil
    end

    it 'treats a blank or missing task_hometown as unset' do
      build(task_hometown: '  ').shift_to_task_hometown
      build.shift_to_task_hometown
      expect($HOMETOWN).to be_nil
    end

    it 'ignores surrounding spaces in the town name' do
      build(task_hometown: ' Crossing ').shift_to_task_hometown
      expect($HOMETOWN).to eq('Crossing')
    end

    it 'resolves a short or lowercase town name to the canonical one lich-5 looks up' do
      build(task_hometown: 'cross').shift_to_task_hometown
      expect($HOMETOWN).to eq('Crossing')
      described_class.restore_hometown
      build(task_hometown: 'crossing').shift_to_task_hometown
      expect($HOMETOWN).to eq('Crossing')
    end

    it 'reports a task_hometown that matches no town and leaves hometown alone' do
      $HOMETOWN = 'Shard'
      build(task_hometown: 'Crosing').shift_to_task_hometown
      expect($HOMETOWN).to eq('Shard')
      expect(described_class.saved_hometown).to be_nil
      expect(messages).to include(/task_hometown 'Crosing' does not match any town/)
      described_class.restore_hometown
      expect($HOMETOWN).to eq('Shard')
    end

    it 'makes task_hometown the hometown while taskmaster runs, and clears it afterwards' do
      build(task_hometown: 'Crossing').shift_to_task_hometown
      expect($HOMETOWN).to eq('Crossing')
      described_class.restore_hometown
      expect($HOMETOWN).to be_nil
    end

    it 'puts back an override another script had set, such as trade' do
      $HOMETOWN = 'Shard'
      build(task_hometown: 'Crossing').shift_to_task_hometown
      expect($HOMETOWN).to eq('Crossing')
      described_class.restore_hometown
      expect($HOMETOWN).to eq('Shard')
    end

    it 'leaves an override another script set while taskmaster ran' do
      $HOMETOWN = 'Shard'
      build(task_hometown: 'Crossing').shift_to_task_hometown
      $HOMETOWN = 'Riverhaven' # set by another script mid-run
      described_class.restore_hometown
      expect($HOMETOWN).to eq('Riverhaven')
      expect(described_class.saved_hometown).to be_nil
    end

    it 'leaves a mid-run clear by another script in place' do
      $HOMETOWN = 'Shard'
      build(task_hometown: 'Crossing').shift_to_task_hometown
      $HOMETOWN = nil # another script cleared it mid-run
      described_class.restore_hometown
      expect($HOMETOWN).to be_nil
    end

    it 'changes nothing on stop when it never shifted' do
      $HOMETOWN = 'Riverhaven'
      described_class.restore_hometown
      expect($HOMETOWN).to eq('Riverhaven')
    end

    it 'restores only once, so a second stop cannot clear a later override' do
      build(task_hometown: 'Crossing').shift_to_task_hometown
      described_class.restore_hometown
      $HOMETOWN = 'Shard' # set by something else after taskmaster stopped
      described_class.restore_hometown
      expect($HOMETOWN).to eq('Shard')
    end

    it 'shifts before running any mode' do
      tm = build(task_hometown: 'Crossing')
      allow(tm).to receive(:find_npc)
      expect { tm.run(OpenStruct.new(npc: 'zasele', find: 'find')) }.to raise_error(SystemExit)
      expect($HOMETOWN).to eq('Crossing')
    end
  end

  describe 'running the script' do
    let(:rope_task) { ['rope', 2, 4, 'cloth', 'burlap'] }
    let(:outfitting_belt) { { 'name' => 'tailor belt', 'items' => [] } }
    let(:all_rooms) do
      [16_145, 16_146, 16_148, 16_150, 16_153, 16_154, 16_147, 16_276, 16_277, 16_278, 16_290, 16_291, 16_292, 16_293, 16_295, 16_296, 16_294, 16_159, 16_161, 16_166, 16_169]
    end

    # Runs the real start-up, as TaskMaster.new.run does, with every step that
    # talks to the game stubbed to record itself. args: the parsed arguments
    # (npc:, repeat:, marathon: ...). ticket: whether a Rangu ticket is
    # carried; samples: the taskmasters cycle picks, in order. The wrap-up flag
    # goes up with the turn-in numbered wrap_up_after. Returns the recorded
    # steps, in order.
    def start(settings: {}, ticket: false, stock_ok: true, wrap_up_after: nil, samples: [], **args)
      tm = described_class.allocate
      events = []
      completed = 0
      allow(tm).to receive(:get_settings).and_return(OpenStruct.new({ outfitting_tools: ['scissors'], outfitting_belt: outfitting_belt }.merge(settings)))
      allow(tm).to receive(:get_data).and_return({ 'stock' => {} })
      allow(tm).to receive(:parse_args) do |definitions|
        events << [:parse_args, definitions.map { |group| group.map { |arg| arg[:name] } }]
        OpenStruct.new(args)
      end
      allow_any_instance_of(Array).to receive(:sample).and_wrap_original do |original, *rest|
        original.receiver == %w[poltu bradyn zasele] ? samples.shift : original.call(*rest)
      end
      allow(DRCI).to receive(:exists?).with('rangu ticket').and_return(ticket)
      allow(tm).to receive(:reconcile_hands) { events << :reconcile }
      allow(tm).to receive(:top_up_copper) { events << [:copper, tm.instance_variable_get(:@remainder), tm.instance_variable_get(:@dispose)] }
      allow(tm).to receive(:refresh_haste) { events << :haste }
      allow(tm).to receive(:run_before_scripts) { events << :before }
      allow(tm).to receive(:get_task) do
        events << :get_task
        # A loop that no longer stops fails here instead of hanging the suite.
        raise 'runaway task loop' if events.count(:get_task) > 10

        rope_task
      end
      allow(tm).to receive(:tool_pickup) { events << :tool_pickup }
      %i[poltu bradyn zasele].each do |npc|
        allow(tm).to receive(npc) do |*task|
          events << [:work, npc, *task]
          tm.instance_variable_set(:@remainder, true)
          tm.instance_variable_set(:@dispose, true)
        end
      end
      allow(tm).to receive(:complete_task) do |item, count|
        events << [:complete, item, count]
        completed += 1
        Flags['wrap-up'] = true if completed == wrap_up_after
      end
      allow(tm).to receive(:resume_task) do
        events << :resume
        exit
      end
      allow(tm).to receive(:restock) { events << :restock }
      allow(tm).to receive(:check_stock) do |*needed|
        events << [:check_stock, *needed]
        stock_ok
      end
      allow(tm).to receive(:repair) { |tools, belt| events << [:repair, tools, belt] }
      allow(tm).to receive(:find_npc) { |rooms, npc| events << [:find_npc, rooms.size, npc] }
      allow(tm).to receive(:tailor_item) { |*task| events << [:tailor, *task] }
      allow(DRCT).to receive(:dispose) { |item, room| events << [:dispose, item, room] }
      allow(tm).to receive(:_respond) { |text| events << [:respond, text] }
      allow(DRC).to receive(:message) { |text| events << [:message, text] }
      begin
        tm.send(:initialize)
        tm.run
      rescue SystemExit
        events << :exit
      end
      events.reject { |event| event.is_a?(Array) && event.first == :parse_args }
    end

    def work(npc = :zasele)
      [:work, npc, 'rope', 2, 4, 'cloth', 'burlap']
    end

    # The steps before each task: the flags from the previous task are cleared
    # before the copper check.
    let(:before_task) { [[:copper, false, false], :haste, :before, :get_task] }

    it 'offers the same arguments' do
      tm = described_class.allocate
      allow(tm).to receive(:get_settings).and_return(OpenStruct.new)
      allow(tm).to receive(:get_data).and_return({ 'stock' => {} })
      names = nil
      allow(tm).to receive(:parse_args) do |definitions|
        names = definitions.map { |group| group.map { |arg| arg[:name] } }
        OpenStruct.new(find: true, npc: 'zasele')
      end
      allow(tm).to receive(:find_npc)
      tm.send(:initialize)
      expect { tm.run }.to raise_error(SystemExit)
      expect(names).to eq([%w[npc finish find tools repeat], %w[reset_output pickup cycle marathon loot_history script_summary]])
    end

    it 'only reads the settings when built, leaving the arguments and the game to run' do
      tm = described_class.allocate
      allow(tm).to receive(:get_settings).and_return(OpenStruct.new)
      allow(tm).to receive(:get_data).and_return({ 'stock' => {} })
      allow(tm).to receive(:parse_args)
      allow(DRC).to receive(:bput)
      allow(tm).to receive(:fput)
      tm.send(:initialize)
      expect(tm).not_to have_received(:parse_args)
      expect(DRC).not_to have_received(:bput)
      expect(tm).not_to have_received(:fput)
      expect(tm.instance_variable_get(:@rooms)).to eq(all_rooms)
      expect(Flags['wrap-up']).to be(false)
    end

    it 'runs the mode it is given without parsing the arguments itself' do
      tm = build(rooms: described_class::ROOMS)
      allow(tm).to receive(:parse_args)
      allow(tm).to receive(:find_npc)
      expect { tm.run(OpenStruct.new(npc: 'bradyn', find: true)) }.to raise_error(SystemExit)
      expect(tm).to have_received(:find_npc).with(described_class::ROOMS, 'bradyn')
      expect(tm).not_to have_received(:parse_args)
    end

    describe 'one task' do
      it 'sorts the hands, then runs copper, haste, before scripts, the task, the worker and the turn-in, in that order' do
        expect(start(npc: 'zasele')).to eq([:reconcile, *before_task, work, [:complete, 'rope', 2]])
      end

      it 'works the task with the named taskmaster' do
        expect(start(npc: 'poltu')).to include(work(:poltu))
      end

      it 'picks up repaired tools between getting the task and working it when a ticket is carried' do
        expect(start(npc: 'zasele', ticket: true)).to eq([:reconcile, *before_task, :tool_pickup, work, [:complete, 'rope', 2]])
      end

      it 'leaves repaired tools alone when repairing its own tools' do
        expect(start(npc: 'zasele', settings: { task_self_repair: true }, ticket: true)).not_to include(:tool_pickup)
      end

      it 'picks up every repaired tool at the end only with task_get_tools_on_completion and a ticket' do
        events = start(npc: 'zasele', settings: { task_self_repair: true, task_get_tools_on_completion: true }, ticket: true)
        expect(events.last(2)).to eq([[:complete, 'rope', 2], :tool_pickup])
        expect(start(npc: 'zasele', settings: { task_get_tools_on_completion: true })).not_to include(:tool_pickup)
      end

      it 'stops after one task without repeat, wrap-up or not' do
        expect(start(npc: 'zasele').count(:get_task)).to eq(1)
      end
    end

    describe 'repeat and cycle' do
      it 'repeats tasks until the wrap-up call, clearing the previous task\'s flags each time' do
        events = start(npc: 'zasele', repeat: true, wrap_up_after: 3)
        expect(events).to eq([:reconcile, *before_task, work, [:complete, 'rope', 2],
                              *before_task, work, [:complete, 'rope', 2],
                              *before_task, work, [:complete, 'rope', 2]])
      end

      it 'stops on the wrap-up call after the first task too' do
        expect(start(npc: 'zasele', repeat: true, wrap_up_after: 1).count(:get_task)).to eq(1)
      end

      it 'picks a taskmaster at random at the start and after every task, until the wrap-up call' do
        events = start(npc: 'zasele', cycle: true, wrap_up_after: 3, samples: %w[bradyn poltu bradyn zasele])
        expect(events.grep(Array).select { |event| event.first == :work }.map { |event| event[1] }).to eq(%i[bradyn poltu bradyn])
      end
    end

    describe 'marathon' do
      # Marathon never clears the previous task's flags. The instructions are
      # thrown away by complete_task once the task is handed in.
      let(:marathon_task) do
        [[:copper, nil, nil], :haste, :before, :get_task, [:check_stock, 8, 'burlap', 'cloth'], [:tailor, 'rope', 2, 'cloth', 'burlap'], [:complete, 'rope', 2]]
      end

      it 'runs Zasele tasks after a restock, whatever taskmaster is named, and exits at the wrap-up call' do
        events = start(npc: 'poltu', marathon: true, wrap_up_after: 2)
        expect(events).to eq([:reconcile, :restock, *marathon_task, *marathon_task, :exit])
        expect(start(npc: 'poltu', marathon: true, stock_ok: false, wrap_up_after: 1)).to include([:find_npc, 21, 'zasele'])
      end

      it 'repairs, restocks and finds the taskmaster again when the stock runs short' do
        events = start(npc: 'zasele', marathon: true, stock_ok: false, wrap_up_after: 1)
        expect(events).to eq([:reconcile, :restock, *marathon_task.first(4), [:check_stock, 8, 'burlap', 'cloth'],
                              [:repair, ['scissors'], outfitting_belt], :restock, [:find_npc, 21, 'zasele'],
                              [:tailor, 'rope', 2, 'cloth', 'burlap'], [:complete, 'rope', 2], :exit])
      end

      it 'skips the repair with task_no_repair' do
        events = start(npc: 'zasele', marathon: true, settings: { task_no_repair: true }, stock_ok: false, wrap_up_after: 1)
        expect(events.map { |event| Array(event).first }).not_to include(:repair)
        expect(events).to include(:restock, [:find_npc, 21, 'zasele'])
      end

      it 'picks up repaired tools after each restock when a ticket is carried, and at the end only when asked' do
        events = start(npc: 'zasele', marathon: true, ticket: true, stock_ok: false, wrap_up_after: 1)
        expect(events.first(3)).to eq(%i[reconcile restock tool_pickup])
        expect(events.each_cons(2).count { |pair| pair == %i[restock tool_pickup] }).to eq(2)
        expect(events.last(2)).to eq([[:complete, 'rope', 2], :exit])
        events = start(npc: 'zasele', marathon: true, settings: { task_self_repair: true, task_get_tools_on_completion: true }, ticket: true, wrap_up_after: 1)
        expect(events.last(3)).to eq([[:complete, 'rope', 2], :tool_pickup, :exit])
      end
    end

    describe 'other modes' do
      it 'finish sorts the hands and resumes the task in progress, without asking for a new one' do
        expect(start(npc: 'zasele', finish: true)).to eq(%i[reconcile resume exit])
      end

      it 'find searches every room for the taskmaster and exits' do
        expect(start(npc: 'bradyn', find: true)).to eq([[:find_npc, 21, 'bradyn'], :exit])
      end

      it 'tools lists the named taskmaster\'s tools and exits' do
        expect(start(npc: 'poltu', tools: true)).to eq([[:message, 'Tools required:'], *['forging hammer', 'bellows', 'tongs', 'stirring rod', 'shovel'].map { |tool| [:message, tool] }, :exit])
      end

      it 'reset_output clears the Task Master window and exits' do
        expect(start(npc: 'zasele', reset_output: true)).to eq([[:respond, "<clearStream id='Task Master'/>"], :exit])
      end

      it 'loot_history prints each taskmaster\'s sacks and exits' do
        UserVars.taskmaster_sacks = { 'poltu' => ['a bronze bar.'], 'bradyn' => [], 'zasele' => ['some coral dye.', 'a large haledroth shard.'] }
        expect(start(npc: 'zasele', loot_history: true)).to eq([[:message, 'Sack history for Taskmaster Poltu:'], [:message, 'a bronze bar.'],
                                                                [:message, 'Sack history for Taskmaster Bradyn:'],
                                                                [:message, 'Sack history for Taskmaster Zasele:'], [:message, 'some coral dye.'], [:message, 'a large haledroth shard.'],
                                                                :exit])
      end

      it 'pickup collects repaired tools only when a ticket is carried, then exits' do
        expect(start(npc: 'zasele', pickup: true, ticket: true)).to eq(%i[tool_pickup exit])
        expect(start(npc: 'zasele', pickup: true, ticket: false)).to eq([:exit])
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

    it 'resumes an unfinished piece made from the wool it buys for knitting tasks too' do
      _, launched = reconcile(right: 'unfinished wool knitted hat', left: nil)
      expect(launched).to eq([['sew', %w[resume hat]]])
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
          offers = ['You may accept by typing ACCEPT TASK']
          game('ask zasele for task' => ->(*) { offers.shift || raise('asked again after the offer') }, 'accept task' => 'You can check your progress with the TASK verb',
               'task' => journal('a coil of reinforced cloth rope', 5, 0), 'read my rope instructions' => rope_materials)
          expect(DRCC).to receive(:stow_crafting_item).with('rope instructions', 'duffel bag', nil).ordered
          expect(DRCI).to receive(:stow_hands).ordered

          expect(tm.get_task).to eq(['rope', 5, 4, 'cloth', 'burlap'])
        end

        it 'starts with no replacement request on record from an earlier task' do
          tm = reader
          UserVars.taskmaster_replacements = { 'zasele' => 'rope', 'poltu' => 'dagger' }
          offers = ['You may accept by typing ACCEPT TASK']
          game('ask zasele for task' => ->(*) { offers.shift || raise('asked again after the offer') }, 'accept task' => 'You can check your progress with the TASK verb',
               'task' => journal('a coil of reinforced cloth rope', 5, 0), 'read my rope instructions' => rope_materials)
          allow(DRCC).to receive(:stow_crafting_item)
          tm.get_task
          expect(UserVars.taskmaster_replacements).to eq('poltu' => 'dagger')
        end
      end

      describe 'every reply to ASK FOR TASK' do
        # Replies shaped to the script's matchers. Offer, wait and ignore lines
        # are from the 2025 Hollow Eve logs; the others are not in the logs at
        # hand.
        let(:offer) { 'You may accept by typing ACCEPT TASK.' }
        let(:terms) { 'Zasele has a task for you, if you agree to her terms.' }
        let(:nobody) { 'To whom are you speaking?' }
        let(:ignored) { 'Seamstress Zasele is utterly ignoring you.' }
        let(:later) { 'Seamstress Zasele says, "I can give you a chance a little later."' }
        let(:wait) { 'Seamstress Zasele says, "I am sorry, you must wait before I can give you a task."' }
        let(:on_task) { 'You are already on a task.' }

        # Plays the replies in order and records each search, ask, pause and
        # command. Accepting returns finish's result and an ongoing task
        # resume_task's, both stubbed. Returns get_task's result, the steps
        # and the instance.
        def asking(replies, boost: false)
          tm = reader(boost: boost, cooldown_poll: 7)
          events = []
          allow(tm).to receive(:find_npc) { events << :find }
          allow(tm).to receive(:pause) { |seconds| events << [:pause, seconds] }
          allow(tm).to receive(:fput) { |command| events << [:fput, command] }
          allow(tm).to receive(:finish) do
            events << :finish
            :accepted
          end
          allow(tm).to receive(:resume_task) do
            events << :resume
            :resumed
          end
          allow(DRC).to receive(:message) { |text| events << [:message, text] }
          ask = lambda do |*|
            events << :ask
            # A loop that asks past the last reply fails here instead of
            # hanging the suite.
            raise 'asked again after the last reply' if replies.empty?

            replies.shift
          end
          accept = lambda do |*|
            events << :accept
            'You can check your progress with the TASK verb.'
          end
          game('ask zasele for task' => ask, 'accept task' => accept)
          [tm.get_task, events, tm]
        end

        let(:accepted) { %i[find ask accept finish] }
        let(:cooldown_message) { [:message, 'Task on cooldown or recently canceled a task, either way, going to have to wait.'] }

        it 'asks with the same matchers' do
          asking([offer])
          expect(DRC).to have_received(:bput).with('ask zasele for task', /if you agree to (his|her) terms/, /You may accept by typing ACCEPT TASK/, /utterly ignoring you/,
                                                   /you must wait before I can give you a task/, /You are already on a task/, /give you a chance a little later/, /^To whom are you speaking/)
          expect(DRC).to have_received(:bput).with('accept task', /You can check your progress with the TASK verb/)
        end

        it 'accepts an offer and returns what reading the task returns' do
          expect(asking([offer]).first(2)).to eq([:accepted, accepted])
        end

        it 'asks again at once when the taskmaster wants her terms agreed first' do
          expect(asking([terms, offer]).first(2)).to eq([:accepted, [:find, :ask, *accepted]])
        end

        it 'asks again at once when nobody answered to the name' do
          expect(asking([nobody, offer]).first(2)).to eq([:accepted, [:find, :ask, *accepted]])
        end

        it 'waits the poll interval and asks again when ignored after a cancel' do
          expect(asking([ignored, offer]).first(2)).to eq([:accepted, [:find, :ask, cooldown_message, [:pause, 7], *accepted]])
        end

        it 'waits the poll interval and asks again when told to come back a little later' do
          expect(asking([later, offer]).first(2)).to eq([:accepted, [:find, :ask, cooldown_message, [:pause, 7], *accepted]])
        end

        it 'waits the poll interval for each cooldown reply without the task boost' do
          expect(asking([wait, wait, offer]).first(2)).to eq([:accepted, [:find, :ask, [:pause, 7], :find, :ask, [:pause, 7], *accepted]])
        end

        it 'boosts once on a cooldown, waits two seconds and asks again' do
          result, events, tm = asking([wait, offer], boost: true)
          expect([result, events]).to eq([:accepted, [:find, :ask, [:fput, 'boost task'], [:pause, 2], *accepted]])
          expect(tm.instance_variable_get(:@boost)).to be(false)
        end

        it 'waits the poll interval on a second cooldown instead of boosting again' do
          expect(asking([wait, wait, offer], boost: true)[1]).to eq([:find, :ask, [:fput, 'boost task'], [:pause, 2], :find, :ask, [:pause, 7], *accepted])
        end

        it 'does not boost again on a later ask from the same run' do
          _, _, tm = asking([wait, offer], boost: true)
          events = []
          allow(tm).to receive(:pause) { |seconds| events << [:pause, seconds] }
          allow(tm).to receive(:fput) { |command| events << [:fput, command] }
          replies = [wait, offer]
          game('ask zasele for task' => ->(*) { replies.shift || raise('asked again after the last reply') }, 'accept task' => 'You can check your progress with the TASK verb.')
          tm.get_task
          expect(events).to eq([[:pause, 7]])
        end

        it 'resumes the task already in progress and returns what resuming returns' do
          expect(asking([on_task]).first(2)).to eq([:resumed, %i[find ask resume]])
        end

        it 'resumes after waiting out a cooldown' do
          expect(asking([wait, on_task]).first(2)).to eq([:resumed, [:find, :ask, [:pause, 7], :find, :ask, :resume]])
        end

        it 'mixes replies in any order, asking until there is an offer' do
          expect(asking([terms, ignored, wait, nobody, offer], boost: true)[1])
            .to eq([:find, :ask, :find, :ask, cooldown_message, [:pause, 7], :find, :ask, [:fput, 'boost task'], [:pause, 2], :find, :ask, *accepted])
        end

        it 'keeps asking through a long cooldown without growing the stack' do
          result, events, = asking([*Array.new(20_000, wait), offer])
          expect(result).to eq(:accepted)
          expect(events.count([:pause, 7])).to eq(20_000)
        end

        it 'gives up and returns nil, without asking again, when no reply matches' do
          expect(asking(['']).first(2)).to eq([nil, %i[find ask]])
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

      describe 'asking for replacement instructions' do
        it 'asks once when the carried set is used up, and remembers it for this task' do
          events = resume(owed: 3, uses: nil)
          expect(events).to include(:asked_for_instructions)
          expect(UserVars.taskmaster_replacements).to eq('zasele' => 'rope')
        end

        it 'stops instead of asking a second time for the same task' do
          UserVars.taskmaster_replacements = { 'zasele' => 'rope' }
          events = resume(owed: 3, uses: nil)
          expect(events).not_to include(:asked_for_instructions)
          expect(events).not_to include([:make, 'rope', 3])
          expect(DRC).to have_received(:message).with(/Already asked zasele for rope instructions/)
        end

        it 'still asks when the earlier request was for a different item' do
          UserVars.taskmaster_replacements = { 'zasele' => 'netting' }
          expect(resume(owed: 3, uses: nil)).to include(:asked_for_instructions)
        end

        it 'does not ask at all while the carried set has a use for every item owed' do
          UserVars.taskmaster_replacements = { 'zasele' => 'rope' }
          expect(resume(owed: 3, uses: 4)).to include([:make, 'rope', 3])
        end
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

      # Regression: trash no longer throws the instructions away, so a task the
      # banked items finish must close out like complete_task does, or the set
      # stays in the bag beside the next task's and the replacement record stays.
      it 'throws the instructions away and clears the replacement record when the banked items finish the task' do
        UserVars.taskmaster_replacements = { 'zasele' => 'rope', 'poltu' => 'dagger' }
        allow(DRCT).to receive(:dispose)
        resume(owed: 3, banked: 3, uses: 4)
        expect(DRCT).to have_received(:dispose).with('rope instructions', nil, nil, nil)
        expect(UserVars.taskmaster_replacements).to eq('poltu' => 'dagger')
      end

      it 'keeps the instructions and the replacement record when the banked items leave some owed' do
        UserVars.taskmaster_replacements = { 'zasele' => 'rope' }
        allow(DRCT).to receive(:dispose)
        resume(owed: 5, banked: 2, uses: 4)
        expect(DRCT).not_to have_received(:dispose)
        expect(UserVars.taskmaster_replacements).to eq('zasele' => 'rope')
      end

      it 'keeps the carried instructions when they have a use for every item owed' do
        events = resume(owed: 3, uses: 4)
        expect(events).not_to include(:asked_for_instructions)
        expect(events).to include([:make, 'rope', 3])
      end

      it 'keeps the carried instructions when they have exactly one use per item owed' do
        expect(resume(owed: 3, uses: 3)).not_to include(:asked_for_instructions)
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
    describe '#trash' do
      def trasher(remainder:)
        tm = build(remainder: remainder)
        disposed = []
        allow(DRCT).to receive(:dispose) { |name, *_| disposed << name }
        gets = ['You get some burlap cloth from inside your duffel bag.']
        allow(DRC).to receive(:bput) { |*| gets.shift || 'What were you referring to?' }
        tm.trash('rope', 'cloth', 'burlap')
        disposed
      end

      it 'leaves the instructions alone, so a task that is not handed in yet keeps them' do
        expect(trasher(remainder: false)).to eq([])
      end

      it 'still throws away leftover stock' do
        expect(trasher(remainder: true)).to eq(['burlap cloth'])
      end
    end

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

    describe 'Poltu and Bradyn tasks' do
      let(:forging_belt) { { 'name' => 'forging belt', 'items' => [] } }
      let(:engineering_belt) { { 'name' => 'engineering belt', 'items' => [] } }

      # Runs the taskmaster's real task method with buying, crafting, repair and
      # disposal stubbed to record their calls, each with the @remainder flag as
      # it stood then. remainder: the flag before the task.
      def run_task(npc, item, count, volume_per_item, base, type, remainder: false)
        tm = build(settings: { forging_tools: ['forging hammer'], forging_belt: forging_belt, engineering_belt: engineering_belt, shaping_tools: ['wood shaper'] },
                   remainder: remainder)
        calls = []
        %i[buy_ingots bingots buy_rocks buy_stackables forge_item carve_stone carve_bone shape_item repair trash].each do |step|
          allow(tm).to receive(step) { |*step_args| calls << [step, *step_args, tm.instance_variable_get(:@remainder)] }
        end
        allow(DRC).to receive(:right_hand).and_return('iron chisels')
        tm.send(npc, item, count, volume_per_item, base, type)
        calls
      end

      # What a metal task does after buying: forge with the metal bought,
      # repair the forging tools, then throw away any leftover metal.
      def forged(count, type, remainder)
        [[:forge_item, 'dagger', count, type, remainder], [:repair, ['forging hammer'], forging_belt, remainder], [:trash, 'dagger', 'ingot', type, remainder]]
      end

      %i[poltu bradyn].each do |npc|
        describe "##{npc} metal purchasing" do
          # count, volume per item => what is bought, the metal forged, @remainder
          {
            [3, 10]  => [[:buy_ingots, 3, 'steel'], 'steel', false],
            [12, 10] => [[:buy_ingots, 12, 'steel'], 'steel', false],
            [4, 5]   => [[:buy_ingots, 4, 'bronze'], 'bronze', false],
            [30, 5]  => [[:buy_ingots, 30, 'bronze'], 'bronze', false],
            [101, 1] => [[:bingots, 3], 'bronze', true],
            [17, 6]  => [[:bingots, 3], 'bronze', true],
            [25, 4]  => [[:bingots, 2], 'bronze', false],
            [17, 3]  => [[:bingots, 2], 'bronze', true],
            [9, 6]   => [[:bingots, 2], 'bronze', true],
            [1, 51]  => [[:bingots, 2], 'bronze', true],
            [25, 2]  => [[:buy_ingots, 1, 'steel'], 'steel', true],
            [3, 4]   => [[:buy_ingots, 1, 'steel'], 'steel', true],
            [8, 6]   => [[:bingots, 1], 'bronze', true],
            [3, 6]   => [[:bingots, 1], 'bronze', true],
            [1, 50]  => [[:bingots, 1], 'bronze', true]
          }.each do |(count, volume), (bought, metal, remainder)|
            it "buys #{bought.inspect} and forges #{metal} for #{count} items of #{volume} volumes (#{count * volume} in all)" do
              calls = run_task(npc, 'dagger', count, volume, 'ingot', 'bronze')
              expect(calls).to eq([[*bought, remainder], *forged(count, metal, remainder)])
            end
          end

          it 'leaves @remainder as it was on tasks of exactly one ingot per item' do
            expect(run_task(npc, 'dagger', 3, 10, 'ingot', 'bronze', remainder: true).last.last).to be(true)
            expect(run_task(npc, 'dagger', 4, 5, 'ingot', 'bronze', remainder: true).last.last).to be(true)
          end
        end
      end

      describe '#bradyn stone, bone and wood tasks' do
        it 'buys a rock deed per item, carves the stone and repairs the tool in hand' do
          expect(run_task(:bradyn, 'idol', 2, 'boulder', 'stone', 'alabaster'))
            .to eq([[:buy_rocks, 2, false], [:carve_stone, 'idol', 2, false], [:repair, ['iron chisels'], engineering_belt, false], [:trash, 'idol', 'stone', 'alabaster', false]])
        end

        it 'buys bone stacks, carves the bone and repairs the tool in hand, even at 10 volumes per item' do
          expect(run_task(:bradyn, 'comb', 3, 10, 'stack', 'deer'))
            .to eq([[:buy_stackables, 'comb', 3, 10, 'stack', false], [:carve_bone, 'comb', 3, false], [:repair, ['iron chisels'], engineering_belt, false], [:trash, 'comb', 'stack', 'deer', false]])
        end

        it 'buys lumber, shapes the wood and repairs the shaping tools' do
          expect(run_task(:bradyn, 'bowl', 2, 5, 'lumber', 'balsa'))
            .to eq([[:buy_stackables, 'bowl', 2, 5, 'lumber', false], [:shape_item, 'bowl', 2, 'lumber', 'balsa', false], [:repair, ['wood shaper'], engineering_belt, false],
                    [:trash, 'bowl', 'lumber', 'balsa', false]])
        end
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

      it 'throws the instructions away in the worn trash can once the task is handed in, and clears the replacement record' do
        tm = finisher
        tm.instance_variable_set(:@worn_trashcan, 'bucket')
        tm.instance_variable_set(:@worn_trashcan_verb, 'tap')
        UserVars.taskmaster_replacements = { 'zasele' => 'rope' }
        allow(DRCT).to receive(:dispose)
        giving([more_needed(1), sack_handed])
        tm.complete_task('rope', 2)
        expect(DRCT).to have_received(:dispose).with('rope instructions', nil, 'bucket', 'tap')
        expect(UserVars.taskmaster_replacements).to eq({})
      end

      it 'keeps the instructions when the items run out before the task is done, for the resume' do
        tm = finisher
        allow(DRCT).to receive(:dispose)
        allow(DRCI).to receive(:in_hands?).and_return(false)
        allow(DRCI).to receive(:get_item?).and_return(false)
        expect { tm.complete_task('rope', 2) }.to raise_error(SystemExit)
        expect(DRCT).not_to have_received(:dispose)
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
