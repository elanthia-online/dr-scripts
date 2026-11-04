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

  # Leftover stock in the crafting bag, the hands, a worn trash can and a
  # room bin, answering commands by noun and by "#id" the way the game does.
  # A piece taken out goes to the first free hand with a new id. With
  # worn_leathers the character wears "sinuous leathers", and DR binds "my
  # leather" to them by prefix (Barrask, Hollow Eve 2026-11-04), so a put by
  # that noun answers "Perhaps you should be holding that first." whatever
  # is in hand. refuse: the bin and the worn trash can are full. bag_full:
  # nothing more fits in the crafting bag. no_floor: the room refuses a drop.
  #
  # DRCI and DRCT are harness doubles, so dispose_trash, put_away_item? and
  # dispose stand in for lich-5 v5.23.0 here: each sends its put through the
  # same world (an "#id" passes through unqualified, a noun gets "my "), and
  # dispose_trash uses the trash can's verb twice after a piece lands. As in
  # v5.23.0, a piece the worn trash can refuses is dropped on the floor and
  # dispose_trash returns true (this room has no bin, and the 15s timeout on
  # the unlisted "There isn't any more room" reply is not waited out); only
  # when the drop is refused too does it return false. DRCT.dispose's false
  # on a refused bin likewise stands for every way, the floor included,
  # having failed. Replies come back the way DRC.bput returns them: the text
  # the first matching pattern matched, or '' when none did.
  #
  # @return [Hash] :bag (pieces left per stock), :hands, :floor (pieces
  #   dropped), :sent (commands)
  def stock_world(pieces, worn_leathers: false, refuse: false, bag_full: false, no_floor: false, hands: {})
    world = { bag: pieces.dup, hands: { right: nil, left: nil }.merge(hands), floor: [], sent: [] }
    next_id = 2_222_485
    allow(GameObj).to receive(:right_hand) { world[:hands][:right] || OpenStruct.new(name: 'Empty', noun: nil, id: nil) }
    allow(GameObj).to receive(:left_hand) { world[:hands][:left] || OpenStruct.new(name: 'Empty', noun: nil, id: nil) }
    allow(DRC).to receive(:right_hand) { world[:hands][:right]&.name }
    allow(DRC).to receive(:left_hand) { world[:hands][:left]&.name }

    held = ->(ref) { world[:hands].find { |_, obj| obj && ["##{obj.id}", "my #{obj.noun}", "my #{obj.name}"].include?(ref) }&.first }
    worn = ->(ref) { worn_leathers && ref.start_with?('my ') && 'leathers'.start_with?(ref.delete_prefix('my ')) }
    reply = lambda do |command|
      case command
      when /\Aget my (.+) from my duffel bag\z/
        stock = Regexp.last_match(1)
        hand = world[:hands].find { |_, obj| obj.nil? }&.first
        next 'You need a free hand to pick that up.' unless hand
        next 'What were you referring to?' unless world[:bag].fetch(stock, 0).positive?

        world[:bag][stock] -= 1
        world[:hands][hand] = OpenStruct.new(name: stock, noun: stock.split.last, id: (next_id += 1).to_s)
        "You get some #{stock} from inside your duffel bag."
      when /\Aput (my \w+(?: \w+)?|#\d+) in (my bucket|bin|my duffel bag)\z/
        ref = Regexp.last_match(1)
        into = Regexp.last_match(2)
        next 'Perhaps you should be holding that first.' if worn.call(ref)

        hand = held.call(ref)
        next 'What were you referring to?' unless hand

        piece = world[:hands][hand]
        if into == 'my duffel bag'
          next "There isn't any more room in the duffel bag for that." if bag_full

          world[:bag][piece.name] = world[:bag].fetch(piece.name, 0) + 1
        elsif refuse
          next "There isn't any more room in the #{into.delete_prefix('my ')} for that."
        end
        world[:hands][hand] = nil
        into == 'my duffel bag' ? "You put your #{piece.noun} in your duffel bag." : "You drop your #{piece.noun} in a #{into.delete_prefix('my ')}."
      when /\Adrop (#\d+)\z/
        hand = held.call(Regexp.last_match(1))
        next 'What were you referring to?' unless hand
        next "You can't do that here." if no_floor

        world[:floor] << world[:hands][hand].name
        world[:hands][hand] = nil
        'You drop some stock.'
      when 'tap my bucket'
        'You drum your fingers on the bucket rhythmically.'
      else
        ''
      end
    end
    allow(DRC).to receive(:bput) do |command, *patterns|
      world[:sent] << command
      line = reply.call(command)
      patterns.flatten.map { |pattern| line.match(pattern) }.compact.first.to_a.first || ''
    end

    ref_of = ->(item) { item.start_with?('#') ? item : "my #{item}" }
    landed = /^You (drop|put)/
    allow(DRCI).to receive(:dispose_trash) do |item, can, verb|
      if DRC.bput("put #{ref_of.call(item)} in my #{can}", landed, /^Perhaps you should/, /^What were you/).match?(landed)
        2.times { DRC.bput("#{verb} my #{can}", /You drum/) } if verb
        next true
      end

      DRC.bput("drop #{ref_of.call(item)}", landed, /^You can't do that/, /^What were you/).match?(landed)
    end
    allow(DRCI).to receive(:put_away_item?) do |item, container|
      DRC.bput("put #{ref_of.call(item)} in my #{container}", landed, /^Perhaps you should/, /^What were you/, /^There isn't any more room/).match?(landed)
    end
    allow(DRCT).to receive(:dispose) do |item, _room|
      DRC.bput("put #{ref_of.call(item)} in bin", landed, /^Perhaps you should/, /^What were you/, /^There isn't any more room/).match?(landed)
    end
    world
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

    describe 'task_bin_leftover_stock' do
      # The binning specs set @bin_leftover_stock directly, so this pins the
      # setting name initialize reads: a misspelt name would silently leave
      # the feature off.
      [true, false, nil].each do |value|
        it "is read from the settings when built (#{value.inspect})" do
          tm = described_class.allocate
          allow(tm).to receive(:get_settings).and_return(OpenStruct.new(task_bin_leftover_stock: value))
          allow(tm).to receive(:get_data).and_return({ 'stock' => {} })
          tm.send(:initialize)
          expect(tm.instance_variable_get(:@bin_leftover_stock)).to eq(value)
        end
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
      allow(DRC).to receive(:message) { |text| events << [:message, text] unless text.start_with?("taskmaster version ") } # the version banner has its own example
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

      it 'loot_history prints each taskmaster\'s sacks and exits, Dorhum\'s empty when an older history has none' do
        UserVars.taskmaster_sacks = { 'poltu' => ['a bronze bar.'], 'bradyn' => [], 'zasele' => ['some coral dye.', 'a large haledroth shard.'] }
        expect(start(npc: 'zasele', loot_history: true)).to eq([[:message, 'Sack history for Taskmaster Poltu:'], [:message, 'a bronze bar.'],
                                                                [:message, 'Sack history for Taskmaster Bradyn:'],
                                                                [:message, 'Sack history for Taskmaster Zasele:'], [:message, 'some coral dye.'], [:message, 'a large haledroth shard.'],
                                                                [:message, 'Sack history for Taskmaster Dorhum:'],
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
          expect { tm.get_task }.not_to raise_error
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
          yield tm if block_given?
          [tm.get_task, events, tm]
        end

        let(:accepted) { %i[find ask accept finish] }
        let(:cooldown_message) { [:message, 'Task on cooldown or recently canceled a task, either way, going to have to wait.'] }

        it 'asks with the same matchers' do
          asking([offer])
          expect(DRC).to have_received(:bput).with('ask zasele for task', /if you agree to (his|her) terms/, /You may accept by typing ACCEPT TASK/, /utterly ignoring you/,
                                                   /you must wait before I can give you a task/, /You are already on a task/, /give you a chance a little later/,
                                                   TaskMaster::TASK_UNRELIABLE, /^To whom are you speaking/)
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
          expect { tm.get_task }.not_to raise_error
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

        it "asks its own taskmaster again after cancelling another taskmaster's task" do
          resumes = 0
          result, events, = asking([on_task, offer]) do |tm|
            allow(tm).to receive(:resume_task) do
              resumes += 1
              throw TaskMaster::FOREIGN_TASK_CANCELLED
            end
          end
          expect(result).to eq(:accepted)
          expect(resumes).to eq(1)
          expect(events).to eq(%i[find ask find ask accept finish])
        end

        # Zasele after a cancelled task (Mahtra, 2026-11-03 18:47), two lines.
        let(:unreliable) { '"Word has traveled.  You are unreliable.  Perhaps I\'ll give' }

        it 'waits the poll interval and asks again when the taskmaster calls you unreliable after a cancel' do
          expect(asking([unreliable, offer]).first(2)).to eq([:accepted, [:find, :ask, cooldown_message, [:pause, 7], *accepted]])
        end

        it 'asks again after a reply it does not know, instead of going on with no task' do
          expect(asking(['', '', offer]).first(2)).to eq([:accepted, [:find, :ask, [:pause, 7], :find, :ask, [:pause, 7], *accepted]])
        end

        it "stops after #{TaskMaster::MAX_UNKNOWN_TASK_REPLIES} replies in a row it does not know" do
          nil
          expect { _, _, _ = asking(Array.new(TaskMaster::MAX_UNKNOWN_TASK_REPLIES, '')) }.to raise_error(SystemExit)
          expect(DRC).to have_received(:message).with('No answer Zasele gives that taskmaster knows, 3 times in a row. Stopping.')
        end

        it 'counts unknown replies in a row only' do
          result = nil
          expect { result = asking(['', '', wait, '', '', offer]) }.not_to raise_error
          expect(result.first).to eq(:accepted)
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

      describe 'a task from another taskmaster' do
        # The journal as the game prints it (Fidon, 2026-11).
        let(:zasele_journal) do
          'While visiting Andreshlew for the Hollow Eve festivities, Zasele has asked you to craft some items to assist her ongoing efforts with the Merelew and others.  ' \
            'In particular, she wanted you to craft a coil of reinforced cloth rope and indicated that 3 would suffice.  So far, you have returned 0 to her.'
        end

        it 'reads the item, the count and the taskmaster off the full journal line' do
          tm = reader
          game('task' => zasele_journal)

          expect(tm.read_task).to eq(['rope', 3])
          expect(tm.instance_variable_get(:@task_giver)).to eq('zasele')
        end

        it "stops on Zasele's task when started for Dorhum, before handing anything in, saying how to finish or cancel it" do
          tm = reader(npc: 'dorhum')
          game('task' => zasele_journal)
          expect(tm).not_to receive(:turn_in_banked)

          expect { tm.resume_task }.to raise_error(SystemExit)

          expect(tm.instance_variable_get(:@npc)).to eq('dorhum')
          expect(DRC).to have_received(:message)
            .with('You are on a task for Zasele, not Dorhum. Finish it with ;taskmaster zasele, or cancel it with ASK ZASELE FOR TASK CANCEL (taskmasters then refuse you for about ten minutes). Or set task_cancel_foreign_tasks to have taskmaster cancel such tasks itself.')
        end

        it "stops on a task from a taskmaster it doesn't do, saying to finish it by hand" do
          tm = reader(npc: 'zasele')
          game('task' => zasele_journal.sub('Zasele has asked', 'Nezhiri has asked'))
          expect(tm).not_to receive(:turn_in_banked)
          expect(tm).not_to receive(:cancel_task)

          expect { tm.resume_task }.to raise_error(SystemExit)

          expect(DRC).to have_received(:message)
            .with('You are on a task for Nezhiri, not Zasele. Nezhiri is not a taskmaster this script does, so finish it yourself, or cancel it with ASK NEZHIRI FOR TASK CANCEL (taskmasters then refuse you for about ten minutes). Or set task_cancel_foreign_tasks to have taskmaster cancel such tasks itself.')
        end

        it "with task_cancel_foreign_tasks, cancels another taskmaster's task, waits out the cooldown and goes back to its own" do
          tm = reader(npc: 'zasele', cancel_foreign_tasks: true)
          game('task' => zasele_journal.sub('Zasele has asked', 'Dorhum has asked'))
          allow(tm).to receive(:pause)
          expect(tm).to receive(:cancel_task).with('dorhum', 'rope')
          expect(tm).not_to receive(:turn_in_banked)

          expect { tm.resume_task }.to throw_symbol(TaskMaster::FOREIGN_TASK_CANCELLED)

          expect(tm).to have_received(:pause).with(600)
          expect(tm.instance_variable_get(:@npc)).to eq('zasele')
        end

        it 'keeps the taskmaster it was started for when the journal names none' do
          tm = reader(npc: 'zasele')
          game('task' => journal('a coil of reinforced cloth rope', 3))

          tm.read_task
          tm.check_task_giver

          expect(tm.instance_variable_get(:@npc)).to eq('zasele')
        end
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

      describe 'sets written for someone else' do
        let(:foreign) { "You can't read the ink printed on the rope instructions.  They were written by or for someone else." }
        let(:usable) { 'These instructions appear to be very fragile and will wear out quickly when studied.  They have only 4 uses remaining.' }

        def carrying(replies)
          tm = reader(worn_trashcan: 'bucket', worn_trashcan_verb: 'drop')
          allow(DRCI).to receive(:get_item?) { !replies.empty? }
          game('read my rope instructions' => ->(*) { replies.shift })
          allow(tm).to receive(:request_replacement)
          allow(DRCC).to receive(:stow_crafting_item)
          tm
        end

        it 'throws a foreign set away instead of putting it back, then asks for a fresh one' do
          tm = carrying([foreign])
          expect(DRCI).to receive(:dispose_trash).with('rope instructions', 'bucket', 'drop').and_return(true)

          tm.ensure_instructions('rope', 2)

          expect(DRCC).not_to have_received(:stow_crafting_item)
          expect(tm).to have_received(:request_replacement).with('rope')
        end

        it 'uses a good set carried behind a foreign one, asking for nothing' do
          tm = carrying([foreign, usable])
          allow(DRCI).to receive(:dispose_trash).and_return(true)

          tm.ensure_instructions('rope', 3)

          expect(tm).not_to have_received(:request_replacement)
        end

        it 'puts a foreign set back when the trash will not take it, and asks once' do
          tm = carrying([foreign, foreign])
          allow(DRCI).to receive(:dispose_trash).and_return(false)

          tm.ensure_instructions('rope', 2)

          expect(DRCC).to have_received(:stow_crafting_item).with('rope instructions', 'duffel bag', nil).once
          expect(tm).to have_received(:request_replacement).once
        end

        it "stops looking after #{TaskMaster::MAX_CARRIED_SETS} sets" do
          tm = carrying(Array.new(10, foreign))
          allow(DRCI).to receive(:dispose_trash).and_return(true)

          tm.ensure_instructions('rope', 2)

          expect(DRCI).to have_received(:dispose_trash).exactly(TaskMaster::MAX_CARRIED_SETS).times
          expect(tm).to have_received(:request_replacement).once
        end
      end

      it 'counts the items still owed after the banked ones are in' do
        expect(resume(owed: 6, target: 8, banked: 1, uses: 6)).to include([:make, 'rope', 5])
      end
    end

    describe '#turn_in_banked' do
      it 'puts back an item the taskmaster will not take, after five tries in a row, and stops handing in' do
        tm = reader
        allow(DRCI).to receive(:get_item?).and_return(true)
        allow(DRCI).to receive(:in_hands?).and_return(true)
        allow(DRC).to receive(:bput).and_return('Zasele shakes her head.')
        expect(DRCC).to receive(:stow_crafting_item).with('rope', 'duffel bag', nil)
        expect(tm.turn_in_banked('rope', 4)).to eq(4)
        expect(DRC).to have_received(:bput).with('give my rope to zasele', any_args).exactly(5).times
      end

      it "gives again through four replies it did not know, as complete_task does, and carries on" do
        tm = reader
        allow(DRCC).to receive(:stow_crafting_item)
        replies = ['', '', '', '', more_needed(2), more_needed(1)]
        allow(tm).to receive(:give_item) { replies.shift }

        expect(tm.turn_in_banked('rope', 3)).to eq(1)

        expect(DRCC).not_to have_received(:stow_crafting_item)
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
      def trasher(remainder:, **world_options)
        world = stock_world({ 'burlap cloth' => 1 }, **world_options)
        build(remainder: remainder).trash('rope', 'cloth', 'burlap')
        world
      end

      it 'leaves the instructions alone, so a task that is not handed in yet keeps them' do
        expect(trasher(remainder: false)[:sent]).to eq([])
      end

      it 'throws away leftover stock by the id of the piece in hand, in the bin room' do
        world = trasher(remainder: true)
        expect(DRCT).to have_received(:dispose).with('#2222486', 14_886)
        expect(world[:sent]).to include('put #2222486 in bin')
        expect(world[:hands].values).to all(be_nil)
        expect(world[:bag]).to eq({ 'burlap cloth' => 0 })
      end

      it 'takes leftover ingots to the forge bin' do
        stock_world({ 'bronze ingot' => 1 })
        build(remainder: true).trash('hammer', 'ingot', 'bronze')
        expect(DRCT).to have_received(:dispose).with('#2222486', 793)
      end

      # Before, the result of the disposal was ignored: the refused piece
      # stayed in hand, the next get filled the other hand, and the third
      # answered "You need a free hand", leaving two pieces for the next
      # task's STOW to send to the default container.
      it 'puts a piece the bin refuses back in the bag by its id and stops, leaving both hands empty' do
        world = stock_world({ 'burlap cloth' => 3 }, refuse: true)
        build(remainder: true).trash('rope', 'cloth', 'burlap')
        expect(world[:sent].count('get my burlap cloth from my duffel bag')).to eq(1)
        expect(world[:sent]).to include('put #2222486 in my duffel bag')
        expect(world[:hands].values).to all(be_nil)
        expect(world[:bag]).to eq({ 'burlap cloth' => 3 })
      end

      it 'says which piece is left when it can be neither thrown away nor put back' do
        world = stock_world({ 'burlap cloth' => 3 }, refuse: true, bag_full: true)
        build(remainder: true).trash('rope', 'cloth', 'burlap')
        expect(world[:sent].count('get my burlap cloth from my duffel bag')).to eq(1)
        expect(DRC).to have_received(:message).with(a_string_including('burlap cloth (#2222486)', 'Stopping'))
      end

      it 'stops at TRASH_CAP pieces when every piece goes in the bin' do
        cap = described_class::TRASH_CAP
        world = stock_world({ 'burlap cloth' => cap + 10 })
        build(remainder: true).trash('rope', 'cloth', 'burlap')
        expect(DRCT).to have_received(:dispose).exactly(cap).times
        expect(world[:bag]).to eq({ 'burlap cloth' => 10 })
      end

      it 'disposes of nothing and says why when both hands are full' do
        full = OpenStruct.new(name: 'iron chisels', noun: 'chisels', id: '1')
        world = stock_world({ 'burlap cloth' => 3 }, hands: { right: full, left: full })
        build(remainder: true).trash('rope', 'cloth', 'burlap')
        expect(world[:sent]).to eq(['get my burlap cloth from my duffel bag'])
        expect(DRCT).not_to have_received(:dispose)
        expect(DRC).to have_received(:message).with(a_string_including('Both hands are full', 'burlap cloth'))
      end

      # A get no pattern matched (bput timed out) must not dispose of
      # whatever happens to be in hand.
      it 'stops without disposing when the get goes unanswered' do
        world = stock_world({ 'burlap cloth' => 3 })
        allow(DRC).to receive(:bput) do |command, *|
          world[:sent] << command
          ''
        end
        build(remainder: true).trash('rope', 'cloth', 'burlap')
        expect(world[:sent]).to eq(['get my burlap cloth from my duffel bag'])
        expect(DRCT).not_to have_received(:dispose)
      end

      it 'stops with a message instead of throwing away a piece it cannot find in hand, after one put-back by name' do
        world = stock_world({ 'burlap cloth' => 3 })
        allow(DRC).to receive(:bput) do |command, *|
          world[:sent] << command
          'You get'
        end
        build(remainder: true).trash('rope', 'cloth', 'burlap')
        expect(world[:sent]).to eq(['get my burlap cloth from my duffel bag', 'put my burlap cloth in my duffel bag'])
        expect(DRCT).not_to have_received(:dispose)
        expect(DRC).to have_received(:message).with(a_string_including("can't find it in your hands", 'may still be in your hand', 'Stopping'))
      end

      # A put whose reply bput did not know waits out its timeout and comes
      # back false, though the piece went in the bin; putting it back by id
      # then fails ("What were you referring to?") and used to stop all
      # disposal with a message that the piece may be in hand.
      it 'goes on to the next piece when the bin took one with a reply it did not know' do
        world = stock_world({ 'burlap cloth' => 3 })
        allow(DRCT).to receive(:dispose) do |item, _room|
          DRC.bput("put #{item} in bin", /^You (drop|put)/)
          false
        end
        build(remainder: true).trash('rope', 'cloth', 'burlap')
        expect(world[:bag]).to eq({ 'burlap cloth' => 0 })
        expect(world[:sent]).not_to include(a_string_ending_with('in my duffel bag'))
        expect(world[:hands].values).to all(be_nil)
        expect(DRC).not_to have_received(:message)
      end
    end

    describe '#zasele leftover stock' do
      def tailor(worn_trashcan:, bin_leftover_stock: true)
        tm = build(worn_trashcan: worn_trashcan, bin_leftover_stock: bin_leftover_stock, settings: { outfitting_tools: ['scissors'] })
        allow(tm).to receive(:buy_stackables)
        allow(tm).to receive(:tailor_item)
        allow(tm).to receive(:repair)
        allow(tm).to receive(:trash)
        tm.zasele('rope', 8, 10, 'cloth', 'burlap')
        tm
      end

      it 'skips the walk to the bin room when opted in with a worn trash can (the stock is binned after the hand-in)' do
        expect(tailor(worn_trashcan: 'bucket')).not_to have_received(:trash)
      end

      it 'still walks leftover stock to the bin room when not opted in, even with a worn trash can' do
        expect(tailor(worn_trashcan: 'bucket', bin_leftover_stock: nil)).to have_received(:trash).with('rope', 'cloth', 'burlap')
      end

      it 'still walks leftover stock to the bin room without a worn trash can' do
        expect(tailor(worn_trashcan: nil)).to have_received(:trash).with('rope', 'cloth', 'burlap')
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

      it 'checks the cotton thread once, from the stock room, never the bare noun a spun spool shares' do
        checks, = tailor('leather')
        expect(checks.select { |c| c.first == 'cotton thread' }.map { |c| c[1..2] }).to eq([[16667, 6]])
        expect(checks.map(&:first)).not_to include('thread')
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
        expect(checks.map(&:first)).to eq(['pins', 'cotton thread'])
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

    describe 'buying task stock (#buy_stackables, #buy_yarn)' do
      # Stock prices and order numbers mirroring data/base-crafting.yaml.
      let(:stockdata) do
        { 'burlap' => { 'stock-value' => 437, 'stock-number' => 8 }, 'rat' => { 'stock-value' => 750, 'stock-number' => 2 },
          'yarn' => { 'stock-value' => 625, 'stock-number' => 13 }, 'balsa' => { 'stock-value' => 500, 'stock-number' => 4 } }
      end
      # Barrask's leftover rat leather, as it sat in his right hand
      # (Hollow Eve 2026-11-04).
      let(:leftover_leather) { OpenStruct.new(name: 'rat leather', noun: 'leather', id: '2222485', yards: 10) }
      let(:hands_full) { 'You realize your hands are full, and stop.' }
      let(:must_hold_both) { 'You must be holding both substances to combine them.  For more information, see HELP VERB COMBINE.' }

      # The stock shop, the hands and the crafting bag, answering commands by
      # "#id" the way the game does. Each piece bought goes to the first free
      # hand with a new id and `yards` yards; with both hands full the sale
      # gets "You realize your hands are full, and stop." His pack is full, so
      # any STOW gets "There isn't any more room". bag_room: pieces the
      # crafting bag still takes. coins: pieces he can pay for. refuse_after:
      # sales that go through before every later one gets the hands-full line.
      # lost: the sale goes through but no piece reaches a hand. late_from: from
      # that sale on (0-based) the piece lands but the clerk's line comes after
      # bput's timeout, so order_item returns ''. refuse_combine:
      # COMBINE always answers "You must be holding both". keep_new: a combine
      # keeps the new piece's id instead of the stack's. new_id_combine: the
      # combined stack comes back under an id neither had. hollow_combine:
      # COMBINE answers "You combine" but both pieces stay in hand.
      # silent_combine / silent_count: that command goes unanswered (bput's
      # '').
      #
      # DRCT, DRCI and DRCC are harness doubles, so order_item and
      # put_away_item? stand in for lich-5 v5.23.0 here and send their
      # commands through the world: order_item asks twice and returns nil on
      # "you don't have enough coins", else the second reply's match, '' when
      # none. The clerk's lines other than the hands-full one are stand-ins
      # carrying the substring order_item matches. stow_crafting_item (the
      # parent's stow by noun) is taken as landing.
      #
      # @return [Hash] :hands, :bag (items in the crafting bag), :orders, :sent
      def shop(hands: {}, yards: 10, bag_room: 100, coins: 100, refuse_after: nil, lost: false, late_from: nil,
               refuse_combine: false, keep_new: false, new_id_combine: false, hollow_combine: false, silent_combine: false,
               silent_count: false)
        world = { hands: { right: nil, left: nil }.merge(hands), bag: [], orders: [], sent: [], sold: 0, asked: false }
        next_id = 3_000_000
        allow(GameObj).to receive(:right_hand) { world[:hands][:right] || OpenStruct.new(name: 'Empty', noun: nil, id: nil) }
        allow(GameObj).to receive(:left_hand) { world[:hands][:left] || OpenStruct.new(name: 'Empty', noun: nil, id: nil) }
        allow(DRC).to receive(:right_hand) { world[:hands][:right]&.name }
        allow(DRC).to receive(:left_hand) { world[:hands][:left]&.name }

        hand_of = ->(ref) { world[:hands].find { |_, obj| obj && "##{obj.id}" == ref }&.first }
        sell = lambda do |number|
          name = { 8 => 'burlap cloth', 2 => 'rat leather', 13 => 'wool yarn', 4 => 'balsa lumber' }.fetch(number)
          free = world[:hands].find { |_, obj| obj.nil? }&.first
          next hands_full if free.nil? || (refuse_after && world[:sold] >= refuse_after)

          late = late_from && world[:sold] >= late_from
          world[:sold] += 1
          world[:hands][free] = OpenStruct.new(name: name, noun: name.split.last, id: (next_id += 1).to_s, yards: yards) unless lost
          late ? '' : "The clerk takes some coins from you and hands you some #{name}."
        end
        combine = lambda do |first, second|
          next must_hold_both if refuse_combine || first.nil? || second.nil? || first == second
          next 'You combine the stacks.' if hollow_combine

          kept, gone = keep_new ? [second, first] : [first, second]
          world[:hands][kept].yards += world[:hands][gone].yards
          world[:hands][gone] = nil
          world[:hands][kept].id = (next_id += 1).to_s if new_id_combine
          silent_combine ? '' : 'You combine the stacks.'
        end
        reply = lambda do |command|
          case command
          when /\Aorder (\d+)\z/
            world[:asked] = !world[:asked]
            next 'The clerk says, "Just order it again to buy it."' if world[:asked]
            next "The clerk frowns, since you don't have enough coins." if world[:sold] >= coins

            sell.call(Regexp.last_match(1).to_i)
          when /\Acombine (#\d+) with (#\d+)\z/
            combine.call(hand_of.call(Regexp.last_match(1)), hand_of.call(Regexp.last_match(2)))
          when /\Acombine (\w+)\z/
            noun = Regexp.last_match(1)
            held = world[:hands].select { |_, obj| obj&.noun == noun }.keys
            combine.call(*(held.size == 2 ? held : [nil, nil]))
          when /\Acount (#\d+)\z/
            hand = hand_of.call(Regexp.last_match(1))
            next 'I could not find what you were referring to.' unless hand
            next '' if silent_count

            "You count out #{world[:hands][hand].yards} yards of material there."
          when /\Aput (#\d+) in my duffel bag\z/
            hand = hand_of.call(Regexp.last_match(1))
            next 'What were you referring to?' unless hand
            next "There isn't any more room in the duffel bag for that." if world[:bag].size >= bag_room

            world[:bag] << world[:hands][hand]
            world[:hands][hand] = nil
            "You put your #{world[:bag].last.noun} in your duffel bag."
          when /\Astow /
            "There isn't any more room in the traveler's pack for that."
          else
            ''
          end
        end
        allow(DRC).to receive(:bput) do |command, *patterns|
          world[:sent] << command
          line = reply.call(command)
          patterns.flatten.map { |pattern| line.match(pattern) }.compact.first.to_a.first || ''
        end

        allow(DRCT).to receive(:order_item) do |room, number|
          world[:orders] << [room, number]
          next if DRC.bput("order #{number}", 'Just order it again', "you don't have enough coins") == "you don't have enough coins"

          DRC.bput("order #{number}", 'takes some coins from you')
        end
        allow(DRCI).to receive(:put_away_item?) do |item, container|
          DRC.bput("put #{item} in my #{container}", /^You put/, /^What were you/, /^There isn't any more room/).start_with?('You put')
        end
        allow(DRCC).to receive(:stow_crafting_item) do |noun, *_rest|
          hand = world[:hands].find { |_, obj| obj&.noun == noun }&.first
          world[:bag] << world[:hands][hand] if hand
          world[:hands][hand] = nil if hand
          true
        end
        world
      end

      def buyer
        build(stockdata: stockdata, settings: { engineering_belt: nil })
      end

      # The yards of a stock that went in the crafting bag in one piece.
      def bagged(world, name)
        world[:bag].select { |obj| obj.name == name }.map(&:yards)
      end

      context 'the Hollow Eve replay: leftover leather in the right hand, the pack full' do
        it 'puts the leather in the crafting bag by its id first, then buys and bags all 60 yards' do
          world = shop(hands: { right: leftover_leather })

          buyer.buy_stackables('rope', 6, 10, 'cloth')

          expect(bagged(world, 'burlap cloth')).to eq([60])
          expect(world[:sent].first).to eq('put #2222485 in my duffel bag')
          expect(bagged(world, 'rat leather')).to eq([10])
          expect(world[:orders]).to eq([[16_667, 8]] * 6)
          expect(world[:hands].values.compact).to be_empty
        end

        it 'stops before ordering anything when the leather will not go in the crafting bag either, naming it and its id' do
          world = shop(hands: { right: leftover_leather }, bag_room: 0)

          expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.to raise_error(SystemExit)
          expect(world[:orders]).to be_empty
          expect(DRC).to have_received(:message).with(/rat leather \(#2222485\).*Stopping/)
        end

        it 'empties both hands, the left as well as the right' do
          shield = OpenStruct.new(name: 'target shield', noun: 'shield', id: '4444', yards: 0)
          world = shop(hands: { right: leftover_leather, left: shield })

          buyer.buy_stackables('rope', 2, 10, 'cloth')

          expect(world[:sent].first(2)).to eq(['put #2222485 in my duffel bag', 'put #4444 in my duffel bag'])
          expect(bagged(world, 'burlap cloth')).to eq([20])
        end
      end

      it 'stops, without starting the task short, when an order gets "You realize your hands are full, and stop."' do
        world = shop(refuse_after: 2)

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/Could not buy burlap cloth: the order did not go through.*Stopping\./)
        expect(world[:orders].size).to eq(3)
        expect(bagged(world, 'burlap cloth')).to eq([20])
      end

      it 'puts back the piece that landed when the first order still comes back empty, leaving both hands empty' do
        world = shop(late_from: 0)

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/Could not buy burlap cloth: the order did not go through.*Stopping\./)
        expect(world[:hands].values.compact).to be_empty
        expect(bagged(world, 'burlap cloth')).to eq([10])
      end

      it 'puts back the stack and the late piece both when a later order comes back empty' do
        world = shop(late_from: 1)

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.to raise_error(SystemExit)
        expect(world[:orders].size).to eq(2)
        expect(world[:sent].grep(/\Aput #/).size).to eq(2)
        expect(world[:hands].values.compact).to be_empty
        expect(bagged(world, 'burlap cloth')).to eq([10, 10])
      end

      it 'stops at the first order he cannot pay for (order_item returns nil)' do
        world = shop(coins: 1)

        expect { buyer.buy_stackables('rope', 3, 10, 'cloth') }.to raise_error(SystemExit)
        expect(world[:orders].size).to eq(2)
        expect(bagged(world, 'burlap cloth')).to eq([10])
      end

      it 'stops when the sale goes through but no piece reaches a hand' do
        shop(lost: true)

        expect { buyer.buy_stackables('rope', 1, 10, 'cloth') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/no new piece is in your hands/)
      end

      it 'takes "You must be holding both substances" as a failed combine, and puts both pieces back' do
        world = shop(refuse_combine: true)

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.to raise_error(SystemExit)
        expect(world[:orders].size).to eq(2)
        expect(DRC).to have_received(:message).with(/Could not combine the burlap cloth \(You must be holding both/)
        expect(bagged(world, 'burlap cloth')).to eq([10, 10])
      end

      it 'follows the stack when the combine keeps the new piece\'s id' do
        world = shop(keep_new: true)

        buyer.buy_stackables('rope', 3, 10, 'cloth')

        expect(bagged(world, 'burlap cloth')).to eq([30])
      end

      it 'follows the stack, counts it and bags it, when "You combine" leaves one id neither piece had' do
        world = shop(new_id_combine: true)

        expect { buyer.buy_stackables('rope', 3, 10, 'cloth') }.not_to raise_error

        expect(world[:sent]).to include('combine cloth', 'count #3000005', 'put #3000005 in my duffel bag')
        expect(world[:sent].grep(/\Acombine #/)).to be_empty
        expect(bagged(world, 'burlap cloth')).to eq([30])
        expect(world[:hands].values.compact).to be_empty
      end

      it 'still stops on the yards counted when a stack under a new id is short' do
        world = shop(new_id_combine: true, yards: 5)

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/Bought 30 yards of burlap cloth, but the task needs 60: 30 yards missing/)
        expect(bagged(world, 'burlap cloth')).to eq([30])
      end

      it 'says the game claimed a combine the hands do not show, and puts both pieces back, when both stay in hand' do
        world = shop(hollow_combine: true)

        expect { buyer.buy_stackables('rope', 3, 10, 'cloth') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message)
          .with(/Could not combine the burlap cloth \(the game said it combined them, but your hands hold #3000001 and #3000002\)\. Stopping\./)
        expect(world[:orders].size).to eq(2)
        expect(world[:hands].values.compact).to be_empty
        expect(bagged(world, 'burlap cloth')).to eq([10, 10])
      end

      it 'names by id the stock it could not put back when the crafting bag refuses it on a stop' do
        world = shop(refuse_after: 2, bag_room: 0)

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message)
          .with(/Could not buy burlap cloth: the order did not go through.*\. #3000001 would not go back in your duffel bag and is still in your hands; put it away before starting again\. Stopping\./)
        expect(world[:hands].values.compact.map(&:yards)).to eq([20])
      end

      it 'names nothing as left in hand when every put-back on a stop goes through' do
        shop(refuse_after: 2)

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/\A[^#]*full hands\)\. Stopping\.\z/)
      end

      it 'trusts the hands when a combine goes unanswered but only the stack is left in hand' do
        world = shop(silent_combine: true)

        buyer.buy_stackables('rope', 2, 10, 'cloth')

        expect(bagged(world, 'burlap cloth')).to eq([20])
      end

      it 'counts the stack by id and stops, saying how much is missing, when it is short' do
        world = shop(yards: 5)

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.to raise_error(SystemExit)
        expect(world[:sent]).to include(a_string_matching(/\Acount #\d+\z/))
        expect(DRC).to have_received(:message).with(/Bought 30 yards of burlap cloth, but the task needs 60: 30 yards missing/)
        expect(bagged(world, 'burlap cloth')).to eq([30])
      end

      it 'takes an unanswered count as nothing counted, and stops' do
        shop(silent_count: true)

        expect { buyer.buy_stackables('rope', 1, 10, 'cloth') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/Bought 0 yards of burlap cloth, but the task needs 10: 10 yards missing/)
      end

      it 'stops when the bought stack will not go in the crafting bag' do
        world = shop(hands: { right: leftover_leather }, bag_room: 1)

        expect { buyer.buy_stackables('rope', 2, 10, 'cloth') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/Could not put the burlap cloth you bought \(#\d+\) in your duffel bag\. Stopping/)
        expect(world[:hands].values.compact.map(&:yards)).to eq([20])
      end

      it 'buys rat leather by its own order number for a leather task' do
        world = shop

        buyer.buy_stackables('belt', 2, 15, 'leather')

        expect(world[:orders]).to eq([[16_667, 2]] * 3)
        expect(bagged(world, 'rat leather')).to eq([30])
      end

      it 'buys 100-yard yarn by the yard needed, combines it and checks it' do
        world = shop(yards: 100)

        buyer.buy_yarn('scarf', 3, 50, 'yarn')

        expect(world[:orders]).to eq([[16_667, 13]] * 2)
        expect(bagged(world, 'wool yarn')).to eq([200])
      end

      it 'stops a yarn task short of yards as well' do
        shop(yards: 40)

        expect { buyer.buy_yarn('scarf', 3, 50, 'yarn') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/Bought 80 yards of wool yarn, but the task needs 150: 70 yards missing/)
      end

      it 'buys and bags lumber by id without counting it in yards' do
        world = shop

        buyer.buy_stackables('bowl', 2, 5, 'lumber')

        expect(world[:sent].grep(/\Acount /)).to be_empty
        expect(bagged(world, 'balsa lumber')).to eq([10])
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

      it 'puts back an item the taskmaster does not take and stops, instead of handing it over again' do
        tm = finisher
        allow(DRCI).to receive(:in_hands?).and_return(true)
        allow(DRCC).to receive(:stow_crafting_item)
        gives = 0
        game('give my rope to zasele' => lambda do |*|
          gives += 1
          raise 'gave the refused rope again' if gives > 6

          gives == 1 ? more_needed(1) : ''
        end)

        expect { tm.complete_task('rope', 2) }.to raise_error(SystemExit)

        expect(gives).to eq(6)
        expect(DRCC).to have_received(:stow_crafting_item).with('rope', 'duffel bag', nil)
        expect(DRC).to have_received(:message).with('Zasele did not take the rope. Stopping.')
        expect(tm).not_to have_received(:sort_sack)
      end

      it 'gives once more after one reply it did not know, and carries on when that one lands' do
        tm = finisher
        replies = [more_needed(1), '', sack_handed]
        allow(tm).to receive(:give_item) { replies.shift }
        expect(tm).not_to receive(:refused_hand_in)

        tm.complete_task('rope', 2)

        expect(tm).to have_received(:sort_sack).with('rope')
      end

      it "keeps giving through four replies it did not know, as Zasele's \"Don't be silly.\" on a fleet log, and finishes" do
        tm = finisher
        replies = ['', '', '', '', more_needed(1), sack_handed]
        allow(tm).to receive(:give_item) { replies.shift }
        expect(tm).not_to receive(:refused_hand_in)

        tm.complete_task('rope', 2)

        expect(tm).to have_received(:sort_sack).with('rope')
      end

      it 'counts unknown replies in a row only' do
        tm = finisher
        # Six in all, but never five in a row.
        replies = ['', '', '', more_needed(1), '', '', '', sack_handed]
        allow(tm).to receive(:give_item) { replies.shift }
        expect(tm).not_to receive(:refused_hand_in)

        tm.complete_task('rope', 3)
      end

      it 'quotes what the taskmaster said when the reply was one bput knew' do
        tm = finisher
        allow(tm).to receive(:give_item).and_return('What is it')
        allow(DRCC).to receive(:stow_crafting_item)

        expect { tm.complete_task('rope', 2) }.to raise_error(SystemExit)

        expect(DRC).to have_received(:message).with('Zasele did not take the rope (What is it). Stopping.')
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

    describe '#bin_task_stock' do
      def binner(**ivars)
        build(worn_trashcan: 'bucket', worn_trashcan_verb: 'tap', bin_leftover_stock: true, **ivars)
      end

      it 'is off by default: base.yaml declares task_bin_leftover_stock false' do
        expect(base_yaml).to include('task_bin_leftover_stock' => false)
      end

      # Marathon restocks once and check_stock reuses the carried stack for
      # every task; binning it after each hand-in would force a full restock
      # (up to 100 yards of cloth and leather, 400 of yarn) every time.
      it "keeps a marathon's carried restock stack, even with the setting on" do
        world = stock_world({ 'burlap cloth' => 1, 'rat leather' => 1, 'wool yarn' => 1 })
        expect(binner(marathon: true).bin_task_stock).to eq(0)
        expect(world[:sent]).to be_empty
      end

      [nil, false].each do |setting|
        it "sends nothing when task_bin_leftover_stock is #{setting.inspect}, even with a worn trash can" do
          world = stock_world({ 'burlap cloth' => 3 })
          expect(binner(bin_leftover_stock: setting).bin_task_stock).to eq(0)
          expect(world[:sent]).to be_empty
        end
      end

      it "bins every piece of Zasele's stock from the crafting bag into the worn trash can, each by its id, then taps it twice" do
        world = stock_world({ 'burlap cloth' => 3, 'rat leather' => 1, 'wool yarn' => 2 })
        expect(binner.bin_task_stock).to eq(6)
        expect(world[:bag].values).to all(eq(0))
        expect(world[:hands].values).to all(be_nil)
        expect(world[:sent].reject { |command| command.start_with?('get ') })
          .to eq((2_222_486..2_222_491).map { |id| "put ##{id} in my bucket" } + ['tap my bucket', 'tap my bucket'])
        expect(DRC).to have_received(:message).with('Binned 6 piece(s) of leftover task stock')
      end

      # The incident: Barrask wears "sinuous leathers", so "put my leather in
      # my bucket" and the fallback "put my leather in my duffel bag" both
      # answered "Perhaps you should be holding that first.", and the rat
      # leather stayed in his hand for the next task's STOW.
      it 'bins a leather by its id while the character wears "sinuous leathers" that "my leather" names' do
        world = stock_world({ 'rat leather' => 1 }, worn_leathers: true)
        expect(binner.bin_task_stock).to eq(1)
        expect(world[:sent]).to include('put #2222486 in my bucket')
        expect(world[:hands].values).to all(be_nil)
        expect(world[:bag]).to eq({ 'rat leather' => 0 })
      end

      it 'sends nothing without a worn trash can, so nothing is ever dropped' do
        world = stock_world({ 'burlap cloth' => 3 })
        expect(binner(worn_trashcan: nil).bin_task_stock).to eq(0)
        expect(world[:sent]).to be_empty
      end

      it "leaves other taskmasters' stock alone" do
        world = stock_world({ 'burlap cloth' => 3 })
        expect(binner(npc: 'poltu').bin_task_stock).to eq(0)
        expect(world[:sent]).to be_empty
      end

      it 'neither taps nor reports when there was nothing to bin' do
        world = stock_world({})
        expect(binner.bin_task_stock).to eq(0)
        expect(world[:sent]).not_to include('tap my bucket')
        expect(DRC).not_to have_received(:message)
      end

      it 'does not tap without a trash can verb' do
        world = stock_world({ 'burlap cloth' => 1 })
        expect(binner(worn_trashcan_verb: nil).bin_task_stock).to eq(1)
        expect(world[:sent]).not_to include(a_string_starting_with('tap'))
      end

      # DRCI.dispose_trash (v5.23.0) drops a piece the worn trash can refuses
      # on the floor and returns true, so binning through it littered every
      # leftover piece in Zasele's room and counted it as binned.
      it 'never drops a piece the full worn trash can refuses: it goes back in the bag by its id' do
        world = stock_world({ 'burlap cloth' => 3 }, refuse: true)
        expect(binner.bin_task_stock).to eq(0)
        expect(world[:floor]).to be_empty
        expect(world[:sent]).not_to include(a_string_starting_with('drop'))
        expect(world[:sent]).to include('put #2222486 in my duffel bag')
        expect(world[:bag]).to eq({ 'burlap cloth' => 3 })
        expect(DRC).not_to have_received(:message).with(a_string_starting_with('Binned'))
      end

      it 'puts a refused piece back in the bag by its id, stops that stock and carries on with the next' do
        world = stock_world({ 'burlap cloth' => 3, 'wool yarn' => 1 }, refuse: true)
        expect(binner.bin_task_stock).to eq(0)
        expect(world[:sent].count('get my burlap cloth from my duffel bag')).to eq(1)
        expect(world[:sent]).to include('put #2222486 in my duffel bag', 'get my wool yarn from my duffel bag', 'put #2222487 in my duffel bag')
        expect(world[:hands].values).to all(be_nil)
        expect(world[:bag]).to eq({ 'burlap cloth' => 3, 'wool yarn' => 1 })
      end

      it 'says which piece is left in hand when it can be neither binned nor put back' do
        world = stock_world({ 'rat leather' => 2 }, worn_leathers: true, refuse: true, bag_full: true, no_floor: true)
        expect(binner.bin_task_stock).to eq(0)
        expect(world[:sent].count('get my rat leather from my duffel bag')).to eq(1)
        expect(DRC).to have_received(:message).with(a_string_including('rat leather (#2222486)', 'duffel bag', 'Stopping'))
      end

      # With a piece stuck in one hand, going on to the next stock filled the
      # other: both hands full, the start of the 2026-11-04 cascade.
      it 'gets no other stock once a piece may be left in hand, so the other hand stays free' do
        world = stock_world({ 'burlap cloth' => 2, 'rat leather' => 2, 'wool yarn' => 2 },
                            refuse: true, bag_full: true, no_floor: true)
        expect(binner.bin_task_stock).to eq(0)
        expect(world[:sent].grep(/\Aget /)).to eq(['get my burlap cloth from my duffel bag'])
        expect(world[:hands][:left]).to be_nil
        expect(DRC).to have_received(:message).with(a_string_including('burlap cloth (#2222486)', 'Stopping')).once
        expect(DRC).not_to have_received(:message).with(a_string_including('Both hands are full'))
      end

      it 'keeps what it binned before a piece got stuck, and still taps and reports it' do
        world = stock_world({ 'burlap cloth' => 2, 'rat leather' => 1, 'wool yarn' => 1 })
        allow(DRCI).to receive(:put_away_item?) do |item, container|
          landed = item == '#2222486' || item == '#2222487'
          DRC.bput("put #{item} in my #{container}", /^You (drop|put)/) if landed
          landed
        end
        expect(binner.bin_task_stock).to eq(2)
        expect(world[:sent].grep(/\Aget /)).to eq(['get my burlap cloth from my duffel bag'] * 3 + ['get my rat leather from my duffel bag'])
        expect(world[:hands].values.compact.map(&:id)).to eq(['2222488'])
        expect(world[:sent].last(2)).to eq(['tap my bucket', 'tap my bucket'])
        expect(DRC).to have_received(:message).with('Binned 2 piece(s) of leftover task stock')
      end

      it 'stops at TASK_STOCK_BIN_CAP pieces per stock' do
        cap = described_class::TASK_STOCK_BIN_CAP
        world = stock_world({ 'burlap cloth' => cap + 5 })
        expect(binner.bin_task_stock).to eq(cap)
        expect(world[:sent].count('get my burlap cloth from my duffel bag')).to eq(cap)
      end

      it 'stops on full hands without putting anything away, says why once, and tries no other stock' do
        full = OpenStruct.new(name: 'iron chisels', noun: 'chisels', id: '1')
        world = stock_world({ 'burlap cloth' => 3, 'rat leather' => 1 }, hands: { right: full, left: full })
        expect(binner.bin_task_stock).to eq(0)
        expect(world[:sent]).to eq(['get my burlap cloth from my duffel bag'])
        expect(DRC).to have_received(:message).with(a_string_including('Both hands are full', 'burlap cloth')).once
      end

      # A piece already in hand from an earlier task must not be mistaken
      # for the one just taken out: the id is the one that newly appeared.
      it 'bins the piece it just took out, not a same-noun piece already in the other hand' do
        old = OpenStruct.new(name: 'rat leather', noun: 'leather', id: '2222485')
        world = stock_world({ 'rat leather' => 1 }, hands: { right: old })
        binner.bin_task_stock
        expect(DRCI).to have_received(:put_away_item?).with('#2222486', 'bucket')
        expect(DRCI).not_to have_received(:put_away_item?).with('#2222485', any_args)
        expect(world[:hands][:right]).to eq(old)
      end

      # "You get" with no new id in hand: the same-noun piece in the other
      # hand was there before, so it is not the one to bin.
      it 'bins nothing, and says why, when the get shows no new id even with a same-noun piece in the other hand' do
        old = OpenStruct.new(name: 'burlap cloth', noun: 'cloth', id: '999')
        world = stock_world({ 'burlap cloth' => 1 }, hands: { left: old })
        allow(DRC).to receive(:bput) do |command, *|
          world[:sent] << command
          command.start_with?('get ') ? 'You get some burlap cloth from inside your duffel bag.' : ''
        end
        expect(binner.bin_task_stock).to eq(0)
        expect(world[:sent]).to eq(['get my burlap cloth from my duffel bag', 'put my burlap cloth in my duffel bag'])
        expect(world[:sent]).not_to include(a_string_including('bucket'))
        expect(DRC).to have_received(:message).with(a_string_including("can't find it in your hands", 'may still be in your hand'))
      end

      # Hands the stream reports without ids: the get takes the piece out,
      # but no id appears to bin it by.
      def hide_hand_ids(world)
        %i[right left].each do |hand|
          allow(GameObj).to receive(:"#{hand}_hand") do
            obj = world[:hands][hand]
            OpenStruct.new(name: obj&.name || 'Empty', noun: obj&.noun, id: nil)
          end
        end
      end

      # Before, the leather taken out stayed in hand with nothing sent to
      # clear it. "my rat leather" names the stock piece even while the
      # character wears "sinuous leathers", which "my leather" would name.
      it 'puts a piece it took out but cannot find by id back in the bag by its full name, past worn "sinuous leathers"' do
        world = stock_world({ 'rat leather' => 2 }, worn_leathers: true)
        hide_hand_ids(world)
        expect(binner.bin_task_stock).to eq(0)
        expect(world[:sent].last(2)).to eq(['get my rat leather from my duffel bag', 'put my rat leather in my duffel bag'])
        expect(world[:hands].values).to all(be_nil)
        expect(world[:bag]).to eq({ 'rat leather' => 2 })
        expect(DRC).to have_received(:message).with(a_string_including('Took out the rat leather', 'went back in your duffel bag', 'Stopping'))
      end

      it 'says the piece is not in hand, not that it was taken out, when "already holding" shows no such piece' do
        world = stock_world({})
        allow(DRC).to receive(:bput) do |command, *|
          world[:sent] << command
          'You are already holding that.'
        end
        expect(binner.bin_task_stock).to eq(0)
        expect(world[:sent]).to eq(['get my burlap cloth from my duffel bag'])
        expect(DRC).to have_received(:message).with(a_string_including('already hold the burlap cloth', 'not in your hands', 'Stopping'))
        expect(DRC).not_to have_received(:message).with(a_string_including('Took out'))
      end

      # DRCI.put_away_item? (v5.23.0) waits out bput's timeout on a reply it
      # does not list and returns false, though the piece went in the can.
      # Putting it back by id then fails, and binning used to stop with
      # "It may still be in your hand" and leave the piece out of the count.
      it 'counts a piece the worn trash can took with a reply it did not know, and carries on' do
        world = stock_world({ 'burlap cloth' => 2, 'wool yarn' => 1 })
        can = []
        allow(DRCI).to receive(:put_away_item?) do |item, container|
          piece = world[:hands].values.compact.find { |obj| item == "##{obj.id}" }
          DRC.bput("put #{item} in my #{container}", /^You (drop|put)/)
          can << piece.name if piece && container == 'bucket'
          false
        end
        expect(binner.bin_task_stock).to eq(3)
        expect(can).to eq(['burlap cloth', 'burlap cloth', 'wool yarn'])
        expect(world[:sent]).not_to include(a_string_ending_with('in my duffel bag'))
        expect(world[:sent].last(2)).to eq(['tap my bucket', 'tap my bucket'])
        expect(DRC).not_to have_received(:message).with(a_string_including('Stopping'))
      end

      it 'carries on when the put-back went in the bag with a reply it did not know' do
        world = stock_world({ 'burlap cloth' => 3, 'wool yarn' => 1 }, refuse: true)
        allow(DRCI).to receive(:put_away_item?) do |item, container|
          landed = DRC.bput("put #{item} in my #{container}", /^You (drop|put)/).start_with?('You')
          container == 'duffel bag' ? false : landed
        end
        expect(binner.bin_task_stock).to eq(0)
        expect(world[:sent].grep(/\Aget /))
          .to eq(['get my burlap cloth from my duffel bag', 'get my rat leather from my duffel bag', 'get my wool yarn from my duffel bag'])
        expect(world[:hands].values).to all(be_nil)
        expect(world[:bag]).to eq({ 'burlap cloth' => 3, 'wool yarn' => 1 })
        expect(DRC).not_to have_received(:message).with(a_string_including('Stopping'))
      end

      it 'bins the held piece by its id when the game says it is already held' do
        held = OpenStruct.new(name: 'burlap cloth', noun: 'cloth', id: '999')
        world = stock_world({}, hands: { left: held })
        allow(DRC).to receive(:bput) do |command, *|
          world[:sent] << command
          case command
          when 'get my burlap cloth from my duffel bag'
            world[:hands][:left] ? 'You are already holding that.' : 'What were you referring to?'
          when 'put #999 in my bucket'
            world[:hands][:left] = nil
            'You drop some burlap cloth in a bucket.'
          else
            ''
          end
        end
        expect(binner.bin_task_stock).to eq(1)
        expect(world[:sent]).to include('put #999 in my bucket')
        expect(world[:hands][:left]).to be_nil
      end

      # "You are already holding that." adds no id to the hands, so the piece
      # meant is picked from them. Picked by noun alone, the right hand came
      # first and the player's own silk cloth went in the trash can.
      it "bins the held burlap cloth by its id, never the player's silk cloth in the other hand, when the game says it is already held" do
        silk = OpenStruct.new(name: 'silk cloth', noun: 'cloth', id: '111')
        burlap = OpenStruct.new(name: 'burlap cloth', noun: 'cloth', id: '222')
        world = stock_world({}, hands: { right: silk, left: burlap })
        allow(DRC).to receive(:bput) do |command, *|
          world[:sent] << command
          case command
          when 'get my burlap cloth from my duffel bag'
            world[:hands][:left] ? 'You are already holding that.' : 'What were you referring to?'
          when 'put #222 in my bucket'
            world[:hands][:left] = nil
            'You drop some burlap cloth in a bucket.'
          when 'put #111 in my bucket'
            world[:hands][:right] = nil
            'You drop some silk cloth in a bucket.'
          else
            ''
          end
        end
        expect(binner.bin_task_stock).to eq(1)
        expect(world[:sent]).to include('put #222 in my bucket')
        expect(world[:sent]).not_to include('put #111 in my bucket')
        expect(world[:hands]).to eq(right: silk, left: nil)
      end

      it 'stops without binning anything when "already holding" leaves only the player\'s silk cloth in hand' do
        silk = OpenStruct.new(name: 'silk cloth', noun: 'cloth', id: '111')
        world = stock_world({}, hands: { right: silk })
        allow(DRC).to receive(:bput) do |command, *|
          world[:sent] << command
          case command
          when 'get my burlap cloth from my duffel bag'
            'You are already holding that.'
          when 'put #111 in my bucket'
            world[:hands][:right] = nil
            'You drop some silk cloth in a bucket.'
          else
            ''
          end
        end
        expect(binner.bin_task_stock).to eq(0)
        expect(world[:sent]).to eq(['get my burlap cloth from my duffel bag'])
        expect(world[:hands]).to eq(right: silk, left: nil)
        expect(DRC).to have_received(:message).with(a_string_including('already hold the burlap cloth', 'not in your hands', 'Stopping'))
      end

      # The game names a "rat-pelt leather" by "rat leather": the stock word
      # only starts a word of the name. Matching the whole stock name against
      # the end of the item's name would miss every leftover rat-pelt piece.
      it 'bins a held "rat-pelt leather" by its id when the game says the rat leather is already held' do
        pelt = OpenStruct.new(name: 'rat-pelt leather', noun: 'leather', id: '333')
        world = stock_world({}, hands: { left: pelt })
        allow(DRC).to receive(:bput) do |command, *|
          world[:sent] << command
          case command
          when 'get my rat leather from my duffel bag'
            world[:hands][:left] ? 'You are already holding that.' : 'What were you referring to?'
          when 'get my burlap cloth from my duffel bag', 'get my wool yarn from my duffel bag'
            'What were you referring to?'
          when 'put #333 in my bucket'
            world[:hands][:left] = nil
            'You drop some rat-pelt leather in a bucket.'
          else
            ''
          end
        end
        expect(binner.bin_task_stock).to eq(1)
        expect(world[:sent]).to include('put #333 in my bucket')
        expect(world[:hands]).to eq(right: nil, left: nil)
        expect(DRC).not_to have_received(:message).with(a_string_including('Stopping'))
      end
    end

    describe 'binning task stock at the hand-in' do
      before do
        allow(DRCT).to receive(:dispose)
      end

      it 'bins after the instructions are thrown away, once complete_task gets the sack' do
        tm = build(worn_trashcan: 'bucket', worn_trashcan_verb: 'tap')
        allow(tm).to receive(:find_npc)
        allow(tm).to receive(:sort_sack)
        allow(tm).to receive(:fput)
        order = []
        allow(DRCT).to receive(:dispose) { order << :instructions }
        allow(tm).to receive(:bin_task_stock) { order << :stock }
        giving([more_needed(1), sack_handed])
        tm.complete_task('rope', 2)
        expect(order).to eq(%i[instructions stock])
      end

      it 'bins when banked items finish the task' do
        tm = build(worn_trashcan: 'bucket', worn_trashcan_verb: 'tap')
        allow(tm).to receive(:find_npc)
        allow(tm).to receive(:sort_sack)
        allow(tm).to receive(:fput)
        allow(tm).to receive(:bin_task_stock)
        giving([sack_handed], banked: 1)
        expect(tm.turn_in_banked('rope', 1)).to eq(0)
        expect(tm).to have_received(:bin_task_stock).once
      end

      it 'does not bin while items are still owed' do
        tm = build(worn_trashcan: 'bucket', worn_trashcan_verb: 'tap')
        allow(tm).to receive(:find_npc)
        allow(tm).to receive(:bin_task_stock)
        allow(DRCC).to receive(:stow_crafting_item)
        giving([more_needed(2)], banked: 1)
        expect(tm.turn_in_banked('rope', 3)).to eq(2)
        expect(tm).not_to have_received(:bin_task_stock)
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

      describe 'taking the coins' do
        # Replies to GET COIN FROM MY SACK as the game prints them (Hollow Eve
        # 2026 logs): one coin stack per get, then this once none is left.
        let(:no_coin) { 'What were you referring to?' }
        # A four-stack sack, of mixed currencies, from Dorhum.
        let(:four_stacks) { ['You pick up 2 copper Dokoras.', 'You pick up 2 bronze Dokoras.', 'You pick up 2 silver Dokoras.', 'You pick up 1 gold Lirum.'] }

        # Real sacks from Zasele and Dorhum (Hollow Eve 2026 logs) holding one
        # to four coin stacks, the most any sack has held, with what LOOK
        # then showed. The old code asked exactly four times.
        real_sacks = {
          1 => [['You pick up 1 gold Lirum.'], 'a large iron nugget'],
          2 => [['You pick up 2 bronze Lirums.', 'You pick up 8 silver Lirums.'], 'a deer-bone stack'],
          3 => [['You pick up 9 copper Lirums.', 'You pick up 5 bronze Dokoras.', 'You pick up 1 gold Dokora.'], 'a bear-bone stack'],
          4 => [['You pick up 2 copper Dokoras.', 'You pick up 2 bronze Dokoras.', 'You pick up 2 silver Dokoras.', 'You pick up 1 gold Lirum.'], 'a huge muracite fragment']
        }.freeze

        # Plays a sack holding the coin stacks `coins` (pickup lines, in
        # order) through sort_sack. Each get is answered as DRC.bput answers:
        # the text the first of its matchers finds in the next line, or ''
        # (a timeout) when none does; `line` overrides what the game says.
        # Returns every command sent, in order.
        def sort_coins(coins, contents: 'a huge muracite fragment', line: nil)
          commands = []
          coins = coins.dup
          allow(DRC).to receive(:bput) do |command, *matchers|
            commands << command
            reply = if command == 'get coin from my sack'
                      line || coins.shift || no_coin
                    elsif command == 'look in my sack'
                      "In the woven sack you see #{contents}."
                    else
                      ''
                    end
            matchers.map { |m| m.is_a?(Regexp) ? m : /#{m}/i }.filter_map { |m| reply.match(m)&.[](0) }.first || ''
          end
          allow(DRCI).to receive(:put_away_item?)
          allow(DRCI).to receive(:dispose_trash)
          UserVars.taskmaster_sacks = { 'zasele' => [] }
          filtered(task_keep_list: ['shard']).sort_sack('rope')
          expect(coins).to be_empty
          commands
        end

        def gets(commands)
          commands.count('get coin from my sack')
        end

        # Every get comes before the LOOK that decides the sack's fate.
        def looked_after_gets(commands)
          commands.rindex('get coin from my sack') < commands.index('look in my sack')
        end

        real_sacks.each do |stacks, (coins, contents)|
          it "takes every coin of a #{stacks}-stack sack, then sorts the sack as before" do
            commands = sort_coins(coins, contents: contents)
            expect(looked_after_gets(commands)).to be(true)
            expect(commands.uniq).to eq(['get coin from my sack', 'look in my sack'])
            expect(DRC).to have_received(:message).with("Nothing special: In the woven sack you see #{contents}.")
            expect(DRCI).to have_received(:dispose_trash).with('sack', nil, nil)
          end

          it "stops asking for coins at the first empty reply from a #{stacks}-stack sack" do
            expect(gets(sort_coins(coins, contents: contents))).to eq(stacks + 1)
          end
        end

        it 'takes a fifth stack instead of binning the sack with it inside' do
          commands = sort_coins(four_stacks + ['You pick up 7 silver Lirums.'])
          expect(gets(commands)).to eq(6)
          expect(looked_after_gets(commands)).to be(true)
          expect(DRCI).to have_received(:dispose_trash)
        end

        it 'asks once for a sack with no coins' do
          commands = sort_coins([])
          expect(gets(commands)).to eq(1)
          expect(commands).to include('look in my sack')
        end

        it "stops at the cap of gets when the coins never run out, and still sorts the sack" do
          commands = sort_coins([], line: 'You pick up 2 copper Dokoras.')
          expect(gets(commands)).to eq(20)
          expect(described_class::SACK_COIN_GETS_MAX).to eq(20)
          expect(looked_after_gets(commands)).to be(true)
          expect(DRCI).to have_received(:dispose_trash)
        end

        it 'stops asking when a get times out' do
          commands = sort_coins([], line: 'Kythkani drums his fingers on his bucket rhythmically.')
          expect(gets(commands)).to eq(1)
          expect(commands).to include('look in my sack')
        end
      end
    end

    describe '#run version banner' do
      it 'prints the version (bold, via DRC.message) before anything else' do
        tm = build
        order = []
        allow(DRC).to receive(:message) { |text| order << text }
        allow(tm).to receive(:shift_to_task_hometown) { order << :hometown }
        allow(tm).to receive(:find_npc)
        expect { tm.run(OpenStruct.new(npc: 'zasele', find: true)) }.to raise_error(SystemExit)
        expect(order.first).to eq("taskmaster version #{described_class::VERSION}")
        expect(described_class::VERSION).to match(/\A\d{4}\.\d{2}\.\d{2}(\.\d+)?\z/)
      end
    end

    describe '#sort_sack with task_unpack_keepers' do
      let(:sack) { OpenStruct.new(noun: 'sack', id: '63768227') }
      let(:bar) { OpenStruct.new(noun: 'bar', id: '63768234') }
      let(:empty_hand) { OpenStruct.new(noun: nil, id: nil) }
      # Replies from a live run (Hollow Eve 2026, a woven sack holding a large tyrium bar).
      let(:got_bar) { 'You get a large tyrium bar from inside your woven sack.' }
      let(:sack_empty) { "There's nothing inside a woven sack!" }

      def unpacker(**settings)
        build(settings: { task_junk_list: ['dye'], task_unpack_keepers: true }.merge(settings),
              lootbag: "traveler's.pack", worn_trashcan: 'bucket', worn_trashcan_verb: 'tap')
          .tap { |tm| tm.send(:configure_loot_filter) }
      end

      # Plays a sack holding `contents` through sort_sack. get_replies are the
      # replies to successive `get <noun> from #<sack>`; a get answered with
      # got_bar puts the bar in the left hand. disposed is what dispose_trash
      # returns.
      def unpack(tm, contents: 'a large tyrium bar', get_replies: [got_bar], inventory: sack_empty, put_ok: true, disposed: true)
        hands = { right: sack, left: empty_hand }
        allow(GameObj).to receive(:right_hand) { hands[:right] }
        allow(GameObj).to receive(:left_hand) { hands[:left] }
        allow(DRC).to receive(:left_hand) { hands[:left]&.noun }
        allow(DRC).to receive(:right_hand) { hands[:right]&.noun }
        allow(tm).to receive(:pause)
        game('look in my sack'            => "In the woven sack you see #{contents}.",
             'get coin from my sack'      => 'What were you referring to?',
             'get '                       => lambda do |*|
               reply = get_replies.shift
               hands[:left] = bar if reply == got_bar
               reply
             end,
             'inventory #63768227'        => inventory,
             'put #63768234 in #63768227' => 'You put your bar in your woven sack.')
        allow(DRCI).to receive(:put_away_item?) { |item, _bag| item == '#63768234' ? put_ok : true }
        allow(DRCI).to receive(:dispose_trash).and_return(disposed)
        UserVars.taskmaster_sacks = { 'zasele' => [] }
        tm.sort_sack('netting')
      end

      it 'takes the item out by noun from the sack id, puts it away by its own id, and bins the empty sack by its id' do
        tm = unpacker
        unpack(tm)
        expect(DRC).to have_received(:bput).with('get bar from #63768227', any_args)
        expect(DRC).to have_received(:bput).with('inventory #63768227', any_args)
        expect(DRCI).to have_received(:put_away_item?).with('#63768234', "traveler's.pack")
        expect(DRCI).to have_received(:dispose_trash).with('#63768227', 'bucket', 'tap')
        expect(DRCI).not_to have_received(:put_away_item?).with('sack', anything)
      end

      it 'puts the empty sack in the loot bag when it cannot be binned' do
        tm = unpacker
        unpack(tm, disposed: false)
        expect(DRCI).to have_received(:put_away_item?).with('#63768234', "traveler's.pack")
        expect(DRCI).to have_received(:dispose_trash).with('#63768227', 'bucket', 'tap')
        expect(DRCI).to have_received(:put_away_item?).with('sack', "traveler's.pack")
      end

      it 'puts the sack in the loot bag when dispose_trash finds it no longer in hand' do
        tm = unpacker
        unpack(tm, disposed: nil)
        expect(DRCI).to have_received(:put_away_item?).with('sack', "traveler's.pack")
      end

      it 'waits for a free hand and retries once when another script holds it' do
        tm = unpacker
        unpack(tm, get_replies: ['You need a free hand to pick that up.', got_bar])
        expect(DRC).to have_received(:bput).with('get bar from #63768227', any_args).twice
        expect(DRCI).to have_received(:dispose_trash)
      end

      it 'keeps the whole sack when the get fails twice for want of a hand' do
        tm = unpacker
        unpack(tm, get_replies: ['You need a free hand to pick that up.'] * 2)
        expect(DRCI).to have_received(:put_away_item?).with('sack', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'keeps the whole sack when the noun does not match the item' do
        tm = unpacker
        unpack(tm, contents: '3 haledroth shards', get_replies: ['What were you referring to?'])
        expect(DRC).to have_received(:bput).with('get shards from #63768227', any_args)
        expect(DRCI).to have_received(:put_away_item?).with('sack', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'puts the item back in the sack and keeps the sack when the loot bag will not take the item' do
        tm = unpacker
        unpack(tm, put_ok: false)
        expect(DRC).to have_received(:bput).with('put #63768234 in #63768227', any_args)
        expect(DRCI).to have_received(:put_away_item?).with('sack', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'keeps a sack that is not empty after the item is out, with whatever is left in it' do
        tm = unpacker
        unpack(tm, inventory: 'Inside a woven sack, you see:')
        expect(DRCI).to have_received(:put_away_item?).with('#63768234', "traveler's.pack")
        expect(DRCI).to have_received(:put_away_item?).with('sack', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'keeps the sack when INVENTORY gives no recognised reply' do
        tm = unpacker
        unpack(tm, inventory: '')
        expect(DRCI).to have_received(:put_away_item?).with('sack', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'keeps the sack when the sack in hand has no id' do
        tm = unpacker
        allow(tm).to receive(:held_id).and_call_original
        allow(tm).to receive(:held_id).with('sack').and_return(nil)
        unpack(tm)
        expect(DRC).not_to have_received(:bput).with(/\Aget bar/, any_args)
        expect(DRCI).to have_received(:put_away_item?).with('sack', "traveler's.pack")
      end

      it 'never unpacks junk, which is binned with its sack as before' do
        tm = unpacker
        unpack(tm, contents: 'some coral dye')
        expect(DRC).not_to have_received(:bput).with(/\Aget dye/, any_args)
        expect(DRCI).to have_received(:dispose_trash).with('sack', 'bucket', 'tap')
      end

      it 'keeps the whole sack, as before, when task_unpack_keepers is off' do
        tm = unpacker(task_unpack_keepers: false)
        unpack(tm)
        expect(DRC).not_to have_received(:bput).with(/\Aget bar/, any_args)
        expect(DRCI).to have_received(:put_away_item?).with('sack', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'gets task_unpack_keepers as false from base.yaml' do
        expect(base_yaml).to include('task_unpack_keepers' => false)
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

  # Dorhum, the enchanting taskmaster (Hollow Eve 2026). Lines come from two
  # task runs: eight spongestones (log 1) and six virga wands (log 2).
  describe "Dorhum's enchanting tasks" do
    let(:sigil_stock) do
      { 'congruence sigil-scroll' => { 'stock-number' => 3, 'stock-value' => 312 },
        'decay sigil-scroll'      => { 'stock-number' => 10, 'stock-value' => 1575 },
        'induction sigil-scroll'  => { 'stock-number' => 1, 'stock-value' => 625 } }
    end

    def dorhum(settings: {}, **ivars)
      build(settings: settings, npc: 'dorhum', lootbag: 'backpack', stockdata: sigil_stock, rock_room: 793, **ivars)
    end

    before(:each) do
      $test_data.crafting = { 'artificing' => { 'Crossing' => { 'stock-room' => 14_753, 'tool-room' => 14_754, 'fount' => 3,
                                                                'brazier-rooms' => [14_757, 14_758, 14_759, 14_760] } } }
    end

    # READ of the instructions as Lich::Util.issue_command returns it: raw
    # lines from the title to the prompt.
    def instructions_read(*ingredients)
      ['<output class="mono"/>', '        -=   Instructions for crafting a spongestone    =-', '', ' A list of ingredients is provided:', '',
       *ingredients.map { |line| "   #{line}" }, '<output class=""/>', '<prompt time="1">&gt;</prompt>']
    end

    describe '#read_instructions' do
      before(:each) { allow(DRCI).to receive(:stow_hands) }

      it 'reads congruence and decay off the spongestone instructions (log 1) and stows them' do
        tm = dorhum
        allow(Lich::Util).to receive(:issue_command)
          .with('read my spongestone instructions', /Instructions for crafting/)
          .and_return(instructions_read('(1) a foraged rock', '(1) mana fount', '(1) primary sigil (congruence)', '(1) secondary sigil (decay)'))
        expect(DRCC).to receive(:stow_crafting_item).with('spongestone instructions', 'duffel bag', nil)

        expect(tm.read_instructions('spongestone', 8)).to eq(['spongestone', 8, %w[congruence decay]])
      end

      it 'reads induction off the virga wand instructions (log 2)' do
        tm = dorhum
        allow(Lich::Util).to receive(:issue_command)
          .and_return(instructions_read('(1) A finished stone, bone or wood wand or rod', '(1) mana fount', '(1) primary sigil (induction)'))
        allow(DRCC).to receive(:stow_crafting_item)

        expect(tm.read_instructions('wand', 6)).to eq(['wand', 6, %w[induction]])
      end

      it 'reads a sigil the game wrapped in tags' do
        tm = dorhum
        allow(Lich::Util).to receive(:issue_command).and_return(instructions_read('(1) primary sigil (<pushBold/>induction<popBold/>)'))
        allow(DRCC).to receive(:stow_crafting_item)

        expect(tm.read_instructions('wand', 6).last).to eq(%w[induction])
      end

      it 'repeats a sigil as many times as the instructions count it' do
        tm = dorhum
        allow(Lich::Util).to receive(:issue_command).and_return(instructions_read('(2) primary sigils (induction)', '(1) secondary sigil (decay)'))
        allow(DRCC).to receive(:stow_crafting_item)

        expect(tm.read_instructions('wand', 6).last).to eq(%w[induction induction decay])
      end

      it 'pauses, then stops, when no sigil can be read off them' do
        tm = dorhum
        allow(Lich::Util).to receive(:issue_command).and_return([])
        allow(DRCC).to receive(:stow_crafting_item)
        expect(tm).to receive(:pause_script)

        expect { tm.read_instructions('spongestone', 8) }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/No sigils could be read off the spongestone instructions/)
      end

      it "leaves the other taskmasters' instructions to the materials line" do
        tm = build(stockdata: {})
        expect(Lich::Util).not_to receive(:issue_command)
        game('read my rope instructions' => 'cloth (8 yards)')
        allow(DRCC).to receive(:stow_crafting_item)

        expect(tm.read_instructions('rope', 3).values_at(2, 3)).to eq([8, 'cloth'])
      end
    end

    describe "Dorhum's task journal" do
      it 'reads the item and how many are owed (log 3)' do
        tm = dorhum
        game('task' => 'While visiting Andreshlew for the Hollow Eve festivities, Dorhum has asked you to craft some items to assist his ongoing efforts with the Merelew and others.  ' \
                       'In particular, he wanted you to craft a spongestone and indicated that 6 would suffice.  So far, you have returned 0 to him.  ' \
                       'Crafting instructions were provided for this item.  If you lost or misplaced them, you can ASK Dorhum for another copy.')

        expect(tm.read_task).to eq(['spongestone', 6])
      end
    end

    describe '#set_aside_held_base' do
      it "puts a rock held at a Dorhum resume back with the unworked ones, since nothing says it was finished" do
        tm = dorhum
        allow(DRCI).to receive(:in_hands?).with('rock').and_return(true)
        expect(DRCC).to receive(:stow_crafting_item).with('rock', 'duffel bag', nil)

        tm.set_aside_held_base('spongestone')
      end

      it 'leaves the hands alone when nothing of the kind is held' do
        allow(DRCI).to receive(:in_hands?).and_return(false)
        expect(DRCC).not_to receive(:stow_crafting_item)

        dorhum.set_aside_held_base('spongestone')
      end

      it "leaves other taskmasters' resumes alone" do
        allow(DRCI).to receive(:in_hands?).and_return(true)
        expect(DRCC).not_to receive(:stow_crafting_item)

        build.set_aside_held_base('rope')
      end
    end

    describe "cancelling another taskmaster's task" do
      # Dorhum's replies, Mahtra 2026-11-03 18:45.
      let(:confirm) { 'Researcher Dorhum looks at you and says, "You wish to end your current task?  If so, ask me again within fifteen seconds."' }
      let(:cancelled) { 'Researcher Dorhum says, "Very well, I see that you no longer wish to assist me."' }
      let(:no_task) { 'Researcher Dorhum looks at you and says, "You do not currently have a task."' }

      def zasele_run
        tm = build(npc: 'zasele', worn_trashcan: 'bucket', worn_trashcan_verb: 'tap', cancel_foreign_tasks: true)
        allow(tm).to receive(:find_npc)
        allow(tm).to receive(:pause)
        allow(DRCI).to receive(:stow_hands)
        allow(DRCT).to receive(:dispose)
        tm
      end

      it "asks twice, as the game wants, then throws the instructions away and clears that taskmaster's replacement record" do
        tm = zasele_run
        UserVars.taskmaster_replacements = { 'dorhum' => 'shell', 'zasele' => 'rope' }
        replies = [confirm, cancelled]
        game('ask dorhum for task cancel' => ->(*) { replies.shift })

        expect { tm.cancel_task('dorhum', 'shell') }.not_to raise_error

        expect(DRC).to have_received(:bput).with('ask dorhum for task cancel', any_args).twice
        expect(DRCT).to have_received(:dispose).with('shell instructions', nil, 'bucket', 'tap')
        expect(UserVars.taskmaster_replacements).to eq('zasele' => 'rope')
        expect(DRC).to have_received(:message).with('You are on a task for Dorhum, not Zasele: cancelling it (task_cancel_foreign_tasks).')
      end

      it "takes the cancel replies only from the taskmaster, not from a player saying them" do
        tm = zasele_run
        player = 'Mallory says, "Very well, I see that you no longer wish to assist me."'
        heard = [[player, confirm], [cancelled]]
        # Like DRC.bput: the first line that one of the matchers takes.
        game('ask dorhum for task cancel' => ->(_cmd, *matchers) { heard.shift.find { |line| matchers.any? { |m| line.match?(m) } }.to_s })

        expect { tm.cancel_task('dorhum', 'shell') }.not_to raise_error

        expect(DRC).to have_received(:bput).with('ask dorhum for task cancel', any_args).twice
      end

      it 'does not take a player looking at the taskmaster and saying the words' do
        heard = 'Mallory looks at Researcher Dorhum and says, "Very well, I see that you no longer wish to assist me."'
        expect(heard).not_to match(build.cancel_reply('dorhum', TaskMaster::TASK_CANCELLED))
        expect(cancelled).to match(build.cancel_reply('dorhum', TaskMaster::TASK_CANCELLED))
        expect(confirm).to match(build.cancel_reply('dorhum', TaskMaster::TASK_CANCEL_CONFIRM))
        expect(no_task).to match(build.cancel_reply('dorhum', TaskMaster::TASK_CANCEL_NONE))
      end

      it 'takes "You do not currently have a task" as done' do
        tm = zasele_run
        game('ask dorhum for task cancel' => no_task)

        expect { tm.cancel_task('dorhum', 'shell') }.not_to raise_error

        expect(DRC).to have_received(:bput).with('ask dorhum for task cancel', any_args).once
      end

      it 'stops when the cancel does not go through, keeping the instructions' do
        tm = zasele_run
        game('ask dorhum for task cancel' => '')

        expect { tm.cancel_task('dorhum', 'shell') }.to raise_error(SystemExit)

        expect(DRCT).not_to have_received(:dispose)
        expect(DRC).to have_received(:message).with("Could not cancel Dorhum's task. Stopping.")
      end

      it 'waits out the ten-minute cooldown a cancel brings before going back to its own taskmaster' do
        tm = zasele_run
        allow(tm).to receive(:cancel_task)

        expect { tm.cancel_foreign_task('dorhum') }.to throw_symbol(TaskMaster::FOREIGN_TASK_CANCELLED)

        expect(tm).to have_received(:pause).with(600)
        expect(DRC).to have_received(:message).with('Waiting 10 minutes: after a cancel, taskmasters call you unreliable for about that long.')
      end

      it "still pauses on an item it cannot make for its own taskmaster's task" do
        tm = dorhum(cancel_foreign_tasks: true)
        expect(tm).not_to receive(:cancel_task)
        expect(tm).to receive(:pause_script)

        expect { tm.hand_in_noun('bauble') }.to raise_error(SystemExit)
      end

      it 'returns from finish mode after a cancel, so the run carries on asking its own taskmaster' do
        tm = build
        allow(tm).to receive(:reconcile_hands)
        allow(tm).to receive(:resume_task) { throw TaskMaster::FOREIGN_TASK_CANCELLED }

        expect { tm.finish_task_in_progress }.not_to raise_error
      end
    end

    describe '#check_loot_bag' do
      it 'stops a Dorhum task whose loot bag is the crafting bag, before buying anything' do
        tm = dorhum(lootbag: 'duffel bag')
        expect(tm).not_to receive(:buy_sigils)

        expect { tm.dorhum('spongestone', 6, %w[congruence decay]) }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/need task_loot_bag \(duffel bag\) to be a container other than your crafting bag \(duffel bag\)/)
      end

      it 'stops a hand-in from the crafting bag too, as after a resume' do
        expect { dorhum(lootbag: 'Duffel Bag ').hand_in_bag }.to raise_error(SystemExit)
      end

      it 'stops when the two bags differ only by adjective, as PUT would find either' do
        expect { dorhum(bag: 'sturdy backpack', lootbag: 'backpack').hand_in_bag }.to raise_error(SystemExit)
      end

      {
        ['sturdy backpack', 'backpack']         => true,
        ['pack', 'travel.pack']                 => true,
        ['duffel bag', 'Duffel Bag']            => true,
        ['travel.pack', "traveler's.pack"]      => false,
        ['duffel bag', "traveler's.pack"]       => false,
        ['leather backpack', 'canvas backpack'] => false
      }.each do |(crafting, loot), same|
        it "takes #{crafting.inspect} and #{loot.inspect} for #{same ? 'the same bag' : 'two bags'}" do
          expect(dorhum.same_container?(crafting, loot)).to be(same)
        end
      end

      it 'lets a loot bag of its own through' do
        expect(dorhum.hand_in_bag).to eq('backpack')
      end
    end

    describe 'the hand-in' do
      it 'hands in a spongestone as the rock it still is, out of the loot bag' do
        tm = dorhum
        allow(tm).to receive(:find_npc)
        allow(DRCI).to receive(:in_hands?).and_return(false)
        expect(DRCI).to receive(:get_item?).with('rock', 'backpack').and_return(true)
        game('give my rock to dorhum' => 'Dorhum holds up his fingers indicating 7 more are needed.')

        expect(tm.give_item('spongestone')).to match(TaskMaster::TURN_IN_MORE_NEEDED)
        expect(DRC).to have_received(:bput).with('give my rock to dorhum', any_args)
      end

      def refusal
        'Researcher Dorhum examines the rock and shakes his head.  "I don\'t sense any hint of enchantment on this.  What are you trying to pull, Pezamus?"'
      end

      # The loot bag holds `rocks`; Dorhum turns down the ones whose index is
      # in `bad` and takes the rest.
      def handing_in(rocks, bad:)
        state = { held: nil, gets: 0, gives: 0, accepted: 0 }
        allow(DRCI).to receive(:in_hands?) { state[:held] }
        allow(DRCI).to receive(:get_item?) do
          next false if state[:gets] >= rocks

          state[:gets] += 1
          state[:held] = state[:gets]
        end
        allow(DRCI).to receive(:dispose_trash) { state[:held] = nil; true }
        game('give my rock to dorhum' => lambda do |*|
          state[:gives] += 1
          next refusal if bad.include?(state[:held])

          state[:accepted] += 1
          state[:held] = nil
          left = rocks - bad.size - state[:accepted]
          left.positive? ? more_needed(left) : sack_handed
        end)
        state
      end

      it 'trashes a rock Dorhum sees no enchantment on, without giving it again, and hands in the rest' do
        tm = dorhum(worn_trashcan: 'bucket', worn_trashcan_verb: 'tap')
        allow(tm).to receive(:find_npc)
        allow(tm).to receive(:sort_sack)
        allow(tm).to receive(:fput)
        allow(tm).to receive(:task_handed_in)
        state = handing_in(3, bad: [2])

        expect { tm.complete_task('spongestone', 2) }.not_to raise_error

        expect(state[:gives]).to eq(3)
        expect(DRCI).to have_received(:dispose_trash).with('rock', 'bucket', 'tap').once
        expect(DRC).to have_received(:message).with('Dorhum saw no enchantment on a rock, so it went in the trash.')
        expect(tm).to have_received(:sort_sack)
      end

      it 'does the same at a resume, then hands in the rest' do
        tm = dorhum(worn_trashcan: 'bucket', worn_trashcan_verb: 'tap')
        allow(tm).to receive(:find_npc)
        allow(DRCC).to receive(:stow_crafting_item)
        state = handing_in(2, bad: [1])
        allow(tm).to receive(:sort_sack)
        allow(tm).to receive(:fput)
        allow(tm).to receive(:task_handed_in)

        expect(tm.turn_in_banked('spongestone', 2)).to eq(0)

        expect(DRCI).to have_received(:dispose_trash).once
        expect(DRCC).not_to have_received(:stow_crafting_item)
        expect(state[:gives]).to eq(2)
      end

      it 'puts the rock back and stops when the trash will not take it' do
        tm = dorhum
        allow(tm).to receive(:find_npc)
        allow(tm).to receive(:sort_sack)
        handing_in(1, bad: [1])
        allow(DRCI).to receive(:dispose_trash).and_return(false)
        allow(DRCC).to receive(:stow_crafting_item)

        expect { tm.complete_task('spongestone', 1) }.to raise_error(SystemExit)

        expect(DRCC).to have_received(:stow_crafting_item).with('rock', 'backpack', nil)
        expect(tm).not_to have_received(:sort_sack)
      end

      it "takes Dorhum's refusal only from Dorhum, not from a player repeating it" do
        text = %(I don't sense any hint of enchantment on this.  What are you trying to pull, Pezamus?)
        expect(%(Researcher Dorhum examines the small brazier and shakes his head.  "#{text}")).to match(TaskMaster::GIVE_NOT_ENCHANTED)
        expect(%(Mallory says, "#{text}")).not_to match(TaskMaster::GIVE_NOT_ENCHANTED)
        expect(%(Mallory says, "Researcher Dorhum examines the rock and shakes his head.  "#{text}")).not_to match(TaskMaster::GIVE_NOT_ENCHANTED)
      end

      it 'hands in a virga wand as a wand' do
        expect(dorhum.hand_in_noun('wand')).to eq('wand')
      end

      it 'keeps Zasele\'s items in the crafting bag' do
        tm = build
        expect([tm.hand_in_noun('rope'), tm.hand_in_bag]).to eq(['rope', 'duffel bag'])
      end

      it 'puts a refused rock back in the loot bag, not among the unworked rocks' do
        tm = dorhum
        expect(DRCC).to receive(:stow_crafting_item).with('rock', 'backpack', nil)

        expect { tm.refused_hand_in('spongestone', '') }.to raise_error(SystemExit)
      end

      it 'pauses, then stops, on an item taskmaster does not know' do
        tm = dorhum
        expect(tm).to receive(:pause_script)

        expect { tm.hand_in_noun('bauble') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/does not know how to make Dorhum's baubles/)
      end
    end

    describe '#buy_sigils' do
      let(:orders) { [] }

      before(:each) do
        allow(DRCT).to receive(:order_item) { |room, number| orders << [room, number] }
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCM).to receive(:ensure_copper_on_hand).and_return(true)
      end

      it 'orders one of each sigil per item from the enchanting supplies, by stock number' do
        allow(DRCI).to receive(:count_items_in_container).and_return(0)

        dorhum.buy_sigils(%w[congruence decay], 8)

        expect(orders.tally).to eq({ [14_753, 3] => 8, [14_753, 10] => 8 })
        expect(DRCC).to have_received(:stow_crafting_item).with('sigil-scroll', 'duffel bag', nil).exactly(16).times
      end

      # RUMMAGE's list, as the game words it ("... and see some sepia pins,
      # some sepia pins and some sepia pins.").
      def rummaged(*names)
        return 'You rummage through a heavy silk duffel bag looking for something similar to "sigil-scroll" but there is nothing in there like that.' if names.empty?

        listed = names.map { |name| "an intricate #{name}" }
        "You rummage through a heavy silk duffel bag looking for something similar to \"sigil-scroll\" and see #{listed[0..-2].join(', ')}#{listed.size > 1 ? ' and ' : ''}#{listed.last}."
      end

      it 'counts the scrolls already in the crafting bag, with one RUMMAGE for every sigil' do
        game('rummage /C sigil-scroll in my duffel bag' => rummaged(*Array.new(3, 'congruence sigil-scroll'), *Array.new(11, 'decay sigil-scroll')))

        dorhum.buy_sigils(%w[congruence decay], 8)

        expect(orders.tally).to eq({ [14_753, 3] => 5 })
        expect(DRC).to have_received(:bput).with('rummage /C sigil-scroll in my duffel bag', any_args).once
      end

      it 'counts one scroll, the last in the list, and none when the bag has none' do
        game('rummage /C sigil-scroll in my duffel bag' => rummaged('decay sigil-scroll'))
        dorhum.buy_sigils(%w[decay], 2)
        expect(orders.tally).to eq({ [14_753, 10] => 1 })

        orders.clear
        game('rummage /C sigil-scroll in my duffel bag' => rummaged)
        dorhum.buy_sigils(%w[decay], 2)
        expect(orders.tally).to eq({ [14_753, 10] => 2 })
      end

      it 'carries enough copper for the scrolls, a new fount, the next fee and repairs' do
        dorhum.buy_sigils(%w[induction], 6)

        expect(DRCM).to have_received(:ensure_copper_on_hand).with(6 * 625 + 312 + 7500, anything, 'Crossing')
      end

      it 'buys two per item of a sigil the instructions list twice' do
        allow(DRCI).to receive(:count_items_in_container).and_return(0)

        dorhum.buy_sigils(%w[induction induction], 6)

        expect(orders.tally).to eq({ [14_753, 1] => 12 })
      end

      it 'pauses, then stops, on a sigil not in the crafting data' do
        tm = dorhum
        expect(tm).to receive(:pause_script)

        expect { tm.buy_sigils(%w[mystery], 2) }.to raise_error(SystemExit)
        expect(orders).to eq([])
      end
    end

    describe '#buy_wands' do
      before(:each) do
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCM).to receive(:ensure_copper_on_hand).and_return(true)
      end

      it 'buys a wand from the steel crate for each virga wand not covered by the wands carried' do
        allow(DRCI).to receive(:count_items_in_container).with('wand', 'duffel bag').and_return(2)
        allow(DRCI).to receive(:in_hands?).with('wand').and_return(true)
        expect(DRCT).to receive(:buy_item).with(14_753, 'wand').exactly(4).times

        dorhum.buy_wands(6)

        expect(DRCC).to have_received(:stow_crafting_item).with('wand', 'duffel bag', nil).exactly(4).times
      end

      it 'buys nothing when enough are carried' do
        allow(DRCI).to receive(:count_items_in_container).and_return(6)
        expect(DRCT).not_to receive(:buy_item)

        dorhum.buy_wands(6)
      end
    end

    describe '#forage_rocks' do
      before(:each) do
        allow(DRCI).to receive(:count_items_in_container).and_return(0)
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCT).to receive(:walk_to)
      end

      it 'forages a rock per item at the rock room and bags each one (log 3)' do
        allow(DRC).to receive(:forage?).with('rock').and_return(true)

        dorhum.forage_rocks(6)

        expect(DRCT).to have_received(:walk_to).with(793)
        expect(DRC).to have_received(:forage?).exactly(6).times
        expect(DRCC).to have_received(:stow_crafting_item).with('rock', 'duffel bag', nil).exactly(6).times
      end

      it 'forages at task_rock_room when set' do
        allow(DRC).to receive(:forage?).and_return(true)

        dorhum(rock_room: 14_137).forage_rocks(1)

        expect(DRCT).to have_received(:walk_to).with(14_137)
      end

      it 'forages only the rocks the crafting bag does not already hold' do
        allow(DRCI).to receive(:count_items_in_container).with('rock', 'duffel bag').and_return(4)
        allow(DRC).to receive(:forage?).and_return(true)

        dorhum.forage_rocks(6)

        expect(DRC).to have_received(:forage?).twice
      end

      it 'goes nowhere when the crafting bag already holds the rocks' do
        allow(DRCI).to receive(:count_items_in_container).with('rock', 'duffel bag').and_return(6)
        expect(DRC).not_to receive(:forage?)

        dorhum.forage_rocks(6)

        expect(DRCT).not_to have_received(:walk_to)
      end

      it 'stops when a forage finds nothing, without bagging a rock it does not have' do
        allow(DRC).to receive(:forage?).and_return(true, false)

        expect { dorhum.forage_rocks(3) }.to raise_error(SystemExit)

        expect(DRCC).to have_received(:stow_crafting_item).once
        expect(DRC).to have_received(:message).with('Could not forage a rock at room 793, stopping. Set task_rock_room to a room where rocks can be found.')
      end
    end

    describe 'glow shells' do
      before(:each) do
        allow(DRCI).to receive(:count_items_in_container).and_return(0)
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCT).to receive(:walk_to)
      end

      it 'hands in a glow shell as a shell, out of the loot bag' do
        expect([dorhum.hand_in_noun('shell'), dorhum.hand_in_bag]).to eq(%w[shell backpack])
      end

      it 'forages a shell per item at room 793 by default and bags each one' do
        allow(DRC).to receive(:forage?).with('shell').and_return(true)

        build(npc: 'dorhum', lootbag: 'backpack', shell_room: TaskMaster::DEFAULT_SHELL_ROOM).forage_shells(5)

        expect(DRCT).to have_received(:walk_to).with(793)
        expect(DRCC).to have_received(:stow_crafting_item).with('shell', 'duffel bag', nil).exactly(5).times
      end

      it 'forages at task_shell_room when set' do
        allow(DRC).to receive(:forage?).and_return(true)

        build(npc: 'dorhum', lootbag: 'backpack', shell_room: 712).forage_shells(1)

        expect(DRCT).to have_received(:walk_to).with(712)
      end

      it 'stops, naming the setting, when no shell can be foraged there' do
        allow(DRC).to receive(:forage?).and_return(false)

        expect { build(npc: 'dorhum', lootbag: 'backpack', shell_room: 793).forage_shells(3) }.to raise_error(SystemExit)

        expect(DRC).to have_received(:message).with('Could not forage a shell at room 793, stopping. Set task_shell_room to a room where shells can be found.')
      end

      it 'reads permutation and paradox off the glow shell instructions (Mahtra, 2026-11-03)' do
        tm = dorhum
        allow(DRCI).to receive(:stow_hands)
        allow(Lich::Util).to receive(:issue_command)
          .and_return(instructions_read('(1) a foraged shell', '(1) mana fount', '(1) primary sigil (permutation)', '(1) secondary sigil (paradox)'))

        expect(tm.read_instructions('shell', 5)).to eq(['shell', 5, %w[permutation paradox]])
      end

      # Mahtra, 2026-11-03: t2task's `taskmaster zasele` met this open Dorhum
      # task ("You are already on a task"), worked it as Zasele's and crashed
      # in buy_stackables on every relaunch.
      it "stops on an open glow shell task when started for Zasele, working it neither as hers nor as Dorhum's" do
        tm = build(npc: 'zasele', lootbag: 'backpack', stockdata: sigil_stock)
        allow(tm).to receive(:find_npc)
        game('task' => 'While visiting Andreshlew for the Hollow Eve festivities, Dorhum has asked you to craft some items to assist his ongoing efforts with the Merelew and others.  ' \
                       'In particular, he wanted you to craft a glow shell and indicated that 6 would suffice.  So far, you have returned 0 to him.  ' \
                       'Crafting instructions were provided for this item.  If you lost or misplaced them, you can ASK Dorhum for another copy.')
        expect(tm).not_to receive(:turn_in_banked)
        expect(tm).not_to receive(:zasele)
        expect(tm).not_to receive(:dorhum)

        expect { tm.resume_task }.to raise_error(SystemExit)

        expect(DRC).to have_received(:message)
          .with('You are on a task for Dorhum, not Zasele. Finish it with ;taskmaster dorhum, or cancel it with ASK DORHUM FOR TASK CANCEL (taskmasters then refuse you for about ten minutes). Or set task_cancel_foreign_tasks to have taskmaster cancel such tasks itself.')
      end

      it 'forages shells for a glow shell task' do
        tm = dorhum
        %i[ensure_tools buy_sigils go_to_enchanting_room enchant_items repair].each { |step| allow(tm).to receive(step) }
        allow(DRCC).to receive(:fount)
        expect(tm).to receive(:forage_shells).with(5)

        tm.dorhum('shell', 5, %w[permutation paradox])
      end
    end

    # A manual run, 2026-11-04 (Pezamus): the journal, the instructions and
    # the hand-in of a splashstone task.
    describe 'splashstones' do
      it 'reads a splashstone task off the journal' do
        tm = dorhum
        game('task' => 'While visiting Andreshlew for the Hollow Eve festivities, Dorhum has asked you to craft some items to assist his ongoing efforts with the Merelew and others.  ' \
                       'In particular, he wanted you to craft a splashstone and indicated that 8 would suffice.  So far, you have returned 0 to him.  ' \
                       'Crafting instructions were provided for this item.  If you lost or misplaced them, you can ASK Dorhum for another copy.')

        expect(tm.read_task).to eq(['splashstone', 8])
      end

      it 'reads rarefaction and integration off the splashstone instructions' do
        tm = dorhum
        allow(DRCI).to receive(:stow_hands)
        allow(DRCC).to receive(:stow_crafting_item)
        allow(Lich::Util).to receive(:issue_command)
          .with('read my splashstone instructions', /Instructions for crafting/)
          .and_return(instructions_read('(1) a foraged rock', '(1) mana fount', '(1) primary sigil (rarefaction)', '(1) secondary sigil (integration)'))

        expect(tm.read_instructions('splashstone', 8)).to eq(['splashstone', 8, %w[rarefaction integration]])
      end

      it 'hands in a splashstone as the rock it still is, out of the loot bag' do
        expect([dorhum.hand_in_noun('splashstone'), dorhum.hand_in_bag]).to eq(%w[rock backpack])
      end

      it 'forages rocks for a splashstone task, then enchants them as rocks' do
        tm = dorhum
        %i[ensure_tools buy_sigils go_to_enchanting_room repair].each { |step| allow(tm).to receive(step) }
        allow(DRCC).to receive(:fount)
        expect(tm).to receive(:forage_rocks).with(8)
        expect(tm).to receive(:enchant_items).with('splashstone', 'rock', 8)

        tm.dorhum('splashstone', 8, %w[rarefaction integration])
      end
    end

    describe '#go_to_enchanting_room' do
      before(:each) do
        allow(DRCT).to receive(:walk_to)
        allow(DRCC).to receive(:find_enchanting_room)
      end

      it 'goes to task_crafting_room first, the room every task crafts in' do
        dorhum(crafting_room: 1111, settings: { enchanting_room: 2222 }).go_to_enchanting_room

        expect(DRCT).to have_received(:walk_to).with(1111)
      end

      it 'goes to enchanting_room when task_crafting_room is unset' do
        dorhum(crafting_room: nil, settings: { enchanting_room: 2222 }).go_to_enchanting_room

        expect(DRCT).to have_received(:walk_to).with(2222)
      end

      it 'stays put with a brazier of its own' do
        allow(DRCI).to receive(:exists?).with('small brazier').and_return(true)

        dorhum(crafting_room: nil, settings: { enchanting_tools: ['small brazier', 'burin'] }).go_to_enchanting_room

        expect(DRCT).not_to have_received(:walk_to)
        expect(DRCC).not_to have_received(:find_enchanting_room)
      end

      it 'finds a brazier room in Crossing without one' do
        allow(DRCI).to receive(:exists?).and_return(false)

        dorhum(crafting_room: nil).go_to_enchanting_room

        expect(DRCC).to have_received(:find_enchanting_room).with('Crossing')
      end
    end

    describe '#enchant_items' do
      let(:enchanted) { "The spell's energies settle upon the rock and seal off the pattern.  With the enchanting process completed, you believe it is safe to collect your things once more." }

      def enchant_runs(*finishes)
        allow(DRC).to receive(:wait_for_script_to_complete) do
          Flags[TaskMaster::ENCHANTED_FLAG] = finishes.shift ? true : false
        end
      end

      it 'enchants each item from the instructions and puts it in the loot bag' do
        tm = dorhum
        enchant_runs(true, true)
        allow(DRCI).to receive(:in_hands?).with('rock').and_return(true)
        expect(DRCI).to receive(:put_away_item?).with('rock', 'backpack').twice.and_return(true)

        tm.enchant_items('spongestone', 'rock', 2)

        expect(DRC).to have_received(:wait_for_script_to_complete).with('enchant', %w[instructions spongestone rock]).twice
      end

      it 'stops, leaving it alone, when enchant stopped with an unworked wand in hand' do
        tm = dorhum
        enchant_runs(true, false)
        allow(DRCI).to receive(:in_hands?).with('wand').and_return(true)
        allow(DRCI).to receive(:put_away_item?).and_return(true)

        expect { tm.enchant_items('wand', 'wand', 3) }.to raise_error(SystemExit)

        expect(DRCI).to have_received(:put_away_item?).once
        expect(DRC).to have_received(:message).with('enchant did not finish a wand for the wands; stopping.')
      end

      it 'puts an unworked base item enchant left in hand back in the crafting bag, not the loot bag' do
        tm = dorhum
        enchant_runs(false)
        allow(DRCI).to receive(:in_hands?).with('wand').and_return(true)
        allow(DRCI).to receive(:put_away_item?)
        expect(DRCC).to receive(:stow_crafting_item).with('wand', 'duffel bag', nil)

        expect { tm.enchant_items('wand', 'wand', 3) }.to raise_error(SystemExit)

        expect(DRCI).not_to have_received(:put_away_item?)
      end

      it 'trashes a finished item the loot bag will not take, rather than stow it with the unworked ones, and stops' do
        tm = dorhum(worn_trashcan: 'bucket', worn_trashcan_verb: 'tap')
        enchant_runs(true, true, true)
        allow(DRCI).to receive(:in_hands?).with('rock').and_return(true)
        allow(DRCI).to receive(:put_away_item?).with('rock', 'backpack').and_return(false)
        expect(DRCI).to receive(:dispose_trash).with('rock', 'bucket', 'tap').and_return(true)
        expect(DRCC).not_to receive(:stow_crafting_item)

        expect { tm.enchant_items('spongestone', 'rock', 3) }.to raise_error(SystemExit)

        expect(DRC).to have_received(:wait_for_script_to_complete).once
        expect(DRC).to have_received(:message).with('The finished rock would not go in backpack, so it went in the trash. Make room in backpack, then start again. Stopping.')
        expect(DRC).not_to have_received(:message).with('3 spongestones completed')
      end

      it 'says the item is still in hand when the trash will not take it either' do
        tm = dorhum
        enchant_runs(true)
        allow(DRCI).to receive(:in_hands?).with('rock').and_return(true)
        allow(DRCI).to receive(:put_away_item?).and_return(false)
        allow(DRCI).to receive(:dispose_trash).and_return(false)

        expect { tm.enchant_items('spongestone', 'rock', 1) }.to raise_error(SystemExit)

        expect(DRC).to have_received(:message).with('The finished rock would not go in backpack, so it is still in your hand. Make room in backpack, then start again. Stopping.')
      end

      it 'stops when the finished item is not in hand' do
        tm = dorhum
        enchant_runs(true)
        allow(DRCI).to receive(:in_hands?).and_return(false)

        expect { tm.enchant_items('spongestone', 'rock', 1) }.to raise_error(SystemExit)
      end

      it "catches the game's completion line, not another player's" do
        tm = dorhum
        Flags.add(TaskMaster::ENCHANTED_FLAG, TaskMaster::ENCHANTED)
        expect(TaskMaster::ENCHANTED).to match(enchanted)
        expect(TaskMaster::ENCHANTED).not_to match(%(Mallory says, "#{enchanted}"))
        expect(TaskMaster::ENCHANTED).not_to match(%([General][Mallory] "#{enchanted}"))
        expect(TaskMaster::ENCHANTED).to match('With the enchantment complete, you collect your things.')
        expect(TaskMaster::ENCHANTED).to match('With enchanting complete, you collect your things.')
        enchant_runs(true)
        allow(DRCI).to receive(:in_hands?).and_return(true)
        allow(DRCI).to receive(:put_away_item?).and_return(true)

        tm.enchant_items('spongestone', 'rock', 1)

        expect(Flags.matchers).not_to have_key(TaskMaster::ENCHANTED_FLAG)
      end
    end

    # Mahtra's private forge (task_crafting_room 16936), 2026-11-02/03.
    describe 'the rental of task_crafting_room' do
      let(:notice) { '[It will expire Thu Dec  3 20:58:13 ET 2026.]' }
      let(:extended) { '[Your private forge rental has been extended until Thu Dec  3 00:56:41 ET 2026.]' }

      def enchant_runs(count, warn_on: nil)
        runs = 0
        allow(DRC).to receive(:wait_for_script_to_complete) do
          runs += 1
          Flags[TaskMaster::RENTAL_WARNING_FLAG] = true if runs == warn_on
          Flags[TaskMaster::ENCHANTED_FLAG] = true
        end
        allow(DRCI).to receive(:in_hands?).and_return(true)
        allow(DRCI).to receive(:put_away_item?).and_return(true)
        count
      end

      it 'reads the expiry off the notice in US Eastern time, standard time in winter and daylight time in summer' do
        tm = dorhum
        winter = TaskMaster::RENTAL_EXPIRES.match(notice)
        summer = TaskMaster::RENTAL_EXPIRES.match('[It will expire Fri Jul 10 12:00:00 ET 2026.]')

        expect(tm.rental_minutes_left(winter, Time.utc(2026, 12, 4, 1, 48, 13))).to eq(10.0)
        expect(tm.rental_minutes_left(summer, Time.utc(2026, 7, 10, 15, 50, 0))).to eq(10.0)
      end

      it "puts the sentry's warning at ten minutes before the notice's time (2026-11-02, the day daylight time ended)" do
        expires = TaskMaster::RENTAL_EXPIRES.match('[It will expire Sun Nov  1 18:58:13 ET 2026.]')

        expect(dorhum.rental_minutes_left(expires, Time.utc(2026, 11, 1, 23, 48, 17))).to be_between(9.9, 10.0)
      end

      it 'checks the notice before enchanting and leaves a rental with time on it alone' do
        tm = dorhum(crafting_room: 16_936)
        allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 4, 0, 0, 0))
        game('read notice' => notice)
        tm.enchant_items('spongestone', 'rock', enchant_runs(2))

        expect(DRC).to have_received(:bput).with('read notice', any_args).once
        expect(DRC).not_to have_received(:bput).with('mark notice', any_args)
      end

      it 'renews before the first item when the rental ends within ten minutes' do
        tm = dorhum(crafting_room: 16_936)
        allow(Time).to receive(:now).and_return(Time.utc(2026, 12, 4, 1, 52, 0))
        game('read notice' => notice, 'mark notice' => extended)
        tm.enchant_items('spongestone', 'rock', enchant_runs(1))

        expect(DRC).to have_received(:bput).with('mark notice', any_args).once
      end

      it "renews between items once the sentry's warning has come" do
        tm = dorhum(crafting_room: 16_936)
        allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 4, 0, 0, 0))
        order = []
        game('read notice' => notice, 'mark notice' => ->(*) { order << :mark && extended })
        allow(DRC).to receive(:wait_for_script_to_complete) do
          order << :enchant
          Flags[TaskMaster::RENTAL_WARNING_FLAG] = true if order.count(:enchant) == 1
          Flags[TaskMaster::ENCHANTED_FLAG] = true
        end
        allow(DRCI).to receive(:in_hands?).and_return(true)
        allow(DRCI).to receive(:put_away_item?).and_return(true)

        tm.enchant_items('spongestone', 'rock', 3)

        expect(order).to eq(%i[enchant mark enchant enchant])
      end

      it 'stops before the next item when the rental is not extended' do
        tm = dorhum(crafting_room: 16_936)
        allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 4, 0, 0, 0))
        game('read notice' => notice, 'mark notice' => '')

        expect { tm.enchant_items('spongestone', 'rock', enchant_runs(3, warn_on: 1)) }.to raise_error(SystemExit)

        expect(DRC).to have_received(:wait_for_script_to_complete).once
        expect(DRC).to have_received(:message).with('Could not renew the rental of room 16936; stopping before it runs out.')
      end

      it 'reads no notice and marks nothing where there is no notice, or without task_crafting_room' do
        unrented = dorhum(crafting_room: 2071)
        game('read notice' => 'I could not find what you were referring to.')
        unrented.enchant_items('spongestone', 'rock', enchant_runs(2, warn_on: 1))
        dorhum.enchant_items('spongestone', 'rock', enchant_runs(1))

        expect(DRC).to have_received(:bput).with('read notice', any_args).once
        expect(DRC).not_to have_received(:bput).with('mark notice', any_args)
      end

      it 'takes the warning behind a leading XML tag too' do
        expect('<pushBold/>[You have less than 10 minutes remaining.  If you wish to renew your rental, simply MARK NOTICE to signal the sentry.]').to match(TaskMaster::RENTAL_WARNING)
      end

      it "takes the sentry's warning, not a player repeating it" do
        warning = '[You have less than 10 minutes remaining.  If you wish to renew your rental, simply MARK NOTICE to signal the sentry.]'
        expect(warning).to match(TaskMaster::RENTAL_WARNING)
        [%(Mallory says, "#{warning}"), %([General][Mallory] "#{warning}"), %(Mallory whispers, "#{warning}")].each do |line|
          expect(line).not_to match(TaskMaster::RENTAL_WARNING)
        end
      end
    end

    describe '#dorhum' do
      it 'checks the tools, buys the sigils, gets the base items, checks the fount, finds a room, enchants, then repairs' do
        tm = dorhum(settings: { enchanting_tools: %w[brazier burin], enchanting_belt: nil })
        steps = []
        allow(tm).to receive(:ensure_tools) { |tools, discipline| steps << [:tools, tools, discipline] }
        allow(tm).to receive(:buy_sigils) { |sigils, count| steps << [:sigils, sigils, count] }
        allow(tm).to receive(:forage_rocks) { |count| steps << [:rocks, count] }
        allow(DRCC).to receive(:fount) { |*args| steps << [:fount, *args] }
        allow(tm).to receive(:go_to_enchanting_room) { steps << :room }
        allow(tm).to receive(:enchant_items) { |*args| steps << [:enchant, *args] }
        allow(tm).to receive(:repair) { |*args| steps << [:repair, *args] }

        tm.dorhum('spongestone', 8, %w[congruence decay])

        expect(steps).to eq([[:tools, %w[burin rod], 'enchanting'], [:sigils, %w[congruence decay], 8], [:fount, 14_754, 1, 3, 8, 'duffel bag', [], nil], [:rocks, 8],
                             :room, [:enchant, 'spongestone', 'rock', 8], [:repair, %w[brazier burin], nil]])
      end

      it "stops before buying anything when task_loot_bag already holds the task's noun" do
        tm = dorhum
        game("rummage /C rock in my backpack" => 'You rummage through a backpack looking for something similar to "rock" and see a smooth rock, a rock marble deed and a rock.')
        expect(tm).not_to receive(:buy_sigils)

        expect { tm.dorhum('spongestone', 6, %w[congruence decay]) }.to raise_error(SystemExit)

        expect(DRC).to have_received(:message).with('backpack already holds 2 rocks that this task has not made or could not hand in: left from another task, not taken at the hand-in, or your own. ' \
                                                    'The hand-in would give those first. Move them out of backpack, then start again.')
      end

      it 'checks the loot bag right after a resume hand-in, before asking for instructions or going to the bank' do
        tm = dorhum
        allow(tm).to receive(:read_task).and_return(['spongestone', 3])
        allow(tm).to receive(:set_aside_held_base)
        allow(tm).to receive(:turn_in_banked).and_return(3)
        game("rummage /C rock in my backpack" => 'You rummage through a backpack looking for something similar to "rock" and see a rock.')
        expect(tm).not_to receive(:ensure_instructions)
        expect(tm).not_to receive(:top_up_copper)

        expect { tm.resume_task }.to raise_error(SystemExit)

        expect(DRC).to have_received(:message).with(/backpack already holds 1 rock that this task has not made or could not hand in/)
      end

      it 'checks the loot bag once on a resume, not again in dorhum' do
        tm = dorhum
        allow(tm).to receive(:read_task).and_return(['spongestone', 3])
        allow(tm).to receive(:set_aside_held_base)
        allow(tm).to receive(:turn_in_banked).and_return(3)
        %i[ensure_instructions refresh_haste top_up_copper ensure_tools buy_sigils forage_rocks go_to_enchanting_room enchant_items repair complete_task].each { |step| allow(tm).to receive(step) }
        allow(tm).to receive(:read_instructions).and_return(['spongestone', 3, %w[congruence decay]])
        allow(DRCI).to receive(:exists?).and_return(false)
        allow(DRCC).to receive(:fount)
        game("rummage /C rock in my backpack" => 'You rummage through a backpack looking for something similar to "rock" but there is nothing in there like that.')

        expect { tm.resume_task }.to raise_error(SystemExit)

        expect(DRC).to have_received(:bput).with('rummage /C rock in my backpack', any_args).once
        expect(tm).to have_received(:enchant_items).with('spongestone', 'rock', 3)
      end

      it 'carries on when task_loot_bag holds none, and does not count a "rock marble deed"' do
        tm = dorhum
        %i[ensure_tools buy_sigils forage_rocks go_to_enchanting_room enchant_items repair].each { |step| allow(tm).to receive(step) }
        allow(DRCC).to receive(:fount)
        game("rummage /C rock in my backpack" => 'You rummage through a backpack looking for something similar to "rock" and see a rock marble deed.')

        expect { tm.dorhum('spongestone', 5, %w[congruence decay]) }.not_to raise_error

        expect(tm).to have_received(:enchant_items).with('spongestone', 'rock', 5)
      end

      it 'sends every enchanting tool but the fount for repair' do
        tm = dorhum(settings: { enchanting_tools: ['brazier', 'fragile fount', 'burin', 'augmenting loop'], enchanting_belt: nil })
        %i[ensure_tools buy_sigils forage_rocks go_to_enchanting_room enchant_items].each { |step| allow(tm).to receive(step) }
        allow(DRCC).to receive(:fount)
        expect(tm).to receive(:repair).with(['brazier', 'burin', 'augmenting loop'], nil)

        tm.dorhum('spongestone', 6, %w[congruence decay])
      end

      it 'buys wands for a virga wand task' do
        tm = dorhum
        %i[ensure_tools buy_sigils go_to_enchanting_room enchant_items repair].each { |step| allow(tm).to receive(step) }
        allow(DRCC).to receive(:fount)
        expect(tm).to receive(:buy_wands).with(6)

        tm.dorhum('wand', 6, %w[induction])
      end
    end

    describe '#ensure_tools' do
      it 'carries on when every tool is on you, asking no clerk' do
        tm = dorhum
        allow(DRCI).to receive(:exists?).and_return(true)
        expect(DRC).not_to receive(:wait_for_script_to_complete)

        expect { tm.ensure_tools(['burin', 'augmenting loop'], 'enchanting') }.not_to raise_error
      end

      it 'gets a missing tool from the society clerk' do
        tm = dorhum
        on_hand = ['burin']
        allow(DRCI).to receive(:exists?) { |tool| on_hand.include?(tool) }
        expect(DRC).to receive(:wait_for_script_to_complete).with('clerk-tools', %w[enchanting get]) { on_hand << 'augmenting loop' }

        expect { tm.ensure_tools(['burin', 'augmenting loop'], 'enchanting') }.not_to raise_error
      end

      it 'stops, naming the tools still missing, before anything is bought' do
        tm = dorhum
        allow(DRCI).to receive(:exists?) { |tool| tool == 'burin' }
        allow(DRC).to receive(:wait_for_script_to_complete)

        expect { tm.ensure_tools(['burin', 'augmenting loop', 'imbuement rod'], 'enchanting') }.to raise_error(SystemExit)

        expect(DRC).to have_received(:message)
          .with("Can't find augmenting loop, imbuement rod: not on you, and the enchanting clerk didn't have it. Stopping before buying anything.")
      end

      it 'leaves the fount and brazier out of what a Dorhum task must carry, and adds the imbue rod enchant falls back to' do
        expect(dorhum(settings: { enchanting_tools: ['small brazier', 'fount', 'burin', 'augmenting loop'] }).dorhum_tools)
          .to eq(['burin', 'augmenting loop', 'rod'])
      end

      it 'needs no rod when an Imbue spell is set up, and uses the rod named in enchanting_tools' do
        spell = dorhum(settings: { enchanting_tools: %w[burin], waggle_sets: { 'imbue' => { 'Imbue' => { 'mana' => 5 } } } })
        named = dorhum(settings: { enchanting_tools: ['burin', 'imbuement rod'] })

        expect([spell.dorhum_tools, named.dorhum_tools]).to eq([%w[burin], ['burin', 'imbuement rod']])
      end

      it 'needs your own brazier when enchanting in a set room that is not a Crossing brazier room' do
        tm = dorhum(crafting_room: 16_936, settings: { enchanting_tools: ['small brazier', 'burin', 'rod'] })

        expect(tm.dorhum_tools).to eq(['burin', 'rod', 'small brazier'])
      end

      it 'judges the task room, not enchanting_room, when both are set' do
        tm = dorhum(crafting_room: 16_936, settings: { enchanting_room: 14_758, enchanting_tools: ['small brazier', 'burin', 'rod'] })

        expect(tm.dorhum_tools).to include('small brazier')
      end

      it "needs no rod when an Imbue spell is set up, even with the rod in enchanting_tools" do
        tm = dorhum(settings: { enchanting_tools: ['burin', 'imbuement rod'], waggle_sets: { 'imbue' => { 'Imbue' => { 'mana' => 5 } } } })

        expect(tm.dorhum_tools).to eq(%w[burin])
      end

      it "needs no brazier of your own in another town's public brazier room" do
        $test_data.crafting['artificing']['Shard'] = { 'brazier-rooms' => [14_777, 14_778] }
        tm = dorhum(settings: { enchanting_room: 14_777, enchanting_tools: ['small brazier', 'burin', 'rod'] })

        expect(tm.dorhum_tools).to eq(%w[burin rod])
      end

      it 'needs no brazier of your own in a Crossing brazier room' do
        tm = dorhum(settings: { enchanting_room: 14_758, enchanting_tools: ['small brazier', 'burin', 'rod'] })

        expect(tm.dorhum_tools).to eq(%w[burin rod])
      end
    end

    describe 'paying for supplies' do
      before(:each) do
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRCI).to receive(:count_items_in_container).and_return(0)
      end

      it 'stops before ordering when the bank cannot cover the sigils' do
        allow(DRCM).to receive(:ensure_copper_on_hand).and_return(false)
        expect(DRCT).not_to receive(:order_item)

        expect { dorhum.buy_sigils(%w[decay], 8) }.to raise_error(SystemExit)

        expect(DRC).to have_received(:message).with(/Out of money: #{(8 * 1575) + 312 + 7500} Kronars/)
      end

      it 'stops when an order does not go through' do
        allow(DRCM).to receive(:ensure_copper_on_hand).and_return(true)
        allow(DRCT).to receive(:order_item).and_return('takes some coins from you', nil)

        expect { dorhum.buy_sigils(%w[decay], 8) }.to raise_error(SystemExit)

        expect(DRCC).to have_received(:stow_crafting_item).once
        expect(DRC).to have_received(:message).with('Could not buy a decay sigil-scroll. Stopping.')
      end

      it 'waits for the wand to reach a hand after the purchase line' do
        allow(DRCM).to receive(:ensure_copper_on_hand).and_return(true)
        allow(DRCT).to receive(:buy_item)
        allow(DRCI).to receive(:in_hands?).with('wand').and_return(false, false, true)

        expect { dorhum.buy_wands(1) }.not_to raise_error

        expect(DRCC).to have_received(:stow_crafting_item).with('wand', 'duffel bag', nil)
      end

      it 'asks the bank for nothing when every sigil-scroll is already carried' do
        game('rummage /C sigil-scroll in my duffel bag' => "You rummage through a heavy silk duffel bag looking for something similar to \"sigil-scroll\" and see #{Array.new(8, 'an intricate decay sigil-scroll').join(', ')}.")
        expect(DRCM).not_to receive(:ensure_copper_on_hand)
        expect(DRCT).not_to receive(:order_item)

        dorhum.buy_sigils(%w[decay], 8)
      end

      it 'stops when a wand does not land in hand' do
        allow(DRCM).to receive(:ensure_copper_on_hand).and_return(true)
        allow(DRCT).to receive(:buy_item)
        allow(DRCI).to receive(:in_hands?).with('wand').and_return(false)

        expect { dorhum.buy_wands(6) }.to raise_error(SystemExit)

        expect(DRCC).not_to have_received(:stow_crafting_item)
      end
    end

    it 'lists the enchanting tools for ;taskmaster dorhum tools' do
      expect(TaskMaster::TOOLS['dorhum']).to include('brazier', 'burin', 'augmenting loop')
    end

    it 'takes dorhum as a taskmaster' do
      expect(TaskMaster::ARG_DEFINITIONS.first.first[:options]).to include('dorhum')
    end
  end
end
