# frozen_string_literal: true

require 'ostruct'
require 'tmpdir'
require 'yaml'

require_relative 'spec_helper'

load_lic_class('taskmaster.lic', 'TaskMaster')
load_lic_class('remedy.lic', 'Remedy')

RSpec.describe TaskMaster do
  # The script's own stack map, so no example runs against a copy that has
  # drifted from it.
  let(:stackmap) { described_class::STACKMAP }
  let(:base_yaml) { YAML.unsafe_load_file(File.expand_path('../profiles/base.yaml', __dir__)) }

  # Turn-in replies as the game prints them (2025 Hollow Eve logs).
  let(:sack_handed) { 'Seamstress Zasele hands you a woven sack.' }
  let(:missed_give) { "What is it you're trying to give?" }
  # Her reply to an item the character did not make (Fizzlestiks, 2026-11-10).
  let(:not_made_by_you) { 'Seamstress Zasele shakes her head and fishes out a piece of parchment from her robe: "It needs to be something that you made."' }

  before do
    allow(DRC).to receive(:message)
    # A boost the game said this login has no credits for is remembered for
    # the Lich process (boost_spent?): forget it so no example sees another's.
    $taskmaster_boost_unavailable = nil
  end

  # A task_repair_every with an entry for every taskmaster, so a run that
  # repairs says nothing about it.
  def every_taskmaster_listed
    TaskMaster::TASKMASTERS.to_h { |npc| [npc, 0] }
  end

  # Stands in for the pickups in a run's steps: tool_pickup (every tool,
  # recorded as :tool_pickup) and collect_tools (one repairer, recorded as
  # :collect, or [:collect, room] with rooms), each bringing back every tool
  # it was given, so their notes are gone afterwards.
  def stub_pickups(tm, events, rooms: false)
    allow(tm).to receive(:repair_replies_known?).and_return(true)
    allow(tm).to receive(:tool_pickup) do
      events << :tool_pickup
      UserVars.taskmaster_repairs = []
    end
    allow(tm).to receive(:collect_tools) do |room, _name, records, **|
      events << (rooms ? [:collect, room] : :collect)
      records.each { |record| tm.forget_repair(record) }
      []
    end
  end

  # The repair replies of data/base-crafting.yaml, read once: what a
  # repairer answers when handed a tool (shared with workorders).
  def real_repair_replies
    @real_repair_replies ||= YAML.load_file(File.expand_path('../data/base-crafting.yaml', __dir__), aliases: true)['repair_replies']
  end

  # The shipped data/base-crafting.yaml, as lich-5's SCRIPT_DIR finds it:
  # its read is stubbed, so no example depends on the file system there.
  let(:shipped_path) { '/lich/scripts/data/base-crafting.yaml' }

  # The shipped file holds these replies, or (file:) is read as that
  # whole, or (raises:) its read raises that.
  def ship(replies = real_repair_replies, raises: nil, file: { 'repair_replies' => replies })
    stub_const('SCRIPT_DIR', '/lich/scripts')
    allow(YAML).to receive(:unsafe_load_file).and_call_original
    read = allow(YAML).to receive(:unsafe_load_file).with(shipped_path)
    raises ? read.and_raise(raises) : read.and_return(file)
  end

  # A bare instance: initialize runs the whole script, so each example builds
  # one with allocate and injects only the state the method under test reads.
  # settings: becomes @settings; every other keyword sets the ivar of that
  # name, replacing the defaults below. settings is a keyword too, since Ruby
  # would read a braceless settings hash as ivar keywords.
  def build(settings: {}, **ivars)
    tm = described_class.allocate
    { settings: OpenStruct.new(settings), bag: 'duffel bag', bag_items: [], npc: 'zasele', rooms: [16_145], stackmap: stackmap,
      repair_replies: real_repair_replies }
      .merge(ivars)
      .each { |name, value| tm.instance_variable_set(:"@#{name}", value) }
    tm
  end

  # What DRC.bput hands back for a game line: the text of the first matcher
  # (a String is matched as /string/i) that matches it, in the order given,
  # or '' when none does (lich-5 common.rb, bput).
  #
  # @param line [String]
  # @param matchers [Array<String, Regexp>]
  # @return [String]
  def bput_match(line, matchers)
    matchers.flatten.each do |matcher|
      found = line.to_s.match(matcher.is_a?(Regexp) ? matcher : /#{matcher}/i)
      return found[0] if found
    end
    ''
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

  # INVENTORY of a container as Lich::Util.issue_command returns it: raw
  # lines from the header to the end of the reply, each item, with its
  # article, on a line of its own indented by two spaces, as Kythkani's
  # "inve sack" showed (2026-11-09 16:51:38 NZDT). With no names, the reply
  # an empty one gives ("There's nothing inside a woven sack!", Hollow Eve
  # 2026).
  def inventoried(names, container: 'heavy silk duffel bag', noun: 'bag', id: '21309821')
    link = %(<a exist="#{id}" noun="#{noun}">#{container}</a>)
    return ["There's nothing inside a #{link}!"] if names.empty?

    ["Inside a #{link}, you see:", '', *names.map { |name| "  #{name}" }, '', "[Use <d cmd='inventory help'>INVENTORY HELP</d> for more options.]"]
  end

  # Lich::Util.issue_command replies keyed by the start of the command that
  # produces them: the lines it returns, or a lambda called with the command
  # that gives them. Any other command gets none, as on a timeout.
  def inventory_replies(responses)
    allow(Lich::Util).to receive(:issue_command) do |command, *|
      reply = responses.find { |prefix, _| command.start_with?(prefix) }&.last
      Array(reply.respond_to?(:call) ? reply.call(command) : reply)
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
    rope = OpenStruct.new(name: 'coil of burlap reinforced rope', noun: 'rope', id: '758800')
    allow(GameObj).to receive(:right_hand) { state[:holding] ? rope : OpenStruct.new(name: 'Empty', noun: nil, id: nil) }
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
  # listed: whether INVENTORY of a container (by name, or "#id" of a worn
  # one in $worn_items whose name holds the container's) answers, listing
  # its pieces. others: other containers' pieces by container name, e.g.
  # { 'backpack' => { 'bronze ingot' => 2 } }.
  def stock_world(pieces, worn_leathers: false, refuse: false, bag_full: false, no_floor: false, hands: {}, listed: true, others: {})
    world = { bag: pieces.dup, hands: { right: nil, left: nil }.merge(hands), floor: [], bucket: [], sent: [], others: others.transform_values(&:dup) }
    contents = ->(container) { container == 'duffel bag' ? world[:bag] : world[:others][container] }
    next_id = 2_222_485
    allow(GameObj).to receive(:right_hand) { world[:hands][:right] || OpenStruct.new(name: 'Empty', noun: nil, id: nil) }
    allow(GameObj).to receive(:left_hand) { world[:hands][:left] || OpenStruct.new(name: 'Empty', noun: nil, id: nil) }
    allow(DRC).to receive(:right_hand) { world[:hands][:right]&.name }
    allow(DRC).to receive(:left_hand) { world[:hands][:left]&.name }

    held = ->(ref) { world[:hands].find { |_, obj| obj && ["##{obj.id}", "my #{obj.noun}", "my #{obj.name}"].include?(ref) }&.first }
    worn = ->(ref) { worn_leathers && ref.start_with?('my ') && 'leathers'.start_with?(ref.delete_prefix('my ')) }
    reply = lambda do |command|
      case command
      when /\Aget my (.+) from my (.+)\z/
        stock = Regexp.last_match(1)
        from = contents.call(Regexp.last_match(2))
        hand = world[:hands].find { |_, obj| obj.nil? }&.first
        next 'You need a free hand to pick that up.' unless hand
        next 'What were you referring to?' unless from&.fetch(stock, 0)&.positive?

        from[stock] -= 1
        world[:hands][hand] = OpenStruct.new(name: stock, noun: stock.split.last, id: (next_id += 1).to_s)
        "You get some #{stock} from inside your #{Regexp.last_match(2)}."
      when /\Aput (my \w+(?: \w+)?|#\d+) in (my bucket|bin|my .+)\z/
        ref = Regexp.last_match(1)
        into = Regexp.last_match(2)
        # A container of ours (the duffel bag or one of others), else a bin.
        container = %w[bin my\ bucket].include?(into) ? nil : contents.call(into.delete_prefix('my '))
        next '' if container.nil? && !%w[bin my\ bucket].include?(into)
        next 'Perhaps you should be holding that first.' if worn.call(ref)

        hand = held.call(ref)
        next 'What were you referring to?' unless hand

        piece = world[:hands][hand]
        if container
          next "There isn't any more room in the duffel bag for that." if bag_full && into == 'my duffel bag'

          container[piece.name] = container.fetch(piece.name, 0) + 1
        elsif refuse
          next "There isn't any more room in the #{into.delete_prefix('my ')} for that."
        end
        world[:bucket] << piece if into == 'my bucket'
        world[:hands][hand] = nil
        container ? "You put your #{piece.noun} in your #{into.delete_prefix('my ')}." : "You drop your #{piece.noun} in a #{into.delete_prefix('my ')}."
      when /\Adrop (#\d+)\z/
        hand = held.call(Regexp.last_match(1))
        next 'What were you referring to?' unless hand
        next "You can't do that here." if no_floor

        world[:floor] << world[:hands][hand].name
        world[:hands][hand] = nil
        'You drop some stock.'
      when /\Aget #(\d+)\z/
        piece = world[:bucket].find { |obj| obj.id == Regexp.last_match(1) }
        hand = world[:hands].find { |_, obj| obj.nil? }&.first
        next 'What were you referring to?' unless piece
        next 'You need a free hand to pick that up.' unless hand

        world[:bucket].delete(piece)
        world[:hands][hand] = piece
        "You get some #{piece.name} from inside your silversteel bucket."
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
    allow(Lich::Util).to receive(:issue_command) do |command, *|
      world[:sent] << command
      ref = command.delete_prefix('inventory ')
      if ref.start_with?('#')
        bag = Array($worn_items).find { |item| "##{item.id}" == ref }
        ref = (['duffel bag'] + world[:others].keys).select { |name| bag&.name.to_s.include?(name) }.max_by(&:size)
      end
      held_in = contents.call(ref)
      next [] unless listed && held_in

      inventoried(held_in.flat_map { |name, count| ["a #{name}"] * count })
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
    # (npc:, repeat:, marathon: ...). ticket: whether Zasele's scissors are
    # noted as left for repair (UserVars.taskmaster_repairs); samples: the taskmasters cycle picks, in order. The wrap-up flag
    # goes up with the turn-in numbered wrap_up_after. stock_ok: what
    # check_stock answers; short_after_restock: what still_short? answers
    # once a task's restock is done; restocks: what each restock returns
    # (the stocks it got none of), in order, then none; made: how many items
    # tailor_item makes, every item owed when nil; taps: record each TAP
    # (DRCI.exists?, finding nothing) as [:tap, item]. Returns the recorded
    # steps, in order.
    def start(settings: {}, ticket: false, stock_ok: true, short_after_restock: false, restocks: [], made: nil, wrap_up_after: nil, samples: [], renote: false, taps: false, **args)
      tm = described_class.allocate
      events = []
      completed = 0
      allow(tm).to receive(:get_settings).and_return(OpenStruct.new({ outfitting_tools: ['scissors'], outfitting_belt: outfitting_belt, task_repair_every: every_taskmaster_listed }.merge(settings)))
      allow(tm).to receive(:get_data).and_return({ 'stock' => {} })
      allow(tm).to receive(:parse_args) do |definitions|
        events << [:parse_args, definitions.map { |group| group.map { |arg| arg[:name] } }]
        OpenStruct.new(args)
      end
      allow_any_instance_of(Array).to receive(:sample).and_wrap_original do |original, *rest|
        original.receiver == %w[poltu bradyn zasele] ? samples.shift : original.call(*rest)
      end
      UserVars.taskmaster_repairs = ticket ? [{ 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'scissors', 'item' => 'jagged scissors' }] : nil
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
      stub_pickups(tm, events)
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
        # renote: the task left its scissors for repair again.
        tm.note_repair('npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'scissors', 'item' => 'jagged scissors') if renote
      end
      allow(tm).to receive(:resume_task) do
        events << :resume
        exit
      end
      allow(tm).to receive(:restock) do
        events << :restock
        restocks.shift || []
      end
      allow(tm).to receive(:check_stock) do |*needed|
        events << [:check_stock, *needed]
        stock_ok
      end
      allow(tm).to receive(:still_short?).and_return(short_after_restock)
      allow(tm).to receive(:repair) { |tools, belt| events << [:repair, tools, belt] }
      allow(tm).to receive(:find_npc) { |rooms, npc| events << [:find_npc, rooms.size, npc] }
      allow(tm).to receive(:tailor_item) do |*task|
        events << [:tailor, *task]
        made || task[1]
      end
      allow(DRCT).to receive(:dispose) { |item, room| events << [:dispose, item, room] }
      allow(tm).to receive(:_respond) { |text| events << [:respond, text] }
      allow(DRC).to receive(:message) { |text| events << [:message, text] unless text.start_with?("taskmaster version ") } # the version banner has its own example
      allow(DRCI).to receive(:exists?) { |item| events << [:tap, item] && false } if taps
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

    describe 'the tools left for repair, noted when left' do
      let(:offer) { 'You may accept by typing ACCEPT TASK.' }
      let(:on_task) { 'You are already on a task.' }

      # One pass of run_tasks for any taskmaster, every step recorded: each
      # TAP (DRCI.exists?), get_task's result from tasks, or the real
      # get_task with asks as ASK FOR TASK's replies. noted: the taskmasters
      # whose bowls are noted as left with Rangu; tools: what the task's work
      # uses (task_tools); rangu_ticket: what a TAP for a Rangu ticket finds.
      def ticket_run(npc: 'zasele', noted: [npc], tasks: [rope_task], asks: nil, tools: ['bowl'], rangu_ticket: false, **ivars)
        tm = build(npc: npc, cooldown_poll: 7, **ivars)
        events = []
        UserVars.taskmaster_repairs = noted.map { |giver| { 'npc' => giver, 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'bowl', 'item' => 'large purpleheart bowl' } }
        allow(tm).to receive(:reconcile_hands)
        allow(tm).to receive(:prepare_for_task) { events << :prepare }
        allow(DRCI).to receive(:exists?) { |item| events << [:tap, item] && rangu_ticket }
        allow(tm).to receive(:task_tools) { |giver, task| events << [:task_tools, giver, task] && tools }
        if asks
          allow(tm).to receive(:find_npc)
          allow(tm).to receive(:pause)
          game("ask #{npc} for task" => lambda { |*|
            events << :ask
            asks.shift || raise('asked again after the last reply')
          }, 'accept task' => 'You can check your progress with the TASK verb.')
          allow(tm).to receive(:finish) { events << :finish && rope_task }
          allow(tm).to receive(:resume_task) do
            events << :resume
            throw TaskMaster::FOREIGN_TASK_CANCELLED
          end
        else
          allow(tm).to receive(:get_task) { events << :get_task && tasks.shift }
        end
        stub_pickups(tm, events, rooms: true)
        allow(tm).to receive(npc.to_sym) { events << :work }
        allow(tm).to receive(:complete_task) { events << :complete }
        tm.run_tasks(OpenStruct.new)
        events
      end

      it 'taps for a Rangu ticket before the ask, and once a task is accepted picks up the noted tools its work uses' do
        %w[zasele poltu bradyn dorhum nezhiri].each do |npc|
          expect(ticket_run(npc: npc)).to eq([:prepare, [:tap, 'Rangu ticket'], :get_task, [:task_tools, npc, rope_task], [:collect, 19_209], :work, :complete]), npc
        end
      end

      it 'goes to no repairer when nothing is noted and no Rangu ticket is carried' do
        expect(ticket_run(noted: [])).to eq([:prepare, [:tap, 'Rangu ticket'], :get_task, [:task_tools, 'zasele', rope_task], :work, :complete])
      end

      it "goes to no repairer for another taskmaster's tool the task does not use, with no Rangu ticket carried" do
        expect(ticket_run(npc: 'zasele', noted: ['nezhiri'], tools: ['scissors']).map { |event| Array(event).first }).to eq(%i[prepare tap get_task task_tools work complete])
        expect(UserVars.taskmaster_repairs.size).to eq(1)
      end

      it 'goes to Rangu after the accept whenever the TAP before the ask found a Rangu ticket, noted or not' do
        expect(ticket_run(noted: [], rangu_ticket: true)).to include([:collect, 19_209])
        expect(ticket_run(noted: ['nezhiri'], tools: ['scissors'], rangu_ticket: true)).to include([:collect, 19_209])
      end

      it 'picks nothing up when get_task finished a task already open (resume_task picks up its own)' do
        expect(ticket_run(tasks: [nil])).to eq([:prepare, [:tap, 'Rangu ticket'], :get_task])
      end

      it 'neither taps nor picks up with task_self_repair' do
        expect(ticket_run(self_repair: true).map { |event| Array(event).first }).to eq(%i[prepare get_task task_tools work complete])
      end

      it "picks up after the accept when another taskmaster's task was cancelled first" do
        expect(ticket_run(asks: [on_task, offer]).map { |event| Array(event).first }).to eq(%i[prepare tap ask resume ask finish task_tools collect work complete])
      end
    end

    describe 'one task' do
      it 'sorts the hands, then runs copper, haste, before scripts, the task, the worker and the turn-in, in that order' do
        expect(start(npc: 'zasele')).to eq([:reconcile, *before_task, work, [:complete, 'rope', 2]])
      end

      it 'works the task with the named taskmaster' do
        expect(start(npc: 'poltu')).to include(work(:poltu))
      end

      it 'picks up repaired tools between getting the task and working it when one it uses is noted' do
        expect(start(npc: 'zasele', ticket: true)).to eq([:reconcile, *before_task, :collect, work, [:complete, 'rope', 2]])
      end

      it 'leaves repaired tools alone when repairing its own tools' do
        expect(start(npc: 'zasele', settings: { task_self_repair: true }, ticket: true)).not_to include(:collect, :tool_pickup)
      end

      it 'picks up every repaired tool at the end only with task_get_tools_on_completion (tool_pickup finds what there is)' do
        events = start(npc: 'zasele', settings: { task_self_repair: true, task_get_tools_on_completion: true }, ticket: true)
        expect(events.last(2)).to eq([[:complete, 'rope', 2], :tool_pickup])
        expect(start(npc: 'zasele', settings: { task_get_tools_on_completion: true }).last(2)).to eq([[:complete, 'rope', 2], :tool_pickup])
        expect(start(npc: 'zasele', ticket: true).last).to eq([:complete, 'rope', 2])
      end

      it 'says, before anything else, which taskmaster task_repair_every has no entry for' do
        events = start(npc: 'zasele', settings: { task_repair_every: nil })
        expect(events.first).to eq([:message, 'task_repair_every has no entry for zasele; its tools go for repair after every task.'])
        expect(start(npc: 'zasele', settings: { task_repair_every: nil, task_no_repair: true })).not_to include(a_collection_including(:message))
      end

      it 'names the three taskmasters cycle picks from, and says nothing in pickup mode' do
        events = start(cycle: true, samples: %w[zasele], wrap_up_after: 1, settings: { task_repair_every: { 'zasele' => 0 } })
        expect(events.select { |event| Array(event).first == :message }.map(&:last)).to eq(['task_repair_every has no entry for poltu; its tools go for repair after every task.',
                                                                                            'task_repair_every has no entry for bradyn; its tools go for repair after every task.'])
        expect(start(npc: 'zasele', pickup: true, settings: { task_repair_every: nil })).to eq(%i[tool_pickup exit])
      end

      it 'names Zasele in a cycle or marathon run that has no entry for it' do
        cycle = start(cycle: true, samples: %w[zasele], wrap_up_after: 1, settings: { task_repair_every: { 'poltu' => 0, 'bradyn' => 0 } })
        expect(cycle).to include([:message, 'task_repair_every has no entry for zasele; its tools go for repair after every task.'])
        marathon = start(npc: 'nezhiri', marathon: true, wrap_up_after: 1, settings: { task_repair_every: { 'nezhiri' => 0 } })
        expect(marathon).to include([:message, 'task_repair_every has no entry for zasele; its tools go for repair after every task.'])
      end

      it "names cycle's task_fallback_npc too when it is not one of the three" do
        events = start(cycle: true, samples: %w[zasele], wrap_up_after: 1, settings: { task_repair_every: { 'poltu' => 0, 'bradyn' => 0, 'zasele' => 0 }, task_fallback_npc: 'dorhum' })
        expect(events).to include([:message, 'task_repair_every has no entry for dorhum; its tools go for repair after every task.'])
      end

      it "names cycle's task_fallback_npc once when it is one of the three" do
        events = start(cycle: true, samples: %w[zasele], wrap_up_after: 1, settings: { task_repair_every: { 'default' => 0 }, task_fallback_npc: 'zasele' })
        expect(events.count([:message, 'task_repair_every has no entry for zasele; its tools go for repair after every task (the default entry).'])).to eq(1)
        expect(events.count { |event| Array(event).first == :message && event.last.include?('no entry for') }).to eq(3)
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

      it 'picks up the tools left for repair right after the opening restock, still in Crossing, and after every accept (once they are back no more), and at the end only when asked' do
        events = start(npc: 'zasele', marathon: true, ticket: true, renote: true, wrap_up_after: 2)
        expect(events).to eq([:reconcile, :restock, :collect, *marathon_task, *marathon_task.first(4), :collect, *marathon_task.drop(4), :exit])
        events = start(npc: 'zasele', marathon: true, ticket: true, stock_ok: false, wrap_up_after: 1)
        expect(events.count(:collect)).to eq(1)
        expect(events.last(2)).to eq([[:complete, 'rope', 2], :exit])
        events = start(npc: 'zasele', marathon: true, settings: { task_self_repair: true, task_get_tools_on_completion: true }, ticket: true, wrap_up_after: 1)
        expect(events.last(3)).to eq([[:complete, 'rope', 2], :tool_pickup, :exit])
      end

      it "taps for a Rangu ticket before each ask, in the taskmaster's cooldown, not after the accept" do
        events = start(npc: 'zasele', marathon: true, ticket: true, renote: true, taps: true, wrap_up_after: 2)
        first = [*marathon_task.first(3), [:tap, 'Rangu ticket'], :get_task, *marathon_task.drop(4)]
        task = [*marathon_task.first(3), [:tap, 'Rangu ticket'], :get_task, :collect, *marathon_task.drop(4)]
        # The opening pickup taps for itself (nothing looked before it) and collects the noted scissors.
        expect(events).to eq([:reconcile, :restock, [:tap, 'Rangu ticket'], :collect, *first, *task, :exit])
      end

      # Fizzlestiks, 2026-11-10 23:11: every walk to the outfitting shop
      # bonked on a closed exit, restock bought nothing, sew found no burlap
      # cloth, and the hand-in gave Zasele a bundling rope five times.
      describe 'when a restock leaves the stock short' do
        let(:unreached) do
          'Restocking bought no burlap cloth, rat leather: the outfitting shop (room 16667) could not be reached, or would not sell (see above). Stopping.'
        end

        it 'stops before asking for a task when the opening restock got none of a stock' do
          events = start(npc: 'zasele', marathon: true, ticket: true, restocks: [%w[cloth leather]], wrap_up_after: 1)
          # The tools left for repair are picked up first, as main did.
          expect(events).to eq([:reconcile, :restock, :collect, [:message, unreached], :exit])
        end

        it "stops before sewing when a task's restock got none of a stock, after picking up the tools left for repair" do
          events = start(npc: 'zasele', marathon: true, ticket: true, stock_ok: false, restocks: [[], %w[cloth leather]], wrap_up_after: 1)
          expect(events.first(7)).to eq([:reconcile, :restock, :collect, *marathon_task.first(4)])
          expect(events.last(5)).to eq([[:check_stock, 8, 'burlap', 'cloth'], [:repair, ['scissors'], outfitting_belt], :restock,
                                        [:message, unreached], :exit])
        end

        it 'stops before sewing when the restock left too little for the task' do
          events = start(npc: 'zasele', marathon: true, stock_ok: false, short_after_restock: true, wrap_up_after: 1)
          expect(events.last(3)).to eq([:restock, [:message, 'Restocking left too little burlap cloth for 2 ropes (8 yards). Stopping before any is made; the task stays open for the next run.'],
                                        :exit])
          expect(events.map { |event| Array(event).first }).not_to include(:tailor, :complete)
        end

        it 'checks the stock again only after a restock for the task' do
          events = start(npc: 'zasele', marathon: true, short_after_restock: true, wrap_up_after: 1)
          expect(events).to include([:tailor, 'rope', 2, 'cloth', 'burlap'], [:complete, 'rope', 2])
        end
      end

      it 'hands nothing in when sew made none of the items, so none of the player\'s own is given' do
        events = start(npc: 'zasele', marathon: true, made: 0, wrap_up_after: 1)
        expect(events.last(3)).to eq([[:tailor, 'rope', 2, 'cloth', 'burlap'],
                                      [:message, 'No rope was made, so none is handed in to Zasele. Stopping; the task stays open for the next run.'], :exit])
        expect(events.map { |event| Array(event).first }).not_to include(:complete)
      end

      it 'hands in what sew made when it made some' do
        expect(start(npc: 'zasele', marathon: true, made: 1, wrap_up_after: 1).last(3)).to eq([[:tailor, 'rope', 2, 'cloth', 'burlap'], [:complete, 'rope', 2], :exit])
      end
    end

    describe 'a task already open when the run asks for one' do
      # The real start-up, task loop, get_task, resume_task, read_task,
      # check_task_giver and read_instructions, with only the leaves that
      # talk to the game or do the work stubbed to record themselves.
      let(:rope_materials) { '   (1) finished fabric cloth (4 yards)' }
      let(:on_task) { 'You are already on a task.' }
      let(:offer) { 'You may accept by typing ACCEPT TASK.' }
      let(:wait) { 'Seamstress Zasele says, "I am sorry, you must wait before I can give you a task."' }
      # Another taskmaster's task: Zasele's journal line as the game prints it
      # (Fidon, 2026-11) with Dorhum named as the giver instead, as the
      # foreign-task examples under #resume_task do.
      let(:dorhum_journal) do
        'While visiting Andreshlew for the Hollow Eve festivities, Dorhum has asked you to craft some items to assist her ongoing efforts with the Merelew and others.  ' \
          'In particular, she wanted you to craft a coil of reinforced cloth rope and indicated that 3 would suffice.  So far, you have returned 0 to her.'
      end

      # asks: the replies to ASK <taskmaster> FOR TASK, in order; journals:
      # the TASK replies, in order (one per resume and one per accepted
      # task); banked: what turn_in_banked returns for each resume, in order
      # (0 when the bag alone finished the task), the owed count when
      # empty. The wrap-up flag goes up with the hand-in numbered
      # wrap_up_after, a banked finish counting as one. real_banked runs the
      # real turn_in_banked instead, with nothing to give (give_item nil).
      # real_zasele runs the real zasele worker, buy_stackables and trash,
      # recording the stock bought and binned. Returns the recorded steps;
      # :exit when the script ended.
      def open_run(asks:, journals:, banked: [], wrap_up_after: nil, ticket: false, settings: {}, samples: [], stock_ok: true,
                   real_banked: false, real_zasele: false, **args)
        tm = described_class.allocate
        events = []
        handed_in = 0
        hand_in = lambda do
          handed_in += 1
          Flags['wrap-up'] = true if handed_in == wrap_up_after
        end
        allow(tm).to receive(:get_settings).and_return(OpenStruct.new({ outfitting_tools: ['scissors'], outfitting_belt: outfitting_belt }.merge(settings)))
        allow(tm).to receive(:get_data).and_return({ 'stock' => { 'burlap' => { 'stock-value' => 125, 'stock-number' => 5 } } })
        allow(tm).to receive(:parse_args).and_return(OpenStruct.new(args))
        allow_any_instance_of(Array).to receive(:sample).and_wrap_original do |original, *rest|
          original.receiver == %w[poltu bradyn zasele] ? samples.shift : original.call(*rest)
        end
        UserVars.taskmaster_repairs = ticket ? [{ 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'scissors', 'item' => 'jagged scissors' }] : nil
        allow(DRCI).to receive(:stow_hands)
        allow(DRCC).to receive(:stow_crafting_item)
        allow(tm).to receive(:reconcile_hands) { events << :reconcile }
        allow(tm).to receive(:top_up_copper) { events << [:copper, tm.instance_variable_get(:@remainder), tm.instance_variable_get(:@dispose)] }
        allow(tm).to receive(:refresh_haste) { events << :haste }
        allow(tm).to receive(:run_before_scripts) { events << :before }
        allow(tm).to receive(:find_npc)
        allow(tm).to receive(:pause) { |seconds| events << [:pause, seconds] }
        stub_pickups(tm, events)
        allow(tm).to receive(:ensure_instructions) { |item, owed| events << [:ensure_instructions, item, owed] }
        if real_banked
          allow(tm).to receive(:give_item) do |item, owed|
            events << [:give, item, owed]
            nil
          end
        else
          allow(tm).to receive(:turn_in_banked) do |item, owed|
            left = banked.empty? ? owed : banked.shift
            events << [:banked, item, owed, left]
            if left.zero?
              # What the real hand-in's task_handed_in notes.
              tm.instance_variable_set(:@task_handed_in, true)
              hand_in.call
            end
            left
          end
        end
        if real_zasele
          allow(DRCM).to receive(:ensure_copper_on_hand)
          allow(tm).to receive(:buy_stock) { |*stock| events << [:buy, *stock] }
          allow(tm).to receive(:dispose_leftovers) { |*stock| events << [:dispose, *stock] }
        end
        (real_zasele ? %i[poltu bradyn] : %i[poltu bradyn zasele]).each do |npc|
          allow(tm).to receive(npc) do |*task|
            events << [:work, npc, *task]
            tm.instance_variable_set(:@remainder, true)
            tm.instance_variable_set(:@dispose, true)
          end
        end
        allow(tm).to receive(:complete_task) do |item, count|
          events << [:complete, item, count]
          tm.instance_variable_set(:@task_handed_in, true)
          hand_in.call
        end
        allow(tm).to receive(:cancel_task) { |giver, item| events << [:cancel, giver, item] }
        allow(tm).to receive(:restock) do
          events << :restock
          []
        end
        allow(tm).to receive(:check_stock) do |*needed|
          raise "check_stock with #{needed.inspect}" if needed.any?(&:nil?)

          events << [:check_stock, *needed]
          stock_ok
        end
        allow(tm).to receive(:still_short?).and_return(false)
        allow(tm).to receive(:repair)
        allow(tm).to receive(:tailor_item) do |*task|
          events << [:tailor, *task]
          task[1]
        end
        allow(DRC).to receive(:message) { |text| events << [:message, text] if text.start_with?('You are not on a task', 'You are on a task', 'Your task journal') }
        ask = lambda do |command, *|
          events << [:ask, command[/\Aask (\w+) for task/, 1]]
          # A loop that no longer stops fails here instead of hanging the suite.
          raise 'asked again after the last reply' if asks.empty?

          asks.shift
        end
        game('ask '                      => ask,
             'accept task'               => 'You can check your progress with the TASK verb.',
             'task'                      => ->(*) { journals.shift || raise('read the journal again after the last entry') },
             'read my rope instructions' => rope_materials)
        begin
          tm.send(:initialize)
          tm.run
        rescue SystemExit
          events << :exit
        end
        events
      end

      let(:before_task) { [[:copper, false, false], :haste, :before] }
      # A resume that finishes the open rope task: 2 of 5 left after the
      # banked items, worked and handed in. resume_task tops up copper and
      # haste itself before the work.
      let(:resumed) do
        [[:banked, 'rope', 2, 2], [:ensure_instructions, 'rope', 2], :haste, [:copper, false, false], [:work, :zasele, 'rope', 2, 4, 'cloth', 'burlap'], [:complete, 'rope', 2]]
      end
      let(:new_task) { [[:work, :zasele, 'rope', 3, 4, 'cloth', 'burlap'], [:complete, 'rope', 3]] }

      it 'with repeat, finishes the open task, then asks for and works a new one, clearing the flags first' do
        events = open_run(npc: 'zasele', repeat: true, wrap_up_after: 2, asks: [on_task, offer],
                          journals: [journal('a coil of reinforced cloth rope', 5, 3), journal('a coil of reinforced cloth rope', 3, 0)])
        expect(events).to eq([:reconcile, *before_task, [:ask, 'zasele'], *resumed,
                              *before_task, [:ask, 'zasele'], *new_task])
      end

      it 'with repeat, goes on asking when the banked items alone finish the open task, without working or handing in anything else for it' do
        events = open_run(npc: 'zasele', repeat: true, wrap_up_after: 2, asks: [on_task, offer], banked: [0],
                          journals: [journal('a coil of reinforced cloth rope', 5, 3), journal('a coil of reinforced cloth rope', 3, 0)])
        expect(events).to eq([:reconcile, *before_task, [:ask, 'zasele'], [:banked, 'rope', 2, 0],
                              *before_task, [:ask, 'zasele'], *new_task])
      end

      it 'with repeat, keeps finishing open tasks while the taskmaster says one is open, and waits out a cooldown before the next' do
        events = open_run(npc: 'zasele', repeat: true, wrap_up_after: 3, asks: [on_task, on_task, wait, offer], banked: [0, 2],
                          journals: [journal('a coil of reinforced cloth rope', 5, 3), journal('a coil of reinforced cloth rope', 5, 3), journal('a coil of reinforced cloth rope', 3, 0)])
        expect(events).to eq([:reconcile, *before_task, [:ask, 'zasele'], [:banked, 'rope', 2, 0],
                              *before_task, [:ask, 'zasele'], *resumed,
                              *before_task, [:ask, 'zasele'], [:pause, 15], [:ask, 'zasele'], *new_task])
      end

      it 'with repeat and tools left for repair, picks them up once, inside the resume of a resumed pass, and not again for the new task' do
        events = open_run(npc: 'zasele', repeat: true, wrap_up_after: 2, ticket: true, asks: [on_task, offer],
                          journals: [journal('a coil of reinforced cloth rope', 5, 3), journal('a coil of reinforced cloth rope', 3, 0)])
        resumed_with_pickup = resumed.dup.insert(4, :collect)
        expect(events).to eq([:reconcile, *before_task, [:ask, 'zasele'], *resumed_with_pickup,
                              *before_task, [:ask, 'zasele'], *new_task])
        events = open_run(npc: 'zasele', repeat: true, wrap_up_after: 2, ticket: true, banked: [0], asks: [on_task, offer],
                          journals: [journal('a coil of reinforced cloth rope', 5, 3), journal('a coil of reinforced cloth rope', 3, 0)])
        expect(events).to eq([:reconcile, *before_task, [:ask, 'zasele'], [:banked, 'rope', 2, 0],
                              *before_task, [:ask, 'zasele'], :collect, *new_task])
      end

      describe 'a journal that shows every item returned, with nothing to give' do
        let(:all_returned) { journal('a coil of reinforced cloth rope', 3, 3) }

        it 'with repeat, stops after one ask instead of resuming the same open task over and over' do
          events = open_run(npc: 'zasele', repeat: true, real_banked: true, asks: [on_task, on_task, on_task], journals: [all_returned, all_returned, all_returned])
          expect(events.count([:ask, 'zasele'])).to eq(1)
          expect(events.last(3)).to eq([[:give, 'rope', 0],
                                        [:message, 'Your task journal shows nothing more owed to Zasele, but nothing could be handed in, so the task is still open. Stopping.'], :exit])
          expect(events.map { |event| Array(event).first }).not_to include(:work, :complete)
        end

        it 'stops there with repeat even after an earlier task of the run was handed in' do
          events = open_run(npc: 'zasele', repeat: true, real_banked: true, asks: [offer, on_task, on_task],
                            journals: [journal('a coil of reinforced cloth rope', 3, 0), all_returned, all_returned])
          expect(events.count([:ask, 'zasele'])).to eq(2)
          expect(events.grep(Array).select { |event| event.first == :complete }).to eq([[:complete, 'rope', 3]])
          expect(events.last).to eq(:exit)
        end

        it 'stops the same way in marathon, cycle, a single run and finish' do
          [{ marathon: true }, { cycle: true, samples: %w[zasele] }, {}, { finish: true }].each do |mode|
            events = open_run(npc: 'zasele', real_banked: true, asks: [on_task, on_task], journals: [all_returned, all_returned], **mode)
            expect(events.count([:ask, 'zasele'])).to eq(mode[:finish] ? 0 : 1), mode.inspect
            expect(events.last(2)).to eq([[:message, 'Your task journal shows nothing more owed to Zasele, but nothing could be handed in, so the task is still open. Stopping.'], :exit]), mode.inspect
          end
        end
      end

      it 'stops at the wrap-up call during the resumed task without asking again, and still picks up tools at the end as asked' do
        events = open_run(npc: 'zasele', repeat: true, wrap_up_after: 1, ticket: true, settings: { task_self_repair: true, task_get_tools_on_completion: true },
                          asks: [on_task], journals: [journal('a coil of reinforced cloth rope', 5, 3)])
        expect(events).to eq([:reconcile, *before_task, [:ask, 'zasele'], *resumed, :tool_pickup])
      end

      it 'stops at the wrap-up call when the banked items finish the open task, with no tool pickup unless asked' do
        events = open_run(npc: 'zasele', repeat: true, wrap_up_after: 1, banked: [0], asks: [on_task], journals: [journal('a coil of reinforced cloth rope', 5, 3)])
        expect(events).to eq([:reconcile, *before_task, [:ask, 'zasele'], [:banked, 'rope', 2, 0]])
        expect(events).not_to include(:exit, :tool_pickup)
      end

      it 'with cycle, picks the next taskmaster from the cycle list after the resumed task and works its task' do
        events = open_run(npc: 'zasele', cycle: true, wrap_up_after: 2, samples: %w[zasele poltu], asks: [on_task, offer],
                          journals: [journal('a coil of reinforced cloth rope', 5, 3), journal('a coil of reinforced cloth rope', 3, 0)])
        expect(events.grep(Array).select { |event| event.first == :ask }).to eq([[:ask, 'zasele'], [:ask, 'poltu']])
        expect(events.last(2)).to eq([[:work, :poltu, 'rope', 3, 4, 'cloth', 'burlap'], [:complete, 'rope', 3]])
      end

      it 'without repeat, ends the script once the open task is handed in, before the end-of-run tool pickup, as before' do
        events = open_run(npc: 'zasele', ticket: true, settings: { task_self_repair: true, task_get_tools_on_completion: true },
                          asks: [on_task], journals: [journal('a coil of reinforced cloth rope', 5, 3)])
        expect(events).to eq([:reconcile, *before_task, [:ask, 'zasele'], *resumed, :exit])
      end

      it 'without repeat, ends the script when the banked items alone finish the open task' do
        events = open_run(npc: 'zasele', banked: [0], asks: [on_task], journals: [journal('a coil of reinforced cloth rope', 5, 3)])
        expect(events).to eq([:reconcile, *before_task, [:ask, 'zasele'], [:banked, 'rope', 2, 0], :exit])
      end

      it 'finish still ends the script once the task is handed in, never asking for another, even with repeat' do
        events = open_run(npc: 'zasele', finish: true, repeat: true, asks: [], journals: [journal('a coil of reinforced cloth rope', 5, 3)])
        expect(events).to eq([:reconcile, *resumed, :exit])
        events = open_run(npc: 'zasele', finish: true, repeat: true, banked: [0], asks: [], journals: [journal('a coil of reinforced cloth rope', 5, 3)])
        expect(events).to eq([:reconcile, [:banked, 'rope', 2, 0], :exit])
      end

      it 'still stops on a run that is not on a task after all, whatever the mode' do
        events = open_run(npc: 'zasele', repeat: true, asks: [on_task], journals: ['You are not currently on a task.'])
        expect(events.last(2)).to eq([[:message, 'You are not on a task with zasele.'], :exit])
      end

      describe 'marathon' do
        # The resumed rope task made from the carried stock: 2 left, 4 yards each.
        let(:resumed_marathon) do
          [[:banked, 'rope', 2, 2], [:ensure_instructions, 'rope', 2], :haste, [:copper, false, false],
           [:check_stock, 8, 'burlap', 'cloth'], [:tailor, 'rope', 2, 'cloth', 'burlap'], [:complete, 'rope', 2]]
        end

        it 'finishes the open task from the carried stock, then checks stock for, tailors and hands in the next, never checking stock with nothing' do
          events = open_run(npc: 'zasele', marathon: true, wrap_up_after: 2, asks: [on_task, offer],
                            journals: [journal('a coil of reinforced cloth rope', 5, 3), journal('a coil of reinforced cloth rope', 3, 0)])
          expect(events).to eq([:reconcile, :restock, [:copper, nil, nil], :haste, :before, [:ask, 'zasele'], *resumed_marathon,
                                [:copper, false, false], :haste, :before, [:ask, 'zasele'],
                                [:check_stock, 12, 'burlap', 'cloth'], [:tailor, 'rope', 3, 'cloth', 'burlap'], [:complete, 'rope', 3], :exit])
        end

        it 'never buys stock for the resumed task nor bins the carried stack, with the real zasele worker in reach' do
          events = open_run(npc: 'zasele', marathon: true, real_zasele: true, wrap_up_after: 2, asks: [on_task, offer],
                            journals: [journal('a coil of reinforced cloth rope', 5, 3), journal('a coil of reinforced cloth rope', 3, 0)])
          expect(events.map { |event| Array(event).first }).not_to include(:buy, :dispose)
          expect(events.grep(Array).select { |event| event.first == :tailor }).to eq([[:tailor, 'rope', 2, 'cloth', 'burlap'], [:tailor, 'rope', 3, 'cloth', 'burlap']])
          expect(events).to eq([:reconcile, :restock, [:copper, nil, nil], :haste, :before, [:ask, 'zasele'], *resumed_marathon,
                                [:copper, false, false], :haste, :before, [:ask, 'zasele'],
                                [:check_stock, 12, 'burlap', 'cloth'], [:tailor, 'rope', 3, 'cloth', 'burlap'], [:complete, 'rope', 3], :exit])
        end

        it 'restocks during the resumed task when the carried stock runs short, as for a new one' do
          events = open_run(npc: 'zasele', marathon: true, wrap_up_after: 1, stock_ok: false, asks: [on_task],
                            journals: [journal('a coil of reinforced cloth rope', 5, 3)])
          expect(events).to eq([:reconcile, :restock, [:copper, nil, nil], :haste, :before, [:ask, 'zasele'],
                                [:banked, 'rope', 2, 2], [:ensure_instructions, 'rope', 2], :haste, [:copper, false, false],
                                [:check_stock, 8, 'burlap', 'cloth'], :restock, [:tailor, 'rope', 2, 'cloth', 'burlap'], [:complete, 'rope', 2], :exit])
        end

        it 'outside marathon, the same resume with the real zasele worker buys stock for the task and bins the remainder' do
          events = open_run(npc: 'zasele', repeat: true, real_zasele: true, wrap_up_after: 1, asks: [on_task],
                            journals: [journal('a coil of reinforced cloth rope', 5, 3)])
          expect(events.grep(Array).select { |event| %i[buy dispose].include?(event.first) }).to eq([[:buy, 'cloth', 5, 1, 8], [:dispose, 'burlap cloth', 14_886]])
          expect(events).not_to include([:check_stock, 8, 'burlap', 'cloth'])
        end

        it 'goes on asking when the banked items alone finish the open task, and exits at the wrap-up call' do
          events = open_run(npc: 'zasele', marathon: true, wrap_up_after: 1, banked: [0], asks: [on_task], journals: [journal('a coil of reinforced cloth rope', 5, 3)])
          expect(events).to eq([:reconcile, :restock, [:copper, nil, nil], :haste, :before, [:ask, 'zasele'], [:banked, 'rope', 2, 0], :exit])
          events = open_run(npc: 'zasele', marathon: true, wrap_up_after: 2, banked: [0], asks: [on_task, offer],
                            journals: [journal('a coil of reinforced cloth rope', 5, 3), journal('a coil of reinforced cloth rope', 3, 0)])
          expect(events.last(4)).to eq([[:check_stock, 12, 'burlap', 'cloth'], [:tailor, 'rope', 3, 'cloth', 'burlap'], [:complete, 'rope', 3], :exit])
        end
      end

      describe "another taskmaster's task" do
        it 'with task_cancel_foreign_tasks, cancels it and asks its own taskmaster again in the same iteration, as before' do
          events = open_run(npc: 'zasele', settings: { task_cancel_foreign_tasks: true }, asks: [on_task, offer],
                            journals: [dorhum_journal, journal('a coil of reinforced cloth rope', 3, 0)])
          expect(events).to eq([:reconcile, *before_task, [:ask, 'zasele'], [:cancel, 'dorhum', 'rope'], [:pause, 600], [:ask, 'zasele'], *new_task])
        end

        it 'with repeat, cancels it, works its own task and goes on, nothing of the cancelled task worked or handed in' do
          events = open_run(npc: 'zasele', repeat: true, wrap_up_after: 1, settings: { task_cancel_foreign_tasks: true }, asks: [on_task, offer],
                            journals: [dorhum_journal, journal('a coil of reinforced cloth rope', 3, 0)])
          expect(events).to eq([:reconcile, *before_task, [:ask, 'zasele'], [:cancel, 'dorhum', 'rope'], [:pause, 600], [:ask, 'zasele'], *new_task])
        end

        it 'without task_cancel_foreign_tasks, stops with repeat too, saying whose task it is' do
          events = open_run(npc: 'zasele', repeat: true, asks: [on_task], journals: [dorhum_journal])
          expect(events.last(2)).to eq([[:message, 'You are on a task for Dorhum, not Zasele. Finish it with ;taskmaster dorhum, or cancel it with ASK DORHUM FOR TASK CANCEL (taskmasters then refuse you for about ten minutes). Or set task_cancel_foreign_tasks to have taskmaster cancel such tasks itself.'], :exit])
          expect(events.map { |event| Array(event).first }).not_to include(:banked, :work, :complete)
        end

        # A cycle run that stopped before a task's work (a tool still at
        # repair, say) leaves that task open, and the next cycle run picks
        # its taskmaster at random.
        describe 'in a cycle run' do
          let(:poltu_journal) { dorhum_journal.sub('Dorhum', 'Poltu') }

          it "finishes an open task of another taskmaster cycle works, whichever it picked, and neither stops nor cancels it" do
            [{}, { settings: { task_cancel_foreign_tasks: true } }].each do |mode|
              events = open_run(npc: 'zasele', cycle: true, wrap_up_after: 2, samples: %w[zasele bradyn], asks: [on_task, offer],
                                journals: [poltu_journal, journal('a coil of reinforced cloth rope', 3, 0)], **mode)
              expect(events).to include([:message, 'You are on a task for Poltu, one of the taskmasters cycle works; finishing it.']), mode.inspect
              expect(events.map { |event| Array(event).first }).not_to include(:cancel, :exit)
              expect(events.grep(Array).select { |event| %i[work ask].include?(event.first) })
                .to eq([[:ask, 'zasele'], [:work, :poltu, 'rope', 3, 4, 'cloth', 'burlap'], [:ask, 'bradyn'], [:work, :bradyn, 'rope', 3, 4, 'cloth', 'burlap']]), mode.inspect
            end
          end

          it "still stops on an open task of a taskmaster cycle does not work (Dorhum's)" do
            events = open_run(npc: 'zasele', cycle: true, samples: %w[zasele], asks: [on_task], journals: [dorhum_journal])
            expect(events.last(2)).to eq([[:message, 'You are on a task for Dorhum, not Zasele. Finish it with ;taskmaster dorhum, or cancel it with ASK DORHUM FOR TASK CANCEL (taskmasters then refuse you for about ten minutes). Or set task_cancel_foreign_tasks to have taskmaster cancel such tasks itself.'], :exit])
          end
        end
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

      it 'loot_history prints each taskmaster\'s sacks and exits, Dorhum\'s and Nezhiri\'s empty when an older history has none' do
        UserVars.taskmaster_sacks = { 'poltu' => ['a bronze bar.'], 'bradyn' => [], 'zasele' => ['some coral dye.', 'a large haledroth shard.'] }
        expect(start(npc: 'zasele', loot_history: true)).to eq([[:message, 'Sack history for Taskmaster Poltu:'], [:message, 'a bronze bar.'],
                                                                [:message, 'Sack history for Taskmaster Bradyn:'],
                                                                [:message, 'Sack history for Taskmaster Zasele:'], [:message, 'some coral dye.'], [:message, 'a large haledroth shard.'],
                                                                [:message, 'Sack history for Taskmaster Dorhum:'],
                                                                [:message, 'Sack history for Taskmaster Nezhiri:'],
                                                                :exit])
      end

      it 'pickup collects every tool left for repair (tool_pickup finds what there is), then exits' do
        expect(start(npc: 'zasele', pickup: true, ticket: true)).to eq(%i[tool_pickup exit])
        expect(start(npc: 'zasele', pickup: true, ticket: false)).to eq(%i[tool_pickup exit])
      end
    end
  end

  describe '#reconcile_hands' do
    let(:outfitting_belt) { { 'name' => 'tailor belt', 'items' => ['sewing needles', 'scissors'] } }

    # A held item as the game shows it. GameObj, and so DRC.right_hand, has
    # only the short hand text, as in <left exist="758800" noun="rope">
    # reinforced rope</left> for a "coil of unfinished burlap reinforced
    # rope", and "leather straps" for "some wide unfinished rat-pelt leather
    # straps": neither says "unfinished" or the stock. Only GLANCE names it in
    # full. The hand texts of pieces no log shows in hand follow the logged
    # ones (adjective and noun).
    def held(text, noun, id, full)
      OpenStruct.new(name: text, noun: noun, id: id, full: full)
    end

    let(:rope_piece) { held('reinforced rope', 'rope', '758800', 'a coil of unfinished burlap reinforced rope') }
    let(:rope) { held('reinforced rope', 'rope', '758800', 'a coil of burlap reinforced rope') }
    let(:straps_piece) { held('leather straps', 'straps', '758801', 'some wide unfinished rat-pelt leather straps') }
    let(:outfit_piece) { held('knitted outfit', 'outfit', '758802', 'an unfinished knitted wool outfit') }
    let(:netting_piece) { held('reinforced netting', 'netting', '758803', 'some unfinished burlap reinforced netting') }
    let(:needles) { held('sewing needles', 'needles', '600001', 'some slender agonite sewing needles') }
    let(:scissors) { held('serrated scissors', 'scissors', '600002', 'some loimic serrated scissors') }

    # Hands after a disconnect, and after_sew: the hands once sew has run,
    # which is how the result is judged. GLANCE answers as the game does
    # (glanced_hands), from each hand's full name; glance: another reply,
    # or a list of them, one per GLANCE, nil for the game's own.
    # put_ok is what putting the finished piece in the bag returns.
    # Returns the instance, the scripts launched and the commands sent.
    def reconcile(right:, left:, npc: 'zasele', after_sew: nil, glance: nil, disposed: true, put_ok: true)
      tm = build(settings: { outfitting_belt: outfitting_belt }, npc: npc, worn_trashcan: nil, worn_trashcan_verb: nil)
      hands = { right: right, left: left }
      empty = OpenStruct.new(name: 'Empty', noun: nil, id: nil)
      allow(GameObj).to receive(:right_hand) { hands[:right] || empty }
      allow(GameObj).to receive(:left_hand) { hands[:left] || empty }
      allow(DRC).to receive(:right_hand) { hands[:right]&.name }
      allow(DRC).to receive(:left_hand) { hands[:left]&.name }
      allow(tm).to receive(:sort_sack)
      sent = []
      glances = glance.is_a?(Array) ? glance.dup : nil
      allow(DRC).to receive(:bput) do |command, *|
        sent << command
        next '' unless command == 'glance'

        reply = glances ? glances.shift : glance
        next reply if reply

        r, l = hands.values_at(:right, :left).map { |obj| obj&.full }
        if r.nil? && l.nil?
          'You glance down at your empty hands.'
        elsif l.nil? && hands[:left].nil?
          "You glance down to see #{r} in your right hand and nothing in your left hand."
        elsif r.nil? && hands[:right].nil?
          "You glance down to see #{l} in your left hand."
        else
          "You glance down to see #{r} in your right hand and #{l} in your left hand."
        end
      end
      launched = []
      allow(DRC).to receive(:wait_for_script_to_complete) do |name, args|
        launched << [name, args]
        hands.merge!(after_sew) if after_sew
      end
      allow(DRCI).to receive(:dispose_trash) do |ref, *|
        next false unless disposed

        hands.each_key { |hand| hands[hand] = nil if hands[hand] && "##{hands[hand].id}" == ref }
        true
      end
      allow(DRCI).to receive(:put_away_item?).and_return(put_ok)
      allow(DRCC).to receive(:stow_crafting_item)
      tm.reconcile_hands
      [tm, launched, sent]
    end

    it 'finishes an unfinished sewn item with sew resume and bags it by its id' do
      _, launched, sent = reconcile(right: scissors, left: rope_piece, after_sew: { left: rope })
      expect(launched).to eq([['sew', %w[resume rope]]])
      expect(DRCI).to have_received(:put_away_item?).with('#758800', 'duffel bag')
      expect(DRCI).not_to have_received(:dispose_trash)
      expect(sent).to eq(%w[glance glance])
    end

    it 'finds the unfinished item in either hand, though the hand text is only "leather straps"' do
      _, launched, = reconcile(right: straps_piece, left: nil)
      expect(launched).to eq([['sew', %w[resume straps]]])
    end

    it 'resumes an unfinished piece made from the wool it buys for knitting tasks too' do
      _, launched, = reconcile(right: nil, left: outfit_piece)
      expect(launched).to eq([['sew', %w[resume outfit]]])
    end

    it 'sorts a reward sack held at start, by the name sort_sack takes a reward sack by' do
      tm, = reconcile(right: held('woven sack', 'sack', '4261859', 'a woven sack'), left: nil)
      expect(tm).to have_received(:sort_sack)
      tm, = reconcile(right: held('leather sack', 'sack', '4261860', 'a leather sack'), left: nil)
      expect(tm).not_to have_received(:sort_sack)
      # A pet sack (the one in sort_sack's pet-sack examples) is woven too,
      # but it is no reward sack, and sort_sack would find none to sort.
      tm, = reconcile(right: held('soft woven sack with a golden piglet charm', 'sack', '57001234', 'a soft woven sack with a golden piglet charm'), left: nil)
      expect(tm).not_to have_received(:sort_sack)
    end

    it 'leaves finished items, tools and empty hands alone' do
      _, launched, = reconcile(right: needles, left: held('reinforced netting', 'netting', '758804', 'some burlap reinforced netting'))
      expect(launched).to be_empty
      _, launched, = reconcile(right: nil, left: nil)
      expect(launched).to be_empty
      expect(DRCI).not_to have_received(:dispose_trash)
      expect(DRCI).not_to have_received(:put_away_item?)
      expect(DRCC).not_to have_received(:stow_crafting_item)
    end

    it 'does not try to resume knitting, whose work does not show in the hand' do
      _, launched, = reconcile(right: held('knitting needles', 'needles', '600003', 'some polished loimic knitting needles'), left: nil)
      expect(launched).to be_empty
    end

    it 'only resumes tailoring, never another taskmaster\'s unfinished item, and does not GLANCE for one' do
      _, launched, sent = reconcile(right: held('steel dagger', 'dagger', '700001', 'an unfinished steel dagger'), left: nil, npc: 'poltu')
      expect(launched).to be_empty
      expect(sent).to be_empty
    end

    it 'throws away an item sew could not finish by its id, stows the tool and carries on' do
      expect do
        reconcile(right: netting_piece, left: nil, after_sew: { left: needles })
      end.not_to raise_error
      expect(DRCI).to have_received(:dispose_trash).with('#758803', nil, nil)
      expect(DRCI).not_to have_received(:put_away_item?)
      expect(DRCC).to have_received(:stow_crafting_item).with('sewing needles', 'duffel bag', outfitting_belt)
      expect(DRCC).not_to have_received(:stow_crafting_item).with('reinforced netting', anything, anything)
      expect(DRC).to have_received(:message).with('sew could not finish your unfinished burlap reinforced netting. Throwing it away and starting a new task.')
    end

    it 'never bags an unfinished piece the trash would not take' do
      reconcile(right: netting_piece, left: nil, after_sew: { left: needles }, disposed: false)
      expect(DRCI).to have_received(:dispose_trash).with('#758803', nil, nil)
      expect(DRCI).not_to have_received(:put_away_item?)
      expect(DRCC).not_to have_received(:stow_crafting_item).with('reinforced netting', anything, anything)
    end

    it 'never throws away by an id no hand holds, as dispose_trash would GET it from wherever it is' do
      tm = build(settings: { outfitting_belt: outfitting_belt }, worn_trashcan: nil, worn_trashcan_verb: nil)
      allow(GameObj).to receive(:right_hand).and_return(needles)
      allow(GameObj).to receive(:left_hand).and_return(OpenStruct.new(name: 'Empty', noun: nil, id: nil))
      allow(DRCI).to receive(:dispose_trash)
      allow(DRCC).to receive(:stow_crafting_item)
      tm.discard_unfinished('758803', 'unfinished burlap reinforced netting')
      expect(DRCI).not_to have_received(:dispose_trash)
      expect(DRCC).not_to have_received(:stow_crafting_item)
    end

    it 'bags nothing when the item left the hands during sew' do
      reconcile(right: straps_piece, left: nil, after_sew: { right: nil, left: nil })
      expect(DRCC).not_to have_received(:stow_crafting_item)
      expect(DRCI).not_to have_received(:put_away_item?)
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'judges the piece by its id, not by another item in hand of its noun' do
      other_rope = held('reinforced rope', 'rope', '758899', 'a coil of burlap reinforced rope')
      reconcile(right: nil, left: straps_piece, after_sew: { left: nil, right: other_rope })
      expect(DRCI).not_to have_received(:put_away_item?)
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'leaves an unfinished item not made from the task stock alone, and says so' do
      [[held('steel dagger', 'dagger', '700001', 'an unfinished steel dagger'), 'unfinished steel dagger'],
       [held('silk shirt', 'shirt', '700002', 'an unfinished silk shirt'), 'unfinished silk shirt']].each do |obj, name|
        _, launched, = reconcile(right: obj, left: nil)
        expect(launched).to be_empty
        expect(DRCI).not_to have_received(:dispose_trash)
        expect(DRCC).not_to have_received(:stow_crafting_item)
        expect(DRC).to have_received(:message).with(/\ALeaving your #{name} alone/)
      end
    end

    it 'resumes the task piece and leaves the player\'s own unfinished item in the other hand' do
      shirt = held('silk shirt', 'shirt', '700002', 'an unfinished silk shirt')
      _, launched, = reconcile(right: shirt, left: rope_piece, after_sew: { left: rope })
      expect(launched).to eq([['sew', %w[resume rope]]])
      expect(DRCI).to have_received(:put_away_item?).with('#758800', 'duffel bag')
      expect(DRCI).not_to have_received(:put_away_item?).with('#700002', anything)
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'leaves the hands alone, and says so, when GLANCE does not answer' do
      _, launched, = reconcile(right: rope_piece, left: nil, glance: '')
      expect(launched).to be_empty
      expect(DRC).to have_received(:message).with(/Could not tell whether what you hold is an unfinished task piece/)
    end

    it 'leaves the hands alone when GLANCE names something other than GameObj shows in that hand' do
      _, launched, = reconcile(right: rope_piece, left: nil,
                               glance: 'You glance down to see some wide unfinished rat-pelt leather straps in your right hand and nothing in your left hand.')
      expect(launched).to be_empty
      expect(DRC).to have_received(:message).with(/Could not tell whether the reinforced rope in your hands/)
    end

    it 'leaves the hands alone when a held item has no id' do
      _, launched, = reconcile(right: held('reinforced rope', 'rope', nil, 'a coil of unfinished burlap reinforced rope'), left: nil)
      expect(launched).to be_empty
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'resumes the piece by the noun GameObj gives it, not the last word of its full name' do
      # No log shows a task piece whose name goes on past its noun; this
      # one does, so the GameObj noun and the name's last word differ.
      buckled = held('leather straps', 'straps', '758805', 'some wide unfinished rat-pelt leather straps with a brass buckle')
      _, launched, = reconcile(right: buckled, left: nil, after_sew: { right: held('leather straps', 'straps', '758805', 'some wide rat-pelt leather straps with a brass buckle') })
      expect(launched).to eq([['sew', %w[resume straps]]])
      expect(DRCI).to have_received(:put_away_item?).with('#758805', 'duffel bag')
    end

    it 'reads a held item whose game noun is several words, and resumes the piece in the other hand' do
      # noun-corpus.tsv: "aged ball and chain", the game's noun "ball and chain".
      chain = held('ball and chain', 'ball and chain', '700010', 'an aged ball and chain')
      _, launched, = reconcile(right: rope_piece, left: chain, after_sew: { right: rope })
      expect(launched).to eq([['sew', %w[resume rope]]])
      expect(DRCI).to have_received(:put_away_item?).with('#758800', 'duffel bag')
      expect(DRC).not_to have_received(:message).with(/Could not tell/)
    end

    it 'sends no GLANCE when both hands are empty' do
      _, launched, sent = reconcile(right: nil, left: nil)
      expect(launched).to be_empty
      expect(sent).to be_empty
    end

    it 'says so, leaving the finished piece in hand, when the bag will not take it' do
      reconcile(right: rope_piece, left: nil, after_sew: { right: rope }, put_ok: false)
      expect(DRCI).to have_received(:put_away_item?).with('#758800', 'duffel bag')
      expect(DRC).to have_received(:message).with('Your duffel bag would not take your finished coil of burlap reinforced rope, so it is still in your hands. Put it in your duffel bag for the turn-in.')
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'leaves the piece in hand, binning and bagging nothing, when GLANCE goes unanswered after sew' do
      _, launched, = reconcile(right: rope_piece, left: nil, after_sew: { right: rope_piece }, glance: [nil, ''])
      expect(launched).to eq([['sew', %w[resume rope]]])
      expect(DRCI).not_to have_received(:dispose_trash)
      expect(DRCI).not_to have_received(:put_away_item?)
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

      it 'leaves the expiry alone when out of credits, and asks no more in that login, not even from a new run' do
        tm = boosted(task_boosts: ['haste'])
        reply_with(no_credits)
        tm.refresh_haste
        expect([UserVars.taskmaster_haste_expires, $taskmaster_boost_unavailable]).to match([nil, { 'haste' => kind_of(Integer) }])

        # t2 starts a new run for the next task, in the same Lich process.
        [tm, boosted(task_boosts: ['haste'])].each(&:refresh_haste)
        expect(DRC).to have_received(:bput).with('boost haste', any_args).once
      end

      # Login rewards add boosts in the middle of a login, at the game's
      # daily rollover (Gorkus 2026-11-18: no credits at 05:56:48 UTC, "you
      # have earned 2 2-Hours of No TASK Cooldown boosts" at 06:00:43, BOOST
      # TASK activated at 06:04:35).
      describe 'after the daily rollover' do
        def at(text)
          Time.utc(*text.split(/[- :]/).map(&:to_i))
        end

        it 'asks again once 05:00 or 06:00 UTC has passed since the no-credits reply, and not before' do
          tm = boosted(task_boosts: ['haste'])
          [['2026-11-18 05:56:48', '2026-11-18 05:59:59', true], ['2026-11-18 05:56:48', '2026-11-18 06:04:35', false],
           ['2026-11-18 04:30:00', '2026-11-18 05:00:01', false], ['2026-11-18 07:00:00', '2026-11-19 04:59:59', true],
           ['2026-11-18 07:00:00', '2026-11-19 05:00:00', false], ['2026-11-18 23:30:00', '2026-11-19 05:30:00', false]].each do |noted, now, spent|
            $taskmaster_boost_unavailable = { 'haste' => at(noted).to_i }
            allow(Time).to receive(:now).and_return(at(now))
            expect([noted, now, tm.boost_spent?('haste')]).to eq([noted, now, spent])
          end
        end

        it "sends BOOST TASK again after the rollover and takes the reward's activation" do
          $taskmaster_boost_unavailable = { 'task' => at('2026-11-18 05:56:48').to_i }
          allow(Time).to receive(:now).and_return(at('2026-11-18 06:04:35'))
          tm = boosted(task_boosts: ['task'])
          expect(tm.instance_variable_get(:@boost)).to be(true)
          allow(DRC).to receive(:bput).with('boost task', any_args).and_return("You've activated the Task Master boost")
          expect(tm.boost_task).to be(true)
        end

        # A different method from the cases above: every note time over two
        # days (7-minute steps) against a set of later times, checked against
        # a minute-by-minute walk for a rollover time (05:00, 05:05, 06:00,
        # 06:05 UTC) in between.
        it 'lapses exactly when a rollover time lies after the note and by now, swept over two days' do
          tm = boosted(task_boosts: ['haste'])
          start = at('2026-11-18 00:00:00').to_i
          turns = [[5, 0], [5, 5], [6, 0], [6, 5]]
          oracle = lambda do |noted, now|
            minute = (noted / 60) + 1
            minute += 1 while minute * 60 <= now && !turns.include?([Time.at(minute * 60).utc.hour, Time.at(minute * 60).utc.min])
            minute * 60 > now
          end
          checked = 0
          (0...(2 * 1440)).step(7) do |offset|
            noted = start + (offset * 60) + 17
            [1, 3, 4, 5, 6, 30, 59, 60, 61, 64, 65, 66, 300, 1439, 1440, 1441].each do |later|
              now = noted + (later * 60)
              $taskmaster_boost_unavailable = { 'haste' => noted }
              allow(Time).to receive(:now).and_return(Time.at(now))
              expect([Time.at(noted).utc, Time.at(now).utc, tm.boost_spent?('haste')]).to eq([Time.at(noted).utc, Time.at(now).utc, oracle.call(noted, now)])
              checked += 1
            end
          end
          expect(checked).to eq(412 * 16)
        end

        # A reply in the minutes after the hour may predate the reward (they
        # come within two minutes of it): it lapses again at 05:05 or 06:05.
        it 'asks again at 06:05 after a no-credits reply at 06:00:20, before the reward came' do
          $taskmaster_boost_unavailable = { 'task' => at('2026-11-18 06:00:20').to_i }
          allow(Time).to receive(:now).and_return(at('2026-11-18 06:04:59'), at('2026-11-18 06:05:00'))
          tm = boosted(task_boosts: ['task'])
          expect([tm.boost_spent?('task'), tm.boost_spent?('task')]).to eq([true, false])
        end

        it 'asks again for a note left by an older taskmaster in the same process (true, no time)' do
          $taskmaster_boost_unavailable = { 'haste' => true }
          expect(boosted(task_boosts: ['haste']).boost_spent?('haste')).to be(false)
        end
      end

      it 'still asks for haste when only the task boost has run out' do
        $taskmaster_boost_unavailable = { 'task' => Time.now.to_i }
        tm = boosted(task_boosts: %w[task haste])
        reply_with(activated)
        tm.refresh_haste
        expect(DRC).to have_received(:bput).with('boost haste', any_args)
        # The run stays armed: whether the task boost is spent is asked at the
        # cooldown (get_task), where it is skipped while the note holds.
        expect([tm.instance_variable_get(:@boost), tm.boost_spent?('task')]).to eq([true, true])
        expect(DRC).not_to have_received(:bput).with('boost task', any_args)
      end

      it 'notes nothing for an activation, another answer or none, so the next hour asks again' do
        [activated, 'You already have an active Minor Haste boost.', ''].each do |reply|
          UserVars.taskmaster_haste_expires = nil
          reply_with(reply)
          boosted(task_boosts: ['haste']).refresh_haste
        end
        expect($taskmaster_boost_unavailable).to be_nil
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
        expect(DRC).to receive(:bput).with('boost haste', TaskMaster::HASTE_ACTIVATED, TaskMaster::HASTE_NO_CREDITS, TaskMaster::HASTE_OTHER).and_return(activated)
        tm.refresh_haste
      end

      # lich-5 DRC.bput (common.rb:272-276) returns the text of the first
      # pattern that matches the first line any pattern matches; this plays
      # the lines the game sends through the patterns refresh_haste gives.
      def bput_reading(*lines)
        allow(DRC).to receive(:bput) do |_command, *patterns|
          match = nil
          lines.find { |line| match = patterns.filter_map { |pattern| line[pattern] }.first }
          match || ''
        end
      end

      [
        ['the no-credit line', "Kvofe says, \"You don't have enough credits for the Minor Haste boost.\""],
        ['the boost by name', 'Kvofe whispers, "Is your Minor Haste boost running?"'],
        ['the no-credit line, as a thought', "Your mind hears Kvofe thinking, \"You don't have enough credits for the Minor Haste boost.\""]
      ].each do |what, chatter|
        it "takes the game's activation, not a player saying #{what} just before it" do
          tm = boosted(task_boosts: ['haste'])
          bput_reading(chatter, activated)
          tm.refresh_haste
          expect([UserVars.taskmaster_haste_expires, $taskmaster_boost_unavailable]).to match([be_within(5).of(Time.now.to_i + 3600), nil])
        end
      end

      it "still takes the game's own no-credit line, and an unknown reply naming the boost" do
        bput_reading(no_credits)
        boosted(task_boosts: ['haste']).refresh_haste
        expect($taskmaster_boost_unavailable).to match({ 'haste' => kind_of(Integer) })

        $taskmaster_boost_unavailable = nil
        bput_reading('You already have an active Minor Haste boost.')
        boosted(task_boosts: ['haste']).refresh_haste
        expect([UserVars.taskmaster_haste_expires, $taskmaster_boost_unavailable]).to match([be_within(5).of(Time.now.to_i + 600), nil])
      end

      it "takes BOOST TASK's activation, not a player saying the no-credit line just before it" do
        tm = boosted(task_boosts: ['task'])
        bput_reading("Kvofe says, \"You don't have enough credits for the Task Master boost.\"", "You've activated the Task Master boost for 2 hours!  Check INFO to see your time remaining.")
        expect(tm.boost_task).to be(true)
        expect($taskmaster_boost_unavailable).to be_nil

        bput_reading("You don't have enough credits for the Task Master boost.  You currently have 0 available but need 1.")
        expect(boosted(task_boosts: ['task']).boost_task).to be(false)
        expect($taskmaster_boost_unavailable).to match({ 'task' => kind_of(Integer) })
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

      # Saelia, 2026-11-18 09:58:20-23: go2 walked her through Upper Dock,
      # where Nezhiri stood, on the way to other rooms on the list. The stream
      # gives each room's title (subtitle) before its room objects.
      describe 'a taskmaster in a room walked through' do
        let(:titles) do
          { 16_145 => '[Andreshlew, Palace Road]', 16_146 => '[Andreshlew, West Dock]',
            16_148 => '[Andreshlew, East Dock]', 16_150 => '[Andreshlew, Upper Dock]',
            16_153 => '[Andreshlew, Dock Walk]', 16_154 => '[Andreshlew, Dock Walk]' }
        end

        def subtitle(title)
          %(<streamWindow id='room' title='Room' subtitle=" - #{title} (**)"/>)
        end

        def objs(*names)
          "<component id='room objs'>You also see #{names.join(', ')}.</component>"
        end

        # path: room => the rooms walked through on the way there (title, and
        # whether Nezhiri's link is in its room objects), fed to the hooks.
        def walk_world(nezhiri_in:, path: {}, start_in: 16_936)
          tm = build(npc: 'nezhiri')
          here = start_in
          walked = []
          map = titles
          # Map titles carry a second pair of brackets, as XMLData.room_title
          # does (lich-5 xml_delta.rb main_subtitle): "[[Andreshlew, Upper Dock]]".
          stub_const('Map', Class.new { define_singleton_method(:[]) { |id| map[id] && OpenStruct.new(title: ["[#{map[id]}]"]) } })
          allow(Room).to receive(:current) { OpenStruct.new(id: here) }
          allow(DRRoom).to receive(:npcs) { here == nezhiri_in ? ['Nezhiri'] : [] }
          allow(DRRoom).to receive(:room_objs) { [] }
          allow(DRCT).to receive(:walk_to) do |room|
            walked << room
            Array(path[room]).each do |id|
              DownstreamHook.run(subtitle(titles[id]))
              DownstreamHook.run(objs(id == nezhiri_in ? '<a exist="76006" noun="Nezhiri">Potion Peddler Nezhiri</a>' : 'a woven sack'))
            end
            DownstreamHook.run(subtitle(titles[room])) if titles[room]
            here = room
          end
          tm.find_npc(titles.keys, 'nezhiri')
          walked
        end

        it 'goes back to the room she was passed in, instead of searching on' do
          walked = walk_world(nezhiri_in: 16_150, path: { 16_145 => [16_148, 16_150] })

          expect(walked).to eq([16_145, 16_150])
          expect(UserVars.taskmaster_last_seen['nezhiri']).to eq(16_150)
        end

        it 'searches the list as before when she was not seen on the way' do
          walked = walk_world(nezhiri_in: 16_150, path: { 16_145 => [16_148] })

          expect(walked).to eq([16_145, 16_146, 16_148, 16_150])
        end

        it 'tries each listed room of the title she was seen under' do
          walked = walk_world(nezhiri_in: 16_154, path: { 16_145 => [16_154] })

          expect(walked).to eq([16_145, 16_153, 16_154])
        end

        def noting(*lines)
          tm = build(npc: 'nezhiri')
          allow(DRCT).to receive(:walk_to) { lines.each { |line| DownstreamHook.run(line) } }
          tm.walk_noting('nezhiri', 16_145)
        end

        it 'notes the title of the room whose objects name her' do
          expect(noting(subtitle('[Andreshlew, East Dock]'), objs('a woven sack'),
                        subtitle('[Andreshlew, Upper Dock]'), objs('<a exist="76006" noun="Nezhiri">Potion Peddler Nezhiri</a>'),
                        subtitle('[Andreshlew, Palace Road]'), objs('a woven sack'))).to eq('[[Andreshlew, Upper Dock]]')
        end

        it 'pairs her with her own room when one chunk carries several rooms' do
          chunk = [subtitle('[Andreshlew, Palace Road]'), objs('a woven sack'),
                   subtitle('[Andreshlew, Upper Dock]'), objs('<a exist="76006" noun="Nezhiri">Potion Peddler Nezhiri</a>')].join("\n")
          expect(noting(chunk)).to eq('[[Andreshlew, Upper Dock]]')
        end

        it 'does not take an item named for her for her' do
          expect(noting(subtitle('[Andreshlew, East Dock]'), objs("some Nezhiri's potion instructions"))).to be_nil
        end

        it 'stops watching the stream once the walk ends' do
          walk_world(nezhiri_in: 16_150, path: { 16_145 => [16_150] })

          expect(DownstreamHook.ordered_hook_names).not_to include(TaskMaster::FIND_NPC_HOOK)
        end
      end

      it 'remembers each taskmaster separately' do
        UserVars.taskmaster_last_seen = { 'poltu' => 16_290 }
        search(zasele_in: 16_146, start_in: 16_936)
        expect(UserVars.taskmaster_last_seen).to eq('poltu' => 16_290, 'zasele' => 16_146)
      end
    end

    # In a cluttered room the game cuts its room objects data short ("... and
    # some other stuff."), and Lich builds DRRoom from that data alone, so a
    # taskmaster listed after the cut is not in DRRoom.npcs. Zasele on a
    # littered Lithralia Street, 2026-11-07 (cite 6300, see
    # spec/fixtures/taskmaster/log_lines.json). DRRoom holds what lich-5 makes
    # of each logged room objs component (spec/fixtures/taskmaster/drroom.json);
    # the game answers LOOK with logged lines.
    describe 'a taskmaster listed after the cut in a cluttered room' do
      let(:drroom) { JSON.parse(File.read(File.expand_path('fixtures/taskmaster/drroom.json', __dir__))) }
      # Her room on arrival at 17:40:40: the data ends "and some other stuff."
      # and leaves her out.
      let(:cut_short) { drroom.fetch('6300:19') }
      # Her room at 17:44:09, the ground partly cleared: she is in DRRoom.npcs.
      let(:cleared) { drroom.fetch('6300:134') }
      # The next room east, not cut short, no taskmaster.
      let(:neighbour) { drroom.fetch('6300:96') }
      # The room as LOOK shows it, with room descriptions on (17:44:07:
      # description and listing on one line) and off (the 17:40:40 layout).
      let(:described_look) { %w[6300:63 6300:64 6300:65 6300:66].map { |cite| ReplayGame.log(cite) } }
      let(:brief_look) { %w[6300:23 6300:24 6300:25 6300:26].map { |cite| ReplayGame.log(cite) } }
      # Installed before each example, so a LOOK nobody scripted is still
      # answered (with silence) and recorded in game.sent.
      let!(:game) { ReplayGame.new.install(self) }
      let(:events) { [] }

      # The listing line as the game would send it, without Zasele.
      def listing_without_her
        ReplayGame.code(ReplayGame.log('6300:24').text.sub(%r{<pushBold/><pushBold/><a exist="76029" noun="Zasele">Seamstress Zasele</a><popBold/><popBold/>, }, ''),
                        from: '6300:24 with Seamstress Zasele taken out')
      end

      # Puts the character in a room showing `data`, as DRRoom would.
      def in_room(data)
        allow(DRRoom).to receive(:npcs) { data['npcs'] }
        allow(DRRoom).to receive(:room_objs) { data['room_objs'] }
      end

      # A small world: each room shows its own DRRoom (the neighbour's unless
      # given), walking changes the room. Walks and commands go to `events`
      # in the order they happen.
      # With moves: false every walk fails and the character stays put.
      # stream: room => lines the walk there sends through the downstream
      # hooks (walk_noting's), as the game streams each room passed.
      def search(room_data:, start_in:, moves: true, stream: {})
        tm = build
        here = start_in
        allow(Room).to receive(:current) { OpenStruct.new(id: here) }
        allow(DRRoom).to receive(:npcs) { room_data.fetch(here, neighbour)['npcs'] }
        allow(DRRoom).to receive(:room_objs) { room_data.fetch(here, neighbour)['room_objs'] }
        allow(DRCT).to receive(:walk_to) do |room|
          events << [:walk, room]
          here = room if moves
          Array(stream[room]).each { |line| DownstreamHook.run(line) }
        end
        allow(DRC).to receive(:bput) do |*args|
          events << [:send, args.first, here]
          game.bput(*args)
        end
        tm.find_npc(rooms, 'zasele')
      end

      { 'described' => :described_look, 'brief' => :brief_look }.each do |layout, look|
        it "stops in her room and remembers it when LOOK (#{layout}) lists her after the cut" do
          game.script('look', *send(look))
          search(room_data: { 16_148 => cut_short }, start_in: 16_936)
          expect(events).to eq([[:walk, 16_145], [:walk, 16_146], [:walk, 16_148], [:send, 'look', 16_148]])
          expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_148)
        end
      end

      # mrhoribu on #8116: the walk there saw her in the room's objects, then a
      # cut-short refresh (#7993) left her out of DRRoom. The LOOK that finds
      # her ends the search; a second check of the room would not LOOK again
      # and would walk on past her.
      it 'stops at the LOOK that finds her when the walk there also saw her' do
        game.script('look', *described_look)
        search(room_data: { 16_148 => cut_short }, start_in: 16_936,
               stream: { 16_148 => [%(<streamWindow id='room' title='Room' subtitle=" - [Lithralia Street] (**)"/>),
                                    %(<component id='room objs'>You also see <a exist="76029" noun="Zasele">Seamstress Zasele</a>.</component>)] })
        expect(events).to eq([[:walk, 16_145], [:walk, 16_146], [:walk, 16_148], [:send, 'look', 16_148]])
        expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_148)
      end

      it 'sends nothing extra when DRRoom lists her (as it will once Lich reads the full listing)' do
        search(room_data: { 16_148 => cleared }, start_in: 16_936)
        expect(events).to eq([[:walk, 16_145], [:walk, 16_146], [:walk, 16_148]])
        expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_148)
      end

      it 'never looks when no room was cut short, even when she is nowhere' do
        search(room_data: {}, start_in: 16_936)
        expect(events.map(&:first).uniq).to eq([:walk])
        expect(events.size).to eq(rooms.size)
        expect(UserVars.taskmaster_last_seen).to eq({})
      end

      it 'walks on from a cut-short room whose LOOK does not list her, looking there only once' do
        game.script('look', ReplayGame.log('6300:23'), listing_without_her, ReplayGame.log('6300:25'), ReplayGame.log('6300:26'))
        search(room_data: { 16_146 => cut_short, 16_150 => cleared }, start_in: 16_936)
        expect(events).to eq([[:walk, 16_145], [:walk, 16_146], [:send, 'look', 16_146], [:walk, 16_148], [:walk, 16_150]])
        expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_150)
      end

      it 'looks once, not twice, when she is in the last room on the list' do
        game.script('look', *described_look)
        search(room_data: { rooms.last => cut_short }, start_in: 16_936)
        expect(events.count { |event| event.first == :send }).to eq(1)
        expect(events.last).to eq([:send, 'look', rooms.last])
        expect(UserVars.taskmaster_last_seen['zasele']).to eq(rooms.last)
      end

      it 'looks once and walks nowhere when she is in the room it starts in' do
        game.script('look', *described_look)
        search(room_data: { 16_276 => cut_short }, start_in: 16_276)
        expect(events).to eq([[:send, 'look', 16_276]])
        expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_276)
      end

      it 'keeps the old last-seen room when LOOK in every cut-short room leaves her out' do
        UserVars.taskmaster_last_seen = { 'zasele' => 16_150 }
        2.times { game.script('look', ReplayGame.log('6300:23'), listing_without_her, ReplayGame.log('6300:25'), ReplayGame.log('6300:26')) }
        search(room_data: { 16_150 => cut_short, 16_153 => cut_short }, start_in: 16_936)
        expect(events.select { |event| event.first == :send }).to eq([[:send, 'look', 16_150], [:send, 'look', 16_153]])
        expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_150)
      end

      # search_order puts the last-seen room first, so a search that starts
      # there checks it, "walks" to it (staying put) and checks it again.
      # give_item, get_task and the rest search again from where she was
      # last found, so this is the usual start.
      it 'looks only once in the last-seen room it starts in when she has wandered off' do
        UserVars.taskmaster_last_seen = { 'zasele' => 16_276 }
        game.script('look', ReplayGame.log('6300:23'), listing_without_her, ReplayGame.log('6300:25'), ReplayGame.log('6300:26'))
        search(room_data: { 16_276 => cut_short, 16_277 => cleared }, start_in: 16_276)
        expect(events).to eq([[:send, 'look', 16_276], [:walk, 16_276], [:walk, 16_277]])
        expect(game.sent).to eq(['look'])
        expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_277)
      end

      it 'looks only once in a cut-short room when every walk fails to leave it' do
        game.script('look', ReplayGame.log('6300:23'), listing_without_her, ReplayGame.log('6300:25'), ReplayGame.log('6300:26'))
        search(room_data: { 16_936 => cut_short }, start_in: 16_936, moves: false)
        expect(events.count { |event| event.first == :walk }).to eq(rooms.size)
        expect(events.select { |event| event.first == :send }).to eq([[:send, 'look', 16_936]])
        expect(UserVars.taskmaster_last_seen).to eq({})
      end

      it 'still reads DRRoom again in a room it has looked in, so she is found if she walks in' do
        UserVars.taskmaster_last_seen = { 'zasele' => 16_276 }
        game.script('look', ReplayGame.log('6300:23'), listing_without_her, ReplayGame.log('6300:25'), ReplayGame.log('6300:26'))
        checks = 0
        tm = build
        allow(Room).to receive(:current) { OpenStruct.new(id: 16_276) }
        # Cut short and without her for the first check; she has arrived by the second.
        allow(DRRoom).to receive(:npcs) { (checks += 1) > 1 ? ['Zasele'] : [] }
        allow(DRRoom).to receive(:room_objs) { cut_short['room_objs'] }
        allow(DRCT).to receive(:walk_to) { |room| events << [:walk, room] }
        tm.find_npc(rooms, 'zasele')
        expect(events).to eq([[:walk, 16_276]])
        expect(game.sent).to eq(['look'])
        expect(UserVars.taskmaster_last_seen['zasele']).to eq(16_276)
      end

      describe '#npc_here?' do
        it 'sees the cut in "and a lot of other stuff." too, the wording of a cut-short container listing' do
          in_room('npcs' => [], 'room_objs' => cut_short['room_objs'][0..-2] + ['lot of other stuff'])
          game.script('look', *described_look)
          expect(build.npc_here?('zasele')).to be(true)
          expect(game.sent).to eq(['look'])
        end

        it 'sees the cut when nothing but the marker is left ("You also see some other stuff.")' do
          in_room('npcs' => [], 'room_objs' => ['other stuff'])
          game.script('look', *brief_look)
          expect(build.npc_here?('zasele')).to be(true)
        end

        {
          'an empty room'                             => [],
          'a last object that only ends in the words' => ['woven sack', 'box of other stuff'],
          'a last object that only starts with them'  => ['woven sack', 'other stuff pile'],
          'the words on an object before the last'    => ['other stuff', 'woven sack'],
          'the marker in other case'                  => ['woven sack', 'Other Stuff']
        }.each do |case_name, room_objs|
          it "does not look for #{case_name}" do
            in_room('npcs' => [], 'room_objs' => room_objs)
            expect(build.npc_here?('zasele')).to be(false)
            expect(game.sent).to eq([])
          end
        end

        it 'does not look for her when DRRoom lists her, even though the data was cut short' do
          in_room('npcs' => ['Zasele'], 'room_objs' => cut_short['room_objs'])
          expect(build.npc_here?('zasele')).to be(true)
          expect(game.sent).to eq([])
        end

        it 'still looks when DRRoom lists another taskmaster but not her' do
          in_room('npcs' => ['Poltu'], 'room_objs' => cut_short['room_objs'])
          game.script('look', *described_look)
          expect(build.npc_here?('zasele')).to be(true)
        end

        it 'stops at the exits line, without waiting out a timeout, when LOOK lists nothing' do
          in_room(cut_short)
          game.script('look', ReplayGame.log('6300:23'), ReplayGame.log('6300:25'), ReplayGame.log('6300:26'))
          expect(build.npc_here?('zasele')).to be(false)
          expect(game.clock).to eq(0.0)
        end

        it 'says no, without raising, when LOOK gets no reply' do
          in_room(cut_short)
          game.script('look')
          expect(build.npc_here?('zasele')).to be(false)
          expect(game.clock).to eq(15.0)
        end

        it 'reads the listing, not the room description before it on the same line' do
          in_room(cut_short)
          described = ReplayGame.log('6300:64').text
          desc, listing = described.split('  You also see', 2)
          game.script('look', ReplayGame.code("#{desc} A statue of Seamstress Zasele stands nearby.  You also see a woven sack.",
                                              from: "6300:64's description with Zasele named in it, and a listing without her"))
          expect(listing).to include('Seamstress Zasele') # the logged line does list her
          expect(build.npc_here?('zasele')).to be(false)
        end

        {
          "an item named for her (Zasele's)" => "  You also see a woven sack, Zasele's woven sack and some wool yarn.",
          'a hyphenated item (Zasele-)'      => '  You also see a Zasele-stamped sack.',
          'a longer name'                    => '  You also see Seamstress Zaseleth and a woven sack.',
          'her name in lower case'           => '  You also see a zasele doll.',
          'another taskmaster'               => '  You also see Blacksmith Poltu and a woven sack.',
          'a name with her name at its end'  => '  You also see a FauxZasele puppet and a woven sack.'
        }.each do |case_name, listing|
          it "does not take #{case_name} in the listing for her" do
            in_room(cut_short)
            game.script('look', ReplayGame.code(listing, from: 'listing shaped like 6300:24'), ReplayGame.log('6300:26'))
            expect(build.npc_here?('zasele')).to be(false)
          end
        end

        # Anyone in the room can say the words; between the LOOK and its
        # listing their line must not be taken for the listing. The game
        # quotes what players say, whisper and think.
        {
          'says'     => 'Bovi says, "You also see Seamstress Zasele."',
          'asks'     => 'Bovi asks, "Hello.  You also see Seamstress Zasele?"',
          'whispers' => 'Bovi whispers, "You also see Seamstress Zasele."',
          'thinks'   => '[General][Bovi] "You also see Seamstress Zasele."'
        }.each do |verb, spoken|
          it "is not fooled by a player who #{verb} \"You also see ... Zasele\" before the listing" do
            in_room(cut_short)
            game.script('look', ReplayGame.code(spoken, from: 'speech in the shape of a player line, quoting 6300:24'),
                        ReplayGame.log('6300:23'), listing_without_her, ReplayGame.log('6300:25'), ReplayGame.log('6300:26'))
            expect(build.npc_here?('zasele')).to be(false)
          end
        end

        it 'does not take the words in the middle of another line for the listing' do
          in_room(cut_short)
          game.script('look', ReplayGame.code('A sign here reads You also see Seamstress Zasele.', from: 'a line quoting 6300:24 mid-sentence'),
                      ReplayGame.log('6300:23'), listing_without_her, ReplayGame.log('6300:25'), ReplayGame.log('6300:26'))
          expect(build.npc_here?('zasele')).to be(false)
        end

        it 'still finds her in the listing that follows a player quoting the words' do
          in_room(cut_short)
          game.script('look', ReplayGame.code('Bovi says, "You also see a woven sack."', from: 'speech in the shape of a player line, quoting 6300:24'),
                      *described_look)
          expect(build.npc_here?('zasele')).to be(true)
        end

        it 'finds her named last in the listing, before the full stop' do
          in_room(cut_short)
          game.script('look', ReplayGame.code('  You also see a woven sack and Seamstress Zasele.', from: 'listing shaped like 6300:24'))
          expect(build.npc_here?('zasele')).to be(true)
        end
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

      # A player's report, 2026-11-18: Nezhiri's speech, then this line.
      describe 'a taskmaster\'s daily limit (task_fallback_npc)' do
        let(:daily_max) { '[You have reached the maximum number of TASKs you may complete for Nezhiri today.  Please try again tomorrow.]' }
        let(:offer) { 'You may accept by typing ACCEPT TASK.' }

        # Asks with per-taskmaster replies; records each ask by taskmaster.
        # Each reply is the game's lines for one ask (one line, or several):
        # the ask returns what DRC.bput would, the first line a matcher takes
        # (bput_match), and '' when none does.
        def limited(replies, npc: 'nezhiri', fallback: 'zasele', marathon: false)
          tm = reader(npc: npc, fallback_npc: fallback.to_s, cooldown_poll: 7, marathon: marathon)
          events = []
          allow(tm).to receive(:find_npc) { |_rooms, who| events << [:find, who] }
          allow(tm).to receive(:pause) { |seconds| events << [:pause, seconds] }
          allow(tm).to receive(:finish) { events << :finish && :accepted }
          allow(DRC).to receive(:message) { |text| events << [:message, text] }
          asks = replies.keys.to_h do |who|
            ["ask #{who} for task", lambda do |_command, *matchers|
              events << [:ask, who]
              raise "asked #{who} again after the last reply" if replies[who].empty?

              Array(replies[who].shift).map { |line| bput_match(line, matchers) }.find { |reply| !reply.empty? }.to_s
            end]
          end
          game(asks.merge('accept task' => 'You can check your progress with the TASK verb.'))
          [tm, events]
        end

        it 'works a task for the fallback taskmaster when the first has hit its daily limit' do
          tm, events = limited({ 'nezhiri' => [daily_max], 'zasele' => [offer] })

          expect(tm.get_task).to eq(:accepted)
          expect(events).to eq([[:find, 'nezhiri'], [:ask, 'nezhiri'],
                                [:message, "Nezhiri has given you all the tasks allowed today; working one of Zasele's instead (the next run asks Nezhiri again)."],
                                [:find, 'zasele'], [:ask, 'zasele'], :finish])
          expect(tm.instance_variable_get(:@npc)).to eq('zasele')
          expect(tm.instance_variable_get(:@primary_npc)).to eq('nezhiri')
        end

        # The limit line is the game's, never quoted; a player saying it in
        # the room ('Mags says, "[You have reached ...]"') is speech.
        it 'reads on past a player saying the limit line, to the answer the taskmaster gives, and notes no limit' do
          spoken = %(Mags says, "#{daily_max}")
          tm, events = limited({ 'nezhiri' => [[spoken, offer]] })

          expect(tm.get_task).to eq(:accepted)
          expect(events).to eq([[:find, 'nezhiri'], [:ask, 'nezhiri'], :finish])
          expect(UserVars.taskmaster_capped).to be_nil
          expect(tm.instance_variable_get(:@npc)).to eq('nezhiri')
        end

        # Logged lines start with the bracket, but the match is deliberately
        # not anchored on it: a line without it, or with unquoted text joined
        # in front, is still the game's limit, not an unknown reply (three of
        # which would stop the run instead of falling back).
        it 'takes the limit line without its leading bracket, or with unquoted text joined in front, and falls back' do
          joined = "Nezhiri shakes her head.  #{daily_max.delete_prefix('[')}"
          tm, events = limited({ 'nezhiri' => [joined], 'zasele' => [offer] })

          expect(tm.get_task).to eq(:accepted)
          expect(events.grep(Array).select { |event| event.first == :ask }).to eq([[:ask, 'nezhiri'], [:ask, 'zasele']])
          expect(UserVars.taskmaster_capped).to include('nezhiri')
          expect(tm.instance_variable_get(:@primary_npc)).to eq('nezhiri')
        end

        # The deliberate other side of the quote rule: the taskmaster's own
        # speech joined to the limit on one line is rejected like a player
        # saying it (never seen: every logged limit line is a line of its
        # own). Matching the bracketed text wherever it falls would take a
        # player's '[You have reached ...' again.
        it "does not take the taskmaster's quoted speech joined in front of the limit line: no answer, asked again, no limit noted" do
          joined = %(Potion Peddler Nezhiri says, "I am still working on packaging what you gave me."  #{daily_max})
          tm, events = limited({ 'nezhiri' => [joined, offer] })

          expect(tm.get_task).to eq(:accepted)
          expect(events).to eq([[:find, 'nezhiri'], [:ask, 'nezhiri'], [:pause, 7], [:find, 'nezhiri'], [:ask, 'nezhiri'], :finish])
          expect(UserVars.taskmaster_capped).to be_nil
        end

        it "does not take a limit line naming another taskmaster as the one asked's: it asks again and notes no limit" do
          tm, events = limited({ 'nezhiri' => [daily_max.sub('Nezhiri', 'Zasele'), offer] })

          expect(tm.get_task).to eq(:accepted)
          expect(events).to eq([[:find, 'nezhiri'], [:ask, 'nezhiri'], [:pause, 7], [:find, 'nezhiri'], [:ask, 'nezhiri'], :finish])
          expect(UserVars.taskmaster_capped).to be_nil
          expect(tm.instance_variable_get(:@npc)).to eq('nezhiri')
        end

        it 'counts such a line as no answer, so the asks stop after MAX_UNKNOWN_TASK_REPLIES of them' do
          tm, events = limited({ 'nezhiri' => [daily_max.sub('Nezhiri', 'Zasele')] * 3 })

          expect { tm.get_task }.to raise_error(SystemExit)
          expect(events.last).to eq([:message, 'No answer Nezhiri gives that taskmaster knows, 3 times in a row. Stopping.'])
          expect(UserVars.taskmaster_capped).to be_nil
        end

        it 'stops, naming the setting, when no fallback is set' do
          tm, events = limited({ 'nezhiri' => [daily_max] }, fallback: nil)

          expect { tm.get_task }.to raise_error(SystemExit)
          expect(events.last).to eq([:message, 'Nezhiri has given you all the tasks allowed today. Set task_fallback_npc to work another taskmaster\'s tasks meanwhile. Stopping.'])
        end

        it 'stops when the fallback taskmaster has hit its limit too, without asking anyone a third time' do
          zasele_max = daily_max.sub('Nezhiri', 'Zasele')
          tm, events = limited({ 'nezhiri' => [daily_max], 'zasele' => [zasele_max] })

          expect { tm.get_task }.to raise_error(SystemExit)
          expect(events.count { |e| e.is_a?(Array) && e.first == :ask }).to eq(2)
          expect(events.last).to eq([:message, 'Zasele has given you all the tasks allowed today. No other taskmaster to ask. Stopping.'])
        end

        # A set fallback whose limit an earlier run noted this game day is
        # not asked (fallback_capped?), and the stop names it rather than
        # saying there is no other taskmaster.
        it 'stops, naming the fallback, when its limit was noted earlier this game day, without walking to it' do
          allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 20, 12))
          UserVars.taskmaster_capped = { 'zasele' => Time.utc(2026, 11, 20, 11).to_i }
          # No 'zasele' replies: a walk to her shows as [:find, 'zasele'], her asks go unanswered.
          tm, events = limited({ 'nezhiri' => [daily_max] })

          expect { tm.get_task }.to raise_error(SystemExit)
          expect(events).not_to include([:find, 'zasele'])
          expect(events.last).to eq([:message, 'Nezhiri has given you all the tasks allowed today, and so did Zasele (task_fallback_npc) earlier this game day (the limit resets at midnight US Central). Stopping.'])
        end

        it 'does not fall back to the taskmaster it was asking' do
          tm, = limited({ 'zasele' => [daily_max.sub('Nezhiri', 'Zasele')] }, npc: 'zasele', fallback: 'zasele')

          expect { tm.get_task }.to raise_error(SystemExit)
        end

        it 'ignores a fallback that is not a taskmaster this script does' do
          tm, = limited({ 'nezhiri' => [daily_max] }, fallback: 'mags')

          expect { tm.get_task }.to raise_error(SystemExit)
        end

        # Review 5944553147 (mrhoribu): marathon tailors every task it gets
        # (marathon_tailor), so it must never take another taskmaster's.
        it 'never falls back in marathon, which works only Zasele\'s tasks' do
          zasele_max = daily_max.sub('Nezhiri', 'Zasele')
          tm, events = limited({ 'zasele' => [zasele_max] }, npc: 'zasele', fallback: 'nezhiri', marathon: true)

          expect { tm.get_task }.to raise_error(SystemExit)
          expect(events.select { |e| e.is_a?(Array) && e.first == :ask }).to eq([[:ask, 'zasele']])
          expect(tm.instance_variable_get(:@npc)).to eq('zasele')
        end

        it 'keeps polling the ordinary cooldown instead of falling back' do
          wait = 'Potion Peddler Nezhiri says, "I am sorry, you must wait before I can give you a task."'
          tm, events = limited({ 'nezhiri' => [wait, wait, offer] })
          allow(tm).to receive(:nezhiri_wait_chores) { events << :chores }

          expect(tm.get_task).to eq(:accepted)
          expect(events).to eq([[:find, 'nezhiri'], [:ask, 'nezhiri'], :chores, [:find, 'nezhiri'], [:ask, 'nezhiri'], [:pause, 7],
                                [:find, 'nezhiri'], [:ask, 'nezhiri'], :finish])
          expect(tm.instance_variable_get(:@npc)).to eq('nezhiri')
        end

        it "forgets what Nezhiri's wait found when it falls back, so the fallback's task is not worked from it" do
          wait = 'Potion Peddler Nezhiri says, "I am sorry, you must wait before I can give you a task."'
          tm, events = limited({ 'nezhiri' => [wait, daily_max], 'zasele' => [offer] })
          allow(tm).to receive(:nezhiri_wait_chores) do
            events << :chores
            tm.instance_variable_set(:@stock_survey, { copper: 50_000, missing_tools: [] })
          end
          allow(tm).to receive(:finish) { events << [:finish, tm.instance_variable_get(:@stock_survey)] && :accepted }

          expect(tm.get_task).to eq(:accepted)
          expect(events.values_at(2, -3, -2, -1)).to eq([:chores, [:find, 'zasele'], [:ask, 'zasele'], [:finish, nil]])
          expect(tm.instance_variable_get(:@npc)).to eq('zasele')
        end

        it 'goes back to the first taskmaster after the fallback task' do
          tm = build(npc: 'zasele', primary_npc: 'nezhiri')

          tm.back_to_primary_npc

          expect([tm.instance_variable_get(:@npc), tm.instance_variable_get(:@primary_npc)]).to eq(['nezhiri', nil])
        end

        it 'leaves the taskmaster alone after a task with no fallback' do
          tm = build(npc: 'nezhiri')

          tm.back_to_primary_npc

          expect(tm.instance_variable_get(:@npc)).to eq('nezhiri')
        end

        it 'asks the first taskmaster again for the task after a fallback task (repeat)' do
          tm = build(npc: 'nezhiri', fallback_npc: 'zasele')
          %i[reconcile_hands prepare_for_task complete_task zasele].each { |name| allow(tm).to receive(name) }
          allow(DRCI).to receive(:exists?).and_return(false)
          asked = []
          allow(tm).to receive(:get_task) do
            asked << tm.instance_variable_get(:@npc)
            if asked.size == 1
              # fall_back_for_the_day's switch, then Zasele's task.
              tm.instance_variable_set(:@primary_npc, 'nezhiri')
              tm.instance_variable_set(:@npc, 'zasele')
              ['rope', 5, 4, 'cloth', 'burlap']
            else
              Flags['wrap-up'] = true
              nil
            end
          end

          tm.run_tasks(OpenStruct.new(repeat: true))

          expect(asked).to eq(%w[nezhiri nezhiri])
          expect(tm).to have_received(:zasele).with('rope', 5, 4, 'cloth', 'burlap')
        end

        describe 'an open task for the fallback taskmaster' do
          it 'is finished as this run\'s own, not cancelled' do
            tm = build(npc: 'nezhiri', fallback_npc: 'zasele', task_giver: 'zasele', cancel_foreign_tasks: true)
            allow(DRC).to receive(:message)
            allow(tm).to receive(:cancel_foreign_task)

            tm.check_task_giver

            expect(tm).not_to have_received(:cancel_foreign_task)
            expect([tm.instance_variable_get(:@npc), tm.instance_variable_get(:@primary_npc)]).to eq(%w[zasele nezhiri])
            expect(DRC).to have_received(:message).with('You are on a task for Zasele, the fallback taskmaster; finishing it.')
          end

          it "in a cycle run, when a cycled taskmaster's task turns up while asking the fallback, leaves nothing to go back to" do
            tm = build(npc: 'nezhiri', primary_npc: 'poltu', cycle: true, fallback_npc: 'nezhiri', task_giver: 'bradyn')
            allow(DRC).to receive(:message)

            tm.check_task_giver

            expect([tm.instance_variable_get(:@npc), tm.instance_variable_get(:@primary_npc)]).to eq(['bradyn', nil])
            expect(DRC).to have_received(:message).with('You are on a task for Bradyn, one of the taskmasters cycle works; finishing it.')
          end

          it 'stays foreign in marathon, which would tailor it' do
            tm = build(npc: 'zasele', fallback_npc: 'nezhiri', task_giver: 'nezhiri', cancel_foreign_tasks: false, marathon: true)
            allow(DRC).to receive(:message)

            expect { tm.check_task_giver }.to raise_error(SystemExit)
            expect(tm.instance_variable_get(:@npc)).to eq('zasele')
          end

          it 'still counts as foreign when it is some other taskmaster\'s' do
            tm = build(npc: 'nezhiri', fallback_npc: 'zasele', task_giver: 'dorhum', cancel_foreign_tasks: false)
            allow(DRC).to receive(:message)

            expect { tm.check_task_giver }.to raise_error(SystemExit)
            expect(tm.instance_variable_get(:@npc)).to eq('nezhiri')
          end
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

        # BOOST TASK's replies: the start of the activation line task-forage.lic
        # reads (the rest of it is not in the logs at hand), and the no-credits
        # line (Holdigor 2026-11-18 15:26:47).
        let(:boosted) { "You've activated the Task Master boost" }
        let(:no_boosts) { "You don't have enough credits for the Task Master boost.  You currently have 0 available but need 1." }

        # Plays the replies in order (each through the ask's matchers, as DRC.bput
        # would) and records each search, ask, pause and
        # command, BOOST TASK answered with boost_reply. Accepting returns
        # finish's (stubbed) result; an ongoing task calls the stubbed
        # resume_task, and get_task then returns nil. Returns get_task's
        # result, the steps and the instance.
        def asking(replies, boost: false, boost_reply: boosted, npc: 'zasele', **get_task_args)
          tm = reader(boost: boost, cooldown_poll: 7, npc: npc)
          events = []
          allow(tm).to receive(:find_npc) { events << :find }
          allow(tm).to receive(:pause) { |seconds| events << [:pause, seconds] }
          allow(tm).to receive(:fput) { |command| events << [:fput, command] }
          allow(tm).to receive(:nezhiri_wait_chores) { events << :chores }
          allow(tm).to receive(:finish) do
            events << :finish
            :accepted
          end
          allow(tm).to receive(:resume_task) do
            events << :resume
            :resumed
          end
          allow(DRC).to receive(:message) { |text| events << [:message, text] }
          ask = lambda do |_command, *matchers|
            events << :ask
            # A loop that asks past the last reply fails here instead of
            # hanging the suite.
            raise 'asked again after the last reply' if replies.empty?

            # What DRC.bput returns: '' for a line no matcher takes.
            bput_match(replies.shift, matchers)
          end
          accept = lambda do |*|
            events << :accept
            'You can check your progress with the TASK verb.'
          end
          boost_task = lambda do |*|
            events << :boost
            boost_reply
          end
          game("ask #{npc} for task" => ask, 'accept task' => accept, 'boost task' => boost_task)
          yield tm if block_given?
          [tm.get_task(**get_task_args), events, tm]
        end

        let(:accepted) { %i[find ask accept finish] }
        let(:cooldown_message) { [:message, 'Task on cooldown or recently canceled a task, either way, going to have to wait.'] }

        it 'asks with the same matchers' do
          asking([offer])
          expect(DRC).to have_received(:bput).with('ask zasele for task', /if you agree to (his|her) terms/, /You may accept by typing ACCEPT TASK/, /utterly ignoring you/,
                                                   /you must wait before I can give you a task/, /You are already on a task/, /give you a chance a little later/,
                                                   TaskMaster::TASK_UNRELIABLE, TaskMaster::TASK_BUSY, TaskMaster::TASK_DAILY_MAX, /^To whom are you speaking/)
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
          expect([result, events]).to eq([:accepted, [:find, :ask, :boost, [:pause, 2], *accepted]])
          expect(tm.instance_variable_get(:@boost)).to be(false)
        end

        it 'waits the poll interval on a second cooldown instead of boosting again' do
          expect(asking([wait, wait, offer], boost: true)[1]).to eq([:find, :ask, :boost, [:pause, 2], :find, :ask, [:pause, 7], *accepted])
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

        it 'resumes the task already in progress, ending the script there by default' do
          result, events, tm = asking([on_task])
          expect([result, events]).to eq([nil, %i[find ask resume]])
          expect(tm).to have_received(:resume_task).with(exit_when_done: true)
        end

        it 'resumes after waiting out a cooldown' do
          expect(asking([wait, on_task]).first(2)).to eq([nil, [:find, :ask, [:pause, 7], :find, :ask, :resume]])
        end

        it 'returns nil, never what resuming returns, once the task in progress is handed in for a run that goes on' do
          result, events, tm = asking([on_task], exit_after_resume: false) do |run|
            # A value resuming might leak, which must not reach the worker.
            allow(run).to receive(:resume_task).and_return(['rope', 2, 4, 'cloth', 'burlap'])
          end
          expect([result, events]).to eq([nil, %i[find ask]])
          expect(tm).to have_received(:resume_task).with(exit_when_done: false).once
        end

        it 'mixes replies in any order, asking until there is an offer' do
          expect(asking([terms, ignored, wait, nobody, offer], boost: true)[1])
            .to eq([:find, :ask, :find, :ask, cooldown_message, [:pause, 7], :find, :ask, :boost, [:pause, 2], :find, :ask, *accepted])
        end

        # Nezhiri turning everyone away for about ten minutes (Byd and Nelis,
        # 2026-11-28 00:14-00:24; Berimeg and Evro, 2026-11-20 20:07-20:16).
        # Before TASK_BUSY it was an unknown reply: three in a row stopped
        # the run, and t2 started it again a minute later, all stretch long.
        describe 'a taskmaster saying it is busy' do
          let(:busy) { %(Potion Peddler Nezhiri shoots you a chilly glance.  "I'm a bit busy just now.  Come back later.") }
          let(:busy_message) { [:message, 'Nezhiri is too busy to give out tasks just now; asking again every 15 seconds until that lifts.'] }
          let(:busy_ask) { [:find, :ask, [:pause, 15]] }

          it 'is matched by the ask, with or without the apostrophe the line carries' do
            expect(bput_match(busy, [TaskMaster::TASK_BUSY])).to eq('a bit busy just now')
            expect(busy.sub("I'm", 'I am')).to match(TaskMaster::TASK_BUSY)
          end

          it 'waits TASK_BUSY_POLL seconds and asks again, saying so once, then accepts the offer that follows' do
            result, events, = asking([busy, busy, busy, offer], npc: 'nezhiri')
            expect([result, events]).to eq([:accepted, [:find, :ask, busy_message, [:pause, 15], *busy_ask, *busy_ask, *accepted]])
          end

          it 'never stops the run however long it lasts (more than MAX_UNKNOWN_TASK_REPLIES in a row)' do
            result, events, = asking([*Array.new(40, busy), offer], npc: 'nezhiri')
            expect(result).to eq(:accepted)
            expect(events.count { |event| event == [:pause, 15] }).to eq(40)
            expect(events.count { |event| event.is_a?(Array) && event.first == :message }).to eq(1)
          end

          it 'waits the poll interval instead when task_cooldown_poll is longer' do
            _, events, = asking([busy, offer], npc: 'nezhiri') { |run| run.instance_variable_set(:@cooldown_poll, 30) }
            expect(events).to eq([:find, :ask, [:message, 'Nezhiri is too busy to give out tasks just now; asking again every 30 seconds until that lifts.'], [:pause, 30], *accepted])
          end

          it 'says so again for a new busy stretch after another reply' do
            _, events, = asking([busy, wait, busy, offer], npc: 'nezhiri')
            expect(events.count(busy_message)).to eq(2)
          end

          it 'counts as an answer: unknown replies either side of it are not three in a row' do
            result, events, = asking(['', '', busy, '', '', offer], npc: 'nezhiri')
            expect(result).to eq(:accepted)
            expect(events).not_to include(:chores)
          end
        end

        describe 'with no credits for the task boost' do
          it 'notes it for the login and waits the poll interval at once, rather than asking again in two seconds' do
            result, events, tm = asking([wait, offer], boost: true, boost_reply: no_boosts)

            expect([result, events]).to eq([:accepted, [:find, :ask, :boost, [:pause, 7], *accepted]])
            expect([tm.instance_variable_get(:@boost), $taskmaster_boost_unavailable]).to match([false, { 'task' => kind_of(Integer) }])
          end

          it 'sends no BOOST TASK in a later run of the same login, whose settings ask for it' do
            asking([wait, offer], boost: true, boost_reply: no_boosts)

            _, events, = asking([wait, offer]) do |run|
              run.instance_variable_set(:@settings, OpenStruct.new(task_boosts: ['task'], task_use_boost: true))
              run.send(:configure_boosts)
            end

            expect(events).to eq([:find, :ask, [:pause, 7], *accepted])
          end

          it 'boosts as before after an activation, or a reply it does not know, which note nothing' do
            [boosted, ''].each do |reply|
              _, events, tm = asking([wait, wait, offer], boost: true, boost_reply: reply)

              expect(events).to eq([:find, :ask, :boost, [:pause, 2], :find, :ask, [:pause, 7], *accepted])
              expect([tm.instance_variable_get(:@boost), $taskmaster_boost_unavailable]).to eq([false, nil])
            end
            run = build(settings: { task_use_boost: true })
            run.send(:configure_boosts)
            expect(run.instance_variable_get(:@boost)).to be(true)
          end

          # OSXLich-Doug's sequence on #8122: the run starts before the
          # rollover with the task boost noted spent, and its first cooldown
          # comes after the login reward. The note is asked at the cooldown.
          it 'sends BOOST TASK at a cooldown after the rollover, though the run started while the note held' do
            noted = Time.utc(2026, 11, 18, 5, 50).to_i
            $taskmaster_boost_unavailable = { 'task' => noted }
            allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 18, 5, 58))
            _, events, = asking([wait, offer], boost_reply: boosted) do |run|
              run.instance_variable_set(:@settings, OpenStruct.new(task_boosts: %w[task]))
              run.send(:configure_boosts)
              allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 18, 6, 3))
            end

            expect(events).to eq([:find, :ask, :boost, [:pause, 2], *accepted])
          end

          it 'waits the poll interval for every taskmaster when the run was started with the boost already spent' do
            $taskmaster_boost_unavailable = { 'task' => Time.now.to_i }
            _, events, = asking([wait, offer]) do |run|
              run.instance_variable_set(:@settings, OpenStruct.new(task_boosts: %w[task haste]))
              run.send(:configure_boosts)
            end

            expect(events).to eq([:find, :ask, [:pause, 7], *accepted])
          end
        end

        describe "Nezhiri's supplies looked over during her wait" do
          it 'spends her first wait without a boost on them, once, and polls through the rest' do
            _, events, = asking([wait, wait, wait, terms, offer], boost: true, npc: 'nezhiri')

            expect(events).to eq([:find, :ask, :boost, [:pause, 2], :find, :ask, :chores, :find, :ask, [:pause, 7], :find, :ask, *accepted])
          end

          it 'never for any other taskmaster' do
            _, events, = asking([wait, wait, wait, terms, offer], boost: true)

            expect(events).to eq([:find, :ask, :boost, [:pause, 2], :find, :ask, [:pause, 7], :find, :ask, [:pause, 7], :find, :ask, *accepted])
          end

          it 'on her first wait when the run has no boost' do
            expect(asking([wait, wait, offer], npc: 'nezhiri')[1]).to eq([:find, :ask, :chores, :find, :ask, [:pause, 7], *accepted])
          end

          it 'on the same wait when the boost had no credits' do
            expect(asking([wait, wait, offer], boost: true, boost_reply: no_boosts, npc: 'nezhiri')[1])
              .to eq([:find, :ask, :boost, :chores, :find, :ask, [:pause, 7], *accepted])
          end

          it 'not after a cancel or "a little later", only on "you must wait"' do
            expect(asking([ignored, later, wait, offer], npc: 'nezhiri')[1])
              .to eq([:find, :ask, cooldown_message, [:pause, 7], :find, :ask, cooldown_message, [:pause, 7], :find, :ask, :chores, *accepted])
          end

          it 'again for the next task, which starts with nothing left from the last survey' do
            seen = []
            _, _, tm = asking([wait, offer, offer], npc: 'nezhiri') do |run|
              allow(run).to receive(:nezhiri_wait_chores) { run.instance_variable_set(:@stock_survey, { copper: 50_000 }) }
              allow(run).to receive(:finish) { seen << run.instance_variable_get(:@stock_survey) }
            end

            tm.get_task

            expect(seen).to eq([{ copper: 50_000 }, nil])
          end

          it 'is forgotten for a task already in progress, which resume_task finishes with every check made afresh' do
            seen = []
            asking([wait, on_task], npc: 'nezhiri') do |run|
              allow(run).to receive(:nezhiri_wait_chores) { run.instance_variable_set(:@stock_survey, { copper: 50_000 }) }
              allow(run).to receive(:resume_task) { seen << run.instance_variable_get(:@stock_survey) }
            end
            asking([on_task], npc: 'nezhiri') do |run|
              run.instance_variable_set(:@stock_survey, { brine_parts: 30 }) # a survey left from an earlier get_task
              allow(run).to receive(:resume_task) { seen << run.instance_variable_get(:@stock_survey) }
            end

            expect(seen).to eq([nil, nil])
          end
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
      def resume(owed:, target: owed, banked: 0, uses: nil, foreign: false, ivars: {})
        tm = reader(**ivars)
        bag_items = banked
        given = 0
        events = []
        allow(tm).to receive(:tool_pickup) { events << :tool_pickup }
        allow(tm).to receive(:refresh_haste) { events << :haste }
        allow(tm).to receive(:top_up_copper) { events << :copper }
        allow(tm).to receive(:sort_sack) { events << :sack }
        allow(tm).to receive(:fput)
        allow(tm).to receive(:zasele) { |item, count, *_| events << [:make, item, count] }
        allow(tm).to receive(:complete_task) { |item, count| events << [:complete, item, count] }
        allow(tm).to receive(:get_instructions) do
          events << :asked_for_instructions
          ReplayGame.log('6201:47608').text # Zasele handing over a set
        end
        allow(DRCC).to receive(:stow_crafting_item) { |name, *_| events << [:stowed, name] }
        allow(DRCI).to receive(:exists?).and_return(false)
        allow(DRCI).to receive(:get_item?) do |name, _bag|
          # One set at most: a get by ordinal ("second rope instructions")
          # finds none.
          if name.end_with?('instructions')
            name == 'rope instructions' && !uses.nil?
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

        # A made-up taskmaster: every crafting taskmaster in the Hollow Eve
        # 2026 logs is one this script does.
        it "stops on a task from a taskmaster it doesn't do, saying to finish it by hand" do
          tm = reader(npc: 'zasele')
          game('task' => zasele_journal.sub('Zasele has asked', 'Ozemir has asked'))
          expect(tm).not_to receive(:turn_in_banked)
          expect(tm).not_to receive(:cancel_task)

          expect { tm.resume_task }.to raise_error(SystemExit)

          expect(DRC).to have_received(:message)
            .with('You are on a task for Ozemir, not Zasele. Ozemir is not a taskmaster this script does, so finish it yourself, or cancel it with ASK OZEMIR FOR TASK CANCEL (taskmasters then refuse you for about ten minutes). Or set task_cancel_foreign_tasks to have taskmaster cancel such tasks itself.')
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

        # Cithrin, 2026-11-11 08:27:20: TASK waited out 15 seconds on this
        # entry and the run said "You are not on a task with zasele.", 305
        # times from 06:43:20.
        let(:mags_journal) { 'The firewood peddler Mags in The Crossing wants you to retrieve 9 nuloe stems.' }

        it "stops on a forage task from a taskmaster it doesn't do, naming it, instead of saying there is no task" do
          tm = reader(npc: 'zasele')
          game('task' => mags_journal)
          expect(tm).not_to receive(:turn_in_banked)

          expect { tm.resume_task }.to raise_error(SystemExit)

          expect(tm.instance_variable_get(:@task_giver)).to eq('mags')
          expect(DRC).to have_received(:message)
            .with('You are on a task for Mags, not Zasele. Mags is not a taskmaster this script does, so finish it yourself, or cancel it with ASK MAGS FOR TASK CANCEL (taskmasters then refuse you for about ten minutes). Or set task_cancel_foreign_tasks to have taskmaster cancel such tasks itself.')
          expect(DRC).not_to have_received(:message).with(/You are not on a task/)
        end

        it 'names a taskmaster this script does from its "from ..." entry' do
          tm = reader(npc: 'zasele')
          game('task' => 'Mechanic Bradyn from the metal spider wants you to craft some wares for his efforts.  You think 3 more will satisfy his request.')

          expect { tm.read_task }.to raise_error(SystemExit)

          expect(DRC).to have_received(:message).with(a_string_starting_with('You are on a task for Bradyn, not Zasele. Finish it with ;taskmaster bradyn'))
        end

        it 'with task_cancel_foreign_tasks, cancels the forage task and goes back to its own taskmaster' do
          tm = reader(npc: 'zasele', cancel_foreign_tasks: true)
          game('task' => mags_journal)
          allow(tm).to receive(:pause)
          expect(tm).to receive(:cancel_task).with('mags', nil)

          expect { tm.resume_task }.to throw_symbol(TaskMaster::FOREIGN_TASK_CANCELLED)
        end

        it 'stops on an entry in that form for its own taskmaster, quoting it, instead of saying there is no task' do
          tm = reader(npc: 'bradyn')
          game('task' => 'Mechanic Bradyn from the metal spider wants you to craft some wares for his efforts.')

          expect { tm.read_task }.to raise_error(SystemExit)

          expect(DRC).to have_received(:message).with(a_string_starting_with("Your task journal shows a task for Bradyn that taskmaster can't read (\"Mechanic Bradyn from the metal spider wants you to "))
          expect(DRC).not_to have_received(:message).with(/You are not on a task/)
        end

        it 'never takes chatter with "wants you to" for an entry' do
          ['[General][Reynne] "that\'s what he wants you to think"',
           'Shavay says to Navesi, "That\'s what he wants you to think."',
           '[DRPrime]-DR:Miteo: "that\'s just what big TDP wants you to think."'].each do |line|
            expect(line).not_to match(TaskMaster::FOREIGN_TASK_ENTRY)
          end
          expect(mags_journal[TaskMaster::FOREIGN_TASK_ENTRY, :giver]).to eq('Mags')
          # bput returns the matched text: the whole entry line.
          expect(mags_journal[TaskMaster::FOREIGN_TASK_ENTRY]).to eq(mags_journal)
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
          expect(DRC).to have_received(:message)
            .with("Already asked zasele for rope instructions on this task, and no set you carry has the 3 uses still needed (you carry none with a use left). Stopping instead of asking again; check why the ropes aren't being made.")
        end

        # 2026-11-10/11: with the stop, t2 started taskmaster again every 12
        # seconds, about 2,000 times on each of 22 characters, until a person
        # cleared it.
        describe 'with task_cancel_when_instructions_short' do
          it 'is on by default: base.yaml declares it true' do
            expect(base_yaml).to include('task_cancel_when_instructions_short' => true)
          end

          it 'cancels the task, waits out the cooldown and sends the run back for a new task' do
            UserVars.taskmaster_replacements = { 'zasele' => 'rope' }
            tm = build(cancel_short_tasks: true)
            allow(tm).to receive(:pause)
            allow(tm).to receive(:get_instructions)
            expect(tm).to receive(:cancel_task)
              .with('zasele', 'rope', why: "Already asked zasele for rope instructions on this task, and no set you carry has the 3 uses still needed (the best has 2). Cancelling the task instead of stopping on every run (task_cancel_when_instructions_short); the ropes made for it are lost.")

            expect { tm.request_replacement('rope', needed: 3, most: 2) }.to throw_symbol(TaskMaster::FOREIGN_TASK_CANCELLED)

            expect(tm).to have_received(:pause).with(600)
            expect(tm).not_to have_received(:get_instructions)
            expect(DRC).not_to have_received(:message).with(/Stopping instead of asking again/)
          end

          it 'is caught by get_task, which asks for a new task after the cancel' do
            UserVars.taskmaster_replacements = { 'zasele' => 'rope' }
            tm = build(cancel_short_tasks: true)
            allow(tm).to receive(:pause)
            allow(tm).to receive(:find_npc)
            allow(tm).to receive(:cancel_task)
            asks = 0
            allow(tm).to receive(:resume_task) { tm.request_replacement('rope', needed: 3, most: 2) }
            allow(tm).to receive(:finish).and_return(:new_task)
            game('ask zasele for task' => lambda do |*|
              asks += 1
              asks == 1 ? 'You are already on a task.' : 'You may accept by typing ACCEPT TASK'
            end,
                 'accept task'         => 'You can check your progress with the TASK verb')

            expect(tm.get_task).to eq(:new_task)
            expect(asks).to eq(2)
            expect(tm).to have_received(:cancel_task).once
          end

          # Review: a remake (remake_not_good_enough) runs under complete_task,
          # which run_tasks and run_marathon call outside any catch.
          it 'is caught in a remake, so the task is cancelled and complete_task returns' do
            UserVars.taskmaster_replacements = { 'zasele' => 'rope' }
            tm = build(cancel_short_tasks: true)
            allow(tm).to receive(:pause)
            allow(tm).to receive(:cancel_task)
            allow(tm).to receive(:resume_task) { tm.request_replacement('rope', needed: 3, most: 2) }

            expect { tm.remake_not_good_enough('rope', 1) }.not_to raise_error

            expect(tm).to have_received(:cancel_task).once
          end

          it 'stops after the cancel in a finish run instead of taking new tasks' do
            UserVars.taskmaster_replacements = { 'zasele' => 'rope' }
            tm = build(cancel_short_tasks: true, finish_only: true)
            allow(tm).to receive(:pause)
            allow(tm).to receive(:cancel_task)

            expect { tm.request_replacement('rope', needed: 3, most: 2) }.to raise_error(SystemExit)

            expect(tm).to have_received(:cancel_task).once
            expect(tm).not_to have_received(:pause)
            expect(DRC).to have_received(:message).with('Cancelled the Zasele task. Not taking a new one: this run was only to finish the task in progress.')
          end

          it 'still asks once for a replacement when none was asked for on this task' do
            UserVars.taskmaster_replacements = {}
            tm = build(cancel_short_tasks: true)
            allow(tm).to receive(:get_instructions).and_return('Seamstress Zasele frowns.  She holds up one of her signs while handing you some reinforced rope instructions:')
            expect(tm).not_to receive(:cancel_task)

            tm.request_replacement('rope', needed: 3, most: 2)

            expect(UserVars.taskmaster_replacements).to eq('zasele' => 'rope')
          end

          it 'stops as before when the setting is false' do
            UserVars.taskmaster_replacements = { 'zasele' => 'rope' }
            tm = build(cancel_short_tasks: false)
            expect(tm).not_to receive(:cancel_task)

            expect { tm.request_replacement('rope', needed: 3, most: 2) }.to raise_error(SystemExit)

            expect(DRC).to have_received(:message).with(/Stopping instead of asking again/)
          end
        end

        # A remake after Zasele turned items down (remake_not_good_enough)
        # runs out of uses this way: each binned item had taken a study. The
        # stop names the refusal rather than sending the player to find out
        # why nothing is being made.
        it 'says the uses went on items the taskmaster turned down, in a remake' do
          UserVars.taskmaster_replacements = { 'zasele' => 'rope' }
          events = resume(owed: 3, uses: nil, ivars: { not_good_enough_remakes: 1 })
          expect(events).not_to include(:asked_for_instructions)
          expect(DRC).to have_received(:message)
            .with("Already asked zasele for rope instructions on this task, and no set you carry has the 3 uses still needed (you carry none with a use left). Stopping instead of asking again; Zasele turned ropes down as not made well enough, and their remakes need more instruction uses than you carry.")
        end

        it 'still asks when the earlier request was for a different item' do
          UserVars.taskmaster_replacements = { 'zasele' => 'netting' }
          expect(resume(owed: 3, uses: nil)).to include(:asked_for_instructions)
        end

        # Barrask, 2026-11-04: a leftover rat-pelt leather and the burlap cloth
        # filled both hands; ASK ZASELE FOR INSTRUCTIONS got "Zasele glances
        # at your full hands." (6200:49190) and no set, yet the request was
        # remembered, so every later run stopped with "Already asked" and the
        # task could never be finished (24,275 stops over 2.6 days).
        describe 'a request the taskmaster does not answer with a set' do
          let(:leather) { OpenStruct.new(name: 'rat-pelt leather', noun: 'leather', id: '758600') }
          let(:cloth) { OpenStruct.new(name: 'burlap cloth', noun: 'cloth', id: '758601') }
          let(:empty) { OpenStruct.new(name: 'Empty', noun: nil, id: nil) }

          # Zasele as the logs show her: with both hands full she glances at
          # them and hands nothing over (6200:49190); with a hand free she
          # hands the set over (6201:47608). Puts by id land in the bag unless
          # put_ok is false.
          def zasele_world(hands, put_ok: true)
            world = { hands: { right: nil, left: nil }.merge(hands), sent: [] }
            allow(GameObj).to receive(:right_hand) { world[:hands][:right] || empty }
            allow(GameObj).to receive(:left_hand) { world[:hands][:left] || empty }
            allow(DRCI).to receive(:put_away_item?) do |ref, bag|
              world[:sent] << "put #{ref} in my #{bag}"
              hand = world[:hands].find { |_, obj| obj && "##{obj.id}" == ref }&.first
              next false unless put_ok && hand

              world[:hands][hand] = nil
              true
            end
            allow(DRCI).to receive(:in_hands?) { |name| world[:hands].values.compact.any? { |obj| obj.name.end_with?(name) } }
            allow(DRC).to receive(:bput) do |command, *patterns|
              world[:sent] << command
              free = world[:hands].find { |_, obj| obj.nil? }&.first
              line = if free.nil?
                       ReplayGame.log('6200:49190').text
                     else
                       world[:hands][free] = OpenStruct.new(name: 'reinforced rope instructions', noun: 'instructions', id: '758700')
                       ReplayGame.log('6201:47608').text
                     end
              patterns.flatten.any? { |pattern| line.match?(pattern) } ? line : ''
            end
            world
          end

          it "empties both hands by id before asking, so Zasele hands the set over and the request is remembered (6201:47608)" do
            tm = reader
            world = zasele_world({ right: leather, left: cloth })

            tm.request_replacement('rope')

            expect(world[:sent]).to eq(['put #758600 in my duffel bag', 'put #758601 in my duffel bag', 'ask zasele for instructions'])
            expect(world[:hands][:right]&.name).to eq('reinforced rope instructions')
            expect(UserVars.taskmaster_replacements).to eq('zasele' => 'rope')
          end

          it 'stops without remembering the request when Zasele glances at full hands and hands nothing over (6200:49190)' do
            tm = reader
            allow(tm).to receive(:get_instructions).with('rope').and_return(ReplayGame.log('6200:49190').text)
            allow(DRCI).to receive(:in_hands?).and_return(false)

            expect { tm.request_replacement('rope') }.to raise_error(SystemExit)

            expect(UserVars.taskmaster_replacements).to eq({})
            expect(DRC).to have_received(:message)
              .with('Asked zasele for rope instructions, but none were handed over ("Zasele glances at your full hands."). That does not count as this task\'s one replacement. Stopping; the next run asks again.')
          end

          it 'asks again on the next run after a request that got no set, and remembers the one that does' do
            tm = reader
            replies = [ReplayGame.log('6200:49190').text, ReplayGame.log('6201:47608').text]
            allow(tm).to receive(:get_instructions) { replies.shift }
            allow(DRCI).to receive(:in_hands?).and_return(false)

            expect { tm.request_replacement('rope') }.to raise_error(SystemExit)
            tm.request_replacement('rope')

            expect(tm).to have_received(:get_instructions).twice
            expect(UserVars.taskmaster_replacements).to eq('zasele' => 'rope')
            expect(DRC).not_to have_received(:message).with(/Already asked/)
          end

          it 'stops without remembering the request when the ask goes unanswered and no set is in hand' do
            tm = reader
            allow(tm).to receive(:get_instructions).and_return('')
            allow(DRCI).to receive(:in_hands?).with('rope instructions').and_return(false)

            expect { tm.request_replacement('rope') }.to raise_error(SystemExit)

            expect(UserVars.taskmaster_replacements).to eq({})
            expect(DRC).to have_received(:message).with(/none were handed over \(no answer\)/)
          end

          it 'remembers the request when the reply was missed but the set is in hand' do
            tm = reader
            allow(tm).to receive(:get_instructions).and_return('')
            allow(DRCI).to receive(:in_hands?).with('rope instructions').and_return(true)

            tm.request_replacement('rope')

            expect(UserVars.taskmaster_replacements).to eq('zasele' => 'rope')
          end

          it "reads Zasele's full-hands reply at once instead of waiting out the ask (6200:49190)" do
            tm = reader
            allow(GameObj).to receive(:right_hand).and_return(empty)
            allow(GameObj).to receive(:left_hand).and_return(empty)
            refusal = ReplayGame.log('6200:49190').text
            allow(DRC).to receive(:bput) { |_command, *patterns| patterns.flatten.any? { |pattern| refusal.match?(pattern) } ? refusal : '' }

            expect(tm.get_instructions('rope')).to eq(refusal)
          end

          it 'stops before asking when a hand cannot be emptied, and remembers nothing' do
            tm = reader
            world = zasele_world({ right: leather, left: cloth }, put_ok: false)

            expect { tm.request_replacement('rope') }.to raise_error(SystemExit)

            expect(world[:sent]).not_to include('ask zasele for instructions')
            expect(UserVars.taskmaster_replacements).to eq({})
            expect(DRC).to have_received(:message).with(/Could not put your rat-pelt leather \(#758600\) in your duffel bag, so there is no free hand for the rope instructions/)
          end
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
          expect(tm).to have_received(:request_replacement).with('rope', needed: 2, most: nil)
        end

        it 'uses a good set carried behind a foreign one, asking for nothing' do
          tm = carrying([foreign, usable])
          allow(DRCI).to receive(:dispose_trash).and_return(true)

          tm.ensure_instructions('rope', 3)

          expect(tm).not_to have_received(:request_replacement)
        end

        it 'puts each foreign set back when the trash will not take it, reads the next one, and asks once' do
          tm = carrying([foreign, foreign])
          allow(DRCI).to receive(:dispose_trash).and_return(false)

          tm.ensure_instructions('rope', 2)

          expect(DRCI).to have_received(:get_item?).with('second rope instructions', 'duffel bag')
          expect(DRCC).to have_received(:stow_crafting_item).with('rope instructions', 'duffel bag', nil).twice
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

      # A replacement goes in the bag in front of the task's own set. Once it
      # ran short, the set behind it was never read, though it had a use for
      # each item owed: a 1-use replacement in front of the task's 2-use set,
      # 2 ropes owed, stopped with "Already asked" (2026-11-07).
      describe 'several sets carried' do
        # The bag as the game keeps it, each set given as its uses left, or
        # :foreign for one written for someone else, which the trash takes: a
        # GET takes the set at the front, or by ordinal the one that many
        # places in ("get my second rope instructions from my duffel bag"),
        # and a set put back goes to the front (the next GET took the set put
        # away last, 2026-11-07). With two sets held, READ reads the first one
        # taken (which one the game reads is not in the logs).
        def carried(bag, held: [])
          tm = reader
          world = { bag: bag.dup, hands: held.dup }
          allow(DRCI).to receive(:in_hands?) { |name| name == 'rope instructions' && !world[:hands].empty? }
          allow(DRCI).to receive(:get_item?) do |name, _bag|
            ordinal = name[/\A(\w+) rope instructions\z/, 1]
            index = ordinal ? $ORDINALS.index(ordinal) : 0
            next false if world[:hands].size == 2 || index.nil? || index >= world[:bag].size

            world[:hands] << world[:bag].delete_at(index)
            true
          end
          allow(DRCC).to receive(:stow_crafting_item) do
            world[:bag].unshift(world[:hands].shift) unless world[:hands].empty?
            true
          end
          allow(DRCI).to receive(:dispose_trash) { !world[:hands].shift.nil? }
          game('read my rope instructions' => lambda do |*|
            next "You can't read the ink printed on the rope instructions.  They were written by or for someone else." if world[:hands].first == :foreign

            "These instructions appear to be very fragile and will wear out quickly when studied.  They have only #{world[:hands].first} uses remaining."
          end)
          [tm, world]
        end

        it "uses the task's set carried behind a short replacement, asking for nothing" do
          tm, world = carried([1, 2])
          expect(tm).not_to receive(:request_replacement)

          tm.ensure_instructions('rope', 2)

          expect(DRCI).to have_received(:get_item?).with('second rope instructions', 'duffel bag')
          expect(world).to eq(bag: [1], hands: [2])
        end

        # Review of #7988: a binned set leaves the bag, so it must not move the
        # ordinal on. Counted, the next get asked for a third set that was not
        # there, missed the good one behind and asked Zasele again.
        it 'reads on past a short set and a binned foreign set to the good set behind them' do
          tm, world = carried([1, :foreign, 2])
          expect(tm).not_to receive(:request_replacement)

          tm.ensure_instructions('rope', 2)

          expect(DRCI).to have_received(:dispose_trash).once
          expect(DRCI).to have_received(:get_item?).with('second rope instructions', 'duffel bag').twice
          expect(DRCI).not_to have_received(:get_item?).with('third rope instructions', 'duffel bag')
          expect(world).to eq(bag: [1], hands: [2])
        end

        it 'puts a set left in hand in the bag first, so it is read with the rest' do
          tm, world = carried([1], held: [2])
          expect(tm).not_to receive(:request_replacement)

          tm.ensure_instructions('rope', 2)

          expect(world).to eq(bag: [1], hands: [2])
        end

        it 'reads every set, then asks with the most uses seen, when all of them run short' do
          tm, world = carried([1, 1, 0])
          allow(tm).to receive(:request_replacement)

          tm.ensure_instructions('rope', 2)

          expect(tm).to have_received(:request_replacement).with('rope', needed: 2, most: 1)
          expect(world).to eq(bag: [0, 1, 1], hands: [])
        end

        it 'says in the stop how many uses the best set has and how many are needed' do
          UserVars.taskmaster_replacements = { 'zasele' => 'rope' }
          tm, = carried([1, 2])

          expect { tm.ensure_instructions('rope', 3) }.to raise_error(SystemExit)

          expect(DRC).to have_received(:message)
            .with("Already asked zasele for rope instructions on this task, and no set you carry has the 3 uses still needed (the best has 2). Stopping instead of asking again; check why the ropes aren't being made.")
        end
      end

      it 'counts the items still owed after the banked ones are in' do
        expect(resume(owed: 6, target: 8, banked: 1, uses: 6)).to include([:make, 'rope', 5])
      end
    end

    describe '#turn_in_banked' do
      # Fizzlestiks, 2026-11-10: with none of the task's ropes in the bag,
      # the GET took the character's own bundling rope. The bag would hand
      # out a second item and Zasele would turn it down too, so only an end
      # to the hand-in keeps this to one give: the put-back item is what the
      # next GET takes.
      it 'puts back an item the character did not make at once, and leaves the items still owed to be made' do
        tm = reader
        allow(DRCC).to receive(:stow_crafting_item)
        giving([not_made_by_you, not_made_by_you], banked: 2)

        expect(tm.turn_in_banked('rope', 7)).to eq(7)

        expect(DRC).to have_received(:bput).with('give my rope to zasele', any_args).once
        expect(DRCC).to have_received(:stow_crafting_item).with('rope', 'duffel bag', nil).once
        expect(DRC).to have_received(:message).with('Zasele only takes a rope you made, and the rope from your duffel bag was not one, so it is back in your duffel bag.')
      end

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

      # A sew that stopped after its study left the rope instructions in hand.
      # DRCI.in_hands?('rope') matched them, so no rope came out of the bag,
      # and five gives of nothing ("What is it you're trying to give?")
      # stopped the task (2026-11-07).
      it 'gets the rope out of the bag while rope instructions are held, and hands it in' do
        tm = reader
        empty = OpenStruct.new(name: 'Empty', noun: nil, id: nil)
        rope = OpenStruct.new(name: 'coil of burlap reinforced rope', noun: 'rope', id: '758800')
        hands = { right: OpenStruct.new(name: 'some reinforced rope instructions', noun: 'instructions', id: '758700'), left: nil }
        bag = [rope]
        allow(GameObj).to receive(:right_hand) { hands[:right] || empty }
        allow(GameObj).to receive(:left_hand) { hands[:left] || empty }
        # lich-5 matches a one-word name by DRC::Item#short_regex, /\bname/i.
        allow(DRCI).to receive(:in_hands?) { |name| hands.values.compact.any? { |obj| obj.name.match?(/\b#{Regexp.escape(name)}/i) } }
        allow(DRCI).to receive(:get_item?).with('rope', 'duffel bag') { bag.empty? ? false : (hands[:left] = bag.shift) && true }
        game('give my rope to zasele' => lambda do |*|
          next missed_give unless hands[:left] == rope

          hands[:left] = nil
          more_needed(1)
        end)

        expect(tm.turn_in_banked('rope', 2)).to eq(1)

        expect(DRC).to have_received(:bput).with('give my rope to zasele', any_args).once
        expect(hands[:right].noun).to eq('instructions')
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
        build(remainder: true, ingots_bought: 1, ingots_before: { 'bronze ingot' => 0, 'steel ingot' => 0 }).trash('hammer', 'ingot', 'bronze')
        expect(DRCT).to have_received(:dispose).with('#2222486', 793)
      end

      describe "sparing the player's own ingots" do
        # before: what the bag held before the metal was bought (nil: unknown).
        def trash_metal(bag, bought:, before:, metal: 'bronze', **world_options)
          world = stock_world(bag, **world_options)
          build(remainder: true, ingots_bought: bought, ingots_before: before).trash('hammer', 'ingot', metal)
          world
        end

        it "throws away only the task's leftover when the bag also holds the player's own" do
          world = trash_metal({ 'bronze ingot' => 3 }, bought: 1, before: { 'bronze ingot' => 2, 'steel ingot' => 0 })
          expect(DRCT).to have_received(:dispose).once
          expect(world[:bag]).to eq({ 'bronze ingot' => 2 })
        end

        it 'throws away every unused whole ingot of a task that stopped short, and no more' do
          world = trash_metal({ 'steel ingot' => 4 }, bought: 3, before: { 'bronze ingot' => 0, 'steel ingot' => 1 }, metal: 'steel')
          expect(DRCT).to have_received(:dispose).exactly(3).times
          expect(world[:bag]).to eq({ 'steel ingot' => 1 })
        end

        it 'never throws away more than the task bought, whatever else the bag gained' do
          world = trash_metal({ 'bronze ingot' => 5 }, bought: 1, before: { 'bronze ingot' => 0, 'steel ingot' => 0 })
          expect(DRCT).to have_received(:dispose).once
          expect(world[:bag]).to eq({ 'bronze ingot' => 4 })
        end

        it 'throws away nothing when the bag holds no more than before (forge used a kept one)' do
          world = trash_metal({ 'bronze ingot' => 2 }, bought: 1, before: { 'bronze ingot' => 2, 'steel ingot' => 0 })
          expect(DRCT).not_to have_received(:dispose)
          expect(world[:sent]).not_to include('get my bronze ingot from my duffel bag')
          expect(world[:bag]).to eq({ 'bronze ingot' => 2 })
        end

        it 'throws away at most what the task bought when the counts are unknown' do
          world = trash_metal({ 'bronze ingot' => 3 }, bought: 1, before: nil)
          expect(DRCT).to have_received(:dispose).once
          expect(world[:bag]).to eq({ 'bronze ingot' => 2 })

          world = trash_metal({ 'bronze ingot' => 3 }, bought: 1, before: { 'bronze ingot' => 0, 'steel ingot' => 0 }, listed: false)
          expect(world[:sent].count { |command| command.start_with?('inventory') }).to eq(2)
          expect(world[:bag]).to eq({ 'bronze ingot' => 2 })
        end

        it 'says once a run how many stay in the bag as the player\'s' do
          world = trash_metal({ 'bronze ingot' => 3 }, bought: 1, before: { 'bronze ingot' => 2, 'steel ingot' => 0 })
          expect(world[:bag]).to eq({ 'bronze ingot' => 2 })
          expect(DRC).to have_received(:message).with('2 bronze ingots stay in your duffel bag. They were there before the task bought its metal, so taskmaster keeps them as yours. If any are leftovers from a run that stopped, throw them away by hand.')

          stock_world({ 'steel ingot' => 2 })
          tm = build(remainder: true, ingots_bought: 1, ingots_before: { 'bronze ingot' => 0, 'steel ingot' => 1 })
          tm.trash('hammer', 'ingot', 'steel')
          tm.trash('hammer', 'ingot', 'steel')
          expect(DRC).to have_received(:message).with(a_string_starting_with('1 steel ingot stays in your duffel bag.')).once
        end

        it 'says nothing when none of the metal stays, or the counts are unknown' do
          trash_metal({ 'bronze ingot' => 1 }, bought: 1, before: { 'bronze ingot' => 0, 'steel ingot' => 0 })
          trash_metal({ 'bronze ingot' => 3 }, bought: 1, before: nil)
          trash_metal({ 'bronze ingot' => 3 }, bought: 1, before: { 'bronze ingot' => 2, 'steel ingot' => 0 }, listed: false)
          expect(DRC).not_to have_received(:message).with(a_string_including('stay'))
        end

        it 'counts a piece it could not throw away among those that stay' do
          world = trash_metal({ 'bronze ingot' => 2 }, bought: 1, before: { 'bronze ingot' => 1, 'steel ingot' => 0 }, refuse: true)
          expect(world[:bag]).to eq({ 'bronze ingot' => 2 })
          expect(DRC).to have_received(:message).with(a_string_starting_with('2 bronze ingots stay in your duffel bag.'))
        end

        it 'dispose_leftovers says how many pieces went in the bin' do
          stock_world({ 'burlap cloth' => 3 })
          expect(build.send(:dispose_leftovers, 'burlap cloth', 14_886, 2)).to eq(2)
          world = stock_world({ 'burlap cloth' => 3 }, refuse: true)
          expect(build.send(:dispose_leftovers, 'burlap cloth', 14_886)).to eq(0)
          expect(world[:bag]).to eq({ 'burlap cloth' => 3 })
        end

        it 'still throws away every leftover piece of cloth, which is never the player\'s' do
          world = stock_world({ 'burlap cloth' => 3 })
          build(remainder: true, ingots_bought: 1, ingots_before: { 'bronze ingot' => 0, 'steel ingot' => 0 }).trash('rope', 'cloth', 'burlap')
          expect(world[:bag]).to eq({ 'burlap cloth' => 0 })
        end
      end

      describe 'what the buyers note for leftover_ingots' do
        before do
          allow(DRCM).to receive(:ensure_copper_on_hand)
          allow(DRCT).to receive(:order_item)
          allow(DRCC).to receive(:stow_crafting_item)
        end

        it 'notes every ingot buy_ingots buys, and the one bulk ingot bingots buys' do
          tm = build(stockdata: { 'bronze' => { 'stock-value' => 562, 'stock-number' => 11 } })
          tm.send(:buy_ingots, 4, 'bronze')
          expect(tm.instance_variable_get(:@ingots_bought)).to eq(4)
          tm.send(:bingots, 3)
          expect(tm.instance_variable_get(:@ingots_bought)).to eq(1)
        end
      end

      describe '#bin_stray_ingots (task_bin_metal_from)' do
        def sweeper(from, **ivars)
          build(settings: { task_bin_metal_from: from }, **ivars)
        end

        def swept_messages
          messages = []
          allow(DRC).to receive(:message) { |text| messages << text }
          messages
        end

        it 'bins every bronze and steel ingot in the named container by id at the forge bin, then says to unset it' do
          messages = swept_messages
          world = stock_world({ 'bronze ingot' => 1 }, others: { 'backpack' => { 'bronze ingot' => 3, 'steel ingot' => 1, 'tyrium ingot' => 2 } })
          sweeper('backpack').send(:bin_stray_ingots)
          expect(DRCT).to have_received(:dispose).with(/\A#\d+\z/, 793).exactly(4).times
          expect(world[:others]['backpack']).to eq({ 'bronze ingot' => 0, 'steel ingot' => 0, 'tyrium ingot' => 2 })
          expect(world[:bag]).to eq({ 'bronze ingot' => 1 })
          expect(messages).to eq(['task_bin_metal_from: threw away 4 bronze and steel ingots from your backpack; none are left there. Unset it now, or it bins your own ingots there on every run.'])
        end

        it 'drops a leading "my" from the setting' do
          world = stock_world({}, others: { 'backpack' => { 'bronze ingot' => 1 } })
          sweeper('my backpack').send(:bin_stray_ingots)
          expect(world[:sent]).to include('get my bronze ingot from my backpack')
          expect(world[:sent].grep(/my my/)).to eq([])
        end

        it 'is done for the run once the container is empty, so a repeat or cycle run does not ask again' do
          world = stock_world({}, others: { 'backpack' => { 'bronze ingot' => 1 } })
          tm = sweeper('backpack')
          tm.send(:bin_stray_ingots)
          world[:sent].clear
          tm.send(:bin_stray_ingots)
          expect(world[:sent]).to eq([])
        end

        it 'does nothing unset or blank' do
          [nil, '', '  '].each do |from|
            world = stock_world({}, others: { 'backpack' => { 'bronze ingot' => 1 } })
            sweeper(from).send(:bin_stray_ingots)
            expect(world[:sent]).to eq([])
          end
        end

        it 'leaves alone any container with the same noun as crafting_container, saying why' do
          messages = swept_messages
          ['duffel bag', 'bag', 'heavy duffel bag', 'silk bag', 'my bag', 'travel.bag'].each do |from|
            world = stock_world({ 'bronze ingot' => 2 })
            sweeper(from).send(:bin_stray_ingots)
            expect(world[:sent]).to eq([]), "swept for #{from}"
            expect(world[:bag]).to eq({ 'bronze ingot' => 2 })
          end
          expect(messages.size).to eq(6)
          expect(messages).to all(include('may be your crafting_container (duffel bag)', 'nothing is swept'))
        end

        # DR takes a shortened noun for the whole one, so "backp" and
        # "backpack" are one bag (crafting_container: backp is
        # profiles/Samples/WarriorMage/Kyrtoth-setup.yaml). Their last words
        # differ, which used to sweep the crafting bag and bin the player's
        # own ingots.
        it 'leaves alone a container whose noun is shortened from crafting_container\'s, or the other way round' do
          messages = swept_messages
          [%w[backp backpack], %w[backpack backp]].each do |bag, from|
            world = stock_world({}, others: { from => { 'bronze ingot' => 2, 'steel ingot' => 1 } })
            sweeper(from, bag: bag).send(:bin_stray_ingots)
            expect(world[:sent]).to eq([]), "swept #{from} with crafting_container #{bag}"
            expect(world[:others][from]).to eq({ 'bronze ingot' => 2, 'steel ingot' => 1 })
          end
          expect(messages).to all(include('nothing is swept'))
        end

        it 'still leaves alone a container that a shortened noun may name, with more than one worn bag it could be' do
          $worn_items = [OpenStruct.new(name: 'silk backpack', noun: 'backpack', id: '501'), OpenStruct.new(name: 'rugged white backpack', noun: 'backpack', id: '502')]
          world = stock_world({}, others: { 'backpack' => { 'bronze ingot' => 2 } })
          sweeper('backpack', bag: 'backp').send(:bin_stray_ingots)
          expect(world[:sent]).to eq([])
        end

        it 'sweeps a worn container of the same noun that is not the crafting bag: two packs with ids of their own' do
          $worn_items = [OpenStruct.new(name: "scuffed traveler's pack", noun: 'pack', id: '1570759'),
                         OpenStruct.new(name: "darkened bitterweave scavenger's pack", noun: 'pack', id: '195238')]
          world = stock_world({}, others: { "scavenger's pack" => { 'bronze ingot' => 2, 'steel ingot' => 1 } })
          sweeper("scavenger's pack", bag: "traveler's pack").send(:bin_stray_ingots)
          expect(world[:sent]).to include("get my bronze ingot from my scavenger's pack", "get my steel ingot from my scavenger's pack")
          expect(world[:others]["scavenger's pack"]).to eq({ 'bronze ingot' => 0, 'steel ingot' => 0 })
        end

        # The crafting bag's name ends in a medallion, not its noun: the
        # worn container a setting names is found by its noun and the
        # setting's words in its name, wherever they are.
        it 'tells the crafting bag from another worn bag by id, though neither name ends in "bag"' do
          $worn_items = [OpenStruct.new(name: 'deep black camlet duffel bag set with a crimson windsteel medallion', noun: 'bag', id: '997'),
                         OpenStruct.new(name: 'dark watersilk bag bearing a detailed cambrinth medallion', noun: 'bag', id: '1144457')]
          world = stock_world({ 'bronze ingot' => 2 }, others: { 'watersilk bag' => { 'bronze ingot' => 3 } })
          sweeper('watersilk bag').send(:bin_stray_ingots)
          expect(world[:others]['watersilk bag']).to eq({ 'bronze ingot' => 0 })
          expect(world[:bag]).to eq({ 'bronze ingot' => 2 })
        end

        it 'leaves alone every container while crafting_container is unset, as it could be any of them' do
          world = stock_world({}, others: { 'backpack' => { 'bronze ingot' => 2 } })
          sweeper('backpack', bag: nil).send(:bin_stray_ingots)
          expect(world[:sent]).to eq([])
        end

        it 'leaves alone a second name for the worn crafting bag' do
          $worn_items = [OpenStruct.new(name: 'deep black camlet duffel bag set with a crimson windsteel medallion', noun: 'bag', id: '997')]
          world = stock_world({ 'bronze ingot' => 2 }, others: { 'camlet duffel bag' => { 'bronze ingot' => 2 } })
          sweeper('camlet duffel bag').send(:bin_stray_ingots)
          expect(world[:sent]).to eq([])
        end

        it 'stops the whole sweep at an ingot the bin refuses, puts it back where it came from, and tries again next time' do
          messages = swept_messages
          world = stock_world({}, refuse: true, others: { 'backpack' => { 'bronze ingot' => 2, 'steel ingot' => 1 } })
          tm = sweeper('backpack')
          tm.send(:bin_stray_ingots)
          expect(world[:sent].grep(/\Aget /)).to eq(['get my bronze ingot from my backpack'])
          expect(world[:sent]).to include('put #2222486 in my backpack')
          expect(world[:others]['backpack']).to eq({ 'bronze ingot' => 2, 'steel ingot' => 1 })
          expect(world[:bag]).to eq({})
          expect(world[:hands].values).to all(be_nil)
          expect(messages.last).to eq('task_bin_metal_from: threw away 0 bronze and steel ingots from your backpack, and could not finish (see above, or check that you carry a backpack). It tries again before the next metal task.')

          world[:sent].clear
          tm.send(:bin_stray_ingots)
          expect(world[:sent]).to include('get my bronze ingot from my backpack')
        end

        it 'never says to unset it while the hands are full, and tries again once they are free' do
          messages = swept_messages
          full = OpenStruct.new(name: 'iron chisels', noun: 'chisels', id: '1')
          world = stock_world({}, hands: { right: full, left: full }, others: { 'backpack' => { 'bronze ingot' => 2 } })
          tm = sweeper('backpack')
          tm.send(:bin_stray_ingots)
          expect(messages).to include('Both hands are full, so the leftover bronze ingot stays in your backpack. Empty your hands to get rid of it.')
          expect(messages.grep(/Unset it now/)).to eq([])
          expect(world[:others]['backpack']).to eq({ 'bronze ingot' => 2 })

          world[:hands] = { right: nil, left: nil }
          tm.send(:bin_stray_ingots)
          expect(world[:others]['backpack']).to eq({ 'bronze ingot' => 0 })
          expect(messages.last).to include('threw away 2 bronze and steel ingots from your backpack; none are left there. Unset it now')
        end

        it 'tries again next time when the container cannot be counted' do
          messages = swept_messages
          world = stock_world({}, listed: false, others: { 'backpack' => { 'bronze ingot' => 1 } })
          tm = sweeper('backpack')
          tm.send(:bin_stray_ingots)
          expect(world[:others]['backpack']).to eq({ 'bronze ingot' => 0 })
          expect(messages.last).to include('could not finish')
          world[:sent].clear
          tm.send(:bin_stray_ingots)
          expect(world[:sent]).not_to be_empty
        end

        it 'stops the run before any metal is bought when a swept ingot is still in hand' do
          messages = swept_messages
          world = stock_world({}, refuse: true, others: { 'backpack' => { 'bronze ingot' => 1, 'steel ingot' => 1 } })
          allow(DRCI).to receive(:put_away_item?).and_return(false)
          tm = build(settings: { task_bin_metal_from: 'backpack', forging_tools: [] })
          allow(tm).to receive(:bingots)
          expect { tm.send(:forge_metal_task, 'dagger', 3, 6, 'ingot', 'bronze') }.to raise_error(SystemExit)
          expect(tm).not_to have_received(:bingots)
          expect(world[:sent].grep(/\Aget /)).to eq(['get my bronze ingot from my backpack'])
          expect(messages.last).to eq('task_bin_metal_from: threw away 0 bronze and steel ingots from your backpack, but a swept ingot may still be in your hand (#2222486). Stopping before buying any metal.')
        end

        it 'runs before the metal is counted and bought on a metal task' do
          tm = build(settings: { forging_tools: [], task_bin_metal_from: 'backpack' }, stockdata: { 'steel' => { 'stock-volume' => 10 } })
          order = []
          allow(tm).to receive(:bin_stray_ingots) { order << :sweep }
          allow(tm).to receive(:carried_ingots) { order << :count && nil }
          allow(tm).to receive(:bingots) { order << :buy }
          allow(tm).to receive(:forge_item) { 3 }
          allow(tm).to receive(:repair)
          allow(tm).to receive(:trash)
          tm.send(:forge_metal_task, 'dagger', 3, 6, 'ingot', 'bronze')
          expect(order).to eq(%i[sweep count buy])
        end
      end

      # Kythkani's "inve sack" (2026-11-09 16:51:38 NZDT), as
      # Lich::Util.issue_command returns it, and lines the same INVENTORY
      # format gave for a toolbelt that day.
      describe '#inventory_listing' do
        let(:sack) do
          ['Inside a <a exist="21309821" noun="sack">woven sack</a>, you see:', '', '  some rat-skin leather', '  some copper coins', '  some bronze coins',
           '  some silver coins', '  a gold coin', '', "[Use <d cmd='inventory help'>INVENTORY HELP</d> for more options.]"]
        end

        def listing(lines)
          inventory_replies('inventory #21309821' => lines)
          build.send(:inventory_listing, '#21309821')
        end

        it 'gives each item line of the logged reply, whole, without its indent or the tags' do
          expect(listing(sack)).to eq(['some rat-skin leather', 'some copper coins', 'some bronze coins', 'some silver coins', 'a gold coin'])
        end

        # A name DRC.list_to_array would cut in two at its "and a".
        it 'keeps a name with "and a" in it as one item' do
          lines = ["Inside a slender onyx-hide tailor's toolbelt plentifully bestrewn with jaspe ties, you see:",
                   '  a small uthamar brazier supported by twisted Sunderstone feet', '  a weighty almanac bound in rich purple leather and a golden closed-eye clasp']
          expect(listing(lines)).to eq(['a small uthamar brazier supported by twisted Sunderstone feet', 'a weighty almanac bound in rich purple leather and a golden closed-eye clasp'])
        end

        it 'lists a container inside it as one item, and skips lines that are not items' do
          lines = [sack[0], 'Inkin says, "Hi."', '  a leather pouch', '', sack.last, '  a stray line after the list']
          expect(listing(lines)).to eq(['a leather pouch'])
        end

        # The Poltu trunk task (Hollow Eve 2026, taskmaster 2026.11.10.4):
        # the trunk forge made was listed closed in the haversack. Mailicyian's
        # "inventory lootbelt" (2026-11-10 12:35:45 NZDT) marked every locked
        # box the same way; LOOK IN and RUMMAGE of the belt did not. The "battered
        # box" line is made up, for a "(closed)" that does not end the line.
        it 'cuts " (closed)" off the end of a closed container\'s line, and off no other' do
          lines = [sack[0], '  a heavy bronze waterproof trunk (closed)', '  a reinforced pine trunk (closed)', '  a piece of hhr\'lav\'geluhh bark', '  some waterproof trunk instructions',
                   '  a weighty almanac bound in rich purple leather and a golden closed-eye clasp', '  a battered box (closed) with a dent', sack.last]
          expect(listing(lines)).to eq(['a heavy bronze waterproof trunk', 'a reinforced pine trunk', "a piece of hhr'lav'geluhh bark", 'some waterproof trunk instructions',
                                        'a weighty almanac bound in rich purple leather and a golden closed-eye clasp', 'a battered box (closed) with a dent'])
        end

        it 'gives none for an empty container' do
          expect(listing(["There's nothing inside a woven sack!"])).to eq([])
        end

        it 'gives nil with no reply, another reply, or a list with no item in it' do
          expect(listing([])).to be_nil
          expect(listing(['What were you referring to?'])).to be_nil
          expect(listing([sack[0], '', sack.last])).to be_nil
        end

        it 'asks for a worn container by the id of the one it names, and for any other by its name, without "my"' do
          $worn_items = [OpenStruct.new(name: 'deep black camlet duffel bag set with a crimson windsteel medallion', noun: 'bag', id: '997')]
          inventory_replies({})
          tm = build
          tm.send(:container_listing, 'camlet duffel bag')
          tm.send(:container_listing, 'my backpack')
          expect(Lich::Util).to have_received(:issue_command).with('inventory #997', any_args)
          expect(Lich::Util).to have_received(:issue_command).with('inventory backpack', any_args)
        end

        it 'sends nothing for a blank setting, since a bare INVENTORY lists everything carried' do
          inventory_replies({})
          expect([nil, '', 'my '].map { |setting| build.send(:container_listing, setting) }).to eq([nil, nil, nil])
          expect(Lich::Util).not_to have_received(:issue_command)
        end
      end

      # The names are real (noun-corpus.tsv gives each its noun=): a wand,
      # two deeds, sigil-scrolls, and a scroll logged in a Dorhum task
      # (taskmaster-nezhiri logs, message.txt:13418).
      describe '#sort_listed' do
        def sorted(name, *lines)
          build.send(:sort_listed, lines, name)
        end

        it 'sorts an item of the noun by its noun, wherever the noun is in its name' do
          expect(sorted('wand', 'a sturdy ironwood wand wrapped in braided lengths of sinew', 'a wand'))
            .to eq({ of_kind: ['a sturdy ironwood wand wrapped in braided lengths of sinew', 'a wand'], unsure: [], unread: [] })
        end

        it "needs the kind's other words as whole words" do
          lines = ['an intricate decay sigil-scroll etched in delicate detail', 'an intricate congruence sigil-scroll etched in delicate detail', 'an intricate decayed sigil-scroll']
          expect(sorted('decay sigil-scroll', *lines)[:of_kind]).to eq(['an intricate decay sigil-scroll etched in delicate detail'])
        end

        it 'puts an item that holds the words, but whose noun reads as another, apart as unsure' do
          expect(sorted('rock', 'a rock marble deed', 'a deed for a large anjisis rock', 'a smooth rock'))
            .to eq({ of_kind: ['a smooth rock'], unsure: ['a rock marble deed', 'a deed for a large anjisis rock'], unread: [] })
          expect(sorted('decay sigil-scroll', 'an intricate decay sigil-scroll comprised of broad strokes'))
            .to eq({ of_kind: [], unsure: ['an intricate decay sigil-scroll comprised of broad strokes'], unread: [] })
        end

        # The one name in noun-corpus.tsv that get_noun reads no noun off
        # (noun="building", a room object, used here only for its name).
        it 'lists an unsure item with no noun read off it as unread too' do
          expect(sorted('building', 'burned out skeleton of a ruined building', 'a ruined building'))
            .to eq({ of_kind: ['a ruined building'], unsure: ['burned out skeleton of a ruined building'], unread: ['burned out skeleton of a ruined building'] })
        end

        it 'sorts nothing out of no reply' do
          expect(sorted('rock')).to eq({ of_kind: [], unsure: [], unread: [] })
          expect(build.send(:sort_listed, nil, 'rock')).to eq({ of_kind: [], unsure: [], unread: [] })
        end
      end

      describe '#carried_ingots' do
        it 'counts each task metal in one INVENTORY, by its whole name' do
          world = stock_world({ 'bronze ingot' => 2, 'steel ingot' => 1, 'tyrium ingot' => 3 })
          expect(build.send(:carried_ingots)).to eq({ 'bronze ingot' => 2, 'steel ingot' => 1 })
          expect(world[:sent]).to eq(['inventory duffel bag'])
        end

        it 'counts another container when given one' do
          world = stock_world({ 'bronze ingot' => 2 }, others: { 'backpack' => { 'steel ingot' => 3 } })
          expect(build.send(:carried_ingots, 'backpack')).to eq({ 'bronze ingot' => 0, 'steel ingot' => 3 })
          expect(world[:sent]).to eq(['inventory backpack'])
        end

        # A deed for an ingot is a deed (noun-corpus.tsv: "deed for a tin
        # ingot", noun="deed"; the bronze one here is that name with the
        # task's metal), so it is neither counted nor binned.
        it 'does not count a deed for an ingot' do
          stock_world({ 'bronze ingot' => 1, 'deed for a bronze ingot' => 1 })
          expect(build.send(:carried_ingots)).to eq({ 'bronze ingot' => 1, 'steel ingot' => 0 })
        end

        it 'asks twice, then gives nil, when INVENTORY goes unanswered' do
          world = stock_world({ 'bronze ingot' => 2 }, listed: false)
          expect(build.send(:carried_ingots)).to be_nil
          expect(world[:sent]).to eq(['inventory duffel bag'] * 2)
        end
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
        allow(DRCT).to receive(:walk_to).and_return(true)
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
      # The real stock table: buy_metal reads the steel ingot's volume from it.
      let(:shop_stock) { YAML.load_file(File.expand_path('../data/base-crafting.yaml', __dir__), aliases: true)['stock'] }

      # Runs the taskmaster's real task method with buying, crafting, repair and
      # disposal stubbed to record their calls, each with the @remainder flag as
      # it stood then. remainder: the flag before the task.
      # made: how many items forge_item reports (every one when nil).
      def run_task(npc, item, count, volume_per_item, base, type, remainder: false, made: nil)
        tm = build(settings: { forging_tools: ['forging hammer'], forging_belt: forging_belt, engineering_belt: engineering_belt, shaping_tools: ['wood shaper'] },
                   remainder: remainder, stockdata: shop_stock)
        calls = []
        %i[buy_ingots bingots buy_rocks buy_stackables forge_item carve_stone carve_bone shape_item repair trash].each do |step|
          allow(tm).to receive(step) { |*step_args| calls << [step, *step_args, tm.instance_variable_get(:@remainder)] }
        end
        allow(tm).to receive(:forge_item) do |*step_args|
          calls << [:forge_item, *step_args, tm.instance_variable_get(:@remainder)]
          made || count
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
            [5, 2]   => [[:buy_ingots, 1, 'steel'], 'steel', true],
            [2, 4]   => [[:buy_ingots, 1, 'steel'], 'steel', true],
            [1, 1]   => [[:buy_ingots, 1, 'steel'], 'steel', true],
            [1, 7]   => [[:buy_ingots, 1, 'steel'], 'steel', true],
            [1, 9]   => [[:buy_ingots, 1, 'steel'], 'steel', true],
            [2, 6]   => [[:bingots, 1], 'bronze', true],
            # Small items that don't fit in one 10-volume steel ingot: the
            # 50-volume bronze one, not a steel ingot that runs out.
            [11, 1]  => [[:bingots, 1], 'bronze', true],
            [3, 4]   => [[:bingots, 1], 'bronze', true],
            [25, 2]  => [[:bingots, 1], 'bronze', true],
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

          it "counts the bag's ingots before it buys any" do
            tm = build(settings: { forging_tools: [], forging_belt: forging_belt }, stockdata: shop_stock)
            order = []
            allow(tm).to receive(:carried_ingots) { order << :count && { 'bronze ingot' => 1, 'steel ingot' => 0 } }
            allow(tm).to receive(:bingots) { order << :buy }
            allow(tm).to receive(:forge_item) { 3 }
            allow(tm).to receive(:repair)
            allow(tm).to receive(:trash)
            tm.send(npc, 'dagger', 3, 6, 'ingot', 'bronze')
            expect(order).to eq(%i[count buy])
            expect(tm.instance_variable_get(:@ingots_before)).to eq({ 'bronze ingot' => 1, 'steel ingot' => 0 })
          end

          # Forging stopped after 1 of 4 whole bronze ingots: the 3 unused
          # ones are thrown away, since the next run buys for all 3 still owed.
          it 'throws the whole ingots away when forging stops short on a task of one ingot per item' do
            calls = run_task(npc, 'dagger', 4, 5, 'ingot', 'bronze', made: 1)
            expect(calls).to eq([[:buy_ingots, 4, 'bronze', false], [:forge_item, 'dagger', 4, 'bronze', false],
                                 [:repair, ['forging hammer'], forging_belt, true], [:trash, 'dagger', 'ingot', 'bronze', true]])
            expect(run_task(npc, 'dagger', 3, 10, 'ingot', 'bronze', made: 0).last).to eq([:trash, 'dagger', 'ingot', 'steel', true])
          end

          it 'keeps nothing back on an exact bulk ingot that stops short either' do
            expect(run_task(npc, 'dagger', 25, 4, 'ingot', 'bronze', made: 24).last).to eq([:trash, 'dagger', 'ingot', 'bronze', true])
          end

          it 'leaves @remainder alone when forging made every item, or says it made more' do
            expect(run_task(npc, 'dagger', 4, 5, 'ingot', 'bronze', made: 4).last.last).to be(false)
            expect(run_task(npc, 'dagger', 4, 5, 'ingot', 'bronze', made: 5).last.last).to be(false)
          end

          # The real buy-count, trash and dispose path on a full run whose last
          # count went unanswered: craft_each reports 3 of 4, but all 4 whole
          # ingots were used, so the bag holds only the player's 2 and none go.
          it "throws away none of the player's ingots when a full run is undercounted" do
            world = stock_world({ 'steel ingot' => 2 })
            tm = build(settings: { forging_tools: [], forging_belt: forging_belt })
            allow(tm).to receive(:buy_ingots) do |count, _|
              tm.instance_variable_set(:@ingots_bought, count)
              world[:bag]['steel ingot'] += count
            end
            allow(tm).to receive(:forge_item) do
              world[:bag]['steel ingot'] -= 4
              3
            end
            allow(tm).to receive(:repair)
            tm.send(npc, 'dagger', 4, 10, 'ingot', 'bronze')
            expect(DRCT).not_to have_received(:dispose)
            expect(world[:bag]).to eq({ 'steel ingot' => 2 })
          end

          it 'throws away only the unused whole ingots, sparing the player\'s, when forging really stops short' do
            world = stock_world({ 'bronze ingot' => 2 })
            tm = build(settings: { forging_tools: [], forging_belt: forging_belt })
            allow(tm).to receive(:buy_ingots) do |count, _|
              tm.instance_variable_set(:@ingots_bought, count)
              world[:bag]['bronze ingot'] += count
            end
            allow(tm).to receive(:forge_item) do
              world[:bag]['bronze ingot'] -= 1
              1
            end
            allow(tm).to receive(:repair)
            tm.send(npc, 'dagger', 4, 5, 'ingot', 'bronze')
            expect(DRCT).to have_received(:dispose).exactly(3).times
            expect(world[:bag]).to eq({ 'bronze ingot' => 2 })
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

      # Runs the real tailor_item; returns the consumable checks, the sew launches
      # and how many it says it made.
      # Each sew run stows one finished netting in the bag while there is stock
      # for one (stock: how many, every item when nil); a run without stock
      # makes nothing, as sew exits in check_hand once it has studied. The
      # bag also holds the task's netting instructions, which INVENTORY
      # netting lists too.
      def tailor(base, count: 6, marathon: false, stock: nil)
        tm = build(settings: { outfitting_belt: { 'name' => 'toolbelt', 'items' => [] } }, crafting_room: 16_936, marathon: marathon)
        allow(tm).to receive(:get_data).and_return(tailoring)
        allow(DRCT).to receive(:walk_to)
        checks = []
        allow(DRCC).to receive(:check_consumables) { |name, room, number, *rest| checks << [name, room, number, rest.last] }
        bagged = 0
        inventory_replies('inventory duffel bag' => ->(*) { inventoried(['some netting instructions'] + Array.new(bagged, 'some burlap netting')) })
        launches = []
        allow(DRC).to receive(:wait_for_script_to_complete) do |name, args|
          launches << [name, args]
          bagged += 1 if stock.nil? || bagged < stock
        end
        made = tm.tailor_item('netting', count, base, 'burlap')
        [checks, launches, made]
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

      # 2026-11-10 report: with task_crafting_room a rented Andreshlew
      # outfitting room, the thread was checked only after the walk there,
      # so a short spool meant a round trip to the Crossing stock room.
      it 'checks pins and thread before walking to task_crafting_room, while still by the Crossing shops' do
        tm = build(settings: { outfitting_belt: { 'name' => 'toolbelt', 'items' => [] } }, crafting_room: 16_936)
        allow(tm).to receive(:get_data).and_return(tailoring)
        order = []
        allow(DRCC).to receive(:check_consumables) { |name, *| order << [:check, name] }
        allow(DRCT).to receive(:walk_to) { |room| order << [:walk, room] }
        allow(tm).to receive(:craft_each).and_return(0)
        tm.tailor_item('straps', 8, 'leather', 'rat')
        expect(order).to eq([[:check, 'pins'], [:check, 'cotton thread'], [:walk, 16_936]])
      end

      it 'walks to task_crafting_room without a consumable check when knitting' do
        tm = build(settings: { outfitting_belt: { 'name' => 'toolbelt', 'items' => [] } }, crafting_room: 16_936)
        allow(DRCC).to receive(:check_consumables)
        allow(DRCT).to receive(:walk_to)
        allow(tm).to receive(:craft_each).and_return(0)
        tm.tailor_item('outfit', 2, 'yarn', 'wool')
        expect(DRCC).not_to have_received(:check_consumables)
        expect(DRCT).to have_received(:walk_to).with(16_936)
      end

      it 'tells every sew run to skip its own consumable check' do
        _, launches = tailor('cloth', count: 3)
        expect(launches.size).to eq(3)
        expect(launches).to all(satisfy { |name, args| name == 'sew' && args.include?('skip') })
      end

      # Barrask, 2026-11-04: a 6-netting task with 10 of the 60 yards. Run 1
      # made one netting; runs 2-6 each studied (one instruction use each),
      # found no burlap and exited, and taskmaster said "6 nettings completed".
      it 'stops launching sew after the first run that made nothing, when there is stock for only one of six' do
        _, launches, made = tailor('cloth', count: 6, stock: 1)
        expect(launches.size).to eq(2)
        expect(made).to eq(1)
      end

      it 'says how many were made of how many, never that all six were completed' do
        tailor('cloth', count: 6, stock: 1)
        expect(DRC).to have_received(:message).with('Made 1 of 6 nettings: no new netting in duffel bag or in hand after the last sew run, so no more runs.')
        expect(DRC).not_to have_received(:message).with('6 nettings completed')
      end

      it 'launches sew only once when the very first run makes nothing' do
        _, launches = tailor('cloth', count: 6, stock: 0)
        expect(launches.size).to eq(1)
        expect(DRC).to have_received(:message).with('Made 0 of 6 nettings: no new netting in duffel bag or in hand after the last sew run, so no more runs.')
      end

      it 'counts from what the bag already held: nettings left from before the task are not made by this one' do
        tm = build(settings: { outfitting_belt: { 'name' => 'toolbelt', 'items' => [] } }, crafting_room: 16_936)
        allow(tm).to receive(:get_data).and_return(tailoring)
        allow(DRCT).to receive(:walk_to)
        allow(DRCC).to receive(:check_consumables)
        inventory_replies('inventory duffel bag' => inventoried(Array.new(3, 'some burlap netting') + ['some netting instructions']))
        launches = 0
        allow(DRC).to receive(:wait_for_script_to_complete) { launches += 1 }
        expect(tm.tailor_item('netting', 4, 'cloth', 'burlap')).to eq(0)
        expect(launches).to eq(1)
      end

      it 'reports every item when every run made one' do
        _, launches, made = tailor('leather', count: 4)
        expect(launches.size).to eq(4)
        expect(made).to eq(4)
        expect(DRC).to have_received(:message).with('4 nettings completed')
      end

      # The last study uses up the instructions, so the run that makes the
      # last netting also takes "some netting instructions" out of the bag.
      # Counting every " netting" in the reply saw no change on that run.
      it 'counts the last netting as made when that run also used up the instructions' do
        tm = build(settings: { outfitting_belt: { 'name' => 'toolbelt', 'items' => [] } }, crafting_room: 16_936)
        allow(tm).to receive(:get_data).and_return(tailoring)
        allow(DRCT).to receive(:walk_to)
        allow(DRCC).to receive(:check_consumables)
        bagged = 0
        uses = 6
        inventory_replies('inventory duffel bag' => lambda do |*|
          inventoried(Array.new(bagged, 'some reinforced cloth netting') + (uses.positive? ? ['some netting instructions'] : []))
        end)
        launches = 0
        allow(DRC).to receive(:wait_for_script_to_complete) do
          launches += 1
          uses -= 1
          bagged += 1
        end
        expect(tm.tailor_item('netting', 6, 'cloth', 'reinforced')).to eq(6)
        expect(launches).to eq(6)
        expect(DRC).to have_received(:message).with('6 nettings completed')
        expect(DRC).not_to have_received(:message).with(/^Made 5 of 6/)
      end

      it 'counts none made when the bag lists the same unfinished netting, instructions and netting after the run' do
        tm = build(settings: { outfitting_belt: { 'name' => 'toolbelt', 'items' => [] } }, crafting_room: 16_936)
        allow(tm).to receive(:get_data).and_return(tailoring)
        allow(DRCT).to receive(:walk_to)
        allow(DRCC).to receive(:check_consumables)
        inventory_replies('inventory duffel bag' => inventoried(['an unfinished burlap netting', 'some netting instructions', 'some burlap netting']))
        launches = 0
        allow(DRC).to receive(:wait_for_script_to_complete) { launches += 1 }
        expect(tm.tailor_item('netting', 3, 'cloth', 'burlap')).to eq(0)
        expect(launches).to eq(1)
      end

      context 'when INVENTORY gets no reply' do
        # Like tailor, but issue_command returns no lines (no reply within
        # its timeout) for the INVENTORY calls numbered in `missed`; call 1 is the
        # count before the first run. The bag starts with `old` nettings from
        # before the task. Returns how many tailor_item says it made and the
        # sew launches.
        def tailor_missing(missed, count: 6, stock: nil, old: 0)
          tm = build(settings: { outfitting_belt: { 'name' => 'toolbelt', 'items' => [] } }, crafting_room: 16_936)
          allow(tm).to receive(:get_data).and_return(tailoring)
          allow(DRCT).to receive(:walk_to)
          allow(DRCC).to receive(:check_consumables)
          listings = 0
          bagged = 0
          inventory_replies('inventory duffel bag' => lambda do |*|
            listings += 1
            next [] if missed.include?(listings)

            inventoried(['some netting instructions'] + Array.new(old + bagged, 'some burlap netting'))
          end)
          launches = 0
          allow(DRC).to receive(:wait_for_script_to_complete) do
            launches += 1
            bagged += 1 if stock.nil? || bagged < stock
          end
          [tm.tailor_item('netting', count, 'cloth', 'burlap'), launches]
        end

        # Counting the first miss as none started from 0 against 3 old
        # nettings: "Made 4 of 6" after one netting was made.
        it 'does not count the 3 nettings already in the bag as made when the first INVENTORY got no reply' do
          made, launches = tailor_missing([1], stock: 1, old: 3)
          expect(made).to eq(1)
          expect(launches).to eq(2)
          expect(DRC).to have_received(:message).with('Made 1 of 6 nettings: no new netting in duffel bag or in hand after the last sew run, so no more runs.')
        end

        it 'launches no sew run, and says why, when the count before the first run gets no reply twice' do
          made, launches = tailor_missing([1, 2])
          expect(made).to eq(0)
          expect(launches).to eq(0)
          expect(DRC).to have_received(:message).with('Could not count the nettings in duffel bag (no reply to INVENTORY), so no sew runs.')
        end

        # Counting the miss as none after run 2 stopped a task where every
        # run made one: "the last sew run made none" after 2 of 6.
        it 'keeps sewing when one INVENTORY after a good run got no reply' do
          made, launches = tailor_missing([3])
          expect(made).to eq(6)
          expect(launches).to eq(6)
          expect(DRC).to have_received(:message).with('6 nettings completed')
        end

        it 'judges the run by the next count when the count after it gets no reply twice' do
          made, launches = tailor_missing([3, 4])
          expect(made).to eq(6)
          expect(launches).to eq(6)
        end

        it 'still stops, one run late, when the uncounted run was followed by one that made none' do
          made, launches = tailor_missing([3, 4], stock: 2)
          expect(made).to eq(2)
          expect(launches).to eq(4)
        end

        it 'counts again after the last run when its count got no reply twice' do
          made, launches = tailor_missing([7, 8])
          expect(made).to eq(6)
          expect(launches).to eq(6)
          expect(DRC).to have_received(:message).with('6 nettings completed')
        end

        it 'says the count is short, not that a run made none, when the last run never got a count' do
          made, launches = tailor_missing([7, 8, 9, 10])
          expect(made).to eq(5)
          expect(launches).to eq(6)
          expect(DRC).to have_received(:message).with('Counted 5 of 6 nettings made (INVENTORY did not answer after every sew run).')
        end
      end

      context 'with what the run left in hand' do
        # One sew run that leaves `left` in the right hand and nothing new in
        # the bag; returns how many tailor_item says it made, the launches and
        # the commands sent. `left` is [hand text, noun, full name]: GameObj
        # has the short hand text and the game's noun ("reinforced netting",
        # netting), only GLANCE the full name, so only GLANCE says
        # "unfinished". glance: GLANCE's reply instead of the game's.
        def run_leaving(left, count: 2, glance: nil)
          tm = build(settings: { outfitting_belt: { 'name' => 'toolbelt', 'items' => [] } }, crafting_room: 16_936)
          allow(tm).to receive(:get_data).and_return(tailoring)
          allow(DRCT).to receive(:walk_to)
          allow(DRCC).to receive(:check_consumables)
          inventory_replies('inventory duffel bag' => inventoried(['some netting instructions']))
          text, noun, full = left
          right = nil
          empty = OpenStruct.new(name: 'Empty', noun: nil, id: nil)
          allow(GameObj).to receive(:right_hand) { right ? OpenStruct.new(name: text, noun: noun, id: '758810') : empty }
          allow(GameObj).to receive(:left_hand).and_return(empty)
          allow(DRC).to receive(:right_hand) { right && text }
          allow(DRC).to receive(:left_hand).and_return(nil)
          sent = []
          allow(DRC).to receive(:bput) do |command, *|
            sent << command
            next 'Roundtime' unless command == 'glance'

            glance || "You glance down to see #{full} in your right hand and nothing in your left hand."
          end
          launches = 0
          allow(DRC).to receive(:wait_for_script_to_complete) do
            launches += 1
            right = true if launches == 1
          end
          [tm.tailor_item('netting', count, 'cloth', 'burlap'), launches, sent]
        end

        it 'counts a finished netting the bag would not take, still in hand, as made' do
          expect(run_leaving(['reinforced netting', 'netting', 'some burlap reinforced netting']).first(2)).to eq([1, 2])
        end

        it 'does not count an unfinished netting in hand as made, though its hand text is the finished one\'s' do
          expect(run_leaving(['reinforced netting', 'netting', 'some unfinished burlap reinforced netting']).first(2)).to eq([0, 1])
        end

        it 'does not count a held item whose name only contains the noun' do
          made, launches, sent = run_leaving(['netting instructions', 'instructions', 'some netting instructions'])
          expect([made, launches]).to eq([0, 1])
          expect(sent).not_to include('glance')
        end

        it 'goes by the noun GameObj gives the hand, not the last word of its name' do
          tm = build
          inventory_replies('inventory duffel bag' => inventoried([]))
          bundle = OpenStruct.new(name: 'lumpy bundle bound by a braided bundling rope', noun: 'bundle', id: '758811')
          allow(GameObj).to receive(:right_hand).and_return(bundle)
          allow(GameObj).to receive(:left_hand).and_return(OpenStruct.new(name: 'Empty', noun: nil, id: nil))
          allow(DRC).to receive(:right_hand).and_return('lumpy rope') # lich-5 DRC.right_hand: first and last word
          allow(DRC).to receive(:bput).and_return('You glance down to see a lumpy bundle bound by a braided bundling rope in your right hand and nothing in your left hand.')
          expect(tm.finished_count('rope')).to eq(0)
          expect(tm.finished_count('bundle')).to eq(1)
        end

        # Real GLANCE replies (2026-09 logs) that do not show the netting in
        # the right hand GameObj gives it: the hands empty, or only
        # something else in the left one.
        ['You glance down at your empty hands.',
         'You glance down to see some burnt incense in your left hand.'].each do |reply|
          it "does not count a held item of the noun when GLANCE answers \"#{reply}\"" do
            expect(run_leaving(['reinforced netting', 'netting', 'some burlap reinforced netting'], glance: reply).first(2)).to eq([0, 1])
          end
        end

        it 'does not count a held item of the noun when GLANCE goes unanswered' do
          expect(run_leaving(['reinforced netting', 'netting', 'some burlap reinforced netting'], glance: '').first(2)).to eq([0, 1])
        end
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

    describe '#forge_item' do
      # Runs the real forge_item in the task_crafting_room with metal for
      # `metal` daggers; each forge run that has metal leaves a dagger the
      # put then bags. Returns how many it says it made and the forge runs.
      def forge(count, metal)
        tm = build(crafting_room: 16_936)
        allow(DRCT).to receive(:walk_to)
        allow(DRCC).to receive(:clean_anvil?).and_return(true)
        bagged = 0
        held = false
        runs = 0
        allow(DRC).to receive(:wait_for_script_to_complete) do
          runs += 1
          held = runs <= metal
        end
        inventory_replies('inventory duffel bag' => ->(*) { inventoried(['some dagger instructions'] + Array.new(bagged, 'a bronze dagger')) })
        allow(DRC).to receive(:bput) do |command, *|
          # bput returns '' on "What were you referring to?", which it does not list.
          next '' unless command == 'put my dagger in my duffel bag' && held

          held = false
          bagged += 1
          'You put your bronze dagger in your heavy silk duffel bag.'
        end
        [tm.forge_item('dagger', count, 'bronze'), runs]
      end

      it 'stops after the first forge run that made nothing' do
        expect(forge(5, 2)).to eq([2, 3])
        expect(DRC).to have_received(:message).with('Made 2 of 5 daggers: no new dagger in duffel bag or in hand after the last forge run, so no more runs.')
      end

      it 'forges every item while there is metal' do
        expect(forge(3, 3)).to eq([3, 3])
        expect(DRC).to have_received(:message).with('3 daggers completed')
      end

      # The Poltu trunk task (Hollow Eve 2026, taskmaster 2026.11.10.4):
      # forge left the trunk in hand, taskmaster put it in the bag, and
      # INVENTORY listed it as "a heavy bronze waterproof trunk (closed)".
      # get_noun reads no noun off that line, so the first run was judged to
      # have made none: "Made 0 of 3 trunks", and no more runs.
      it 'counts a trunk INVENTORY lists as closed as made, and forges the rest' do
        tm = build(crafting_room: 16_936)
        allow(DRCT).to receive(:walk_to)
        allow(DRCC).to receive(:clean_anvil?).and_return(true)
        bagged = 0
        held = false
        runs = 0
        allow(DRC).to receive(:wait_for_script_to_complete) do
          runs += 1
          held = true
        end
        inventory_replies('inventory duffel bag' => ->(*) { inventoried(Array.new(bagged, 'a heavy bronze waterproof trunk (closed)') + ['some waterproof trunk instructions']) })
        allow(DRC).to receive(:bput) do |command, *|
          next '' unless command == 'put my trunk in my duffel bag' && held

          held = false
          bagged += 1
          'You put your trunk in your heavy silk duffel bag.'
        end
        expect([tm.forge_item('trunk', 3, 'bronze'), runs]).to eq([3, 3])
        expect(DRC).to have_received(:message).with('3 trunks completed')
      end
    end

    describe '#shape_item' do
      it 'stops after the first shape run that made nothing' do
        tm = build
        allow(DRCC).to receive(:find_shaping_room)
        bagged = 0
        inventory_replies('inventory duffel bag' => ->(*) { inventoried(Array.new(bagged, 'a balsa bowl') + ['some bowl instructions']) })
        runs = 0
        allow(DRC).to receive(:wait_for_script_to_complete) do
          runs += 1
          bagged += 1 if runs == 1
        end
        expect(tm.shape_item('bowl', 4, 'lumber', 'balsa')).to eq(1)
        expect(runs).to eq(2)
        expect(DRC).to have_received(:message).with('Made 1 of 4 bowls: no new bowl in duffel bag or in hand after the last shape run, so no more runs.')
      end
    end

    describe '#restock (marathon)' do
      # Stock prices and order numbers mirroring data/base-crafting.yaml.
      let(:stockdata) do
        { 'burlap' => { 'stock-value' => 437, 'stock-number' => 8 }, 'rat' => { 'stock-value' => 750, 'stock-number' => 2 },
          'yarn' => { 'stock-value' => 625, 'stock-number' => 13 }, 'thread' => { 'stock-value' => 971, 'stock-number' => 6 } }
      end

      # What each order number brings in, by the name TAP and COUNT use.
      let(:ordered) { { 8 => ['burlap cloth', 10], 2 => ['rat leather', 10], 13 => ['wool yarn', 100], 6 => ['cotton thread', 100] } }

      # The crafting bag's stock and the shop, for the real restock with the
      # script's own stack map. carried: yards carried of each stock by name
      # (none of any other); reached: whether the walk to the shop works
      # (order_item returns nil and nothing comes in when it does not, as on
      # 2026-11-10); missed: stocks whose first TAP after an order goes
      # unanswered. Returns the world; :orders records every order placed.
      def restock_world(tm, carried: {}, reached: true, missed: [])
        world = { orders: [], carried: Hash.new(0).merge(carried), missed: missed.dup }
        allow(tm).to receive(:get_data).and_return({ 'tailoring' => { 'Crossing' => { 'tool-room' => 16667 } } })
        allow(tm).to receive(:exchange_coins)
        allow(tm).to receive(:top_up_copper)
        allow(DRCC).to receive(:check_consumables)
        allow(DRCI).to receive(:exists?) do |name|
          next false if world[:orders].any? && world[:missed].delete(name)

          world[:carried][name].positive?
        end
        allow(DRCT).to receive(:walk_to)
        allow(DRCT).to receive(:order_item) do |room, number|
          world[:orders] << [room, number]
          next nil unless reached

          name, yards = ordered.fetch(number)
          world[:carried][name] += yards
          'The clerk takes some coins from you'
        end
        allow(DRC).to receive(:bput) do |command, *|
          name = command[/\Acount my (.+)\z/, 1]
          name ? "You count out #{world[:carried][name]} yards of material" : 'You combine'
        end
        allow(DRCC).to receive(:stow_crafting_item)
        world
      end

      # Runs the real restock from an empty bag, recording every order placed.
      def restock_orders(tm = build(stockdata: stockdata))
        world = restock_world(tm)
        tm.restock
        world[:orders]
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

      describe 'what it got none of' do
        # Fizzlestiks' bag before the 2026-11-10 23:11 restock: no burlap
        # cloth, 20 yards of rat leather, 84 of wool yarn, 400 of cotton
        # thread.
        let(:fizzlestiks_bag) { { 'rat leather' => 20, 'wool yarn' => 84, 'cotton thread' => 400 } }

        it 'is nothing when every stock it ordered came in' do
          tm = build(stockdata: stockdata)
          world = restock_world(tm, carried: fizzlestiks_bag)

          expect(tm.restock).to eq([])
          expect(world[:carried]).to include('burlap cloth' => 100, 'rat leather' => 100, 'wool yarn' => 384, 'cotton thread' => 400)
        end

        it 'is every stock it ordered when the shop could not be reached, as on 2026-11-10' do
          tm = build(stockdata: stockdata)
          world = restock_world(tm, carried: fizzlestiks_bag, reached: false)

          expect(tm.restock).to eq(%w[cloth leather yarn])
          expect(world[:orders].map(&:last).tally).to eq(8 => 10, 2 => 8, 13 => 3)
        end

        it 'asks again before calling a stock it got none of, so one missed TAP does not stop the run' do
          tm = build(stockdata: stockdata)
          world = restock_world(tm, carried: fizzlestiks_bag, missed: ['burlap cloth'])

          expect(tm.restock).to eq([])
          # The missed TAP was asked.
          expect(world[:missed]).to be_empty
        end

        it 'is nothing, with nothing counted again, when no stock was short' do
          tm = build(stockdata: stockdata)
          world = restock_world(tm, carried: { 'burlap cloth' => 100, 'rat leather' => 95, 'wool yarn' => 400, 'cotton thread' => 350 })

          expect(tm.restock).to eq([])
          expect(world[:orders]).to be_empty
          expect(DRC).to have_received(:bput).with(/\Acount my /, any_args).exactly(4).times
        end
      end
    end

    describe '#still_short?' do
      it 'asks check_stock once more before calling a stock short' do
        tm = build
        answers = [false, true]
        allow(tm).to receive(:check_stock) { answers.shift }

        expect(tm.still_short?(8, 'burlap', 'cloth')).to be(false)
        expect(tm).to have_received(:check_stock).with(8, 'burlap', 'cloth').twice
      end

      it 'calls it short when both answers say so, and asks once when the first says enough' do
        tm = build
        allow(tm).to receive(:check_stock).and_return(false)
        expect(tm.still_short?(8, 'burlap', 'cloth')).to be(true)

        tm = build
        allow(tm).to receive(:check_stock).and_return(true)
        expect(tm.still_short?(8, 'burlap', 'cloth')).to be(false)
        expect(tm).to have_received(:check_stock).once
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
      # keeps the new piece's id instead of the stack's. new_id_combine (the default, as in game): the
      # combined stack comes back under an id neither had. hollow_combine:
      # COMBINE answers "You combine" but both pieces stay in hand.
      # silent_combine: COMBINE goes unanswered (bput's ''). silent_count: the
      # first that many COUNTs go unanswered (Float::INFINITY for all).
      # count_text: COUNT answers with this line instead of the yards.
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
               refuse_combine: false, keep_new: false, new_id_combine: true, hollow_combine: false, silent_combine: false,
               silent_count: 0, count_text: nil)
        world = { hands: { right: nil, left: nil }.merge(hands), bag: [], orders: [], sent: [], sold: 0, asked: false, silenced: 0 }
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
            next '' if (world[:silenced] += 1) <= silent_count
            next count_text if count_text

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

      it 'trusts the hands, taking each new piece as bought, when every order comes back empty after paying' do
        world = shop(late_from: 0)

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.not_to raise_error
        expect(DRC).not_to have_received(:message).with(/Could not buy/)
        expect(world[:orders].size).to eq(6)
        expect(world[:hands].values.compact).to be_empty
        expect(bagged(world, 'burlap cloth')).to eq([60])
      end

      it 'takes the piece in hand as bought when only the last order comes back empty, and bags one 60-yard stack' do
        world = shop(late_from: 5)

        buyer.buy_stackables('rope', 6, 10, 'cloth')

        expect(world[:orders].size).to eq(6)
        expect(world[:sent].grep(/\Aput #/).size).to eq(1)
        expect(bagged(world, 'burlap cloth')).to eq([60])
      end

      it 'still stops, saying the order did not go through, when an order comes back empty and no new piece is in hand' do
        world = shop(late_from: 0, lost: true)

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/Could not buy burlap cloth: the order did not go through/)
        expect(world[:orders].size).to eq(1)
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
        world = shop(keep_new: true, new_id_combine: false)

        buyer.buy_stackables('rope', 3, 10, 'cloth')

        expect(bagged(world, 'burlap cloth')).to eq([30])
      end

      it 'follows the stack, counts it and bags it, when "You combine" leaves one id neither piece had' do
        world = shop(new_id_combine: true)

        expect { buyer.buy_stackables('rope', 3, 10, 'cloth') }.not_to raise_error

        expect(world[:sent]).to include('combine #3000003 with #3000004', 'count #3000005', 'put #3000005 in my duffel bag')
        expect(world[:sent].grep(/\Acombine \w+\z/)).to be_empty
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
          .with(/Could not buy burlap cloth: the order did not go through.*\. #3000003 would not go back in your duffel bag and is still in your hands; put it away before starting again\. Stopping\./)
        expect(world[:hands].values.compact.map(&:yards)).to eq([20])
      end

      it 'names nothing as left in hand when every put-back on a stop goes through' do
        shop(refuse_after: 2)

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/\A[^#]*full hands\)\. Stopping\.\z/)
      end

      it 'trusts the hands when a combine goes unanswered but one id, the stack under its new id, is all that is held' do
        world = shop(silent_combine: true)

        buyer.buy_stackables('rope', 2, 10, 'cloth')

        expect(bagged(world, 'burlap cloth')).to eq([20])
      end

      it 'follows the stack when the game keeps the stack\'s own id' do
        world = shop(new_id_combine: false)

        buyer.buy_stackables('rope', 3, 10, 'cloth')

        expect(bagged(world, 'burlap cloth')).to eq([30])
        expect(world[:hands].values.compact).to be_empty
      end

      it 'counts the stack by id and stops, saying how much is missing, when it is short' do
        world = shop(yards: 5)

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.to raise_error(SystemExit)
        expect(world[:sent]).to include(a_string_matching(/\Acount #\d+\z/))
        expect(DRC).to have_received(:message).with(/Bought 30 yards of burlap cloth, but the task needs 60: 30 yards missing/)
        expect(bagged(world, 'burlap cloth')).to eq([30])
      end

      it 'asks COUNT twice, never a third time, then goes ahead uncounted, saying so, when COUNT goes unanswered' do
        world = shop(silent_count: Float::INFINITY)

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.not_to raise_error
        expect(world[:sent].grep(/\Acount #/).size).to eq(2)
        expect(DRC).to have_received(:message)
          .with(/\ACould not count the burlap cloth \(#\d+\): COUNT went unanswered twice\. Going ahead uncounted; the task needs 60 yards\.\z/)
        expect(DRC).not_to have_received(:message).with(/Bought \d+ yards/)
        expect(bagged(world, 'burlap cloth')).to eq([60])
        expect(world[:hands].values.compact).to be_empty
      end

      it 'goes on the second COUNT\'s answer, without saying it was not counted, when only the first goes unanswered' do
        world = shop(silent_count: 1)

        buyer.buy_stackables('rope', 6, 10, 'cloth')

        expect(world[:sent].grep(/\Acount #/).size).to eq(2)
        expect(DRC).not_to have_received(:message).with(/Could not count/)
        expect(bagged(world, 'burlap cloth')).to eq([60])
      end

      it 'still stops on a short count that only the second COUNT answers' do
        world = shop(silent_count: 1, yards: 5)

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/Bought 30 yards of burlap cloth, but the task needs 60: 30 yards missing/)
        expect(bagged(world, 'burlap cloth')).to eq([30])
      end

      it 'stops on a COUNT in other wording, quoting it, without asking again or going ahead, even when the stack is short' do
        world = shop(yards: 5, count_text: 'You count out 30 pieces of material there.')

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.to raise_error(SystemExit)
        expect(world[:sent].grep(/\Acount #/).size).to eq(1)
        expect(DRC).to have_received(:message)
          .with(/\ACould not read the count of the burlap cloth you bought \(#\d+\): the game said "You count out 30 pieces of material there\.", not yards\. Not starting the task\. Stopping\.\z/)
        expect(DRC).not_to have_received(:message).with(/Going ahead|unanswered/)
        expect(bagged(world, 'burlap cloth')).to eq([30])
      end

      it 'stops on a COUNT in other wording even when the stack is in fact long enough' do
        world = shop(count_text: 'You count out 60 pieces of material there.')

        expect { buyer.buy_stackables('rope', 6, 10, 'cloth') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with(/the game said "You count out 60 pieces of material there\.", not yards/)
        expect(bagged(world, 'burlap cloth')).to eq([60])
      end

      it 'stops on "That doesn\'t tell you much", quoting it, rather than reading it as no answer' do
        world = shop(hands: { right: leftover_leather }, count_text: "That doesn't tell you much of anything.")

        expect { buyer.check_yards('2222485', 10, 'rat leather') }.to raise_error(SystemExit)
        expect(world[:sent].grep(/\Acount #/).size).to eq(1)
        expect(DRC).to have_received(:message).with(/the game said "That doesn't tell you much of anything\.", not yards/)
        expect(DRC).not_to have_received(:message).with(/Going ahead/)
      end

      it 'stops, naming the id, without asking again, when COUNT cannot find the stack' do
        world = shop

        expect { buyer.check_yards('9999999', 60, 'burlap cloth') }.to raise_error(SystemExit)
        expect(world[:sent].grep(/\Acount #/)).to eq(['count #9999999'])
        expect(DRC).to have_received(:message).with(/\ACould not find the burlap cloth you bought \(#9999999\) to count it\. Not starting the task\. Stopping\.\z/)
        expect(DRC).not_to have_received(:message).with(/Going ahead/)
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

      # Fizzlestiks, 2026-11-10: the GET took the character's own bundling
      # rope, and each of five gives waited out bput's 15 s on Zasele's reply.
      context 'when the taskmaster says the character did not make the item' do
        it 'puts it back and stops at once, instead of giving it again' do
          tm = finisher
          allow(DRCC).to receive(:stow_crafting_item)
          messages = []
          allow(DRC).to receive(:message) { |text| messages << text }
          state = giving([more_needed(1), not_made_by_you])

          expect { tm.complete_task('rope', 2) }.to raise_error(SystemExit)

          expect(state[:gets]).to eq(2)
          expect(DRC).to have_received(:bput).with('give my rope to zasele', any_args).twice
          expect(DRCC).to have_received(:stow_crafting_item).with('rope', 'duffel bag', nil).once
          expect(messages).to eq(['Zasele only takes a rope you made, and the rope from your duffel bag was not one, so it is back in your duffel bag.',
                                  "Stopping; the task stays open. Keep your own ropes out of your duffel bag while on Zasele's tasks."])
          expect(tm).not_to have_received(:sort_sack)
        end

        it "matches Zasele's reply as logged, and as bput hands it back, and is one of the replies every GIVE waits for" do
          expect(not_made_by_you).to match(TaskMaster::GIVE_NOT_MADE_BY_YOU)
          expect(not_made_by_you[TaskMaster::GIVE_NOT_MADE_BY_YOU]).to match(TaskMaster::GIVE_NOT_MADE_BY_YOU)
          expect(TaskMaster::GIVE_REPLIES).to include(TaskMaster::GIVE_NOT_MADE_BY_YOU)
        end

        it 'does not match a player saying the words' do
          expect(%(Mallory says, "It needs to be something that you made.")).not_to match(TaskMaster::GIVE_NOT_MADE_BY_YOU)
          expect(%(Mallory says, "#{not_made_by_you}")).not_to match(TaskMaster::GIVE_NOT_MADE_BY_YOU)
        end
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

      it 'exits when the bag runs out of items, saying the task is not finished' do
        tm = finisher
        allow(DRCI).to receive(:in_hands?).and_return(false)
        allow(DRCI).to receive(:get_item?).and_return(false)
        expect { tm.complete_task('rope', 2) }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with('Could not get another rope to hand in and the task is not finished, stopping.')
      end
    end

    describe '#give_item answering "Don\'t be silly."' do
      let(:silly) { "Don't be silly." }
      let(:rope) { OpenStruct.new(name: 'burlap rope', noun: 'rope', id: '3758858') }
      let(:leather) { OpenStruct.new(name: 'rat-pelt leather', noun: 'leather', id: '2222485') }
      let(:empty_hand) { OpenStruct.new(name: 'Empty', noun: nil, id: nil) }

      # Zasele at the hand-in. named: replies to "give my rope to zasele"
      # (the game sends "You don't need to specify the object - GIVE <person>
      # assumes you mean to give the object in your right hand!" before each
      # "Don't be silly."; bput returns only the matched line);
      # bare: replies to "give zasele", which hands over whatever is in the
      # right hand. A taken rope leaves the hand; swap: whether SWAP moves
      # the hands. Returns :sent (commands), :handed (what Zasele got) and
      # :hands.
      def zasele(named:, bare: [], right: nil, left: nil, swap: true)
        world = { sent: [], handed: [], hands: { right: right, left: left } }
        allow(GameObj).to receive(:right_hand) { world[:hands][:right] || empty_hand }
        allow(GameObj).to receive(:left_hand) { world[:hands][:left] || empty_hand }
        allow(DRCI).to receive(:in_hands?) { |noun| world[:hands].values.compact.any? { |obj| obj.noun == noun } }
        allow(DRCI).to receive(:get_item?).and_return(false)
        take = lambda do |reply, side|
          if reply.match?(TaskMaster::TURN_IN_MORE_NEEDED) || reply.include?('hands you a')
            world[:handed] << world[:hands][side]
            world[:hands][side] = nil
          end
          reply
        end
        allow(DRC).to receive(:bput) do |command, *_|
          world[:sent] << command
          case command
          when 'give my rope to zasele'
            reply = named.shift || silly
            reply == silly ? silly : take.call(reply, world[:hands].key(rope) || :right)
          when 'give zasele'
            take.call(bare.shift || silly, :right)
          when 'swap'
            world[:hands][:right], world[:hands][:left] = world[:hands][:left], world[:hands][:right] if swap
            'You move a burlap rope to your right hand.'
          else
            ''
          end
        end
        world
      end

      def giver
        tm = build
        allow(tm).to receive(:find_npc)
        allow(tm).to receive(:pause)
        allow(tm).to receive(:sort_sack)
        allow(tm).to receive(:fput)
        tm
      end

      it 'hands the rope over from the right hand with a bare GIVE ZASELE, at once' do
        tm = giver
        world = zasele(named: [silly], bare: [more_needed(1)], right: rope)

        expect(tm.give_item('rope')).to eq(more_needed(1))

        expect(world[:sent]).to eq(['give my rope to zasele', 'give zasele'])
        expect(world[:handed]).to eq([rope])
        expect(tm).not_to have_received(:pause)
      end

      it 'swaps the rope into the right hand first when it is in the left' do
        tm = giver
        world = zasele(named: [silly], bare: [more_needed(1)], right: leather, left: rope)

        tm.give_item('rope')

        expect(world[:sent]).to eq(['give my rope to zasele', 'swap', 'give zasele'])
        expect(world[:handed]).to eq([rope])
        expect(world[:hands][:left]).to eq(leather)
      end

      it 'never sends a bare GIVE while the right hand holds something else (Zasele keeps what she is given)' do
        tm = giver
        world = zasele(named: Array.new(70, silly), right: leather, left: rope, swap: false)

        reply = tm.give_item('rope')

        expect(world[:sent]).not_to include('give zasele')
        expect(world[:handed]).to be_empty
        expect(reply).to eq(silly)
      end

      it 'tries both gives again after a pause while the bare GIVE is refused too, then hands the rope in' do
        tm = giver
        world = zasele(named: [silly, silly], bare: [silly, more_needed(1)], right: rope)

        expect(tm.give_item('rope')).to eq(more_needed(1))

        expect(world[:sent]).to eq(['give my rope to zasele', 'give zasele', 'give my rope to zasele', 'give zasele'])
        expect(tm).to have_received(:pause).with(TaskMaster::GIVE_NOT_NOW_PAUSE).once
        expect(DRC).to have_received(:message).with(/answered "Don't be silly\." to the rope from the right hand too/).once
      end

      it 'waits at most GIVE_NOT_NOW_MAX_WAIT in all across complete_task\'s retries, then stops' do
        tm = giver
        allow(DRCC).to receive(:stow_crafting_item)
        zasele(named: Array.new(500, silly), bare: Array.new(500, silly), right: rope)

        expect { tm.complete_task('rope', 2) }.to raise_error(SystemExit)

        expect(tm).to have_received(:pause).exactly(TaskMaster::GIVE_NOT_NOW_MAX_WAIT / TaskMaster::GIVE_NOT_NOW_PAUSE).times
        expect(DRC).to have_received(:message).with("Zasele did not take the rope (#{silly}). Stopping.")
      end

      it 'starts the wait over after a give is taken' do
        tm = giver
        zasele(named: [silly, silly, more_needed(1)], bare: [silly, silly], right: rope)

        tm.give_item('rope')

        expect(tm.instance_variable_get(:@not_now_waited)).to eq(0)
      end
    end

    describe 'an item Zasele says is not made well enough' do
      # Mahtra, 2026-11-10 22:21:10 NZDT: an unfinished netting a lagged sew
      # left in the duffel bag on 2026-11-06 sat first in the bag, so every
      # hand-in took it, Zasele turned it down, and the task stopped.
      let(:not_good_enough) do
        'Seamstress Zasele inspects the reinforced netting and frowns uncomfortably.  She writes, "I\'m sorry, but this could be done better.  ' \
          'Perhaps consider materials that are easier for you to work with or simply practice more.  This must be well-crafted or better to be useful to those I assist."'
      end
      let(:silly) { "Don't be silly." }
      let(:empty_hand) { OpenStruct.new(name: 'Empty', noun: nil, id: nil) }

      def netting(id, finished: true)
        OpenStruct.new(name: "#{finished ? '' : 'unfinished '}burlap reinforced netting", noun: 'netting', id: id.to_s, finished: finished)
      end

      # The duffel bag, first item first (a GET takes the first), the hands,
      # and Zasele. As on the log, the named GIVE gets "Don't be silly." and
      # the bare GIVE ZASELE hands over the right hand. She takes a finished
      # netting (owed counts down, the last one brings the sack) and turns
      # an unfinished one down, leaving it in hand. DRCI.dispose_trash with
      # a "#id" bins the held item of that id. Returns :sent, :handed,
      # :binned and :bag.
      def zasele_world(bag:, owed:, trash_works: true)
        world = { sent: [], handed: [], binned: [], bag: bag, hands: { right: nil, left: nil }, owed: owed }
        allow(GameObj).to receive(:right_hand) { world[:hands][:right] || empty_hand }
        allow(GameObj).to receive(:left_hand) { world[:hands][:left] || empty_hand }
        allow(DRCI).to receive(:in_hands?) { |noun| world[:hands].values.compact.any? { |obj| obj.noun == noun } }
        allow(DRCI).to receive(:get_item?).with('netting', 'duffel bag') do
          next false if world[:bag].empty?

          world[:hands][:right] = world[:bag].shift
          true
        end
        allow(DRCI).to receive(:dispose_trash) do |ref, *|
          held = world[:hands].keys.find { |side| world[:hands][side] && "##{world[:hands][side].id}" == ref }
          next false unless trash_works && held

          world[:binned] << world[:hands][held]
          world[:hands][held] = nil
          true
        end
        allow(DRCC).to receive(:stow_crafting_item) do |*|
          world[:bag].unshift(world[:hands][:right]) if world[:hands][:right]
          world[:hands][:right] = nil
        end
        allow(DRC).to receive(:bput) do |command, *_|
          world[:sent] << command
          case command
          when 'give my netting to zasele'
            silly
          when 'give zasele'
            held = world[:hands][:right]
            if held.nil?
              "What is it you're trying to give?"
            elsif !held.finished
              not_good_enough
            else
              world[:handed] << held
              world[:hands][:right] = nil
              world[:owed] -= 1
              world[:owed].zero? ? 'Zasele hands you a woven sack.' : more_needed(world[:owed])
            end
          else
            ''
          end
        end
        world
      end

      def hander(**ivars)
        tm = build(worn_trashcan: 'bucket', worn_trashcan_verb: 'tap', **ivars)
        allow(tm).to receive(:find_npc)
        allow(tm).to receive(:pause)
        allow(tm).to receive(:sort_sack)
        allow(tm).to receive(:fput)
        allow(tm).to receive(:bin_task_stock)
        allow(DRCT).to receive(:dispose)
        tm
      end

      describe 'GIVE_NOT_GOOD_ENOUGH' do
        it "matches Zasele's refusal as logged" do
          expect(not_good_enough).to match(TaskMaster::GIVE_NOT_GOOD_ENOUGH)
        end

        it 'is one of the replies every GIVE waits for, so the refusal does not wait out 15 seconds' do
          expect(TaskMaster::GIVE_REPLIES).to include(TaskMaster::GIVE_NOT_GOOD_ENOUGH)
        end

        it 'does not match a player saying the words' do
          expect(%(Gervin says, "I'm sorry, but this could be done better.")).not_to match(TaskMaster::GIVE_NOT_GOOD_ENOUGH)
          expect(%(Gervin whispers, "Zasele inspects the netting.  She writes, \\"I'm sorry, but this could be done better.\\"")).not_to match(TaskMaster::GIVE_NOT_GOOD_ENOUGH)
        end

        it 'does not match an acceptance' do
          expect('Seamstress Zasele takes your reinforced netting and inspects the craftsmanship.  She holds up a sign that simply reads, "Acceptable."').not_to match(TaskMaster::GIVE_NOT_GOOD_ENOUGH)
        end
      end

      describe '#turn_in_banked' do
        it "bins the unfinished netting by its id and hands in the good ones behind it, as Mahtra's hand-in should have" do
          tm = hander
          bad = netting(25_785_999, finished: false)
          good = [netting(1), netting(2), netting(3)]
          world = zasele_world(bag: [bad, *good], owed: 7)

          expect(tm.turn_in_banked('netting', 7)).to eq(4)

          expect(world[:binned]).to eq([bad])
          expect(world[:handed]).to eq(good)
          expect(DRCI).to have_received(:dispose_trash).with('#25785999', 'bucket', 'tap').once
          expect(world[:sent].count('give zasele')).to eq(4)
          expect(DRCC).not_to have_received(:stow_crafting_item)
          expect(DRC).to have_received(:message).with('Zasele said a netting was not made well enough, so it went in the trash.')
        end

        it 'leaves the binned one owed, so the resume makes it again' do
          tm = hander
          world = zasele_world(bag: [netting(9, finished: false)], owed: 2)

          expect(tm.turn_in_banked('netting', 2)).to eq(2)

          expect(world[:handed]).to be_empty
          expect(world[:binned].size).to eq(1)
        end
      end

      describe '#complete_task' do
        it 'bins a rejected netting and finishes the task with the good ones, with no remake' do
          tm = hander
          allow(tm).to receive(:resume_task)
          world = zasele_world(bag: [netting(9, finished: false), netting(1), netting(2)], owed: 2)

          tm.complete_task('netting', 2)

          expect(world[:binned].map(&:id)).to eq(['9'])
          expect(world[:handed].map(&:id)).to eq(%w[1 2])
          expect(tm).to have_received(:sort_sack).with('netting').once
          expect(tm).not_to have_received(:resume_task)
        end

        it 'makes the task again once the bag runs out after a netting was binned, instead of stopping' do
          tm = hander
          allow(tm).to receive(:resume_task)
          world = zasele_world(bag: [netting(1), netting(9, finished: false)], owed: 2)

          expect { tm.complete_task('netting', 2) }.not_to raise_error

          expect(tm).to have_received(:resume_task).with(exit_when_done: false).once
          expect(world[:binned].map(&:id)).to eq(['9'])
          # The remake's own hand-in sorts the sack; this one has none.
          expect(tm).not_to have_received(:sort_sack)
          expect(DRC).to have_received(:message).with('Zasele turned down 1 netting as not made well enough, and it went in the trash. Making the task\'s nettings again.')
          expect(DRC).not_to have_received(:message).with(/Could not get another netting/)
        end

        it 'counts every netting binned in the hand-in' do
          tm = hander
          allow(tm).to receive(:resume_task)
          zasele_world(bag: [netting(8, finished: false), netting(9, finished: false)], owed: 2)

          tm.complete_task('netting', 2)

          expect(DRC).to have_received(:message).with('Zasele turned down 2 nettings as not made well enough, and they went in the trash. Making the task\'s nettings again.')
        end

        it 'stops after MAX_NOT_GOOD_ENOUGH_REMAKES remakes that keep coming out not good enough, rather than crafting and binning forever' do
          tm = hander
          world = zasele_world(bag: [netting(100, finished: false)], owed: 1)
          remakes = 0
          allow(tm).to receive(:resume_task) do
            remakes += 1
            raise 'remade past the cap' if remakes > TaskMaster::MAX_NOT_GOOD_ENOUGH_REMAKES

            world[:bag] << netting(100 + remakes, finished: false)
            tm.complete_task('netting', 1)
          end

          expect { tm.complete_task('netting', 1) }.to raise_error(SystemExit)

          expect(remakes).to eq(TaskMaster::MAX_NOT_GOOD_ENOUGH_REMAKES)
          expect(world[:binned].size).to eq(TaskMaster::MAX_NOT_GOOD_ENOUGH_REMAKES + 1)
          expect(DRC).to have_received(:message).with(/after #{TaskMaster::MAX_NOT_GOOD_ENOUGH_REMAKES} remakes on this task\. Stopping/)
        end

        it 'gives each task its own remakes: a hand-in clears the count' do
          tm = hander(not_good_enough_remakes: TaskMaster::MAX_NOT_GOOD_ENOUGH_REMAKES)
          zasele_world(bag: [netting(1)], owed: 1)

          tm.complete_task('netting', 1)

          expect(tm.instance_variable_get(:@not_good_enough_remakes)).to eq(0)
        end

        it 'puts the netting back and stops, never giving it again, when the trash will not take it' do
          tm = hander
          allow(tm).to receive(:resume_task)
          bad = netting(9, finished: false)
          world = zasele_world(bag: [bad, netting(1)], owed: 2, trash_works: false)

          expect { tm.complete_task('netting', 2) }.to raise_error(SystemExit)

          expect(world[:sent].count('give zasele')).to eq(1)
          expect(world[:bag].first).to eq(bad)
          expect(DRC).to have_received(:message).with("Zasele did not take the netting (#{not_good_enough}). Stopping.")
          expect(tm).not_to have_received(:resume_task)
        end

        it 'stops, rather than give it again and again, when the trash says yes but the netting is still in hand' do
          tm = hander
          allow(tm).to receive(:resume_task)
          world = zasele_world(bag: [netting(9, finished: false), netting(1)], owed: 2)
          allow(DRCI).to receive(:dispose_trash).and_return(true)

          expect { tm.complete_task('netting', 2) }.to raise_error(SystemExit)

          expect(world[:sent].count('give zasele')).to eq(1)
          expect(DRC).to have_received(:message).with("Zasele did not take the netting (#{not_good_enough}). Stopping.")
        end

        it 'never bins by the noun: with no netting in hand to bin, it stops instead' do
          tm = hander
          allow(tm).to receive(:give_item).and_return(not_good_enough)
          allow(GameObj).to receive(:right_hand).and_return(empty_hand)
          allow(GameObj).to receive(:left_hand).and_return(empty_hand)
          allow(DRCI).to receive(:dispose_trash)
          allow(DRCC).to receive(:stow_crafting_item)

          expect { tm.complete_task('netting', 2) }.to raise_error(SystemExit)

          expect(DRCI).not_to have_received(:dispose_trash)
        end
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

      # With a lich-5 whose DRCI confirms the worn trash can's flush
      # (DRCI.flush_worn_trashcan, DRCI.note_thrown_away). On 2026-11-10 the
      # bucket's TAP did nothing for 90 minutes; binned yarn stayed in it and
      # sew took it back by its remembered id.
      context 'when DRCI confirms the flush' do
        let(:no_effect) { 'You tap a portable silversteel bucket with a flared rim that you are wearing.' }
        let(:thrown) { [] }

        def flush_gives(outcome)
          allow(DRCI).to receive(:flush_worn_trashcan).with('bucket', 'tap').and_return(outcome)
          allow(DRCI).to receive(:note_thrown_away) { |ref| thrown << ref }
          allow(XMLData).to receive(:room_title).and_return('[Andreshlew, Pearl Road]')
        end

        it 'leaves the flush to DRCI, sends no TAP itself, and records every piece as thrown away' do
          world = stock_world({ 'burlap cloth' => 2, 'wool yarn' => 1 })
          flush_gives(:flushed)
          expect(binner.bin_task_stock).to eq(3)
          expect(world[:sent]).not_to include('tap my bucket')
          expect(thrown).to eq(%w[#2222486 #2222487 #2222488])
          expect(DRC).to have_received(:message).with('Binned 3 piece(s) of leftover task stock')
        end

        it 'records every piece as thrown away even without a trash can verb, and sends no TAP' do
          world = stock_world({ 'wool yarn' => 2 })
          flush_gives(:flushed)
          expect(binner(worn_trashcan_verb: nil).bin_task_stock).to eq(2)
          expect(thrown).to eq(%w[#2222486 #2222487])
          expect(DRCI).not_to have_received(:flush_worn_trashcan)
          expect(world[:sent]).not_to include(a_string_starting_with('tap'))
        end

        it 'counts a trash can with no confirming line as flushed, as before' do
          stock_world({ 'wool yarn' => 1 })
          flush_gives(:unconfirmed)
          expect(binner.bin_task_stock).to eq(1)
          expect(thrown).to eq(['#2222486'])
          expect(DRC).not_to have_received(:message).with(a_string_including('did not flush'))
        end

        context 'when the bucket does not flush' do
          it 'says what it is doing and why, then takes each piece back by its id and gives it to DRCI.dispose_trash' do
            world = stock_world({ 'burlap cloth' => 1, 'wool yarn' => 1 })
            flush_gives(no_effect)
            expect(binner.bin_task_stock).to eq(2)
            expect(DRC).to have_received(:message).with(a_string_including(
                                                          "did not flush (#{no_effect})", '2 piece(s) of leftover stock', 'about 5 minutes',
                                                          'Taking each back out to throw away here (Andreshlew, Pearl Road)', 'otherwise the floor'
                                                        )).ordered
            expect(DRC).to have_received(:message).with('Threw away 2 piece(s) of leftover task stock (the bucket did not flush; see above)').ordered
            expect(world[:sent]).to include('get #2222486', 'get #2222487')
            expect(DRCI).to have_received(:dispose_trash).with('#2222486', 'bucket', 'tap')
            expect(DRCI).to have_received(:dispose_trash).with('#2222487', 'bucket', 'tap')
            expect(world[:hands].values).to all(be_nil)
            expect(thrown).to eq(%w[#2222486 #2222487])
          end

          it 'takes back only the pieces it binned, never by name' do
            world = stock_world({ 'wool yarn' => 2 })
            flush_gives('no reply')
            binner.bin_task_stock
            expect(world[:sent].grep(/\Aget #/)).to eq(['get #2222486', 'get #2222487'])
            expect(world[:sent]).not_to include(a_string_matching(/\Aget my .* from my bucket/))
          end

          it 'goes on when a piece is already gone from the bucket' do
            world = stock_world({ 'wool yarn' => 2 })
            flush_gives(no_effect)
            allow(DRCI).to receive(:flush_worn_trashcan) do
              world[:bucket].reject! { |obj| obj.id == '2222486' }
              no_effect
            end
            expect(binner.bin_task_stock).to eq(2)
            expect(world[:sent]).to include('get #2222486', 'get #2222487')
            expect(DRCI).not_to have_received(:dispose_trash).with('#2222486', any_args)
            expect(DRCI).to have_received(:dispose_trash).with('#2222487', 'bucket', 'tap')
            expect(DRC).not_to have_received(:message).with(a_string_including('Could not'))
          end

          it 'says a piece it could not take back will be thrown out where the character is' do
            world = stock_world({ 'wool yarn' => 1 })
            flush_gives(no_effect)
            # Both hands fill before the GET back: "You need a free hand".
            allow(DRCI).to receive(:flush_worn_trashcan) do
              world[:hands][:left] = OpenStruct.new(name: 'sewing needles', noun: 'needles', id: '1')
              world[:hands][:right] = OpenStruct.new(name: 'scissors', noun: 'scissors', id: '2')
              no_effect
            end
            expect(binner.bin_task_stock).to eq(1)
            expect(world[:bucket].map(&:id)).to eq(['2222486'])
            expect(DRC).to have_received(:message).with(a_string_including('Could not take #2222486 back out of your bucket', 'free hand', 'about 5 minutes'))
          end

          it 'says so when a piece it took back cannot be thrown away here' do
            world = stock_world({ 'wool yarn' => 1 })
            flush_gives(no_effect)
            allow(DRCI).to receive(:dispose_trash).and_return(false)
            expect(binner.bin_task_stock).to eq(1)
            expect(world[:hands].values.compact.map(&:id)).to eq(['2222486'])
            expect(DRC).to have_received(:message).with('Could not throw away #2222486 here; it is still in your hand.')
          end
        end
      end

      # A scrap stowed into the pack after sew stopped on it was taken back by
      # its remembered id (Lilwea, 2026-11-11 08:32:01 "You get some burlap
      # cloth from inside your traveler's pack."); 22 characters carried such
      # scraps after 2026-11-10.
      describe '#bin_stray_stock' do
        def stray_binner(**ivars)
          binner(lootbag: "traveler's pack", settings: { task_loot_bag: "traveler's pack" }, **ivars)
        end

        it 'bins the task stock in task_loot_bag, leaves the crafting bag alone, flushes and says why' do
          world = stock_world({ 'burlap cloth' => 2 }, others: { "traveler's pack" => { 'burlap cloth' => 1, 'wool yarn' => 1 } })
          expect(stray_binner.bin_stray_stock('sew made no netting on its last run (0 of 3 made)')).to eq(2)
          expect(world[:others]["traveler's pack"]).to eq('burlap cloth' => 0, 'wool yarn' => 0)
          expect(world[:bag]).to eq('burlap cloth' => 2)
          expect(world[:sent]).to include("get my burlap cloth from my traveler's pack", "get my wool yarn from my traveler's pack", 'tap my bucket')
          expect(DRC).to have_received(:message).with("sew made no netting on its last run (0 of 3 made): binned 2 piece(s) of task stock left in your traveler's pack, outside the crafting bag, where a GET by a remembered id could take one for the next item.")
        end

        it 'sends nothing and says nothing when none is there' do
          world = stock_world({ 'burlap cloth' => 2 }, others: { "traveler's pack" => {} })
          expect(stray_binner.bin_stray_stock('x')).to eq(0)
          expect(world[:sent].grep(/\Aput /)).to be_empty
          expect(DRC).not_to have_received(:message)
        end

        it 'does nothing without task_bin_leftover_stock, in marathon, or when task_loot_bag is the crafting bag' do
          world = stock_world({}, others: { "traveler's pack" => { 'burlap cloth' => 1 } })
          expect(stray_binner(bin_leftover_stock: false).bin_stray_stock('x')).to eq(0)
          expect(stray_binner(marathon: true).bin_stray_stock('x')).to eq(0)
          expect(binner(lootbag: 'duffel bag').bin_stray_stock('x')).to eq(0)
          expect(world[:sent]).to be_empty
        end

        it 'runs from tailor_item after a counted sew run that made none, not otherwise' do
          tm = stray_binner
          allow(tm).to receive(:check_sewing_consumables)
          allow(DRCT).to receive(:walk_to)
          allow(tm).to receive(:bin_stray_stock)
          allow(tm).to receive(:craft_each) do
            tm.instance_variable_set(:@craft_stalled, true)
            1
          end

          expect(tm.tailor_item('netting', 3, 'cloth', 'burlap')).to eq(1)
          expect(tm).to have_received(:bin_stray_stock).with('sew made no netting on its last run (1 of 3 made)').once

          allow(tm).to receive(:craft_each) do
            tm.instance_variable_set(:@craft_stalled, false)
            3
          end
          expect(tm.tailor_item('netting', 3, 'cloth', 'burlap')).to eq(3)
          expect(tm).to have_received(:bin_stray_stock).once
        end

        it 'does not run when INVENTORY never answered and no sew run was launched' do
          tm = stray_binner
          allow(tm).to receive(:check_sewing_consumables)
          allow(DRCT).to receive(:walk_to)
          allow(tm).to receive(:finished_count).and_return(nil)
          allow(tm).to receive(:bin_stray_stock)
          allow(DRC).to receive(:wait_for_script_to_complete)

          expect(tm.tailor_item('netting', 3, 'cloth', 'burlap')).to eq(0)

          expect(DRC).not_to have_received(:wait_for_script_to_complete)
          expect(tm).not_to have_received(:bin_stray_stock)
        end

        it 'does not run when INVENTORY never answered, even after an earlier run in the process stalled' do
          tm = stray_binner
          allow(tm).to receive(:check_sewing_consumables)
          allow(DRCT).to receive(:walk_to)
          allow(tm).to receive(:bin_stray_stock)
          allow(DRC).to receive(:wait_for_script_to_complete)

          # an earlier forge run that made none leaves its stall behind
          allow(tm).to receive(:finished_count).and_return(0)
          expect(tm.craft_each('forge', 'shovel', 2) {}).to eq(0)

          allow(tm).to receive(:finished_count).and_return(nil)
          expect(tm.tailor_item('netting', 3, 'cloth', 'burlap')).to eq(0)

          expect(DRC).not_to have_received(:wait_for_script_to_complete)
          expect(tm).not_to have_received(:bin_stray_stock)
        end

        it 'puts a piece the trash can refuses back in task_loot_bag, never in the crafting bag' do
          world = stock_world({}, refuse: true, others: { "traveler's pack" => { 'burlap cloth' => 1 } })
          expect(stray_binner.bin_stray_stock('x')).to eq(0)
          expect(world[:sent]).to include("put #2222486 in my traveler's pack")
          expect(world[:sent]).not_to include('put #2222486 in my duffel bag')
          expect(world[:others]["traveler's pack"]).to eq('burlap cloth' => 1)
          expect(world[:bag]).to eq({})
        end

        it 'puts back, without binning, a piece the GET found that is not named as the stock' do
          world = stock_world({}, others: { "traveler's pack" => {} })
          tm = stray_binner
          allow(tm).to receive(:take_stock_piece).and_return('#7001', nil)
          allow(GameObj).to receive(:right_hand).and_return(OpenStruct.new(name: 'silk cloth', noun: 'cloth', id: '7001'))
          allow(DRCI).to receive(:put_away_item?).and_return(true)

          expect(tm.bin_stray_stock('x')).to eq(0)

          expect(DRCI).to have_received(:put_away_item?).with('#7001', "traveler's pack")
          expect(DRCI).not_to have_received(:put_away_item?).with('#7001', 'bucket')
          expect(world[:sent]).to be_empty
        end

        it 'does nothing without task_loot_bag set (never the backpack default)' do
          world = stock_world({}, others: { 'backpack' => { 'burlap cloth' => 1 } })
          expect(binner(lootbag: 'backpack').bin_stray_stock('x')).to eq(0)
          expect(world[:sent]).to be_empty
        end

        it 'takes task_loot_bag named another way for the crafting bag too' do
          world = stock_world({ 'burlap cloth' => 1 })
          expect(binner(lootbag: 'my duffel bag', settings: { task_loot_bag: 'my duffel bag' }).bin_stray_stock('x')).to eq(0)
          expect(world[:sent]).to be_empty
        end

        it 'says the pieces were thrown away, not binned, when the trash can did not flush' do
          stock_world({}, others: { "traveler's pack" => { 'wool yarn' => 1 } })
          tm = stray_binner
          allow(tm).to receive(:flush_binned_stock).and_return(false)

          expect(tm.bin_stray_stock('x')).to eq(1)

          expect(DRC).to have_received(:message).with(a_string_starting_with('x: threw away 1 piece(s) of task stock').and(ending_with('(the bucket did not flush; see above).')))
        end

        it 'runs before the cancel when the instructions run out' do
          UserVars.taskmaster_replacements = { 'zasele' => 'rope' }
          tm = stray_binner(cancel_short_tasks: true)
          allow(tm).to receive(:pause)
          order = []
          allow(tm).to receive(:bin_stray_stock) { order << :bin }
          allow(tm).to receive(:cancel_task) { order << :cancel }

          expect { tm.request_replacement('rope', needed: 3, most: 2) }.to throw_symbol(TaskMaster::FOREIGN_TASK_CANCELLED)

          expect(order).to eq(%i[bin cancel])
          expect(tm).to have_received(:bin_stray_stock).with('The rope instructions ran out')
        end
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
        # Noted for resume_task, which tells this from nothing to give.
        expect(tm.instance_variable_get(:@task_handed_in)).to be(true)
      end

      it 'does not bin while items are still owed' do
        tm = build(worn_trashcan: 'bucket', worn_trashcan_verb: 'tap')
        allow(tm).to receive(:find_npc)
        allow(tm).to receive(:bin_task_stock)
        allow(DRCC).to receive(:stow_crafting_item)
        giving([more_needed(2)], banked: 1)
        expect(tm.turn_in_banked('rope', 3)).to eq(2)
        expect(tm).not_to have_received(:bin_task_stock)
        expect(tm.instance_variable_get(:@task_handed_in)).to be_nil
      end

      it 'returns 0 without noting a hand-in when nothing is owed and there is nothing to give' do
        tm = build
        allow(tm).to receive(:give_item).and_return(nil)
        expect(tm.turn_in_banked('rope', 0)).to eq(0)
        expect(tm.instance_variable_get(:@task_handed_in)).to be_nil
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

      context 'with junk-list string entries' do
        it 'matches a string entry as a whole word, not inside a longer one' do
          tm = filtered(task_junk_list: %w[steel pine])
          expect(tm.keeper?(sack('a silversteel ingot'))).to be(true)
          expect(tm.keeper?(sack('some ghostspine lumber'))).to be(true)
          expect(tm.keeper?(sack('a steel ingot'))).to be(false)
          expect(tm.keeper?(sack('some pine lumber'))).to be(false)
        end

        it 'matches across a hyphen' do
          expect(filtered(task_junk_list: ['bone']).keeper?(sack('a bear-bone stack'))).to be(false)
        end

        it 'matches a string entry that starts or ends with punctuation' do
          expect(filtered(task_junk_list: ['dye.']).keeper?(sack('some coral dye'))).to be(false)
          expect(filtered(task_junk_list: ['(used)']).keeper?(sack('a deed (used)'))).to be(false)
        end
      end

      context 'with junk-list regexp entries' do
        it 'keeps the flags of a lone regexp entry' do
          expect(filtered(task_junk_list: [/DYE/i]).keeper?(sack('some coral dye'))).to be(false)
          expect(filtered(task_junk_list: [/coral \s dye/x]).keeper?(sack('some coral dye'))).to be(false)
        end

        it 'uses a regexp entry as written, without adding word boundaries' do
          expect(filtered(task_junk_list: [/wood/]).keeper?(sack('some rosewood lumber'))).to be(false)
          expect(filtered(task_junk_list: [/dye\./]).keeper?(sack('some coral dye'))).to be(false)
        end
      end

      it 'ignores blank junk-list entries instead of binning every sack' do
        tm = filtered(task_junk_list: ['steel', nil, ''])
        expect(tm.keeper?(sack('a large haledroth shard'))).to be(true)
        expect(tm.keeper?(sack('a steel ingot'))).to be(false)
      end

      it 'falls back to the keep list when every junk-list entry is blank' do
        expect(filtered(task_keep_list: %w[agonite], task_junk_list: [nil]).keeper?(sack('a large agonite bar'))).to be(true)
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

      # The reward sack in hand, as GameObj gives it (<right exist="63768227"
      # noun="sack">woven sack</right>, Hollow Eve 2026 XML logs).
      let(:reward_sack) { OpenStruct.new(noun: 'sack', name: 'woven sack', id: '63768227') }

      def hold(right, left = nil)
        allow(GameObj).to receive(:right_hand).and_return(right)
        allow(GameObj).to receive(:left_hand).and_return(left)
      end

      before { hold(reward_sack) }

      def sort(tm, contents)
        allow(DRC).to receive(:bput).and_return('You pick up')
        allow(DRC).to receive(:bput).with('look in #63768227', any_args).and_return("In the woven sack you see #{contents}.")
        allow(DRCI).to receive(:put_away_item?)
        allow(DRCI).to receive(:dispose_trash)
        UserVars.taskmaster_sacks = { 'zasele' => [] }
        tm.sort_sack('rope')
      end

      it 'puts a keeper in the loot bag and pings Slack when asked to' do
        tm = filtered(task_junk_list: ['dye'], task_slack_keepers: true)
        expect(tm).to receive(:send_slackbot_message).with('Found a keeper: large haledroth shard')
        sort(tm, 'a large haledroth shard')
        expect(DRCI).to have_received(:put_away_item?).with('#63768227', 'backpack')
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

      describe 'naming the sack by its id' do
        # Catheroine's pet sack (Hollow Eve 2026, binned 2026-11-06 00:31:13
        # by a lagged second sort whose "get my sack" fetched it from the
        # duffel bag).
        let(:pet_sack) { OpenStruct.new(noun: 'sack', name: 'soft woven sack with a golden piglet charm', id: '57001234') }

        def commands
          sent = []
          allow(DRC).to receive(:bput) do |command, *|
            sent << command
            command == 'look in #63768227' ? 'In the woven sack you see some coral dye.' : ''
          end
          sent
        end

        it 'sends no command naming a bare sack apart from the pouch fill' do
          sent = commands
          allow(DRCI).to receive(:dispose_trash)
          allow(DRCI).to receive(:fill_gem_pouch_with_container)
          UserVars.taskmaster_sacks = { 'zasele' => [] }
          filtered(task_junk_list: ['dye']).sort_sack('rope')
          expect(sent).to eq(['get coin from #63768227', 'look in #63768227'])
          expect(DRCI).to have_received(:dispose_trash).with('#63768227', nil, nil)
          expect(DRCI).to have_received(:fill_gem_pouch_with_container).with(anything, anything, 'sack', any_args)
        end

        it 'leaves a pet sack in hand alone: nothing is looked in, kept or binned' do
          hold(pet_sack)
          stub_const("#{described_class}::REWARD_SACK_WAIT", 0)
          sent = commands
          allow(DRCI).to receive(:dispose_trash)
          allow(DRCI).to receive(:put_away_item?)
          allow(DRCI).to receive(:fill_gem_pouch_with_container)
          filtered(task_junk_list: ['dye']).sort_sack('rope')
          expect(sent).to be_empty
          expect(DRCI).not_to have_received(:dispose_trash)
          expect(DRCI).not_to have_received(:put_away_item?)
          expect(DRCI).not_to have_received(:fill_gem_pouch_with_container)
          expect(DRC).to have_received(:message).with('No reward sack in hand to sort.')
        end

        it 'does nothing with empty hands, so a sack already binned is never fetched by noun' do
          hold(nil, nil)
          stub_const("#{described_class}::REWARD_SACK_WAIT", 0)
          sent = commands
          allow(DRCI).to receive(:dispose_trash)
          filtered(task_junk_list: ['dye']).sort_sack('rope')
          expect(sent).to be_empty
          expect(DRCI).not_to have_received(:dispose_trash)
        end

        it 'does nothing with a reward sack the game gave no id' do
          hold(OpenStruct.new(noun: 'sack', name: 'woven sack', id: nil))
          stub_const("#{described_class}::REWARD_SACK_WAIT", 0)
          sent = commands
          allow(DRCI).to receive(:dispose_trash)
          filtered(task_junk_list: ['dye']).sort_sack('rope')
          expect(sent).to be_empty
          expect(DRCI).not_to have_received(:dispose_trash)
        end

        it 'picks the reward sack from the other hand when a pet sack is held too' do
          hold(pet_sack, reward_sack)
          sent = commands
          allow(DRCI).to receive(:dispose_trash)
          UserVars.taskmaster_sacks = { 'zasele' => [] }
          filtered(task_junk_list: ['dye']).sort_sack('rope')
          expect(sent).to include('look in #63768227')
          expect(DRCI).to have_received(:dispose_trash).with('#63768227', nil, nil)
          expect(sent.join(' ')).not_to include('57001234')
        end

        it 'waits for a hand update that trails the hand-in, then sorts by that id' do
          hands = [nil, nil, reward_sack]
          allow(GameObj).to receive(:right_hand) { hands.size > 1 ? hands.shift : hands.first }
          tm = filtered(task_junk_list: ['dye'])
          allow(tm).to receive(:pause)
          sent = commands
          allow(DRCI).to receive(:dispose_trash)
          UserVars.taskmaster_sacks = { 'zasele' => [] }
          tm.sort_sack('rope')
          expect(tm).to have_received(:pause).with(0.1).twice
          expect(DRCI).to have_received(:dispose_trash).with('#63768227', nil, nil)
          expect(sent).to include('look in #63768227')
        end

        it 'gives up waiting after REWARD_SACK_WAIT seconds' do
          hold(nil, nil)
          tm = filtered(task_junk_list: ['dye'])
          clock = Time.at(0)
          allow(Time).to receive(:now) { clock }
          allow(tm).to receive(:pause) { |seconds| clock += seconds }
          sent = commands
          tm.sort_sack('rope')
          expect(sent).to be_empty
          expect(clock - Time.at(0)).to be_within(0.15).of(described_class::REWARD_SACK_WAIT)
        end

        it 'keeps a sack whose LOOK cannot be read, unopened and unlogged, instead of binning it unseen' do
          allow(DRC).to receive(:bput).and_return('')
          allow(DRCI).to receive(:put_away_item?)
          allow(DRCI).to receive(:dispose_trash)
          UserVars.taskmaster_sacks = { 'zasele' => [] }
          tm = filtered(task_junk_list: ['dye'])
          tm.sort_sack('rope')
          expect(DRCI).to have_received(:put_away_item?).with('#63768227', 'backpack')
          expect(DRCI).not_to have_received(:dispose_trash)
          expect(DRC).to have_received(:message).with('Could not read the reward sack; keeping it unopened.')
          expect(DRC).not_to have_received(:message).with(/\ANothing special/)
          expect(UserVars.taskmaster_sacks['zasele']).to be_empty
        end

        # Review of #8041 (mrhoribu): an empty container answers LOOK IN with
        # VESSEL_EMPTY, which is a read, not a timeout.
        it 'bins, by its id, a sack LOOK shows empty, without keeping or logging it' do
          allow(DRC).to receive(:bput) do |command, *patterns|
            line = command == 'look in #63768227' ? 'There is nothing in there.' : ''
            patterns.flatten.filter_map { |pt| line[pt.is_a?(Regexp) ? pt : /#{pt}/] }.first || ''
          end
          allow(DRCI).to receive(:put_away_item?)
          allow(DRCI).to receive(:dispose_trash)
          UserVars.taskmaster_sacks = { 'zasele' => [] }
          filtered(task_junk_list: ['dye']).sort_sack('rope')
          expect(DRCI).to have_received(:dispose_trash).with('#63768227', nil, nil)
          expect(DRCI).not_to have_received(:put_away_item?)
          expect(DRC).to have_received(:message).with('Nothing special: the reward sack is empty.')
          expect(DRC).not_to have_received(:message).with(/keeper|keeping/)
          expect(UserVars.taskmaster_sacks['zasele']).to be_empty
        end

        it 'keeps a sack whose LOOK reply is about something else (the pet-sack line), never binning it' do
          allow(DRC).to receive(:bput) do |command, *patterns|
            line = command == 'look in #63768227' ? 'Curled up inside a soft woven sack with a golden piglet charm is a foul-smelling field pig.' : ''
            patterns.flatten.filter_map { |pt| line[pt.is_a?(Regexp) ? pt : /#{pt}/] }.first || ''
          end
          allow(DRCI).to receive(:put_away_item?)
          allow(DRCI).to receive(:dispose_trash)
          filtered(task_junk_list: ['dye']).sort_sack('rope')
          expect(DRCI).not_to have_received(:dispose_trash)
          expect(DRCI).to have_received(:put_away_item?).with('#63768227', 'backpack')
        end
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
            reply = if command == 'get coin from #63768227'
                      line || coins.shift || no_coin
                    elsif command == 'look in #63768227'
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
          commands.count('get coin from #63768227')
        end

        # Every get comes before the LOOK that decides the sack's fate.
        def looked_after_gets(commands)
          commands.rindex('get coin from #63768227') < commands.index('look in #63768227')
        end

        real_sacks.each do |stacks, (coins, contents)|
          it "takes every coin of a #{stacks}-stack sack, then sorts the sack as before" do
            commands = sort_coins(coins, contents: contents)
            expect(looked_after_gets(commands)).to be(true)
            expect(commands.uniq).to eq(['get coin from #63768227', 'look in #63768227'])
            expect(DRC).to have_received(:message).with("Nothing special: In the woven sack you see #{contents}.")
            expect(DRCI).to have_received(:dispose_trash).with('#63768227', nil, nil)
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
          expect(commands).to include('look in #63768227')
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
          expect(commands).to include('look in #63768227')
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
      let(:sack) { OpenStruct.new(noun: 'sack', name: 'woven sack', id: '63768227') }
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
      # got_bar puts the bar in the left hand, and putting the bar away
      # empties it. listing is the items the first INVENTORY of the sack
      # lists, the one item LOOK shows by default; nil makes that INVENTORY
      # return `inventory` too. inventory is what every later INVENTORY of
      # the sack returns (issue_command's lines; a String is one line).
      # disposed is what dispose_trash returns.
      def unpack(tm, contents: 'a large tyrium bar', listing: [contents], get_replies: [got_bar], inventory: sack_empty, put_ok: true, disposed: true)
        hands = { right: sack, left: empty_hand }
        allow(GameObj).to receive(:right_hand) { hands[:right] }
        allow(GameObj).to receive(:left_hand) { hands[:left] }
        allow(DRC).to receive(:left_hand) { hands[:left]&.noun }
        allow(DRC).to receive(:right_hand) { hands[:right]&.noun }
        allow(tm).to receive(:pause)
        game('look in #63768227'          => "In the woven sack you see #{contents}.",
             'get coin from #63768227'    => 'What were you referring to?',
             'get '                       => lambda do |*|
               reply = get_replies.shift
               hands[:left] = bar if reply == got_bar
               reply
             end,
             'put #63768234 in #63768227' => 'You put your bar in your woven sack.')
        listed = listing.nil?
        inventory_replies('inventory #63768227' => lambda do |*|
          next Array(inventory) if listed

          listed = true
          inventoried(listing, container: 'woven sack', noun: 'sack', id: '63768227')
        end)
        allow(DRCI).to receive(:put_away_item?) do |item, _bag|
          next true unless item == '#63768234'

          hands[:left] = empty_hand if put_ok
          put_ok
        end
        allow(DRCI).to receive(:dispose_trash).and_return(disposed)
        UserVars.taskmaster_sacks = { 'zasele' => [] }
        tm.sort_sack('netting')
      end

      # A keeper sack the game holds, item by item: `items` are [INVENTORY
      # line, the game's noun, id]. A get by a word takes the first item
      # left whose noun starts with it, as DR matches a noun by its start,
      # into the free left hand; putting it in the loot bag empties the
      # hand. INVENTORY lists what is left. Returns the commands sent.
      def unpack_world(tm, items, sack_id: '4261859')
        held_sack = OpenStruct.new(noun: 'sack', name: 'woven sack', id: sack_id)
        left = items.map(&:dup)
        hands = { right: held_sack, left: empty_hand }
        allow(GameObj).to receive(:right_hand) { hands[:right] }
        allow(GameObj).to receive(:left_hand) { hands[:left] }
        allow(DRC).to receive(:left_hand) { hands[:left]&.noun }
        allow(DRC).to receive(:right_hand) { hands[:right]&.noun }
        allow(tm).to receive(:pause)
        sent = []
        listed = left.map(&:first).join(', ').sub(/, ([^,]*)\z/, ' and \\1')
        game("look in ##{sack_id}"       => "In the woven sack you see #{listed}.",
             "get coin from ##{sack_id}" => 'What were you referring to?',
             'get '                      => lambda do |command, *|
               sent << command
               word = command[/\Aget (\S+) from ##{sack_id}\z/, 1]
               item = word && left.find { |_, noun, _| noun.start_with?(word) }
               next 'What were you referring to?' unless item

               left.delete(item)
               hands[:left] = OpenStruct.new(noun: item[1], id: item[2])
               "You get #{item[0]} from inside your woven sack."
             end)
        inventory_replies("inventory ##{sack_id}" => lambda do |*|
          inventoried(left.map(&:first), container: 'woven sack', noun: 'sack', id: sack_id)
        end)
        allow(DRCI).to receive(:put_away_item?) do |item, _bag|
          hands[:left] = empty_hand if item == "##{hands[:left].id}"
          true
        end
        allow(DRCI).to receive(:dispose_trash).and_return(true)
        UserVars.taskmaster_sacks = { 'zasele' => [] }
        tm.sort_sack('netting')
        sent
      end

      # Lukedo's keeper sack (2026-11-05 10:14:26): LOOK showed "a large
      # coralite lump, a huge piece of amber and a small lilac amethyst",
      # and the amethyst came out as #4261862; the other two ids are made
      # up. lich-5's DRC.get_noun reads lump, amber and amethyst off the
      # lines, each the game's noun (noun-corpus.tsv).
      let(:lukedo_sack) do
        [['a large coralite lump', 'lump', '4261860'], ['a huge piece of amber', 'amber', '4261861'], ['a small lilac amethyst', 'amethyst', '4261862']]
      end

      it 'takes every item of a sack holding several out, one get per INVENTORY line, and bins the empty sack' do
        tm = unpacker
        sent = unpack_world(tm, lukedo_sack)
        expect(sent).to eq(['get lump from #4261859', 'get amber from #4261859', 'get amethyst from #4261859'])
        %w[#4261860 #4261861 #4261862].each { |ref| expect(DRCI).to have_received(:put_away_item?).with(ref, "traveler's.pack") }
        expect(DRCI).to have_received(:dispose_trash).with('#4261859', 'bucket', 'tap')
        expect(DRCI).not_to have_received(:put_away_item?).with('#4261859', anything)
      end

      it 'takes a closed container out by its noun, and bins the empty sack' do
        tm = unpacker
        sent = unpack_world(tm, [['a heavy bronze waterproof trunk (closed)', 'trunk', '4261866']])
        expect(sent).to eq(['get trunk from #4261859'])
        expect(DRCI).to have_received(:put_away_item?).with('#4261866', "traveler's.pack")
        expect(DRCI).to have_received(:dispose_trash).with('#4261859', 'bucket', 'tap')
      end

      it 'takes two items of one noun out with a get each (Kythkani\'s coin lines)' do
        tm = unpacker
        sent = unpack_world(tm, [['some copper coins', 'coins', '5001'], ['some bronze coins', 'coins', '5002']])
        expect(sent).to eq(['get coins from #4261859'] * 2)
        expect(DRCI).to have_received(:dispose_trash).with('#4261859', 'bucket', 'tap')
      end

      it 'takes an item by the noun get_noun reads off its INVENTORY line, not the line\'s last word' do
        tm = unpacker
        # A real name (2026-11-09) that also defeats DRC.list_to_array: the
        # " and a " inside it reads as a second item.
        sent = unpack_world(tm, [['a weighty almanac bound in rich purple leather and a golden closed-eye clasp', 'almanac', '4261864']])
        expect(sent).to eq(['get almanac from #4261859'])
        expect(DRCI).to have_received(:put_away_item?).with('#4261864', "traveler's.pack")
        expect(DRCI).to have_received(:dispose_trash).with('#4261859', 'bucket', 'tap')
      end

      it 'puts away the item newly in hand when the game\'s noun only starts with the noun get_noun reads' do
        tm = unpacker
        # noun-corpus.tsv: get_noun reads "robe" off this name, whose noun is
        # "robes"; DR's prefix match gets it.
        sent = unpack_world(tm, [['a shadowy black nightsilk robe pinned with a trio of panther claws', 'robes', '4261865']])
        expect(sent).to eq(['get robe from #4261859'])
        expect(DRCI).to have_received(:put_away_item?).with('#4261865', "traveler's.pack")
        expect(DRCI).to have_received(:dispose_trash).with('#4261859', 'bucket', 'tap')
        expect(DRCI).not_to have_received(:put_away_item?).with('#4261859', anything)
      end

      it 'goes on to the next line after a get the game finds nothing by, and keeps the sack with that item' do
        tm = unpacker
        # noun-corpus.tsv names; get_noun reads "as" off the observer, whose
        # noun is "observer".
        sent = unpack_world(tm, [['a frosty observer manifested as an array of jagged icicles', 'observer', '4261866'],
                                 ['a sparkling white cloak lined with matching satin', 'cloak', '4261867'],
                                 ["a shadesatin astral traveler's haversack with moonsilver stars", 'haversack', '4261868']])
        expect(sent).to eq(['get as from #4261859', 'get cloak from #4261859', 'get haversack from #4261859'])
        %w[#4261867 #4261868].each { |ref| expect(DRCI).to have_received(:put_away_item?).with(ref, "traveler's.pack") }
        expect(DRCI).to have_received(:put_away_item?).with('#4261859', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'keeps the sack, with what is left in it, when get_noun reads a noun off a line the game does not answer to' do
        tm = unpacker
        # get_noun reads "feet" off this line (Kythkani's toolbelt, 2026-11-09).
        sent = unpack_world(tm, [['a large coralite lump', 'lump', '4261860'], ['a small uthamar brazier supported by twisted Sunderstone feet', 'brazier', '4261863']])
        expect(sent).to eq(['get lump from #4261859', 'get feet from #4261859'])
        expect(DRCI).to have_received(:put_away_item?).with('#4261860', "traveler's.pack")
        expect(DRCI).to have_received(:put_away_item?).with('#4261859', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'leaves a line get_noun reads no noun off in the sack, and keeps the sack' do
        tm = unpacker
        allow(DRC).to receive(:get_noun).and_call_original
        allow(DRC).to receive(:get_noun).with('a huge piece of amber').and_return(nil) # no logged line gives none
        sent = unpack_world(tm, lukedo_sack)
        expect(sent).to eq(['get lump from #4261859', 'get amethyst from #4261859'])
        expect(DRCI).to have_received(:put_away_item?).with('#4261859', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      { 'goes unanswered'        => '',
        'lists no item line'     => ['Inside a woven sack, you see:', '', "[Use <d cmd='inventory help'>INVENTORY HELP</d> for more options.]"],
        'says the sack is empty' => "There's nothing inside a woven sack!" }.each do |what, reply|
        it "keeps the sack, getting nothing, when the first INVENTORY of it #{what}" do
          tm = unpacker
          unpack(tm, listing: nil, inventory: reply)
          expect(DRC).not_to have_received(:bput).with(/\Aget (?!coin)/, any_args)
          expect(DRCI).to have_received(:put_away_item?).with('#63768227', "traveler's.pack")
          expect(DRCI).not_to have_received(:dispose_trash)
        end
      end

      it 'takes the item out by noun from the sack id, puts it away by its own id, and bins the empty sack by its id' do
        tm = unpacker
        unpack(tm)
        expect(DRC).to have_received(:bput).with('get bar from #63768227', any_args)
        # Once for the items, once to see the sack empty.
        expect(Lich::Util).to have_received(:issue_command).with('inventory #63768227', any_args).twice
        expect(DRCI).to have_received(:put_away_item?).with('#63768234', "traveler's.pack")
        expect(DRCI).to have_received(:dispose_trash).with('#63768227', 'bucket', 'tap')
        expect(DRCI).not_to have_received(:put_away_item?).with('#63768227', anything)
      end

      it 'puts the empty sack in the loot bag when it cannot be binned' do
        tm = unpacker
        unpack(tm, disposed: false)
        expect(DRCI).to have_received(:put_away_item?).with('#63768234', "traveler's.pack")
        expect(DRCI).to have_received(:dispose_trash).with('#63768227', 'bucket', 'tap')
        expect(DRCI).to have_received(:put_away_item?).with('#63768227', "traveler's.pack")
      end

      it 'puts the sack in the loot bag when dispose_trash finds it no longer in hand' do
        tm = unpacker
        unpack(tm, disposed: nil)
        expect(DRCI).to have_received(:put_away_item?).with('#63768227', "traveler's.pack")
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
        expect(DRCI).to have_received(:put_away_item?).with('#63768227', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'keeps the whole sack when the noun does not match the item' do
        tm = unpacker
        unpack(tm, contents: 'some haledroth shards', get_replies: ['What were you referring to?'],
                   inventory: inventoried(['some haledroth shards'], container: 'woven sack', noun: 'sack', id: '63768227'))
        expect(DRC).to have_received(:bput).with('get shards from #63768227', any_args)
        expect(DRCI).to have_received(:put_away_item?).with('#63768227', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'puts the item back in the sack and keeps the sack when the loot bag will not take the item' do
        tm = unpacker
        unpack(tm, put_ok: false)
        expect(DRC).to have_received(:bput).with('put #63768234 in #63768227', any_args)
        expect(DRCI).to have_received(:put_away_item?).with('#63768227', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'keeps a sack that is not empty after the item is out, with whatever is left in it' do
        tm = unpacker
        unpack(tm, inventory: inventoried(['some coral dye'], container: 'woven sack', noun: 'sack', id: '63768227'))
        expect(DRCI).to have_received(:put_away_item?).with('#63768234', "traveler's.pack")
        expect(DRCI).to have_received(:put_away_item?).with('#63768227', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'keeps a sack whose INVENTORY list has no item line it can read' do
        tm = unpacker
        unpack(tm, inventory: ['Inside a woven sack, you see:', '', "[Use <d cmd='inventory help'>INVENTORY HELP</d> for more options.]"])
        expect(DRCI).to have_received(:put_away_item?).with('#63768227', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'keeps the sack when INVENTORY gives no recognised reply' do
        tm = unpacker
        unpack(tm, inventory: '')
        expect(DRCI).to have_received(:put_away_item?).with('#63768227', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'never unpacks junk, which is binned with its sack as before' do
        tm = unpacker
        unpack(tm, contents: 'some coral dye')
        expect(DRC).not_to have_received(:bput).with(/\Aget dye/, any_args)
        expect(DRCI).to have_received(:dispose_trash).with('#63768227', 'bucket', 'tap')
      end

      it 'keeps the whole sack, as before, when task_unpack_keepers is off' do
        tm = unpacker(task_unpack_keepers: false)
        unpack(tm)
        expect(DRC).not_to have_received(:bput).with(/\Aget bar/, any_args)
        expect(DRCI).to have_received(:put_away_item?).with('#63768227', "traveler's.pack")
        expect(DRCI).not_to have_received(:dispose_trash)
      end

      it 'unpacks the reward sack by its id, never the pet sack held in the other hand' do
        tm = unpacker
        pet = OpenStruct.new(noun: 'sack', name: 'soft woven sack with a golden piglet charm', id: '57001234')
        allow(GameObj).to receive(:right_hand).and_return(pet)
        allow(GameObj).to receive(:left_hand).and_return(sack)
        allow(DRC).to receive(:left_hand).and_return('sack')
        allow(DRC).to receive(:right_hand).and_return('sack')
        allow(tm).to receive(:pause)
        stub_const("#{described_class}::UNPACK_FREE_HAND_WAIT", 0)
        game('look in #63768227' => 'In the woven sack you see a large tyrium bar.',
             'get '              => 'You need a free hand to pick that up.')
        inventory_replies('inventory #63768227' => inventoried(['a large tyrium bar'], container: 'woven sack', noun: 'sack', id: '63768227'),
                          'inventory #57001234' => inventoried(['a foul-smelling field pig'], container: 'soft woven sack', noun: 'sack', id: '57001234'))
        allow(DRCI).to receive(:put_away_item?).and_return(true)
        allow(DRCI).to receive(:dispose_trash).and_return(true)
        UserVars.taskmaster_sacks = { 'zasele' => [] }
        tm.sort_sack('netting')
        expect(Lich::Util).to have_received(:issue_command).with('inventory #63768227', any_args)
        expect(Lich::Util).not_to have_received(:issue_command).with('inventory #57001234', any_args)
        expect(DRC).not_to have_received(:bput).with(/57001234/, any_args)
        expect(DRCI).to have_received(:put_away_item?).with('#63768227', "traveler's.pack")
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

      it 'asks its own taskmaster to end a task from one it does not do, and takes her "will notify" reply as done' do
        tm = zasele_run
        UserVars.taskmaster_replacements = { 'zasele' => 'rope' }
        replies = ['Seamstress Zasele looks at you and says, "You wish to end your current task?  If so, ask me again within fifteen seconds."',
                   'Seamstress Zasele says, "Very well, I will notify the firewood peddler Mags that you no longer desire to pursue your task."']
        game('ask zasele for task cancel' => ->(*) { replies.shift })

        expect { tm.cancel_task('mags', nil) }.not_to raise_error

        expect(tm).to have_received(:find_npc).with(anything, 'zasele')
        expect(DRC).to have_received(:bput).with('ask zasele for task cancel', any_args).twice
        expect(DRC).not_to have_received(:bput).with('ask mags for task cancel', any_args)
        expect(DRCT).not_to have_received(:dispose)
        expect(DRC).to have_received(:message).with('You are on a task for Mags, not Zasele: cancelling it, asking Zasele (task_cancel_foreign_tasks).')
      end

      it 'takes the "will notify" reply from the taskmaster asked for her own taskmaster too' do
        line = 'The firewood peddler Mags says, "Very well, I will notify Seamstress Zasele that you no longer desire to pursue your task."'
        expect(line).to match(build.cancel_reply('mags', TaskMaster::TASK_CANCELLED_FOR_ANOTHER))
        expect('Mallory says, "I will notify Zasele that you no longer desire to pursue your task."').not_to match(build.cancel_reply('zasele', TaskMaster::TASK_CANCELLED_FOR_ANOTHER))
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

      # crafting_container: backp (profiles/Samples/WarriorMage/
      # Kyrtoth-setup.yaml) with task_loot_bag unset, so 'backpack': DR takes
      # "backp" for the backpack, though the last words differ.
      it 'stops when one name is a shortened noun of the other, as with crafting_container backp and the default loot bag' do
        expect { dorhum(bag: 'backp', lootbag: 'backpack').hand_in_bag }.to raise_error(SystemExit)
        expect { dorhum(bag: 'backpack', lootbag: 'backp').hand_in_bag }.to raise_error(SystemExit)
      end

      it 'stops when both names find the one worn bag, whose name ends in a medallion' do
        $worn_items = [OpenStruct.new(name: 'deep black camlet duffel bag set with a crimson windsteel medallion', noun: 'bag', id: '997')]
        expect { dorhum(bag: 'duffel bag', lootbag: 'camlet duffel bag').hand_in_bag }.to raise_error(SystemExit)
      end

      it 'goes on when the two names find two worn bags, even sharing an adjective' do
        $worn_items = [OpenStruct.new(name: 'battered black duffel bag', noun: 'bag', id: '387369'),
                       OpenStruct.new(name: 'black spidersilk bag woven to resemble a cocoon fortified by tomiek spiderwebs', noun: 'bag', id: '194112')]
        expect(dorhum(bag: 'black duffel bag', lootbag: 'black spidersilk bag').hand_in_bag).to eq('black spidersilk bag')
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

      # INVENTORY of the crafting bag listing these scrolls, each "an
      # intricate <name>", among the bag's other items.
      def scrolls(*names)
        inventory_replies('inventory duffel bag' => inventoried(['some burlap cloth', *names.map { |name| "an intricate #{name}" }]))
      end

      it 'counts the scrolls already in the crafting bag, with one INVENTORY for every sigil' do
        scrolls(*Array.new(3, 'congruence sigil-scroll'), *Array.new(11, 'decay sigil-scroll'))

        dorhum.buy_sigils(%w[congruence decay], 8)

        expect(orders.tally).to eq({ [14_753, 3] => 5 })
        expect(Lich::Util).to have_received(:issue_command).with('inventory duffel bag', any_args).once
      end

      it 'counts one scroll, the last in the list, and none when the bag has none' do
        scrolls('decay sigil-scroll')
        dorhum.buy_sigils(%w[decay], 2)
        expect(orders.tally).to eq({ [14_753, 10] => 1 })

        orders.clear
        inventory_replies('inventory duffel bag' => inventoried([]))
        dorhum.buy_sigils(%w[decay], 2)
        expect(orders.tally).to eq({ [14_753, 10] => 2 })
      end

      # The task's scrolls as the game names them: "You get an intricate
      # decay sigil-scroll comprised of broad strokes from inside your
      # leather satchel" (taskmaster-nezhiri logs, 2026-11-06,
      # message.txt:13379, 13418). Counting names that end in "decay
      # sigil-scroll" counted none of them and bought all six again.
      # lich-5's DRC.get_noun reads "strokes" off them.
      it 'counts the logged scrolls whose names go on past "sigil-scroll" as carried, and names them, rather than buy them again' do
        scrolls(*Array.new(3, 'congruence sigil-scroll comprised of broad strokes'), *Array.new(3, 'decay sigil-scroll comprised of broad strokes'))

        dorhum.buy_sigils(%w[congruence decay], 3)

        expect(orders).to be_empty
        expect(DRCM).not_to have_received(:ensure_copper_on_hand)
        expect(DRC).to have_received(:message).with('Counted 3 "an intricate decay sigil-scroll comprised of broad strokes" in your duffel bag as decay sigil-scrolls, so none is bought for them: ' \
                                                    'the name holds "decay sigil-scroll", but its noun could not be read. If they are not, move them out of your duffel bag and start again.')
        expect(DRC).to have_received(:message).with(a_string_starting_with('Counted 3 "an intricate congruence sigil-scroll comprised of broad strokes" in your duffel bag as congruence sigil-scrolls'))
      end

      # "intricate decay sigil-scroll etched in delicate detail" is a real
      # sigil-scroll (noun-corpus.tsv, noun="sigil-scroll"), whose noun
      # get_noun reads past its flavor.
      it 'counts, without a word, a scroll whose noun get_noun reads past its flavor, and only for its own sigil' do
        scrolls('decay sigil-scroll etched in delicate detail', 'decay sigil-scroll etched in delicate detail', 'congruence sigil-scroll')

        dorhum.buy_sigils(%w[congruence decay], 3)

        expect(orders.tally).to eq({ [14_753, 3] => 2, [14_753, 10] => 1 })
        expect(DRC).not_to have_received(:message).with(/\ACounted/)
      end

      it 'buys every scroll when INVENTORY goes unanswered, as when RUMMAGE did' do
        inventory_replies({})

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
        inventory_replies('inventory backpack' => inventoried(['a smooth rock', 'some coral dye', 'a rock'], container: 'backpack', noun: 'backpack'))
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
        inventory_replies('inventory backpack' => inventoried(['a rock'], container: 'backpack', noun: 'backpack'))
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
        inventory_replies('inventory backpack' => inventoried([], container: 'backpack', noun: 'backpack'))

        expect { tm.resume_task }.to raise_error(SystemExit)

        expect(Lich::Util).to have_received(:issue_command).with('inventory backpack', any_args).once
        expect(tm).to have_received(:enchant_items).with('spongestone', 'rock', 3)
      end

      describe 'what counts as an item of the noun in task_loot_bag' do
        def check(noun, *names)
          inventory_replies('inventory backpack' => inventoried(names, container: 'backpack', noun: 'backpack'))
          dorhum.send(:check_loot_bag_clear, noun)
        end

        # Logged items from reward sacks (Hollow Eve 2026) and a deed for a
        # tin ingot (noun-corpus.tsv, noun="deed").
        it 'carries on when task_loot_bag holds none, though it holds other items' do
          tm = dorhum
          %i[ensure_tools buy_sigils forage_rocks go_to_enchanting_room enchant_items repair].each { |step| allow(tm).to receive(step) }
          allow(DRCC).to receive(:fount)
          inventory_replies('inventory backpack' => inventoried(['a large tyrium bar', 'some coral dye', 'a deed for a tin ingot'], container: 'backpack', noun: 'backpack'))

          expect { tm.dorhum('spongestone', 5, %w[congruence decay]) }.not_to raise_error

          expect(tm).to have_received(:enchant_items).with('spongestone', 'rock', 5)
        end

        # A real wand (noun-corpus.tsv: noun="wand", 101 sightings) whose
        # name goes on past its noun. Counting names that end in "wand"
        # let a virga wand task put its wands in with it, and the hand-in's
        # GET of a wand could give it away.
        it 'stops for a wand whose name goes on past "wand"' do
          expect { check('wand', 'a sturdy ironwood wand wrapped in braided lengths of sinew') }.to raise_error(SystemExit)

          expect(DRC).to have_received(:message).with('backpack already holds 1 wand that this task has not made or could not hand in: left from another task, not taken at the hand-in, or your own. ' \
                                                      'The hand-in would give those first. Move them out of backpack, then start again.')
        end

        # Each holds the task's noun but reads as another, as its noun= in
        # noun-corpus.tsv says ("deed", "instructions"; the rock marble deed
        # is the Dorhum reward count_listed names). The hand-in's GET of a
        # rock, shell or wand would not take them, so a player who keeps
        # them in task_loot_bag is not stopped. get_noun read every rock,
        # shell and wand logged in November 2026 as its noun, so no real
        # one is waved through this way.
        it 'carries on past items that hold the noun but whose noun reads as another' do
          { 'rock' => ['a rock marble deed', 'a deed for a large anjisis rock'], 'shell' => ['some glow shell instructions'], 'wand' => ['some virga wand instructions'] }.each do |noun, names|
            expect { check(noun, *names) }.not_to raise_error, "#{noun}: #{names.inspect}"
          end

          expect(DRC).not_to have_received(:message)
        end

        it 'counts a rock next to a rock marble deed, and only the rock' do
          expect { check('rock', 'a rock marble deed', 'a smooth rock') }.to raise_error(SystemExit)

          expect(DRC).to have_received(:message).with('backpack already holds 1 rock that this task has not made or could not hand in: left from another task, not taken at the hand-in, or your own. ' \
                                                      'The hand-in would give those first. Move them out of backpack, then start again.')
        end

        # An item no noun can be read off may be one of the noun, so it
        # stops the run, named. The one such name in noun-corpus.tsv (a
        # room object, used here only for its name) stands in for it.
        it 'stops, naming it, for an item that holds the noun but has no noun read off it' do
          expect { check('building', 'burned out skeleton of a ruined building') }.to raise_error(SystemExit)

          expect(DRC).to have_received(:message).with(a_string_ending_with('Move them out of backpack, then start again. Counted as buildings, since taskmaster can\'t tell that it is not: ' \
                                                                           '"burned out skeleton of a ruined building".'))
        end

        it 'does not count an item that only holds part of the noun, or none of it' do
          expect { check('rock', 'some rocks', 'a spongestone', 'a large tyrium bar') }.not_to raise_error
        end

        it 'carries on when INVENTORY goes unanswered, as when RUMMAGE did' do
          inventory_replies({})

          expect { dorhum.send(:check_loot_bag_clear, 'rock') }.not_to raise_error
        end
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
        inventory_replies('inventory duffel bag' => inventoried(Array.new(8, 'an intricate decay sigil-scroll')))
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

  # Nezhiri's alchemy tasks, replayed from another player's Hollow Eve 2026
  # Nezhiri task logs (cite keys 6100..6106, see
  # spec/fixtures/taskmaster/log_lines.json). Every game reply is a logged
  # line, ReplayGame.log, or a whole logged window from a transcript; the few
  # lines no log has are ReplayGame.code and say where they come from. The
  # commands were sent by the logging player's client script. Cite key 6400
  # is a task run by taskmaster itself.
  describe "Nezhiri's alchemy tasks" do
    # The real stock table, so the order numbers and prices are the ones
    # taskmaster reads in game (get_data('crafting')['stock']).
    let(:stock) { YAML.unsafe_load_file(File.expand_path('../data/base-crafting.yaml', __dir__))['stock'] }

    # What read_remedy_instructions returns for each product, from the logs.
    let(:moisturizer_recipe) do
      { noun: 'moisturizer', herb: 'red flower', stock: 'red flowers', vessel: 'mortar', heals: 'provide minor external healing over the entire body',
        product: 'scale moisturizer', order: 13, price: 343, pieces: 5 }
    end
    let(:draught_recipe) do
      { noun: 'draught', herb: 'junliar', stock: 'junliar', vessel: 'bowl', heals: 'heal internal wounds of the back',
        product: 'deep-sea draught', order: 9, price: 531, pieces: 5 }
    end
    let(:glop_recipe) do
      { noun: 'glop', herb: 'georin', stock: 'georin', vessel: 'mortar', heals: 'heal external wounds of the neck',
        product: 'gill glop', order: 7, price: 437, pieces: 5 }
    end
    let(:potion_recipe) do
      { noun: 'potion', herb: 'aevaes', stock: 'aevaes', vessel: 'bowl', heals: 'heal internal wounds of the eyes',
        product: 'landsickness potion', order: 10, price: 537, pieces: 5 }
    end

    # remedy_takes_stocked? answers true, for the remedy.lic shipped with
    # this taskmaster, unless real_remedy_check: true (its own examples).
    def nezhiri_tm(real_remedy_check: false, **ivars)
      tm = build(npc: 'nezhiri', stockdata: stock, rooms: TaskMaster::ROOMS, **ivars)
      allow(tm).to receive(:remedy_takes_stocked?).and_return(true) unless real_remedy_check
      tm
    end

    # A replay for the example: the game answers DRC.bput, fput and
    # Lich::Util.issue_command from log lines, the commons helpers move
    # things in a model of the bags and hands, and Nezhiri stands in the
    # room, so find_npc walks nowhere (a walk would show in the timeline).
    def replay(inventory: {})
      game = ReplayGame.new.install(self)
      commons = ReplayCommons.new(game: game, inventory: inventory).install(self)
      DRRoom.npcs = ['Nezhiri']
      [game, commons]
    end

    def transcript(run)
      ReplayTranscript.load(File.expand_path("fixtures/taskmaster/transcripts/#{run}.json", __dir__))
    end

    # The logged lines of one log from one line to another (log lines not in
    # the fixture, the commands, are skipped).
    def logged(log, from, to)
      (from..to).filter_map { |line| ReplayGame.log("#{log}:#{line}") if ReplayGame.log_lines.key?("#{log}:#{line}") }
    end

    # Logged READs of each product's instructions: uses line, title,
    # description and ingredients.
    let(:reads) do
      { 'moisturizer' => logged(6100, 208, 220), 'potion' => logged(6100, 3915, 3927), 'draught' => logged(6100, 6126, 6138), 'glop' => logged(6100, 8648, 8660) }
    end

    describe 'the task journal' do
      it "reads every logged Nezhiri journal as doses of a whole product, and Dorhum's and Zasele's journals as before" do
        tm = nezhiri_tm
        journals = { '6100:154' => ['moisturizer', 12, 'scale moisturizer'], '6100:3908' => ['potion', 15, 'landsickness potion'],
                     '6100:6119' => ['draught', 14, 'deep-sea draught'], '6100:8641' => ['glop', 13, 'gill glop'],
                     '6101:24' => ['moisturizer', 12, 'scale moisturizer'], '6102:23' => ['draught', 14, 'deep-sea draught'],
                     '6103:49' => ['potion', 15, 'landsickness potion'], '6104:28' => ['glop', 14, 'gill glop'],
                     '6105:74' => ['draught', 15, 'deep-sea draught'], '6106:56' => ['glop', 12, 'gill glop'] }
        read = journals.keys.map do |cite|
          game = replay.first
          game.script('task', ReplayGame.log(cite))
          [*tm.read_task, tm.instance_variable_get(:@task_product), tm.instance_variable_get(:@task_giver)]
        end
        expect(read).to eq(journals.values.map { |entry| [*entry, 'nezhiri'] })
        expect(DRC).to have_received(:message).with('Making 12 doses of scale moisturizer').twice

        # Dorhum's real journal (same log) and Zasele's (her test journal) keep
        # their captures: no "doses", so the count is the number before
        # "would suffice", as it always was.
        dorhum = build(npc: 'dorhum')
        replay.first.script('task', ReplayGame.log('6100:12881'))
        expect([*dorhum.read_task, dorhum.instance_variable_get(:@task_product)]).to eq(['spongestone', 6, 'spongestone'])
        expect(DRC).to have_received(:message).with('Making 6 spongestones')
        expect(TaskMaster::TASK_JOURNAL.match(journal('a coil of reinforced cloth rope', 5, 2)).captures).to eq([nil, 'a coil of reinforced cloth rope', '5', '2'])
        expect(TaskMaster::TASK_JOURNAL.match(journal('a coil of reinforced cloth rope', 5)).captures).to eq([nil, 'a coil of reinforced cloth rope', '5', nil])
      end

      it "says to finish Nezhiri's task with ;taskmaster nezhiri when another taskmaster's run finds it" do
        tm = build(npc: 'zasele')
        allow(tm).to receive(:find_npc)
        replay.first.script('task', ReplayGame.log('6100:154'))
        expect(tm).not_to receive(:turn_in_banked)

        expect { tm.resume_task }.to raise_error(SystemExit)

        expect(DRC).to have_received(:message)
          .with('You are on a task for Nezhiri, not Zasele. Finish it with ;taskmaster nezhiri, or cancel it with ASK NEZHIRI FOR TASK CANCEL (taskmasters then refuse you for about ten minutes). Or set task_cancel_foreign_tasks to have taskmaster cancel such tasks itself.')
      end
    end

    describe '#get_task' do
      it 'asks twice, accepts, reads the journal and the instructions, all from one logged task (6100:132-220)' do
        tm = nezhiri_tm
        game, = replay
        transcript('2026-11-06_6100_accept_moisturizer')
          .script(game, commands: /\A(?:ask nezhiri for task|accept task|task|read my moisturizer instructions)\z/, skip: [183, 192])

        item, count, recipe = tm.get_task

        expect([item, count, recipe]).to eq(['moisturizer', 12, moisturizer_recipe.merge(uses: 13)])
        expect(game.timeline).to eq(['>> ask nezhiri for task', '>> ask nezhiri for task', '>> accept task', '>> task', '>> read my moisturizer instructions',
                                     '** DRCC.stow_crafting_item("moisturizer instructions", "duffel bag", nil)'])
        # Her accept prints "[You can check your progress with the TASK verb.]"
        # (6100:150): no reply was waited out.
        expect([game.clock, game.diagnostics]).to eq([0.0, []])
      end

      it 'boosts past "you must wait", then asks twice and accepts (6100:10293-10338)' do
        tm = nezhiri_tm(boost: true, cooldown_poll: 15)
        game, = replay
        transcript('2026-11-06_6100_boost_draught')
          .script(game, commands: /\A(?:ask nezhiri for task|boost task|accept task|task|read my draught instructions)\z/)

        item, count, recipe = tm.get_task

        expect([item, count, recipe]).to eq(['draught', 13, draught_recipe.merge(uses: 14)])
        expect(game.timeline(calls: false)).to eq(['>> ask nezhiri for task', '>> boost task', '>> ask nezhiri for task', '>> ask nezhiri for task',
                                                   '>> accept task', '>> task', '>> read my draught instructions'])
        expect([game.clock, game.diagnostics, tm.instance_variable_get(:@boost)]).to eq([2.0, [], false])
      end

      it 'spends the poll interval on her supplies instead when it has no boost, then takes the same offer' do
        tm = nezhiri_tm(boost: false, cooldown_poll: 15)
        game, = replay
        transcript('2026-11-06_6100_boost_draught')
          .script(game, commands: /\A(?:ask nezhiri for task|accept task|task|read my draught instructions)\z/)
        allow(tm).to receive(:survey_remedy_supplies) { game.record_call('survey_remedy_supplies') }

        expect(tm.get_task.first(2)).to eq(['draught', 13])
        expect(game.sent).not_to include('boost task')
        expect(game.timeline.first(3)).to eq(['>> ask nezhiri for task', '** survey_remedy_supplies', '>> ask nezhiri for task'])
        expect(game.clock).to be_within(1).of(15.0)
      end
    end

    describe '#read_instructions' do
      it "reads each product's logged instructions and returns its recipe, with order number and price from base-crafting.yaml" do
        recipes = { 'moisturizer' => moisturizer_recipe.merge(uses: 13), 'potion' => potion_recipe.merge(uses: 16),
                    'draught' => draught_recipe.merge(uses: 15), 'glop' => glop_recipe.merge(uses: 14) }
        recipes.each do |noun, recipe|
          tm = nezhiri_tm(task_product: recipe[:product])
          game, = replay
          game.script("read my #{noun} instructions", *reads[noun])

          expect(tm.read_instructions(noun, 12)).to eq([noun, 12, recipe])
          expect(game.timeline).to eq([">> read my #{noun} instructions", "** DRCC.stow_crafting_item(\"#{noun} instructions\", \"duffel bag\", nil)"])
        end
      end

      # A roundtime refusal before the READ ("...wait 6 seconds.", 6100:14245,
      # after a study) is sat out inside issue_command's timeout. At its
      # default 5 s the READ came back empty and the run paused and stopped.
      it 'reads the set after a "...wait" longer than issue_command\'s default 5 s, since the READ waits as long as bput (6100:14245)' do
        tm = nezhiri_tm(task_product: 'gill glop')
        game, = replay
        game.script('read my glop instructions', ReplayGame.log('6100:14245'))
        game.script('read my glop instructions', *reads['glop'])
        expect(tm).not_to receive(:pause_script)

        expect(tm.read_instructions('glop', 13)).to eq(['glop', 13, glop_recipe.merge(uses: 14)])
        expect([game.sent, game.clock]).to eq([['read my glop instructions'] * 2, 6.0])
      end

      it 'still pauses when the READ is not answered within those 15 s' do
        tm = nezhiri_tm(task_product: 'gill glop')
        game, = replay
        game.script('read my glop instructions', ReplayGame.log('6100:14245'))
        game.script('read my glop instructions', ReplayGame.log('6100:13450'))
        expect(tm).to receive(:pause_script)

        expect { tm.read_instructions('glop', 13) }.to raise_error(SystemExit)
        expect(game.clock).to eq(15.0)
        expect(DRC).to have_received(:message).with(a_string_including('no title was read'))
      end

      it 'takes the product from the title when no journal was read' do
        tm = nezhiri_tm
        replay.first.script('read my glop instructions', *reads['glop'])

        expect(tm.read_instructions('glop', 13).last).to eq(glop_recipe.merge(uses: 14))
      end

      it 'pins every Nezhiri product to an herb the Crossing alchemy supplies sell, at the order number and price on its menu (6102:72-78)' do
        menu = %w[6102:72 6102:74 6102:75 6102:78].to_h do |cite|
          number, name, price = ReplayGame.log(cite).text.match(/(\d+)\)\.\s+\(25 pieces\) (.+?)\.{2,}\s*(\d+) Kronars/).captures
          [name, [number.to_i, price.to_i]]
        end
        shop_names = { 'georin' => 'dried georin', 'red flowers' => 'dried red flowers', 'aevaes' => 'crushed aevaes', 'junliar' => 'crushed junliar' }
        stocked = TaskMaster::NEZHIRI_ITEMS.values.to_h { |recipe| [shop_names.fetch(recipe[:stock]), stock.fetch(recipe[:stock]).values_at('stock-number', 'stock-value')] }
        expect(stocked).to eq(menu)
      end

      describe 'instructions that are not what taskmaster expects' do
        # Each pauses with a message, then stops when unpaused, after the
        # instructions are stowed.
        def refused(tm, noun, reply, message)
          game, = replay
          game.script("read my #{noun} instructions", *reply)
          expect(tm).to receive(:pause_script)

          expect { tm.read_instructions(noun, 13) }.to raise_error(SystemExit)

          expect(game.timeline).to include("** DRCC.stow_crafting_item(\"#{noun} instructions\", \"duffel bag\", nil)")
          expect(DRC).to have_received(:message).with("#{message} Pausing; make them yourself, or kill the script. Unpausing stops it.")
          game
        end

        it "pauses on a product taskmaster does not know (Dorhum's real spongestone instructions)" do
          refused(nezhiri_tm(task_product: 'spongestone'), 'spongestone', logged(6100, 12888, 12901),
                  "taskmaster does not know how to make Nezhiri's spongestone yet.")
        end

        it 'pauses when the instructions are for another product than the journal names' do
          refused(nezhiri_tm(task_product: 'gill glop'), 'glop', reads['draught'],
                  'The glop instructions do not read as taskmaster expects for gill glop: they are for deep-sea draught.')
        end

        it "pauses when the title's product has another noun than the one asked for" do
          refused(nezhiri_tm, 'potion', reads['glop'], 'The potion instructions are for gill glop, which is not a potion.')
        end

        # Real lines, in a combination no log has: the gill glop READ with the
        # deep-sea draught's herb line (6100:6136) in place of its own.
        it 'pauses when the herb heals something else than the product needs' do
          reply = reads['glop'].map { |line| line.cite == '6100:8658' ? ReplayGame.log('6100:6136') : line }
          refused(nezhiri_tm(task_product: 'gill glop'), 'glop', reply,
                  'The glop instructions do not read as taskmaster expects for gill glop: the herb is known to heal internal wounds of the back, not to heal external wounds of the neck.')
        end

        it 'pauses when each use takes another number of herb pieces' do
          four = ReplayGame.code('   (4) prepared herb (pieces per use, known to heal external wounds of the neck)', from: '6100:8658 with another piece count')
          reply = reads['glop'].map { |line| line.cite == '6100:8658' ? four : line }
          refused(nezhiri_tm(task_product: 'gill glop'), 'glop', reply,
                  'The glop instructions do not read as taskmaster expects for gill glop: each use takes 4 herb pieces, not 5.')
        end

        it 'pauses when the brine line is missing' do
          reply = reads['glop'].reject { |line| line.cite == '6100:8659' }
          refused(nezhiri_tm(task_product: 'gill glop'), 'glop', reply,
                  'The glop instructions do not read as taskmaster expects for gill glop: no brine line was read.')
        end

        it 'pauses when no herb line was read' do
          reply = reads['glop'].reject { |line| line.cite == '6100:8658' }
          refused(nezhiri_tm(task_product: 'gill glop'), 'glop', reply,
                  'The glop instructions do not read as taskmaster expects for gill glop: no herb line was read.')
        end

        it 'pauses after the READ times out when no instructions are carried' do
          game = refused(nezhiri_tm(task_product: 'gill glop'), 'glop', [ReplayGame.log('6100:202')],
                         'The glop instructions do not read as taskmaster expects for gill glop: no title was read.')
          expect(game.clock).to eq(15.0) # TaskMaster::NEZHIRI_READ_TIMEOUT
        end

        it "pauses when base-crafting.yaml has no stock entry for the product's herb" do
          refused(nezhiri_tm(task_product: 'gill glop', stockdata: stock.except('georin')), 'glop', reads['glop'],
                  "base-crafting.yaml has no stock entry 'georin' for gill glop's herb.")
        end
      end
    end

    describe '#ensure_instructions' do
      it 'asks Nezhiri for a replacement when no set is carried, which has a use per dose owed (6100:2944-2963)' do
        tm = nezhiri_tm(task_product: 'scale moisturizer')
        game, = replay
        transcript('2026-11-06_6100_replacement_moisturizer')
          .script(game, commands: /\A(?:ask nezhiri for instructions|read my moisturizer instructions)\z/)

        tm.ensure_instructions('moisturizer', 12)
        recipe = tm.read_instructions('moisturizer', 12).last

        expect(game.timeline(calls: false)).to eq(['>> ask nezhiri for instructions', '>> read my moisturizer instructions'])
        expect(UserVars.taskmaster_replacements).to eq('nezhiri' => 'moisturizer')
        expect(recipe[:uses]).to eq(12)
      end

      # The set carried at 6100:3780 had 10 uses left with 12 doses owed
      # (6100:3546): two crafts' worth.
      it 'keeps a set with fewer uses than doses owed while it has a use for each craft still to make' do
        tm = nezhiri_tm
        game, commons = replay(inventory: { 'scale moisturizer instructions' => 'duffel bag' })
        game.script('read my moisturizer instructions', ReplayGame.log('6100:3780'))

        tm.ensure_instructions('moisturizer', 12)

        expect(game.sent).to eq(['read my moisturizer instructions'])
        expect([$right_hand, commons.inventory]).to eq(['scale moisturizer instructions', []])
        expect(UserVars.taskmaster_replacements).to be_nil
      end

      # The set at 6100:1576 had one use left: enough for 6 doses (one craft),
      # not for 7 (two).
      it 'asks for a replacement only when the uses left are fewer than the crafts still to make' do
        outcomes = [6, 7].map do |doses|
          UserVars.taskmaster_replacements = nil
          tm = nezhiri_tm
          game, = replay(inventory: { 'scale moisturizer instructions' => 'duffel bag' })
          $right_hand = nil
          game.script('read my moisturizer instructions', ReplayGame.log('6100:1576'))
          game.script('ask nezhiri for instructions', ReplayGame.log('6100:2949')) # her replacement reply, later in the same log
          tm.ensure_instructions('moisturizer', doses)
          game.timeline
        end
        # With 7 doses the short set goes back, and the bag holds no second set.
        expect(outcomes).to eq([['** DRCI.in_hands?("moisturizer instructions")', '** DRCI.get_item?("moisturizer instructions", "duffel bag")',
                                 '>> read my moisturizer instructions'],
                                ['** DRCI.in_hands?("moisturizer instructions")', '** DRCI.get_item?("moisturizer instructions", "duffel bag")',
                                 '>> read my moisturizer instructions', '** DRCC.stow_crafting_item("moisturizer instructions", "duffel bag", nil)',
                                 '** DRCI.get_item?("second moisturizer instructions", "duffel bag")', '>> ask nezhiri for instructions']])
      end

      # The set at 6100:1576 has one use left. With 5 doses a craft
      # remembered for the task's product, 6 doses are two crafts, so it is
      # not enough; a yield remembered for another product changes nothing.
      it "counts the crafts at the doses a craft the journal's product made last time, and at 6 for another product's" do
        outcomes = [{ 'scale moisturizer' => 5 }, { 'gill glop' => 5 }].map do |remembered|
          UserVars.taskmaster_replacements = nil
          UserVars.taskmaster_remedy_yields = remembered
          tm = nezhiri_tm(task_product: 'scale moisturizer')
          game, = replay(inventory: { 'scale moisturizer instructions' => 'duffel bag' })
          $right_hand = nil
          game.script('read my moisturizer instructions', ReplayGame.log('6100:1576'))
          game.script('ask nezhiri for instructions', ReplayGame.log('6100:2949'))
          tm.ensure_instructions('moisturizer', 6)
          game.sent
        end
        expect(outcomes).to eq([['read my moisturizer instructions', 'ask nezhiri for instructions'], ['read my moisturizer instructions']])
      end

      it 'counts the crafts as doses over six, rounded up, and none for no doses' do
        tm = nezhiri_tm
        expect([-3, 0, 1, 6, 7, 12, 13, 18, 19].map { |doses| tm.nezhiri_crafts(doses) }).to eq([0, 0, 1, 1, 2, 2, 3, 3, 4])
      end
    end

    describe 'cancelling her task' do
      # Her cancel replies are in no log. Built from TASK_CANCEL_CONFIRM and
      # TASK_CANCELLED in Dorhum's logged wording, with her title as she says
      # "you must wait" (6100:10294).
      let(:confirm) do
        ReplayGame.code('Potion Peddler Nezhiri looks at you and says, "You wish to end your current task?  If so, ask me again within fifteen seconds."',
                        from: 'taskmaster.lic TASK_CANCEL_CONFIRM, with the title of 6100:10294')
      end
      let(:cancelled) do
        ReplayGame.code('Potion Peddler Nezhiri says, "Very well, I see that you no longer wish to assist me."', from: 'taskmaster.lic TASK_CANCELLED, with the title of 6100:10294')
      end

      it 'takes the replies of a taskmaster with a two-word title, asking twice as the game wants' do
        tm = build(npc: 'zasele', worn_trashcan: 'bucket', worn_trashcan_verb: 'tap', rooms: TaskMaster::ROOMS)
        game, = replay
        game.script('ask nezhiri for task cancel', confirm)
        game.script('ask nezhiri for task cancel', cancelled)
        allow(DRCT).to receive(:dispose)

        expect { tm.cancel_task('nezhiri', 'glop') }.not_to raise_error

        expect(game.sent).to eq(['ask nezhiri for task cancel'] * 2)
        expect(DRCT).to have_received(:dispose).with('glop instructions', nil, 'bucket', 'tap')
      end

      it 'matches her real line by its two-word title, still a one-word title, and not a player looking at her' do
        tm = build
        player = 'Mallory looks at Potion Peddler Nezhiri and says, "Very well, I see that you no longer wish to assist me."'
        expect(tm.cancel_reply('nezhiri', 'you must wait before I can give you a task')).to match(ReplayGame.log('6100:10294').text)
        expect(tm.cancel_reply('dorhum', TaskMaster::TASK_CANCELLED)).to match('Researcher Dorhum says, "Very well, I see that you no longer wish to assist me."')
        expect(tm.cancel_reply('nezhiri', TaskMaster::TASK_CANCELLED)).not_to match(player)
      end
    end

    describe 'taking her as a taskmaster' do
      it 'offers nezhiri as a taskmaster, with her tools and a sack history, but never picks her for cycle' do
        expect(TaskMaster::ARG_DEFINITIONS.first.first[:options]).to include('nezhiri')
        expect(TaskMaster::TASKMASTERS).to include('nezhiri')
        expect(TaskMaster::TOOLS['nezhiri']).to eq(['mortar', 'pestle', 'bowl', 'mixing stick', 'sieve'])

        tm = described_class.allocate
        allow(tm).to receive(:get_settings).and_return(OpenStruct.new)
        allow(tm).to receive(:get_data).and_return({ 'stock' => {} })
        UserVars.taskmaster_sacks = nil
        tm.send(:initialize)
        expect(UserVars.taskmaster_sacks).to include('nezhiri' => [])

        source = File.read(File.expand_path('../taskmaster.lic', __dir__))
        expect(source.scan(/\[[^\]]*\]\.sample/)).to all(eq("['poltu', 'bradyn', 'zasele'].sample"))
      end
    end

    # After sew stopped on a piece too small to use, repair's DRCI.stow_hands
    # (task_no_repair) put the scrap and the knitting needles in the pack,
    # and sew's next GET by the scrap's remembered id took it back from there
    # (Lilwea, 2026-11-11 08:32:01 "You get some burlap cloth from inside
    # your traveler's pack.").
    describe '#put_hands_away' do
      let(:belt) { { 'name' => "tailor's.toolbelt", 'items' => ['knitting needles', 'clockwork scissors', 'sewing needles'] } }
      let(:empty) { OpenStruct.new(name: 'Empty', noun: nil, id: nil) }

      def hold(right: nil, left: nil)
        allow(GameObj).to receive(:right_hand).and_return(right || empty)
        allow(GameObj).to receive(:left_hand).and_return(left || empty)
      end

      def obj(name, noun, id)
        OpenStruct.new(name: name, noun: noun, id: id)
      end

      before do
        allow(DRCI).to receive(:put_away_item?).and_return(true)
        allow(DRCC).to receive(:stow_crafting_item).and_return(true)
        allow(DRCI).to receive(:stow_hands)
      end

      it 'puts a raw piece of stock in the crafting bag by its id and ties a belt tool to the belt' do
        hold(right: obj('polished loimic knitting needles', 'needles', '24321517'), left: obj('wool yarn', 'yarn', '25735696'))
        build(settings: { outfitting_belt: belt }).put_hands_away
        expect(DRCI).to have_received(:put_away_item?).with('#25735696', 'duffel bag')
        expect(DRCC).to have_received(:stow_crafting_item).with('knitting needles', 'duffel bag', belt)
        expect(DRCI).to have_received(:stow_hands)
      end

      it 'knows rat-pelt leather and burlap cloth as stock' do
        hold(right: obj('rat-pelt leather', 'leather', '1'), left: obj('burlap cloth', 'cloth', '2'))
        build(settings: { outfitting_belt: belt }).put_hands_away
        expect(DRCI).to have_received(:put_away_item?).with('#1', 'duffel bag')
        expect(DRCI).to have_received(:put_away_item?).with('#2', 'duffel bag')
      end

      it 'leaves an unfinished piece to the default container, never the crafting bag' do
        hold(left: obj('coil of unfinished burlap reinforced rope', 'rope', '3'))
        build(settings: { outfitting_belt: belt }).put_hands_away
        expect(DRCI).not_to have_received(:put_away_item?)
        expect(DRCC).not_to have_received(:stow_crafting_item)
        expect(DRCI).to have_received(:stow_hands)
      end

      it 'does not take worn-looking leathers or other cloth for stock' do
        hold(right: obj('silk cloth', 'cloth', '4'), left: obj('sinuous leathers', 'leathers', '5'))
        build(settings: { outfitting_belt: belt }).put_hands_away
        expect(DRCI).not_to have_received(:put_away_item?)
        expect(DRCI).to have_received(:stow_hands)
      end

      it 'puts instructions in the crafting bag, never on the belt' do
        hold(right: obj('reinforced netting instructions', 'instructions', '6'))
        build(settings: { outfitting_belt: belt }).put_hands_away
        expect(DRCC).to have_received(:stow_crafting_item).with('instructions', 'duffel bag', nil)
      end

      it 'leaves a tool the belt does not list to the default container' do
        hold(right: obj('steel serrated bone saw', 'saw', '7'))
        build(settings: { outfitting_belt: belt }).put_hands_away
        expect(DRCC).not_to have_received(:stow_crafting_item)
        expect(DRCI).to have_received(:stow_hands)
      end

      # GLANCE as the game words it (reconcile_hands' fixtures).
      def glance(reply)
        allow(DRC).to receive(:bput).with('glance', any_args).and_return(reply)
      end

      it 'puts a tool crafting_items_in_container lists in the crafting bag, with no belt listing it (Bradyn\'s chisels)' do
        hold(right: obj('iron chisels', 'chisels', '9'))
        glance('You glance down to see some iron chisels in your right hand.')
        build(npc: 'bradyn', bag_items: ['chisels', 'bone saw']).put_hands_away
        expect(DRCC).to have_received(:stow_crafting_item).with('chisels', 'duffel bag', nil)
        expect(DRCI).to have_received(:stow_hands)
      end

      # A stray '-' line in the list loads as nil ("crafting_items_in_container:
      # \n  - chisels\n  -\n" gives ["chisels", nil]); main never matched
      # these entries, so such a profile ran.
      it 'ignores a blank or non-String crafting_items_in_container entry: no crash, no stow by an empty name' do
        bag_items = YAML.safe_load("crafting_items_in_container:\n  - chisels\n  -\n  - ''\n  - 5\n")['crafting_items_in_container']
        expect(bag_items).to eq(['chisels', nil, '', 5])
        hold(right: obj('iron chisels', 'chisels', '9'), left: obj('polished loimic slender awl', 'awl', '10'))
        glance('You glance down to see some iron chisels in your right hand and a polished loimic slender awl in your left hand.')
        expect { build(npc: 'bradyn', bag_items: bag_items).put_hands_away(nil) }.not_to raise_error
        expect(DRCC).to have_received(:stow_crafting_item).once
        expect(DRCC).to have_received(:stow_crafting_item).with('chisels', 'duffel bag', nil)
        expect(DRCI).to have_received(:stow_hands)
      end

      it 'ignores a blank or nil belt entry the same way' do
        hold(right: obj('polished loimic slender awl', 'awl', '10'))
        tied = { 'name' => 'toolbelt', 'items' => [nil, ' ', 'scissors'] }
        expect { build.put_hands_away(tied) }.not_to raise_error
        expect(DRCC).not_to have_received(:stow_crafting_item)
        expect(DRCI).to have_received(:stow_hands)
      end

      it 'leaves an unfinished piece whose hand tag leaves "unfinished" out to the default container, by its full name from GLANCE' do
        hold(left: obj('reinforced rope', 'rope', '3'))
        glance('You glance down to see a coil of unfinished burlap reinforced rope in your left hand.')
        build(bag_items: ['rope']).put_hands_away
        expect(DRCC).not_to have_received(:stow_crafting_item)
        expect(DRCI).to have_received(:stow_hands)
      end

      # The hand changed between the hand tag and GLANCE: a well-formed
      # GLANCE that names another item (no "rope" in it) does not vouch for
      # the rope held, which goes to the default container.
      it 'leaves a bag item in hand to the default container when GLANCE names an item without its noun' do
        hold(left: obj('reinforced rope', 'rope', '3'))
        glance('You glance down to see a brass hammer in your left hand.')
        build(bag_items: ['rope']).put_hands_away
        expect(DRCC).not_to have_received(:stow_crafting_item)
        expect(DRCI).to have_received(:stow_hands)
      end

      it 'leaves a bag item in hand to the default container when GLANCE does not name it' do
        hold(right: obj('iron chisels', 'chisels', '9'))
        glance('')
        build(npc: 'bradyn', bag_items: ['chisels']).put_hands_away
        expect(DRCC).not_to have_received(:stow_crafting_item)
        expect(DRCI).to have_received(:stow_hands)
      end

      it 'leaves an unfinished piece to the default container even when crafting_items_in_container names its noun' do
        hold(left: obj('coil of unfinished burlap reinforced rope', 'rope', '3'))
        build(bag_items: ['rope']).put_hands_away
        expect(DRCC).not_to have_received(:stow_crafting_item)
      end

      it "uses the taskmaster's own belt setting" do
        forging = { 'name' => 'forging belt', 'items' => ['forging hammer'] }
        hold(right: obj('ball-peen forging hammer', 'hammer', '8'))
        build(npc: 'poltu', settings: { forging_belt: forging, outfitting_belt: belt }).put_hands_away
        expect(DRCC).to have_received(:stow_crafting_item).with('forging hammer', 'duffel bag', forging)
      end

      it 'still stows with no belt set and empty hands' do
        hold
        build.put_hands_away
        expect(DRCI).not_to have_received(:put_away_item?)
        expect(DRCI).to have_received(:stow_hands)
      end

      it 'is what repair uses with task_no_repair, with the belt repair was given' do
        hold(right: obj('polished loimic knitting needles', 'needles', '9'), left: obj('wool yarn', 'yarn', '10'))
        build(no_repair: true).repair(['knitting needles'], belt)
        expect(DRCI).to have_received(:put_away_item?).with('#10', 'duffel bag')
        expect(DRCC).to have_received(:stow_crafting_item).with('knitting needles', 'duffel bag', belt)
      end
    end

    # Layer 3: taskmaster makes her remedies. Whole logged tasks are replayed
    # from ask to reward sack: every game reply is a logged line (from a
    # transcript, or ReplayGame.log), except INVENTORY of the crafting bag,
    # which the logging player's client script never sent (its replies are
    # code-derived, in the format Kythkani's "inve sack" logged on
    # 2026-11-09). remedy itself is not run: a stub
    # leaves the product in hand with an id of its own, as remedy leaves it
    # (6 uses each time, as every craft in 6100..6106 counted). The ids are made up
    # (code-derived): the logs carry none. Commands taskmaster words by id
    # ("count #7001") are answered with the logged reply to the client
    # script's wording ("count my glop").
    # Found by a mutation sweep: afford's stop puts the hands away as it
    # always has (every taskmaster's purchases); only a Nezhiri continue
    # asks it to leave a held vessel in hand.
    describe '#afford' do
      it 'puts the hands away before stopping when the bank cannot cover it' do
        tm = build
        allow(DRCM).to receive(:ensure_copper_on_hand).and_return(false)
        allow(DRCI).to receive(:stow_hands)

        expect { tm.afford(9000) }.to raise_error(SystemExit)

        expect(DRCI).to have_received(:stow_hands)
        expect(DRC).to have_received(:message).with('Out of money: 9000 Kronars (copper) needed and the Crossing bank could not cover it. Stopping before buying anything more.')
      end

      it 'leaves the hands as they are with keep_hands' do
        tm = build
        allow(DRCM).to receive(:ensure_copper_on_hand).and_return(false)
        allow(DRCI).to receive(:stow_hands)

        expect { tm.afford(9000, keep_hands: true) }.to raise_error(SystemExit)

        expect(DRCI).not_to have_received(:stow_hands)
      end

      it 'does nothing when the copper is there' do
        tm = build
        allow(DRCM).to receive(:ensure_copper_on_hand).and_return(true)
        allow(DRCI).to receive(:stow_hands)

        tm.afford(9000)

        expect(DRCI).not_to have_received(:stow_hands)
      end
    end

    # Review of #7974 (mrhoribu): stop_buying puts the hands away as it
    # always has for every taskmaster, and leaves only ids in keep in hand.
    describe '#stop_buying' do
      it 'stows the hands before stopping, as for every taskmaster' do
        tm = build
        allow(DRCI).to receive(:stow_hands)
        allow(DRCI).to receive(:put_away_item?)

        expect { tm.stop_buying('a decay sigil-scroll') }.to raise_error(SystemExit)

        expect(DRCI).to have_received(:stow_hands)
        expect(DRCI).not_to have_received(:put_away_item?)
        expect(DRC).to have_received(:message).with('Could not buy a decay sigil-scroll. Stopping.')
      end

      it 'leaves the kept ids in hand, puts the rest in the bag by id, and says the note' do
        tm = build
        allow(tm).to receive(:hand_ids).and_return(%w[6001 8105])
        allow(DRCI).to receive(:stow_hands)
        allow(DRCI).to receive(:put_away_item?).and_return(true)

        expect { tm.stop_buying('brine', keep: ['6001'], note: 'Mind the mortar.') }.to raise_error(SystemExit)

        expect(DRCI).not_to have_received(:stow_hands)
        expect(DRCI).to have_received(:put_away_item?).with('#8105', 'duffel bag')
        expect(DRCI).not_to have_received(:put_away_item?).with('#6001', anything)
        expect(DRC).to have_received(:message).with('Could not buy brine. Mind the mortar. Stopping.')
      end
    end

    describe 'making her remedies' do
      let(:crafting) { YAML.unsafe_load_file(File.expand_path('../data/base-crafting.yaml', __dir__)) }
      # The logging player's tools: mortar, pestle and sieve on a grass
      # toolstrap (6100:8794-8797), the bowl and stick in the bag.
      let(:belt) { { 'name' => 'grass toolstrap', 'items' => %w[mortar pestle sieve] } }
      let(:settings) { { alchemy_tools: ['bowl', 'mixing stick', 'mortar', 'pestle', 'sieve'], alchemy_belt: belt, alchemy_room: 7896 } }
      # Tools and supplies as the logs show them (6100:8794-8797,
      # 6100:8905-8910).
      let(:kit) do
        [['polished belzune stone mortar', 'grass toolstrap'], ['smooth belzune pestle', 'grass toolstrap'], ['trapezoidal darkstone wire sieve', 'grass toolstrap'],
         ["khor'vela medicine bowl", 'duffel bag'], ['purpleheart mixing stick', 'duffel bag'],
         ['water', 'duffel bag'], ['grain alcohol', 'duffel bag'], ['large coal nugget', 'duffel bag']]
      end

      before { $test_data.crafting = crafting }

      # remedy_takes_stocked? answers true (the shipped remedy.lic) unless
      # real_remedy_check: true.
      def maker(settings: self.settings, real_remedy_check: false, **ivars)
        tm = build(settings: settings, npc: 'nezhiri', stockdata: crafting['stock'], rooms: TaskMaster::ROOMS, lootbag: 'velvet backpack',
                   keeplist_regex: /leather|stack/, **ivars)
        allow(tm).to receive(:remedy_takes_stocked?).and_return(true) unless real_remedy_check
        tm
      end

      # The arguments read as remedy.lic reads them: Lich joins a caller's
      # list (ArgParserModel.caller_vars), remedy's forms match it and
      # Remedy::Order.from_args builds the order. Layer 06 of the Nezhiri
      # stack: every craft says stocked (buy_remedy_supplies checked the
      # water, the alcohol and the coal for it), so remedy taps none of them
      # again; the carry-on does not, so remedy checks them itself there.
      describe "the arguments remedy is run with, read by remedy.lic's forms" do
        # @param args [Array<String>]
        # @return [Remedy::Order]
        def remedy_order(args)
          Remedy::Order.from_args(ArgParserModel.parse(Remedy::ARG_DEFINITIONS, ArgParserModel.caller_vars(args).drop(1)))
        end

        %i[moisturizer_recipe draught_recipe glop_recipe potion_recipe].each do |name|
          it "crafts the #{name.to_s.delete_suffix('_recipe')} stocked in the instructions form, and carries one on unstocked in the continue form" do
            recipe = send(name)
            craft = remedy_order(maker.remedy_args(recipe))
            carry = remedy_order(maker.remedy_continue_args(recipe))
            expect([craft.mode, craft.stocked?, craft.herb1, craft.catalyst, craft.container_request, craft.noun, craft.herb_quantity])
              .to eq([:instructions, true, recipe[:herb], 'coal nugget', recipe[:vessel], recipe[:noun], 25])
            expect([carry.mode, carry.stocked?, carry.catalyst, carry.container_request, carry.noun]).to eq([:continue, false, 'coal nugget', recipe[:vessel], recipe[:noun]])
          end
        end

        # taskmaster can be updated without remedy.lic. An older remedy
        # prints its help on the word and crafts nothing, after the task was
        # taken and its supplies bought; without the word it is run with the
        # arguments taskmaster gave it before (main's remedy_args).
        describe 'with the remedy.lic Lich would run' do
          let(:messages) { [] }
          let(:old_args) { ['instructions', 'georin', 'coal nugget', 'mortar', 'glop', '25'] }

          before { allow(DRC).to receive(:message) { |text| messages << text } }

          # @param text [String, nil] the file's text; nil for no file found
          # @return [TaskMaster]
          def with_remedy_file(text)
            tm = maker(real_remedy_check: true)
            path = text && File.join(Dir.mktmpdir, 'remedy.lic')
            File.write(path, text) if path
            allow(tm).to receive(:remedy_script_file).and_return(path)
            tm
          end

          it 'says stocked when it is the remedy.lic shipped with this taskmaster' do
            tm = with_remedy_file(File.read(File.expand_path('../remedy.lic', __dir__)))
            expect(tm.remedy_args(glop_recipe)).to eq(old_args + ['stocked'])
            expect(messages).to be_empty
          end

          it 'leaves the word out, saying so once a run, when it has no stocked word' do
            tm = with_remedy_file("class Remedy\n  ARG_DEFINITIONS = [].freeze\nend\n")
            2.times { expect(tm.remedy_args(glop_recipe)).to eq(old_args) }
            expect(messages).to eq(['Your remedy.lic does not take the stocked word (it is older than this taskmaster, or could not be read), so remedy checks the water, alcohol and coal on every craft. ' \
                                    'Update remedy.lic to skip those checks.'])
            expect(remedy_order(old_args).stocked?).to be(false)
          end

          it 'leaves the word out when Lich finds no remedy.lic, or it cannot be read' do
            expect(with_remedy_file(nil).remedy_args(glop_recipe)).to eq(old_args)
            unreadable = maker(real_remedy_check: true)
            allow(unreadable).to receive(:remedy_script_file).and_return(File.join(Dir.mktmpdir, 'missing', 'remedy.lic'))
            expect(unreadable.remedy_args(glop_recipe)).to eq(old_args)
            expect(messages.size).to eq(2)
          end

          # With repeat one taskmaster launches remedy task after task, and
          # the file Lich picks can change in between: a custom remedy taken
          # out leaves an older one in the scripts folder.
          it 'asks again at every launch, and goes by the file Lich now picks, read again only when it changes' do
            dir = Dir.mktmpdir
            custom = File.join(dir, 'custom-remedy.lic')
            standard = File.join(dir, 'remedy.lic')
            File.write(custom, File.read(File.expand_path('../remedy.lic', __dir__)))
            File.write(standard, "class Remedy\n  ARG_DEFINITIONS = [].freeze\nend\n")
            tm = maker(real_remedy_check: true)
            picked = [custom, custom, standard, standard]
            allow(tm).to receive(:remedy_script_file) { picked.shift }
            allow(File).to receive(:binread).and_call_original

            args = Array.new(4) { tm.remedy_args(glop_recipe).last }

            expect(args).to eq(['stocked', 'stocked', '25', '25'])
            expect(File).to have_received(:binread).twice
            expect(messages.size).to eq(1)
          end

          it 're-reads the file when it changes in place' do
            tm = with_remedy_file("class Remedy\nend\n")
            path = tm.send(:remedy_script_file)
            expect(tm.remedy_args(glop_recipe).last).to eq('25')

            File.write(path, "class Remedy\n  STOCKED_ARG = {}.freeze\nend\n# now longer\n")
            expect(tm.remedy_args(glop_recipe).last).to eq('stocked')
          end

          it "finds the file by Lich's own lookup, custom/ first, and gives nil when that lookup is not there" do
            tm = maker
            stub_const('SCRIPT_DIR', '/lich/scripts')
            allow(Script).to receive(:send).and_call_original
            allow(Script).to receive(:send).with(:__find_script_file, 'remedy').and_return('/custom/remedy.lic')
            expect(tm.send(:remedy_script_file)).to eq('/lich/scripts/custom/remedy.lic')

            allow(Script).to receive(:send).with(:__find_script_file, 'remedy').and_raise(NoMethodError)
            expect(tm.send(:remedy_script_file)).to be_nil
          end
        end
      end

      # The game, the commons model with shops answered through the game,
      # and Nezhiri in the room.
      def shop_world(inventory, shop: :game)
        game = ReplayGame.new(send_budget: 200).install(self)
        commons = ReplayCommons.new(game: game, inventory: inventory, shop: shop, container_gets: true, buys: { 'brine' => "brewer's brine" },
                                    orders: { 7 => 'dried georin', 9 => 'crushed junliar', 13 => 'dried red flowers', 1 => 'water', 2 => 'grain alcohol',
                                              [8775, 2] => 'massive coal nugget' },
                                    ids: { 'dried georin' => '8101', 'crushed junliar' => '8102', 'water' => '8103', 'grain alcohol' => '8104',
                                           'massive coal nugget' => '8105', 'dried red flowers' => '8106' }).install(self)
        DRRoom.npcs = ['Nezhiri']
        [game, commons]
      end

      # remedy, stubbed: each run leaves the next id's stack of the product
      # in hand, until the ids run out (then nothing, as when remedy stops).
      def remedy_makes(commons, product, ids)
        runs = []
        allow(DRC).to receive(:wait_for_script_to_complete) do |name, args|
          commons.wait_for_script_to_complete(name, args)
          runs << [name, args]
          commons.hold(product, id: ids.shift) if name == 'remedy' && !ids.empty?
        end
        runs
      end

      # A COMBINE the game took: both stacks leave the hands and one comes
      # back under a new id, as cloth did (combine_stock).
      def merges(commons, product, *ids, into:, hand: nil)
        lambda do |_game|
          ids.each { |id| commons.release("##{id}") }
          commons.hold(product, id: into, hand: hand)
        end
      end

      # A BREAK the game took: the held stack becomes two. Which hand holds
      # the marked piece is not in the logs: kept_hand says.
      def breaks(commons, product, id, kept:, rest:, kept_hand: :left)
        lambda do |_game|
          commons.release("##{id}")
          commons.hold(product, id: kept, hand: kept_hand)
          commons.hold(product, id: rest)
        end
      end

      # SWAP of the left hand's stack to the right.
      def swaps(commons, product, id)
        lambda do |_game|
          commons.release("##{id}")
          commons.hold(product, id: id, hand: :right)
        end
      end

      # INVENTORY of the duffel bag listing `names`, as reply lines.
      def bag_listed(*names)
        inventoried(names).map do |line|
          ReplayGame.code(line, from: "INVENTORY reply in the format of Kythkani's \"inve sack\" (2026-11-09 16:51:38 NZDT); the logging player's client script never sent INVENTORY")
        end
      end

      describe 'a whole logged task' do
        # The logged runs sent the vessel's two tools only; the sieve goes too
        # now, unless repaired within task_repair_every, as it is here, so the
        # log's commands still hold.
        before { UserVars.taskmaster_repaired_at = { 'sieve' => Time.now.to_i } }

        # 6100:8619-10292: 13 doses of gill glop, nothing on hand. One part of
        # brine is carried (6100:8665), so a brine is bought (6100:8718);
        # three crafts make 6, 12 and 18 doses (6100:9223, 9371, 9539); the
        # mortar and pestle go to Rangu (6100:9659-9671); the 18 are cut to 13
        # (6100:9688-9692) and handed in for a woven sack (6100:10258-10261).
        it 'asks, accepts, buys brine and herbs, crafts three times, combines, cuts to 13 and hands in (6100:8619-10292)' do
          tm = maker(settings: settings.merge(task_repair_every: { 'nezhiri' => 10_800 }))
          game, commons = shop_world(kit)
          allow(tm).to receive(:prepare_for_task)
          runs = remedy_makes(commons, 'gill glop', %w[7001 7002 7004])
          commands = /\A(?:ask nezhiri for task|accept task|task|read my glop instructions|count my first brine|count my first georin|buy brine|order 7|give Rangu|stow ticket|mark my glop at 13|break my glop|give my glop to nezhiri|get coin from my sack|look in my sack|dump junk)\z/
          hooks = { 9660 => ->(_) { commons.release('mortar') }, 9668 => ->(_) { commons.release('pestle') },
                    9689 => breaks(commons, 'gill glop', '7005', kept: '7007', rest: '7006'),
                    10257 => lambda { |_|
                      commons.release('#7007')
                      commons.hold('woven sack', id: '7900')
                    } }
          transcript('2026-11-06_6100_whole_glop').script(game, commands: commands, skip: [8799, 9672, 10281], after: hooks)
          game.alias_command('get coin from #7900', as: 'get coin from my sack')
          game.alias_command('look in #7900', as: 'look in my sack')
          game.script('inventory duffel bag', *bag_listed('some gill glop instructions'))
          game.script('count my second brine', ReplayGame.log('6100:8793'))
          # The client script tapped "my coal nugget" (6100:8909): a large one,
          # 4 rubs, enough for the 3 crafts, so none is bought.
          game.script('tap my first coal nugget', ReplayGame.log('6100:8910'))
          game.script('count #7001', ReplayGame.log('6100:9223'))
          game.script('combine #7001 with #7002', ReplayGame.log('6100:9368'), after: merges(commons, 'gill glop', '7001', '7002', into: '7003'))
          game.script('count #7003', ReplayGame.log('6100:9371'))
          game.script('combine #7003 with #7004', ReplayGame.log('6100:9537'), after: merges(commons, 'gill glop', '7003', '7004', into: '7005'))
          game.script('count #7005', ReplayGame.log('6100:9539'))
          game.script('inventory duffel bag', *bag_listed('some gill glop instructions', 'some gill glop'))
          game.script('count #7005', ReplayGame.log('6100:9685'))
          game.script('count #7006', ReplayGame.log('6100:28265')) # the 5 left over (6100:28265 counts a 5-dose gill glop)
          game.script('count #7007', ReplayGame.log('6100:9692'))
          game.script('swap', ReplayGame.log('6106:1805'), after: swaps(commons, 'gill glop', '7007'))

          tm.run_tasks(OpenStruct.new)

          expect(game.timeline(calls: false)).to eq(
            ['>> ask nezhiri for task', '>> ask nezhiri for task', '>> accept task', '>> task', '>> read my glop instructions',
             '>> inventory duffel bag', '>> count my first brine', '>> count my second brine', '>> tap my first coal nugget', '>> count my first georin',
             '>> buy brine', '>> order 7', '>> order 7', '>> order 7', '>> order 7', '>> order 7', '>> order 7',
             '>> count #7001', '>> combine #7001 with #7002', '>> count #7003', '>> combine #7003 with #7004', '>> count #7005',
             '>> give Rangu', '>> give Rangu', '>> stow ticket', '>> give Rangu', '>> give Rangu', '>> stow ticket',
             '>> inventory duffel bag', '>> count #7005', '>> mark my glop at 13', '>> break my glop', '>> count #7006', '>> count #7007',
             '>> swap', '>> give my glop to nezhiri',
             '>> get coin from #7900', '>> get coin from #7900', '>> get coin from #7900', '>> get coin from #7900', '>> look in #7900', '>> dump junk']
          )
          expect(runs.select { |name, _| name == 'remedy' }).to eq([['remedy', ['instructions', 'georin', 'coal nugget', 'mortar', 'glop', '25', 'stocked']]] * 3)
          calls = commons.calls.map(&:first)
          expect(commons.calls).to include(['DRCM.ensure_copper_on_hand', (1 * 50) + (3 * 437) + 7500, 'Crossing'], ['DRCT.buy_item', 51_102, 'brine'],
                                           ['DRCT.walk_to', 7896], ['DRCT.walk_to', 19_209])
          expect(commons.calls.select { |name, *| name == 'DRCT.order_item' }).to eq([['DRCT.order_item', 8862, 7]] * 3)
          # Bought before the walk to the crafting room, crafted there, then
          # the tools went to Rangu before the hand-in.
          expect(calls.index('DRCT.buy_item')).to be < commons.calls.index(['DRCT.walk_to', 7896])
          expect(commons.calls.index(['DRCT.walk_to', 7896])).to be < calls.index('DRC.wait_for_script_to_complete')
          # The 5 left over went back in the bag; the 13 were handed in.
          expect(commons.inventory.select { |item| item.name == 'gill glop' }.map(&:to_a)).to eq([['gill glop', 'duffel bag', '7006']])
          expect(commons.moves).to include('gill glop: hand -> game', 'woven sack: hand -> velvet backpack')
          expect(UserVars.taskmaster_sacks['nezhiri']).to eq(['azure-scale leather'])
          expect([game.clock, game.diagnostics]).to eq([0.0, []])
        end

        # 6100:10293-11330: 13 doses of deep-sea draught, after a must-wait
        # and BOOST TASK. A 4-dose draught is left from the 14-dose task
        # before (6100:10519), and 26 parts of brine are carried
        # (6100:10343-10349): no brine is bought, two crafts make 10 and 16
        # doses (6100:10914, 11038), the bowl and stick go to Rangu
        # (6100:11156-11168), and the 16 are cut to 13 (6100:11183-11187).
        # The coal nugget carried is tiny (6100:10599), one rub, and two
        # crafts need two: a massive one is bought at the forging supplies
        # (the logged purchase, 6100:4250-4252). The client script used the
        # tiny one up in the first craft (6100:10850-10852), and its second
        # craft happened to add no catalyst; under remedy every craft asked
        # for one (6102:313, 690, 1024).
        it 'counts the 4 doses left from an earlier task, buys no brine with 26 parts carried, crafts twice and hands in 13 of 16 (6100:10293-11330)' do
          tm = maker(settings: settings.merge(task_repair_every: { 'nezhiri' => 10_800 }), boost: true, cooldown_poll: 15)
          game, commons = shop_world(kit + [['deep-sea draught', 'duffel bag', '7101']])
          allow(tm).to receive(:prepare_for_task)
          runs = remedy_makes(commons, 'deep-sea draught', %w[7102 7104])
          commands = /\A(?:ask nezhiri for task|boost task|accept task|task|read my draught instructions|count my (?:first|second|third|fourth) brine|count my first junliar|order 9|give Rangu|stow ticket|mark my draught at 13|break my draught|give my draught to nezhiri|get coin from my sack|look in my sack|dump junk)\z/
          hooks = { 11157 => ->(_) { commons.release('bowl') }, 11165 => ->(_) { commons.release('stick') },
                    11184 => breaks(commons, 'deep-sea draught', '7105', kept: '7106', rest: '7105', kept_hand: :right),
                    11300 => lambda { |_|
                      commons.release('#7106')
                      commons.hold('woven sack', id: '7900')
                    } }
          transcript('2026-11-06_6100_leftover_draught').script(game, commands: commands, skip: [10502, 10512, 10527, 10529, 10531, 10533, 11169, 11323], after: hooks)
          game.alias_command('get coin from #7900', as: 'get coin from my sack')
          game.alias_command('look in #7900', as: 'look in my sack')
          game.script('inventory duffel bag', *bag_listed('some deep-sea draught instructions', 'some deep-sea draught'))
          game.script('count #7101', ReplayGame.log('6100:10519'))
          game.script('tap my first coal nugget', ReplayGame.log('6100:10599'))
          game.script('tap my second coal nugget', ReplayGame.log('6100:225')) # a TAP that found nothing (tap my brine, 6100:224)
          game.script('order 2', ReplayGame.log('6100:4250'))
          game.script('order 2', ReplayGame.log('6100:4252'))
          game.script('combine #7101 with #7102', ReplayGame.log('6100:10912'), after: merges(commons, 'deep-sea draught', '7101', '7102', into: '7103'))
          game.script('count #7103', ReplayGame.log('6100:10914'))
          game.script('combine #7103 with #7104', ReplayGame.log('6100:11036'), after: merges(commons, 'deep-sea draught', '7103', '7104', into: '7105'))
          game.script('count #7105', ReplayGame.log('6100:11038'))
          game.script('inventory duffel bag', *bag_listed('some deep-sea draught instructions', 'some deep-sea draught'))
          game.script('count #7105', ReplayGame.log('6100:11180'))
          game.script('count #7106', ReplayGame.log('6100:11187'))

          tm.run_tasks(OpenStruct.new)

          expect(game.timeline(calls: false)).to eq(
            ['>> ask nezhiri for task', '>> boost task', '>> ask nezhiri for task', '>> ask nezhiri for task', '>> accept task', '>> task',
             '>> read my draught instructions', '>> inventory duffel bag', '>> count #7101',
             '>> count my first brine', '>> count my second brine', '>> count my third brine', '>> count my fourth brine',
             '>> tap my first coal nugget', '>> tap my second coal nugget', '>> count my first junliar',
             '>> order 2', '>> order 2', '>> order 9', '>> order 9', '>> order 9', '>> order 9',
             '>> combine #7101 with #7102', '>> count #7103', '>> combine #7103 with #7104', '>> count #7105',
             '>> give Rangu', '>> give Rangu', '>> stow ticket', '>> give Rangu', '>> give Rangu', '>> stow ticket',
             '>> inventory duffel bag', '>> count #7105', '>> mark my draught at 13', '>> break my draught', '>> count #7106',
             '>> give my draught to nezhiri',
             '>> get coin from #7900', '>> get coin from #7900', '>> get coin from #7900', '>> get coin from #7900', '>> look in #7900', '>> dump junk']
          )
          expect(runs.select { |name, _| name == 'remedy' }).to eq([['remedy', ['instructions', 'junliar', 'coal nugget', 'bowl', 'draught', '25', 'stocked']]] * 2)
          expect(commons.calls.map(&:first)).not_to include('DRCT.buy_item')
          expect(commons.calls).to include(['DRCM.ensure_copper_on_hand', (2 * 531) + 212 + 7500, 'Crossing'])
          expect(commons.calls.select { |name, *| name == 'DRCT.order_item' }).to eq([['DRCT.order_item', 8775, 2]] + ([['DRCT.order_item', 8862, 9]] * 2))
          expect(commons.inventory.map(&:to_a)).to include(['massive coal nugget', 'duffel bag', nil])
          expect(commons.calls.select { |name, *| name == 'DRCC.get_crafting_item' }.map { |call| call[1] }).to eq(['bowl', 'mixing stick'])
          # The leftover stack's id is not known at the start, so it is got
          # by the remedy's whole name, which the game takes for that item
          # only; the logs got remedies by the noun ("get my glop from my
          # leather satchel", 6100:9365), which another draught answers too.
          expect(commons.calls.select { |name, *| name == 'DRCI.get_item?' }.map { |call| call[1] }.grep_v(/\A#|instructions/)).to eq(['deep-sea draught'])
          expect(commons.inventory.select { |item| item.name == 'deep-sea draught' }.map(&:to_a)).to eq([['deep-sea draught', 'duffel bag', '7105']])
          expect(UserVars.taskmaster_sacks['nezhiri']).to eq(['horse-bone stack'])
          # The boost's 2 s pause; no reply was waited out.
          expect([game.clock, game.diagnostics]).to eq([2.0, []])
        end
      end

      describe '#nezhiri' do
        let(:moisturizer) { moisturizer_recipe.merge(uses: 13) }
        let(:glop) { glop_recipe.merge(uses: 14) }

        # Sets of the remedy's instructions in the crafting bag, each given
        # as its uses left, or :foreign for one written for someone else
        # (which the trash takes), as the game keeps them: a GET takes the
        # set in front, or by ordinal the one that many places in, and a set
        # put back goes in front (2026-11-07, as in ensure_instructions'
        # specs). Each READ is scripted, in the order the sets are read.
        # Other items are left to the commons model. Returns the bag.
        def instruction_sets(game, commons, noun, sets)
          name = "#{noun} instructions"
          world = { bag: sets.dup, hand: nil }
          sets.each do |uses|
            reply = if uses == :foreign
                      ReplayGame.code("You can't read the ink printed on the #{name}.  They were written by or for someone else.", from: 'FOREIGN_INSTRUCTIONS, the reply ensure_instructions reads')
                    elsif uses == 1
                      ReplayGame.log('6100:1576')
                    else
                      ReplayGame.code("These instructions appear to be very fragile and will wear out quickly when studied.  They have only #{uses} uses remaining.", from: 'INSTRUCTION_USES, in the shape of 6100:1576')
                    end
            game.script("read my #{name}", reply)
          end
          allow(DRCI).to receive(:get_item?) do |item, container|
            ordinal = item[/\A(\w+) #{noun} instructions\z/, 1]
            next commons.get_item?(item, container) unless item == name || ordinal

            index = ordinal ? $ORDINALS.index(ordinal) : 0
            next false if world[:hand] || index.nil? || index >= world[:bag].size

            world[:hand] = world[:bag].delete_at(index)
            true
          end
          allow(DRCC).to receive(:stow_crafting_item) do |item, bag, belt|
            next commons.stow_crafting_item(item, bag, belt) unless item == name

            world[:bag].unshift(world[:hand]) if world[:hand]
            world[:hand] = nil
            true
          end
          allow(DRCI).to receive(:dispose_trash) do |item, *|
            next false unless item == name && world[:hand]

            world[:hand] = nil
            true
          end
          world[:bag]
        end

        it 'buys and crafts nothing when the doses on hand cover the task, and the hand-in cuts them down (6100:11038, 11180-11187)' do
          tm = maker(task_product: 'deep-sea draught')
          game, commons = shop_world(kit + [['deep-sea draught', 'duffel bag', '7105']])
          runs = remedy_makes(commons, 'deep-sea draught', [])
          2.times { game.script('inventory duffel bag', *bag_listed('some deep-sea draught')) }
          game.script('count #7105', ReplayGame.log('6100:11038'))
          game.script('count #7105', ReplayGame.log('6100:11180'))
          game.script('mark my draught at 13', ReplayGame.log('6100:11183'))
          game.script('break my draught', ReplayGame.log('6100:11185'), after: breaks(commons, 'deep-sea draught', '7105', kept: '7106', rest: '7105', kept_hand: :right))
          game.script('count #7106', ReplayGame.log('6100:11187'))
          game.script('give my draught to nezhiri', ReplayGame.log('6100:11301'), ReplayGame.log('6100:11304'), after: ->(_) { commons.release('#7106') })
          allow(tm).to receive(:sort_sack)
          game.fallback('dump junk', ReplayGame.log('6100:10286'))

          tm.nezhiri('draught', 13, draught_recipe.merge(uses: 14))
          tm.complete_task('draught', 13)

          expect(game.sent).to eq(['inventory duffel bag', 'count #7105', 'inventory duffel bag', 'count #7105',
                                   'mark my draught at 13', 'break my draught', 'count #7106', 'give my draught to nezhiri', 'dump junk'])
          expect(runs).to be_empty
          expect(commons.calls.map(&:first)).not_to include('DRCM.ensure_copper_on_hand', 'DRCI.count_item_parts', 'DRCT.walk_to', 'DRCC.get_crafting_item')
          expect(DRC).to have_received(:message).with('13 doses of deep-sea draught owed, 16 on hand: 0 crafts to make.')
          expect(DRC).not_to have_received(:message).with(/more craft|short of the/)
          expect([game.clock, game.diagnostics]).to eq([0.0, []])
        end

        # The healing potion is in the bag before the landsickness potion, so
        # a get by the noun alone ("get my potion") would bring it; the get
        # by the whole name brings the landsickness potion only. It used to
        # stop the run here, before buying anything.
        it "names another item of the remedy's noun, leaves it in the bag and goes on, getting the remedy by its whole name" do
          tm = maker(task_product: 'landsickness potion')
          game, commons = shop_world(kit + [['healing potion', 'duffel bag'], ['landsickness potion', 'duffel bag', '7301']])
          game.script('inventory duffel bag', *bag_listed('some landsickness potion instructions', 'a healing potion', 'some landsickness potion'))
          game.script('count #7301', ReplayGame.log('6100:6040')) # 15 doses

          tm.nezhiri('potion', 15, potion_recipe.merge(uses: 16))

          expect(game.sent).to eq(['inventory duffel bag', 'count #7301'])
          expect(commons.calls.select { |name, *| name == 'DRCI.get_item?' }.map { |call| call.drop(1) }).to eq([['landsickness potion', 'duffel bag']])
          expect([commons.location_of('healing potion'), commons.location_of('#7301')]).to eq(['duffel bag', 'duffel bag'])
          expect(DRC).to have_received(:message)
            .with('Your duffel bag also holds 1 potion that is not landsickness potion ("a healing potion"). taskmaster gets the landsickness potion by its id or its whole name, and leaves it there.')
          expect(DRC).to have_received(:message).with('15 doses of landsickness potion owed, 15 on hand: 0 crafts to make.')
        end

        # Defileous, 2026-11-18 12:56:21: "an ojhenik draught" in the duffel
        # bag on a deep-sea draught task stopped every relaunch for about 26
        # minutes. Both draught stacks are got by the whole name and
        # combined; the ojhenik draught, first in the bag, is never got.
        it 'gathers only the deep-sea draught stacks when the bag also holds an ojhenik draught, and does not stop' do
          tm = maker(task_product: 'deep-sea draught')
          game, commons = shop_world(kit + [['ojhenik draught', 'duffel bag', '7200'], ['deep-sea draught', 'duffel bag', '7101'], ['deep-sea draught', 'duffel bag', '7102']])
          game.script('inventory duffel bag', *bag_listed('an ojhenik draught', 'some deep-sea draught', 'some deep-sea draught'))
          game.script('combine #7101 with #7102', ReplayGame.log('6100:10912'), after: merges(commons, 'deep-sea draught', '7101', '7102', into: '7103'))
          game.script('count #7103', ReplayGame.log('6100:10914'))

          expect(tm.remedy_doses_on_hand(draught_recipe)).to eq(10)

          expect(game.sent).to eq(['inventory duffel bag', 'combine #7101 with #7102', 'count #7103'])
          expect(commons.calls.select { |name, *| name == 'DRCI.get_item?' }.map { |call| call[1] }).to eq(['deep-sea draught'] * 2)
          expect([commons.location_of('#7200'), commons.location_of('#7103')]).to eq(['duffel bag', 'duffel bag'])
          expect(commons.moves.grep(/ojhenik/)).to be_empty
          expect(DRC).to have_received(:message)
            .with('Your duffel bag also holds 1 draught that is not deep-sea draught ("an ojhenik draught"). taskmaster gets the deep-sea draught by its id or its whole name, and leaves it there.')
          expect(DRC).not_to have_received(:message).with(/Stopping/)
        end

        it 'gets nothing when the only item of the noun in the bag is another remedy' do
          tm = maker(task_product: 'deep-sea draught')
          game, commons = shop_world(kit + [['ojhenik draught', 'duffel bag', '7200']])
          game.script('inventory duffel bag', *bag_listed('some deep-sea draught instructions', 'an ojhenik draught'))

          expect(tm.remedy_doses_on_hand(draught_recipe)).to eq(0)

          expect(game.sent).to eq(['inventory duffel bag'])
          expect(commons.calls.map(&:first)).not_to include('DRCI.get_item?')
          expect(commons.location_of('#7200')).to eq('duffel bag')
        end

        # The planning count and the hand-in each read the bag; the same
        # other items are named once a run, and other ones again.
        it 'names the other items of the noun once a run, not again at the hand-in' do
          tm = maker(task_product: 'deep-sea draught')
          game, = shop_world(kit)
          2.times { game.script('inventory duffel bag', *bag_listed('an ojhenik draught', 'some deep-sea draught')) }
          game.script('inventory duffel bag', *bag_listed('an ojhenik draught', 'a murky draught', 'some deep-sea draught'))

          3.times { expect(tm.send(:remedy_stacks_in_bag, draught_recipe)).to eq(1) }

          expect(DRC).to have_received(:message).with(/also holds 1 draught that is not deep-sea draught \("an ojhenik draught"\)/).once
          expect(DRC).to have_received(:message)
            .with('Your duffel bag also holds 2 draughts that are not deep-sea draught ("an ojhenik draught", "a murky draught"). taskmaster gets the deep-sea draught by its id or its whole name, and leaves them there.').once
        end

        # With repeat one taskmaster works task after task: a deep-sea draught
        # task, a landsickness potion one, then a deep-sea draught one again,
        # the bag unchanged. Each remedy's other items are named once.
        it 'names each remedy\'s other items once when tasks for different remedies alternate' do
          tm = maker(task_product: 'deep-sea draught')
          game, = shop_world(kit)
          listed = bag_listed('an ojhenik draught', 'some deep-sea draught', 'a healing potion', 'some landsickness potion')
          3.times { game.script('inventory duffel bag', *listed) }

          [draught_recipe, potion_recipe, draught_recipe].each { |recipe| expect(tm.send(:remedy_stacks_in_bag, recipe)).to eq(1) }

          expect(DRC).to have_received(:message).with(/also holds 1 draught that is not deep-sea draught \("an ojhenik draught"\)/).once
          expect(DRC).to have_received(:message).with(/also holds 1 potion that is not landsickness potion \("a healing potion"\)/).once
        end

        # Two other items the whole name finds come back in front, turned
        # around (get_remedy_stack); the hand-in's INVENTORY lists them so.
        it 'names the same other items once when the bag lists them in another order' do
          tm = maker(task_product: 'scale moisturizer')
          game, = shop_world(kit)
          game.script('inventory duffel bag', *bag_listed('some scaled moisturizer', 'a scalemail moisturizer', 'some scale moisturizer'))
          game.script('inventory duffel bag', *bag_listed('a scalemail moisturizer', 'some scaled moisturizer', 'some scale moisturizer'))

          2.times { tm.send(:remedy_stacks_in_bag, moisturizer_recipe) }

          expect(DRC).to have_received(:message).with(/\AYour duffel bag also holds 2 moisturizers that are not scale moisturizer/).once
        end

        # The crafting bag in order, front first, as the game keeps it: each
        # word of a name finds the start of a word ("scale" finds "scaled",
        # seen in game 2026-11-19), an ordinal picks among the items found,
        # and an item put back goes in front (read_carried_instructions).
        # Gets by id, and puts into anything else, go to the ReplayCommons
        # model.
        def ordered_bag(commons, items)
          bag = items.map(&:dup)
          finds = lambda do |name, requested|
            words = name.downcase.split
            asked = requested.downcase.split
            asked.all? { |word| words.any? { |own| own.start_with?(word) } } && words.last.start_with?(asked.last)
          end
          allow(DRCI).to receive(:get_item?) do |item, container|
            next commons.get_item?(item, container) if item.start_with?('#')

            commons.calls << ['DRCI.get_item?', item, container]
            ordinal, rest = item.split(' ', 2)
            place = $ORDINALS.index(ordinal)
            found = bag.select { |name, _| finds.call(name, place ? rest : item) }[place || 0]
            next false unless found

            bag.delete(found)
            commons.inventory.reject! { |entry| entry.id == found[1] }
            commons.hold(found[0], id: found[1])
            true
          end
          allow(DRCI).to receive(:put_away_item?) do |item, container|
            held = [GameObj.right_hand, GameObj.left_hand].find { |obj| obj&.id && "##{obj.id}" == item }
            bag.unshift([held.name, held.id]) if held && container == 'duffel bag'
            commons.put_away_item?(item, container)
          end
          bag
        end

        # @return [Array<String>] the items DRCI.get_item? was asked for by name
        def gets_by_name(commons)
          commons.calls.select { |name, item, *| name == 'DRCI.get_item?' && !item.start_with?('#') }.map { |call| call[1] }
        end

        it 'puts back a "scaled" moisturizer the whole name brings and gets the stack as the second' do
          tm = maker(task_product: 'scale moisturizer')
          _, commons = shop_world(kit + [['scaled moisturizer', 'duffel bag', '7200'], ['scale moisturizer', 'duffel bag', '7101']])
          bag = ordered_bag(commons, [['scaled moisturizer', '7200'], ['scale moisturizer', '7101']])

          expect(tm.send(:get_remedy_stack, moisturizer_recipe, nil)).to eq('7101')

          expect(gets_by_name(commons)).to eq(['scale moisturizer', 'second scale moisturizer'])
          expect(commons.calls).to include(['DRCI.put_away_item?', '#7200', 'duffel bag'])
          expect(bag).to eq([['scaled moisturizer', '7200']])
          expect(DRC).not_to have_received(:message).with(/Stopping/)
        end

        it 'goes on to the third when two other items the whole name finds are ahead, each put back in front' do
          tm = maker(task_product: 'scale moisturizer')
          _, commons = shop_world(kit + [['scaled moisturizer', 'duffel bag', '7200'], ['scaled moisturizer', 'duffel bag', '7201'], ['scale moisturizer', 'duffel bag', '7101']])
          bag = ordered_bag(commons, [['scaled moisturizer', '7200'], ['scaled moisturizer', '7201'], ['scale moisturizer', '7101']])

          expect(tm.send(:get_remedy_stack, moisturizer_recipe, nil)).to eq('7101')

          expect(gets_by_name(commons)).to eq(['scale moisturizer', 'second scale moisturizer', 'third scale moisturizer'])
          expect(bag).to eq([['scaled moisturizer', '7201'], ['scaled moisturizer', '7200']])
        end

        it 'stops, with what came put back, once a get brings nothing and none was the remedy' do
          tm = maker(task_product: 'scale moisturizer')
          _, commons = shop_world(kit + [['scaled moisturizer', 'duffel bag', '7200']])
          bag = ordered_bag(commons, [['scaled moisturizer', '7200']])

          expect { tm.send(:get_remedy_stack, moisturizer_recipe, nil) }.to raise_error(SystemExit)

          expect(gets_by_name(commons)).to eq(['scale moisturizer', 'second scale moisturizer'])
          expect(bag).to eq([['scaled moisturizer', '7200']])
          expect(DRC).to have_received(:message)
            .with('Could not get the scale moisturizer out of your duffel bag: the gets brought only scaled moisturizer (#7200), put back there. Stopping.')
        end

        # A get by the whole name that brings another item of the noun puts
        # it back by id and asks for the second; here (an ordinal the model
        # does not place) that brings nothing, and the run stops before
        # anything is combined with the stack already held.
        it 'stops, putting it back by id and combining nothing, when the get by the whole name brings another item of the noun' do
          tm = maker(task_product: 'deep-sea draught')
          game, commons = shop_world(kit + [['ojhenik draught', 'duffel bag', '7200'], ['deep-sea draught', 'duffel bag', '7101']])
          commons.hold('deep-sea draught', id: '7102')
          game.script('inventory duffel bag', *bag_listed('an ojhenik draught', 'some deep-sea draught'))
          # Every other get goes to the ReplayCommons model shop_world
          # installed (and_wrap_original would wrap the harness stub instead).
          allow(DRCI).to receive(:get_item?) do |item, container|
            next commons.get_item?(item, container) unless item == 'deep-sea draught'

            commons.calls << ['DRCI.get_item?', item, container]
            commons.inventory.reject! { |entry| entry.id == '7200' }
            commons.hold('ojhenik draught', id: '7200')
            true
          end

          expect { tm.remedy_doses_on_hand(draught_recipe) }.to raise_error(SystemExit)

          expect(game.sent).to eq(['inventory duffel bag'])
          expect(commons.calls).to include(['DRCI.put_away_item?', '#7200', 'duffel bag'])
          expect([commons.location_of('#7200'), commons.location_of('#7101'), commons.location_of('#7102')]).to eq(['duffel bag', 'duffel bag', 'duffel bag'])
          expect(DRC).to have_received(:message)
            .with('Could not get the deep-sea draught out of your duffel bag: the gets brought only ojhenik draught (#7200), put back there. Stopping.')
        end

        # Each of Nezhiri's remedies, from a bag whose name has an
        # apostrophe (Nelis's trapper's duffel), with another item of its
        # noun ahead of it there. The other names are made up.
        it "gets each remedy's stack by its whole name, never by its noun, from any crafting bag" do
          TaskMaster::NEZHIRI_ITEMS.each do |product, info|
            tm = maker(task_product: product)
            tm.instance_variable_set(:@bag, "trapper's duffel")
            _, commons = shop_world([["ojhenik #{info[:noun]}", "trapper's duffel", '7400'], [product, "trapper's duffel", '7401']])

            expect(tm.send(:get_remedy_stack, { product: product, noun: info[:noun] }, nil)).to eq('7401')

            expect(commons.calls.select { |name, *| name == 'DRCI.get_item?' }.map { |call| call.drop(1) }).to eq([[product, "trapper's duffel"]])
            expect(commons.location_of('#7400')).to eq("trapper's duffel")
            commons.release('#7401') # the hands are not reset between worlds
          end
        end

        it 'stops rather than take an INVENTORY unanswered twice for an empty bag' do
          tm = maker(task_product: 'gill glop')
          game, commons = shop_world(kit + [['gill glop', 'duffel bag', '7001']])

          expect { tm.nezhiri('glop', 13, glop) }.to raise_error(SystemExit)

          expect(game.sent).to eq(['inventory duffel bag'] * 2)
          expect(commons.calls.map(&:first)).not_to include('DRCI.count_item_parts', 'DRCM.ensure_copper_on_hand')
          expect(DRC).to have_received(:message).with('Could not look for gill glop in your duffel bag: INVENTORY went unanswered twice. Stopping.')
        end

        it "counts a remedy whose name ends in the product's as the remedy, and its instructions as nothing" do
          tm = maker(task_product: 'landsickness potion')
          game, = shop_world(kit + [['landsickness potion', 'duffel bag', '7301']])
          game.script('inventory duffel bag', *bag_listed('some landsickness potion instructions', 'some landsickness potion'))
          game.script('count #7301', ReplayGame.log('6100:6040')) # 15 doses
          expect(tm.remedy_doses_on_hand(potion_recipe)).to eq(15)
          expect(game.sent).to eq(['inventory duffel bag', 'count #7301'])
        end

        # Both hold "draught" and read as another noun, as their noun= in
        # noun-corpus.tsv says ("instructions", "holster"): remedy and the
        # hand-in, which take the draught by its noun, would not take them.
        it 'does not count items that hold the noun but whose noun reads as another' do
          tm = maker(task_product: 'deep-sea draught')
          game, = shop_world(kit)
          game.script('inventory duffel bag', *bag_listed('some deep-sea draught instructions', 'a cracked black leather draught holster set with a vivid fire whirl ruby', 'some deep-sea draught'))

          expect(tm.send(:remedy_stacks_in_bag, draught_recipe)).to eq(1)

          expect(DRC).not_to have_received(:message)
        end

        # No item logged in November 2026 that holds a remedy's noun reads as
        # no noun, so get_noun is made to read none off this real one. It is
        # named and left in the bag; it used to stop the run.
        it 'names, and does not count or stop for, an item that holds the noun but has no noun read off it' do
          tm = maker(task_product: 'deep-sea draught')
          game, = shop_world(kit)
          holster = 'a cracked black leather draught holster set with a vivid fire whirl ruby'
          game.script('inventory duffel bag', *bag_listed(holster, 'some deep-sea draught'))
          allow(DRC).to(receive(:get_noun).and_wrap_original { |real, name| name == holster ? nil : real.call(name) })

          expect(tm.send(:remedy_stacks_in_bag, draught_recipe)).to eq(1)

          expect(DRC).to have_received(:message)
            .with("Your duffel bag also holds 1 item with no noun taskmaster can read (\"#{holster}\"). taskmaster gets the deep-sea draught by its id or its whole name, and leaves it there.")
        end

        # An unread line holding every word of the remedy's name may be the
        # remedy itself (no November 2026 line was: get_noun is made to read
        # none off it). It is not counted, and the note says so rather than
        # that the remedy is left behind; only the counted stack is got (one
        # get by the whole name), counted and put back, and nothing combined.
        it 'gets only the counted stack, and names as uncounted an item named as the remedy with no noun read off it' do
          tm = maker(task_product: 'deep-sea draught')
          game, commons = shop_world(kit + [['deep-sea draught', 'duffel bag', '7101'], ['fresh deep-sea draught', 'duffel bag', '7103']])
          2.times { game.script('inventory duffel bag', *bag_listed('some deep-sea draught', 'some fresh deep-sea draught')) }
          game.script('count #7101', ReplayGame.log('6100:10519')) # 4 doses
          allow(DRC).to(receive(:get_noun).and_wrap_original { |real, name| name == 'some fresh deep-sea draught' ? nil : real.call(name) })

          expect(tm.send(:remedy_stacks_in_bag, draught_recipe)).to eq(1)
          expect(tm.remedy_doses_on_hand(draught_recipe)).to eq(4)

          expect(game.sent).to eq(['inventory duffel bag'] * 2 + ['count #7101'])
          expect(commons.calls.select { |name, *| name == 'DRCI.get_item?' }.map { |call| call.drop(1) }).to eq([['deep-sea draught', 'duffel bag']])
          expect(commons.calls.map(&:first).grep(/combine/i)).to eq([])
          expect([commons.location_of('#7101'), commons.location_of('#7103')]).to eq(['duffel bag', 'duffel bag'])
          expect(DRC).to have_received(:message)
            .with('Your duffel bag also holds 1 item named deep-sea draught with no noun taskmaster can read ("some fresh deep-sea draught"). ' \
                  'taskmaster does not count it as deep-sea draught, so it may craft more than is owed.').once
          expect(DRC).not_to have_received(:message).with(/leaves it there/)
        end

        # Its only stack unread: none is counted, so nothing is got, combined
        # or counted, and the run crafts all the doses owed.
        it 'counts no doses and gets nothing when the only stack of the remedy has no noun read off it' do
          tm = maker(task_product: 'deep-sea draught')
          game, commons = shop_world(kit + [['deep-sea draught', 'duffel bag', '7101']])
          game.script('inventory duffel bag', *bag_listed('some deep-sea draught'))
          allow(DRC).to(receive(:get_noun).and_wrap_original { |real, name| name == 'some deep-sea draught' ? nil : real.call(name) })

          expect(tm.remedy_doses_on_hand(draught_recipe)).to eq(0)

          expect(game.sent).to eq(['inventory duffel bag'])
          expect(commons.calls.map(&:first)).not_to include('DRCI.get_item?')
          expect(commons.location_of('#7101')).to eq('duffel bag')
          expect(tm.instance_variable_get(:@remedy_stack)).to be_nil
          expect(DRC).to have_received(:message)
            .with('Your duffel bag also holds 1 item named deep-sea draught with no noun taskmaster can read ("some deep-sea draught"). ' \
                  'taskmaster does not count it as deep-sea draught, so it may craft more than is owed.')
        end

        it 'names the uncounted items after the others, in one message, plural when more than one' do
          tm = maker(task_product: 'deep-sea draught')
          game, = shop_world(kit)
          unread = ['some deep-sea draught', 'a vial of deep-sea draught']
          game.script('inventory duffel bag', *bag_listed('an ojhenik draught', *unread))
          allow(DRC).to(receive(:get_noun).and_wrap_original { |real, name| unread.include?(name) ? nil : real.call(name) })

          expect(tm.send(:remedy_stacks_in_bag, draught_recipe)).to eq(0)

          expect(DRC).to have_received(:message)
            .with('Your duffel bag also holds 1 draught that is not deep-sea draught ("an ojhenik draught"). taskmaster gets the deep-sea draught by its id or its whole name, ' \
                  'and leaves it there. It holds 2 items named deep-sea draught with no noun taskmaster can read ("some deep-sea draught", "a vial of deep-sea draught"). ' \
                  'taskmaster does not count them as deep-sea draught, so it may craft more than is owed.').once
        end

        it 'stops before buying anything when the instructions have fewer uses than crafts' do
          tm = maker(task_product: 'scale moisturizer')
          game, commons = shop_world(kit)
          game.script('inventory duffel bag', *bag_listed)
          bag = instruction_sets(game, commons, 'moisturizer', [1])

          expect { tm.nezhiri('moisturizer', 12, moisturizer.merge(uses: 1)) }.to raise_error(SystemExit)

          expect(commons.calls.map(&:first)).not_to include('DRCI.count_item_parts', 'DRCM.ensure_copper_on_hand')
          expect(game.sent.grep(/\Aread /)).to eq(['read my moisturizer instructions'])
          expect(bag).to eq([1])
          expect(DRC).to have_received(:message)
            .with('The moisturizer instructions you carry have 1 use left, and 2 crafts are needed. Ask Nezhiri for another copy (ASK NEZHIRI FOR INSTRUCTIONS), then run ;taskmaster nezhiri finish. Stopping before buying anything.')
        end

        # Found by a mutation sweep: no example had exactly as many uses as
        # crafts, or crafts that make exactly the doses owed.
        it 'goes on when the instructions have exactly as many uses as crafts' do
          tm = maker(task_product: 'scale moisturizer')
          allow(tm).to receive(:exit) { raise 'stopped' }

          expect { tm.check_remedy_uses('moisturizer', moisturizer.merge(uses: 2), 2) }.not_to raise_error

          expect(DRC).not_to have_received(:message)
        end

        # 6100:9361-9371: two gill glop crafts of 6, combined into 12; 12 owed.
        it 'stops crafting without a stop when two crafts make exactly the 12 doses owed (6100:9361, 9368, 9371)' do
          tm = maker(task_product: 'gill glop', remedy_stack: nil, remedy_doses: 0)
          game, commons = shop_world(kit)
          runs = remedy_makes(commons, 'gill glop', %w[7001 7002])
          game.script('count #7001', ReplayGame.log('6100:9361'))
          game.script('combine #7001 with #7002', ReplayGame.log('6100:9368'), after: merges(commons, 'gill glop', '7001', '7002', into: '7003'))
          game.script('count #7003', ReplayGame.log('6100:9371'))

          expect(tm.brew_remedies(glop_recipe, 12, 2)).to eq(12)

          expect(runs.count { |name, _| name == 'remedy' }).to eq(2)
          expect(game.sent).to eq(['count #7001', 'combine #7001 with #7002', 'count #7003'])
          expect(commons.location_of('#7003')).to eq('duffel bag')
          expect(tm.instance_variable_get(:@remedy_doses)).to eq(12)
          expect(DRC).to have_received(:message).with('12 doses of gill glop made and combined into one.')
          expect(DRC).not_to have_received(:message).with(/short of the/)
          expect([game.clock, game.diagnostics]).to eq([0.0, []])
        end

        it 'stops before buying anything when the bank cannot cover the supplies' do
          tm = maker(task_product: 'gill glop')
          game, commons = shop_world(kit)
          game.script('inventory duffel bag', *bag_listed)
          game.script('count my first brine', ReplayGame.log('6100:8665'))
          game.script('count my second brine', ReplayGame.log('6100:8793'))
          game.script('tap my first coal nugget', ReplayGame.log('6100:8910'))
          game.script('count my first georin', ReplayGame.log('6100:8793'))
          allow(DRCM).to receive(:ensure_copper_on_hand).and_return(false)
          allow(DRCI).to receive(:stow_hands)

          expect { tm.nezhiri('glop', 13, glop) }.to raise_error(SystemExit)

          expect(DRCM).to have_received(:ensure_copper_on_hand).with(1361 + 7500, anything, 'Crossing')
          expect(commons.calls.map(&:first)).not_to include('DRCT.buy_item', 'DRCT.order_item', 'DRC.wait_for_script_to_complete')
          expect(DRCI).to have_received(:stow_hands) # no vessel to keep: the hands are put away as always
          expect(DRC).to have_received(:message).with('Out of money: 8861 Kronars (copper) needed and the Crossing bank could not cover it. Stopping before buying anything more.')
        end

        it 'buys only the herb stacks not carried, counting 25 pieces as a stack (6100:4595)' do
          tm = maker(task_product: 'gill glop')
          game, commons = shop_world(kit + [['dried georin', 'duffel bag']], shop: :model)
          game.script('inventory duffel bag', *bag_listed)
          game.script('count my first brine', ReplayGame.log('6100:8800'))
          game.script('count my second brine', ReplayGame.log('6100:8793'))
          game.script('tap my first coal nugget', ReplayGame.log('6100:8910'))
          game.script('count my first georin', ReplayGame.log('6100:4595'))
          game.script('count my second georin', ReplayGame.log('6100:8793'))
          allow(tm).to receive(:brew_remedies)
          allow(tm).to receive(:top_up_remedies)
          allow(tm).to receive(:repair)

          tm.nezhiri('glop', 13, glop)

          expect(commons.calls.select { |name, *| name == 'DRCT.order_item' }).to eq([['DRCT.order_item', 8862, 7]] * 2)
          expect(commons.calls).to include(['DRCM.ensure_copper_on_hand', (2 * 437) + 7500, 'Crossing'])
          expect(commons.calls.map(&:first)).not_to include('DRCT.buy_item')
        end

        it "sends the remedy's vessel and its tool for repair with the sieve, and none of the other vessel's" do
          tm = maker(task_product: 'gill glop')
          game, = shop_world(kit + [['dried georin', 'duffel bag']], shop: :model)
          game.script('inventory duffel bag', *bag_listed)
          game.script('count my first brine', ReplayGame.log('6100:8800'))
          game.script('count my second brine', ReplayGame.log('6100:8793'))
          game.script('tap my first coal nugget', ReplayGame.log('6100:8910'))
          game.script('count my first georin', ReplayGame.log('6100:4595'))
          game.script('count my second georin', ReplayGame.log('6100:8793'))
          allow(tm).to receive(:brew_remedies)
          allow(tm).to receive(:top_up_remedies)
          allow(tm).to receive(:repair)

          tm.nezhiri('glop', 13, glop)

          expect(tm).to have_received(:repair).with(%w[mortar pestle sieve], belt)
        end

        it 'buys the coal nugget at the forging supplies, then water and alcohol at the alchemy supplies, only when the wait before the task found none' do
          tm = maker(task_product: 'gill glop', stock_survey: { water: false, alcohol: false })
          game, commons = shop_world(kit.reject { |name, _| name =~ /water|alcohol|coal/ }, shop: :model)
          game.script('inventory duffel bag', *bag_listed)
          game.script('count my first brine', ReplayGame.log('6100:8800'))
          game.script('count my second brine', ReplayGame.log('6100:8793'))
          game.script('tap my first coal nugget', ReplayGame.log('6100:225'))
          game.script('count my first georin', ReplayGame.log('6100:8793'))
          sold = { [8775, 2] => ['large coal nugget', '8105'], [8862, 1] => ['water', '8103'], [8862, 2] => ['grain alcohol', '8104'], [8862, 7] => ['dried georin', '8101'] }
          orders = []
          allow(DRCT).to receive(:order_item) do |room, number|
            orders << [room, number]
            name, id = sold.fetch([room, number])
            commons.hold(name, id: id)
            nil
          end
          allow(tm).to receive(:brew_remedies)
          allow(tm).to receive(:top_up_remedies)
          allow(tm).to receive(:repair)

          tm.nezhiri('glop', 13, glop)

          expect(orders).to eq([[8775, 2], [8862, 1], [8862, 2]] + ([[8862, 7]] * 3))
          expect(commons.calls).to include(['DRCM.ensure_copper_on_hand', 212 + 62 + 81 + (3 * 437) + 7500, 'Crossing'])
          expect(commons.inventory.map(&:name)).to include('large coal nugget', 'water', 'grain alcohol', 'dried georin')
        end

        it 'leaves water and alcohol to remedy when water_container and alcohol_container name vessels: the wait does not look for them' do
          tm = maker(settings: settings.merge(water_container: 'jug', alcohol_container: 'flask'))
          shop_world([])
          inventory_replies({})
          allow(DRCI).to receive(:exists?).and_return(false)
          allow(DRCM).to receive(:wealth).and_return(0)

          tm.survey_remedy_supplies

          # The coal TAP goes unanswered here, so the count is marked not whole.
          expect(tm.instance_variable_get(:@stock_survey).keys).to eq(%i[brine_parts coal_rubs herb_parts missing_tools coal_whole copper])
          expect(DRCI).not_to have_received(:exists?).with('water')
          expect(DRCI).not_to have_received(:exists?).with('alcohol')
          expect(tm.missing_remedy_supplies(1).map { |supply| supply[:name] }).to eq(['coal nugget'])
        end

        # None of her four remedies uses water or alcohol: every logged READ
        # lists a herb, a splash of brewer's brine and a catalyst (the reads
        # let). Her crafts run stocked, but the carry-on run does not, and
        # remedy then buys a missing one, mid-task, at the crafting town's
        # shop (remedy.lic Supplies#buy_missing), so with no
        # answer from the wait (no wait, a finish, a survey made with a
        # water_container set) they are looked for and bought on the way.
        it 'looks for water and alcohol when the wait gave no answer for them, and buys those not found, though her remedies use neither' do
          reads.each_value { |lines| expect(lines.map(&:text).grep(/\(\d+\) (?!prepared herb|splash of brewer's brine|catalyst material)/)).to eq([]) }
          [nil, { coal_rubs: 4 }].each do |survey|
            tm = maker(stock_survey: survey)
            game, commons = shop_world([['large coal nugget', 'duffel bag']])
            game.script('tap my first coal nugget', ReplayGame.log('6100:8910'))

            expect(tm.missing_remedy_supplies(3).map { |supply| supply[:name] }).to eq(%w[water alcohol])
            expect(commons.calls.select { |name, *| name == 'DRCI.exists?' }.map { |call| call[1] }).to eq(%w[water alcohol])
          end

          # Found by TAP (in another container, say): none bought.
          tm = maker
          game, = shop_world([['large coal nugget', 'duffel bag'], ['water', 'traveler\'s pack'], ['grain alcohol', 'traveler\'s pack']])
          game.script('tap my first coal nugget', ReplayGame.log('6100:8910'))
          expect(tm.missing_remedy_supplies(3)).to eq([])
        end

        it 'never looks for water or alcohol when water_container and alcohol_container name vessels, with or without a survey' do
          [nil, { coal_rubs: 4 }].each do |survey|
            tm = maker(settings: settings.merge(water_container: 'jug', alcohol_container: 'flask'), stock_survey: survey)
            game, = shop_world([['large coal nugget', 'duffel bag']])
            game.script('tap my first coal nugget', ReplayGame.log('6100:8910'))

            expect(tm.missing_remedy_supplies(3)).to eq([])
            expect(DRCI).not_to have_received(:exists?)
          end
        end

        # A coal nugget shrinks a size a rub and a tiny one is used up
        # (6100:3370-3372, then 6100:3501): one too small for the crafts runs
        # out part way, and remedy then stops with the vessel in hand.
        it 'buys a coal nugget when the one carried is tiny and two crafts need two rubs, and none for one craft (6100:10599)' do
          tm = maker(settings: settings.merge(water_container: 'jug', alcohol_container: 'flask'))
          game, = shop_world([])
          game.script('tap my first coal nugget', ReplayGame.log('6100:10599'))
          game.script('tap my second coal nugget', ReplayGame.log('6100:225'))
          game.script('tap my first coal nugget', ReplayGame.log('6100:10599'))

          expect(tm.missing_remedy_supplies(2)).to eq([{ name: 'coal nugget', room: 8775, number: 2, stock: 'coal', price: 212 }])
          expect(tm.missing_remedy_supplies(1)).to eq([])
          expect([game.sent, game.clock]).to eq([['tap my first coal nugget', 'tap my second coal nugget', 'tap my first coal nugget'], 0.0])
        end

        it 'adds up the rubs of every nugget carried, and taps no further once they cover the crafts (6100:2445, 3154)' do
          tm = maker(settings: settings.merge(water_container: 'jug', alcohol_container: 'flask'))
          game, = shop_world([])
          game.script('tap my first coal nugget', ReplayGame.log('6100:2445')) # small: 2
          game.script('tap my second coal nugget', ReplayGame.log('6100:3154')) # tiny: 1

          expect(tm.missing_remedy_supplies(3)).to eq([])
          expect(game.sent).to eq(['tap my first coal nugget', 'tap my second coal nugget'])
        end

        it 'buys a coal nugget when the TAP goes unanswered, rather than run out part way' do
          tm = maker(settings: settings.merge(water_container: 'jug', alcohol_container: 'flask'))
          game, = shop_world([])

          expect(tm.missing_remedy_supplies(1).map { |supply| supply[:name] }).to eq(['coal nugget'])
          expect([game.sent, game.clock]).to eq([['tap my first coal nugget'], 15.0])
        end

        it 'needs the vessel of the remedy and its tool, the sieve, and not the other vessel' do
          tm = maker
          expect([tm.remedy_tools(glop_recipe), tm.remedy_tools(draught_recipe)]).to eq([%w[mortar pestle sieve], ['bowl', 'mixing stick', 'sieve']])
        end

        # remedy stopped before it got the mortar (no product and no vessel in
        # hand): nothing to look in, so the run stops and points at remedy's
        # own Remedy: line.
        it "stops when remedy leaves neither the remedy nor its vessel in hand, pointing at remedy's Remedy: line, with nothing looked in" do
          tm = maker(task_product: 'gill glop')
          game, commons = shop_world(kit)
          runs = remedy_makes(commons, 'gill glop', [])
          game.script('inventory duffel bag', *bag_listed)
          game.script('count my first brine', ReplayGame.log('6100:8800'))
          game.script('count my second brine', ReplayGame.log('6100:8793'))
          game.script('count my first georin', ReplayGame.log('6100:4595'))
          game.script('count my second georin', ReplayGame.log('6100:8793'))
          game.script('tap my first coal nugget', ReplayGame.log('6100:8910'))
          2.times { game.script('order 7', ReplayGame.log('6100:8888')).script('order 7', ReplayGame.log('6100:8890')) }

          expect { tm.nezhiri('glop', 13, glop) }.to raise_error(SystemExit)

          expect(runs.count { |name, _| name == 'remedy' }).to eq(1)
          expect(game.sent.grep(/\Acount #|\Acombine |\Alook /)).to be_empty
          expect(DRC).to have_received(:message)
            .with("remedy did not leave any gill glop in your hands (craft 1 of 3); its Remedy: line says why. Once that is sorted, run ;taskmaster nezhiri finish. Stopping.")
        end

        it 'stops, both stacks back in the bag, when the game will not combine them (6100:9229)' do
          tm = maker(task_product: 'gill glop')
          game, commons = shop_world(kit)
          allow(tm).to receive(:buy_remedy_supplies)
          remedy_makes(commons, 'gill glop', %w[7001 7002])
          game.script('inventory duffel bag', *bag_listed)
          game.script('count #7001', ReplayGame.log('6100:9223'))
          game.script('combine #7001 with #7002', ReplayGame.log('6100:9229'))

          expect { tm.nezhiri('glop', 13, glop) }.to raise_error(SystemExit)

          expect(DRC).to have_received(:message).with('Could not combine the gill glop (You must be holding both). Stopping.')
          expect(commons.inventory.select { |item| item.name == 'gill glop' }.map(&:id)).to contain_exactly('7001', '7002')
          expect(commons.calls.map(&:first)).not_to include('DRCC.get_crafting_item') # no repair after a stop
        end

        describe 'crafts that make fewer doses than owed' do
          # COUNT of a stack the logs never showed at this size, in the shape
          # of the logged ones.
          def counted(doses)
            log = { 3 => '6100:6051', 4 => '6100:10519', 5 => '6100:28265', 6 => '6100:9223', 12 => '6100:9371', 13 => '6100:9692', 15 => '6100:6040', 18 => '6100:9539' }[doses]
            log ? ReplayGame.log(log) : ReplayGame.code("You count out #{doses} uses remaining.", from: 'REMEDY_COUNT, in the shape of 6100:9223')
          end

          # remedy, stubbed to leave a new stack in hand each run, and the
          # game's COMBINE and COUNT replies for those stacks: each craft adds
          # the next of `gains` to the stack. The new stacks are 7002, 7004
          # and so on; each COMBINE makes the new stack's id plus one. With
          # on_hand ([id, doses]) the first craft is combined into that stack.
          # Returns the remedy runs.
          def crafts_adding(game, commons, gains, on_hand: nil)
            made_ids = (1..gains.size).map { |n| (7000 + (2 * n)).to_s }
            runs = remedy_makes(commons, 'gill glop', made_ids.dup)
            stack, total = on_hand || [nil, 0]
            gains.zip(made_ids).each do |gain, made|
              total += gain
              if stack
                into = (made.to_i + 1).to_s
                game.script("combine ##{stack} with ##{made}", ReplayGame.log('6100:9368'), after: merges(commons, 'gill glop', stack, made, into: into))
                stack = into
              else
                stack = made
              end
              game.script("count ##{stack}", counted(total))
            end
            runs
          end

          def remedy_runs(runs)
            runs.count { |name, _| name == 'remedy' }
          end

          # Each round's crafts, as bought: buy_remedy_supplies is checked on
          # its own above, so here it only records the crafts it was asked for.
          def bought_crafts(tm)
            bought = []
            allow(tm).to receive(:buy_remedy_supplies) { |_recipe, crafts| bought << crafts }
            bought
          end

          # The report's task (15 owed, 13 made by the crafts planned for
          # them): one more craft, planned at the 4 doses the smallest craft
          # made, bought through the real purchases (brine, coal and herbs
          # counted again for it), crafted where the crafts are made, and
          # combined into the same stack.
          it 'makes one more craft when three make 13 of the 15 owed, buying for it alone, then hands the tools to Rangu' do
            tm = maker(task_product: 'gill glop')
            game, commons = shop_world(kit, shop: :model)
            game.script('inventory duffel bag', *bag_listed)
            2.times do
              game.script('count my first brine', ReplayGame.log('6100:8800')) # ten parts
              game.script('count my second brine', ReplayGame.log('6100:8793'))
              game.script('tap my first coal nugget', ReplayGame.log('6100:8910')) # large: 4 rubs
              game.script('count my first georin', ReplayGame.log('6100:8793'))
            end
            runs = crafts_adding(game, commons, [5, 4, 4, 6])
            allow(tm).to receive(:repair)

            tm.nezhiri('glop', 15, glop.merge(uses: 16))

            expect(remedy_runs(runs)).to eq(4)
            expect(commons.calls.select { |name, *| name == 'DRCT.order_item' }).to eq([['DRCT.order_item', 8862, 7]] * 4)
            expect(commons.calls.select { |name, *| name == 'DRCM.ensure_copper_on_hand' })
              .to eq([['DRCM.ensure_copper_on_hand', (3 * 437) + 7500, 'Crossing'], ['DRCM.ensure_copper_on_hand', 437 + 7500, 'Crossing']])
            expect(commons.calls.select { |name, *| name == 'DRCT.walk_to' }.count { |call| call[1] == 7896 }).to eq(2)
            expect(DRC).to have_received(:message).with('13 of 15 doses of gill glop made: 1 more craft to make.').ordered
            expect(DRC).to have_received(:message).with('19 doses of gill glop made and combined into one.').ordered
            expect(tm.instance_variable_get(:@remedy_doses)).to eq(19)
            expect(commons.location_of('#7009')).to eq('duffel bag')
            expect(tm).to have_received(:repair).once
            expect(DRC).not_to have_received(:message).with(/short of the/)
            expect(game.diagnostics).to eq([])
          end

          # 6400: 12 doses of scale moisturizer owed, none on hand, a new set
          # of instructions with 13 uses (6400:313). The two crafts planned
          # made 5 each (6400:683, combined at 6400:811 into 10, 6400:813),
          # where taskmaster 2026.11.08.2 stopped (6400:816-817). Now one
          # extra craft, planned at 5 doses, makes the 15 that cover the 12.
          # The extra craft's COMBINE and COUNT of 15 are past the end of
          # 6400: 6100's lines stand in.
          it 'makes one extra craft when two make 5 doses each of the 12 owed, as in 6400' do
            tm = maker(task_product: 'scale moisturizer')
            game, commons = shop_world(kit, shop: :model)
            game.script('inventory duffel bag', *bag_listed)
            2.times do
              game.script('count my first brine', ReplayGame.log('6100:8800')) # ten parts
              game.script('count my second brine', ReplayGame.log('6100:8793'))
              game.script('tap my first coal nugget', ReplayGame.log('6100:8910')) # large: 4 rubs
              game.script('count my first red flowers', ReplayGame.log('6100:8793'))
            end
            runs = remedy_makes(commons, 'scale moisturizer', %w[7002 7004 7006])
            game.script('count #7002', ReplayGame.log('6400:683'))
            game.script('combine #7002 with #7004', ReplayGame.log('6400:811'), after: merges(commons, 'scale moisturizer', '7002', '7004', into: '7005'))
            game.script('count #7005', ReplayGame.log('6400:813'))
            game.script('combine #7005 with #7006', ReplayGame.log('6100:9368'), after: merges(commons, 'scale moisturizer', '7005', '7006', into: '7007'))
            game.script('count #7007', ReplayGame.log('6100:6040')) # 15 doses
            allow(tm).to receive(:repair)

            tm.nezhiri('moisturizer', 12, moisturizer)

            expect(remedy_runs(runs)).to eq(3)
            expect(game.sent.grep(/\A(?:count|combine) #/))
              .to eq(['count #7002', 'combine #7002 with #7004', 'count #7005', 'combine #7005 with #7006', 'count #7007'])
            expect(commons.calls.select { |name, *| name == 'DRCT.order_item' }).to eq([['DRCT.order_item', 8862, 13]] * 3)
            expect(commons.calls.select { |name, *| name == 'DRCM.ensure_copper_on_hand' })
              .to eq([['DRCM.ensure_copper_on_hand', (2 * 343) + 7500, 'Crossing'], ['DRCM.ensure_copper_on_hand', 343 + 7500, 'Crossing']])
            expect(DRC).to have_received(:message).with('12 doses of scale moisturizer owed, 0 on hand: 2 crafts to make.').ordered
            expect(DRC).to have_received(:message).with('10 doses of scale moisturizer made and combined into one.').ordered
            expect(DRC).to have_received(:message).with('10 of 12 doses of scale moisturizer made: 1 more craft to make.').ordered
            expect(DRC).to have_received(:message).with('15 doses of scale moisturizer made and combined into one.').ordered
            expect([tm.instance_variable_get(:@remedy_doses), tm.instance_variable_get(:@remedy_yield), tm.instance_variable_get(:@remedy_studies)]).to eq([15, 5, 3])
            expect(commons.location_of('#7007')).to eq('duffel bag')
            expect(game.sent.grep(/\Aread /)).to eq([]) # 13 uses less the 2 studies cover the extra craft
            expect(tm).to have_received(:repair).once
            expect(DRC).not_to have_received(:message).with(/short of the|uses? left/)
            expect(game.diagnostics).to eq([])
          end

          it 'plans the extra crafts at the fewest doses a craft made: 3 a craft leaves 7 of 16 short, so three more' do
            tm = maker(task_product: 'gill glop')
            game, commons = shop_world(kit)
            game.script('inventory duffel bag', *bag_listed)
            bought = bought_crafts(tm)
            runs = crafts_adding(game, commons, [3, 3, 3, 3, 3, 3])
            allow(tm).to receive(:repair)

            tm.nezhiri('glop', 16, glop.merge(uses: 17))

            expect(bought).to eq([3, 3])
            expect(remedy_runs(runs)).to eq(6)
            expect(DRC).to have_received(:message).with('9 of 16 doses of gill glop made: 3 more crafts to make.')
            expect(tm.instance_variable_get(:@remedy_doses)).to eq(18)
            expect(tm).to have_received(:repair).once
          end

          it 'never plans a craft at more than 6 doses, nor at none, and plans by the fewest seen' do
            tm = maker
            plans = [[nil, 7], [7, 7], [6, 7], [5, 7], [4, 2], [3, 7], [1, 3]].map do |seen, short|
              tm.instance_variable_set(:@remedy_yield, seen)
              tm.remedy_top_up_crafts(short, 'gill glop')
            end
            expect(plans).to eq([2, 2, 2, 2, 1, 3, 3])
          end

          it 'keeps the fewest doses a craft added, passing over a craft that added none' do
            tm = maker(remedy_yield: nil)
            [5, 0, 4, 6, -1].each { |gain| tm.note_remedy_yield(gain) }
            expect(tm.instance_variable_get(:@remedy_yield)).to eq(4)
          end

          # The finish path: the 4 doses carried count once, toward the
          # doses owed and not as a craft's.
          it 'counts the doses carried once: 4 carried and two crafts of 3 leave 6 of 16 short, two more crafts' do
            tm = maker(task_product: 'gill glop')
            game, commons = shop_world(kit + [['gill glop', 'duffel bag', '7101']])
            game.script('inventory duffel bag', *bag_listed('some gill glop'))
            game.script('count #7101', ReplayGame.log('6100:10519')) # 4 doses
            bought = bought_crafts(tm)
            runs = crafts_adding(game, commons, [3, 3, 3, 3], on_hand: ['7101', 4])
            allow(tm).to receive(:repair)

            tm.nezhiri('glop', 16, glop.merge(uses: 4))

            expect(DRC).to have_received(:message).with('16 doses of gill glop owed, 4 on hand: 2 crafts to make.')
            expect(DRC).to have_received(:message).with('10 of 16 doses of gill glop made: 2 more crafts to make.')
            expect(bought).to eq([2, 2])
            expect(remedy_runs(runs)).to eq(4)
            expect(tm.instance_variable_get(:@remedy_doses)).to eq(16)
          end

          it 'makes no extra craft when the crafts planned make exactly the doses owed' do
            tm = maker(task_product: 'gill glop')
            game, commons = shop_world(kit)
            game.script('inventory duffel bag', *bag_listed)
            bought = bought_crafts(tm)
            runs = crafts_adding(game, commons, [6, 6])
            allow(tm).to receive(:repair)

            tm.nezhiri('glop', 12, glop)

            expect(bought).to eq([2])
            expect(remedy_runs(runs)).to eq(2)
            expect(DRC).not_to have_received(:message).with(/more craft|short of the/)
            expect(tm).to have_received(:repair).once
          end

          it 'stops, the stack in the bag and no tools to Rangu, when the extra crafts add no doses' do
            tm = maker(task_product: 'gill glop')
            game, commons = shop_world(kit)
            game.script('inventory duffel bag', *bag_listed)
            bought = bought_crafts(tm)
            runs = crafts_adding(game, commons, [5, 4, 4, 0])
            allow(tm).to receive(:repair)

            expect { tm.nezhiri('glop', 15, glop.merge(uses: 16)) }.to raise_error(SystemExit)

            expect(bought).to eq([3, 1])
            expect(remedy_runs(runs)).to eq(4)
            expect(DRC).to have_received(:message)
              .with('The last crafts added no doses, so more of them would not help. 13 doses made is short of the 15 owed. Run ;taskmaster nezhiri finish to make the rest. Stopping.')
            expect(commons.location_of('#7009')).to eq('duffel bag')
            expect(tm).not_to have_received(:repair)
          end

          # Two rounds of extra crafts, each adding a dose: still short, so
          # the run stops rather than buy a third round.
          it 'stops after two rounds of extra crafts that leave the doses short, buying no third' do
            tm = maker(task_product: 'gill glop')
            game, commons = shop_world(kit)
            game.script('inventory duffel bag', *bag_listed)
            bought = bought_crafts(tm)
            runs = crafts_adding(game, commons, [5, 5, 1] + [1, 0, 0, 0] + [1, 0, 0])
            allow(tm).to receive(:repair)

            expect { tm.nezhiri('glop', 15, glop.merge(uses: 20)) }.to raise_error(SystemExit)

            expect(bought).to eq([3, 4, 3])
            expect(remedy_runs(runs)).to eq(10)
            expect(DRC).to have_received(:message).with('11 of 15 doses of gill glop made: 4 more crafts to make.')
            expect(DRC).to have_received(:message).with('12 of 15 doses of gill glop made: 3 more crafts to make.')
            expect(DRC).to have_received(:message)
              .with('2 rounds of extra crafts did not make up the doses. 13 doses made is short of the 15 owed. Run ;taskmaster nezhiri finish to make the rest. Stopping.')
            expect(tm.instance_variable_get(:@remedy_studies)).to eq(10)
            expect(tm).not_to have_received(:repair)
          end

          # The uses are read once, at the start: the 3 crafts planned spent
          # the 3 uses (the game tossed the set at its last), and no other
          # set is carried, so the extra one has none.
          it 'stops before buying for the extra crafts when the studies this run spent the uses and no other set is carried' do
            tm = maker(task_product: 'gill glop')
            game, commons = shop_world(kit)
            game.script('inventory duffel bag', *bag_listed)
            instruction_sets(game, commons, 'glop', [])
            bought = bought_crafts(tm)
            runs = crafts_adding(game, commons, [5, 4, 4])
            allow(tm).to receive(:repair)

            expect { tm.nezhiri('glop', 15, glop.merge(uses: 3)) }.to raise_error(SystemExit)

            expect(bought).to eq([3])
            expect(remedy_runs(runs)).to eq(3)
            expect(DRCI).to have_received(:get_item?).with('glop instructions', 'duffel bag')
            expect(commons.calls.select { |name, *| name == 'DRCT.walk_to' }.count { |call| call[1] == 7896 }).to eq(1)
            expect(DRC).to have_received(:message)
              .with('The glop instructions you carry have 0 uses left, and 1 more craft is needed. The 13 doses made so far stay in your duffel bag. ' \
                    'Ask Nezhiri for another copy (ASK NEZHIRI FOR INSTRUCTIONS), then run ;taskmaster nezhiri finish. Stopping before buying anything more.')
            expect(commons.location_of('#7007')).to eq('duffel bag')
            expect(tm).not_to have_received(:repair)
          end

          # A finish takes the first set with a use for each craft planned
          # (ensure_instructions); a top-up then counts the sets behind it,
          # which remedy studies once the game tosses the first.
          it 'goes on to the extra craft when the uses read at the start are spent but another set carried has a use for it' do
            tm = maker(task_product: 'gill glop')
            game, commons = shop_world(kit)
            game.script('inventory duffel bag', *bag_listed)
            bag = instruction_sets(game, commons, 'glop', [1])
            bought = bought_crafts(tm)
            runs = crafts_adding(game, commons, [5, 4, 4, 6])
            allow(tm).to receive(:repair)

            tm.nezhiri('glop', 15, glop.merge(uses: 3))

            expect(bought).to eq([3, 1])
            expect(remedy_runs(runs)).to eq(4)
            expect(game.sent.grep(/\Aread /)).to eq(['read my glop instructions'])
            expect(bag).to eq([1])
            expect(DRC).not_to have_received(:message).with(/uses? left/)
            expect(tm).to have_received(:repair).once
          end

          it 'adds up the uses of every set carried, binning a foreign one, and stops before buying when they are still too few' do
            tm = maker(task_product: 'gill glop', worn_trashcan: 'bucket', worn_trashcan_verb: 'drop')
            game, commons = shop_world(kit)
            game.script('inventory duffel bag', *bag_listed)
            bag = instruction_sets(game, commons, 'glop', [1, :foreign, 1])
            bought = bought_crafts(tm)
            runs = crafts_adding(game, commons, [3, 3, 3])
            allow(tm).to receive(:repair)

            expect { tm.nezhiri('glop', 16, glop.merge(uses: 3)) }.to raise_error(SystemExit)

            expect(bought).to eq([3])
            expect(remedy_runs(runs)).to eq(3)
            expect(game.sent.grep(/\Aread /)).to eq(['read my glop instructions'] * 3)
            expect(DRCI).to have_received(:dispose_trash).with('glop instructions', 'bucket', 'drop').once
            # The binned set leaves the bag, so the ordinal does not move on for it.
            expect(DRCI).to have_received(:get_item?).with('second glop instructions', 'duffel bag').twice
            expect(DRCI).to have_received(:get_item?).with('third glop instructions', 'duffel bag').once
            expect(bag).to eq([1, 1])
            expect(DRC).to have_received(:message)
              .with('The glop instructions you carry have 2 uses left, and 3 more crafts are needed. The 9 doses made so far stay in your duffel bag. ' \
                    'Ask Nezhiri for another copy (ASK NEZHIRI FOR INSTRUCTIONS), then run ;taskmaster nezhiri finish. Stopping before buying anything more.')
            expect(tm).not_to have_received(:repair)
          end

          # 6, 6 and 1 make 13 of 18: five more crafts planned at 1 a craft,
          # but the first of them makes 6, which covers the doses owed.
          it 'stops the extra crafts as soon as the doses cover the task' do
            tm = maker(task_product: 'gill glop')
            game, commons = shop_world(kit)
            game.script('inventory duffel bag', *bag_listed)
            bought = bought_crafts(tm)
            runs = crafts_adding(game, commons, [6, 6, 1, 6, 6])
            allow(tm).to receive(:repair)

            tm.nezhiri('glop', 18, glop.merge(uses: 19))

            expect(bought).to eq([3, 5])
            expect(remedy_runs(runs)).to eq(4)
            expect(DRC).to have_received(:message).with('13 of 18 doses of gill glop made: 5 more crafts to make.')
            expect(DRC).to have_received(:message).with('19 doses of gill glop made and combined into one.')
            expect(tm.instance_variable_get(:@remedy_doses)).to eq(19)
            expect(tm.instance_variable_get(:@remedy_studies)).to eq(4)
            expect(tm).to have_received(:repair).once
          end

          # The finish path: the planned crafts leave the 4 doses carried at 4.
          it 'stops, buying no extra crafts and no tools to Rangu, when the crafts planned add no doses' do
            tm = maker(task_product: 'gill glop')
            game, commons = shop_world(kit + [['gill glop', 'duffel bag', '7101']])
            game.script('inventory duffel bag', *bag_listed('some gill glop'))
            game.script('count #7101', ReplayGame.log('6100:10519')) # 4 doses
            bought = bought_crafts(tm)
            runs = crafts_adding(game, commons, [0, 0], on_hand: ['7101', 4])
            allow(tm).to receive(:repair)

            expect { tm.nezhiri('glop', 12, glop) }.to raise_error(SystemExit)

            expect(bought).to eq([2])
            expect(remedy_runs(runs)).to eq(2)
            expect(DRC).not_to have_received(:message).with(/more craft/)
            expect(DRC).to have_received(:message)
              .with('The last crafts added no doses, so more of them would not help. 4 doses made is short of the 12 owed. Run ;taskmaster nezhiri finish to make the rest. Stopping.')
            expect(tm).not_to have_received(:repair)
          end

          it 'goes on to the extra craft when the set has exactly one use left for it' do
            tm = maker(task_product: 'gill glop')
            game, commons = shop_world(kit)
            game.script('inventory duffel bag', *bag_listed)
            bought = bought_crafts(tm)
            runs = crafts_adding(game, commons, [5, 4, 4, 6])
            allow(tm).to receive(:repair)

            tm.nezhiri('glop', 15, glop.merge(uses: 4))

            expect(bought).to eq([3, 1])
            expect(remedy_runs(runs)).to eq(4)
            expect(DRC).not_to have_received(:message).with(/uses? left/)
          end

          it 'checks no uses for the extra crafts when none were read off the set' do
            tm = maker(task_product: 'gill glop')
            game, commons = shop_world(kit)
            game.script('inventory duffel bag', *bag_listed)
            bought = bought_crafts(tm)
            crafts_adding(game, commons, [5, 4, 4, 6])
            allow(tm).to receive(:repair)

            tm.nezhiri('glop', 15, glop.merge(uses: nil))

            expect(bought).to eq([3, 1])
            expect(tm).to have_received(:repair).once
          end

          # run_tasks works one task after another on the same instance: the
          # yield and studies of the task before must not carry into the next.
          it 'starts each task with no yield or studies from the task before' do
            tm = maker(task_product: 'gill glop', remedy_yield: 1, remedy_studies: 9)
            game, commons = shop_world(kit)
            game.script('inventory duffel bag', *bag_listed)
            bought = bought_crafts(tm)
            crafts_adding(game, commons, [5, 4, 4, 6])
            allow(tm).to receive(:repair)

            tm.nezhiri('glop', 15, glop.merge(uses: 4))

            expect(bought).to eq([3, 1])
            expect([tm.instance_variable_get(:@remedy_yield), tm.instance_variable_get(:@remedy_studies)]).to eq([4, 4])
          end

          # The fewest doses one craft made is remembered per character
          # (UserVars) and product, and the next task's crafts are planned by
          # it: 6400's character made 5 a craft (6400:679, 6400:805), so every
          # repeat task planned at 6 fell short and needed an extra round.
          describe 'remembering the yield for the next task' do
            let(:supplies_once) do
              lambda do |game, herb|
                game.script('count my first brine', ReplayGame.log('6100:8800')) # ten parts
                game.script('count my second brine', ReplayGame.log('6100:8793'))
                game.script('tap my first coal nugget', ReplayGame.log('6100:8910')) # large: 4 rubs
                game.script("count my first #{herb}", ReplayGame.log('6100:8793'))
              end
            end

            it 'stores the fewest doses one craft added, not the last craft nor the average: 6, 4, 6 stores 4' do
              tm = maker(task_product: 'gill glop')
              game, commons = shop_world(kit)
              game.script('inventory duffel bag', *bag_listed)
              bought = bought_crafts(tm)
              crafts_adding(game, commons, [6, 4, 6])
              allow(tm).to receive(:repair)

              tm.nezhiri('glop', 16, glop.merge(uses: 17))

              expect(bought).to eq([3])
              expect(UserVars.taskmaster_remedy_yields).to eq('gill glop' => 4)
            end

            # 6400's shape with the smallest craft last: the last craft's own
            # gain must count before the yield is stored.
            it 'stores the last craft\'s gain when it is the fewest: 6, 6, 4 stores 4' do
              UserVars.taskmaster_remedy_yields = { 'gill glop' => 6 }
              tm = maker(task_product: 'gill glop')
              game, commons = shop_world(kit)
              game.script('inventory duffel bag', *bag_listed)
              bought = bought_crafts(tm)
              runs = crafts_adding(game, commons, [6, 6, 4])
              allow(tm).to receive(:repair)

              tm.nezhiri('glop', 16, glop.merge(uses: 17))

              expect(bought).to eq([3])
              expect(remedy_runs(runs)).to eq(3)
              expect(UserVars.taskmaster_remedy_yields).to eq('gill glop' => 4)
            end

            # The yield is stored after each craft, so a stop inside the
            # crafts (here the game will not combine craft 2's stack,
            # 6100:9229) still leaves craft 1's 5 stored over the 6.
            it 'stores the doses the crafts made so far when a later craft stops the run' do
              UserVars.taskmaster_remedy_yields = { 'gill glop' => 6 }
              tm = maker(task_product: 'gill glop')
              game, commons = shop_world(kit)
              allow(tm).to receive(:buy_remedy_supplies)
              runs = remedy_makes(commons, 'gill glop', %w[7001 7002])
              game.script('inventory duffel bag', *bag_listed)
              game.script('count #7001', ReplayGame.log('6100:28265')) # 5 doses
              game.script('combine #7001 with #7002', ReplayGame.log('6100:9229'))

              expect { tm.nezhiri('glop', 13, glop) }.to raise_error(SystemExit)

              expect(remedy_runs(runs)).to eq(2)
              expect(DRC).to have_received(:message).with('Could not combine the gill glop (You must be holding both). Stopping.')
              expect(UserVars.taskmaster_remedy_yields).to eq('gill glop' => 5)
            end

            # 6400 again, with its 5 a craft remembered: three crafts planned
            # at the start, one purchase and no extra round. The second
            # COMBINE and the third COUNT are past 6400's end: 6100's lines
            # stand in.
            it 'plans 3 crafts for 12 doses with 5 a craft remembered, and makes no extra round when they make 5 each (6400)' do
              UserVars.taskmaster_remedy_yields = { 'scale moisturizer' => 5 }
              tm = maker(task_product: 'scale moisturizer')
              game, commons = shop_world(kit, shop: :model)
              game.script('inventory duffel bag', *bag_listed)
              supplies_once.call(game, 'red flowers')
              runs = remedy_makes(commons, 'scale moisturizer', %w[7002 7004 7006])
              game.script('count #7002', ReplayGame.log('6400:683'))
              game.script('combine #7002 with #7004', ReplayGame.log('6400:811'), after: merges(commons, 'scale moisturizer', '7002', '7004', into: '7005'))
              game.script('count #7005', ReplayGame.log('6400:813'))
              game.script('combine #7005 with #7006', ReplayGame.log('6100:9368'), after: merges(commons, 'scale moisturizer', '7005', '7006', into: '7007'))
              game.script('count #7007', ReplayGame.log('6100:6040')) # 15 doses
              allow(tm).to receive(:repair)

              tm.nezhiri('moisturizer', 12, moisturizer)

              expect(DRC).to have_received(:message).with('12 doses of scale moisturizer owed, 0 on hand: 3 crafts to make (5 doses a craft last time).')
              expect(remedy_runs(runs)).to eq(3)
              expect(commons.calls.select { |name, *| name == 'DRCT.order_item' }).to eq([['DRCT.order_item', 8862, 13]] * 3)
              expect(commons.calls.select { |name, *| name == 'DRCM.ensure_copper_on_hand' }).to eq([['DRCM.ensure_copper_on_hand', (3 * 343) + 7500, 'Crossing']])
              expect(DRC).not_to have_received(:message).with(/more craft|short of the|uses? left/)
              expect(tm.instance_variable_get(:@remedy_doses)).to eq(15)
              expect(UserVars.taskmaster_remedy_yields).to eq('scale moisturizer' => 5)
              expect(tm).to have_received(:repair).once
              expect(game.diagnostics).to eq([])
            end

            # Replaced, not the smallest ever: a character whose crafts now
            # make 6 plans at 6 again.
            it 'replaces a remembered 5 with the 6 a craft this task made, leaving the other products alone' do
              UserVars.taskmaster_remedy_yields = { 'gill glop' => 5, 'scale moisturizer' => 4 }
              tm = maker(task_product: 'gill glop')
              game, commons = shop_world(kit)
              game.script('inventory duffel bag', *bag_listed)
              bought = bought_crafts(tm)
              runs = crafts_adding(game, commons, [6, 6])
              allow(tm).to receive(:repair)

              tm.nezhiri('glop', 12, glop)

              expect(DRC).to have_received(:message).with('12 doses of gill glop owed, 0 on hand: 3 crafts to make (5 doses a craft last time).')
              expect(bought).to eq([3]) # planned at 5; the third craft is not made once the 12 are
              expect(remedy_runs(runs)).to eq(2)
              expect(UserVars.taskmaster_remedy_yields).to eq('gill glop' => 6, 'scale moisturizer' => 4)
              expect([tm.remedy_planned_yield('gill glop'), tm.nezhiri_crafts(12, tm.remedy_planned_yield('gill glop'))]).to eq([6, 2])
            end

            it 'leaves the remembered yield alone when the doses on hand cover the task and nothing is crafted' do
              UserVars.taskmaster_remedy_yields = { 'gill glop' => 4 }
              tm = maker(task_product: 'gill glop')
              game, = shop_world(kit + [['gill glop', 'duffel bag', '7101']])
              game.script('inventory duffel bag', *bag_listed('some gill glop'))
              game.script('count #7101', ReplayGame.log('6100:9539')) # 18 doses
              bought = bought_crafts(tm)
              allow(tm).to receive(:repair)

              tm.nezhiri('glop', 13, glop)

              expect(DRC).to have_received(:message).with('13 doses of gill glop owed, 18 on hand: 0 crafts to make.')
              expect(bought).to eq([])
              expect(UserVars.taskmaster_remedy_yields).to eq('gill glop' => 4)
              expect(tm).not_to have_received(:repair)
            end

            # remedy stopped before it got the mortar: the run stops on craft
            # 1 with no doses added, and the yield from the task before stays.
            it 'leaves the remembered yield alone when the first craft stops before adding any doses' do
              UserVars.taskmaster_remedy_yields = { 'gill glop' => 5 }
              tm = maker(task_product: 'gill glop')
              game, commons = shop_world(kit)
              runs = remedy_makes(commons, 'gill glop', [])
              game.script('inventory duffel bag', *bag_listed)
              game.script('count my first brine', ReplayGame.log('6100:8800'))
              game.script('count my second brine', ReplayGame.log('6100:8793'))
              game.script('count my first georin', ReplayGame.log('6100:4595'))
              game.script('count my second georin', ReplayGame.log('6100:8793'))
              game.script('tap my first coal nugget', ReplayGame.log('6100:8910'))
              2.times { game.script('order 7', ReplayGame.log('6100:8888')).script('order 7', ReplayGame.log('6100:8890')) }

              expect { tm.nezhiri('glop', 13, glop) }.to raise_error(SystemExit)

              expect(remedy_runs(runs)).to eq(1)
              expect(DRC).to have_received(:message).with(/\Aremedy did not leave any gill glop in your hands \(craft 1 of 3\)/)
              expect(UserVars.taskmaster_remedy_yields).to eq('gill glop' => 5)
            end

            # The finish path's 4 doses carried, and two crafts that add none.
            it 'leaves the remembered yield alone when crafts are made but add no doses' do
              UserVars.taskmaster_remedy_yields = { 'gill glop' => 4 }
              tm = maker(task_product: 'gill glop')
              game, commons = shop_world(kit + [['gill glop', 'duffel bag', '7101']])
              game.script('inventory duffel bag', *bag_listed('some gill glop'))
              game.script('count #7101', ReplayGame.log('6100:10519')) # 4 doses
              bought_crafts(tm)
              runs = crafts_adding(game, commons, [0, 0], on_hand: ['7101', 4])
              allow(tm).to receive(:repair)

              expect { tm.nezhiri('glop', 12, glop) }.to raise_error(SystemExit)

              expect(DRC).to have_received(:message).with('12 doses of gill glop owed, 4 on hand: 2 crafts to make (4 doses a craft last time).')
              expect(remedy_runs(runs)).to eq(2)
              expect(UserVars.taskmaster_remedy_yields).to eq('gill glop' => 4)
            end

            # A stop after the crafts (here the extra round adds nothing)
            # still leaves this task's own fewest stored, replacing the 6.
            it 'stores the fewest doses a craft added even when the task then stops short' do
              UserVars.taskmaster_remedy_yields = { 'gill glop' => 6 }
              tm = maker(task_product: 'gill glop')
              game, commons = shop_world(kit)
              game.script('inventory duffel bag', *bag_listed)
              bought = bought_crafts(tm)
              crafts_adding(game, commons, [5, 4, 4, 0])
              allow(tm).to receive(:repair)

              expect { tm.nezhiri('glop', 15, glop.merge(uses: 16)) }.to raise_error(SystemExit)

              expect(bought).to eq([3, 1])
              expect(DRC).to have_received(:message).with(/short of the 15 owed/)
              expect(UserVars.taskmaster_remedy_yields).to eq('gill glop' => 4)
            end

            # Nothing in the logs shows a craft making more than 6, so a
            # stored 7 (or 9, set by hand) still plans at 6, with no note.
            it 'plans at no more than 6 doses a craft whatever is remembered, and says nothing of a yield of 6 or more' do
              UserVars.taskmaster_remedy_yields = { 'gill glop' => 9 }
              tm = maker(task_product: 'gill glop')
              game, commons = shop_world(kit)
              game.script('inventory duffel bag', *bag_listed)
              bought = bought_crafts(tm)
              crafts_adding(game, commons, [6, 6])
              allow(tm).to receive(:repair)

              tm.nezhiri('glop', 12, glop)

              expect(DRC).to have_received(:message).with('12 doses of gill glop owed, 0 on hand: 2 crafts to make.')
              expect(bought).to eq([2])
              expect(UserVars.taskmaster_remedy_yields).to eq('gill glop' => 6)
            end

            it 'plans at 6 when nothing usable is remembered: unset, not a Hash, another product, or not a positive whole number' do
              tm = maker
              stored = [nil, 'junk', [5], { 'scale moisturizer' => 3 }, { 'gill glop' => 0 }, { 'gill glop' => -2 }, { 'gill glop' => '5' },
                        { 'gill glop' => 4.5 }, { 'gill glop' => nil }, { 'gill glop' => 7 }, { 'gill glop' => 6 }, { 'gill glop' => 1 }, { 'gill glop' => 5 }]
              plans = stored.map do |value|
                UserVars.taskmaster_remedy_yields = value
                tm.remedy_planned_yield('gill glop')
              end
              expect(plans).to eq([6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 1, 5])
            end

            it 'looks the product up whatever its case, and an unknown product (nil) plans at 6' do
              UserVars.taskmaster_remedy_yields = { 'scale moisturizer' => 4 }
              tm = maker
              expect([tm.remedy_planned_yield('Scale Moisturizer'), tm.remedy_planned_yield('scale moisturizer'), tm.remedy_planned_yield(nil),
                      tm.remedy_planned_yield('gill glop')]).to eq([4, 4, 6, 6])
            end

            it 'replaces a stored value that is not a Hash, and stores the product in lower case' do
              tm = maker(remedy_yield: 5)
              UserVars.taskmaster_remedy_yields = %w[not a hash]
              tm.remember_remedy_yield('Scale Moisturizer')
              expect(UserVars.taskmaster_remedy_yields).to eq('scale moisturizer' => 5)
            end

            it 'stores nothing, and creates no Hash, while this run has no yield' do
              tm = maker(remedy_yield: nil)
              tm.remember_remedy_yield('gill glop')
              expect(UserVars.taskmaster_remedy_yields).to be_nil
              tm.instance_variable_set(:@remedy_yield, 0)
              tm.remember_remedy_yield('gill glop')
              expect(UserVars.taskmaster_remedy_yields).to be_nil
            end

            # Extra crafts plan by this run's fewest when there is one (it is
            # fresher than the task before's), else as the first round did.
            it "plans extra crafts at this run's fewest over the remembered one, and at the remembered one only when this run has none" do
              tm = maker
              plans = [[5, 4, 10], [6, 3, 7], [4, 5, 9], [nil, 4, 10], [nil, 9, 7], [nil, nil, 7], [8, 3, 7]].map do |seen, remembered, short|
                UserVars.taskmaster_remedy_yields = remembered && { 'gill glop' => remembered }
                tm.instance_variable_set(:@remedy_yield, seen)
                tm.remedy_top_up_crafts(short, 'gill glop')
              end
              expect(plans).to eq([2, 2, 3, 3, 2, 2, 2])
            end

            # Remembered 4, so 4 crafts for 15; they make 5, 5, 1 and 1: the
            # extra round plans the 3 short at this run's 1 a craft (3
            # crafts), not at the 4 remembered (1 craft).
            it "plans the extra round at this run's fewest when it is below the remembered yield" do
              UserVars.taskmaster_remedy_yields = { 'gill glop' => 4 }
              tm = maker(task_product: 'gill glop')
              game, commons = shop_world(kit)
              game.script('inventory duffel bag', *bag_listed)
              bought = bought_crafts(tm)
              crafts_adding(game, commons, [5, 5, 1, 1, 1, 1, 1])
              allow(tm).to receive(:repair)

              tm.nezhiri('glop', 15, glop.merge(uses: 16))

              expect(DRC).to have_received(:message).with('15 doses of gill glop owed, 0 on hand: 4 crafts to make (4 doses a craft last time).')
              expect(DRC).to have_received(:message).with('12 of 15 doses of gill glop made: 3 more crafts to make.')
              expect(bought).to eq([4, 3])
              expect(UserVars.taskmaster_remedy_yields).to eq('gill glop' => 1)
            end
          end
        end
      end

      describe 'what the wait before her task found, and the INVENTORY taken for the doses on hand' do
        # Gnarta's crafting bag as INVENTORY listed it (2026-11-18 16:16:51).
        let(:gnarta_bag) do
          ['some deep-sea draught', 'a large purpleheart bowl edged with ivory', 'a grooved agonite mixing stick', 'a medium coal nugget',
           "some brewer's brine", 'some deep-sea draught instructions', 'a trapezoidal loimic wire sieve', 'some gill glop',
           'a polished belzune stone mortar', 'a loimic grooved pestle', 'some dried georin', 'some landsickness potion', 'some grain alcohol', 'some water']
        end
        let(:herb_pieces) { { 'georin' => 25, 'red flowers' => 0, 'aevaes' => 0, 'junliar' => 50 } }
        # TAP of a coal nugget, shaped like 6100:3154 ("You tap a tiny coal
        # nugget inside your leather satchel.") with each size.
        def coal_tap(size)
          "You tap a #{size} coal nugget inside your duffel bag."
        end

        # Runs survey_remedy_supplies with every game step recorded in order:
        # the INVENTORY (nil: unanswered), each COUNT (parts by item), each
        # tool, water and alcohol TAP (all found), each coal TAP (taps by
        # command, else none found) and the WEALTH.
        def surveying(tm, listing: gnarta_bag, taps: {}, wealth: 55_437_323, brine: 8, missing: [])
          steps = []
          inventory_replies('inventory duffel bag' => lambda { |command|
            steps << command
            listing && inventoried(listing)
          })
          parts = herb_pieces.merge('brine' => brine)
          allow(DRCI).to receive(:count_item_parts) { |item| steps << "count #{item}" && parts.fetch(item) }
          allow(DRCI).to receive(:in_hands?).and_return(false)
          allow(DRCI).to receive(:exists?) { |item| steps << "tap #{item}" && !missing.include?(item) }
          allow(DRCM).to receive(:wealth) { |town| steps << "wealth #{town}" && wealth }
          game('tap my' => ->(command, *) { steps << command && taps.fetch(command, 'I could not find what you were referring to.') })
          tm.survey_remedy_supplies
          steps
        end

        describe '#survey_remedy_supplies' do
          it "counts the brine, the coal and all four herbs, reads the tools off the bag's INVENTORY, taps water and alcohol, and reads the copper last" do
            tm = maker
            steps = surveying(tm, taps: { 'tap my first coal nugget' => coal_tap('medium') })

            # The medium nugget listed has 3 rubs, short of 6: every nugget is
            # tapped, as one may be kept outside the bag.
            expect(steps).to eq(['inventory duffel bag', 'count brine', 'tap my first coal nugget', 'tap my second coal nugget',
                                 'count georin', 'count red flowers', 'count aevaes', 'count junliar', 'tap water', 'tap alcohol', 'wealth Crossing'])
            expect(tm.instance_variable_get(:@stock_survey))
              .to eq(brine_parts: 8, coal_rubs: 3, herb_parts: herb_pieces, missing_tools: [], water: true, alcohol: true, copper: 55_437_323)
          end

          it 'taps no coal when the nuggets listed already have six rubs' do
            tm = maker
            steps = surveying(tm, listing: gnarta_bag.map { |line| line.sub('medium', 'massive') })

            expect(steps.grep(/coal/)).to eq([])
            expect(tm.instance_variable_get(:@stock_survey)[:coal_rubs]).to eq(6)
          end

          it 'taps a tool the bag does not list (on a belt, in another container) and finds one missing' do
            tm = maker
            steps = surveying(tm, listing: gnarta_bag - ['a loimic grooved pestle', 'a trapezoidal loimic wire sieve'], missing: ['sieve'])

            expect(steps.grep(/\Atap (?!my )/)).to eq(['tap pestle', 'tap sieve', 'tap water', 'tap alcohol'])
            expect(tm.instance_variable_get(:@stock_survey)[:missing_tools]).to eq(['sieve'])
          end

          # A TAP with no answer may have left nuggets uncounted: the rubs the
          # TAPs before it confirmed are kept, marked not whole.
          it 'keeps the rubs a TAP confirmed, marked not whole, when a later TAP goes unanswered' do
            tm = maker
            steps = surveying(tm, taps: { 'tap my first coal nugget' => coal_tap('medium'), 'tap my second coal nugget' => '' })

            expect(steps.grep(/coal/)).to eq(['tap my first coal nugget', 'tap my second coal nugget'])
            expect(tm.instance_variable_get(:@stock_survey)).to include(coal_rubs: 3, coal_whole: false)
          end

          it 'marks nothing when every TAP was answered' do
            tm = maker
            surveying(tm, taps: { 'tap my first coal nugget' => coal_tap('medium') })

            expect(tm.instance_variable_get(:@stock_survey)).not_to have_key(:coal_whole)
          end

          it 'taps every tool and the coal when INVENTORY goes unanswered' do
            steps = surveying(maker, listing: nil, taps: { 'tap my first coal nugget' => coal_tap('massive') })

            expect(steps).to eq(['inventory duffel bag', 'count brine', 'tap my first coal nugget', 'count georin', 'count red flowers', 'count aevaes', 'count junliar',
                                 'tap bowl', 'tap mixing stick', 'tap mortar', 'tap pestle', 'tap sieve', 'tap water', 'tap alcohol', 'wealth Crossing'])
          end
        end

        describe '#nezhiri_wait_chores' do
          it 'pauses what is left of the poll interval after the survey, and not at all when the survey took longer' do
            [[4.5, 2.5], [9, 0]].each do |took, left|
              tm = maker(cooldown_poll: 7)
              start = Time.at(1_000)
              times = [start, start + took]
              allow(Time).to receive(:now) { times.shift || (start + took) }
              allow(tm).to receive(:survey_remedy_supplies)
              allow(tm).to receive(:pause)

              tm.nezhiri_wait_chores

              expect(tm).to have_received(:survey_remedy_supplies).ordered
              expect(tm).to have_received(:pause).with(left).ordered
            end
          end
        end

        describe 'using each answer once' do
          it 'takes the brine count the wait made for the first check, and counts afresh for the next' do
            tm = maker(stock_survey: { brine_parts: 1 })
            allow(DRCI).to receive(:count_item_parts).with('brine').and_return(30)

            expect([tm.brines_to_buy(3), tm.brines_to_buy(3)]).to eq([1, 0])
            expect(DRCI).to have_received(:count_item_parts).once
          end

          it 'takes the coal the wait counted when it stopped short of six rubs or covers the crafts, and taps afresh when the crafts need more' do
            sent = []
            game('tap my' => lambda { |command, *|
              sent << command
              { 'tap my first coal nugget' => coal_tap('massive'), 'tap my second coal nugget' => coal_tap('large') }.fetch(command, '')
            })
            coal = ->(survey, crafts) { maker(stock_survey: survey.merge(water: true, alcohol: true)).missing_remedy_supplies(crafts).map { |supply| supply[:name] } }

            # Two rubs, all the nuggets carried: a nugget for three crafts, no TAP.
            expect([coal.call({ coal_rubs: 2 }, 3), sent]).to eq([['coal nugget'], []])
            # Six or more cover three crafts.
            expect([coal.call({ coal_rubs: 6 }, 3), sent]).to eq([[], []])
            # Six may be more than counted: seven crafts tap afresh, and the
            # massive and large nuggets carried cover them.
            expect([coal.call({ coal_rubs: 6 }, 7), sent]).to eq([[], ['tap my first coal nugget', 'tap my second coal nugget']])
          end

          # The wait's TAP of the medium nugget went unanswered; the round's
          # INVENTORY lists it, and its 3 rubs cover three crafts.
          it 'buys no coal when a fresh INVENTORY lists enough, whatever the wait counted' do
            sent = []
            game('tap my' => ->(command, *) { sent << command && '' })
            listed = ['a medium coal nugget']
            coal = ->(survey) { maker(stock_survey: survey.merge(water: true, alcohol: true)).missing_remedy_supplies(3, listed).map { |supply| supply[:name] } }

            expect([coal.call({ coal_rubs: 0 }), coal.call({ coal_rubs: nil }), coal.call({}), sent]).to eq([[], [], [], []])
          end

          # OSXLich-Doug's sequence on #8122: a medium nugget kept outside the
          # crafting bag, its TAP in the wait answered, the next one not, and
          # every TAP after the accept unanswered too.
          it 'buys no coal when the wait confirmed enough rubs, though its count was cut short and every TAP after goes unanswered' do
            tm = maker
            surveying(tm, listing: gnarta_bag.reject { |line| line.include?('coal') }, taps: { 'tap my first coal nugget' => coal_tap('medium'), 'tap my second coal nugget' => '' })
            sent = []
            game('tap my' => ->(command, *) { sent << command && '' })
            tm.instance_variable_get(:@stock_survey).merge!(water: true, alcohol: true)

            expect(tm.missing_remedy_supplies(3).map { |supply| supply[:name] }).to eq([])
            expect(sent).to eq([])
          end

          it 'counts again when a cut-short count falls short, keeps the larger when that goes unanswered too, and goes by a whole recount' do
            replies = {}
            sent = []
            game('tap my' => ->(command, *) { sent << command && replies.fetch(command, '') })
            coal = ->(rubs, crafts) { maker(stock_survey: { coal_rubs: rubs, coal_whole: false, water: true, alcohol: true }).missing_remedy_supplies(crafts).map { |supply| supply[:name] } }

            # Unanswered again: the wait's 3 confirmed rubs stand, short of 4.
            expect([coal.call(3, 4), coal.call(3, 3)]).to eq([['coal nugget'], []])
            # A whole recount answers, more or fewer than the wait's.
            replies['tap my first coal nugget'] = coal_tap('large')
            expect(coal.call(3, 4)).to eq([])
            replies['tap my first coal nugget'] = 'I could not find what you were referring to.'
            expect(coal.call(2, 3)).to eq(['coal nugget'])
            expect(sent.count('tap my first coal nugget')).to eq(3)
          end

          it 'counts the coal afresh when the wait kept no count, and buys on what that finds' do
            sent = []
            game('tap my' => ->(command, *) { sent << command && 'I could not find what you were referring to.' })
            tm = maker(stock_survey: { coal_rubs: nil, water: true, alcohol: true })

            expect(tm.missing_remedy_supplies(3).map { |supply| supply[:name] }).to eq(['coal nugget'])
            expect(sent).to eq(['tap my first coal nugget'])
          end

          it 'leaves the herb count for the first round with herbs when a craft carried on buys none, then counts afresh' do
            tm = maker(stock_survey: { herb_parts: { 'georin' => 50 } })
            allow(tm).to receive(:brines_to_buy).and_return(0)
            allow(tm).to receive(:missing_remedy_supplies).and_return([])
            allow(DRCI).to receive(:count_item_parts).and_return(0)
            ordered = []
            allow(tm).to receive(:order_remedy_supply) { |_room, number, *| ordered << number }
            allow(DRCM).to receive(:ensure_copper_on_hand).and_return(true)

            tm.buy_remedy_supplies(glop_recipe, 1, herbs: false)
            tm.buy_remedy_supplies(glop_recipe, 3)
            # 50 pieces carried: two stacks of the three, so one is ordered.
            expect(ordered).to eq([7])
            expect(DRCI).not_to have_received(:count_item_parts)
            tm.buy_remedy_supplies(glop_recipe, 3)
            expect(DRCI).to have_received(:count_item_parts).with('georin').once
            expect(ordered).to eq([7, 7, 7, 7])
          end

          it "skips the first round's WEALTH only when the copper the wait found, less her 5 gold fee, covers the cost and the spare" do
            asked = []
            allow(DRCM).to receive(:ensure_copper_on_hand) { |amount, *| asked << amount && true }
            survey = ->(copper) { { herb_parts: { 'georin' => 0 }, copper: copper }.compact }
            buy = lambda do |tm|
              allow(tm).to receive(:order_remedy_supply)
              allow(tm).to receive(:brines_to_buy).and_return(0)
              allow(tm).to receive(:missing_remedy_supplies).and_return([])
              tm.buy_remedy_supplies(glop_recipe, 3)
            end

            # Three stacks of georin, 1311 Kronars, and 7500 spare: 13811
            # carried before the fee covers them.
            buy.call(maker(stock_survey: survey.call(13_811)))
            expect(asked).to eq([])
            [13_810, nil].each { |copper| buy.call(maker(stock_survey: survey.call(copper))) }
            expect(asked).to eq([1311 + 7500] * 2)
            # The answer is used once: a later round checks.
            tm = maker(stock_survey: survey.call(1_000_000))
            2.times { buy.call(tm) }
            expect(asked.size).to eq(3)
          end

          it 'takes what the wait found of water and alcohol for the first check, and taps afresh for the next' do
            tm = maker(stock_survey: { water: false, alcohol: true, coal_rubs: 6 })
            taps = []
            allow(DRCI).to receive(:exists?) { |item| taps << item && true }

            expect(tm.missing_remedy_supplies(1).map { |supply| supply[:name] }).to eq(['water'])
            expect(taps).to eq([])
            game('tap my' => coal_tap('massive'))
            expect(tm.missing_remedy_supplies(1)).to eq([])
            expect(taps).to eq(%w[water alcohol])
          end

          # With no wait (a finish, her timer already out), the first round
          # reads them off the INVENTORY taken for the doses on hand, as
          # Gnarta's listed "some water" and "some grain alcohol" (16:16:51).
          it "with no survey, taps only the water or alcohol the bag's INVENTORY does not list, and takes no unsure line for either" do
            taps = []
            allow(DRCI).to receive(:exists?) { |item| taps << item && false }
            supplies = ->(listing) { maker.missing_remedy_supplies(1, listing).map { |supply| supply[:name] } }

            expect([supplies.call(gnarta_bag), taps]).to eq([[], []])
            expect([supplies.call(gnarta_bag - ['some grain alcohol']), taps]).to eq([['alcohol'], ['alcohol']])
            taps.clear
            # "some water lily" holds the word but is a lily, not water.
            expect([supplies.call((gnarta_bag - ['some water']) + ['some water lily']), taps]).to eq([['water'], ['water']])
            taps.clear
            expect([supplies.call(nil), taps]).to eq([%w[coal\ nugget water alcohol], ['water', 'alcohol']])
          end
        end

        describe "the task's tools" do
          # nezhiri with everything but the tool check stubbed; every TAP
          # recorded, each tool found unless missing names it.
          def tooled(recipe, survey: nil, listing: nil, missing: [])
            tm = maker(task_product: recipe[:product], stock_survey: survey, bag_listing: listing)
            allow(tm).to receive(:remedy_doses_on_hand).and_return(0)
            allow(tm).to receive(:check_remedy_uses)
            allow(tm).to receive(:brew_remedy_round).and_return(18)
            allow(tm).to receive(:top_up_remedies)
            allow(tm).to receive(:repair)
            allow(tm).to receive(:put_hands_away)
            allow(tm).to receive(:ensure_tools).and_call_original
            allow(DRC).to receive(:wait_for_script_to_complete) { missing.clear }
            taps = []
            allow(DRCI).to receive(:in_hands?).and_return(false)
            # No repair ticket is carried: a missing tool's TAP for one
            # (collect_missing_by_ticket) finds none, so no ticket is read.
            allow(DRCI).to receive(:exists?) { |item| taps << item && !missing.include?(item) && !item.end_with?(' ticket') }
            tm.nezhiri(recipe[:noun], 13, recipe.merge(uses: 13))
            [tm, taps]
          end

          it 'taps none when the wait found none of them missing, nor when the one missing is the other vessel' do
            [[], ['bowl', 'mixing stick']].each do |missing|
              tm, taps = tooled(glop_recipe, survey: { missing_tools: missing })
              expect(taps).to eq([])
              expect(tm).not_to have_received(:ensure_tools)
            end
          end

          it 'checks them all afresh, and asks the clerk, when the wait found one of them missing' do
            tm, taps = tooled(glop_recipe, survey: { missing_tools: ['sieve'] }, missing: ['sieve'])

            # The missing sieve is looked for among the Rangu tickets carried
            # (one TAP, none carried) before the clerk is asked.
            expect(taps).to eq(['mortar', 'pestle', 'sieve', 'Rangu ticket', 'sieve'])
            expect(DRC).to have_received(:wait_for_script_to_complete).with('clerk-tools', %w[alchemy get])
            expect(tm).to have_received(:ensure_tools).with(%w[mortar pestle sieve], 'alchemy', listed: nil)
          end

          it "with no survey, taps only those the bag's INVENTORY does not list" do
            _, taps = tooled(draught_recipe, listing: gnarta_bag - ['a trapezoidal loimic wire sieve'])
            expect(taps).to eq(['sieve'])

            # A line holding the tool's name only inside another word
            # ("bowl-shaped") is not sorted at all.
            _, taps = tooled(draught_recipe, listing: ['a bowl-shaped charm', 'a grooved agonite mixing stick', 'a trapezoidal loimic wire sieve'])
            expect(taps).to eq(['bowl'])

            # A line holding every word of the tool's name whose noun is
            # another's (sort_listed's unsure: "polish") is not taken for it.
            _, taps = tooled(draught_recipe, listing: ['some bowl polish', 'a grooved agonite mixing stick', 'a trapezoidal loimic wire sieve'])
            expect(taps).to eq(['bowl'])

            _, taps = tooled(draught_recipe)
            expect(taps).to eq(['bowl', 'mixing stick', 'sieve'])
          end

          it "leaves Dorhum's tools to TAP, as before" do
            tm = build(npc: 'dorhum', settings: { enchanting_tools: ['brazier', 'burin'] }, bag_listing: ['a brazier', 'a burin'])
            taps = []
            allow(DRCI).to receive(:in_hands?).and_return(false)
            allow(DRCI).to receive(:exists?) { |item| taps << item && true }

            tm.ensure_tools(%w[brazier burin], 'enchanting')

            expect(taps).to eq(%w[brazier burin])
          end
        end

        describe 'a whole first round read off the INVENTORY taken for the doses on hand' do
          it 'taps neither the listed tools nor the coal, and the next round taps the coal afresh (draught, 6100:8800, 6100:8910)' do
            tm = maker(task_product: 'deep-sea draught')
            game, commons = shop_world(kit, shop: :model)
            game.script('inventory duffel bag', *bag_listed("a khor'vela medicine bowl", 'a purpleheart mixing stick', 'a large coal nugget', 'some water', 'some grain alcohol'))
            game.script('count my first brine', ReplayGame.log('6100:8800'))
            game.script('count my second brine', ReplayGame.log('6100:8793'))
            game.script('count my first junliar', ReplayGame.log('6100:8793'))
            game.script('tap my first coal nugget', ReplayGame.log('6100:8910'))
            allow(tm).to receive(:brew_remedies).and_return(0)
            allow(tm).to receive(:top_up_remedies)
            allow(tm).to receive(:repair)

            tm.nezhiri('draught', 13, draught_recipe.merge(uses: 14))

            expect(game.sent).to eq(['inventory duffel bag', 'count my first brine', 'count my second brine', 'count my first junliar'])
            expect(commons.calls.select { |name, *| name == 'DRCI.exists?' }.map { |call| call[1] }).to eq(['sieve'])
            expect(commons.calls.select { |name, *| name == 'DRCT.order_item' }).to eq([['DRCT.order_item', 8862, 9]] * 3)

            game.script('count my first brine', ReplayGame.log('6100:8800'))
            game.script('count my second brine', ReplayGame.log('6100:8793'))
            game.script('count my first junliar', ReplayGame.log('6100:8793'))
            tm.buy_remedy_supplies(draught_recipe, 1)
            expect(game.sent.last(4)).to eq(['count my first brine', 'count my second brine', 'tap my first coal nugget', 'count my first junliar'])
            # The listing is used once: the next round taps the water and alcohol.
            expect(commons.calls.select { |name, *| name == 'DRCI.exists?' }.map { |call| call[1] }).to eq(%w[sieve water alcohol])
            expect([game.clock, game.diagnostics]).to eq([0.0, []])
          end
        end
      end

      describe 'the hand-in' do
        def handing_in(tm, inventory, owed)
          game, commons = shop_world(inventory)
          allow(tm).to receive(:sort_sack)
          allow(tm).to receive(:task_handed_in)
          game.fallback('dump junk', ReplayGame.log('6100:10286'))
          [game, commons, -> { tm.complete_task(tm.instance_variable_get(:@task_item), owed) }]
        end

        # 6105:1886-1911: 18 doses given for 15; she asks to CUT; MARK at 15,
        # BREAK and the 15 are taken. Here taskmaster believed 18 were owed.
        it 'cuts the stack to the doses she asks for when she says CUT, then hands it in (6105:1886-1911)' do
          tm = maker(task_product: 'deep-sea draught', task_item: 'draught')
          game, commons, hand_in = handing_in(tm, kit + [['deep-sea draught', 'duffel bag', '7401']], 18)
          game.script('inventory duffel bag', *bag_listed('some deep-sea draught'))
          game.script('count #7401', ReplayGame.log('6100:6980')) # 18 doses of deep-sea draught
          game.script('give my draught to nezhiri', ReplayGame.log('6105:1886'))
          game.script('inventory duffel bag', *bag_listed)
          game.script('count #7401', ReplayGame.log('6100:7123'))
          game.script('mark my draught at 15', ReplayGame.log('6105:1892'))
          game.script('break my draught', ReplayGame.log('6105:1896'), after: breaks(commons, 'deep-sea draught', '7401', kept: '7402', rest: '7401', kept_hand: :right))
          game.script('count #7402', ReplayGame.log('6105:1900'))
          game.script('give my draught to nezhiri', ReplayGame.log('6105:1908'), ReplayGame.log('6105:1911'), after: ->(_) { commons.release('#7402') })

          hand_in.call

          expect(game.sent).to eq(['inventory duffel bag', 'count #7401', 'give my draught to nezhiri', 'inventory duffel bag', 'count #7401',
                                   'mark my draught at 15', 'break my draught', 'count #7402', 'give my draught to nezhiri', 'dump junk'])
          expect(commons.inventory.select { |item| item.name == 'deep-sea draught' }.map(&:to_a)).to eq([['deep-sea draught', 'duffel bag', '7401']])
          expect(tm).to have_received(:task_handed_in).with('draught')
          expect([game.clock, game.diagnostics]).to eq([0.0, []])
        end

        # 6101:3610-3626: a 6-dose moisturizer given for 12; she asks to
        # COMBINE; the other 6 are got and combined, SWAP, and the 12 are
        # taken. Here taskmaster believed 6 were owed and cut 12 down to 6
        # (that MARK and BREAK at 6 are in no log). Her refusal (6101:3611)
        # answered a bare GIVE NEZ (6101:3610), which gives the right hand:
        # the moisturizer, as here.
        it 'combines the rest back in when she says COMBINE, then hands in (6101:3610-3626)' do
          tm = maker(task_product: 'scale moisturizer', task_item: 'moisturizer')
          game, commons, hand_in = handing_in(tm, kit + [['scale moisturizer', 'duffel bag', '7501']], 6)
          game.script('inventory duffel bag', *bag_listed('some scale moisturizer'))
          game.script('count #7501', ReplayGame.log('6100:22475')) # 12 doses of scale moisturizer
          game.script('mark my moisturizer at 6', ReplayGame.code('You measure out 6 usable portions from the stack and mark it for cutting.', from: '6100:9688 with 6 portions'))
          game.script('break my moisturizer', ReplayGame.code('You carefully break off 6 pieces from the stack.', from: '6100:9690 with 6 pieces'),
                      after: breaks(commons, 'scale moisturizer', '7501', kept: '7502', rest: '7501', kept_hand: :right))
          game.script('count #7502', ReplayGame.log('6101:3613'))
          game.script('give my moisturizer to nezhiri', ReplayGame.log('6101:3611'))
          game.script('inventory duffel bag', *bag_listed('some scale moisturizer'))
          game.script('combine #7502 with #7501', ReplayGame.log('6101:3619'), after: merges(commons, 'scale moisturizer', '7502', '7501', into: '7503', hand: :left))
          game.script('count #7503', ReplayGame.log('6100:22617'))
          game.script('swap', ReplayGame.log('6101:3621'), after: swaps(commons, 'scale moisturizer', '7503'))
          game.script('give my moisturizer to nezhiri', ReplayGame.log('6101:3623'), ReplayGame.log('6101:3626'), after: ->(_) { commons.release('#7503') })

          hand_in.call

          expect(game.sent).to eq(['inventory duffel bag', 'count #7501', 'mark my moisturizer at 6', 'break my moisturizer', 'count #7502',
                                   'give my moisturizer to nezhiri', 'inventory duffel bag', 'combine #7502 with #7501', 'count #7503',
                                   'swap', 'give my moisturizer to nezhiri', 'dump junk'])
          expect(commons.inventory.map(&:name)).not_to include('scale moisturizer')
          expect(DRC).to have_received(:message).with('Nezhiri wants 12 doses turned in as a single moisturizer; making it that size.')
          expect([game.clock, game.diagnostics]).to eq([0.0, []])
        end

        # 6106:1811: 6 doses given for 12, and nothing more on hand.
        it 'stops at once when she says COMBINE and no more doses are on hand, without giving again (6106:1811)' do
          tm = maker(task_product: 'gill glop', task_item: 'glop')
          game, commons, hand_in = handing_in(tm, kit + [['gill glop', 'duffel bag', '7601']], 6)
          game.script('inventory duffel bag', *bag_listed('some gill glop'))
          game.script('count #7601', ReplayGame.log('6100:9223'))
          game.script('give my glop to nezhiri', ReplayGame.log('6106:1811'))
          game.script('inventory duffel bag', *bag_listed)
          game.script('count #7601', ReplayGame.log('6100:9361')) # 6 doses of gill glop

          expect { hand_in.call }.to raise_error(SystemExit)

          expect(game.sent.count('give my glop to nezhiri')).to eq(1)
          expect(commons.inventory.map(&:to_a)).to include(['gill glop', 'duffel bag', '7601'])
          expect(DRC).to have_received(:message).with('6 of the 12 doses of gill glop owed are on hand: not enough to hand in yet.')
          expect(DRC).to have_received(:message).with('Could not get another glop to hand in and the task is not finished, stopping.')
          expect([game.clock, game.diagnostics]).to eq([0.0, []])
        end

        # 6100:5593 then 6101:5463: she says CUT to a landsickness potion
        # given with GIVE MY POTION TO NEZHIRI, twice.
        it 'stops after a second wrong-amount refusal instead of giving the same stack again and again (6100:5593, 6101:5463)' do
          tm = maker(task_product: 'landsickness potion', task_item: 'potion')
          game, commons, hand_in = handing_in(tm, kit + [['landsickness potion', 'duffel bag', '7701']], 15)
          game.script('inventory duffel bag', *bag_listed('some landsickness potion'))
          game.script('count #7701', ReplayGame.log('6100:6040'))
          game.script('give my potion to nezhiri', ReplayGame.log('6100:5593'))
          game.script('inventory duffel bag', *bag_listed)
          game.script('count #7701', ReplayGame.log('6101:5910')) # 15 doses of landsickness potion
          game.script('give my potion to nezhiri', ReplayGame.log('6101:5463'))

          expect { hand_in.call }.to raise_error(SystemExit)

          expect(game.sent.count('give my potion to nezhiri')).to eq(2)
          expect(commons.inventory.map(&:to_a)).to include(['landsickness potion', 'duffel bag', '7701'])
          expect(DRC).to have_received(:message)
            .with('Nezhiri still says the amount is off: she asked for 15 doses as a single potion, and taskmaster could not hand her that. The potion is back in your duffel bag. Stopping.')
          expect([game.clock, game.diagnostics]).to eq([0.0, []])
        end

        # The same two refusals, met by ;taskmaster nezhiri finish
        # (turn_in_banked) rather than at the end of a run: made ready once
        # more, then a stop. Found by a mutation sweep.
        it 'stops after a second wrong-amount refusal at a finish too (6100:5593, 6101:5463)' do
          tm = maker(task_product: 'landsickness potion', task_item: 'potion')
          game, commons, = handing_in(tm, kit + [['landsickness potion', 'duffel bag', '7701']], 15)
          game.script('inventory duffel bag', *bag_listed('some landsickness potion'))
          game.script('count #7701', ReplayGame.log('6100:6040'))
          game.script('give my potion to nezhiri', ReplayGame.log('6100:5593'))
          game.script('inventory duffel bag', *bag_listed)
          game.script('count #7701', ReplayGame.log('6101:5910')) # 15 doses of landsickness potion
          game.script('give my potion to nezhiri', ReplayGame.log('6101:5463'))

          expect { tm.turn_in_banked('potion', 15) }.to raise_error(SystemExit)

          expect(game.sent.count('give my potion to nezhiri')).to eq(2)
          expect(commons.inventory.map(&:to_a)).to include(['landsickness potion', 'duffel bag', '7701'])
          expect(DRC).to have_received(:message).with('Nezhiri wants 15 doses turned in as a single potion; making it that size.')
          expect(DRC).to have_received(:message)
            .with('Nezhiri still says the amount is off: she asked for 15 doses as a single potion, and taskmaster could not hand her that. The potion is back in your duffel bag. Stopping.')
          expect([game.clock, game.diagnostics]).to eq([0.0, []])
        end

        # Gorkus, 2026-11-18 06:39:41-06:40:19: the stack was cut and held,
        # then go2's dolphin to Andreshlew ran bescort, whose STOW RIGHT put it
        # in the rucksack; on arrival taskmaster said "Could not get another
        # potion" and stopped. The stack is got back by its id instead.
        it 'gets the stack back by its id when the walk to her stowed it (Gorkus 2026-11-18 06:39:46)' do
          tm = maker(task_product: 'landsickness potion', task_item: 'potion')
          game, commons, hand_in = handing_in(tm, kit + [['landsickness potion', 'duffel bag', '7701']], 14)
          game.script('inventory duffel bag', *bag_listed('some landsickness potion'))
          game.script('count #7701', ReplayGame.code('You count out 14 uses remaining.', from: 'Gorkus 2026-11-18 06:39:43'))
          allow(tm).to receive(:find_npc) { commons.put_away_item?('#7701', 'rucksack') } # bescort's STOW RIGHT
          game.script('give my potion to nezhiri', ReplayGame.log('6101:3623'), ReplayGame.log('6101:3626'), after: ->(_) { commons.release('#7701') })

          hand_in.call

          expect(game.sent).to eq(['inventory duffel bag', 'count #7701', 'give my potion to nezhiri', 'dump junk'])
          expect(commons.inventory.map(&:name)).not_to include('landsickness potion')
          expect([game.clock, game.diagnostics]).to eq([0.0, []])
        end

        it 'still stops when the stowed stack cannot be got back' do
          tm = maker(task_product: 'landsickness potion', task_item: 'potion')
          game, commons, hand_in = handing_in(tm, kit + [['landsickness potion', 'duffel bag', '7701']], 14)
          game.script('inventory duffel bag', *bag_listed('some landsickness potion'))
          game.script('count #7701', ReplayGame.code('You count out 14 uses remaining.', from: 'Gorkus 2026-11-18 06:39:43'))
          allow(tm).to receive(:find_npc) { commons.release('#7701') } # gone for good

          expect { hand_in.call }.to raise_error(SystemExit)

          expect(game.sent).not_to include('give my potion to nezhiri')
          expect(DRC).to have_received(:message).with('Could not get another potion to hand in and the task is not finished, stopping.')
        end

        # Gorkus, 2026-11-18 06:39:41-46: the stack was cut in the crafting
        # room and carried on the walk to her, where bescort's STOW RIGHT took
        # it. It now waits in the crafting bag for the walk
        # (set_aside_remedy_hand_in) and is got from there by its id.
        describe 'the stack on the walk to her' do
          let(:potion_count) { ReplayGame.code('You count out 14 uses remaining.', from: 'Gorkus 2026-11-18 06:39:43') }

          def potion_hand_in(tm)
            game, commons, hand_in = handing_in(tm, kit + [['landsickness potion', 'duffel bag', '7701']], 14)
            game.script('inventory duffel bag', *bag_listed('some landsickness potion'))
            game.script('count #7701', potion_count)
            [game, commons, hand_in]
          end

          def taken(game, commons)
            game.script('give my potion to nezhiri', ReplayGame.log('6101:3623'), ReplayGame.log('6101:3626'), after: ->(_) { commons.release('#7701') })
          end

          def stack_calls(commons, name)
            commons.calls.select { |call| call[0] == name && call[1] == '#7701' }
          end

          it 'puts the stack in the crafting bag for the walk, and gets it from there by its id once she is found' do
            tm = maker(task_product: 'landsickness potion', task_item: 'potion')
            game, commons, hand_in = potion_hand_in(tm)
            DRRoom.npcs = []
            walk = nil
            allow(tm).to receive(:find_npc) do
              walk = { held: tm.send(:hand_ids), calls: commons.calls.dup }
              DRRoom.npcs = ['Nezhiri']
            end
            taken(game, commons)

            hand_in.call

            expect(walk[:held]).not_to include('7701')
            expect(walk[:calls]).to include(['DRCI.put_away_item?', '#7701', 'duffel bag'])
            expect(walk[:calls]).not_to include(['DRCI.get_item?', '#7701', 'duffel bag'])
            expect(stack_calls(commons, 'DRCI.get_item?')).to eq([['DRCI.get_item?', '#7701', 'duffel bag']])
            expect(game.sent).to eq(['inventory duffel bag', 'count #7701', 'give my potion to nezhiri', 'dump junk'])
            expect(commons.inventory.map(&:name)).not_to include('landsickness potion')
            expect([game.clock, game.diagnostics]).to eq([0.0, []])
          end

          it 'keeps the stack in hand when she is in the room already' do
            tm = maker(task_product: 'landsickness potion', task_item: 'potion')
            game, commons, hand_in = potion_hand_in(tm)
            held_on_walk = nil
            allow(tm).to receive(:find_npc) { held_on_walk = tm.send(:hand_ids) }
            taken(game, commons)

            hand_in.call

            expect(held_on_walk).to include('7701')
            expect(stack_calls(commons, 'DRCI.put_away_item?')).to eq([])
            expect(stack_calls(commons, 'DRCI.get_item?')).to eq([])
            expect([game.clock, game.diagnostics]).to eq([0.0, []])
          end

          it 'puts it back in the bag again when she wandered off before the give, and gets it back for the next' do
            tm = maker(task_product: 'landsickness potion', task_item: 'potion')
            game, commons, hand_in = potion_hand_in(tm)
            held_on_walks = []
            allow(tm).to receive(:find_npc) do
              held_on_walks << tm.send(:hand_ids)
              DRRoom.npcs = ['Nezhiri']
            end
            game.script('give my potion to nezhiri', ReplayGame.code(missed_give, from: 'taskmaster.lic GIVE_MISSED'), after: ->(_) { DRRoom.npcs = [] })
            taken(game, commons)

            hand_in.call

            expect(held_on_walks.map { |held| held.include?('7701') }).to eq([true, false])
            expect(stack_calls(commons, 'DRCI.put_away_item?')).to eq([['DRCI.put_away_item?', '#7701', 'duffel bag']])
            expect(stack_calls(commons, 'DRCI.get_item?')).to eq([['DRCI.get_item?', '#7701', 'duffel bag']])
            expect(game.sent.count('give my potion to nezhiri')).to eq(2)
            expect(commons.inventory.map(&:name)).not_to include('landsickness potion')
            expect([game.clock, game.diagnostics]).to eq([0.0, []])
          end

          it 'carries the stack as before when it will not go in the bag' do
            tm = maker(task_product: 'landsickness potion', task_item: 'potion')
            game, commons, hand_in = potion_hand_in(tm)
            DRRoom.npcs = []
            allow(DRCI).to receive(:put_away_item?).with('#7701', 'duffel bag').and_return(false)
            held_on_walk = nil
            allow(tm).to receive(:find_npc) do
              held_on_walk = tm.send(:hand_ids)
              DRRoom.npcs = ['Nezhiri']
            end
            taken(game, commons)

            hand_in.call

            expect(held_on_walk).to include('7701')
            expect(stack_calls(commons, 'DRCI.get_item?')).to eq([])
            expect(game.sent).to eq(['inventory duffel bag', 'count #7701', 'give my potion to nezhiri', 'dump junk'])
            expect([game.clock, game.diagnostics]).to eq([0.0, []])
          end

          it 'gets it by its id from wherever it went when it is no longer in the bag' do
            tm = maker(task_product: 'landsickness potion', task_item: 'potion')
            game, commons, hand_in = potion_hand_in(tm)
            DRRoom.npcs = []
            allow(tm).to receive(:find_npc) do
              commons.get_item?('#7701', 'duffel bag') # moved on the walk,
              commons.put_away_item?('#7701', 'rucksack') # to the rucksack
              DRRoom.npcs = ['Nezhiri']
            end
            taken(game, commons)

            hand_in.call

            expect(stack_calls(commons, 'DRCI.get_item?').last).to eq(['DRCI.get_item?', '#7701', nil])
            expect(game.sent).to eq(['inventory duffel bag', 'count #7701', 'give my potion to nezhiri', 'dump junk'])
            expect(commons.inventory.map(&:name)).not_to include('landsickness potion')
            expect([game.clock, game.diagnostics]).to eq([0.0, []])
          end
        end

        # 6106:1800-1839: "ignores your offer", then the same stack is given
        # from the right hand with a bare GIVE and taken.
        it 'gives from the right hand with a bare GIVE when she ignores the offer (6106:1800, 1836-1839)' do
          tm = maker(task_product: 'gill glop', task_item: 'glop')
          game, commons, hand_in = handing_in(tm, kit + [['gill glop', 'duffel bag', '7801']], 12)
          game.script('inventory duffel bag', *bag_listed('some gill glop'))
          game.script('count #7801', ReplayGame.log('6100:9371'))
          game.script('give my glop to nezhiri', ReplayGame.log('6106:1800'))
          game.script('give nezhiri', ReplayGame.log('6106:1836'), ReplayGame.log('6106:1839'), after: ->(_) { commons.release('#7801') })

          hand_in.call

          expect(game.sent).to eq(['inventory duffel bag', 'count #7801', 'give my glop to nezhiri', 'give nezhiri', 'dump junk'])
          expect([game.clock, game.diagnostics]).to eq([0.0, []])
        end

        it 'counts the right hand first after the break, keeps the stack of the doses owed, and puts the other one back' do
          tm = maker
          game, commons = shop_world(kit)
          commons.hold('gill glop', id: '7901')
          game.script('mark my glop at 13', ReplayGame.log('6100:9688'))
          game.script('break my glop', ReplayGame.log('6100:9690'), after: breaks(commons, 'gill glop', '7901', kept: '7903', rest: '7902'))
          game.script('count #7902', ReplayGame.log('6100:28265'))
          game.script('count #7903', ReplayGame.log('6100:9692'))

          expect(tm.trim_remedy('7901', 13, glop_recipe)).to eq('7903')
          expect(game.sent).to eq(['mark my glop at 13', 'break my glop', 'count #7902', 'count #7903'])
          expect([commons.location_of('#7902'), commons.location_of('#7903'), tm.instance_variable_get(:@remedy_stack)]).to eq(['duffel bag', 'left', '7902'])
        end

        it 'stops, both pieces back in the bag, when neither counts the doses owed after the break' do
          tm = maker
          game, commons = shop_world(kit)
          commons.hold('gill glop', id: '7901')
          game.script('mark my glop at 13', ReplayGame.log('6100:9688'))
          game.script('break my glop', ReplayGame.log('6100:9690'), after: breaks(commons, 'gill glop', '7901', kept: '7903', rest: '7902'))
          game.script('count #7902', ReplayGame.log('6100:28265'))
          game.script('count #7903', ReplayGame.log('6100:28616'))

          expect { tm.trim_remedy('7901', 13, glop_recipe) }.to raise_error(SystemExit)
          expect(DRC).to have_received(:message).with('After the break, no gill glop in your hands counts 13 doses. Stopping.')
          expect(commons.inventory.select { |item| item.name == 'gill glop' }.map(&:id)).to contain_exactly('7902', '7903')
        end

        it 'stops when MARK is not answered, the stack back in the bag' do
          tm = maker
          game, commons = shop_world(kit)
          commons.hold('gill glop', id: '7901')

          expect { tm.trim_remedy('7901', 13, glop_recipe) }.to raise_error(SystemExit)
          expect(game.sent).to eq(['mark my glop at 13'])
          expect(DRC).to have_received(:message).with('Could not mark the gill glop (#7901) at 13 doses. Stopping.')
          expect(commons.location_of('#7901')).to eq('duffel bag')
        end

        it 'stops when a count cannot be read, asking twice before calling it unanswered' do
          tm = maker
          game, = shop_world(kit)

          expect { tm.count_remedy('7901', 'gill glop') }.to raise_error(SystemExit)
          expect(game.sent).to eq(['count #7901'] * 2)
          expect(DRC).to have_received(:message).with('Could not count the gill glop (#7901): COUNT went unanswered twice. Stopping.')
        end
      end

      describe 'finishing her task after a stop' do
        it 'hands nothing in with too few doses on hand, and asks for instructions only for the doses still to make' do
          tm = maker(npc: 'nezhiri')
          game, commons = shop_world(kit + [['deep-sea draught', 'duffel bag', '7101']])
          transcript('2026-11-06_6100_leftover_draught').script(game, commands: /\Atask\z/, skip: [11169])
          game.script('inventory duffel bag', *bag_listed('some deep-sea draught'))
          game.script('count #7101', ReplayGame.log('6100:10519'))
          expect(tm).to receive(:ensure_instructions).with('draught', 9)
          expect(tm).to receive(:read_instructions).with('draught', 13).and_return(['draught', 13, draught_recipe])
          %i[refresh_haste top_up_copper].each { |step| allow(tm).to receive(step) }
          expect(tm).to receive(:nezhiri).with('draught', 13, draught_recipe, nil, nil)
          expect(tm).to receive(:complete_task).with('draught', 13)
          allow(tm).to receive(:find_npc)

          expect { tm.resume_task }.to raise_error(SystemExit)

          expect(game.sent).to eq(['task', 'inventory duffel bag', 'count #7101'])
          expect(tm).not_to have_received(:find_npc) # not looked for with nothing to give
          expect(commons.location_of('#7101')).to eq('duffel bag')
        end

        # The same finish with 4 doses a craft remembered for deep-sea
        # draught: the 9 doses still to make are 3 crafts, so the carried set
        # with 2 uses (enough at 6 a craft) is put back and Nezhiri asked
        # for another, rather than taken and found short by nezhiri.
        it 'sizes the instruction uses a finish needs at the remembered doses a craft' do
          [[{ 'deep-sea draught' => 4 }, true], [nil, false]].each do |remembered, asks|
            UserVars.taskmaster_replacements = nil
            UserVars.taskmaster_remedy_yields = remembered
            tm = maker(npc: 'nezhiri')
            game, = shop_world(kit + [['deep-sea draught', 'duffel bag', '7101'], ['deep-sea draught instructions', 'duffel bag']])
            $right_hand = nil
            transcript('2026-11-06_6100_leftover_draught').script(game, commands: /\Atask\z/, skip: [11169])
            game.script('inventory duffel bag', *bag_listed('some deep-sea draught'))
            game.script('count #7101', ReplayGame.log('6100:10519'))
            game.script('read my draught instructions',
                        ReplayGame.code('These instructions appear to be very fragile and will wear out quickly when studied.  They have only 2 uses remaining.',
                                        from: 'INSTRUCTION_USES, in the shape of 6100:1576'))
            game.script('ask nezhiri for instructions',
                        ReplayGame.code('Potion Peddler Nezhiri hands you some deep-sea draught instructions.', from: '6100:2949, for the draught'))
            allow(tm).to receive(:read_instructions).and_return(['draught', 13, draught_recipe])
            %i[refresh_haste top_up_copper nezhiri complete_task find_npc].each { |step| allow(tm).to receive(step) }

            expect { tm.resume_task }.to raise_error(SystemExit)

            expect(game.sent.include?('ask nezhiri for instructions')).to eq(asks)
            expect(UserVars.taskmaster_replacements).to eq(asks ? { 'nezhiri' => 'draught' } : nil)
          end
        end

        # ;taskmaster nezhiri repeat with 6400's task already open (its
        # journal entry, 6400:306, is 6101:24's word for word: 12 doses of
        # scale moisturizer, none returned) and no doses on hand. The open
        # task is finished inside the loop: the two crafts planned make 5
        # each, as in log 6400 (6400:683, 811, 813), one extra craft makes the
        # 15, 5 a craft is remembered, the 15 are cut to 12 and handed in,
        # and the loop then asks Nezhiri for the next task rather than
        # ending the script. The extra craft's COMBINE and COUNT, the cut and
        # the hand-in are past 6400's end: 6100's lines stand in.
        it 'finishes the open task under repeat with an extra craft, remembers the yield, hands in, then asks for the next task (6400:306, 683-813)' do
          asked_again = Class.new(StandardError)
          UserVars.taskmaster_remedy_yields = nil
          tm = maker(npc: 'nezhiri', boosts: [], copper_floor: 0)
          game, commons = shop_world(kit + [['scale moisturizer instructions', 'duffel bag']], shop: :model)
          iterations = 0
          allow(tm).to receive(:prepare_for_task) { iterations += 1 }
          allow(tm).to receive(:repair)
          allow(tm).to receive(:sort_sack)
          game.script('ask nezhiri for task', ReplayGame.code('You are already on a task.', from: "the reply get_task waits for (/You are already on a task/); no Nezhiri log has it"))
          game.script('task', ReplayGame.log('6101:24'))
          # turn_in_banked's hand-in and nezhiri's count find no doses.
          2.times { game.script('inventory duffel bag', *bag_listed('some scale moisturizer instructions')) }
          game.script('read my moisturizer instructions', ReplayGame.log('6100:208')) # ensure_instructions: 13 uses
          game.script('read my moisturizer instructions', *reads['moisturizer'])
          2.times do
            game.script('count my first brine', ReplayGame.log('6100:8800')) # ten parts
            game.script('count my second brine', ReplayGame.log('6100:8793'))
            game.script('tap my first coal nugget', ReplayGame.log('6100:8910')) # large: 4 rubs
            game.script('count my first red flowers', ReplayGame.log('6100:8793'))
          end
          runs = remedy_makes(commons, 'scale moisturizer', %w[7002 7004 7006])
          game.script('count #7002', ReplayGame.log('6400:683'))
          game.script('combine #7002 with #7004', ReplayGame.log('6400:811'), after: merges(commons, 'scale moisturizer', '7002', '7004', into: '7005'))
          game.script('count #7005', ReplayGame.log('6400:813'))
          game.script('combine #7005 with #7006', ReplayGame.log('6100:9368'), after: merges(commons, 'scale moisturizer', '7005', '7006', into: '7007'))
          game.script('count #7007', ReplayGame.log('6100:6040')) # 15 doses
          game.script('inventory duffel bag', *bag_listed('some scale moisturizer instructions', 'some scale moisturizer'))
          game.script('count #7007', ReplayGame.log('6100:6040'))
          game.script('mark my moisturizer at 12', ReplayGame.code('You measure out 12 usable portions from the stack and mark it for cutting.', from: '6100:9688 with 12 portions'))
          game.script('break my moisturizer', ReplayGame.code('You carefully break off 12 pieces from the stack.', from: '6100:9690 with 12 pieces'),
                      after: breaks(commons, 'scale moisturizer', '7007', kept: '7009', rest: '7008', kept_hand: :right))
          game.script('count #7009', ReplayGame.log('6100:22617')) # 12 doses
          game.script('give my moisturizer to nezhiri', ReplayGame.log('6100:3753'), ReplayGame.log('6100:3756'), after: ->(_) { commons.release('#7009') })
          game.fallback('dump junk', ReplayGame.log('6100:10286'))
          # The loop's next ask: what matters is that it is made.
          game.script('ask nezhiri for task', ReplayGame.log('6100:145'), after: ->(_) { raise asked_again })

          expect { tm.run_tasks(OpenStruct.new(repeat: true)) }.to raise_error(asked_again)

          expect(runs.count { |name, _| name == 'remedy' }).to eq(3)
          expect(game.sent).to eq(
            ['ask nezhiri for task', 'task', 'inventory duffel bag', 'read my moisturizer instructions', 'read my moisturizer instructions',
             'inventory duffel bag', 'count my first brine', 'count my second brine', 'tap my first coal nugget', 'count my first red flowers',
             'count #7002', 'combine #7002 with #7004', 'count #7005',
             'count my first brine', 'count my second brine', 'tap my first coal nugget', 'count my first red flowers',
             'combine #7005 with #7006', 'count #7007',
             'inventory duffel bag', 'count #7007', 'mark my moisturizer at 12', 'break my moisturizer', 'count #7009',
             'give my moisturizer to nezhiri', 'dump junk', 'ask nezhiri for task']
          )
          expect(DRC).to have_received(:message).with('0 of the 12 doses of scale moisturizer owed are on hand: not enough to hand in yet.').ordered
          expect(DRC).to have_received(:message).with('12 doses of scale moisturizer owed, 0 on hand: 2 crafts to make.').ordered
          expect(DRC).to have_received(:message).with('10 of 12 doses of scale moisturizer made: 1 more craft to make.').ordered
          expect(DRC).to have_received(:message).with('15 doses of scale moisturizer made and combined into one.').ordered
          expect(DRC).not_to have_received(:message).with(/short of the|Stopping/)
          expect(UserVars.taskmaster_remedy_yields).to eq('scale moisturizer' => 5)
          expect(tm.instance_variable_get(:@task_handed_in)).to be(true)
          expect(tm).to have_received(:repair).once
          expect(tm).to have_received(:sort_sack).once
          # The 3 doses left over wait in the bag for the next task.
          expect([commons.location_of('#7008'), commons.location_of('#7009'), tm.instance_variable_get(:@remedy_stack)]).to eq(['duffel bag', nil, '7008'])
          expect(iterations).to eq(2)
          expect(game.diagnostics).to eq([])
        end

        # ;taskmaster nezhiri repeat: a gill glop task is cut from 18 to 13,
        # the 5 left noted by id; the next task is deep-sea draught, with a
        # 4-dose draught in the bag. The glop's id must not be taken for the
        # draught.
        it "does not take the leftover of another remedy, noted by id at an earlier task's cut, for this task's remedy (6100:9688-9692, 10519)" do
          tm = maker
          game, commons = shop_world(kit + [['deep-sea draught', 'duffel bag', '7101']])
          commons.hold('gill glop', id: '7005')
          game.script('mark my glop at 13', ReplayGame.log('6100:9688'))
          game.script('break my glop', ReplayGame.log('6100:9690'), after: breaks(commons, 'gill glop', '7005', kept: '7007', rest: '7006'))
          game.script('count #7006', ReplayGame.log('6100:28265'))
          game.script('count #7007', ReplayGame.log('6100:9692'))
          expect(tm.trim_remedy('7005', 13, glop_recipe)).to eq('7007')
          commons.release('#7007') # handed in
          expect(tm.instance_variable_get(:@remedy_stack)).to eq('7006')

          game.script('inventory duffel bag', *bag_listed('some deep-sea draught'))
          game.script('count #7101', ReplayGame.log('6100:10519'))

          expect(tm.remedy_doses_on_hand(draught_recipe)).to eq(4)
          expect(game.sent.last(2)).to eq(['inventory duffel bag', 'count #7101'])
          # The glop got by its id goes back; the draught is then got by its
          # whole name, counted and put back.
          expect(commons.calls.select { |name, *| %w[DRCI.get_item? DRCI.put_away_item?].include?(name) }.last(4))
            .to eq([['DRCI.get_item?', '#7006', 'duffel bag'], ['DRCI.put_away_item?', '#7006', 'duffel bag'], ['DRCI.get_item?', 'deep-sea draught', 'duffel bag'],
                    ['DRCI.put_away_item?', '#7101', 'duffel bag']])
          expect([commons.location_of('#7006'), commons.location_of('#7101'), tm.instance_variable_get(:@remedy_stack)]).to eq(['duffel bag', 'duffel bag', '7101'])
        end

        # remedy leaves the vessel in hand, the unfinished remedy in it, when
        # it stops part way; a crash does the same. ;taskmaster nezhiri finish
        # used to put the mortar in the bag and craft afresh. Now it looks in
        # it; a LOOK that goes unanswered (asked twice) stops the run with
        # the mortar left in hand, never put away.
        it "stops on finish with the remedy's vessel in hand when LOOK IN goes unanswered twice, leaving it there, and names the remedy continue line (6100:8641)" do
          tm = maker
          game, commons = shop_world(kit.reject { |name, _| name.include?('mortar') })
          commons.hold('polished belzune stone mortar', id: '6001')
          game.script('task', ReplayGame.log('6100:8641'))
          game.script('inventory duffel bag', *bag_listed)
          allow(tm).to receive(:find_npc)

          expect { tm.resume_task }.to raise_error(SystemExit)

          expect(game.sent).to eq(['task', 'inventory duffel bag', 'look in my mortar', 'look in my mortar'])
          expect(commons.location_of('#6001')).to eq('right')
          expect(commons.moves.grep(/mortar/)).to eq(['polished belzune stone mortar: game -> hand']) # held, never put away
          expect(commons.calls.map(&:first)).not_to include('DRC.wait_for_script_to_complete')
          expect(DRC).to have_received(:message)
            .with('Your polished belzune stone mortar is in your hands, and taskmaster can\'t carry on what is in it (LOOK IN went unanswered twice). If it holds an unfinished glop, finish it with ' \
                  ';remedy continue na "coal nugget" mortar glop; if not, empty it or put it away. Then run ;taskmaster nezhiri finish. Stopping, with the mortar left in hand.')
          expect([game.clock, game.diagnostics.size]).to eq([2 * ReplayGame::BPUT_TIMEOUT, 2])
        end

        it "goes on with the other vessel in hand, which is not the remedy's, putting it away" do
          tm = maker(task_product: 'gill glop')
          game, commons = shop_world(kit.reject { |name, _| name.include?('bowl') })
          commons.hold("khor'vela medicine bowl", id: '6002')
          game.script('inventory duffel bag', *bag_listed)

          expect(tm.remedy_doses_on_hand(glop_recipe)).to eq(0)
          expect(commons.location_of('#6002')).to eq('duffel bag')
        end

        # The healing potion that, with a give by noun, went to her five times
        # (6100:3908 journal). The hand-in looks in the bag first; it used to
        # stop there. Now the healing potion is named and left in the bag,
        # and with no landsickness potion on hand nothing is given.
        it 'gives Nezhiri nothing on finish, and leaves the healing potion in the bag, with no doses on hand (6100:3908)' do
          tm = maker
          game, commons = shop_world(kit + [['small healing potion', 'duffel bag']])
          game.script('task', ReplayGame.log('6100:3908'))
          game.script('inventory duffel bag', *bag_listed('some landsickness potion instructions', 'a small healing potion'))
          expect(tm).to receive(:ensure_instructions).with('potion', 15)
          expect(tm).to receive(:read_instructions).with('potion', 15).and_return(['potion', 15, potion_recipe])
          %i[refresh_haste top_up_copper nezhiri complete_task].each { |step| allow(tm).to receive(step) }
          allow(tm).to receive(:find_npc)

          expect { tm.resume_task }.to raise_error(SystemExit)

          expect(game.sent).to eq(['task', 'inventory duffel bag'])
          expect(commons.location_of('small healing potion')).to eq('duffel bag')
          expect(commons.calls.map(&:first)).not_to include('DRCI.get_item?')
          expect(tm).not_to have_received(:find_npc)
          expect(DRC).to have_received(:message).with(a_string_starting_with('Your duffel bag also holds 1 potion that is not landsickness potion ("a small healing potion").'))
          expect(DRC).to have_received(:message).with('0 of the 15 doses of landsickness potion owed are on hand: not enough to hand in yet.')
        end

        # The same bag with 15 doses of landsickness potion behind the
        # healing potion: the hand-in readies the landsickness potion, got by
        # its whole name, and the healing potion stays in the bag.
        it 'readies the landsickness potion for the hand-in, not the healing potion ahead of it in the bag (6100:3908)' do
          tm = maker(task_product: 'landsickness potion')
          game, commons = shop_world(kit + [['small healing potion', 'duffel bag'], ['landsickness potion', 'duffel bag', '7301']])
          game.script('inventory duffel bag', *bag_listed('some landsickness potion instructions', 'a small healing potion', 'some landsickness potion'))
          game.script('count #7301', ReplayGame.log('6100:6040')) # 15 doses

          expect(tm.remedy_hand_in?('potion', 15)).to be(true)

          expect(game.sent).to eq(['inventory duffel bag', 'count #7301'])
          expect(tm.instance_variable_get(:@remedy_hand_in)).to eq('7301')
          expect([commons.location_of('#7301'), commons.location_of('small healing potion')]).to eq(['right', 'duffel bag'])
          expect(commons.calls.select { |name, *| name == 'DRCI.get_item?' }.map { |call| call[1] }).to eq(['landsickness potion'])
        end

        it 'puts a stack left in hand together with the ones in the bag before counting' do
          tm = maker(task_product: 'deep-sea draught')
          game, commons = shop_world(kit + [['deep-sea draught', 'duffel bag', '7101']])
          commons.hold('deep-sea draught', id: '7102')
          game.script('inventory duffel bag', *bag_listed('some deep-sea draught'))
          game.script('combine #7102 with #7101', ReplayGame.log('6100:10912'), after: merges(commons, 'deep-sea draught', '7101', '7102', into: '7103'))
          game.script('count #7103', ReplayGame.log('6100:10914'))

          expect(tm.remedy_doses_on_hand(draught_recipe)).to eq(10)
          expect(commons.location_of('#7103')).to eq('duffel bag')
          expect(tm.instance_variable_get(:@remedy_stack)).to eq('7103')
        end
      end

      # A remedy run that stops part way, or a crash, leaves the mortar or
      # bowl in hand, whatever got into it still there. taskmaster looks in
      # it (LOOK IN, the form the logs used: "l in mort", 6101:2016; "look
      # in mort", 6105:613; "l in bowl", 6101:5692) and acts on what the
      # game shows, at the start of a run, at a finish, and after a remedy
      # run that left no remedy in hand. remedy is stubbed: each run leaves
      # in hand what the logged runs left (the remedy made, or the vessel
      # with the unfinished remedy in it after a stop).
      # The hands as GameObj gives them, by the game's noun; the names are
      # the full names noun-corpus.tsv logged for each noun.
      describe '#held_vessel and #held_remedy_ids' do
        def holding_objs(right, left = nil)
          empty = OpenStruct.new(name: 'Empty', noun: nil, id: nil)
          allow(GameObj).to receive(:right_hand).and_return(right || empty)
          allow(GameObj).to receive(:left_hand).and_return(left || empty)
        end

        it 'finds a held mortar or bowl by its noun, whatever its name ends in' do
          tm = maker
          [['rustic mortar of unpolished soapstone', 'mortar', glop_recipe],
           ['white granite mortar shaped like an open-top monkey skull', 'mortar', glop_recipe],
           ['ceramic mixing bowl with auburn glazing', 'bowl', draught_recipe]].each do |name, noun, recipe|
            vessel = OpenStruct.new(name: name, noun: noun, id: '6001')
            holding_objs(nil, vessel)
            expect(tm.held_vessel(recipe)).to eq(vessel)
          end
        end

        it 'does not take a pipe with a bowl at the end of its name for the bowl' do
          holding_objs(OpenStruct.new(name: 'felwood pipe with a purple tulip-shaped bowl', noun: 'pipe', id: '6002'))
          expect(maker.held_vessel(draught_recipe)).to be_nil
        end

        it 'takes held stacks of the remedy by their noun and the rest of its name' do
          holding_objs(OpenStruct.new(name: 'gill glop', noun: 'glop', id: '7001'), OpenStruct.new(name: 'gill glop', noun: 'glop', id: '7002'))
          expect(maker.held_remedy_ids('gill glop')).to eq(%w[7001 7002])
          holding_objs(OpenStruct.new(name: 'deep-sea draught', noun: 'draught', id: '7003'))
          expect(maker.held_remedy_ids('deep-sea draught')).to eq(['7003'])
        end

        it 'does not take another remedy of the same noun, or the instructions' do
          holding_objs(OpenStruct.new(name: 'healing potion', noun: 'potion', id: '7004'), OpenStruct.new(name: 'landsickness potion', noun: 'potion', id: '7005'))
          expect(maker.held_remedy_ids('landsickness potion')).to eq(['7005'])
          holding_objs(OpenStruct.new(name: 'gill glop instructions', noun: 'instructions', id: '7006'))
          expect(maker.held_remedy_ids('gill glop')).to eq([])
        end

        it 'takes the remedy\'s noun from NEZHIRI_ITEMS, not from its name' do
          tm = maker
          allow(DRC).to receive(:get_noun).and_return('gill') # a misread NEZHIRI_ITEMS' noun makes moot
          holding_objs(OpenStruct.new(name: 'gill glop', noun: 'glop', id: '7001'))
          expect(tm.held_remedy_ids('gill glop')).to eq(['7001'])
          expect(DRC).not_to have_received(:get_noun)
        end
      end

      describe 'a mortar or bowl left in hand' do
        let(:mortar) { 'polished belzune stone mortar' }
        let(:bowl) { "khor'vela medicine bowl" }
        # The kit with the mortar given an id, so remedy's get of it is seen.
        let(:kit_ids) { kit.map { |entry| entry.first == mortar ? [mortar, 'grass toolstrap', '6001'] : entry } }
        let(:moisturizer) { moisturizer_recipe.merge(uses: 13) }
        let(:continued) { %w[continue na coal\ nugget mortar moisturizer] }
        let(:unfinished) { ReplayGame.log('6101:3436') } # In the stone mortar you see some unfinished scale moisturizer.
        let(:carrying_on) { 'In the stone mortar you see some unfinished scale moisturizer. Carrying it on with ;remedy continue.' }

        # The world without the vessel in its place, the vessel in hand.
        def holding(vessel, id, hand: nil, others: [])
          game, commons = shop_world(kit.reject { |name, _| name == vessel } + others)
          commons.hold(vessel, id: id, hand: hand)
          [game, commons]
        end

        # remedy, stubbed run by run. Each outcome is what that run leaves:
        # an id, that stack of the product in hand, with the vessel put away
        # as remedy's finisher does (6105:942-948); :stopped, the vessel got
        # and left in hand with the unfinished remedy in it (remedy's stop);
        # nil, nothing.
        def remedy_does(commons, product, vessel, outcomes)
          runs = []
          allow(DRC).to receive(:wait_for_script_to_complete) do |name, args|
            commons.wait_for_script_to_complete(name, args)
            next unless name == 'remedy'

            runs << args
            case (outcome = outcomes.shift)
            when :stopped then commons.get_crafting_item(vessel, 'duffel bag', [], belt)
            when String
              commons.stow_crafting_item(vessel, 'duffel bag', belt)
              commons.hold(product, id: outcome)
            end
          end
          runs
        end

        # The brine and coal a continue needs, on hand: ten parts of brine
        # (6100:8800) and a large coal nugget (6100:8910).
        def supplies_on_hand(game)
          game.script('count my first brine', ReplayGame.log('6100:8800'))
          game.script('count my second brine', ReplayGame.log('6100:8793'))
          game.script('tap my first coal nugget', ReplayGame.log('6100:8910'))
        end

        def supply_checks
          ['count my first brine', 'count my second brine', 'tap my first coal nugget']
        end

        describe 'at the start of a run' do
          it 'carries an unfinished remedy in the held mortar on with one continue run where remedies are crafted, and counts the doses it made (6101:3436)' do
            tm = maker(task_product: 'scale moisturizer')
            game, commons = holding(mortar, '6001')
            runs = remedy_does(commons, 'scale moisturizer', 'mortar', %w[7001])
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my mortar', unfinished)
            supplies_on_hand(game)
            game.script('count #7001', ReplayGame.log('6101:3613'))

            expect(tm.remedy_doses_on_hand(moisturizer_recipe)).to eq(6)

            expect(game.sent).to eq(['inventory duffel bag', 'look in my mortar', *supply_checks, 'count #7001'])
            expect(runs).to eq([continued])
            calls = commons.calls.map(&:first)
            expect(commons.calls.index(['DRCT.walk_to', 7896])).to be < calls.index('DRC.wait_for_script_to_complete')
            expect(calls).not_to include('DRCM.ensure_copper_on_hand', 'DRCT.buy_item', 'DRCT.order_item')
            expect(DRC).to have_received(:message).with(carrying_on)
            # Held through the look and the checks; remedy put it away (the
            # one stow, remedy's own), so taskmaster sends none of its own.
            expect(commons.moves.grep(/mortar/)).to eq(["#{mortar}: game -> hand", "#{mortar}: hand -> grass toolstrap"])
            expect(commons.calls.map(&:first).count('DRCC.stow_crafting_item')).to eq(1)
            expect([commons.location_of('#7001'), tm.instance_variable_get(:@remedy_stack)]).to eq(['duffel bag', '7001'])
            expect([game.clock, game.diagnostics]).to eq([0.0, []])
          end

          it 'carries it on from the left hand, putting away what the right hand holds and keeping the mortar (6101:3436)' do
            tm = maker(task_product: 'scale moisturizer')
            game, commons = holding(mortar, '6001', hand: :left, others: [])
            commons.hold('smooth belzune pestle', id: '6003', hand: :right)
            runs = remedy_does(commons, 'scale moisturizer', 'mortar', %w[7001])
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my mortar', unfinished)
            supplies_on_hand(game)
            game.script('count #7001', ReplayGame.log('6101:3613'))

            expect(tm.remedy_doses_on_hand(moisturizer_recipe)).to eq(6)

            expect(runs).to eq([continued])
            expect(commons.calls).to include(['DRCI.put_away_item?', '#6003', 'duffel bag'])
            expect(commons.calls).not_to include(['DRCI.put_away_item?', '#6001', 'duffel bag'])
            expect(commons.moves.grep(/mortar/)).to eq(["#{mortar}: game -> hand", "#{mortar}: hand -> grass toolstrap"])
          end

          it 'buys brine on Andreshlew first when none is left, keeping the mortar in hand, then walks back to craft (6100:8718-8719)' do
            tm = maker(task_product: 'scale moisturizer')
            game, commons = holding(mortar, '6001')
            runs = remedy_does(commons, 'scale moisturizer', 'mortar', %w[7001])
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my mortar', unfinished)
            game.script('count my first brine', ReplayGame.log('6100:8793')) # none
            game.script('tap my first coal nugget', ReplayGame.log('6100:8910'))
            game.script('buy brine', ReplayGame.log('6100:8718'), ReplayGame.log('6100:8719'))
            game.script('count #7001', ReplayGame.log('6101:3613'))

            expect(tm.remedy_doses_on_hand(moisturizer_recipe)).to eq(6)

            expect(game.sent).to eq(['inventory duffel bag', 'look in my mortar', 'count my first brine', 'tap my first coal nugget', 'buy brine', 'count #7001'])
            expect(runs).to eq([continued])
            calls = commons.calls.map(&:first)
            expect(commons.calls).to include(['DRCM.ensure_copper_on_hand', 50 + 7500, 'Crossing'], ['DRCT.buy_item', 51_102, 'brine'])
            expect(calls.index('DRCT.buy_item')).to be < commons.calls.index(['DRCT.walk_to', 7896])
            expect(commons.calls.index(['DRCT.walk_to', 7896])).to be < calls.index('DRC.wait_for_script_to_complete')
            expect(commons.location_of("brewer's brine")).to eq('duffel bag')
            expect(commons.moves.grep(/mortar/)).to eq(["#{mortar}: game -> hand", "#{mortar}: hand -> grass toolstrap"]) # in hand while buying
          end

          it 'keeps the mortar in hand when the bank cannot cover the brine, and stops before running remedy' do
            tm = maker(task_product: 'scale moisturizer')
            game, commons = holding(mortar, '6001')
            runs = remedy_does(commons, 'scale moisturizer', 'mortar', %w[7001])
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my mortar', unfinished)
            game.script('count my first brine', ReplayGame.log('6100:8793'))
            game.script('tap my first coal nugget', ReplayGame.log('6100:8910'))
            allow(DRCM).to receive(:ensure_copper_on_hand).and_return(false)
            allow(DRCI).to receive(:stow_hands)

            expect { tm.remedy_doses_on_hand(moisturizer_recipe) }.to raise_error(SystemExit)

            expect(game.sent).to eq(['inventory duffel bag', 'look in my mortar', 'count my first brine', 'tap my first coal nugget'])
            expect(DRCM).to have_received(:ensure_copper_on_hand).with(50 + 7500, anything, 'Crossing')
            expect(DRC).to have_received(:message)
              .with('Out of money: 7550 Kronars (copper) needed and the Crossing bank could not cover it. Your polished belzune stone mortar is left in your hands ' \
                    'with the unfinished moisturizer in it: once you have the supplies, finish it with ;remedy continue na "coal nugget" mortar moisturizer, ' \
                    'then run ;taskmaster nezhiri finish. Stopping before buying anything more.')
            expect(runs).to be_empty
            expect(commons.location_of('#6001')).to eq('right')
            expect(DRCI).not_to have_received(:stow_hands)
          end

          # Review of #7974 (mrhoribu): a purchase that fails while the vessel
          # is kept in hand must leave it there too, not only afford's stop.
          # Otherwise the unfinished remedy goes in the bag with no continue
          # line, and clear_held_vessel (which looks only at a held vessel)
          # never finds it again.
          describe 'a purchase that fails while carrying an unfinished remedy on' do
            let(:kept_note) do
              'Your polished belzune stone mortar is left in your hands with the unfinished moisturizer in it: once you have the supplies, ' \
                'finish it with ;remedy continue na "coal nugget" mortar moisturizer, then run ;taskmaster nezhiri finish.'
            end

            it 'keeps the mortar in hand and names the continue line when the brine is not bought' do
              tm = maker(task_product: 'scale moisturizer')
              game, commons = holding(mortar, '6001')
              runs = remedy_does(commons, 'scale moisturizer', 'mortar', %w[7001])
              game.script('inventory duffel bag', *bag_listed)
              game.script('look in my mortar', unfinished)
              game.script('count my first brine', ReplayGame.log('6100:8793')) # none
              game.script('tap my first coal nugget', ReplayGame.log('6100:8910'))
              allow(DRCI).to receive(:stow_hands)

              expect { tm.remedy_doses_on_hand(moisturizer_recipe) }.to raise_error(SystemExit)

              expect(commons.calls).to include(['DRCT.buy_item', 51_102, 'brine'])
              expect(runs).to be_empty
              expect(commons.location_of('#6001')).to eq('right')
              expect(DRCI).not_to have_received(:stow_hands)
              expect(DRC).to have_received(:message).with("Could not buy brewer's brine at Andreshlew (room 51102). #{kept_note} Stopping.")
            end

            it 'keeps the mortar in hand and names the continue line when the coal nugget order does not go through' do
              tm = maker(task_product: 'scale moisturizer')
              game, commons = holding(mortar, '6001')
              runs = remedy_does(commons, 'scale moisturizer', 'mortar', %w[7001])
              game.script('inventory duffel bag', *bag_listed)
              game.script('look in my mortar', unfinished)
              game.script('count my first brine', ReplayGame.log('6100:8800'))
              game.script('count my second brine', ReplayGame.log('6100:8793'))
              game.script('tap my first coal nugget', ReplayGame.log('6100:225')) # none carried

              expect { tm.remedy_doses_on_hand(moisturizer_recipe) }.to raise_error(SystemExit)

              expect(commons.calls).to include(['DRCT.order_item', 8775, 2])
              expect(commons.calls).not_to include(['DRCI.put_away_item?', '#6001', 'duffel bag'])
              expect(runs).to be_empty
              expect(commons.location_of('#6001')).to eq('right')
              expect(DRC).to have_received(:message).with(/\ACould not buy coal nugget: the order did not go through .*\. #{Regexp.escape(kept_note)} Stopping\.\z/)
            end

            it 'keeps the mortar in hand, and leaves it out of the stop text, when the bought coal nugget will not go in the bag (6100:4250, 4252)' do
              tm = maker(task_product: 'scale moisturizer')
              game, commons = holding(mortar, '6001')
              runs = remedy_does(commons, 'scale moisturizer', 'mortar', %w[7001])
              game.script('inventory duffel bag', *bag_listed)
              game.script('look in my mortar', unfinished)
              game.script('count my first brine', ReplayGame.log('6100:8800'))
              game.script('count my second brine', ReplayGame.log('6100:8793'))
              game.script('tap my first coal nugget', ReplayGame.log('6100:225')) # none carried
              game.script('order 2', ReplayGame.log('6100:4250'))
              game.script('order 2', ReplayGame.log('6100:4252'))
              allow(DRCI).to receive(:put_away_item?).and_call_original
              allow(DRCI).to receive(:put_away_item?).with('#8105', 'duffel bag').and_return(false) # the bag refuses the new nugget

              expect { tm.remedy_doses_on_hand(moisturizer_recipe) }.to raise_error(SystemExit)

              expect(DRCI).not_to have_received(:put_away_item?).with('#6001', anything)
              expect(runs).to be_empty
              expect(commons.location_of('#6001')).to eq('right')
              expect(DRC).to have_received(:message)
                .with("Could not put the coal nugget you bought (#8105) in your duffel bag. #8105 would not go back in your duffel bag and is still in your hands; put it away before starting again. #{kept_note} Stopping.")
            end
          end

          it 'runs remedy at most once: a continue that again leaves no remedy stops, the mortar left in hand (6101:3436)' do
            tm = maker(task_product: 'scale moisturizer')
            game, commons = holding(mortar, '6001')
            runs = remedy_does(commons, 'scale moisturizer', 'mortar', [nil, '7001'])
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my mortar', unfinished)
            game.fallback('look in my mortar', unfinished)
            supplies_on_hand(game)

            expect { tm.remedy_doses_on_hand(moisturizer_recipe) }.to raise_error(SystemExit)

            expect(runs).to eq([continued])
            expect(game.sent.count('look in my mortar')).to eq(1)
            expect(commons.location_of('#6001')).to eq('right')
            expect(DRC).to have_received(:message)
              .with("remedy's continue run left no scale moisturizer in your hands either; its Remedy: line says why. taskmaster carries an unfinished remedy on only once. " \
                    'Once that is sorted, run ;taskmaster nezhiri finish. Stopping.')
          end

          it 'takes a finished remedy left in the mortar out (never tilting it) and counts it as made (6101:2017, 2020)' do
            tm = maker(task_product: 'scale moisturizer')
            game, commons = holding(mortar, '6001')
            runs = remedy_does(commons, 'scale moisturizer', 'mortar', [])
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my mortar', ReplayGame.log('6101:2017'))
            game.script('get my moisturizer from my mortar', ReplayGame.log('6101:2020'), after: ->(_) { commons.hold('scale moisturizer', id: '7001') })
            game.script('count #7001', ReplayGame.log('6101:3613'))

            expect(tm.remedy_doses_on_hand(moisturizer_recipe)).to eq(6)

            expect(game.sent).to eq(['inventory duffel bag', 'look in my mortar', 'get my moisturizer from my mortar', 'count #7001'])
            expect(game.sent.grep(/tilt/)).to be_empty
            expect(runs).to be_empty
            expect(commons.calls).to include(['DRCC.stow_crafting_item', 'mortar', 'duffel bag', belt])
            expect([commons.location_of('#6001'), commons.location_of('#7001')]).to eq(['grass toolstrap', 'duffel bag'])
            expect([game.clock, game.diagnostics]).to eq([0.0, []])
          end

          # code-derived: no log looks in a bowl holding only the herb. The
          # logged herb-only looks are in a stone mortar (6101:4236, crushed
          # aevaes), so the line is that one with the potion task's bowl. The
          # get's reply is the logged one to "get aeva in my bowl" (6103:355).
          it 'puts the herb back in the crafting bag and the bowl away when crafting never began, then crafts as usual (6103:355)' do
            tm = maker(task_product: 'landsickness potion')
            game, commons = holding(bowl, '6002')
            runs = remedy_does(commons, 'landsickness potion', 'bowl', [])
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my bowl', ReplayGame.code('In the medicine bowl you see some crushed aevaes.', from: "6101:4236 (crushed aevaes in a stone mortar) with the potion task's khor'vela medicine bowl"))
            game.script('get my aevaes from my bowl', ReplayGame.log('6103:355'), after: ->(_) { commons.hold('crushed aevaes', id: '8107') })

            expect(tm.remedy_doses_on_hand(potion_recipe)).to eq(0)

            expect(game.sent).to eq(['inventory duffel bag', 'look in my bowl', 'get my aevaes from my bowl'])
            expect(runs).to be_empty
            expect([commons.location_of('#8107'), commons.location_of('#6002')]).to eq(['duffel bag', 'duffel bag'])
            expect([game.clock, game.diagnostics]).to eq([0.0, []])
          end

          # The same herb, put back in the bag, then counted as a stack
          # carried: three crafts of landsickness potion order two stacks.
          it 'counts the herb taken out of the bowl as a stack carried, ordering one stack fewer (6103:355, 6100:4595)' do
            tm = maker(task_product: 'landsickness potion')
            game, commons = holding(bowl, '6002')
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my bowl', ReplayGame.code('In the medicine bowl you see some crushed aevaes.', from: "6101:4236 (crushed aevaes in a stone mortar) with the potion task's khor'vela medicine bowl"))
            game.script('get my aevaes from my bowl', ReplayGame.log('6103:355'), after: ->(_) { commons.hold('crushed aevaes', id: '8107') })
            supplies_on_hand(game)
            game.script('count my first aevaes', ReplayGame.log('6100:4595')) # 25 pieces
            game.script('count my second aevaes', ReplayGame.log('6100:8793'))
            orders = []
            allow(DRCT).to receive(:order_item) do |room, number|
              orders << [room, number]
              commons.hold('crushed aevaes', id: "81#{orders.size}0")
              nil
            end
            allow(tm).to receive(:brew_remedies)
            allow(tm).to receive(:top_up_remedies)
            allow(tm).to receive(:repair)

            tm.nezhiri('potion', 15, potion_recipe.merge(uses: 16))

            expect(orders).to eq([[8862, 10]] * 2)
            expect(commons.calls).to include(['DRCM.ensure_copper_on_hand', (2 * 537) + 7500, 'Crossing'])
            expect(commons.inventory.select { |item| item.name == 'crushed aevaes' }.map(&:to_a)).to contain_exactly(['crushed aevaes', 'duffel bag', '8107'],
                                                                                                                     ['crushed aevaes', 'duffel bag', '8110'], ['crushed aevaes', 'duffel bag', '8120'])
            expect(commons.location_of('#6002')).to eq('duffel bag')
          end

          # What the wait before the task found was true before the herb went
          # back in the bag: taken as it is, it would buy a stack too many.
          it 'forgets what the wait before the task found once the herb is back in the bag, counting it afresh (6103:355, 6100:4595)' do
            survey = { brine_parts: 30, coal_rubs: 6, herb_parts: { 'aevaes' => 0, 'junliar' => 0, 'georin' => 0, 'red flowers' => 0 }, missing_tools: [],
                       water: true, alcohol: true, copper: 10_000_000 }
            tm = maker(task_product: 'landsickness potion', stock_survey: survey)
            game, commons = holding(bowl, '6002')
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my bowl', ReplayGame.code('In the medicine bowl you see some crushed aevaes.', from: "6101:4236 (crushed aevaes in a stone mortar) with the potion task's khor'vela medicine bowl"))
            game.script('get my aevaes from my bowl', ReplayGame.log('6103:355'), after: ->(_) { commons.hold('crushed aevaes', id: '8107') })
            supplies_on_hand(game)
            game.script('count my first aevaes', ReplayGame.log('6100:4595')) # 25 pieces
            game.script('count my second aevaes', ReplayGame.log('6100:8793'))
            allow(DRCT).to receive(:order_item) { |*| commons.hold('crushed aevaes', id: '8110') && nil }
            allow(tm).to receive(:brew_remedies)
            allow(tm).to receive(:top_up_remedies)
            allow(tm).to receive(:repair)

            tm.nezhiri('potion', 15, potion_recipe.merge(uses: 16))

            expect(game.sent).to eq(['inventory duffel bag', 'look in my bowl', 'get my aevaes from my bowl', *supply_checks, 'count my first aevaes', 'count my second aevaes'])
            expect(DRCT).to have_received(:order_item).twice
            expect(commons.calls.select { |name, *| name == 'DRCI.exists?' }.map { |call| call[1] }).to eq(['bowl', 'mixing stick', 'sieve', 'water', 'alcohol'])
            expect(commons.calls).to include(['DRCM.ensure_copper_on_hand', (2 * 537) + 7500, 'Crossing'])
            expect(tm.instance_variable_get(:@stock_survey)).to be_nil
          end

          it 'checks the supplies afresh for a craft carried on, and for the round after it, whatever the wait before the task found (6101:3436)' do
            tm = maker(task_product: 'scale moisturizer', stock_survey: { brine_parts: 0, coal_rubs: 0, copper: 0 })
            game, commons = holding(mortar, '6001')
            remedy_does(commons, 'scale moisturizer', 'mortar', %w[7001])
            game.script('inventory duffel bag', *bag_listed('a large coal nugget'))
            game.script('look in my mortar', unfinished)
            supplies_on_hand(game)
            game.script('count #7001', ReplayGame.log('6101:3613'))

            expect(tm.remedy_doses_on_hand(moisturizer_recipe)).to eq(6)

            # Taken as found, no brine and no coal would have been bought.
            expect(game.sent).to eq(['inventory duffel bag', 'look in my mortar', *supply_checks, 'count #7001'])
            expect(commons.calls.map(&:first)).not_to include('DRCT.buy_item', 'DRCT.order_item')
            expect([tm.instance_variable_get(:@stock_survey), tm.instance_variable_get(:@bag_listing)]).to eq([nil, nil])
          end

          it 'puts an empty bowl away and goes on (6101:5693)' do
            tm = maker(task_product: 'landsickness potion')
            game, commons = holding(bowl, '6002')
            runs = remedy_does(commons, 'landsickness potion', 'bowl', [])
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my bowl', ReplayGame.log('6101:5693'))

            expect(tm.remedy_doses_on_hand(potion_recipe)).to eq(0)

            expect(game.sent).to eq(['inventory duffel bag', 'look in my bowl'])
            expect(runs).to be_empty
            expect(commons.location_of('#6002')).to eq('duffel bag')
            expect(commons.calls).to include(['DRCC.stow_crafting_item', 'bowl', 'duffel bag', belt])
          end

          # 6101:4236 is crushed aevaes (a potion's herb) in a stone mortar:
          # on a gill glop task it is neither this remedy nor its herb.
          it "stops with the mortar in hand when it holds something that is not this task's (6101:4236 on a gill glop task)" do
            tm = maker(task_product: 'gill glop')
            game, commons = holding(mortar, '6001')
            runs = remedy_does(commons, 'gill glop', 'mortar', [])
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my mortar', ReplayGame.log('6101:4236'))

            expect { tm.remedy_doses_on_hand(glop_recipe) }.to raise_error(SystemExit)

            expect(game.sent).to eq(['inventory duffel bag', 'look in my mortar'])
            expect(runs).to be_empty
            expect(commons.moves.grep(/mortar/)).to eq(["#{mortar}: game -> hand"])
            expect(DRC).to have_received(:message)
              .with("Your #{mortar} is in your hands, and taskmaster can't carry on what is in it (the game said \"In the stone mortar you see some crushed aevaes.\"). " \
                    'If it holds an unfinished glop, finish it with ;remedy continue na "coal nugget" mortar glop; if not, empty it or put it away. Then run ;taskmaster nezhiri finish. Stopping, with the mortar left in hand.')
          end

          # Another remedy's unfinished batch is not carried on as this one:
          # 6101:3436 (unfinished scale moisturizer) on a gill glop task.
          it "does not carry on another remedy's unfinished batch (6101:3436 on a gill glop task)" do
            tm = maker(task_product: 'gill glop')
            game, commons = holding(mortar, '6001')
            runs = remedy_does(commons, 'gill glop', 'mortar', %w[7001])
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my mortar', unfinished)

            expect { tm.remedy_doses_on_hand(glop_recipe) }.to raise_error(SystemExit)

            expect(game.sent).to eq(['inventory duffel bag', 'look in my mortar'])
            expect(runs).to be_empty
            expect(commons.location_of('#6001')).to eq('right')
            expect(DRC).to have_received(:message).with(/can't carry on what is in it \(the game said "In the stone mortar you see some unfinished scale moisturizer\."\)/)
          end

          # A foreign item of the noun used to stop the run before the look,
          # the bowl left in hand. It is named and left in the bag, and the
          # bowl is looked in and dealt with as without it.
          it 'looks in the bowl and puts it away, empty, when the bag also holds a foreign item of the noun (6101:5693)' do
            tm = maker(task_product: 'landsickness potion')
            game, commons = holding(bowl, '6002', others: [['healing potion', 'duffel bag']])
            game.script('inventory duffel bag', *bag_listed('a healing potion'))
            game.script('look in my bowl', ReplayGame.log('6101:5693'))

            expect(tm.remedy_doses_on_hand(potion_recipe)).to eq(0)

            expect(game.sent).to eq(['inventory duffel bag', 'look in my bowl'])
            expect([commons.location_of('#6002'), commons.location_of('healing potion')]).to eq(['duffel bag', 'duffel bag'])
            expect(DRC).to have_received(:message).with(a_string_starting_with('Your duffel bag also holds 1 potion that is not landsickness potion ("a healing potion").'))
          end
        end

        # ;taskmaster nezhiri finish: the hand-in gathers the remedy first
        # (remedy_hand_in?), so the vessel is looked in there. The journal is
        # the logged one for the task (6101:24, 12 doses of scale
        # moisturizer; 6100:3908, 15 doses of landsickness potion); the doses
        # had from the vessel lower the doses the instructions must cover.
        describe 'at a finish' do
          def finishing(tm, journal, item, owed, still_owed)
            tm.instance_variable_set(:@npc, 'nezhiri')
            allow(tm).to receive(:find_npc)
            %i[refresh_haste top_up_copper nezhiri complete_task].each { |step| allow(tm).to receive(step) }
            expect(tm).to receive(:ensure_instructions).with(item, still_owed)
            expect(tm).to receive(:read_instructions).with(item, owed).and_return([item, owed, {}])
            @journal = ReplayGame.log(journal)
          end

          it 'carries an unfinished remedy on, then counts its 6 doses toward the 12 owed (6101:24, 6101:3436)' do
            tm = maker
            game, commons = holding(mortar, '6001')
            runs = remedy_does(commons, 'scale moisturizer', 'mortar', %w[7001])
            finishing(tm, '6101:24', 'moisturizer', 12, 6)
            game.script('task', @journal)
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my mortar', unfinished)
            supplies_on_hand(game)
            game.script('count #7001', ReplayGame.log('6101:3613'))

            expect { tm.resume_task }.to raise_error(SystemExit)

            expect(game.sent).to eq(['task', 'inventory duffel bag', 'look in my mortar', *supply_checks, 'count #7001'])
            expect(runs).to eq([continued])
            expect(commons.location_of('#7001')).to eq('duffel bag')
            expect(DRC).to have_received(:message).with('6 of the 12 doses of scale moisturizer owed are on hand: not enough to hand in yet.')
          end

          it 'takes a finished remedy out of the mortar and counts it (6101:24, 6101:2017, 2020)' do
            tm = maker
            game, commons = holding(mortar, '6001')
            runs = remedy_does(commons, 'scale moisturizer', 'mortar', [])
            finishing(tm, '6101:24', 'moisturizer', 12, 6)
            game.script('task', @journal)
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my mortar', ReplayGame.log('6101:2017'))
            game.script('get my moisturizer from my mortar', ReplayGame.log('6101:2020'), after: ->(_) { commons.hold('scale moisturizer', id: '7001') })
            game.script('count #7001', ReplayGame.log('6101:3613'))

            expect { tm.resume_task }.to raise_error(SystemExit)

            expect(game.sent).to eq(['task', 'inventory duffel bag', 'look in my mortar', 'get my moisturizer from my mortar', 'count #7001'])
            expect(runs).to be_empty
            expect([commons.location_of('#6001'), commons.location_of('#7001')]).to eq(['grass toolstrap', 'duffel bag'])
          end

          it 'puts the herb back and the bowl away, and makes all 15 doses (6100:3908, 6103:355)' do
            tm = maker
            game, commons = holding(bowl, '6002')
            runs = remedy_does(commons, 'landsickness potion', 'bowl', [])
            finishing(tm, '6100:3908', 'potion', 15, 15)
            game.script('task', @journal)
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my bowl', ReplayGame.code('In the medicine bowl you see some crushed aevaes.', from: "6101:4236 (crushed aevaes in a stone mortar) with the potion task's khor'vela medicine bowl"))
            game.script('get my aevaes from my bowl', ReplayGame.log('6103:355'), after: ->(_) { commons.hold('crushed aevaes', id: '8107') })

            expect { tm.resume_task }.to raise_error(SystemExit)

            expect(game.sent).to eq(['task', 'inventory duffel bag', 'look in my bowl', 'get my aevaes from my bowl'])
            expect(runs).to be_empty
            expect([commons.location_of('#8107'), commons.location_of('#6002')]).to eq(['duffel bag', 'duffel bag'])
          end

          it 'puts an empty bowl away and makes all 15 doses (6100:3908, 6101:5693)' do
            tm = maker
            game, commons = holding(bowl, '6002')
            runs = remedy_does(commons, 'landsickness potion', 'bowl', [])
            finishing(tm, '6100:3908', 'potion', 15, 15)
            game.script('task', @journal)
            game.script('inventory duffel bag', *bag_listed)
            game.script('look in my bowl', ReplayGame.log('6101:5693'))

            expect { tm.resume_task }.to raise_error(SystemExit)

            expect(game.sent).to eq(['task', 'inventory duffel bag', 'look in my bowl'])
            expect(runs).to be_empty
            expect(commons.location_of('#6002')).to eq('duffel bag')
          end
        end

        describe 'after a remedy run that left no remedy in hand' do
          # 12 doses of scale moisturizer, none on hand: two crafts. Two
          # 25-piece stacks of red flowers are carried (6100:4595), so none is
          # bought. The first remedy run stops part way, the mortar in hand
          # with the unfinished moisturizer (6101:3436); it is carried on
          # (6 doses, 6101:3613), the second craft makes 6 more, combined
          # into 12 (6101:3619, 6100:22475), and the 12 are handed in
          # (6100:22617, 6100:3753-3756).
          it 'carries the unfinished remedy on once, crafts on to the doses owed and hands them in' do
            tm = maker(task_product: 'scale moisturizer')
            game, commons = shop_world(kit_ids + [['dried red flowers', 'duffel bag'], ['dried red flowers', 'duffel bag']])
            runs = remedy_does(commons, 'scale moisturizer', 'mortar', [:stopped, '7001', '7002'])
            allow(tm).to receive(:repair)
            allow(tm).to receive(:sort_sack)
            allow(tm).to receive(:task_handed_in)
            game.script('inventory duffel bag', *bag_listed)
            2.times { supplies_on_hand(game) }
            game.script('count my first red flowers', ReplayGame.log('6100:4595'))
            game.script('count my second red flowers', ReplayGame.log('6100:4595'))
            game.script('count my third red flowers', ReplayGame.log('6100:8793'))
            game.script('look in my mortar', unfinished)
            game.script('count #7001', ReplayGame.log('6101:3613'))
            game.script('combine #7001 with #7002', ReplayGame.log('6101:3619'), after: merges(commons, 'scale moisturizer', '7001', '7002', into: '7003'))
            game.script('count #7003', ReplayGame.log('6100:22475'))
            game.script('inventory duffel bag', *bag_listed('some scale moisturizer'))
            game.script('count #7003', ReplayGame.log('6100:22617'))
            game.script('give my moisturizer to nezhiri', ReplayGame.log('6100:3753'), ReplayGame.log('6100:3756'), after: ->(_) { commons.release('#7003') })
            game.fallback('dump junk', ReplayGame.log('6100:10286'))

            tm.nezhiri('moisturizer', 12, moisturizer)
            tm.complete_task('moisturizer', 12)

            expect(game.sent).to eq(
              ['inventory duffel bag', *supply_checks, 'count my first red flowers', 'count my second red flowers', 'count my third red flowers',
               'look in my mortar', *supply_checks, 'count #7001', 'combine #7001 with #7002', 'count #7003',
               'inventory duffel bag', 'count #7003', 'give my moisturizer to nezhiri', 'dump junk']
            )
            expect(runs).to eq([['instructions', 'red flower', 'coal nugget', 'mortar', 'moisturizer', '25', 'stocked'], continued,
                                ['instructions', 'red flower', 'coal nugget', 'mortar', 'moisturizer', '25', 'stocked']])
            expect(DRC).to have_received(:message).with(carrying_on)
            expect(DRC).to have_received(:message).with('12 doses of scale moisturizer made and combined into one.')
            expect(tm).to have_received(:task_handed_in).with('moisturizer')
            expect(commons.location_of('#6001')).to eq('grass toolstrap')
            expect([game.clock, game.diagnostics]).to eq([0.0, []])
          end

          # Found by a mutation sweep. The supplies bought before the
          # continue cover it and every craft still to come: here the first
          # of two crafts stopped, so two (a coal nugget with one rub left
          # would run out at the second, and remedy would then buy one at
          # the hometown's shop).
          it 'buys supplies for the continue and every craft still to come (craft 1 of 2: two)' do
            tm = maker(task_product: 'scale moisturizer')
            game, commons = holding(mortar, '6001')
            game.script('look in my mortar', unfinished)
            expect(tm).to receive(:continue_remedy).with(hash_including(product: 'scale moisturizer'), have_attributes(id: '6001'), unfinished.text, 2).and_return('7001')

            expect(tm.remedy_left_in_vessel(moisturizer_recipe, 1, 2)).to eq('7001')

            expect(game.sent).to eq(['look in my mortar'])
            expect(commons.location_of('#6001')).to eq('right')
          end

          # Found by a mutation sweep: remedy puts the vessel away when it
          # finishes, but when it leaves it in hand with the remedy, the
          # continue puts it away.
          it 'puts the vessel away after a continue that left it in hand with the remedy' do
            tm = maker(task_product: 'scale moisturizer')
            _game, commons = holding(mortar, '6001')
            allow(tm).to receive(:buy_remedy_supplies)
            allow(DRC).to receive(:wait_for_script_to_complete) do |name, args|
              commons.wait_for_script_to_complete(name, args)
              commons.hold('scale moisturizer', id: '7001', hand: :left) if name == 'remedy'
            end

            expect(tm.continue_remedy(moisturizer_recipe, GameObj.right_hand, unfinished.text, 1)).to eq('7001')

            expect(commons.calls).to include(['DRCC.stow_crafting_item', 'mortar', 'duffel bag', belt])
            expect(commons.location_of('#6001')).not_to eq('right')
          end

          it 'stops after one continue when that run leaves no remedy either, never running remedy a third time' do
            tm = maker(task_product: 'scale moisturizer')
            game, commons = shop_world(kit_ids + [['dried red flowers', 'duffel bag'], ['dried red flowers', 'duffel bag']])
            runs = remedy_does(commons, 'scale moisturizer', 'mortar', [:stopped, nil, '7002'])
            game.script('inventory duffel bag', *bag_listed)
            2.times { supplies_on_hand(game) }
            game.script('count my first red flowers', ReplayGame.log('6100:4595'))
            game.script('count my second red flowers', ReplayGame.log('6100:4595'))
            game.script('count my third red flowers', ReplayGame.log('6100:8793'))
            game.fallback('look in my mortar', unfinished)

            expect { tm.nezhiri('moisturizer', 12, moisturizer) }.to raise_error(SystemExit)

            expect(runs).to eq([['instructions', 'red flower', 'coal nugget', 'mortar', 'moisturizer', '25', 'stocked'], continued])
            expect(game.sent.count('look in my mortar')).to eq(1)
            expect(commons.location_of('#6001')).to eq('right')
            expect(DRC).to have_received(:message).with(/\Aremedy's continue run left no scale moisturizer in your hands either/)
          end

          # The first run stopped with only the herb in the mortar (crafting
          # never began): running remedy again would meet the same trouble.
          it 'stops, the mortar in hand, when the vessel holds no unfinished remedy (6101:5693)' do
            tm = maker(task_product: 'scale moisturizer')
            game, commons = shop_world(kit_ids + [['dried red flowers', 'duffel bag'], ['dried red flowers', 'duffel bag']])
            runs = remedy_does(commons, 'scale moisturizer', 'mortar', [:stopped])
            game.script('inventory duffel bag', *bag_listed)
            supplies_on_hand(game)
            game.script('count my first red flowers', ReplayGame.log('6100:4595'))
            game.script('count my second red flowers', ReplayGame.log('6100:4595'))
            game.script('count my third red flowers', ReplayGame.log('6100:8793'))
            game.script('look in my mortar', ReplayGame.log('6101:5693'))

            expect { tm.nezhiri('moisturizer', 12, moisturizer) }.to raise_error(SystemExit)

            expect(runs.size).to eq(1)
            expect(commons.location_of('#6001')).to eq('right')
            expect(DRC).to have_received(:message)
              .with("remedy did not leave any scale moisturizer in your hands (craft 1 of 2); its Remedy: line says why. Your #{mortar} is in your hands, and taskmaster can't carry on what is in it " \
                    '(the game said "There is nothing in there."). If it holds an unfinished moisturizer, finish it with ;remedy continue na "coal nugget" mortar moisturizer; ' \
                    'if not, empty it or put it away. Then run ;taskmaster nezhiri finish. Stopping, with the mortar left in hand.')
          end

          it 'takes a finished remedy left in the mortar out as the craft (6101:2017, 2020)' do
            tm = maker(task_product: 'scale moisturizer', remedy_stack: nil, remedy_doses: 0)
            game, commons = shop_world(kit_ids)
            runs = remedy_does(commons, 'scale moisturizer', 'mortar', [:stopped])
            game.script('look in my mortar', ReplayGame.log('6101:2017'))
            game.script('get my moisturizer from my mortar', ReplayGame.log('6101:2020'), after: ->(_) { commons.hold('scale moisturizer', id: '7001') })
            game.script('count #7001', ReplayGame.log('6101:3613'))

            tm.brew_remedies(moisturizer_recipe, 6, 1)

            expect(runs.size).to eq(1)
            expect(game.sent).to eq(['look in my mortar', 'get my moisturizer from my mortar', 'count #7001'])
            expect([commons.location_of('#6001'), commons.location_of('#7001')]).to eq(['grass toolstrap', 'duffel bag'])
          end
        end
      end

      describe 'the game lines it reads' do
        # Each logged LOOK IN reply, read for each task it could be met on.
        it 'reads the logged LOOK IN replies as unfinished, finished, herb, empty, or something else (6101:3436, 2017, 4236, 5693)' do
          tm = maker
          lines = { unfinished: ReplayGame.log('6101:3436'), finished: ReplayGame.log('6101:2017'), aevaes: ReplayGame.log('6101:4236'), empty: ReplayGame.log('6101:5693') }
          read = ->(recipe) { lines.transform_values { |line| tm.vessel_state(recipe, line.text[Regexp.union(TaskMaster::VESSEL_LOOK_REPLIES)].to_s) } }
          expect(read.call(moisturizer_recipe)).to eq(unfinished: :unfinished, finished: :finished, aevaes: :other, empty: :empty)
          expect(read.call(potion_recipe)).to eq(unfinished: :other, finished: :other, aevaes: :herb, empty: :empty)
          expect(read.call(glop_recipe)).to eq(unfinished: :other, finished: :other, aevaes: :other, empty: :empty)
          # No answer, and wordings no log has: two things in it, or the
          # remedy's name only as a part of another's.
          expect(tm.vessel_state(moisturizer_recipe, '')).to eq(:other)
          expect(tm.vessel_state(potion_recipe, ReplayGame.code('In the medicine bowl you see some crushed aevaes and a coal nugget.', from: '6101:4236 with a second thing in it').text)).to eq(:other)
          expect(tm.vessel_state(moisturizer_recipe, ReplayGame.code('In the stone mortar you see some unfinished scale moisturizer jar.', from: '6101:3436 with another noun').text)).to eq(:other)
          expect(ReplayGame.log('6101:2020').text).to match(TaskMaster::VESSEL_GET_REPLIES.first)
          expect(ReplayGame.log('6103:355').text).to match(TaskMaster::VESSEL_GET_REPLIES.first)
        end

        it 'reads the logged COUNT, MARK, BREAK, COMBINE and refusal lines' do
          expect(%w[6100:9223 6100:9371 6100:9539 6100:10519].map { |cite| ReplayGame.log(cite).text[TaskMaster::REMEDY_COUNT, 1] }).to eq(%w[6 12 18 4])
          expect(ReplayGame.log('6100:9688').text).to match(TaskMaster::REMEDY_MARKED)
          expect(ReplayGame.log('6100:9690').text).to match(TaskMaster::REMEDY_BROKEN)
          expect(%w[6101:5463 6101:3611 6105:1886 6106:1811].map { |cite| ReplayGame.log(cite).text[TaskMaster::GIVE_WRONG_AMOUNT, 1] }).to eq(%w[15 12 15 12])
          expect(ReplayGame.log('6106:1800').text).to match(TaskMaster::GIVE_IGNORED)
          replies = Regexp.union(TaskMaster::COMBINE_REPLIES)
          expect(%w[6100:9368 6100:9229 6100:9169].map { |cite| ReplayGame.log(cite).text[replies] })
            .to eq(['You combine', 'You must be holding both', 'Those items cannot be combined'])
          # Nothing else a give gets back reads as a wrong amount.
          expect(ReplayGame.log('6100:10258').text).not_to match(Regexp.union(TaskMaster::GIVE_REPLIES))
          expect(ReplayGame.log('6100:10261').text).to match(/hands you a/)
        end
      end
    end
  end

  describe 'leaving tools for repair (#tool_drop)' do
    # Rangu's answers to the mortar (Hollow Eve 2026, log 6100:9659 and 9661).
    let(:rangu_quote) { "Rangu looks over the mortar and says, \"That will cost 240 Kronars to repair.  Just give it to me again if you want, and I'll have it ready in 1 roisaen.\"" }
    let(:rangu_ticket) { "You hand Rangu 240 Kronars and he gives you back a repair ticket.  Rangu says, \"I should be having that done for you in about 1 roisaen.  Don't lose this ticket!  You must have it to reclaim your mortar.\"" }
    # Catrox's answer to a tool with no wear (Byd, 2026-11-18 23:03:03).
    let(:no_scratch) { "Catrox shrugs and says, \"There isn't a scratch on that, and I'm not one to rob you.\"" }
    let(:sent) { [] }

    def drop(*replies, tools: ['mortar'], reached: true, data: real_repair_replies)
      tm = build(repair_replies: data)
      queue = replies.dup
      allow(DRCT).to receive(:walk_to).and_return(reached)
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRC).to receive(:bput) do |command, *matchers|
        sent << command
        command == 'stow ticket' ? 'You put' : bput_match(queue.shift, matchers)
      end
      tm.tool_drop(tools, 'alchemy belt')
      tm
    end

    it 'confirms a quote with a second give and keeps the ticket' do
      drop(rangu_quote, rangu_ticket)

      expect(sent).to eq(['give Rangu', 'give Rangu', 'stow ticket'])
      expect(DRCC).not_to have_received(:stow_crafting_item)
    end

    it "confirms Fang Cove's wording of the prompt (\"If you agree, give it to me again\")" do
      drop('Osmandikar says, "If you agree, give it to me again."', rangu_ticket)

      expect(sent).to eq(['give Rangu', 'give Rangu', 'stow ticket'])
    end

    it 'confirms a quote pattern from data/custom that matches the cost alone, and still puts a refused tool away' do
      cost_only = real_repair_replies.merge('quote' => 'cost [\d,]+ \w+ to repair', 'offered' => ['cost [\d,]+ \w+ to repair', "There isn't a scratch on that", 'give it to me again'])
      drop('Rangu says, "That will cost 240 Kronars to repair."', rangu_ticket, "Rangu says, \"There isn't a scratch on that, and I'm not one to rob you.\"", tools: %w[mortar pestle], data: cost_only)

      expect(sent).to eq(['give Rangu', 'give Rangu', 'stow ticket', 'give Rangu'])
      expect(DRCC).to have_received(:stow_crafting_item).with('pestle', 'duffel bag', 'alchemy belt').once
    end

    it 'gives each tool its own quote and ticket' do
      drop(rangu_quote, rangu_ticket, rangu_quote, rangu_ticket, tools: %w[mortar pestle])

      expect(sent).to eq(['give Rangu', 'give Rangu', 'stow ticket', 'give Rangu', 'give Rangu', 'stow ticket'])
    end

    it 'puts a tool with no wear away without a second give' do
      drop(no_scratch)

      expect(sent).to eq(['give Rangu'])
      expect(DRCC).to have_received(:stow_crafting_item).with('mortar', 'duffel bag', 'alchemy belt')
    end

    it 'puts the tool away, with no second give, and says so when Rangu is not there to take it' do
      drop(missed_give)

      expect(sent).to eq(['give Rangu'])
      expect(DRC).to have_received(:message).with('Rangu did not take the mortar (What is it); putting it away.')
      expect(DRCC).to have_received(:stow_crafting_item).with('mortar', 'duffel bag', 'alchemy belt')
    end

    # Stand-ins for the repairer's past-repair and no-wear lines (only the
    # quoted words are known: crossing-repair.lic:218), spoken as NPCs speak.
    ['Rangu says, "I can\'t fix those.  They only have so many uses and then you must buy another."', 'Rangu says, "I will not repair something that isn\'t broken."'].each do |reply|
      it "puts the tool away, saying nothing, on #{reply[0, 42]}...\"" do
        drop(reply)

        expect(sent).to eq(['give Rangu'])
        expect(DRC).not_to have_received(:message)
        expect(DRCC).to have_received(:stow_crafting_item).with('mortar', 'duffel bag', 'alchemy belt')
      end
    end

    it 'says so when the repairer does not repair such tools' do
      drop("I don't repair those here.")

      expect(DRC).to have_received(:message).with("Rangu did not take the mortar (I don't repair those here); putting it away.")
      expect(DRCC).to have_received(:stow_crafting_item).with('mortar', 'duffel bag', 'alchemy belt')
    end

    it "gives nothing when the repairer's room can't be reached, and says so" do
      drop(rangu_quote, rangu_ticket, reached: false)

      expect(sent).to be_empty
      expect(DRC).to have_received(:message).with('Could not reach Rangu (room 19209); not leaving mortar for repair this time.')
    end

    it 'has the tool noted before the confirming give, so a run stopped once it goes through leaves a note that leads to the ticket' do
      noted_at_give = nil
      tm = build
      replies = [rangu_quote, rangu_ticket]
      allow(DRCT).to receive(:walk_to).and_return(true)
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRC).to receive(:bput) do |command, *matchers|
        sent << command
        noted_at_give = UserVars.taskmaster_repairs.map { |record| record['tool'] } if sent.count('give Rangu') == 2 && command == 'give Rangu'
        command == 'stow ticket' ? 'You put' : bput_match(replies.shift, matchers)
      end

      tm.tool_drop(['mortar'], 'alchemy belt')

      expect(noted_at_give).to eq(['mortar'])
      expect(UserVars.taskmaster_repairs.map { |record| record['tool'] }).to eq(['mortar'])
    end

    it 'keeps the note on any answer to the confirming give but the ticket (short of coin, or none), for the next whole look to forget' do
      drop(rangu_quote, 'Rangu says, "You will need more coin if I am to be repairing that!"')
      expect(UserVars.taskmaster_repairs.map { |record| record['tool'] }).to eq(['mortar'])

      UserVars.taskmaster_repairs = []
      drop(rangu_quote, '')
      expect(UserVars.taskmaster_repairs.map { |record| record['tool'] }).to eq(['mortar'])
    end

    # lich-5's DRC.bput returns on the first line any pattern matches, so a
    # line from another player in the room can come back as the answer.
    def drop_with_chatter(confirming_lines)
      tm = build
      replies = [[rangu_quote], confirming_lines]
      allow(DRCT).to receive(:walk_to).and_return(true)
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRC).to receive(:bput) do |command, *matchers|
        sent << command
        next 'You put' if command == 'stow ticket'

        found = replies.shift.map { |line| bput_match(line, matchers) }.reject(&:empty?)
        found.first || ''
      end
      tm.tool_drop(['mortar'], 'alchemy belt')
      tm
    end

    it "keeps the note when another player's \"more coin\" comes ahead of the ticket, so the ticket handed over stays tracked" do
      drop_with_chatter(['Kalak says, "Bah, I need more coin for that."', rangu_ticket])

      expect(UserVars.taskmaster_repairs.map { |record| record['tool'] }).to eq(['mortar'])
    end

    it "takes only the game's own \"You hand\" line for the ticket, not another player's words naming one, and puts the tool away" do
      drop_with_chatter(['Kalak asks, "Did you get a repair ticket?"', 'Rangu says, "You will need more coin if I am to be repairing that!"'])

      expect(sent).to eq(['give Rangu', 'give Rangu'])
      expect(DRC).to have_received(:message).with('No repair ticket for the mortar (more coin); putting it away.')
      expect(DRCC).to have_received(:stow_crafting_item).with('mortar', 'duffel bag', 'alchemy belt')
    end

    it 'puts away, by its id, a ticket that shows in hand after the confirming give went unanswered, keeping the note' do
      tm = build
      queue = [rangu_quote, '']
      allow(DRCT).to receive(:walk_to).and_return(true)
      allow(DRCC).to receive(:get_crafting_item) { $right_hand = 'polished belzune stone mortar' }
      allow(DRCC).to receive(:stow_crafting_item) { $right_hand = nil }
      allow(DRCI).to receive(:put_away_item?) do |ref, *_rest|
        sent << [:put_away, ref]
        $left_hand = nil
        true
      end
      allow(DRC).to receive(:bput) do |command, *matchers|
        sent << command
        reply = queue.shift
        # The ticket comes after bput gave up on the confirming give.
        if command == 'give Rangu' && reply == ''
          $left_hand = 'Rangu ticket'
          $hand_ids = { 'Rangu ticket' => '777' }
        end
        bput_match(reply, matchers)
      end

      tm.tool_drop(['mortar'], 'alchemy belt')

      expect(sent).to eq(['give Rangu', 'give Rangu', [:put_away, '#777']])
      expect(UserVars.taskmaster_repairs.map { |record| record['item'] }).to eq(['polished belzune stone mortar'])
      expect($left_hand).to be_nil
    end

    it 'puts away a ticket that shows in hand only after the unanswered confirming give, before the next tool is given, so the next give hands over that tool' do
      tm = build
      queue = [rangu_quote, '', rangu_quote, rangu_ticket]
      given = []
      late = false
      allow(DRCT).to receive(:walk_to).and_return(true)
      # Each tool comes into the free hand, as get_crafting_item takes it.
      allow(DRCC).to receive(:get_crafting_item) { |tool, *| $right_hand.nil? ? ($right_hand = tool) : ($left_hand = tool) }
      allow(DRCC).to receive(:stow_crafting_item) do |tool, *|
        sent << [:stow, tool]
        if late
          # The ticket arrives with the next command after bput gave up.
          $right_hand = 'Rangu ticket'
          $hand_ids = { 'Rangu ticket' => '777' }
          late = false
        end
      end
      allow(DRCI).to receive(:put_away_item?) do |ref, *_rest|
        sent << [:put_away, ref]
        $right_hand = nil if ref == '#777' && $right_hand == 'Rangu ticket'
        true
      end
      allow(DRC).to receive(:bput) do |command, *matchers|
        sent << command
        next 'You put' if command == 'stow ticket'

        reply = queue.shift
        given << $right_hand
        # The confirming give takes the tool; the ticket comes later.
        if command == 'give Rangu' && reply == ''
          $right_hand = nil
          late = true
        end
        bput_match(reply, matchers)
      end

      tm.tool_drop(['bowl', 'mixing stick'], nil)

      expect(sent).to eq(['give Rangu', 'give Rangu', [:stow, 'bowl'], [:put_away, '#777'], 'give Rangu', 'give Rangu', 'stow ticket'])
      expect(given).to eq(['bowl', 'bowl', 'mixing stick', 'mixing stick'])
      expect(UserVars.taskmaster_repairs.map { |record| record['tool'] }).to eq(['bowl', 'mixing stick'])
    end

    it 'puts away a ticket that shows in hand only after the last tool, before the work goes on' do
      tm = build
      queue = [rangu_quote, '']
      allow(DRCT).to receive(:walk_to).and_return(true)
      allow(DRCC).to receive(:get_crafting_item) { $right_hand = 'polished belzune stone mortar' }
      allow(DRCC).to receive(:stow_crafting_item) do
        $right_hand = 'Rangu ticket'
        $hand_ids = { 'Rangu ticket' => '777' }
      end
      allow(DRCI).to receive(:put_away_item?) do |ref, *_rest|
        sent << [:put_away, ref]
        $right_hand = nil
        true
      end
      allow(DRC).to receive(:bput) do |command, *matchers|
        sent << command
        $right_hand = nil if command == 'give Rangu' && queue.size == 1
        bput_match(queue.shift, matchers)
      end

      tm.tool_drop(['mortar'], 'alchemy belt')

      expect(sent).to eq(['give Rangu', 'give Rangu', [:put_away, '#777']])
      expect($right_hand).to be_nil
    end

    it 'marks the note ticketed only when the game hands over the ticket; an unanswered confirming give leaves it unticketed' do
      drop(rangu_quote, rangu_ticket)
      expect(UserVars.taskmaster_repairs.map { |record| record['ticketed'] }).to eq([true])

      UserVars.taskmaster_repairs = []
      drop(rangu_quote, '')
      expect(UserVars.taskmaster_repairs.map { |record| record['ticketed'] }).to eq([false])
    end

    it 'saves the note at once, before the confirming give, so a crash before Lich saves leaves it' do
      vars = double('Vars', save: nil)
      stub_const('Vars', vars)
      tm = build
      replies = [rangu_quote, rangu_ticket]
      allow(DRCT).to receive(:walk_to).and_return(true)
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRC).to receive(:bput) do |command, *matchers|
        sent << command
        command == 'stow ticket' ? 'You put' : bput_match(replies.shift, matchers)
      end
      allow(vars).to receive(:save) { sent << :saved }

      tm.tool_drop(['mortar'], 'alchemy belt')

      # Saved at the note, then on the ticket line twice: the note marked
      # ticketed (confirm_note) and the repaired stamp (note_repaired).
      expect(sent).to eq(['give Rangu', :saved, 'give Rangu', :saved, :saved, 'stow ticket'])
    end

    it 'saves at once when a note is forgotten' do
      stub_const('Vars', double('Vars', save: nil))
      tm = build
      record = { 'npc' => 'nezhiri', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'mortar', 'item' => 'stone mortar', 'left_at' => 1 }
      UserVars.taskmaster_repairs = [record]

      tm.forget_repair(record)

      expect(UserVars.taskmaster_repairs).to eq([])
      expect(Vars).to have_received(:save).once
    end

    it 'gives no second time for an answer that both a custom offered pattern and a declined one match, and puts the tool away' do
      # DRC.bput hands back what the offered pattern matched: here the
      # whole line up to the prompt, scratch and all.
      custom = real_repair_replies.merge('offered' => ['.*give it to me again'])
      drop("Rangu says, \"There isn't a scratch on that, give it to me again some time.\"", data: custom)

      expect(sent).to eq(['give Rangu'])
      expect(UserVars.taskmaster_repairs).to be_nil
      expect(DRCC).to have_received(:stow_crafting_item).with('mortar', 'duffel bag', 'alchemy belt')
    end

    it 'says so and puts the tool away when the second give brings no ticket (short of coin)' do
      drop(rangu_quote, 'Rangu says, "You will need more coin if I am to be repairing that!"')

      expect(sent).to eq(['give Rangu', 'give Rangu'])
      expect(DRC).to have_received(:message).with('No repair ticket for the mortar (more coin); putting it away.')
      expect(DRCC).to have_received(:stow_crafting_item).with('mortar', 'duffel bag', 'alchemy belt')
    end

    it 'takes every reply from the shipped base-crafting.yaml, and says so once, when the data (a stale data/custom copy) has none' do
      ship
      tm = build(repair_replies: nil)
      allow(tm).to receive(:get_data).with('crafting').and_return({ 'stock' => {} })
      queue = [rangu_quote, rangu_ticket]
      allow(DRCT).to receive(:walk_to).and_return(true)
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRC).to receive(:bput) do |command, *matchers|
        sent << command
        # Bounded, so a pickup that reads on and on fails here rather than hanging.
        raise 'looked on and on' if sent.size > 20
        next 'You put' if command == 'stow ticket'

        bput_match(command.start_with?('look at my ') ? 'I could not find what you were referring to.' : queue.shift, matchers)
      end
      allow(DRCI).to receive(:exists?).with('Rangu ticket').and_return(false)

      tm.tool_drop(['mortar'], nil)
      tm.tool_pickup

      expect(sent).to eq(['give Rangu', 'give Rangu', 'stow ticket', 'look at my first Rangu ticket'])
      expect(DRC).to have_received(:message).with("data/custom/base-crafting.yaml has no usable repair_replies quote, prompt, offered, declined, ticket, need_coin, ready, not_ready, ticket_handed, ticket_not_taken (a copy from before they were added?); using the shipped data/base-crafting.yaml's. Update that copy.").once
      expect(YAML).to have_received(:unsafe_load_file).with(shipped_path).once
    end

    # Unstubbed: the real shipped file, and a copy of it with a line that only
    # a permissive load reads (lich-5's get_data reads it so), as the file may
    # later gain. A safe load raises on the Date and hides every reply.
    { 'the shipped file' => '', 'the shipped file with a Date in it' => "added_on: 2026-11-21\n" }.each do |label, extra|
      it "reads every repair reply from #{label}, unstubbed" do
        root = Dir.mktmpdir
        FileUtils.mkdir_p(File.join(root, 'data'))
        File.write(File.join(root, 'data', 'base-crafting.yaml'), File.read(File.expand_path('../data/base-crafting.yaml', __dir__)) + extra)
        stub_const('SCRIPT_DIR', root)
        tm = build(repair_replies: nil)
        allow(tm).to receive(:get_data).with('crafting').and_return({ 'stock' => {} })

        expect(tm.repair_replies).to eq(real_repair_replies)
        expect(tm.repair_replies_known?).to be(true)
      end
    end

    # A hand-edited copy whose repair_replies is a list, a pattern or a
    # number has no usable key: every reply comes from the shipped file,
    # rather than a TypeError (or NoMethodError) at the first lookup.
    [['quote', 'prompt'], 'quote', 5].each do |copy|
      it "takes every reply from the shipped base-crafting.yaml, and says so once, when the data's repair_replies is not a mapping (#{copy.inspect})" do
        ship
        tm = build(repair_replies: copy)

        expect(tm.repair_replies).to eq(real_repair_replies)
        expect(tm.repair_replies_known?).to be(true)
        expect(DRC).to have_received(:message).with("data/custom/base-crafting.yaml has no usable repair_replies quote, prompt, offered, declined, ticket, need_coin, ready, not_ready, ticket_handed, ticket_not_taken (a copy from before they were added?); using the shipped data/base-crafting.yaml's. Update that copy.").once
      end
    end

    it 'takes from the shipped file only the keys the copy lacks, keeping its own' do
      ship
      copy = real_repair_replies.except('prompt', 'ticket_handed', 'ticket_not_taken').merge('quote' => 'cost [\d,]+ \w+ to repair')
      tm = build(repair_replies: copy)

      expect(tm.repair_replies).to eq(copy.merge(real_repair_replies.slice('prompt', 'ticket_handed', 'ticket_not_taken')))
      expect(tm.repair_replies['quote']).to eq('cost [\d,]+ \w+ to repair')
      expect(DRC).to have_received(:message).with(/no usable repair_replies prompt, ticket_handed, ticket_not_taken \(/).once
    end

    it "confirms Fang Cove's prompt through the shipped prompt when the copy lacks it" do
      ship
      drop('Osmandikar says, "If you agree, give it to me again."', rangu_ticket, data: real_repair_replies.except('prompt'))

      expect(sent).to eq(['give Rangu', 'give Rangu', 'stow ticket'])
    end

    it 'takes the shipped value for a key of the wrong kind (declined one string, ticket a list, a broken pattern), rather than crashing' do
      ship
      copy = real_repair_replies.merge('declined' => 'scratch', 'ticket' => ['repair ticket'], 'need_coin' => 'more coin (')

      expect { drop(rangu_quote, rangu_ticket, no_scratch, tools: %w[mortar pestle], data: copy) }.not_to raise_error

      expect(sent).to eq(['give Rangu', 'give Rangu', 'stow ticket', 'give Rangu'])
      expect(DRCC).to have_received(:stow_crafting_item).with('pestle', 'duffel bag', 'alchemy belt').once
      expect(DRC).to have_received(:message).with(/no usable repair_replies declined, ticket, need_coin \(/).once
    end

    it 'takes the shipped value for an empty list or an empty pattern (offered none, ready blank), and still waits on a ticket not ready' do
      # An empty offered would give with no pattern to answer it (bput waits
      # out its 15 s); an empty ready matches every look, so a ticket not
      # ready would be handed in at once.
      ship
      copy = real_repair_replies.merge('offered' => [], 'ready' => '')
      tm = drop(rangu_quote, rangu_ticket, data: copy)

      expect(sent).to eq(['give Rangu', 'give Rangu', 'stow ticket'])
      expect(tm.repair_replies.values_at('offered', 'ready')).to eq(real_repair_replies.values_at('offered', 'ready'))
      expect(DRC).to have_received(:message).with(/no usable repair_replies offered, ready \(/).once

      # The note tool_drop left leads the pickup to Rangu's first ticket:
      # not ready at the first look, ready at the second (after one wait).
      looks = ['Looking at the Rangu ticket you see it is for a mortar.  You recall that your mortar should be ready any moment now.',
               'Looking at the Rangu ticket you see it is for a mortar.  You recall that your mortar should be ready by now.']
      allow(DRCI).to receive(:exists?).with('Rangu ticket').and_return(true)
      # Bounded, so a loop that keeps going fails here rather than hanging.
      pauses = 0
      allow(tm).to receive(:pause) { raise 'paused on and on' if (pauses += 1) > 5 }
      allow(tm).to receive(:redeem_ticket).and_invoke(proc { :unseen }, proc { raise 'redeemed twice' })
      allow(DRC).to receive(:bput) do |command, *matchers|
        line = case command
               when 'look at my first Rangu ticket' then looks.shift || raise('looked again after ready')
               else 'I could not find what you were referring to.'
               end
        bput_match(line, matchers)
      end

      tm.tool_pickup

      expect(tm).to have_received(:redeem_ticket).with('Rangu', 'first', hash_including('tool' => 'mortar')).once
      expect(tm).to have_received(:pause).with(30).once
    end

    # lich-5's get_item? looks only for the noun (ticket) in a hand, so with
    # another shop's ticket held it is true whatever the GET did. The object
    # new in a hand is taken only when it is the repairer's ticket: a tool
    # whose hand update trails in is not offered on GIVE, and the ticket,
    # should it show a moment later, still is.
    context 'the object new in a hand after the GET' do
      let(:catrox_ticket) { OpenStruct.new(id: '7', noun: 'ticket', name: 'Catrox ticket') }
      let(:hammer) { OpenStruct.new(id: '8', noun: 'hammer', name: 'steel hammer') }
      let(:rangu_ticket) { OpenStruct.new(id: '9', noun: 'ticket', name: 'Rangu ticket') }

      def redeem_with(*hands)
        tm = build
        allow(tm).to receive(:pause)
        allow(tm).to receive(:held_objects).and_return(*hands)
        allow(tm).to receive(:put_away_tickets)
        allow(DRCI).to receive(:get_item?).with('first Rangu ticket').and_return(true)
        allow(tm).to receive(:move_to_right_hand).and_return(false)
        allow(DRC).to receive(:bput).and_return('You put')
        [tm, tm.redeem_ticket('Rangu', 'first')]
      end

      it 'is never a tool that shows in a hand while another shop\'s ticket is held' do
        tm, result = redeem_with([catrox_ticket], [catrox_ticket, hammer])

        expect(result).to eq(:not_got)
        expect(tm).not_to have_received(:move_to_right_hand)
        expect(DRC).not_to have_received(:bput).with('give Rangu', any_args)
      end

      it 'is the repairer\'s ticket when it shows after the tool' do
        tm, = redeem_with([catrox_ticket], [catrox_ticket, hammer], [catrox_ticket, hammer, rangu_ticket])

        expect(tm).to have_received(:move_to_right_hand).with('9')
      end
    end

    # A stray '-' line in a belt's items loads as nil, which matched every
    # tool (no words to miss) and then raised in belt_tool, after the
    # repairer had the ticket. Such an entry names nothing.
    it 'stows the tool handed back on the belt that lists it, past a belt with a blank or nil entry' do
      ticket = OpenStruct.new(id: '9', noun: 'ticket', name: 'Rangu ticket')
      bowl = OpenStruct.new(id: '10', noun: 'bowl', name: 'large purpleheart bowl')
      tm = build(settings: { forging_belt: { 'name' => 'forging belt', 'items' => [nil, ' ', 5] }, alchemy_belt: { 'name' => 'alchemy belt', 'items' => ['bowl'] } })
      allow(tm).to receive(:pause)
      allow(tm).to receive(:put_away_tickets)
      allow(tm).to receive(:held_objects).and_return([], [ticket], [ticket], [bowl])
      allow(DRCI).to receive(:get_item?).with('first Rangu ticket').and_return(true)
      allow(tm).to receive(:move_to_right_hand).and_return(true)
      allow(DRC).to receive(:bput).with('give Rangu', any_args).and_return('You hand Rangu your ticket and are handed back a large purpleheart bowl.')
      allow(DRCC).to receive(:stow_crafting_item)

      expect(tm.redeem_ticket('Rangu', 'first')).to eq(bowl)
      expect(DRCC).to have_received(:stow_crafting_item).with('bowl', 'duffel bag', { 'name' => 'alchemy belt', 'items' => ['bowl'] })
    end

    every_key = /none for quote, prompt, offered, .*ticket_not_taken; tools are not left for repair or collected\. Update dr-scripts\./
    [['the shipped file cannot be read', { raises: Errno::ENOENT }, every_key],
     ['the shipped file cannot be parsed', { raises: Psych::SyntaxError.new('base-crafting.yaml', 3, 1, 10, 'did not find expected key', 'while parsing a block mapping') }, every_key],
     ['the shipped file has no repair_replies block', { file: { 'stock' => {} } }, every_key],
     ['the shipped file is not a mapping', { file: [1, 2] }, every_key],
     ['the shipped file has declined as one string too', { file: :declined_string }, /none for declined; tools are not left/]].each do |title, shipped, warning|
      it "says so once and leaves nothing for repair, or collects nothing, when #{title}" do
        if shipped[:raises] then ship(raises: shipped[:raises])
        elsif shipped[:file] == :declined_string then ship(real_repair_replies.merge('declined' => 'scratch'))
        else ship(file: shipped[:file])
        end
        tm = build(repair_replies: nil)
        allow(tm).to receive(:get_data).with('crafting').and_return({ 'stock' => {} })
        allow(DRCT).to receive(:walk_to)
        allow(DRC).to receive(:bput)

        tm.tool_drop(['mortar'], nil)
        tm.tool_pickup

        expect(DRCT).not_to have_received(:walk_to)
        expect(DRC).not_to have_received(:bput)
        expect(DRC).to have_received(:message).with(warning).once
      end
    end

    # A town repairer's no-wear reply and wrong-material refusal, as
    # crossing-repair.lic:218 matches them: each is answered by a data
    # pattern (bput hands it back at once, not '' after its 15 s), and the
    # tool is put away with no second give.
    ["Osmandikar says, \"Lucky for you!  That isn't damaged!\"", 'Osmandikar says, "I don\'t work on those here."'].each do |line|
      it "puts the tool away at once on \"#{line[19, 30]}...\"" do
        returned = []
        tm = build
        allow(DRCT).to receive(:walk_to).and_return(true)
        allow(DRCC).to receive(:get_crafting_item)
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRC).to receive(:bput) do |command, *matchers|
          sent << command
          bput_match(line, matchers).tap { |reply| returned << reply }
        end

        tm.tool_drop(['mortar'], 'alchemy belt')

        expect(sent).to eq(['give Rangu'])
        expect(returned).to eq([line[/(Lucky for you!  That isn't damaged!|I don't work on those here)/]])
        expect(DRCC).to have_received(:stow_crafting_item).with('mortar', 'duffel bag', 'alchemy belt')
      end
    end

    # The hands as the game keeps them: a GET puts the tool in a free hand,
    # the right one first, and GIVE RANGU hands over the right hand. A
    # confirming give marked :late goes through (Rangu takes the tool) but
    # is answered only after bput's 15 s (''), and its ticket shows in the
    # right hand once the next command, the stow, is answered. A ticket
    # given is answered by nothing the first give knows.
    it 'puts away a ticket that comes after an unanswered confirming give, so the next give hands over the next tool, and none is left in hand' do
      tm = build
      $hand_ids = {}
      ids = 0
      hold = lambda do |hand, name|
        hand == :right ? ($right_hand = name) : ($left_hand = name)
        $hand_ids[name] = (ids += 1).to_s if name
      end
      replies = { 'mortar' => [rangu_quote, :late], 'pestle' => [rangu_quote, :late] }
      given = []
      late = false
      allow(DRCT).to receive(:walk_to).and_return(true)
      allow(DRCC).to receive(:get_crafting_item) do |name, *|
        sent << "get #{name}"
        hold.call($right_hand ? :left : :right, name) unless $right_hand && $left_hand
        true
      end
      allow(DRCC).to receive(:stow_crafting_item) do |name, *|
        sent << "stow #{name}"
        hold.call(:right, 'Rangu ticket') if late
        late = false
        hold.call(:left, nil) if $left_hand == name
        hold.call(:right, nil) if $right_hand == name
      end
      allow(DRCI).to receive(:put_away_item?) do |ref|
        sent << "put away #{ref}"
        hold.call(:right, nil) if ref == "##{$hand_ids[$right_hand]}"
        hold.call(:left, nil) if ref == "##{$hand_ids[$left_hand]}"
        true
      end
      allow(DRC).to receive(:bput) do |command, *matchers|
        sent << command
        next '' unless command == 'give Rangu'

        given << $right_hand
        reply = replies.fetch($right_hand, ["Rangu glances at the ticket and says, \"That isn't ready yet.\""]).shift
        if reply == :late
          hold.call(:right, nil)
          late = true
          reply = ''
        end
        bput_match(reply, matchers)
      end

      tm.tool_drop(%w[mortar pestle], 'alchemy belt')

      expect(given).to eq(%w[mortar mortar pestle pestle])
      expect(sent).to eq(['get mortar', 'give Rangu', 'give Rangu', 'stow mortar', 'put away #2',
                          'get pestle', 'give Rangu', 'give Rangu', 'stow pestle', 'put away #4'])
      expect(DRC).to have_received(:message).with('No repair ticket for the mortar (no answer); putting it away.').once
      expect([$right_hand, $left_hand]).to eq([nil, nil])
    end

    # A ticket that will not be put away stays in the right hand: the next
    # tool's GET would land in the left, and the bare GIVE would hand the
    # repairer the ticket. No more tools are left that visit.
    it 'leaves no more tools, and gives nothing more, while a ticket in hand will not be put away' do
      tm = build
      $hand_ids = {}
      ids = 0
      hold = lambda do |hand, name|
        hand == :right ? ($right_hand = name) : ($left_hand = name)
        $hand_ids[name] = (ids += 1).to_s if name
      end
      replies = { 'mortar' => [rangu_quote, rangu_ticket] }
      given = []
      allow(DRCT).to receive(:walk_to).and_return(true)
      allow(DRCC).to receive(:get_crafting_item) do |name, *|
        sent << "get #{name}"
        hold.call($right_hand ? :left : :right, name) unless $right_hand && $left_hand
        true
      end
      allow(DRCC).to receive(:stow_crafting_item) { |name, *| sent << "stow #{name}" }
      allow(DRCI).to receive(:put_away_item?) do |ref|
        sent << "put away #{ref}"
        false
      end
      allow(DRC).to receive(:bput) do |command, *matchers|
        sent << command
        next '' if command == 'stow ticket'
        next '' unless command == 'give Rangu'

        given << $right_hand
        reply = replies.fetch($right_hand, ["Rangu glances at the ticket and says, \"That isn't ready yet.\""]).shift
        hold.call(:right, 'Rangu ticket') if reply == rangu_ticket
        bput_match(reply, matchers)
      end

      tm.tool_drop(%w[mortar pestle], 'alchemy belt')

      expect(given).to eq(%w[mortar mortar])
      expect(sent).not_to include('get pestle')
      expect(DRC).to have_received(:message).with('A Rangu ticket is still in your hands (it would not be put away); not leaving pestle for repair this time, so the next give does not hand it over.').once
    end

    # Only Rangu's own tickets are put away, by id: a held item of his name
    # that is no ticket, another repairer's ticket, and an item with no id
    # stay in hand.
    [[{ right: "Rangu's ledger", left: 'clerk ticket' }, []],
     [{ right: 'Rangu ticket', left: 'steel tongs' }, ['#1']],
     [{ right: 'steel tongs', left: 'Rangu ticket' }, ['#2']]].each do |hands, put|
      it "puts away only a Rangu ticket held (#{hands.values.join(', ')})" do
        tm = build
        $right_hand, $left_hand = hands.values_at(:right, :left)
        $hand_ids = { $right_hand => '1', $left_hand => '2' }
        allow(DRCI).to receive(:put_away_item?).and_return(true)

        expect(tm.put_away_tickets('Rangu')).to be(true)

        put.each { |ref| expect(DRCI).to have_received(:put_away_item?).with(ref).once }
        expect(DRCI).to have_received(:put_away_item?).exactly(put.size).times
      end
    end

    it 'puts away no Rangu ticket GameObj shows without an id, and says so of one that will not go' do
      tm = build
      $right_hand = 'Rangu ticket'
      $left_hand = 'Rangu ticket'
      $hand_ids = {}
      $hand_item_ids = { right: ['Rangu ticket', nil], left: ['Rangu ticket', '7'] }
      allow(DRCI).to receive(:put_away_item?).and_return(false)

      expect(tm.put_away_tickets('Rangu')).to be(false)

      expect(DRCI).to have_received(:put_away_item?).with('#7').once
      expect(DRCI).to have_received(:put_away_item?).once
      expect(DRC).to have_received(:message).with('Could not put away the Rangu ticket in hand; a pickup may not get its tickets.').once
    end

    it 'puts the tool away when the first give gets no answer, and says so' do
      drop('')

      expect(sent).to eq(['give Rangu'])
      expect(DRC).to have_received(:message).with('Rangu did not take the mortar (no answer); putting it away.')
      expect(DRCC).to have_received(:stow_crafting_item).with('mortar', 'duffel bag', 'alchemy belt')
    end

    # The pickup after the accept waits only for the tools the work uses, so
    # a worker that repairs more (Zasele's cloth tasks all of
    # outfitting_tools, Dorhum's the brazier) may find one still out.
    describe 'a tool still noted at a repairer (#repair)' do
      def repair_run(npc:, tools:, notes:, settings: {})
        UserVars.taskmaster_repairs = notes
        tm = build(npc: npc, settings: settings)
        allow(tm).to receive(:get_data).and_return('Crossing' => { 'metal_repair' => { 'id' => 19_093, 'name' => 'Catrox' } })
        allow(DRCT).to receive(:walk_to) { |room| sent << [:walk, room] }
        allow(DRCC).to receive(:get_crafting_item) { |tool, *| sent << [:get, tool] }
        allow(DRCC).to receive(:stow_crafting_item)
        replies = Array.new(tools.size) { no_scratch }
        allow(DRC).to receive(:bput) do |command, *matchers|
          sent << command
          # Catrox's line, said by whoever was given the tool.
          bput_match(replies.shift&.sub('Catrox', command.delete_prefix('give ')), matchers)
        end
        tm.repair(tools, nil)
        tm
      end

      it "sends a Zasele cloth task's tools but the knitting needles still at Rangu, and says so" do
        needles_out = { 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'knitting needle', 'item' => 'slender knitting needles', 'left_at' => 1 }
        repair_run(npc: 'zasele', tools: ['scissors', 'knitting needle'], notes: [needles_out])

        expect(sent).to eq([[:walk, 19_209], [:get, 'scissors'], 'give Rangu'])
        expect(DRC).to have_received(:message).with('knitting needle still at repair (left earlier); not sent again. A later task or ;taskmaster pickup collects it.')
        expect(UserVars.taskmaster_repairs).to eq([needles_out])
      end

      it "sends the stirring rod forging_tools names \"rod\" while a Dorhum task's imbuement rod is noted, as its own note's only" do
        imbuement_rod = { 'npc' => 'dorhum', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'imbuement rod', 'item' => 'cambrinth imbuement rod', 'left_at' => 1 }
        repair_run(npc: 'poltu', tools: %w[hammer rod], notes: [imbuement_rod], settings: { forging_tools: %w[hammer rod] })

        expect(sent).to eq([[:walk, 19_209], [:get, 'hammer'], 'give Rangu', [:get, 'rod'], 'give Rangu'])
        expect(DRC).not_to have_received(:message).with(/still at repair/)
      end

      it "sends none of a Dorhum task's tools still at Catrox (the brazier, which a public brazier room's task never uses), and goes nowhere when none is left to send" do
        brazier = { 'npc' => 'dorhum', 'repairer' => 'Catrox', 'room' => 19_093, 'tool' => 'brazier', 'item' => 'iron brazier', 'left_at' => 1 }
        repair_run(npc: 'dorhum', tools: ['augment loop', 'brazier', 'burin'], notes: [brazier], settings: { task_repair_by: 'town' })

        expect(sent).to eq([[:walk, 19_093], [:get, 'augment loop'], 'give Catrox', [:get, 'burin'], 'give Catrox'])

        sent.clear
        repair_run(npc: 'dorhum', tools: ['brazier'], notes: [brazier], settings: { task_repair_by: 'town' })
        expect(sent).to be_empty
      end

      # Only the due tools (task_repair_every) are looked at for this.
      it 'neither sends nor names a tool still at Rangu that is not due' do
        needles_out = { 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'knitting needle', 'item' => 'slender knitting needles', 'left_at' => 1 }
        UserVars.taskmaster_repaired_at = { 'knitting needle' => Time.now.to_i - 60 }
        repair_run(npc: 'zasele', tools: ['scissors', 'knitting needle'], notes: [needles_out], settings: { task_repair_every: { 'zasele' => 3600 } })

        expect(sent).to eq([[:walk, 19_209], [:get, 'scissors'], 'give Rangu'])
        expect(DRC).not_to have_received(:message).with(/still at repair/)
      end

      it "names a due tool still at Rangu and leaves its clock as it is (tool_drop never sees it)" do
        needles_out = { 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'knitting needle', 'item' => 'slender knitting needles', 'left_at' => 1 }
        stamped = Time.now.to_i - 7200
        UserVars.taskmaster_repaired_at = { 'knitting needle' => stamped }
        repair_run(npc: 'zasele', tools: ['scissors', 'knitting needle'], notes: [needles_out], settings: { task_repair_every: { 'zasele' => 3600 } })

        expect(sent).to eq([[:walk, 19_209], [:get, 'scissors'], 'give Rangu'])
        expect(DRC).to have_received(:message).with('knitting needle still at repair (left earlier); not sent again. A later task or ;taskmaster pickup collects it.')
        expect(UserVars.taskmaster_repaired_at['knitting needle']).to eq(stamped)
        # The scissors, sent and found unworn, are stamped: the clock works here.
        expect(UserVars.taskmaster_repaired_at['scissors']).to be_within(5).of(Time.now.to_i)
      end
    end
  end

  describe 'where tools go for repair (task_repair_by)' do
    let(:town_data) { YAML.load_file(File.expand_path('../data/base-town.yaml', __dir__), aliases: true) }
    let(:crafting_data) { YAML.load_file(File.expand_path('../data/base-crafting.yaml', __dir__), aliases: true) }

    def repairer(npc: 'nezhiri', task_hometown: nil, **settings)
      tm = build(settings: { hometown: 'Shard' }.merge(settings), npc: npc, task_hometown: task_hometown)
      allow(tm).to receive(:get_data) { |type| type == 'town' ? town_data : crafting_data }
      allow(DRC).to receive(:get_town_name) { |name| { 'crossing' => 'Crossing', 'riverhaven' => 'Riverhaven', 'shard' => 'Shard', 'fang cove' => 'Fang Cove' }[name.downcase] }
      tm
    end

    it 'is Rangu by default, unset or empty' do
      [nil, '', 'rangu', ' Rangu '].each do |mode|
        expect(repairer(task_repair_by: mode).repairer_for).to eq('id' => 19_209, 'name' => 'Rangu'), mode.inspect
      end
    end

    it "is Crossing's repairer from base-town.yaml with town, whatever the task and whatever task_hometown says: tasks are crafted there" do
      [nil, 'Riverhaven', 'Shard', 'Fang Cove', 'Nowhere'].each do |home|
        %w[nezhiri zasele bradyn].each do |npc|
          expect(repairer(npc: npc, task_repair_by: 'town', task_hometown: home).repairer_for).to eq('id' => 19_093, 'name' => 'Catrox'), "#{npc} #{home.inspect}"
        end
      end
      expect(DRC).not_to have_received(:get_town_name)
    end

    it "takes hometown, town's earlier name, as town, and says nothing of it" do
      %w[hometown Hometown].each do |name|
        expect(repairer(npc: 'zasele', task_repair_by: name, task_hometown: 'Shard').repairer_for).to eq('id' => 19_093, 'name' => 'Catrox')
      end
      expect(DRC).not_to have_received(:message).with(/task_repair_by/)
    end

    it "is Crossing's discipline repairer with task_type whatever task_hometown says, for Nezhiri as for the rest" do
      %w[Riverhaven Shard].each do |home|
        expect(repairer(npc: 'zasele', task_repair_by: 'task_type', task_hometown: home).repairer_for)
          .to eq('id' => 16_659, 'name' => crafting_data['tailoring']['Crossing']['repair-npc'])
        expect(repairer(task_repair_by: 'task_type', task_hometown: home).repairer_for).to eq('id' => 8860, 'name' => crafting_data['remedies']['Crossing']['repair-npc'])
      end
    end

    it "takes Crossing's leather_repair with town when the town data has no metal_repair" do
      tm = repairer(npc: 'zasele', task_repair_by: 'town')
      allow(tm).to receive(:get_data).and_return({ 'Crossing' => { 'leather_repair' => { 'id' => 1234, 'name' => 'Tanner' } } })

      expect(tm.repairer_for).to eq('id' => 1234, 'name' => 'Tanner')
    end

    it "is the task's discipline repairer from base-crafting.yaml with task_type" do
      expectations = { 'nezhiri' => ['remedies', 8860], 'zasele' => ['tailoring', 16_659], 'poltu' => ['blacksmithing', 8776],
                       'bradyn' => ['shaping', 19_209], 'dorhum' => ['artificing', 19_209] }
      expectations.each do |npc, (discipline, room)|
        info = crafting_data[discipline]['Crossing']
        expect(info['repair-room']).to eq(room)
        expect(repairer(npc: npc, task_repair_by: 'task_type').repairer_for).to eq('id' => room, 'name' => info['repair-npc']), npc
      end
    end

    it 'says so once and uses Rangu when the setting names no known way' do
      tm = repairer(task_repair_by: 'catrox')
      2.times { expect(tm.repairer_for).to eq('id' => 19_209, 'name' => 'Rangu') }
      expect(DRC).to have_received(:message).with("task_repair_by 'catrox' is not one of rangu, town, task_type; using Rangu.").once
    end

    it "says so and uses Rangu when Crossing has no such repairer in the data" do
      tm = repairer(npc: 'zasele', task_repair_by: 'task_type', task_hometown: 'Riverhaven')
      allow(tm).to receive(:get_data).and_return({ 'tailoring' => { 'Riverhaven' => { 'repair-room' => 1, 'repair-npc' => 'clerk' } } })
      expect(tm.repairer_for).to eq('id' => 19_209, 'name' => 'Rangu')
      expect(DRC).to have_received(:message).with('No tailoring repairer for Crossing in the data (task_repair_by task_type); using Rangu.')
      tm = repairer(npc: 'zasele', task_repair_by: 'town')
      allow(tm).to receive(:get_data).and_return({ 'Crossing' => {} })
      expect(tm.repairer_for).to eq('id' => 19_209, 'name' => 'Rangu')
      expect(DRC).to have_received(:message).with('No repairer for Crossing in the data (task_repair_by town); using Rangu.')
    end

    it "leaves a tool with Crossing's repairer (town) on a bare prompt with no cost on the line (Fang Cove's wording), and notes it there" do
      tm = repairer(npc: 'zasele', task_repair_by: 'town', task_hometown: 'Fang Cove')
      catrox = town_data['Crossing']['metal_repair']
      sent = []
      replies = ["#{catrox['name']} says, \"If you agree, give it to me again.\"", "You hand #{catrox['name']} 240 Kronars and he gives you back a repair ticket."]
      allow(DRCT).to receive(:walk_to) { |room| sent << [:walk, room] }
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRC).to receive(:bput) do |command, *matchers|
        sent << command
        command == 'stow ticket' ? 'You put' : bput_match(replies.shift, matchers)
      end

      tm.tool_drop(['scissors'], nil)

      expect(sent).to eq([[:walk, catrox['id']], "give #{catrox['name']}", "give #{catrox['name']}", 'stow ticket'])
      expect(UserVars.taskmaster_repairs.map { |record| record.values_at('repairer', 'room', 'tool') }).to eq([[catrox['name'], catrox['id'], 'scissors']])
    end

    it 'keeps one repairer per taskmaster' do
      tm = repairer(task_repair_by: 'task_type')
      expect(tm.repairer_for('nezhiri')['id']).to eq(8860)
      expect(tm.repairer_for('zasele')['id']).to eq(16_659)
    end
  end

  describe 'tickets for the tools left for repair' do
    # LOOK AT a ticket, as the game words it for a stowed ticket: ready
    # (Mithandres's Granzer ticket, 2026-01-03 00:55:40), and not yet
    # (Cithrin's Catrox ticket, 2026-11-20 07:59:19).
    def ticket_look(name, item, ready: true)
      "Looking at the #{name} ticket you see it is for a #{item}.  You recall that your #{item.split.last} should be ready #{ready ? 'by now' : 'any moment now'}."
    end

    # Notes as tool_drop writes them: 'item' is the tool's hand tag, which
    # leaves out the words after the noun (lich-5 common-items.rb, the
    # carried-name matching), while its ticket names the whole item.
    let(:bowl) { { 'npc' => 'nezhiri', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'bowl', 'item' => 'large purpleheart bowl', 'left_at' => 1 } }
    let(:bowl_ticket) { 'large purpleheart bowl edged with ivory' }
    let(:stick) { { 'npc' => 'nezhiri', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'mixing stick', 'item' => 'grooved agonite mixing stick', 'left_at' => 1 } }
    let(:needles) { { 'npc' => 'zasele', 'repairer' => 'clerk', 'room' => 16_659, 'tool' => 'knitting needles', 'item' => 'knitting needles', 'left_at' => 1 } }
    let(:mortar) { { 'npc' => 'nezhiri', 'repairer' => 'Catrox', 'room' => 19_093, 'tool' => 'mortar', 'item' => 'polished belzune stone mortar', 'left_at' => 1 } }
    let(:alchemy_belt) { { 'name' => 'alchemy belt', 'items' => ['bowl', 'mixing stick'] } }
    let(:sent) { [] }

    def looks
      sent.count { |step| step.is_a?(String) && step.start_with?('look at my ') }
    end

    def gives
      sent.count { |step| step.is_a?(String) && step.start_with?('give ') }
    end

    # tickets: per repairer name, the items its tickets are for, in order,
    # each [item, ready]; a redeemed ticket leaves the list. ready_after: how
    # many 30 s pauses before every ticket is ready. unanswered: looks
    # ("second Rangu") that get no reply. refused: a reply to the give that
    # is not a hand-over. refuse_first: how many gives are answered "What is
    # it you're trying to give?". unreached: rooms walk_to can't reach.
    # hands_back: the name of the tool a give hands back, or one per give,
    # in order; else the ticket's item as a hand tag shows it (the words
    # after the noun left out). A ticket got lands in a free hand as
    # "<name> ticket" (noun ticket) with an id of its own. lich-5's
    # get_item? checks only the noun (ticket) in a hand after the GET: with
    # one of the repairer's tickets already in hand it is true and nothing
    # new comes ("You are already holding that."), and with no hand free, or
    # no such ticket, it is true when any ticket is in a hand, else false.
    # on_pause and on_get: called with the count of 30 s pauses, or of gets,
    # so far, before the world answers (to move tickets meanwhile).
    # restow: where 'stow ticket' puts a ticket the repairer did not take
    # back among the tickets: :front, :back, or (nil) its own place.
    # missing_reply: the reply to a look past the last ticket. silent_looks:
    # which looks, counted from 1 over the whole pickup, get no reply ('',
    # as DRC.bput gives after 15 s). silent_gives: which ticket gives,
    # counted from 1, hand the tool back with their reply too late for
    # DRC.bput (''). chatter: called with each command; a line it gives
    # (another player's speech) comes ahead of the game's reply, and as
    # lich-5's bput returns on the first line any pattern matches, it may be
    # the answer. Every pause
    # and every step a stub records (command, walk, TAP, get, put-away,
    # stow) counts, and the world raises once a pickup spins (over 500
    # pauses, or 300 steps), so a loop guard undone fails at once rather
    # than hanging.
    def pickup_world(tickets, ready_after: 0, unanswered: [], refused: nil, refuse_first: 0, unreached: [], lands_in: :right, hands_back: nil, settings: {}, on_pause: nil, on_get: nil,
                     restow: nil, missing_reply: 'I could not find what you were referring to.', silent_looks: [], silent_gives: [], chatter: nil, **ivars)
      tm = build(npc: 'nezhiri', settings: { alchemy_belt: alchemy_belt }.merge(settings), **ivars)
      pauses = 0
      spins = 0
      held = nil
      given = 0
      not_taken = nil
      looked = 0
      step = lambda do |entry|
        sent << entry
        raise 'pickup spun: over 300 steps' if sent.size > 300

        true
      end
      allow(tm).to receive(:pause) do |seconds|
        if seconds == 30
          pauses += 1
          on_pause&.call(pauses)
        end
        raise 'pickup spun: over 500 pauses' if (spins += 1) > 500
      end
      allow(DRCT).to receive(:walk_to) do |room|
        step.call([:walk, room])
        !unreached.include?(room)
      end
      allow(DRCI).to receive(:exists?) { |item| step.call([:tap, item]) && tickets.fetch(item.sub(/ ticket\z/, ''), []).any? }
      gets = 0
      tries = 0
      allow(DRCI).to receive(:get_item?) do |item|
        step.call([:get, item])
        on_get&.call(tries += 1)
        ordinal, name = item.match(/\A(\w+) (\w+) ticket\z/).captures
        entry = tickets.fetch(name, [])[TaskMaster::TICKET_ORDINALS.index(ordinal)]
        held = nil
        next true if [$right_hand, $left_hand].include?("#{name} ticket")
        next [$right_hand, $left_hand].any? { |hand| hand.to_s.end_with?(' ticket') } unless entry && ($right_hand.nil? || $left_hand.nil?)

        held = [name, ordinal]

        gets += 1
        $hand_ids = ($hand_ids || {}).merge("#{name} ticket" => "ticket-#{gets}")
        $right_hand.nil? ? ($right_hand = "#{name} ticket") : ($left_hand = "#{name} ticket")
        true
      end
      allow(DRCI).to receive(:put_away_item?) do |ref, *_rest|
        step.call([:put_away, ref])
        right = GameObj.right_hand.id
        left = GameObj.left_hand.id
        $right_hand = nil if right && ref == "##{right}"
        $left_hand = nil if left && ref == "##{left}"
        true
      end
      drop_ticket = lambda do
        $right_hand = nil if $right_hand.to_s.end_with?(' ticket')
        $left_hand = nil if $left_hand.to_s.end_with?(' ticket')
      end
      # The game's line, behind any chatter: the first line a matcher takes.
      answer = lambda do |command, line, matchers|
        [chatter&.call(command), line].compact.each do |text|
          found = bput_match(text, matchers)
          return found unless found.empty?
        end
        ''
      end
      allow(DRC).to receive(:bput) do |command, *matchers|
        step.call(command)

        if (look = command.match(/\Alook at my (\w+) (\w+) ticket\z/))
          next '' if silent_looks.include?(looked += 1) || unanswered.include?("#{look[1]} #{look[2]}")

          entry = tickets.fetch(look[2], [])[TaskMaster::TICKET_ORDINALS.index(look[1])]
          line = entry ? ticket_look(look[2], entry.first, ready: entry.last || pauses >= ready_after) : missing_reply
          answer.call(command, line, matchers)
        elsif command == 'swap'
          $right_hand, $left_hand = $left_hand, $right_hand
          bput_match('You move a ticket to your right hand.', matchers)
        elsif command == 'stow ticket'
          drop_ticket.call
          if restow && not_taken
            name, entry = not_taken
            tickets[name].delete_at(tickets[name].index { |other| other.equal?(entry) })
            restow == :front ? tickets[name].unshift(entry) : tickets[name].push(entry)
          end
          not_taken = nil
          'You put'
        elsif command.start_with?('give ') && held
          given += 1
          name, ordinal = held
          not_taken = [name, tickets[name][TaskMaster::TICKET_ORDINALS.index(ordinal)]]
          next answer.call(command, refused, matchers) if refused

          if refuse_first.positive?
            refuse_first -= 1
            held = nil
            next bput_match("What is it you're trying to give?", matchers)
          end

          not_taken = nil
          item = tickets[name].delete_at(TaskMaster::TICKET_ORDINALS.index(ordinal)).first
          back = (hands_back.is_a?(Array) ? hands_back[given - 1] : hands_back) || DRC.remove_flavor_text(item)
          drop_ticket.call
          # The tool lands in the hand asked for when it is free, else the other.
          if (lands_in == :left && $left_hand.nil?) || !$right_hand.nil?
            $left_hand = back
          else
            $right_hand = back
          end
          held = nil
          next '' if silent_gives.include?(given)

          answer.call(command, "You hand #{name} your ticket and are handed back a #{item}.", matchers)
        else
          ''
        end
      end
      allow(DRCC).to receive(:stow_crafting_item) do |tool, *_rest|
        step.call([:stow, tool])
        if $right_hand.to_s.match?(/\b#{Regexp.escape(tool.split.last)}\b/i)
          $right_hand = nil
        elsif $left_hand.to_s.match?(/\b#{Regexp.escape(tool.split.last)}\b/i)
          $left_hand = nil
        end
      end
      tm
    end

    # task_repair_every: a tool its ticket brings back was repaired, so its
    # clock runs from when it was left (#note_collected).
    describe 'the repair clock of a tool collected by its ticket' do
      let(:every_nezhiri) { { alchemy_belt: alchemy_belt, task_repair_every: { 'nezhiri' => 10_800 } } }
      let(:quote) { "Rangu looks over the mortar and says, \"That will cost 240 Kronars to repair.  Just give it to me again if you want, and I'll have it ready in 1 roisaen.\"" }

      # tool_drop leaves the mortar with Rangu: the quote, then a confirming
      # give that bput gets no answer to in 15 s (lag) though it went
      # through (the mortar leaves the hand; its ticket shows up later).
      def leave_mortar_unanswered
        tm = build(npc: 'nezhiri', settings: every_nezhiri)
        replies = [quote, '']
        allow(DRCT).to receive(:walk_to).and_return(true)
        allow(DRCC).to receive(:get_crafting_item) { $right_hand = 'polished belzune stone mortar' }
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRC).to receive(:bput) do |_command, *matchers|
          reply = bput_match(replies.shift, matchers)
          $right_hand = nil if replies.empty?
          reply
        end
        tm.tool_drop(['mortar'], nil)
      end

      it 'starts, as of when it was left, for one whose confirming give went unanswered but went through' do
        leave_mortar_unanswered
        expect(UserVars.taskmaster_repairs).to match([a_hash_including('tool' => 'mortar', 'item' => 'polished belzune stone mortar', 'left_at' => be_within(5).of(Time.now.to_i))])
        expect(Hash(UserVars.taskmaster_repaired_at)).not_to have_key('mortar')
        # The pickup comes a while later (the next task's).
        left_at = Time.now.to_i - 600
        UserVars.taskmaster_repairs = [UserVars.taskmaster_repairs.first.merge('left_at' => left_at)]

        tm = pickup_world({ 'Rangu' => [['polished belzune stone mortar', true]] }, settings: every_nezhiri)
        tm.tool_pickup

        expect(sent).to include('give Rangu', [:stow, 'mortar'])
        expect(UserVars.taskmaster_repairs).to eq([])
        expect(UserVars.taskmaster_repaired_at).to eq('mortar' => left_at)
        expect(tm.repair_due?('mortar')).to be(false)
      end

      it 'keeps a stamp from when it was left or later (the kept ticket stamped it at the give), and stamps none for a note forgotten for want of a ticket' do
        left_at = Time.now.to_i - 600
        UserVars.taskmaster_repairs = [mortar.merge('repairer' => 'Rangu', 'room' => 19_209, 'left_at' => left_at)]
        UserVars.taskmaster_repaired_at = { 'mortar' => left_at + 5 }
        pickup_world({ 'Rangu' => [['polished belzune stone mortar', true]] }, settings: every_nezhiri).tool_pickup
        expect(UserVars.taskmaster_repairs).to eq([])
        expect(UserVars.taskmaster_repaired_at).to eq('mortar' => left_at + 5)

        sent.clear
        UserVars.taskmaster_repairs = [mortar.merge('repairer' => 'Rangu', 'room' => 19_209, 'left_at' => left_at)]
        UserVars.taskmaster_repaired_at = nil
        pickup_world({ 'Rangu' => [] }, settings: every_nezhiri).tool_pickup
        expect(UserVars.taskmaster_repairs).to eq([])
        expect(UserVars.taskmaster_repaired_at).to be_nil
      end
    end

    describe 'after the accept (#collect_task_tools)' do
      it 'hands in the tickets of the noted tools the work uses, matched by the hand tag noted (the ticket names more), and forgets them once back' do
        UserVars.taskmaster_repairs = [bowl, needles, stick]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], ['grooved agonite mixing stick', true]], 'clerk' => [['knitting needles', true]] })

        tm.collect_task_tools(['bowl', 'mixing stick', 'sieve'])

        expect(sent).to include([:walk, 19_209], [:get, 'first Rangu ticket'], [:stow, 'bowl'], [:stow, 'mixing stick'])
        expect(sent).not_to include([:walk, 16_659])
        expect(UserVars.taskmaster_repairs).to eq([needles])
        expect { tm.stop_if_tools_at_repair(['bowl', 'mixing stick', 'sieve']) }.not_to raise_error
      end

      it 'hands in nothing for a note two tickets of different items could be for, keeps the note, says so, and stops the work that uses it' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], ['large purpleheart bowl edged with silver', true]] }, rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(sent).not_to include(a_string_starting_with('give '))
        expect(UserVars.taskmaster_repairs).to eq([bowl])
        expect(DRC).to have_received(:message).with('More than one Rangu ticket carried could be for large purpleheart bowl; handing in none for it, and keeping the note. Hand the right one in yourself.').once
        expect { tm.stop_if_tools_at_repair(['bowl']) }.to raise_error(SystemExit)
      end

      it 'hands in, in the sweep of the Rangu tickets no note accounts for, neither of two tickets a note could be for, and keeps the note' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], ['large purpleheart bowl edged with silver', true]] }, rangu_ticket: true)

        tm.collect_task_tools(['bowl'])

        expect(gives).to eq(0)
        expect(UserVars.taskmaster_repairs).to eq([bowl])
        expect(DRC).to have_received(:message).with('More than one Rangu ticket carried could be for large purpleheart bowl; handing in none for it, and keeping the note. Hand the right one in yourself.').once
      end

      it 'still sweeps an un-noted Rangu ticket for another item when two tickets a note could be for are carried' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], ['large purpleheart bowl edged with silver', true], ['iron forging hammer', true]] }, rangu_ticket: true)

        tm.collect_task_tools(['bowl'])

        expect(gives).to eq(1)
        expect(sent).to include([:get, 'third Rangu ticket'])
        expect(sent).not_to include([:get, 'first Rangu ticket'], [:get, 'second Rangu ticket'])
        expect(UserVars.taskmaster_repairs).to eq([bowl])
      end

      # Nothing between runs changes what the tickets read, so a note kept
      # for want of the player's hand stops every run the same way.
      it 'says, at the stop, that every run stops until the player hands the right ticket in, run after run, when two tickets could be the note\'s' do
        UserVars.taskmaster_repairs = [bowl]
        2.times do
          tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], ['large purpleheart bowl edged with silver', true]] }, rangu_ticket: false)
          tm.collect_task_tools(['bowl'])
          expect { tm.stop_if_tools_at_repair(['bowl']) }.to raise_error(SystemExit)
        end

        expect(gives).to eq(0)
        expect(DRC).to have_received(:message).with("large purpleheart bowl still at repair (see above); stopping before Nezhiri's task is worked. It stays open, and every run stops here until you hand the right Rangu ticket in yourself, then run ;taskmaster pickup.").twice
        expect(DRC).not_to have_received(:message).with(/the next run collects/)
      end

      it 'names apart, at the stop, a tool the next run collects and one held back for the player\'s hand' do
        UserVars.taskmaster_repairs = [bowl, stick]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], ['large purpleheart bowl edged with silver', true], ['grooved agonite mixing stick', false]] }, ready_after: 999, rangu_ticket: false)

        tm.collect_task_tools(['bowl', 'mixing stick'])

        expect { tm.stop_if_tools_at_repair(['bowl', 'mixing stick']) }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with("large purpleheart bowl, grooved agonite mixing stick still at repair (see above); stopping before Nezhiri's task is worked. It stays open, and the next run collects grooved agonite mixing stick first; every run stops here until you hand the right Rangu ticket in for large purpleheart bowl yourself, then run ;taskmaster pickup.")
      end

      it 'forgets, at the next task\'s pickup on the same run, that a note was held back once a ticket can be handed in for it' do
        UserVars.taskmaster_repairs = [bowl]
        tickets = { 'Rangu' => [[bowl_ticket, false], ['large purpleheart bowl edged with silver', false]] }
        tm = pickup_world(tickets, ready_after: 999, rangu_ticket: false)
        tm.collect_task_tools(['bowl'])
        tickets['Rangu'].pop

        tm.collect_task_tools(['bowl'])

        expect { tm.stop_if_tools_at_repair(['bowl']) }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with("large purpleheart bowl still at repair (see above); stopping before Nezhiri's task is worked. It stays open, and the next run collects it first.")
      end

      it "takes a note's ticket for its very name in hand before a longer one that begins with it" do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], ['large purpleheart bowl', true]] }, rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(gives).to eq(1)
        expect(sent).to include([:get, 'second Rangu ticket'])
        expect(sent).not_to include([:get, 'first Rangu ticket'])
        expect(DRC).not_to have_received(:message).with(/More than one/)
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it "never takes for a note a longer ticket another note has by its very name" do
        long = bowl.merge('item' => bowl_ticket)
        tm = build

        expect(tm.ticket_for(bowl, [{ ordinal: 'first', item: bowl_ticket }], [long, bowl])).to be_nil
        expect(tm.ticket_for(bowl, [{ ordinal: 'first', item: bowl_ticket }], [bowl])).to eq({ ordinal: 'first', item: bowl_ticket })
      end

      context 'a note with no name in hand' do
        let(:nameless) { { 'npc' => 'nezhiri', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'bowl', 'left_at' => 0 } }
        let(:two_bowls) { [{ ordinal: 'first', item: 'large purpleheart bowl' }, { ordinal: 'second', item: 'small wooden bowl' }] }

        it 'takes a ticket by its setting name\'s words only when one item fits; two different items are :unclear and the note is kept' do
          tm = build
          expect(tm.ticket_for(nameless, two_bowls.first(1))).to eq(two_bowls.first)
          expect(tm.ticket_for(nameless, two_bowls)).to eq(:unclear)
        end

        it 'never hands in either of two tickets that fit a note with no name in hand, and keeps the note' do
          UserVars.taskmaster_repairs = [nameless.merge('repairer' => 'Catrox', 'room' => 19_093)]
          tm = pickup_world({ 'Catrox' => [['heavy iron bowl', true], ['large purpleheart bowl', true]] }, rangu_ticket: false)

          tm.collect_task_tools(['bowl'])

          expect(gives).to eq(0)
          expect(UserVars.taskmaster_repairs.size).to eq(1)
        end

        # A look that goes unanswered hides a ticket that may fit too: the one
        # seen only looks unique. An approximate claim waits for a whole read;
        # an exact one does not.
        it 'hands in no ticket that only approximately fits a named note while a look goes unanswered, and keeps the note' do
          mortar = { 'npc' => 'nezhiri', 'repairer' => 'Catrox', 'room' => 19_093, 'tool' => 'mortar', 'item' => 'stone mortar', 'left_at' => 0 }
          UserVars.taskmaster_repairs = [mortar]
          tm = pickup_world({ 'Catrox' => [['rough granite stone mortar', true], ['polished belzune stone mortar', true]] }, unanswered: ['second Catrox'], rangu_ticket: false)

          tm.collect_task_tools(['mortar'])

          expect(gives).to eq(0)
          expect(UserVars.taskmaster_repairs).to eq([mortar])
        end

        it 'still hands in a ticket for the very name in hand while a later look goes unanswered' do
          mortar = { 'npc' => 'nezhiri', 'repairer' => 'Catrox', 'room' => 19_093, 'tool' => 'mortar', 'item' => 'polished belzune stone mortar', 'left_at' => 0 }
          UserVars.taskmaster_repairs = [mortar]
          tm = pickup_world({ 'Catrox' => [['polished belzune stone mortar', true], ['rough granite stone mortar', true]] }, unanswered: ['second Catrox'], rangu_ticket: false)

          tm.collect_task_tools(['mortar'])

          expect(gives).to eq(1)
          expect(UserVars.taskmaster_repairs).to eq([])
        end

        it 'holds back an approximate claim, but not an exact one, when the read was not whole' do
          tm = build
          named = { 'npc' => 'nezhiri', 'repairer' => 'Catrox', 'room' => 19_093, 'tool' => 'mortar', 'item' => 'stone mortar', 'left_at' => 0 }
          seen = [{ ordinal: 'first', item: 'rough granite stone mortar' }]

          expect(tm.ticket_for(named, seen, [named], [], whole: false)).to be_nil
          expect(tm.ticket_for(nameless, two_bowls.first(1), [nameless], [], whole: false)).to be_nil
          expect(tm.ticket_for(named.merge('item' => 'rough granite stone mortar'), seen, [named], [], whole: false)).to eq(seen.first)
          expect(tm.ticket_for(named, seen)).to eq(seen.first)
          # Nor does the Rangu sweep hand in the ticket held back.
          expect(tm.unaccounted_tickets(seen, [[named, nil]], whole: false)).to eq([])
          expect(tm.unaccounted_tickets(seen, [[named, nil]])).to eq(seen)
        end

        it 'sweeps no Rangu ticket that approximately fits a named note while a look goes unanswered' do
          mortar = { 'npc' => 'nezhiri', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'mortar', 'item' => 'stone mortar', 'left_at' => 0 }
          UserVars.taskmaster_repairs = [mortar]
          tm = pickup_world({ 'Rangu' => [['rough granite stone mortar', true], ['polished belzune stone mortar', true]] }, unanswered: ['second Rangu'], rangu_ticket: true)

          tm.collect_task_tools(['mortar'])

          expect(gives).to eq(0)
          expect(UserVars.taskmaster_repairs).to eq([mortar])
        end

        it "fits a ticket by its setting name's words, and so keeps a ticket of its tool out of the Rangu sweep when the repairer refused it" do
          tm = build
          mortar_ticket = { ordinal: 'third', item: 'heavy iron mortar' }

          expect(tm.fits_note?(nameless, 'small wooden bowl')).to be(true)
          expect(tm.fits_note?(nameless, 'heavy iron mortar')).to be(false)
          expect(tm.unaccounted_tickets([two_bowls.last, mortar_ticket], [[nameless, :refused]])).to eq([mortar_ticket])
        end
      end

      # A full hand (:not_got) or an unseen tool ends the visit, so whichever
      # ticket goes first is the one sure to be handed in.
      it "hands in the work's own ticket before a Rangu ticket no note accounts for, so a visit cut short has collected it" do
        UserVars.taskmaster_repairs = [bowl]
        fill_hands = ->(gets) { ($right_hand = 'iron mortar') && ($left_hand = 'iron pestle') if gets == 2 }
        tm = pickup_world({ 'Rangu' => [['steel hammer', true], [bowl_ticket, true]] }, rangu_ticket: true, on_get: fill_hands)

        tm.collect_task_tools(['bowl'])

        expect(sent.select { |step| step.is_a?(Array) && step.first == :get }.first).to eq([:get, 'second Rangu ticket'])
        expect(UserVars.taskmaster_repairs).to eq([])
        expect { tm.stop_if_tools_at_repair(['bowl']) }.not_to raise_error
      end

      it 'pairs a note with a name in hand before one without, so the nameless note does not take the named one\'s ticket' do
        nameless = { 'npc' => 'nezhiri', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'bowl', 'left_at' => 0 }
        UserVars.taskmaster_repairs = [nameless, bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, false], ['small bowl', false]] }, ready_after: 999, rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(UserVars.taskmaster_repairs).to eq([nameless, bowl])
        expect(DRC).not_to have_received(:message).with(/No Rangu ticket carried/)
        expect(gives).to eq(0)
      end

      it 'takes either of two tickets for one item (two of the same tool), one per note' do
        twin = bowl.merge('left_at' => 2)
        UserVars.taskmaster_repairs = [bowl, twin]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], [bowl_ticket, true]] }, rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(gives).to eq(2)
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it 'pairs two notes for one item with a ticket each, so neither ticket counts as one no note accounts for while both are not ready' do
        twin = bowl.merge('left_at' => 2)
        UserVars.taskmaster_repairs = [bowl, twin]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, false], [bowl_ticket, false]] }, ready_after: 999, rangu_ticket: true)

        tm.collect_task_tools(['bowl'])

        expect(DRC).to have_received(:message).with("Rangu has not finished #{bowl_ticket}, #{bowl_ticket}; leaving them for a later pickup.")
        expect(tm.instance_variable_get(:@tools_left_at_repair)).to eq([bowl, twin])
      end

      it "hands in another taskmaster's noted ticket at the same repairer when it is ready, and waits for none of them" do
        scissors = { 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'scissors', 'item' => 'jagged steel scissors', 'left_at' => 1 }
        UserVars.taskmaster_repairs = [scissors, bowl, stick]
        tm = pickup_world({ 'Rangu' => [['jagged steel scissors', true], [bowl_ticket, true], ['grooved agonite mixing stick', false]] }, ready_after: 999, npc: 'zasele')

        tm.collect_task_tools(['scissors'])

        expect(sent).to include([:stow, 'scissors'], [:stow, 'bowl'])
        expect(tm).not_to have_received(:pause).with(30)
        expect(UserVars.taskmaster_repairs).to eq([stick])
        expect { tm.stop_if_tools_at_repair(['scissors']) }.not_to raise_error
      end

      it "only looks, and walks nowhere, when the Rangu tickets carried are other tasks' tools not ready yet" do
        hammer = { 'npc' => 'poltu', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'forging hammer', 'item' => 'diagonal-peen forging hammer', 'left_at' => 1 }
        UserVars.taskmaster_repairs = [hammer]
        tm = pickup_world({ 'Rangu' => [['diagonal-peen forging hammer', false]] }, ready_after: 999, npc: 'bradyn', settings: { forging_tools: ['forging hammer'] })

        tm.collect_task_tools(tm.bradyn_tools('stone'))

        expect(sent).to eq([[:tap, 'Rangu ticket'], 'look at my first Rangu ticket', 'look at my second Rangu ticket'])
        expect(UserVars.taskmaster_repairs).to eq([hammer])
        expect { tm.stop_if_tools_at_repair(['chisels']) }.not_to raise_error
      end

      it 'collects for a Bradyn metal task the forging hammer a Poltu task left (they share the forging tools), and the other way round' do
        poltu_hammer = { 'npc' => 'poltu', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'forging hammer', 'item' => 'steel forging hammer', 'left_at' => 1 }
        UserVars.taskmaster_repairs = [poltu_hammer]
        tm = pickup_world({ 'Rangu' => [['steel forging hammer', false]] }, ready_after: 1, npc: 'bradyn', settings: { forging_tools: ['forging hammer', 'tongs'] }, rangu_ticket: false)

        tm.collect_task_tools(tm.task_tools('bradyn', ['sword', 2, 5, 'ingot', 'bronze']))

        expect(tm).to have_received(:pause).with(30).once
        expect(sent).to include([:stow, 'forging hammer'])
        expect(UserVars.taskmaster_repairs).to eq([])
        UserVars.taskmaster_repairs = [poltu_hammer.merge('npc' => 'bradyn')]
        tm = pickup_world({ 'Rangu' => [['steel forging hammer', true]] }, npc: 'poltu', settings: { forging_tools: ['forging hammer', 'tongs'] }, rangu_ticket: false)
        tm.collect_task_tools(tm.task_tools('poltu', ['sword', 2, 5, 'ingot', 'bronze']))
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      # An older taskmaster kept no notes, so its tickets, and any whose
      # note was lost (another Lich install, ;e UserVars.taskmaster_repairs
      # = nil), are collected as main collected every Rangu ticket.
      it 'hands in, waiting for it, a Rangu ticket no note accounts for when the TAP before the ask found one' do
        tm = pickup_world({ 'Rangu' => [['diagonal-peen hammer', false]] }, ready_after: 1, npc: 'poltu', rangu_ticket: true)

        tm.collect_task_tools(['bellows'])

        expect(tm).to have_received(:pause).with(30).once
        expect(sent).to include([:walk, 19_209], 'give Rangu', [:stow, 'hammer'])
      end

      # The first run after an upgrade: main left every task's tools with
      # Rangu and kept no notes.
      it 'names an un-noted Rangu ticket still not ready after the longest wait, and stops the work when its item names a tool the work uses' do
        tm = pickup_world({ 'Rangu' => [['diagonal-peen forging hammer', false]] }, ready_after: 999, npc: 'poltu', rangu_ticket: true, settings: { forging_tools: ['forging hammer', 'tongs'] })

        tm.collect_task_tools(tm.task_tools('poltu', ['sword', 2, 5, 'ingot', 'bronze']))

        expect(tm).to have_received(:pause).with(30).exactly(TaskMaster::TICKET_WAIT_POLLS).times
        expect(DRC).to have_received(:message).with('Rangu has not finished diagonal-peen forging hammer; leaving it for a later pickup. No note was kept for diagonal-peen forging hammer ' \
                                                    '(an older taskmaster\'s, or a note lost); a later task or ;taskmaster pickup hands it in.')
        expect(UserVars.taskmaster_repairs).to be_nil
        expect { tm.stop_if_tools_at_repair(['forging hammer', 'tongs']) }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with("diagonal-peen forging hammer still at repair (see above); stopping before Poltu's task is worked. It stays open, and the next run collects it first.")
      end

      it 'names an un-noted Rangu ticket still not ready after the longest wait, and the task goes on when its item names no tool the work uses' do
        tm = pickup_world({ 'Rangu' => [['diagonal-peen forging hammer', false]] }, ready_after: 999, npc: 'nezhiri', rangu_ticket: true)

        tm.collect_task_tools(['bowl', 'mixing stick'])

        expect(tm).to have_received(:pause).with(30).exactly(TaskMaster::TICKET_WAIT_POLLS).times
        expect(DRC).to have_received(:message).with(/\ARangu has not finished diagonal-peen forging hammer; .* No note was kept for diagonal-peen forging hammer/)
        expect { tm.stop_if_tools_at_repair(['bowl', 'mixing stick']) }.not_to raise_error
      end

      # A refused ticket counts as one still at repair: the next run's TAP
      # sweeps it again, and the work it is for waits for it.
      it 'names an un-noted Rangu ticket the repairer does not take, tries it once, and stops the work when its item names a tool the work uses' do
        tm = pickup_world({ 'Rangu' => [['diagonal-peen forging hammer', true]] }, refuse_first: 99, npc: 'poltu', rangu_ticket: true, settings: { forging_tools: ['forging hammer', 'tongs'] })

        tm.collect_task_tools(tm.task_tools('poltu', ['sword', 2, 5, 'ingot', 'bronze']))

        expect(gives).to eq(1)
        expect(tm).not_to have_received(:pause).with(30)
        expect(DRC).to have_received(:message).with('Rangu did not take the ticket (What is it); keeping it for a later pickup.')
        expect(UserVars.taskmaster_repairs).to be_nil
        expect(tm.instance_variable_get(:@tools_left_at_repair)).to eq([{ 'repairer' => 'Rangu', 'room' => 19_209, 'item' => 'diagonal-peen forging hammer' }])
        expect { tm.stop_if_tools_at_repair(['forging hammer', 'tongs']) }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with("diagonal-peen forging hammer still at repair (see above); stopping before Poltu's task is worked. It stays open, and the next run collects it first.")
      end

      it 'names a noted ticket still not ready once, as its note, not again by its ticket, when a Rangu ticket is carried' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, false]] }, ready_after: 999, rangu_ticket: true)

        tm.collect_task_tools(['bowl'])

        expect(tm.instance_variable_get(:@tools_left_at_repair)).to eq([bowl])
        expect { tm.stop_if_tools_at_repair(['bowl']) }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with("large purpleheart bowl still at repair (see above); stopping before Nezhiri's task is worked. It stays open, and the next run collects it first.")
      end

      it 'hands in a second ticket for a noted item when a Rangu ticket is carried (one note, one ticket), and names it when still not ready' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], [bowl_ticket, true]] }, rangu_ticket: true)

        tm.collect_task_tools(['bowl'])

        expect(gives).to eq(2)
        expect(sent.count([:stow, 'bowl'])).to eq(2)
        expect(UserVars.taskmaster_repairs).to eq([])

        sent.clear
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], [bowl_ticket, false]] }, ready_after: 999, rangu_ticket: true)

        tm.collect_task_tools(['bowl'])

        expect(gives).to eq(1)
        expect(UserVars.taskmaster_repairs).to eq([])
        expect(DRC).to have_received(:message).with(/\ARangu has not finished #{bowl_ticket}; .* No note was kept for #{bowl_ticket}/)
        expect(tm.instance_variable_get(:@tools_left_at_repair)).to eq([{ 'repairer' => 'Rangu', 'room' => 19_209, 'item' => bowl_ticket }])
      end

      it 'hands in a ready_only ticket that becomes ready during the wait for the work\'s own, before it leaves the repairer' do
        scissors = { 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'scissors', 'item' => 'jagged steel scissors', 'left_at' => 1 }
        knitting = { 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'knitting needle', 'item' => 'knitting needles', 'left_at' => 1 }
        UserVars.taskmaster_repairs = [scissors, knitting]
        tm = pickup_world({ 'Rangu' => [['jagged steel scissors', false], ['knitting needles', false]] }, ready_after: 1, npc: 'zasele', rangu_ticket: false,
                                                                                                           settings: { outfitting_tools: ['scissors', 'knitting needle'] })

        tm.collect_task_tools(tm.tailoring_tools_used('cloth'))

        expect(tm).to have_received(:pause).with(30).once
        expect(sent).to include([:stow, 'scissors'], [:stow, 'knitting needle'])
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it 'hands in a ready_only tool while the work\'s own is waited for, and calls neither lost' do
        scissors = { 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'scissors', 'item' => 'jagged steel scissors', 'left_at' => 1 }
        UserVars.taskmaster_repairs = [scissors, bowl]
        tm = pickup_world({ 'Rangu' => [['jagged steel scissors', false], [bowl_ticket, true]] }, ready_after: 1, npc: 'zasele', rangu_ticket: false)

        tm.collect_task_tools(['scissors'])

        expect(sent).to include([:stow, 'bowl'], [:stow, 'scissors'])
        expect(DRC).not_to have_received(:message).with(/forgetting/)
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it 'forgets a ready_only note with no ticket once, however long the work\'s own is waited for' do
        scissors = { 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'scissors', 'item' => 'jagged steel scissors', 'left_at' => 1 }
        UserVars.taskmaster_repairs = [scissors, bowl]
        tm = pickup_world({ 'Rangu' => [['jagged steel scissors', false]] }, ready_after: 999, npc: 'zasele', rangu_ticket: false)

        tm.collect_task_tools(['scissors'])

        expect(tm).to have_received(:pause).with(30).exactly(TaskMaster::TICKET_WAIT_POLLS).times
        expect(DRC).to have_received(:message).with('No Rangu ticket carried for: large purpleheart bowl; forgetting it (collected by hand or by another script?).').once
        expect(UserVars.taskmaster_repairs).to eq([scissors])
      end

      it "sweeps only Rangu's un-noted tickets when a Rangu ticket is carried, never Catrox's (crossing-repair's, mining-buddy's), at Catrox for a noted tool" do
        UserVars.taskmaster_repairs = [mortar]
        tm = pickup_world({ 'Catrox' => [['heavy iron mortar', true], ['polished belzune stone mortar', true]], 'Rangu' => [['steel hammer', true]] }, rangu_ticket: true)

        tm.collect_task_tools(['mortar'])

        expect(sent).to include([:get, 'second Catrox ticket'], [:stow, 'mortar'], [:get, 'first Rangu ticket'], [:stow, 'hammer'])
        expect(sent).not_to include([:get, 'first Catrox ticket'])
        expect(gives).to eq(2)
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it 'says once that more than one ticket could be for a note, however long another ticket is waited for, and hands in none for it' do
        UserVars.taskmaster_repairs = [bowl, stick]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], ['large purpleheart bowl edged with silver', true], ['grooved agonite mixing stick', false]] }, ready_after: 3, rangu_ticket: false)

        tm.collect_task_tools(['bowl', 'mixing stick'])

        expect(tm).to have_received(:pause).with(30).exactly(3).times
        expect(DRC).to have_received(:message).with('More than one Rangu ticket carried could be for large purpleheart bowl; handing in none for it, and keeping the note. Hand the right one in yourself.').once
        expect(sent.grep(Array).select { |step| step.first == :get }).to eq([[:get, 'third Rangu ticket']])
        expect(sent).to include([:stow, 'mixing stick'])
        expect(UserVars.taskmaster_repairs).to eq([bowl])
      end

      # A ticket ahead handed in by hand, or by another script, in a 30 s wait.
      it "reads every ticket again when a wait reads another ticket at the waited one's ordinal, and hands in the right one" do
        UserVars.taskmaster_repairs = [bowl]
        carried = { 'Rangu' => [['steel hammer', true], [bowl_ticket, false], ['grooved agonite mixing stick', true]] }
        tm = pickup_world(carried, ready_after: 2, rangu_ticket: false, on_pause: ->(count) { carried['Rangu'].shift if count == 1 })

        tm.collect_task_tools(['bowl'])

        # The read (to the fourth, none), the wait's look at the second (the
        # stick now), all again (the bowl first), the next wait's look at the first.
        expect(sent.grep(/\Alook at my /).map { |look| look[/my (\w+)/, 1] }).to eq(%w[first second third fourth second first second third first])
        expect(sent.grep(Array).select { |step| step.first == :get }).to eq([[:get, 'first Rangu ticket']])
        expect(sent.grep(Array).select { |step| step.first == :stow }).to eq([[:stow, 'bowl']])
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      # The GET brings another ticket than the one read at that ordinal: one
      # ahead was handed in meanwhile.
      it 'reads the tickets again after a tool not the noted one comes back, and hands in the noted ticket at its ordinal now' do
        UserVars.taskmaster_repairs = [bowl]
        carried = { 'Rangu' => [['steel hammer', true], [bowl_ticket, true], ['grooved agonite mixing stick', true]] }
        tm = pickup_world(carried, rangu_ticket: false, on_get: ->(count) { carried['Rangu'].shift if count == 1 })

        tm.collect_task_tools(['bowl'])

        expect(sent.grep(Array).select { |step| step.first == :get }.map(&:last)).to eq(['second Rangu ticket', 'first Rangu ticket'])
        expect(sent.grep(Array).select { |step| step.first == :stow }).to eq([[:stow, 'mixing stick'], [:stow, 'bowl']])
        expect(UserVars.taskmaster_repairs).to eq([])
        expect(DRC).not_to have_received(:message).with(/forgetting/)
      end

      it 'keeps the note when a tool not the noted one comes back and the look finds no ticket while a TAP still finds one' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] }, hands_back: 'heavy iron mortar', rangu_ticket: false)
        allow(DRCI).to receive(:exists?) { |item| sent << [:tap, item] && true }

        tm.collect_task_tools(['bowl'])

        expect(sent).to include([:stow, 'mortar'], [:tap, 'Rangu ticket'])
        expect(DRC).to have_received(:message).with('Could not look at the Rangu tickets carried; keeping the notes of large purpleheart bowl.')
        expect(UserVars.taskmaster_repairs).to eq([bowl])
      end

      it "tries a note's next ticket for the same item when the repairer does not take the first (another clerk's, with no note of it), and keeps the note only when it takes none" do
        UserVars.taskmaster_repairs = [needles]
        tm = pickup_world({ 'clerk' => [['knitting needles', true], ['knitting needles', true]] }, npc: 'zasele', rangu_ticket: false, refuse_first: 1)

        tm.collect_task_tools(['knitting needles'])

        expect(sent.grep(Array).select { |step| step.first == :get }.map(&:last)).to eq(['first clerk ticket', 'second clerk ticket'])
        expect(gives).to eq(2)
        expect(sent).to include([:stow, 'knitting needles'])
        expect(UserVars.taskmaster_repairs).to eq([])
        expect { tm.stop_if_tools_at_repair(['knitting needles']) }.not_to raise_error

        sent.clear
        UserVars.taskmaster_repairs = [needles]
        tm = pickup_world({ 'clerk' => [['knitting needles', true], ['knitting needles', true]] }, npc: 'zasele', rangu_ticket: false, refuse_first: 2)

        tm.collect_task_tools(['knitting needles'])

        expect(sent.grep(Array).select { |step| step.first == :get }.map(&:last)).to eq(['first clerk ticket', 'second clerk ticket'])
        expect(gives).to eq(2)
        expect(UserVars.taskmaster_repairs).to eq([needles])
        expect { tm.stop_if_tools_at_repair(['knitting needles']) }.to raise_error(SystemExit)
      end

      # lich-5's get_item? checks only the noun (ticket) in a hand, so the
      # Catrox ticket held makes it true though the GET brought nothing.
      it "gives nothing, says the hands are full, and keeps the note when another repairer's ticket is held and the other hand is busy" do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] }, rangu_ticket: false)
        $right_hand = 'Catrox ticket'
        $left_hand = 'steel tongs'
        $hand_ids = { 'Catrox ticket' => '801', 'steel tongs' => '802' }

        tm.collect_task_tools(['bowl'])

        expect(sent).to include([:get, 'first Rangu ticket'])
        expect(gives).to eq(0)
        expect(sent).not_to include('stow ticket')
        expect(DRC).to have_received(:message).with('Could not get the first Rangu ticket (hands full?); leaving it for a later pickup.')
        expect(DRC).not_to have_received(:message).with(/into your right hand/)
        expect(UserVars.taskmaster_repairs).to eq([bowl])
      end

      it 'taps for a Rangu ticket itself when nothing looked before the ask (a finish, a restock), and does nothing more with none noted or carried' do
        tm = pickup_world({})

        tm.collect_task_tools(['bowl'])

        expect(sent).to eq([[:tap, 'Rangu ticket']])
        expect(tm.instance_variable_get(:@tools_left_at_repair)).to eq([])
      end

      it 'sends nothing when the TAP before the ask found no Rangu ticket and nothing is noted' do
        tm = pickup_world({}, rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(sent).to be_empty
      end

      it 'waits, 30 s at a time, until a noted ticket the work uses is ready, looking again only at that ticket' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, false]] }, ready_after: 2, rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(tm).to have_received(:pause).with(30).twice
        expect(sent).to include([:stow, 'bowl'])
        # Two looks to read the tickets (the second finds none), then one per wait.
        expect(looks).to eq(4)
      end

      it 'looks at the tickets once for many tools, keeping track of the ordinals as each is handed in, not again after each' do
        tools = ['bellows', 'diagonal-peen hammer', 'shovel', 'tongs']
        UserVars.taskmaster_repairs = tools.map { |tool| { 'npc' => 'poltu', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => tool, 'item' => "steel #{tool}", 'left_at' => 1 } }
        tm = pickup_world({ 'Rangu' => tools.map { |tool| ["steel #{tool}", true] } }, npc: 'poltu', settings: { forging_tools: tools }, rangu_ticket: false)

        tm.collect_task_tools(tools)

        expect(looks).to eq(tools.size + 1)
        expect(sent.grep(Array).select { |step| step.first == :get }.map(&:last)).to eq(Array.new(4, 'first Rangu ticket'))
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it 'leaves a noted ticket still not ready after the longest wait, says so, keeps it noted, and stops the work that uses it' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, false]] }, ready_after: 999, rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(tm).to have_received(:pause).with(30).exactly(TaskMaster::TICKET_WAIT_POLLS).times
        expect(DRC).to have_received(:message).with("Rangu has not finished #{bowl_ticket}; leaving it for a later pickup.")
        expect(UserVars.taskmaster_repairs).to eq([bowl])
        expect { tm.stop_if_tools_at_repair(['bowl', 'mixing stick', 'sieve']) }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with("large purpleheart bowl still at repair (see above); stopping before Nezhiri's task is worked. It stays open, and the next run collects it first.")
        expect { tm.stop_if_tools_at_repair(%w[mortar pestle sieve]) }.not_to raise_error
      end

      it "puts away the repairer's ticket already in a hand first, so its get brings it, and collects the tool" do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] }, rangu_ticket: false)
        $right_hand = 'Rangu ticket'
        $hand_ids = { 'Rangu ticket' => '901' }

        tm.collect_task_tools(['bowl'])

        expect(sent.first).to eq([:put_away, '#901'])
        expect(sent).to include('give Rangu', [:stow, 'bowl'])
        expect(UserVars.taskmaster_repairs).to eq([])
        expect { tm.stop_if_tools_at_repair(['bowl']) }.not_to raise_error
        expect(DRC).not_to have_received(:message).with(/Could not put away/)
      end

      it "says so when the repairer's ticket in a hand will not go away" do
        tm = build
        $right_hand = 'Rangu ticket'
        $hand_ids = { 'Rangu ticket' => '901' }
        allow(DRCI).to receive(:put_away_item?).with('#901').and_return(false)

        tm.put_away_tickets('Rangu')

        expect(DRC).to have_received(:message).with('Could not put away the Rangu ticket in hand; a pickup may not get its tickets.')
      end

      it "puts away nothing in a hand that is not one of the repairer's tickets with an id: a clerk's ledger, or a ticket GameObj shows no id for" do
        tm = build
        $right_hand = "clerk's ledger"
        $left_hand = 'clerk ticket'
        $hand_ids = { "clerk's ledger" => '111' }
        $hand_nouns = { "clerk's ledger" => 'ledger', 'clerk ticket' => 'ticket' }
        allow(DRCI).to receive(:put_away_item?)

        tm.put_away_tickets('clerk')

        expect(DRCI).not_to have_received(:put_away_item?)
      end

      it "never hands a society clerk's ticket to another clerk: a ticket noted at one clerk's room stays carried at another's" do
        sieve = { 'npc' => 'nezhiri', 'repairer' => 'clerk', 'room' => 8860, 'tool' => 'sieve', 'item' => 'wide sieve', 'left_at' => 1 }
        UserVars.taskmaster_repairs = [sieve, needles]
        tm = pickup_world({ 'clerk' => [['wide sieve', true], ['knitting needles', true]] }, npc: 'zasele', rangu_ticket: false)

        tm.collect_task_tools(['knitting needles'])

        expect(sent).to include([:walk, 16_659], [:get, 'second clerk ticket'], [:stow, 'knitting needles'])
        expect(sent).not_to include([:walk, 8860], [:get, 'first clerk ticket'])
        expect(UserVars.taskmaster_repairs).to eq([sieve])
      end

      it "hands in nothing for a note whose ticket could as well be another clerk's tool of the same name" do
        twin = needles.merge('npc' => 'nezhiri', 'room' => 8860)
        UserVars.taskmaster_repairs = [twin, needles]
        tm = pickup_world({ 'clerk' => [['knitting needles', true]] }, npc: 'zasele', rangu_ticket: false)

        tm.collect_task_tools(['knitting needles'])

        expect(sent).not_to include(a_string_starting_with('give '))
        expect(UserVars.taskmaster_repairs).to eq([twin, needles])
        # Both are the work's tools, so each clerk's room is looked at, and each says so.
        expect(DRC).to have_received(:message).with('The clerk ticket carried for knitting needles could as well be for the same tool noted at the clerk in room 8860; handing in none for it, and keeping the note. Hand it in yourself at the right clerk, then run ;taskmaster pickup.')
        expect(DRC).to have_received(:message).with('The clerk ticket carried for knitting needles could as well be for the same tool noted at the clerk in room 16659; handing in none for it, and keeping the note. Hand it in yourself at the right clerk, then run ;taskmaster pickup.')
        # One ticket is carried: not "more than one".
        expect(DRC).not_to have_received(:message).with(/More than one/)
        expect(sent).not_to include(a_collection_starting_with(:walk))
        # Every run would stop on it the same way, so the stop says what to do.
        expect { tm.stop_if_tools_at_repair(['knitting needles']) }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with("knitting needles, knitting needles still at repair (see above); stopping before Zasele's task is worked. It stays open, and every run stops here until you hand the right clerk ticket in yourself, then run ;taskmaster pickup.")
      end

      it "stows a forged bone saw back on the toolbelt by the belt's own name for it, not the shortened name noted" do
        saw = { 'npc' => 'bradyn', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'steel saw', 'item' => 'steel straight bone saw', 'left_at' => 1 }
        belt = { 'name' => 'engineering belt', 'items' => ['bone saw', 'chisels'] }
        UserVars.taskmaster_repairs = [saw]
        tm = pickup_world({ 'Rangu' => [['steel straight bone saw', true]] }, npc: 'bradyn', settings: { engineering_belt: belt }, rangu_ticket: false)

        tm.collect_task_tools(tm.bradyn_tools('stack'))

        expect(DRCC).to have_received(:stow_crafting_item).with('bone saw', 'duffel bag', belt)
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it 'stows a tool on the toolbelt whose items name it, though another belt comes first' do
        UserVars.taskmaster_repairs = [bowl]
        forging_belt = { 'name' => 'forging belt', 'items' => ['forging hammer', 'tongs'] }
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] }, settings: { forging_belt: forging_belt }, rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(DRCC).to have_received(:stow_crafting_item).with('bowl', 'duffel bag', alchemy_belt)
      end
    end

    # A tool a task needs that is not on you, looked for among the repair
    # tickets carried before the society clerk is asked: Kythkani,
    # 2026-11-23 03:39-06:08, task_no_repair, had its mortar at Catrox
    # (crossing-repair left it at 03:23) and the Catrox ticket in the pack,
    # and every run stopped at "Can't find mortar: not on you, and the
    # alchemy clerk didn't have it." until the ticket was handed in by hand.
    describe 'a tool missing at a task, looked for among the tickets carried (#ensure_tools)' do
      let(:kythkani_mortar) { 'polished belzune stone mortar' }

      # pickup_world, plus: Catrox as Crossing's town repairer; the tools
      # on you (on_you), and any tool stowed since (by its noun), found by
      # a TAP; a TAP for "<repairer> ticket" true while that repairer's
      # tickets list holds one; clerk-tools recorded and bringing nothing.
      def missing_world(tickets, on_you: [], **opts)
        tm = pickup_world(tickets, **opts)
        allow(tm).to receive(:get_data).with('town').and_return('Crossing' => { 'metal_repair' => { 'id' => 19_093, 'name' => 'Catrox' } })
        allow(tm).to receive(:put_hands_away)
        allow(DRCI).to receive(:in_hands?).and_return(false)
        allow(DRCI).to receive(:exists?) do |item|
          sent << [:tap, item]
          next tickets.fetch(item.delete_suffix(' ticket'), []).any? if item.end_with?(' ticket')

          on_you.include?(item) || sent.any? { |entry| entry.is_a?(Array) && entry.first == :stow && entry.last.split.last == item.split.last }
        end
        allow(DRC).to receive(:wait_for_script_to_complete) { |*args| sent << [:script, *args] }
        tm
      end

      it "hands in another script's Catrox ticket for the missing mortar, and asks no clerk (Kythkani, 2026-11-23)" do
        tm = missing_world({ 'Catrox' => [['steel ring mail', true], [kythkani_mortar, true]] }, on_you: %w[pestle sieve], no_repair: true)

        expect { tm.ensure_tools(%w[mortar pestle sieve], 'alchemy') }.not_to raise_error

        expect(sent).to include([:walk, 19_093], [:get, 'second Catrox ticket'], 'give Catrox', [:stow, 'mortar'])
        expect(gives).to eq(1)
        expect(sent).not_to include([:stow, 'mail'])
        expect(sent).not_to include([:script, 'clerk-tools', %w[alchemy get]])
        expect(DRC).to have_received(:message).with('Got mortar back by its repair ticket.')
      end

      it 'looks at no ticket and walks nowhere when a TAP finds none carried, then asks the clerk' do
        tm = missing_world({}, on_you: %w[pestle sieve], no_repair: true)

        expect { tm.ensure_tools(%w[mortar pestle sieve], 'alchemy') }.to raise_error(SystemExit)

        expect(sent).to include([:tap, 'Rangu ticket'], [:tap, 'Catrox ticket'], [:script, 'clerk-tools', %w[alchemy get]])
        expect(looks).to eq(0)
        expect(sent.grep(Array).map(&:first)).not_to include(:walk)
        expect(DRC).to have_received(:message).with("Can't find mortar: not on you, and the alchemy clerk didn't have it. Stopping before buying anything.")
      end

      it 'taps nothing for tickets when every tool is on you' do
        tm = missing_world({ 'Catrox' => [[kythkani_mortar, true]] }, on_you: %w[mortar pestle sieve])

        tm.ensure_tools(%w[mortar pestle sieve], 'alchemy')

        expect(sent).to eq([[:tap, 'mortar'], [:tap, 'pestle'], [:tap, 'sieve']])
      end

      it 'waits for a ticket not ready yet, as any pickup does' do
        tm = missing_world({ 'Catrox' => [[kythkani_mortar, false]] }, ready_after: 2, on_you: %w[pestle sieve], no_repair: true)

        tm.ensure_tools(%w[mortar pestle sieve], 'alchemy')

        expect(tm).to have_received(:pause).with(30).twice
        expect(sent).to include([:stow, 'mortar'])
      end

      it 'leaves a ticket still not ready after the longest wait, and the stop names it to hand in yourself' do
        tm = missing_world({ 'Catrox' => [[kythkani_mortar, false]] }, ready_after: 999, on_you: %w[pestle sieve], no_repair: true)

        expect { tm.ensure_tools(%w[mortar pestle sieve], 'alchemy') }.to raise_error(SystemExit)

        expect(tm).to have_received(:pause).with(30).exactly(TaskMaster::TICKET_WAIT_POLLS).times
        expect(DRC).to have_received(:message).with("Catrox has not finished #{kythkani_mortar}; leaving it there.")
        expect(DRC).to have_received(:message)
          .with("Can't find mortar: not on you, and the alchemy clerk didn't have it. You carry a Catrox ticket for #{kythkani_mortar}: hand it in yourself. Stopping before buying anything.")
      end

      it 'hands in none of two tickets for different items that could be the tool, says so, and names both at the stop' do
        tm = missing_world({ 'Catrox' => [['rough granite stone mortar', true], [kythkani_mortar, true]] }, on_you: %w[pestle sieve], no_repair: true)

        expect { tm.ensure_tools(%w[mortar pestle sieve], 'alchemy') }.to raise_error(SystemExit)

        expect(gives).to eq(0)
        expect(sent.grep(Array).map(&:first)).not_to include(:walk)
        expect(DRC).to have_received(:message)
          .with("More than one Catrox ticket carried could be for the mortar (rough granite stone mortar, #{kythkani_mortar}); handing in none for it. Hand the right one in yourself.").once
        expect(DRC).to have_received(:message).with(/\ACan't find mortar: .* You carry a Catrox ticket for rough granite stone mortar, a Catrox ticket for #{kythkani_mortar}: hand them in yourself\./)
      end

      it "hands in no ticket for another tool, nor one whose noun only follows the tool's name" do
        tm = missing_world({ 'Catrox' => [['loimic grooved pestle', true], ['stiff mortar brush', true]] }, on_you: %w[pestle sieve], no_repair: true)

        expect { tm.ensure_tools(%w[mortar pestle sieve], 'alchemy') }.to raise_error(SystemExit)

        expect(gives).to eq(0)
        expect(DRC).to have_received(:message).with("Can't find mortar: not on you, and the alchemy clerk didn't have it. Stopping before buying anything.")
      end

      it 'hands in no ticket for it from a read that did not reach every ticket (more than the ordinals): one not seen could be for it too' do
        many = [[kythkani_mortar, true]] + Array.new(TaskMaster::TICKET_ORDINALS.size) { |index| ["steel ring mail #{index}", true] }
        tm = missing_world({ 'Catrox' => many }, on_you: %w[pestle sieve], no_repair: true)

        expect { tm.ensure_tools(%w[mortar pestle sieve], 'alchemy') }.to raise_error(SystemExit)

        expect(gives).to eq(0)
        expect(looks).to eq(TaskMaster::TICKET_ORDINALS.size)
      end

      it 'hands in one ticket of two for the same item, leaving the other carried' do
        tm = missing_world({ 'Catrox' => [[kythkani_mortar, true], [kythkani_mortar, true]] }, on_you: %w[pestle sieve], no_repair: true)

        tm.ensure_tools(%w[mortar pestle sieve], 'alchemy')

        expect(gives).to eq(1)
        expect(sent).to include([:stow, 'mortar'])
      end

      it 'tries a ticket the repairer refuses once, and the stop names it' do
        tm = missing_world({ 'Catrox' => [[kythkani_mortar, true]] }, refused: 'Catrox shakes his head.', on_you: %w[pestle sieve], no_repair: true)

        expect { tm.ensure_tools(%w[mortar pestle sieve], 'alchemy') }.to raise_error(SystemExit)

        expect(gives).to eq(1)
        expect(DRC).to have_received(:message).with(/You carry a Catrox ticket for #{kythkani_mortar}: hand it in yourself\./)
      end

      it "hands in the noted tool's own ticket by its note, forgets the note and starts its clock as of when it was left" do
        UserVars.taskmaster_repairs = [mortar]
        tm = missing_world({ 'Catrox' => [[kythkani_mortar, true]] }, on_you: %w[pestle sieve])

        tm.ensure_tools(%w[mortar pestle sieve], 'alchemy')

        expect(sent).to include([:stow, 'mortar'])
        expect(UserVars.taskmaster_repairs).to eq([])
        expect(Hash(UserVars.taskmaster_repaired_at)['mortar']).to eq(1)
      end

      it "looks among the society clerk's tickets with task_repair_by task_type, but not when taskmaster sends nothing for repair" do
        clerk_data = { 'remedies' => { 'Crossing' => { 'repair-room' => 8860, 'repair-npc' => 'clerk' } } }
        tm = missing_world({ 'clerk' => [[kythkani_mortar, true]] }, on_you: %w[pestle sieve], settings: { task_repair_by: 'task_type' })
        allow(tm).to receive(:get_data).with('crafting').and_return(clerk_data)

        tm.ensure_tools(%w[mortar pestle sieve], 'alchemy')
        expect(sent).to include([:tap, 'clerk ticket'], [:walk, 8860], [:stow, 'mortar'])

        sent.clear
        tm = missing_world({ 'clerk' => [[kythkani_mortar, true]] }, on_you: %w[pestle sieve], settings: { task_repair_by: 'task_type' }, no_repair: true)
        allow(tm).to receive(:get_data).with('crafting').and_return(clerk_data)
        expect { tm.ensure_tools(%w[mortar pestle sieve], 'alchemy') }.to raise_error(SystemExit)
        expect(sent).not_to include([:tap, 'clerk ticket'])
      end

      it 'looks for no ticket while the repair replies are not known' do
        tm = missing_world({ 'Catrox' => [[kythkani_mortar, true]] }, on_you: %w[pestle sieve], no_repair: true)
        allow(tm).to receive(:repair_replies_known?).and_return(false)

        expect { tm.ensure_tools(%w[mortar pestle sieve], 'alchemy') }.to raise_error(SystemExit)

        expect(sent).not_to include([:tap, 'Catrox ticket'])
        expect(looks).to eq(0)
      end

      it 'looks again after a look that goes unanswered, then hands the ticket in' do
        tm = missing_world({ 'Catrox' => [[kythkani_mortar, true]] }, silent_looks: [1], on_you: %w[pestle sieve], no_repair: true)

        tm.ensure_tools(%w[mortar pestle sieve], 'alchemy')

        expect(tm).to have_received(:pause).with(30).once
        expect(sent).to include([:stow, 'mortar'])
      end

      # Review of #8147: one missing tool, a ticket for it at two repairers.
      it 'hands in one ticket for a missing tool, though another repairer holds one for it too' do
        tm = missing_world({ 'Rangu' => [['rough granite stone mortar', true]], 'Catrox' => [[kythkani_mortar, true]] }, on_you: %w[pestle sieve], no_repair: true)

        expect { tm.ensure_tools(%w[mortar pestle sieve], 'alchemy') }.not_to raise_error

        expect(gives).to eq(1)
        expect(sent).to include([:stow, 'mortar'])
        expect(sent).not_to include([:walk, 19_093])
        expect(sent).not_to include([:tap, 'Catrox ticket'])
      end

      # Review of #8147: with no wand or rod in enchanting_tools, Dorhum needs the
      # imbuement rod enchant falls back to ("rod"); a stirring rod is not it.
      describe "Dorhum's fallback rod (#ensure_dorhum_tools)" do
        let(:stirring_rod) { { 'npc' => 'poltu', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'rod', 'item' => 'bronze stirring rod', 'left_at' => 1 } }

        def dorhum_world(tickets)
          missing_world(tickets, on_you: %w[burin loop], settings: { enchanting_tools: %w[burin loop] })
        end

        it "hands in no stirring rod's ticket no note accounts for, and asks the enchanting clerk" do
          tm = dorhum_world({ 'Rangu' => [['bronze stirring rod', true]] })

          expect { tm.ensure_dorhum_tools }.to raise_error(SystemExit)

          expect(gives).to eq(0)
          expect(sent).to include([:script, 'clerk-tools', %w[enchanting get]])
          expect(DRC).not_to have_received(:message).with(/back by its repair ticket/)
        end

        it "hands in no ticket of Poltu's noted stirring rod, and keeps the note" do
          UserVars.taskmaster_repairs = [stirring_rod]
          tm = dorhum_world({ 'Rangu' => [['bronze stirring rod', true]] })

          expect { tm.ensure_dorhum_tools }.to raise_error(SystemExit)

          expect(gives).to eq(0)
          expect(UserVars.taskmaster_repairs).to eq([stirring_rod])
          expect(sent).to include([:script, 'clerk-tools', %w[enchanting get]])
        end

        it 'hands in an imbuement rod ticket for it, and asks no clerk' do
          tm = dorhum_world({ 'Rangu' => [['simple imbuement rod', true]] })

          expect { tm.ensure_dorhum_tools }.not_to raise_error

          expect(gives).to eq(1)
          expect(sent).to include([:stow, 'rod'])
          expect(sent).not_to include(a_collection_starting_with(:script))
        end
      end

      describe '#ticket_names_tool?' do
        let(:tm) { build(npc: 'nezhiri') }

        it 'takes an item whose noun is the tool and that holds every word of its name' do
          expect(tm.ticket_names_tool?(kythkani_mortar, 'mortar')).to be(true)
          expect(tm.ticket_names_tool?('a grooved agonite mixing stick', 'mixing stick')).to be(true)
          expect(tm.ticket_names_tool?('large purpleheart bowl edged with ivory', 'bowl')).to be(true)
        end

        it 'refuses another noun, a missing word, and the sewing needles for the knitting needles' do
          expect(tm.ticket_names_tool?('stiff mortar brush', 'mortar')).to be(false)
          expect(tm.ticket_names_tool?('agonite stick', 'mixing stick')).to be(false)
          expect(tm.ticket_names_tool?('slender agonite sewing needles', 'knitting needles')).to be(false)
          expect(tm.ticket_names_tool?('slender agonite knitting needles', 'needles')).to be(false)
        end

        it 'needs every word of the tool in the item, not the item in the tool' do
          expect(tm.ticket_names_tool?('rod', 'imbuement rod')).to be(false)
          expect(tm.ticket_names_tool?('bronze stirring rod', TaskMaster::IMBUE_ROD)).to be(false)
          expect(tm.ticket_names_tool?('simple imbuement rod', TaskMaster::IMBUE_ROD)).to be(true)
        end
      end
    end

    describe 'every tool (#tool_pickup: the pickup mode, and task_get_tools_on_completion)' do
      it 'hands in every noted tool at every repairer, and every Rangu ticket, but no clerk ticket no note accounts for' do
        UserVars.taskmaster_repairs = [needles]
        tm = pickup_world({ 'Rangu' => [['steel hammer', true]], 'clerk' => [['bronze tongs', true], ['knitting needles', true]] })

        tm.tool_pickup

        expect(sent).to include([:walk, 16_659], [:walk, 19_209], [:stow, 'knitting needles'], [:stow, 'hammer'])
        expect(sent).not_to include([:stow, 'tongs'])
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it "leaves another named repairer's tickets that no note accounts for (Catrox: crossing-repair's, mining-buddy's)" do
        catrox = { 'npc' => 'zasele', 'repairer' => 'Catrox', 'room' => 19_093, 'tool' => 'scissors', 'item' => 'jagged scissors', 'left_at' => 1 }
        UserVars.taskmaster_repairs = [catrox]
        tm = pickup_world({ 'Catrox' => [['jagged scissors', true], ['steel ring mail', true]] })

        tm.tool_pickup

        expect(sent).to include([:stow, 'scissors'])
        expect(sent).not_to include([:stow, 'mail'])
        expect(gives).to eq(1)
      end

      it 'waits for a Rangu ticket no note accounts for, as for a noted one, and leaves it, named, after the longest wait' do
        tm = pickup_world({ 'Rangu' => [['steel hammer', false]] }, ready_after: 1)
        tm.tool_pickup
        expect(sent).to include([:stow, 'hammer'])

        sent.clear
        tm = pickup_world({ 'Rangu' => [['steel hammer', false]] }, ready_after: 999)
        tm.tool_pickup
        expect(tm).to have_received(:pause).with(30).exactly(TaskMaster::TICKET_WAIT_POLLS).times
        expect(DRC).to have_received(:message).with(/\ARangu has not finished steel hammer; leaving it for a later pickup\. No note was kept for steel hammer/)
      end

      it 'skips a ticket noted nowhere that the repairer does not take, and goes on to the next' do
        tm = pickup_world({ 'Rangu' => [['steel hammer', true], ['bronze tongs', true]] }, refuse_first: 1)

        tm.tool_pickup

        expect(sent).to include('stow ticket', [:get, 'second Rangu ticket'], [:stow, 'tongs'])
      end

      it 'with nothing noted, only taps for a Rangu ticket' do
        tm = pickup_world({})

        tm.tool_pickup

        expect(sent).to eq([[:tap, 'Rangu ticket']])
      end

      it 'hands in every Rangu ticket, one note pairing with one: a second ticket for a noted item too' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], [bowl_ticket, true]] })

        tm.tool_pickup

        expect(gives).to eq(2)
        expect(sent.count([:stow, 'bowl'])).to eq(2)
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it "stows the tool that comes back by the belt's name for it, not what the other hand already held" do
        tm = pickup_world({ 'Rangu' => [['grooved agonite mixing stick', true]] }, lands_in: :left)
        # The ticket comes into the left hand and is swapped to the right for
        # the give, so the bowl ends in the left and the stick comes back to
        # the right hand the give emptied. A right-first pick finds the stick
        # here too: "keeps the note, and puts away nothing else, when the
        # ticket is taken but nothing new shows ..." is what tells the object
        # new in a hand from one already held.
        $right_hand = 'large purpleheart bowl'

        tm.tool_pickup

        expect(sent).to include([:stow, 'mixing stick'])
        expect(sent).not_to include([:stow, 'bowl'])
      end

      it 'moves a ticket that lands in the left hand to the right before the give (the right hand busy)' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] })
        $right_hand = 'gnarled walking stick'

        tm.tool_pickup

        expect(sent.index('swap')).to be < sent.index('give Rangu')
        expect(sent).to include([:stow, 'bowl'])
        expect(UserVars.taskmaster_repairs).to eq([])
      end
    end

    describe 'what keeps or forgets a note' do
      it 'forgets, and names, a noted tool with no ticket carried for it once a whole look finds none' do
        UserVars.taskmaster_repairs = [bowl, stick]
        tm = pickup_world({ 'Rangu' => [['grooved agonite mixing stick', true]] }, rangu_ticket: false)

        tm.collect_task_tools(['bowl', 'mixing stick'])

        expect(DRC).to have_received(:message).with('No Rangu ticket carried for: large purpleheart bowl; forgetting it (collected by hand or by another script?).')
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it 'forgets nothing on a look that goes unanswered (the ticket may be behind it), and hands in nothing it did not see' do
        UserVars.taskmaster_repairs = [bowl, stick]
        tm = pickup_world({ 'Rangu' => [['grooved agonite mixing stick', true], [bowl_ticket, true]] }, unanswered: ['second Rangu', 'first Rangu'], rangu_ticket: false)

        tm.collect_task_tools(['bowl', 'mixing stick'])

        expect(sent).not_to include([:stow, 'bowl'])
        expect(UserVars.taskmaster_repairs).to eq([bowl, stick])
        expect(DRC).not_to have_received(:message).with(/forgetting/)
        # Looked at again after each wait, as for a ticket not ready, until the polls run out.
        expect(tm).to have_received(:pause).with(30).exactly(TaskMaster::TICKET_WAIT_POLLS).times
        expect(DRC).to have_received(:message).with('Could not look at every Rangu ticket carried (a look went unanswered, 20 times); large purpleheart bowl, grooved agonite mixing stick left for a later pickup.')
        # LOOK reads a stowed ticket anywhere: no walk to look again.
        expect(sent).not_to include([:walk, 19_209])
      end

      # lich-5's DRC.bput returns on the first line any pattern matches, so
      # another player's line can answer a LOOK; the game's reply behind it
      # is then lost to the next command.
      it "forgets no note on another player's line ahead of a look's answer (it does not start as a ticket's look), and collects the tool" do
        UserVars.taskmaster_repairs = [needles]
        speech = ['Kerl says, "I was looking at the notice board."']
        chatter = ->(command) { speech.shift if command.start_with?('look at my ') }
        tm = pickup_world({ 'clerk' => [['knitting needles', true]] }, npc: 'zasele', chatter: chatter, rangu_ticket: false)

        tm.collect_task_tools(['knitting needles'])

        expect(DRC).not_to have_received(:message).with(/forgetting/)
        # Not even taken for an unanswered look: the look's pattern does not match it.
        expect(tm).not_to have_received(:pause).with(30)
        expect(sent).to include([:get, 'first clerk ticket'], [:stow, 'knitting needles'])
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it 'reads as a ticket only a line that starts as a ticket\'s look does and names the item' do
        tm = build

        expect(tm.read_ticket(ticket_look('Rangu', bowl_ticket), 'first')).to eq({ ordinal: 'first', item: bowl_ticket, ready: true })
        expect(tm.read_ticket("Kerl says, \"#{ticket_look('Rangu', bowl_ticket)}\"", 'first')).to be_nil
        expect(tm.read_ticket('Looking at the Rangu ticket you see nothing of note.', 'first')).to be_nil
      end

      it 'reads every ticket again, within the polls, after an unanswered look cut the opening read short while a ticket ahead stays not ready' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [['heavy iron mortar', false], [bowl_ticket, true]] }, ready_after: 10_000, silent_looks: [2], rangu_ticket: true)

        tm.collect_task_tools(['bowl'])

        expect(gives).to eq(1)
        expect(sent).to include([:stow, 'bowl'])
        expect(UserVars.taskmaster_repairs).to eq([])
        expect { tm.stop_if_tools_at_repair(['bowl']) }.not_to raise_error
      end

      # Both tickets are for the very names in hand: the second look stays
      # unanswered throughout, so no read is whole, and an approximate claim
      # (bowl_ticket) would wait for one (ticket_for).
      it 'collects a ticket seen before a look that goes unanswered, then the one behind it once a look reaches it' do
        UserVars.taskmaster_repairs = [bowl, stick]
        tm = pickup_world({ 'Rangu' => [['grooved agonite mixing stick', true], ['large purpleheart bowl', true]] }, unanswered: ['second Rangu'], rangu_ticket: false)

        tm.collect_task_tools(['bowl', 'mixing stick'])

        # Once the stick is collected the bowl's ticket is the first, which
        # answers: the bowl is collected too, not forgotten.
        expect(sent).to include([:stow, 'mixing stick'], [:stow, 'bowl'])
        expect(UserVars.taskmaster_repairs).to eq([])
        expect(DRC).not_to have_received(:message).with(/forgetting/)
      end

      it 'keeps the notes and the tickets the repairer does not take, handing each in once, with nothing else waited for' do
        UserVars.taskmaster_repairs = [bowl, stick]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], ['grooved agonite mixing stick', true]] },
                          refused: "Rangu smiles and says, \"Well that is almost done, just give me a few more moments here.\"", rangu_ticket: false)

        tm.collect_task_tools(['bowl', 'mixing stick'])

        expect(gives).to eq(2)
        expect(sent.count('stow ticket')).to eq(2)
        expect(UserVars.taskmaster_repairs).to eq([bowl, stick])
        expect(DRC).to have_received(:message).with('Rangu did not take the ticket (almost done); keeping it for a later pickup.').twice
        # Refused this visit, refused again the next: the player's hand is needed.
        expect { tm.stop_if_tools_at_repair(['bowl', 'mixing stick']) }.to raise_error(SystemExit)
        expect(DRC).to have_received(:message).with("large purpleheart bowl, grooved agonite mixing stick still at repair (see above); stopping before Nezhiri's task is worked. It stays open, and every run stops here until you hand the right Rangu ticket in yourself, then run ;taskmaster pickup.")
      end

      # The hand-in matches the repair_replies ticket_handed and
      # ticket_not_taken that workorders reads, so a refusal added to the data
      # (a clerk handed another clerk's ticket, say) is answered at once and
      # named, rather than waited out as no answer.
      it "answers the ticket hand-in with the data's ticket_not_taken, and names the refusal it matched" do
        UserVars.taskmaster_repairs = [bowl]
        data = real_repair_replies.merge('ticket_not_taken' => real_repair_replies['ticket_not_taken'] + ["isn't one of mine"])
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] }, refused: "Rangu frowns and says, \"That ticket isn't one of mine.\"", repair_replies: data, rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(UserVars.taskmaster_repairs).to eq([bowl])
        expect(DRC).to have_received(:message).with("Rangu did not take the ticket (isn't one of mine); keeping it for a later pickup.")
      end

      it "takes the tool back on the data's ticket_handed" do
        UserVars.taskmaster_repairs = [bowl]
        data = real_repair_replies.merge('ticket_handed' => ['^You hand \w+ your ticket'])
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] }, repair_replies: data, rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(DRC).to have_received(:bput).with('give Rangu', '^You hand \w+ your ticket', *real_repair_replies['ticket_not_taken'])
        expect(sent).to include([:stow, 'bowl'])
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      # DRC.bput gives '' when the answer comes after 15 s, and returns on the
      # first line any pattern matches, another player's speech included:
      # neither means the ticket was not taken while it has left the hand.
      it 'takes a hand-in whose answer came too late for bput as handed in, once the ticket has left the hand, and stows the tool that came back' do
        UserVars.taskmaster_repairs = [bowl, stick]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], ['grooved agonite mixing stick', true]] }, silent_gives: [1], rangu_ticket: false)

        tm.collect_task_tools(['bowl', 'mixing stick'])

        expect(DRC).not_to have_received(:message).with(/did not take the ticket|forgetting/)
        expect(sent).not_to include('stow ticket')
        expect(sent).to include([:stow, 'bowl'], [:stow, 'mixing stick'])
        expect([$right_hand, $left_hand]).to eq([nil, nil])
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it "does not take another player's \"almost done\" ahead of the hand-in's answer for a refusal when the ticket has left the hand" do
        UserVars.taskmaster_repairs = [bowl]
        speech = ['Kerl says, "I am almost done with mine."']
        chatter = ->(command) { speech.shift if command == 'give Rangu' }
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] }, chatter: chatter, rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(DRC).not_to have_received(:message).with(/did not take the ticket|forgetting/)
        expect(sent).not_to include('stow ticket')
        expect(sent).to include([:stow, 'bowl'])
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it 'waits a moment for a ticket given to leave the hand before taking it as not taken (the hand update may trail the reply)' do
        tm = build
        $right_hand = 'Rangu ticket'
        $hand_ids = { 'Rangu ticket' => '901' }
        waits = 0
        allow(tm).to receive(:pause).with(0.1) { $right_hand = nil if (waits += 1) == 3 }

        expect(tm.ticket_still_held?('901')).to be(false)
        expect(waits).to eq(3)

        $right_hand = 'Rangu ticket'
        waits = -100
        expect(tm.ticket_still_held?('901')).to be(true)
        expect(tm).to have_received(:pause).with(0.1).exactly(3 + TaskMaster::TICKET_IN_HAND_POLLS - 1).times
      end

      it "keeps every note when the repairer's room can't be reached, after looking at the tickets" do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] }, unreached: [19_209], rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(sent).to eq(['look at my first Rangu ticket', 'look at my second Rangu ticket', [:walk, 19_209]])
        expect(UserVars.taskmaster_repairs).to eq([bowl])
        expect(DRC).to have_received(:message).with('Could not reach Rangu (room 19209) to collect the tools left there; the tickets stay for a later pickup.')
      end

      it "walks before the first wait, and waits for nothing, when the repairer's room can't be reached and the ticket is not ready" do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, false]] }, ready_after: 999, unreached: [19_209], rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(tm).not_to have_received(:pause).with(30)
        expect(sent).to eq(['look at my first Rangu ticket', 'look at my second Rangu ticket', [:walk, 19_209]])
        expect(UserVars.taskmaster_repairs).to eq([bowl])
      end

      it 'looks again, after a wait, when the first look goes unanswered with no note there, and hands in the Rangu ticket no note accounts for' do
        UserVars.taskmaster_repairs = []
        tm = pickup_world({ 'Rangu' => [['iron stirring rod', true]] }, rangu_ticket: true, silent_looks: [1], npc: 'poltu', settings: { forging_tools: %w[hammer rod] })

        tm.collect_task_tools(%w[hammer rod])

        expect(tm).to have_received(:pause).with(30).once
        expect(gives).to eq(1)
        expect(sent).to include([:stow, 'rod'])
        expect(tm.instance_variable_get(:@tools_left_at_repair)).to eq([])
      end

      it 'looks again, after a wait, when the first look goes unanswered (lag), and collects the tool' do
        tongs = { 'npc' => 'poltu', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'tongs', 'item' => 'iron tongs', 'left_at' => 1 }
        UserVars.taskmaster_repairs = [tongs]
        tm = pickup_world({ 'Rangu' => [['iron tongs', true]] }, silent_looks: [1], npc: 'poltu', rangu_ticket: true, settings: { forging_tools: %w[bellows tongs] })

        tm.collect_task_tools(%w[bellows tongs])

        expect(tm).to have_received(:pause).with(30).once
        expect(sent).to include([:stow, 'tongs'])
        expect(UserVars.taskmaster_repairs).to eq([])
        expect(DRC).not_to have_received(:message).with(/Could not look/)
        expect { tm.stop_if_tools_at_repair(%w[bellows tongs]) }.not_to raise_error
      end

      it 'counts a look that ends the read on "What were you referring to?" as a whole look' do
        UserVars.taskmaster_repairs = [bowl, stick]
        tm = pickup_world({ 'Rangu' => [['grooved agonite mixing stick', true]] }, missing_reply: 'What were you referring to?', rangu_ticket: false)

        tm.collect_task_tools(['bowl', 'mixing stick'])

        expect(DRC).to have_received(:message).with('No Rangu ticket carried for: large purpleheart bowl; forgetting it (collected by hand or by another script?).')
        expect(DRC).not_to have_received(:message).with(/Could not look/)
        expect(sent).to include([:stow, 'mixing stick'])
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it "reads a ticket through a not_ready pattern with alternatives in the data, the whole line and not just the alternative matched" do
        UserVars.taskmaster_repairs = [bowl]
        data = real_repair_replies.merge('not_ready' => 'Looking at the|You glance at the')
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] }, repair_replies: data, rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(sent).to include('give Rangu', [:stow, 'bowl'])
        expect(DRC).not_to have_received(:message).with(/No Rangu ticket carried/)
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      [:front, :back].each do |place|
        it "hands in no ticket twice when the repairer refuses two that each go back to the #{place} of the tickets" do
          UserVars.taskmaster_repairs = [bowl, stick]
          tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], ['grooved agonite mixing stick', true]] }, refuse_first: 10_000, restow: place, rangu_ticket: false)

          tm.collect_task_tools(['bowl', 'mixing stick'])

          expect(gives).to eq(2)
          expect(sent.count('stow ticket')).to eq(2)
          expect(UserVars.taskmaster_repairs).to eq([bowl, stick])
          expect(DRC).to have_received(:message).with('Rangu did not take the ticket (What is it); keeping it for a later pickup.').twice
        end
      end

      it 'bounds the refusals by the most tickets any read saw, not the first read a lost look cut short' do
        tm = pickup_world({ 'Rangu' => [['steel hammer', true], ['iron tongs', true], ['bronze bellows', true]] }, refuse_first: 2, silent_looks: [2])

        tm.tool_pickup

        expect(gives).to eq(3)
        expect(DRC).not_to have_received(:message).with(/did not take \d+ tickets/)
        expect(sent).to include([:stow, 'bellows'])
      end

      it 'keeps a note when the read after a refusal finds no ticket while a TAP still finds one, though a ticket was handed in before it' do
        UserVars.taskmaster_repairs = [bowl, stick]
        tm = build
        reads = [[[{ ordinal: 'first', item: bowl_ticket, ready: true }, { ordinal: 'second', item: 'grooved agonite mixing stick', ready: true }], true, nil],
                 [[], true, nil]]
        allow(tm).to receive(:carried_tickets) { reads.shift || raise('read on and on') }
        allow(tm).to receive(:redeem_ticket).and_return(OpenStruct.new(name: 'large purpleheart bowl'), false)
        allow(DRCI).to receive(:exists?).with('Rangu ticket').and_return(true)
        allow(tm).to receive(:put_away_tickets)
        allow(tm).to receive(:reach_repairer).and_return(true)

        tm.collect_tools(19_209, 'Rangu', [bowl, stick])

        expect(UserVars.taskmaster_repairs).to eq([stick])
        expect(DRC).to have_received(:message).with('Could not look at the Rangu tickets carried; keeping the notes of grooved agonite mixing stick.')
        expect(DRC).not_to have_received(:message).with(/forgetting/)
      end

      it 'reads again once past the last ordinal after a hand-in, and stops when that read still stops short' do
        others = Array.new(20) { |index| ["iron tongs #{index}", false] }
        UserVars.taskmaster_repairs = [stick, bowl]
        tm = pickup_world({ 'Rangu' => [['grooved agonite mixing stick', true], *others, [bowl_ticket, true]] }, ready_after: 999, rangu_ticket: false)

        tm.collect_task_tools(['bowl', 'mixing stick'])

        expect(sent).to include([:stow, 'mixing stick'])
        expect(looks).to eq(2 * TaskMaster::TICKET_ORDINALS.size)
        expect(DRC).to have_received(:message).with('Could not look at every Rangu ticket carried (more than 20); large purpleheart bowl left for a later pickup. Hand some of the Rangu tickets in by hand, or put them in another container.')
        expect(UserVars.taskmaster_repairs).to eq([bowl])
      end

      it 'counts toward the refusal backstop the most tickets a later read saw, when the first read was cut short' do
        sieve = { 'npc' => 'nezhiri', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'sieve', 'item' => 'wide sieve', 'left_at' => 1 }
        UserVars.taskmaster_repairs = [bowl, stick, sieve]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], ['grooved agonite mixing stick', true], ['wide sieve', true]] },
                          silent_looks: [2], refused: "What is it you're trying to give?", rangu_ticket: false)

        tm.collect_task_tools(['bowl', 'mixing stick', 'sieve'])

        expect(gives).to eq(3)
        expect(DRC).not_to have_received(:message).with(/more than the/)
      end

      it 'hands in no more once the repairer has refused more tickets than were read (a ticket read as another item each time)' do
        carried = { 'Rangu' => [['steel hammer', true]] }
        tm = pickup_world(carried, refuse_first: 10_000, on_get: ->(count) { carried['Rangu'][0] = ["steel hammer #{count}", true] })

        tm.tool_pickup

        expect(gives).to eq(2)
        expect(DRC).to have_received(:message).with('Rangu did not take 2 tickets, more than the 1 read; handing in no more this time.')
      end

      it 'keeps the note, and puts away nothing else, when the ticket is taken but nothing new shows in a hand while the other hand holds another tool' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] }, rangu_ticket: false)
        $right_hand = 'heavy iron mortar'
        allow(tm).to receive(:held_objects).and_wrap_original do |original|
          # The bowl never shows; the mortar was held all along.
          original.call.reject { |obj| obj.name.to_s.include?('bowl') }
        end
        stub_const('TaskMaster::TOOL_BACK_WAIT', 0)

        tm.collect_task_tools(['bowl'])

        expect(gives).to eq(1)
        expect(DRC).to have_received(:message).with('Nothing new in hand after Rangu took the ticket; look for the tool by hand.')
        expect(sent.grep(Array).select { |step| step.first == :stow }).to eq([])
        expect(UserVars.taskmaster_repairs).to eq([bowl])
      end

      # lich-5's get_item? returns at once on the Catrox ticket held, so the
      # Rangu ticket's hand update may come a moment after it.
      it "waits a moment for the ticket got to show in a hand when another repairer's ticket is held" do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] }, rangu_ticket: false)
        $right_hand = 'Catrox ticket'
        $hand_ids = { 'Catrox ticket' => '801' }
        hidden = true
        allow(tm).to receive(:held_objects).and_wrap_original do |original|
          hidden ? original.call.reject { |obj| obj.name == 'Rangu ticket' } : original.call
        end
        allow(tm).to receive(:pause) { |seconds| hidden = false if seconds < 1 }

        tm.collect_task_tools(['bowl'])

        expect(gives).to eq(1)
        expect(sent).to include([:stow, 'bowl'])
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it 'puts away a ticket got that shows in a hand only after the wait for it, says the hands are full, and keeps the note' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] }, rangu_ticket: false)
        $right_hand = 'Catrox ticket'
        $hand_ids = { 'Catrox ticket' => '801' }
        waits = 0
        allow(tm).to receive(:held_objects).and_wrap_original do |original|
          waits < TaskMaster::TICKET_IN_HAND_POLLS ? original.call.reject { |obj| obj.name == 'Rangu ticket' } : original.call
        end
        allow(tm).to receive(:pause) do |seconds|
          waits += 1 if seconds < 1
          raise 'paused on and on' if waits > 50
        end

        tm.collect_task_tools(['bowl'])

        expect(gives).to eq(0)
        expect(sent).to include([:put_away, '#ticket-1'])
        expect(DRC).to have_received(:message).with('Could not get the first Rangu ticket (hands full?); leaving it for a later pickup.')
        expect($left_hand).to be_nil
        expect(UserVars.taskmaster_repairs).to eq([bowl])
      end

      it 'keeps the notes when a look finds no ticket but a TAP still does (the look could not see where they are)' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] }, rangu_ticket: false)
        allow(DRC).to receive(:bput).and_wrap_original do |original, command, *matchers|
          command.start_with?('look at my') ? (sent << command && bput_match('I could not find what you were referring to.', matchers)) : original.call(command, *matchers)
        end

        tm.collect_task_tools(['bowl'])

        expect(UserVars.taskmaster_repairs).to eq([bowl])
        expect(DRC).to have_received(:message).with('Could not look at the Rangu tickets carried; keeping the notes of large purpleheart bowl.')
      end

      it 'never hands in a ticket of the same noun for a tool noted by its name in hand (the noted one collected by hand): forgets the note, leaving that ticket' do
        UserVars.taskmaster_repairs = [mortar]
        tm = pickup_world({ 'Catrox' => [['heavy iron mortar', true]] }, rangu_ticket: false)

        tm.collect_task_tools(['mortar'])

        expect(sent).not_to include([:get, 'first Catrox ticket'])
        expect(UserVars.taskmaster_repairs).to eq([])
        expect(DRC).to have_received(:message).with('No Catrox ticket carried for: polished belzune stone mortar; forgetting it (collected by hand or by another script?).')
      end

      it "takes the ticket for a note noted by a hand tag that leaves words out before the noun (\"sewing needles\" for \"slender agonite sewing needles\")" do
        needles = mortar.merge('tool' => 'sewing needles', 'item' => 'sewing needles')
        UserVars.taskmaster_repairs = [needles]
        tm = pickup_world({ 'Catrox' => [['slender agonite sewing needles', true]] }, rangu_ticket: false)

        tm.collect_task_tools(['sewing needles'])

        expect(sent).to include([:get, 'first Catrox ticket'])
        expect(gives).to eq(1)
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it 'keeps a hand-tag note, handing in nothing, when two tickets hold its words (its ticket cannot be told)' do
        needles = mortar.merge('tool' => 'sewing needles', 'item' => 'sewing needles')
        UserVars.taskmaster_repairs = [needles]
        tm = pickup_world({ 'Catrox' => [['slender agonite sewing needles', true], ['steel sewing needles', true]] }, rangu_ticket: false)

        tm.collect_task_tools(['sewing needles'])

        expect(gives).to eq(0)
        expect(UserVars.taskmaster_repairs).to eq([needles])
      end

      it "forgets a note whose name in hand no ticket holds (a named note's setting words take no ticket), leaving that ticket carried" do
        UserVars.taskmaster_repairs = [mortar.merge('item' => 'granite mortar')]
        tm = pickup_world({ 'Catrox' => [['polished belzune stone mortar', true]] }, rangu_ticket: false)

        tm.collect_task_tools(['mortar'])

        expect(sent).not_to include([:get, 'first Catrox ticket'])
        expect(gives).to eq(0)
        expect(UserVars.taskmaster_repairs).to eq([])
        expect(DRC).to have_received(:message).with('No Catrox ticket carried for: granite mortar; forgetting it (collected by hand or by another script?).')
      end

      it "takes a noted tool's ticket by its name before another of the same noun (an un-noted iron mortar ahead of it)" do
        UserVars.taskmaster_repairs = [mortar]
        tm = pickup_world({ 'Catrox' => [['heavy iron mortar', true], ['polished belzune stone mortar', true]] }, rangu_ticket: false)

        tm.collect_task_tools(['mortar'])

        expect(sent).to include([:get, 'second Catrox ticket'])
        expect(sent).not_to include([:get, 'first Catrox ticket'])
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it "lets a note with no name in hand take a ticket by its setting words only when no named note has that ticket by its name" do
        nameless = mortar.merge('item' => nil, 'left_at' => 2)
        UserVars.taskmaster_repairs = [nameless, mortar]
        tm = pickup_world({ 'Catrox' => [['polished belzune stone mortar', true], ['heavy iron mortar', true]] }, rangu_ticket: false)

        tm.collect_task_tools(['mortar'])

        expect(gives).to eq(2)
        expect(UserVars.taskmaster_repairs).to eq([])
        expect(DRC).not_to have_received(:message).with(/forgetting/)
      end

      it 'forgets a note when the tool handed back is not the noted one and no ticket carried is for it now, stowing that tool by its noun (no belt lists it)' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] }, hands_back: 'heavy iron mortar', rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(DRC).to have_received(:message).with('Rangu handed back heavy iron mortar, not the noted large purpleheart bowl; looking at the Rangu tickets again, and keeping its note only while one is for it.')
        expect(DRC).to have_received(:message).with('No Rangu ticket carried for: large purpleheart bowl; forgetting it (collected by hand or by another script?).')
        expect(sent).to include([:stow, 'mortar'])
        expect(sent).not_to include([:stow, 'bowl'])
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it 'keeps the note, and hands in the next ticket for it, when the tool handed back is not the noted one but another ticket carried is for it' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], [bowl_ticket, true]] }, hands_back: ['heavy iron mortar'], rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(DRC).to have_received(:message).with('Rangu handed back heavy iron mortar, not the noted large purpleheart bowl; looking at the Rangu tickets again, and keeping its note only while one is for it.')
        expect(DRC).not_to have_received(:message).with(/forgetting/)
        expect(gives).to eq(2)
        expect(sent).to include([:stow, 'mortar'], [:stow, 'bowl'])
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it "does not count a tool of the noted one's setting words as the noted one when a name in hand was noted (an iron mortar for the belzune one)" do
        UserVars.taskmaster_repairs = [mortar]
        tm = pickup_world({ 'Catrox' => [['polished belzune stone mortar', true]] }, hands_back: 'heavy iron mortar', rangu_ticket: false)

        tm.collect_task_tools(['mortar'])

        expect(DRC).to have_received(:message).with(/\ACatrox handed back heavy iron mortar, not the noted polished belzune stone mortar; looking at the Catrox tickets again/)
        expect(DRC).to have_received(:message).with('No Catrox ticket carried for: polished belzune stone mortar; forgetting it (collected by hand or by another script?).')
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it 'goes on to the next noted ticket after a tool not the noted one comes back' do
        UserVars.taskmaster_repairs = [bowl, stick]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], ['grooved agonite mixing stick', true]] }, hands_back: ['heavy iron mortar'], rangu_ticket: false)

        tm.collect_task_tools(['bowl', 'mixing stick'])

        expect(gives).to eq(2)
        expect(sent).to include([:stow, 'mixing stick'])
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it 'counts the tool handed back as the noted one when its hand tag is the name noted, or one of them begins the other' do
        tm = build
        expect(tm.returned_tool?(bowl, 'large purpleheart bowl')).to be(true)
        expect(tm.returned_tool?(bowl, bowl_ticket)).to be(true)
        expect(tm.returned_tool?(bowl.merge('item' => bowl_ticket), 'large purpleheart bowl')).to be(true)
        expect(tm.returned_tool?(mortar, 'heavy iron mortar')).to be(false)
        expect(tm.returned_tool?(bowl, 'large purpleheart bowlful')).to be(false)
      end

      it "takes a ticket by its item's start only when the nouns agree" do
        tm = build
        expect(tm.extends_item?(bowl_ticket, 'large purpleheart bowl')).to be(true)
        expect(tm.extends_item?('steel hammer head', 'steel hammer')).to be(false)
        expect(tm.extends_item?('a Large Purpleheart Bowl', 'large purpleheart bowl')).to be(true)
        expect(tm.extends_item?('heavy iron mortar', 'polished belzune stone mortar')).to be(false)
      end

      it 'keeps the note, and hands in nothing more, when the ticket is taken but nothing new shows in a hand' do
        UserVars.taskmaster_repairs = [bowl, stick]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], ['grooved agonite mixing stick', true]] }, rangu_ticket: false)
        allow(tm).to receive(:held_objects).and_wrap_original do |original|
          # The tool never shows: drop it from what the hands show.
          original.call.reject { |obj| obj.name.to_s.include?('bowl') }
        end
        stub_const('TaskMaster::TOOL_BACK_WAIT', 0)

        tm.collect_task_tools(['bowl', 'mixing stick'])

        expect(gives).to eq(1)
        expect(DRC).to have_received(:message).with('Nothing new in hand after Rangu took the ticket; look for the tool by hand.')
        expect(UserVars.taskmaster_repairs).to eq([bowl, stick])
      end

      it 'gives nothing when the ticket cannot be brought to the right hand' do
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true]] }, rangu_ticket: false)
        allow(tm).to receive(:move_to_right_hand).and_return(false)

        tm.collect_task_tools(['bowl'])

        expect(sent).not_to include('give Rangu')
        expect(sent).to include('stow ticket')
        expect(DRC).to have_received(:message).with('Could not get the first Rangu ticket into your right hand; leaving it for a later pickup.')
        expect(UserVars.taskmaster_repairs).to eq([bowl])
      end

      it 'says so when a ticket cannot be got (no hand free), and tries no other' do
        UserVars.taskmaster_repairs = [bowl, stick]
        tm = pickup_world({ 'Rangu' => [[bowl_ticket, true], ['grooved agonite mixing stick', true]] }, rangu_ticket: false)
        $right_hand = 'unfinished burlap reinforced rope'
        $left_hand = 'sewing needles'

        tm.collect_task_tools(['bowl', 'mixing stick'])

        expect(sent.count { |step| step.is_a?(Array) && step.first == :get }).to eq(1)
        expect(DRC).to have_received(:message).with('Could not get the first Rangu ticket (hands full?); leaving it for a later pickup.')
        expect(UserVars.taskmaster_repairs).to eq([bowl, stick])
      end

      it 'reaches a noted ticket behind ten others of the same repairer (eleventh)' do
        UserVars.taskmaster_repairs = [bowl]
        others = (1..10).map { |i| ["steel hammer #{i}", false] }
        tm = pickup_world({ 'Rangu' => others + [[bowl_ticket, true]] }, rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(sent).to include('look at my eleventh Rangu ticket', [:get, 'eleventh Rangu ticket'], [:stow, 'bowl'])
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it 'says so when a noted ticket is past the last ordinal it looks at' do
        UserVars.taskmaster_repairs = [bowl]
        others = (1..TaskMaster::TICKET_ORDINALS.size).map { |i| ["steel hammer #{i}", false] }
        tm = pickup_world({ 'Rangu' => others + [[bowl_ticket, true]] }, rangu_ticket: false)

        tm.collect_task_tools(['bowl'])

        expect(DRC).to have_received(:message).with('Could not look at every Rangu ticket carried (more than 20); large purpleheart bowl left for a later pickup. ' \
                                                    'Hand some of the Rangu tickets in by hand, or put them in another container.')
        expect(UserVars.taskmaster_repairs).to eq([bowl])
      end

      it 'looks again past the last ordinal once tickets ahead of a noted one are handed in' do
        hammers = Array.new(TaskMaster::TICKET_ORDINALS.size) { ['steel hammer', true] }
        UserVars.taskmaster_repairs = [bowl]
        tm = pickup_world({ 'Rangu' => hammers + [[bowl_ticket, true]] }, rangu_ticket: true)

        tm.collect_task_tools(['bowl'])

        expect(sent).to include([:stow, 'bowl'])
        expect(UserVars.taskmaster_repairs).to eq([])
      end

      it "reads the tool off a stowed Rangu ticket, article and all, and matches it to the tool's name in hand" do
        # Kythkani, 2026-11-20 08:08:39: the ticket put in the pack, then looked at.
        look = 'Looking at the Rangu ticket you see it is for some slender agonite sewing needles capped with tiny tidal bloodstones.  You recall that your needles should be ready any moment now.'
        item = look[TaskMaster::TICKET_ITEM, :item]
        sewing = { 'tool' => 'sewing needles', 'item' => 'slender agonite sewing needles' }

        expect(item).to eq('slender agonite sewing needles capped with tiny tidal bloodstones')
        expect(build.ticket_for(sewing, [{ ordinal: 'first', item: item, ready: false }])).to eq({ ordinal: 'first', item: item, ready: false })
        expect(look).not_to match(/#{real_repair_replies['ready']}/i)
      end
    end

    describe 'with stale data' do
      it 'hands the tickets in through the shipped replies when the data (a stale data/custom copy) has none' do
        ship
        tm = pickup_world({ 'Rangu' => [['polished belzune stone mortar', true]] }, repair_replies: nil)
        allow(tm).to receive(:get_data).with('crafting').and_return({ 'stock' => {} })

        tm.collect_task_tools(['mortar'])

        expect(sent).to include([:get, 'first Rangu ticket'], 'give Rangu', [:stow, 'mortar'])
        expect(DRC).to have_received(:message).with(/no usable repair_replies quote, .*; using the shipped data/).once
      end

      it 'collects nothing, and the task goes on, when even the shipped base-crafting.yaml has no repair_replies and a Rangu ticket is carried' do
        ship(raises: Errno::ENOENT)
        tm = pickup_world({ 'Rangu' => [['polished belzune stone mortar', true]] }, repair_replies: nil)
        allow(tm).to receive(:get_data).with('crafting').and_return({ 'stock' => {} })

        expect { tm.collect_task_tools(['mortar']) }.not_to raise_error

        expect(sent).to eq([[:tap, 'Rangu ticket']])
        expect(DRC).to have_received(:message).with(/no usable repair_replies quote, prompt, .*none for quote, prompt, .*tools are not left for repair or collected/).once
      end
    end

    describe 'stopping before work whose tools are still at repair (#stop_if_tools_at_repair)' do
      it 'names a tool by its setting name or the name in hand, singular or plural, a word start being enough' do
        tm = build
        expect(tm.names_tool?('iron chisels', 'chisels')).to be(true)
        expect(tm.names_tool?('knitting needle', 'knitting needles')).to be(true)
        expect(tm.names_tool?('mortar', 'pestle')).to be(false)
        expect(tm.names_tool?('', 'bowl')).to be(false)
        expect(tm.names_tool?('steel spins', 'pins')).to be(false)
      end

      it 'never names the knitting needles by a name that is not theirs (a bare "needles" is the sewing needles)' do
        tm = build
        expect(tm.names_tool?('knitting needles', 'needles')).to be(false)
        expect(tm.names_tool?('needles', 'slender bone knitting needles')).to be(false)
        expect(tm.names_tool?('slender bone knitting needles', 'knitting needle')).to be(true)
        expect(tm.names_tool?('steel sewing needles', 'needles')).to be(true)
      end

      it "finds a toolbelt by every word of one of its items in the tool's name" do
        tm = build
        expect(tm.belt_lists_tool?({ 'items' => ['bowl'] }, bowl_ticket)).to be(true)
        expect(tm.belt_lists_tool?({ 'items' => ['mixing bowl'] }, bowl_ticket)).to be(false)
        expect(tm.belt_lists_tool?({ 'items' => ['knitting needles'] }, 'slender sewing needles')).to be(false)
        expect(tm.belt_lists_tool?(nil, bowl_ticket)).to be(false)
        expect(tm.belt_lists_tool?({ 'name' => 'belt' }, bowl_ticket)).to be(false)
      end

      it 'gives the tools each task works with, as its worker checks them' do
        tm = build(settings: { outfitting_tools: ['knitting needle', 'needles', 'scissors'], forging_tools: %w[hammer tongs], shaping_tools: ['carving knife'],
                               alchemy_tools: ['bowl', 'mixing stick', 'mortar', 'pestle', 'sieve'] })
        allow(tm).to receive(:dorhum_tools).and_return(%w[burin rod])

        expect(tm.task_tools('zasele', ['rope', 2, 4, 'cloth', 'burlap'])).to eq(%w[needles scissors])
        # By outfitting_tools' own name for them (knitting_needles_name), the
        # key their repair clock is kept under.
        expect(tm.task_tools('zasele', ['hat', 2, 4, 'yarn', 'wool'])).to eq(['knitting needle'])
        expect(tm.task_tools('poltu', ['sword', 2, 5, 'ingot', 'bronze'])).to eq(%w[hammer tongs])
        expect(tm.task_tools('bradyn', ['bowl', 2, 5, 'lumber', 'balsa'])).to eq(['carving knife'])
        expect(tm.task_tools('bradyn', ['idol', 2, 'boulder', 'stone', 'alabaster'])).to eq(['chisels'])
        expect(tm.task_tools('nezhiri', ['draught', 13, { vessel: 'mortar' }])).to eq(%w[mortar pestle sieve])
        expect(tm.task_tools('dorhum', ['spongestone', 6, %w[congruence]])).to eq(%w[burin rod])
      end

      it "stops a Zasele cloth task when the scissors are still at repair, but not a yarn task, which uses only the knitting needles" do
        tm = build(settings: { outfitting_tools: %w[scissors yardstick] }, tools_left_at_repair: [{ 'tool' => 'scissors', 'item' => 'jagged scissors' }])
        allow(tm).to receive(:buy_yarn)
        allow(tm).to receive(:buy_stackables)
        allow(tm).to receive(:tailor_item)
        allow(tm).to receive(:repair)
        allow(tm).to receive(:trash)
        allow(tm).to receive(:bins_task_stock?).and_return(true)

        expect { tm.zasele('rope', 2, 4, 'cloth', 'burlap') }.to raise_error(SystemExit)
        expect(tm).not_to have_received(:buy_stackables)
        expect { tm.zasele('hat', 2, 4, 'yarn', 'wool') }.not_to raise_error
      end

      it 'stops a marathon tailoring task before sewing when one of its tools is still at repair' do
        tm = build(settings: { outfitting_tools: %w[scissors] }, tools_left_at_repair: [{ 'tool' => 'scissors', 'item' => 'jagged scissors' }])
        allow(tm).to receive(:check_stock).and_return(true)
        allow(tm).to receive(:tailor_item)

        expect { tm.marathon_tailor('rope', 2, 4, 'cloth', 'burlap') }.to raise_error(SystemExit)
        expect(tm).not_to have_received(:tailor_item)
      end

      it "picks up, after a marathon restock, the tools that restock's repair left, and stops before sewing while one is still not ready" do
        tm = pickup_world({ 'Rangu' => [['jagged scissors', false]] }, ready_after: 999, npc: 'zasele', settings: { outfitting_tools: %w[scissors] })
        order = []
        allow(tm).to receive(:check_stock).and_return(false)
        allow(tm).to receive(:repair) do |*|
          order << :repair
          UserVars.taskmaster_repairs = [{ 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'scissors', 'item' => 'jagged scissors', 'left_at' => 1 }]
        end
        allow(tm).to receive(:restock) { order << :restock && [] }
        allow(tm).to receive(:still_short?).and_return(false)
        allow(tm).to receive(:find_npc)
        allow(tm).to(receive(:collect_tools).and_wrap_original { |original, *args, **kw| order << :collect && original.call(*args, **kw) })
        # Stubbed so a missing stop fails at once rather than sewing on the harness.
        allow(tm).to receive(:tailor_item).and_return(2)

        expect { tm.marathon_tailor('rope', 2, 4, 'cloth', 'burlap') }.to raise_error(SystemExit)
        expect(order).to eq(%i[repair restock collect])
        # The scissors the task sews with are waited for, not only taken if ready.
        expect(tm).to have_received(:pause).with(30).exactly(TaskMaster::TICKET_WAIT_POLLS).times
        expect(tm).not_to have_received(:tailor_item)
      end

      it "waits, after a marathon restock, for the tools that restock's repair left, tapping again for a Rangu ticket (the accept's TAP is spent), and sews once they are back" do
        tm = pickup_world({ 'Rangu' => [['jagged scissors', false]] }, ready_after: 1, npc: 'zasele', settings: { outfitting_tools: %w[scissors] }, rangu_ticket: false)
        allow(tm).to receive(:check_stock).and_return(false)
        allow(tm).to receive(:repair) do |*|
          UserVars.taskmaster_repairs = [{ 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'scissors', 'item' => 'jagged scissors', 'left_at' => 1 }]
        end
        allow(tm).to receive(:restock).and_return([])
        allow(tm).to receive(:still_short?).and_return(false)
        allow(tm).to receive(:find_npc)
        allow(tm).to receive(:tailor_item).and_return(2)
        # The accept's pickup, on the TAP before the ask (none found, nothing noted).
        tm.collect_task_tools(['scissors'])
        expect(sent).to be_empty

        expect(tm.marathon_tailor('rope', 2, 4, 'cloth', 'burlap')).to eq(2)

        expect(sent.first).to eq([:tap, 'Rangu ticket'])
        expect(tm).to have_received(:pause).with(30).once
        expect(sent).to include([:stow, 'scissors'])
        expect(UserVars.taskmaster_repairs).to eq([])
        expect(tm).to have_received(:tailor_item)
      end

      context 'in marathon, collecting while the run is in Crossing' do
        # Knitting needles left by an earlier restock's repair: outfitting_tools
        # lists them, but a cloth task never sews with them.
        let(:needles_out) { { 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'knitting needle', 'item' => 'knitting needles', 'left_at' => 1 } }
        let(:outfitting) { { outfitting_tools: ['knitting needle', 'scissors'] } }

        it 'collects right after the opening restock, so the first accept, on Andreshlew, walks nowhere for a tool the task does not use' do
          UserVars.taskmaster_repairs = [needles_out]
          tm = pickup_world({ 'Rangu' => [['knitting needles', true]] }, npc: 'zasele', settings: outfitting)
          where = nil
          walks = []
          allow(DRCT).to receive(:walk_to) do |room|
            walks << [room, where]
            true
          end
          allow(tm).to receive(:reconcile_hands)
          allow(tm).to receive(:restock) { (where = :crossing) && [] }
          allow(tm).to receive(:prepare_for_task)
          allow(tm).to receive(:get_task) do
            raise 'runaway task loop' if where == :andreshlew

            where = :andreshlew
            ['rope', 2, 4, 'cloth', 'burlap']
          end
          allow(tm).to receive(:marathon_tailor)
          allow(tm).to receive(:complete_task) { Flags['wrap-up'] = true }

          expect { tm.run_marathon }.to raise_error(SystemExit)

          expect(walks).to eq([[19_209, :crossing]])
          expect(sent).to include([:stow, 'knitting needle'])
          expect(UserVars.taskmaster_repairs).to eq([])
        end

        it "waits, after a task's restock, for every tool its repair left at the run's repairer, not only those the task uses" do
          tm = pickup_world({ 'Rangu' => [['knitting needles', false]] }, ready_after: 1, npc: 'zasele', settings: outfitting, rangu_ticket: false)
          allow(tm).to receive(:check_stock).and_return(false)
          allow(tm).to receive(:repair) { UserVars.taskmaster_repairs = [needles_out] }
          allow(tm).to receive(:restock).and_return([])
          allow(tm).to receive(:still_short?).and_return(false)
          allow(tm).to receive(:find_npc)
          allow(tm).to receive(:tailor_item).and_return(2)

          expect(tm.marathon_tailor('rope', 2, 4, 'cloth', 'burlap')).to eq(2)

          expect(tm).to have_received(:pause).with(30).once
          expect(sent).to include([:stow, 'knitting needle'])
          expect(UserVars.taskmaster_repairs).to eq([])
        end
      end

      it 'does not stop a Zasele cloth task, or a marathon one, when only the knitting needles are at repair (sewing never uses them)' do
        needles_left = [{ 'tool' => 'knitting needle', 'item' => 'knitting needles' }]
        tm = build(settings: { outfitting_tools: ['knitting needle', 'scissors'] }, tools_left_at_repair: needles_left)
        allow(tm).to receive(:buy_yarn)
        allow(tm).to receive(:buy_stackables)
        allow(tm).to receive(:tailor_item).and_return(2)
        allow(tm).to receive(:repair)
        allow(tm).to receive(:trash)
        allow(tm).to receive(:bins_task_stock?).and_return(true)
        allow(tm).to receive(:check_stock).and_return(true)

        expect { tm.zasele('rope', 2, 4, 'cloth', 'burlap') }.not_to raise_error
        expect { tm.marathon_tailor('rope', 2, 4, 'leather', 'deer') }.not_to raise_error
        expect { tm.zasele('hat', 2, 4, 'yarn', 'wool') }.to raise_error(SystemExit)
        expect(tm).to have_received(:repair).with(['knitting needle', 'scissors'], anything)
        sewing = build(settings: { outfitting_tools: ['knitting needle', 'needles'] }, tools_left_at_repair: [{ 'tool' => 'needles', 'item' => 'steel sewing needles' }])
        allow(sewing).to receive(:buy_stackables)
        expect { sewing.zasele('rope', 2, 4, 'cloth', 'burlap') }.to raise_error(SystemExit)
      end

      it 'does not stop a cloth or leather task for the knitting needles with a bare "needles" (the sewing needles) in outfitting_tools, but stops a yarn task' do
        needles_left = [{ 'tool' => 'knitting needle', 'item' => 'knitting needles' }]
        tm = build(settings: { outfitting_tools: ['knitting needle', 'needles', 'scissors'] }, tools_left_at_repair: needles_left)
        allow(tm).to receive(:buy_yarn)
        allow(tm).to receive(:buy_stackables)
        # Stubbed so a missing guard fails at once rather than sewing on the harness.
        allow(tm).to receive(:tailor_item).and_return(2)
        allow(tm).to receive(:repair)
        allow(tm).to receive(:trash)
        allow(tm).to receive(:bins_task_stock?).and_return(true)
        allow(tm).to receive(:check_stock).and_return(true)

        expect { tm.zasele('rope', 2, 4, 'cloth', 'burlap') }.not_to raise_error
        expect { tm.marathon_tailor('rope', 2, 4, 'leather', 'deer') }.not_to raise_error
        expect { tm.zasele('hat', 2, 4, 'yarn', 'wool') }.to raise_error(SystemExit)
      end

      it 'stops a Bradyn bone task when its forged bone saw is at repair, noted by the shortened name in hand ("steel saw")' do
        tm = build(npc: 'bradyn', tools_left_at_repair: [{ 'npc' => 'bradyn', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'steel saw', 'item' => 'steel straight bone saw', 'left_at' => 1 }])
        allow(tm).to receive(:buy_stackables)
        # Stubbed so a missing stop fails at once rather than carving on the harness.
        allow(tm).to receive(:carve_bone)

        expect { tm.bradyn('comb', 2, 5, 'stack', 'deer') }.to raise_error(SystemExit)
        expect(tm).not_to have_received(:buy_stackables)
        expect(DRC).to have_received(:message).with(/\Asteel straight bone saw still at repair/)
      end

      it 'stops a Bradyn lumber task when a shaping tool is at repair, before any lumber is bought' do
        tm = build(npc: 'bradyn', settings: { shaping_tools: ['carving knife', 'rasp'] }, tools_left_at_repair: [{ 'npc' => 'bradyn', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'carving knife', 'item' => 'bronze carving knife', 'left_at' => 1 }])
        allow(tm).to receive(:buy_stackables)
        # Stubbed so a missing stop fails at once rather than shaping on the harness.
        allow(tm).to receive(:shape_item)
        allow(tm).to receive(:repair)
        allow(tm).to receive(:trash)

        expect { tm.bradyn('bowl', 2, 5, 'lumber', 'balsa') }.to raise_error(SystemExit)
        expect(tm).not_to have_received(:buy_stackables)
        expect(tm).not_to have_received(:shape_item)
      end

      it 'stops a Poltu (or Bradyn) metal task when a forging tool is at repair, before any ingot is handled' do
        tm = build(npc: 'poltu', settings: { forging_tools: %w[hammer tongs] }, tools_left_at_repair: [{ 'npc' => 'poltu', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'hammer', 'item' => 'steel hammer', 'left_at' => 1 }])
        allow(tm).to receive(:bin_stray_ingots)

        expect { tm.poltu('sword', 2, 5, 'ingot', 'bronze') }.to raise_error(SystemExit)
        expect(tm).not_to have_received(:bin_stray_ingots)
      end

      it 'stops a Dorhum task when an enchanting tool is at repair, before the tools are checked or a sigil is bought' do
        tm = build(npc: 'dorhum', loot_bag_checked: true, tools_left_at_repair: [{ 'npc' => 'dorhum', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'burin', 'item' => 'iron burin', 'left_at' => 1 }])
        allow(tm).to receive(:check_loot_bag)
        allow(tm).to receive(:dorhum_recipe).and_return({ noun: 'rock' })
        allow(tm).to receive(:dorhum_tools).and_return(%w[burin rod])
        allow(tm).to receive(:ensure_tools)
        allow(tm).to receive(:buy_sigils)

        expect { tm.dorhum('spongestone', 6, %w[congruence decay]) }.to raise_error(SystemExit)
        expect(tm).not_to have_received(:ensure_tools)
        expect(tm).not_to have_received(:buy_sigils)
      end

      it 'stops a Nezhiri task with crafts to make when a tool of its vessel is at repair, before the tools are checked or anything is crafted' do
        tm = build(tools_left_at_repair: [bowl])
        allow(tm).to receive(:remedy_doses_on_hand).and_return(0)
        allow(tm).to receive(:remedy_planned_yield).and_return(6)
        allow(tm).to receive(:check_remedy_uses)
        allow(tm).to receive(:remedy_tools).and_return(['bowl', 'mixing stick'])
        allow(tm).to receive(:ensure_tools)
        allow(tm).to receive(:brew_remedy_round)

        expect { tm.nezhiri('draught', 13, { product: 'deep-sea draught', vessel: 'bowl' }) }.to raise_error(SystemExit)
        expect(tm).not_to have_received(:ensure_tools)
        expect(tm).not_to have_received(:brew_remedy_round)
      end

      # bradyn() leaves the chisels by the name in hand (repair([DRC.right_hand])),
      # and tool_drop notes 'npc' with every tool: only the taskmaster's own
      # note matches the one-word "chisels" by names_tool?.
      it "stops a Bradyn stone task when the chisels (noted by the name in hand, as tool_drop notes them) are at repair, before buying rocks" do
        chisels = { 'npc' => 'bradyn', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'iron chisels', 'item' => 'iron chisels', 'left_at' => 1 }
        tm = build(npc: 'bradyn', tools_left_at_repair: [chisels])
        allow(tm).to receive(:buy_rocks)
        # Stubbed so a missing stop fails at once rather than carving on the harness.
        allow(tm).to receive(:carve_stone)

        expect { tm.bradyn('idol', 2, 'boulder', 'stone', 'alabaster') }.to raise_error(SystemExit)
        expect(tm).not_to have_received(:buy_rocks)
      end

      it 'stops a Bradyn stone task on an un-noted Rangu ticket for its chisels (no npc)' do
        tm = build(npc: 'bradyn', tools_left_at_repair: [{ 'repairer' => 'Rangu', 'room' => 19_209, 'item' => 'iron chisels' }])
        allow(tm).to receive(:buy_rocks)
        allow(tm).to receive(:carve_stone)

        expect { tm.bradyn('idol', 2, 'boulder', 'stone', 'alabaster') }.to raise_error(SystemExit)
        expect(tm).not_to have_received(:buy_rocks)
      end

      it "matches a one-word setting name to the taskmaster's own note of a longer name in hand, not to another taskmaster's" do
        own = { 'npc' => 'bradyn', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'iron chisels', 'item' => 'iron chisels', 'left_at' => 1 }
        other = own.merge('npc' => 'zasele')
        tm = build(npc: 'bradyn')

        expect(tm.tools_left_for(['chisels'], [own, other])).to eq([own])
      end

      # shape, forge and enchant get "stamp" with no skip when
      # mark_crafted_goods is set, so a stamp at repair would stop them part
      # way, a finished item unmarked in hand.
      describe 'the stamp a crafting script marks the items with (mark_crafted_goods)' do
        let(:stamp_out) { { 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'stamp', 'item' => 'iron stamp', 'left_at' => 1 } }
        let(:marking) { { mark_crafted_goods: true, outfitting_tools: ['stamp', 'knitting needle'], shaping_tools: ['carving knife', 'rasp'] } }

        it 'waits for, and stops a Bradyn lumber task before buying lumber on, a stamp another taskmaster\'s task left' do
          UserVars.taskmaster_repairs = [stamp_out]
          tm = pickup_world({ 'Rangu' => [['iron stamp', false]] }, ready_after: 999, npc: 'bradyn', rangu_ticket: false, settings: marking)
          allow(tm).to receive(:buy_stackables)
          allow(tm).to receive(:shape_item)

          tm.collect_task_tools(tm.task_tools('bradyn', ['bowl', 2, 10, 'lumber', 'balsa']))

          expect(tm).to have_received(:pause).with(30).exactly(TaskMaster::TICKET_WAIT_POLLS).times
          expect { tm.bradyn('bowl', 2, 10, 'lumber', 'balsa') }.to raise_error(SystemExit)
          expect(tm).not_to have_received(:buy_stackables)
          expect(DRC).to have_received(:message).with("iron stamp still at repair (see above); stopping before Bradyn's task is worked. It stays open, and the next run collects it first.")
        end

        it 'collects the stamp for a lumber task when it is ready, and waits for none without mark_crafted_goods' do
          UserVars.taskmaster_repairs = [stamp_out]
          tm = pickup_world({ 'Rangu' => [['iron stamp', false]] }, ready_after: 1, npc: 'bradyn', rangu_ticket: false, settings: marking)
          tm.collect_task_tools(tm.task_tools('bradyn', ['bowl', 2, 10, 'lumber', 'balsa']))
          expect(sent).to include([:stow, 'stamp'])
          expect(UserVars.taskmaster_repairs).to eq([])

          sent.clear
          UserVars.taskmaster_repairs = [stamp_out]
          tm = pickup_world({ 'Rangu' => [['iron stamp', false]] }, ready_after: 999, npc: 'bradyn', rangu_ticket: false, settings: marking.merge(mark_crafted_goods: false))
          allow(tm).to receive(:buy_stackables)
          allow(tm).to receive(:shape_item)
          allow(tm).to receive(:repair)
          allow(tm).to receive(:trash)
          tm.collect_task_tools(tm.task_tools('bradyn', ['bowl', 2, 10, 'lumber', 'balsa']))
          expect(sent).to be_empty
          expect { tm.bradyn('bowl', 2, 10, 'lumber', 'balsa') }.not_to raise_error
        end

        it 'stops Poltu\'s and Dorhum\'s work on a stamp still at repair, by any name a tool setting gives it, and counts it for Zasele\'s, but not Nezhiri\'s or Bradyn\'s stone and bone' do
          left = [stamp_out.merge('tool' => 'iron stamp')]
          settings = marking.merge(outfitting_tools: ['iron stamp'], forging_tools: %w[hammer tongs], alchemy_tools: %w[bowl])
          tm = build(npc: 'poltu', settings: settings, tools_left_at_repair: left)
          allow(tm).to receive(:bin_stray_ingots)
          expect { tm.poltu('sword', 2, 5, 'ingot', 'bronze') }.to raise_error(SystemExit)
          expect(tm).not_to have_received(:bin_stray_ingots)

          tm = build(npc: 'dorhum', loot_bag_checked: true, settings: settings, tools_left_at_repair: left)
          allow(tm).to receive(:check_loot_bag)
          allow(tm).to receive(:dorhum_recipe).and_return({ noun: 'rock' })
          allow(tm).to receive(:dorhum_tools).and_return(%w[burin rod])
          allow(tm).to receive(:ensure_tools)
          expect { tm.dorhum('spongestone', 6, %w[congruence decay]) }.to raise_error(SystemExit)
          expect(tm).not_to have_received(:ensure_tools)

          tm = build(npc: 'bradyn', settings: settings)
          expect(tm.task_tools('bradyn', ['sword', 2, 5, 'ingot', 'bronze'])).to eq(%w[hammer tongs stamp] + ['iron stamp'])
          %w[stone stack].each { |base| expect(tm.task_tools('bradyn', ['idol', 2, 5, base, 'alabaster'])).not_to include('stamp') }
          expect(tm.task_tools('zasele', ['rope', 2, 4, 'cloth', 'burlap'])).to eq(['iron stamp', 'stamp'])
          expect(tm.task_tools('zasele', ['scarf', 2, 4, 'yarn', 'wool'])).to eq(['knitting needles', 'stamp', 'iron stamp'])
          expect(tm.task_tools('nezhiri', ['draught', 13, { vessel: 'bowl' }])).not_to include('stamp')
        end

        # sew gets the stamp with skip at each item's finish, then stops the
        # run itself when it is not in hand (sew.lic swap_tool), the item
        # made but unmarked. A yarn task's work is only the knitting needles,
        # so the stamp outfitting_tools lists counts only by marking_tools.
        it 'waits for, and stops a Zasele yarn task (single or marathon) before buying yarn on, the stamp outfitting_tools lists' do
          UserVars.taskmaster_repairs = [stamp_out]
          tm = pickup_world({ 'Rangu' => [['iron stamp', false]] }, ready_after: 999, npc: 'zasele', rangu_ticket: false, settings: marking)
          allow(tm).to receive(:buy_yarn)
          allow(tm).to receive(:tailor_item).and_return(2)

          tm.collect_task_tools(tm.task_tools('zasele', ['scarf', 2, 4, 'yarn', 'wool']))

          expect(tm).to have_received(:pause).with(30).exactly(TaskMaster::TICKET_WAIT_POLLS).times
          expect { tm.zasele('scarf', 2, 4, 'yarn', 'wool') }.to raise_error(SystemExit)
          expect(tm).not_to have_received(:buy_yarn)
          expect(DRC).to have_received(:message).with("iron stamp still at repair (see above); stopping before Zasele's task is worked. It stays open, and the next run collects it first.")

          allow(tm).to receive(:check_stock).and_return(true)
          expect { tm.marathon_tailor('scarf', 2, 4, 'yarn', 'wool') }.to raise_error(SystemExit)
          expect(tm).not_to have_received(:tailor_item)
        end

        it "waits, after a marathon yarn restock, for the stamp that restock's repair of outfitting_tools left, and knits once it is back" do
          tm = pickup_world({ 'Rangu' => [['iron stamp', false]] }, ready_after: 1, npc: 'zasele', settings: marking, rangu_ticket: false)
          allow(tm).to receive(:check_stock).and_return(false)
          allow(tm).to receive(:repair) { UserVars.taskmaster_repairs = [stamp_out] }
          allow(tm).to receive(:restock).and_return([])
          allow(tm).to receive(:still_short?).and_return(false)
          allow(tm).to receive(:find_npc)
          allow(tm).to receive(:tailor_item).and_return(2)

          expect(tm.marathon_tailor('scarf', 2, 4, 'yarn', 'wool')).to eq(2)

          expect(tm).to have_received(:pause).with(30).once
          expect(sent).to include([:stow, 'stamp'])
          expect(UserVars.taskmaster_repairs).to eq([])
        end

        it "stops a Zasele cloth task on a stamp another taskmaster's toolset sent, when outfitting_tools names none" do
          left = [stamp_out.merge('npc' => 'poltu')]
          settings = marking.merge(outfitting_tools: ['scissors', 'knitting needle'], forging_tools: %w[hammer stamp])
          tm = build(npc: 'zasele', settings: settings, tools_left_at_repair: left)
          allow(tm).to receive(:buy_stackables)
          allow(tm).to receive(:tailor_item)

          expect { tm.zasele('rope', 2, 4, 'cloth', 'burlap') }.to raise_error(SystemExit)
          expect(tm).not_to have_received(:buy_stackables)

          tm = build(npc: 'zasele', settings: settings.merge(mark_crafted_goods: false), tools_left_at_repair: left)
          allow(tm).to receive(:buy_stackables)
          allow(tm).to receive(:tailor_item)
          allow(tm).to receive(:repair)
          allow(tm).to receive(:trash)
          expect { tm.zasele('rope', 2, 4, 'cloth', 'burlap') }.not_to raise_error
        end
      end

      describe "another taskmaster's tool of the same noun" do
        let(:imbuement_rod) { { 'npc' => 'dorhum', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'imbuement rod', 'item' => 'cambrinth imbuement rod', 'left_at' => 1 } }
        let(:stirring_rod) { { 'npc' => 'poltu', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'stirring rod', 'item' => 'iron stirring rod', 'left_at' => 1 } }

        it 'neither waits for nor stops a Poltu task on the imbuement rod a Dorhum task left, when forging_tools names the stirring rod "rod"' do
          UserVars.taskmaster_repairs = [imbuement_rod]
          tm = pickup_world({ 'Rangu' => [['cambrinth imbuement rod', false]] }, ready_after: 999, npc: 'poltu', rangu_ticket: false, settings: { forging_tools: %w[hammer tongs rod] })

          tm.collect_task_tools(tm.task_tools('poltu', ['sword', 2, 5, 'ingot', 'bronze']))

          expect(sent).to be_empty
          expect { tm.stop_if_tools_at_repair(%w[hammer tongs rod]) }.not_to raise_error
        end

        it "neither waits for nor stops a Dorhum task (its fallback rod) on the stirring rod a Poltu task left, yet stops it on its own imbuement rod" do
          UserVars.taskmaster_repairs = [stirring_rod]
          tm = pickup_world({ 'Rangu' => [['iron stirring rod', false]] }, ready_after: 999, npc: 'dorhum', rangu_ticket: false, settings: { enchanting_tools: ['augment loop', 'brazier', 'burin'] })
          allow(tm).to receive(:needs_own_brazier?).and_return(false)

          expect(tm.task_tools('dorhum', ['spongestone', 6, %w[congruence]])).to eq(['augment loop', 'burin', 'imbuement rod'])
          tm.collect_task_tools(tm.task_tools('dorhum', ['spongestone', 6, %w[congruence]]))

          expect(sent).to be_empty
          expect { tm.stop_if_tools_at_repair(['augment loop', 'burin', 'imbuement rod']) }.not_to raise_error
          tm.instance_variable_set(:@tools_left_at_repair, [imbuement_rod])
          expect { tm.stop_if_tools_at_repair(['augment loop', 'burin', 'imbuement rod']) }.to raise_error(SystemExit)
        end

        # forging_tools names the stirring rod "rod", and Poltu notes it under
        # that very setting name; with no rod in enchanting_tools, enchant
        # falls back to "rod" for the imbue rod, which no note is under.
        it "neither waits for nor stops a Dorhum task (its fallback rod) on the stirring rod Poltu noted as \"rod\", and still looks for the rod by enchant's \"rod\"" do
          noted_rod = stirring_rod.merge('tool' => 'rod')
          UserVars.taskmaster_repairs = [noted_rod]
          settings = { forging_tools: %w[hammer tongs rod], enchanting_tools: ['augment loop', 'brazier', 'burin'] }
          tm = pickup_world({ 'Rangu' => [['iron stirring rod', false]] }, ready_after: 999, npc: 'dorhum', rangu_ticket: false, settings: settings)
          allow(tm).to receive(:needs_own_brazier?).and_return(false)

          tm.collect_task_tools(tm.task_tools('dorhum', ['spongestone', 6, %w[congruence]]))

          expect(sent).to be_empty
          expect(tm.instance_variable_get(:@tools_left_at_repair)).to eq([noted_rod])
          allow(tm).to receive(:check_loot_bag)
          allow(tm).to receive(:dorhum_recipe).and_return({ noun: 'rock' })
          allow(tm).to receive(:ensure_tools).and_raise('past the stop')
          tm.instance_variable_set(:@loot_bag_checked, true)
          expect { tm.dorhum('spongestone', 6, %w[congruence]) }.to raise_error(RuntimeError, 'past the stop')
          # Its tickets and notes are matched as the imbuement rod (ensure_dorhum_tools).
          expect(tm).to have_received(:ensure_tools).with(['augment loop', 'burin', 'rod'], 'enchanting', match_as: ['augment loop', 'burin', TaskMaster::IMBUE_ROD])
        end

        it "still names another taskmaster's tool by its very setting name, or by names of two words or more" do
          tm = build(npc: 'bradyn')
          expect(tm.tools_left_for(['stamp'], [{ 'npc' => 'zasele', 'tool' => 'stamp', 'item' => 'iron stamp' }])).not_to be_empty
          expect(tm.tools_left_for(['knitting needles'], [{ 'npc' => 'zasele', 'tool' => 'knitting needle', 'item' => 'knitting needles' }])).not_to be_empty
          expect(tm.tools_left_for(['rod'], [{ 'npc' => 'dorhum', 'tool' => 'imbuement rod', 'item' => 'imbuement rod' }])).to be_empty
          expect(tm.tools_left_for(['rod'], [{ 'tool' => 'imbuement rod', 'item' => 'imbuement rod' }])).not_to be_empty
        end
      end
    end
  end

  describe 'noting the tools left for repair (#tool_drop)' do
    let(:quote) { "Catrox looks over the needles and says, \"That will cost 4036 Kronars to repair.  Just give it to me again if you want, and I'll have it ready in 3 roisaen.\"" }
    let(:ticket) { "You hand Catrox 4036 Kronars and he gives you back a repair ticket.  Catrox says, \"I will complete this work for you in about 3 roisaen.  Please don't lose this ticket!\"" }
    let(:no_scratch) { "Catrox shrugs and says, \"There isn't a scratch on that, and I'm not one to rob you.\"" }

    # DRC.right_hand as lich-5 gives it (common.rb, fix_dr_bullshit): a name
    # over two words shortened to its first and last ("steel straight bone
    # saw" is "steel saw"); GameObj keeps the hand tag whole.
    def shorten_right_hand
      allow(DRC).to receive(:right_hand) do
        words = $right_hand.to_s.split
        words.size > 2 ? "#{words.first} #{words.last}" : $right_hand
      end
    end

    def drop(replies, tools, hands)
      tm = build(npc: 'zasele', settings: { task_repair_by: 'town' })
      allow(tm).to receive(:get_data).and_return('Crossing' => { 'metal_repair' => { 'id' => 19_093, 'name' => 'Catrox' } })
      allow(DRCT).to receive(:walk_to).and_return(true)
      shorten_right_hand
      queue = replies.dup
      held = hands.dup
      allow(DRCC).to receive(:get_crafting_item) { $right_hand = held.shift }
      allow(DRCC).to receive(:stow_crafting_item) { $right_hand = nil }
      allow(DRC).to receive(:bput) do |command, *matchers|
        if command == 'stow ticket'
          $right_hand = nil
          'You put'
        else
          bput_match(queue.shift, matchers)
        end
      end
      tm.tool_drop(tools, nil)
      tm
    end

    it "walks to the task's repairer, gives it by name and notes each tool whose ticket it keeps, with its whole name in hand (GameObj, not DRC.right_hand's shortened one)" do
      drop([quote, ticket, no_scratch], ['knitting needles', 'scissors'], ['slender bone knitting needles', 'jagged steel scissors'])
      expect(DRC.right_hand).to be_nil
      $right_hand = 'slender bone knitting needles'
      expect(DRC.right_hand).to eq('slender needles')

      expect(DRCT).to have_received(:walk_to).with(19_093)
      expect(DRC).to have_received(:bput).with('give Catrox', any_args).exactly(3).times
      expect(UserVars.taskmaster_repairs).to match([a_hash_including('npc' => 'zasele', 'repairer' => 'Catrox', 'room' => 19_093, 'tool' => 'knitting needles',
                                                                     'item' => 'slender bone knitting needles', 'left_at' => be_within(5).of(Time.now.to_i))])
    end

    # lich-5's Vars keeps whatever it is given, so a hand-edited value of
    # the wrong kind persists across runs.
    it 'reads only the notes from taskmaster_repairs of the wrong kind (a Hash, or a list with junk), and notes the next tool in a list' do
      tm = build
      allow(tm).to receive(:save_user_vars)
      note = { 'npc' => 'zasele', 'repairer' => 'Catrox', 'room' => 19_093, 'tool' => 'awl', 'item' => 'loimic slender awl', 'left_at' => 1 }
      UserVars.taskmaster_repairs = { 'x' => 1 }
      expect(tm.repairs_out).to eq([])

      UserVars.taskmaster_repairs = ['junk', note]
      expect(tm.repairs_out).to eq([note])

      UserVars.taskmaster_repairs = { 'x' => 1 }
      tm.note_repair(note)
      expect(UserVars.taskmaster_repairs).to eq([note])
    end

    it 'notes the tool before it stows the ticket, so a run stopped in between leaves a note, not an un-noted ticket' do
      order = []
      allow(UserVars).to(receive(:taskmaster_repairs=).and_wrap_original { |original, value| order << :note && original.call(value) })
      tm = build(npc: 'zasele', settings: { task_repair_by: 'town' })
      allow(tm).to receive(:get_data).and_return('Crossing' => { 'metal_repair' => { 'id' => 19_093, 'name' => 'Catrox' } })
      allow(DRCT).to receive(:walk_to).and_return(true)
      allow(DRCC).to receive(:get_crafting_item) { $right_hand = 'slender knitting needles' }
      replies = [quote, ticket]
      allow(DRC).to receive(:bput) { |command, *matchers| command == 'stow ticket' ? (order << :stow && 'You put') : bput_match(replies.shift, matchers) }

      tm.tool_drop(['knitting needles'], nil)

      # The note, then its mark as ticketed, both before the stow.
      expect(order).to eq(%i[note note stow])
    end

    it 'notes nothing when no ticket is kept' do
      drop([no_scratch], ['scissors'], ['jagged scissors'])

      expect(UserVars.taskmaster_repairs).to be_nil
    end

    # bput matches each String pattern as /pattern/i and hands back the text
    # in the game's case (lich-5 common.rb, bput), so the script's own checks
    # of that text must ignore case too, as the data header says every
    # pattern is matched. The lines below differ in case from the shipped
    # patterns, so the script's match, not the double's, decides each one.
    it "matches the quote, the confirming give's ticket and a declined answer without regard to case, as bput does" do
      quote_case = quote.sub('cost 4036 Kronars to repair', 'COST 4036 Kronars TO REPAIR').sub('give it to me again', 'GIVE IT TO ME AGAIN')
      ticket_case = ticket.sub('a repair ticket', 'a REPAIR TICKET')
      no_scratch_case = no_scratch.sub('scratch', 'SCRATCH')

      drop([quote_case, ticket_case, no_scratch_case], ['knitting needles', 'scissors'], ['slender bone knitting needles', 'jagged steel scissors'])

      expect(DRC).to have_received(:bput).with('give Catrox', any_args).exactly(3).times
      expect(DRC).to have_received(:bput).with('stow ticket', any_args).once
      expect(UserVars.taskmaster_repairs).to match([a_hash_including('tool' => 'knitting needles', 'item' => 'slender bone knitting needles')])
      expect(DRC).not_to have_received(:message).with(/did not take|No repair ticket/)
    end
  end

  describe 'how often tools go for repair (task_repair_every)' do
    let(:now) { Time.at(1_800_000_000) }

    def every(setting, npc: 'nezhiri', **ivars)
      build(settings: { task_repair_every: setting }, npc: npc, **ivars)
    end

    describe '#repair_interval' do
      it "takes the taskmaster's entry, else default, else 0" do
        expect(every({ 'nezhiri' => 10_800, 'default' => 600 }).repair_interval).to eq(10_800)
        expect(every({ 'zasele' => 43_200, 'default' => 600 }).repair_interval).to eq(600)
        expect(every({ 'zasele' => 43_200 }).repair_interval).to eq(0)
        expect(every(nil).repair_interval).to eq(0)
      end

      it 'reads symbol and mixed-case keys as YAML or a hand-made setting may give them' do
        expect(every({ Nezhiri: 10_800 }).repair_interval).to eq(10_800)
        expect(every({ default: 7200 }).repair_interval).to eq(7200)
      end

      it 'treats a setting that is not a mapping as unset (repair after every task)' do
        expect(every('10800').repair_interval).to eq(0)
        expect(every([10_800]).repair_interval).to eq(0)
      end

      it 'reads whole seconds given as text, and treats a blank entry as none' do
        expect(every({ 'nezhiri' => '10800' }).repair_interval).to eq(10_800)
        expect(every({ 'nezhiri' => nil, 'default' => 600 }).repair_interval).to eq(600)
        expect(every({ 'nezhiri' => '  ', 'default' => 600 }).repair_interval).to eq(600)
      end

      it 'drops a blank entry (nil, empty or spaces) without naming it as not whole seconds' do
        expect(every({ 'nezhiri' => nil, 'zasele' => '', 'poltu' => '  ', 'default' => 600 }).repair_every_setting).to eq('default' => 600)
        expect(DRC).not_to have_received(:message).with(/is not a whole number/)
      end

      it "names and ignores values that are not whole seconds, 0 or more: fractions, negatives, quoted hex text ('0x10'); reads quoted digits in base 10 ('010' is 10)" do
        tm = every({ 'nezhiri' => 10_800.9, 'zasele' => -5, 'poltu' => '0x10', 'bradyn' => '010', 'dorhum' => 7200.0 })
        expect(tm.repair_every_setting).to eq('bradyn' => 10, 'dorhum' => 7200)
        %w[nezhiri:\ '10800.9' zasele:\ '-5' poltu:\ '0x10'].each { |part| expect(DRC).to have_received(:message).with(/task_repair_every #{part}/) }
      end

      it 'takes unquoted YAML 0600 and 0x10 as the octal and hex Integers Psych makes of them (why base.yaml asks for plain digits)' do
        # As lich-5 setup_files.rb loads a profile.
        setting = YAML.unsafe_load("task_repair_every:\n  nezhiri: 0600\n  poltu: 0x10\n  zasele: '0x10'\n  bradyn: '0600'\n")['task_repair_every']
        expect(every(setting).repair_every_setting).to eq('nezhiri' => 384, 'poltu' => 16, 'bradyn' => 600)
        expect(DRC).to have_received(:message).with("task_repair_every zasele: '0x10' is not a whole number of seconds (0 or more); ignoring it.")
      end

      it 'reads unquoted YAML 0800 (not octal) in base 10, takes 3:00:00 as the base-60 Integer Psych makes of it, and names an unquoted 3h' do
        # As lich-5 setup_files.rb loads a profile: Psych leaves 0800 and 3h
        # as Strings.
        setting = YAML.unsafe_load("task_repair_every:\n  nezhiri: 0800\n  poltu: 3:00:00\n  zasele: 3h\n")['task_repair_every']
        expect(every(setting).repair_every_setting).to eq('nezhiri' => 800, 'poltu' => 10_800)
        expect(DRC).to have_received(:message).with("task_repair_every zasele: '3h' is not a whole number of seconds (0 or more); ignoring it.")
      end

      it 'names a setting that is not a mapping (a bare number) instead of dropping it silently' do
        expect(every(10_800).repair_interval).to eq(0)
        expect(DRC).to have_received(:message).with("task_repair_every should map taskmasters to seconds ({ default: 0, nezhiri: 10800 }), not '10800'; ignoring it.")
      end

      it 'names and ignores an endless or not-a-number value (.inf, .nan in YAML) instead of crashing' do
        tm = every({ 'nezhiri' => Float::INFINITY, 'zasele' => Float::NAN, 'default' => 600 })
        expect(tm.repair_interval).to eq(600)
        expect(DRC).to have_received(:message).with("task_repair_every nezhiri: 'Infinity' is not a whole number of seconds (0 or more); ignoring it.")
        expect(DRC).to have_received(:message).with("task_repair_every zasele: 'NaN' is not a whole number of seconds (0 or more); ignoring it.")
      end

      it 'says so, once, and ignores an entry that is not whole seconds' do
        tm = every({ 'nezhiri' => '3h', 'default' => 600 })
        2.times { expect(tm.repair_interval).to eq(600) }
        expect(DRC).to have_received(:message).with("task_repair_every nezhiri: '3h' is not a whole number of seconds (0 or more); ignoring it.").once
      end
    end

    describe '#repair_due?' do
      it 'is due when never repaired' do
        expect(every({ 'nezhiri' => 10_800 }).repair_due?('bowl', now)).to be(true)
      end

      it 'is due once the interval has run out since the last repair, not a second before' do
        tm = every({ 'nezhiri' => 10_800 })
        UserVars.taskmaster_repaired_at = { 'bowl' => now.to_i - 10_799 }
        expect(tm.repair_due?('bowl', now)).to be(false)
        UserVars.taskmaster_repaired_at = { 'bowl' => now.to_i - 10_800 }
        expect(tm.repair_due?('bowl', now)).to be(true)
      end

      it 'keeps each tool on its own clock' do
        tm = every({ 'nezhiri' => 10_800 })
        UserVars.taskmaster_repaired_at = { 'bowl' => now.to_i, 'mortar' => now.to_i - 20_000 }
        expect(tm.repair_due?('bowl', now)).to be(false)
        expect(tm.repair_due?('mortar', now)).to be(true)
      end

      it 'is due when the last repair is noted later than now (the clock was set back)' do
        UserVars.taskmaster_repaired_at = { 'bowl' => now.to_i + 3600 }
        expect(every({ 'nezhiri' => 10_800 }).repair_due?('bowl', now)).to be(true)
      end

      it 'reads a repaired_at that is not a mapping as nothing noted' do
        UserVars.taskmaster_repaired_at = 'oops'
        tm = every({ 'nezhiri' => 10_800 })
        expect(tm.repair_due?('bowl', now)).to be(true)
        tm.note_repaired('bowl', now)
        expect(UserVars.taskmaster_repaired_at).to eq('bowl' => now.to_i)
      end

      it 'saves each stamp at once (a crash must not lose it)' do
        stub_const('Vars', double('Vars', save: nil))
        every({ 'nezhiri' => 10_800 }).note_repaired('bowl', now)
        expect(Vars).to have_received(:save)
      end

      it 'is always due at 0, as before the setting' do
        UserVars.taskmaster_repaired_at = { 'bowl' => now.to_i }
        expect(every({}).repair_due?('bowl', now)).to be(true)
      end
    end

    describe '#repair' do
      # bag_items (crafting_items_in_container) is not empty, so an example
      # sees it passed on: repair_own_tools gets a tool it lists from the
      # crafting bag (lich-5 common-crafting.rb get_crafting_item).
      def repair_with(due:, own_result: nil, carried: %w[mortar pestle sieve], **ivars)
        allow(DRCI).to receive(:exists?) { |tool| carried.include?(tool) }
        tm = every({ 'nezhiri' => 10_800 }, bag_items: %w[pestle], **ivars)
        UserVars.taskmaster_repaired_at = (%w[mortar pestle sieve] - due).to_h { |tool| [tool, Time.now.to_i] }
        @steps = []
        allow(tm).to receive(:tool_drop) { |tools, _belt| @steps << [:tool_drop, tools] }
        allow(tm).to receive(:put_hands_away) { @steps << :put_hands_away }
        allow(DRCC).to receive(:repair_own_tools).and_return(own_result)
        tm.repair(%w[mortar pestle sieve], 'alchemy belt')
        tm
      end

      it 'leaves only the tools due with the repairer, after putting the hands away (a tool not due may be in hand)' do
        expect(repair_with(due: %w[sieve])).to have_received(:tool_drop).with(['sieve'], 'alchemy belt')
        expect(@steps).to eq([:put_hands_away, [:tool_drop, ['sieve']]])
      end

      # A toolset with a stray '-' line ([tong, ~, shovel]) gives nil, and so
      # does Bradyn's stone or bone task when DRC.right_hand finds the right
      # hand empty (repair([DRC.right_hand], ...)). repair_due?(nil) is true,
      # so without the .compact a nil would reach tool_drop's get.
      it 'drops a nil tool entry: only the named tools go to the repairer, or to repair_own_tools at interval 0' do
        tm = every({ 'nezhiri' => 10_800 })
        allow(tm).to receive(:put_hands_away)
        allow(tm).to receive(:tool_drop)
        UserVars.taskmaster_repaired_at = nil
        tm.repair(['mortar', nil, 'sieve'], 'alchemy belt')
        expect(tm).to have_received(:tool_drop).with(%w[mortar sieve], 'alchemy belt').once

        own = every({ 'default' => 0 }, self_repair: true)
        allow(own).to receive(:put_hands_away)
        allow(DRCC).to receive(:repair_own_tools).and_return(nil)
        own.repair(['mortar', nil, 'sieve'], 'alchemy belt')
        expect(DRCC).to have_received(:repair_own_tools).with(anything, %w[mortar sieve], 'duffel bag', [], 'alchemy belt').once
      end

      it "puts the hands away and sends nothing after Bradyn's stone task when the right hand is empty (DRC.right_hand nil)" do
        engineering = { 'name' => 'engineering belt', 'items' => ['chisels'] }
        tm = build(npc: 'bradyn', settings: { engineering_belt: engineering, task_repair_every: { 'bradyn' => 0 } })
        %i[stop_if_tools_at_repair buy_rocks carve_stone trash put_hands_away tool_drop].each { |step| allow(tm).to receive(step) }
        allow(DRCC).to receive(:repair_own_tools)
        $right_hand = nil
        expect(DRC.right_hand).to be_nil

        tm.bradyn('stone bowl', 1, 1, 'stone', 'bowl')

        expect(tm).to have_received(:put_hands_away).with(engineering)
        expect(tm).not_to have_received(:tool_drop)
        expect(DRCC).not_to have_received(:repair_own_tools)
      end

      it 'puts the hands away and goes nowhere when none is due' do
        tm = repair_with(due: [])
        expect(tm).not_to have_received(:tool_drop)
        expect(tm).to have_received(:put_hands_away).with('alchemy belt')
      end

      it 'sends nothing with task_no_repair, due or not' do
        tm = repair_with(due: %w[mortar pestle sieve], no_repair: true)
        expect(tm).not_to have_received(:tool_drop)
        expect(tm).to have_received(:put_hands_away).with('alchemy belt')
      end

      it 'repairs only the tools due with task_self_repair, and notes them repaired' do
        repair_with(due: %w[mortar], self_repair: true)
        expect(DRCC).to have_received(:repair_own_tools).with(anything, ['mortar'], 'duffel bag', ['pestle'], 'alchemy belt')
        expect(UserVars.taskmaster_repaired_at['mortar']).to be_within(5).of(Time.now.to_i)
      end

      it 'with task_self_repair, repairs and notes only the due tools found carried (DRCI.exists?); a missing one stays due' do
        repair_with(due: %w[mortar pestle], self_repair: true, carried: %w[pestle sieve])
        expect(DRCC).to have_received(:repair_own_tools).with(anything, ['pestle'], 'duffel bag', ['pestle'], 'alchemy belt')
        expect(UserVars.taskmaster_repaired_at.keys).to contain_exactly('sieve', 'pestle')
        expect(DRCI).to have_received(:exists?).twice
      end

      it 'with task_self_repair at interval 0 (every task), hands every tool to repair_own_tools with no TAP and notes none, as before the setting' do
        tm = every({ 'default' => 0 }, self_repair: true, bag_items: %w[pestle sieve])
        # A TAP that finds nothing: were the tools still tapped, none would
        # reach repair_own_tools.
        allow(DRCI).to receive(:exists?).and_return(false)
        allow(tm).to receive(:put_hands_away)
        allow(DRCC).to receive(:repair_own_tools).and_return(nil)
        UserVars.taskmaster_repaired_at = nil

        tm.repair(%w[mortar pestle sieve], 'alchemy belt')

        expect(DRCI).not_to have_received(:exists?)
        expect(DRCC).to have_received(:repair_own_tools)
          .with({ 'finisher-room' => 8776, 'finisher-number' => 6 }, %w[mortar pestle sieve], 'duffel bag', %w[pestle sieve], 'alchemy belt').once
        expect(UserVars.taskmaster_repaired_at).to be_nil
      end

      it "does not note a tool on Lich's immune list: repair_own_tools drops it from the array it is given, in place" do
        tm = every({ 'nezhiri' => 10_800 }, self_repair: true)
        allow(DRCI).to receive(:exists?).and_return(true)
        allow(tm).to receive(:put_hands_away)
        UserVars.taskmaster_repaired_at = { 'sieve' => Time.now.to_i }
        # As lich-5 does it: tools = tools.to_a (the same array), then reject!.
        allow(DRCC).to receive(:repair_own_tools) { |_info, tools, *_rest| tools.to_a.reject! { |tool| tool == 'pestle' } && nil }

        tm.repair(%w[mortar pestle sieve], 'alchemy belt')

        expect(UserVars.taskmaster_repaired_at.keys).to contain_exactly('sieve', 'mortar')
      end

      it 'notes nothing repaired when own repairs stop (engaged), so every tool due is tried again' do
        repair_with(due: %w[mortar pestle], self_repair: true, own_result: :engaged)
        expect(UserVars.taskmaster_repaired_at.keys).to eq(['sieve'])
      end
    end

    describe 'noting a tool repaired when it is left (#tool_drop)' do
      let(:quote) { "Rangu looks over the mortar and says, \"That will cost 240 Kronars to repair.  Just give it to me again if you want, and I'll have it ready in 1 roisaen.\"" }
      let(:ticket) { "You hand Rangu 240 Kronars and he gives you back a repair ticket.  Rangu says, \"I should be having that done for you in about 1 roisaen.  Don't lose this ticket!  You must have it to reclaim your mortar.\"" }

      let(:sent) { [] }

      # Each reply is one line, or an Array of the lines that come in
      # before bput's answer: bput tries every pattern on a line before the
      # next line, and hands back the first match (lich-5 common.rb).
      def drop(*replies, repairer: 'Rangu')
        tm = every({ 'nezhiri' => 10_800 })
        allow(tm).to receive(:repairer_for).and_return({ 'id' => 19_209, 'name' => repairer })
        queue = replies.dup
        allow(DRCT).to receive(:walk_to).and_return(true)
        allow(DRCC).to receive(:get_crafting_item) { $right_hand = 'polished belzune stone mortar' }
        allow(DRCC).to receive(:stow_crafting_item)
        allow(DRC).to receive(:bput) do |command, *matchers|
          sent << command
          next 'You put' if command == 'stow ticket'

          Array(queue.shift).lazy.map { |line| bput_match(line, matchers) }.find { |match| !match.empty? }.to_s
        end
        tm.tool_drop(['mortar'], nil)
        Hash(UserVars.taskmaster_repaired_at)['mortar']
      end

      it 'when the ticket is kept' do
        expect(drop(quote, ticket)).to be_within(5).of(Time.now.to_i)
      end

      it 'when the repairer finds no wear on it, or says it is past repair (the declined answers)' do
        expect(drop("Rangu shrugs and says, \"There isn't a scratch on that, and I'm not one to rob you.\"")).to be_within(5).of(Time.now.to_i)
        UserVars.taskmaster_repaired_at = nil
        expect(drop('Rangu says, "I can\'t fix those.  They only have so many uses and then you must buy another."')).to be_within(5).of(Time.now.to_i)
        UserVars.taskmaster_repaired_at = nil
        expect(drop('A clerk shrugs and says, "There isn\'t a scratch on that, and I\'m not one to rob you."', repairer: 'clerk')).to be_within(5).of(Time.now.to_i)
      end

      # bput hands back the first line any pattern matches, so room speech
      # ahead of the repairer's quote decides the answer; only the
      # repairer's own declined line starts the clock (main's tool_drop put
      # the tool away on any of these, with no clock).
      it 'not on a declined word in room speech ahead of the quote, or a line naming the repairer after the speaker, or one with no speaker' do
        ['Kalak says, "I will not lend you my mortar again."', 'Kalak says to Rangu, "There isn\'t a scratch on that, friend."',
         "Rangu's apprentice says, \"There isn't a scratch on that.\"", "I can't fix those.  They only have so many uses and then you must buy another."].each do |line|
          UserVars.taskmaster_repaired_at = nil
          expect(drop([line, quote])).to be_nil
          expect(sent).to eq(['give Rangu'])
          sent.clear
        end
        expect(DRCC).to have_received(:stow_crafting_item).with('mortar', 'duffel bag', nil).exactly(4).times
        expect(DRC).to have_received(:message).with('Heard "I will not", not as Rangu\'s answer; putting the mortar away, not noted as looked over.')
        expect(DRC).to have_received(:message).with(/\AHeard "There isn't a scratch on that", not as Rangu's answer/).twice
        expect(DRC).to have_received(:message).with(/\AHeard "I can't fix those\.  They only have so many uses/)
      end

      it 'not when the repairer refuses the tool itself, so it goes again after the next task' do
        expect(drop("Rangu says, \"I don't repair those here.\"")).to be_nil
        expect(drop("Rangu says, \"I don't work on those here.\"")).to be_nil
        expect(DRC).to have_received(:message).with("Rangu did not take the mortar (I don't repair those here); putting it away.")
        expect(DRC).to have_received(:message).with("Rangu did not take the mortar (I don't work on those here); putting it away.")
      end

      it 'not when nobody looked at it (no repairer there, no answer) or no ticket came (short of coin)' do
        expect(drop(missed_give)).to be_nil
        expect(drop('')).to be_nil
        expect(drop(quote, 'Rangu says, "You will need more coin if I am to be repairing that!"')).to be_nil
      end
    end

    describe 'the warning at the start of a run that repairs (#warn_repair_intervals)' do
      def warned(setting, npc: 'nezhiri', fallback: 'zasele', **ivars)
        tm = build(settings: { task_repair_every: setting }, npc: npc, fallback_npc: fallback, **ivars)
        tm.warn_repair_intervals
        tm
      end

      it 'names the taskmaster asked and the fallback when neither has an entry, with the interval used instead' do
        warned({ 'default' => 0 })
        expect(DRC).to have_received(:message).with('task_repair_every has no entry for nezhiri; its tools go for repair after every task (the default entry).')
        expect(DRC).to have_received(:message).with('task_repair_every has no entry for zasele; its tools go for repair after every task (the default entry).')
        # base.yaml's default key is not taken for a misspelt taskmaster.
        expect(DRC).not_to have_received(:message).with(/misspelling/)
      end

      it 'warns when the setting is not there at all' do
        warned(nil, fallback: '')
        expect(DRC).to have_received(:message).with('task_repair_every has no entry for nezhiri; its tools go for repair after every task.').once
      end

      it 'gives a non-zero default in hours or minutes' do
        warned({ 'default' => 10_800, 'nezhiri' => 10_800 })
        expect(DRC).to have_received(:message).with('task_repair_every has no entry for zasele; its tools go for repair every 3 hours (the default entry).')
        warned({ 'default' => 5400, 'nezhiri' => 10_800 })
        expect(DRC).to have_received(:message).with('task_repair_every has no entry for zasele; its tools go for repair every 90 minutes (the default entry).')
      end

      it 'says nothing when both have an entry, or with task_no_repair' do
        warned({ 'nezhiri' => 10_800, 'zasele' => 43_200 })
        warned({}, no_repair: true)
        expect(DRC).not_to have_received(:message)
      end

      it 'leaves out the fallback in marathon, which never falls back' do
        warned({ 'zasele' => 43_200 }, npc: 'zasele', fallback: 'nezhiri', marathon: true)
        expect(DRC).not_to have_received(:message)
      end

      it 'says the fallback is not worked during repairs while either taskmaster lacks an entry' do
        warned({ 'nezhiri' => 10_800 })
        expect(DRC).to have_received(:message).with("No Zasele task is worked while Nezhiri's tools are at repair until task_repair_every has entries for both (and Nezhiri's is more than 0).")
        warned({ 'nezhiri' => 10_800 }, fallback: '')
        expect(DRC).to have_received(:message).with(/No Zasele task/).once
      end

      it 'names a key that is neither default nor a taskmaster (a misspelling)' do
        warned({ 'nezhri' => 10_800, 'nezhiri' => 10_800, 'zasele' => 43_200 })
        expect(DRC).to have_received(:message).with('task_repair_every names nezhri, which is not a taskmaster (poltu, bradyn, zasele, dorhum, nezhiri); a misspelling?')
      end

      it 'says nothing about the fallback during repairs with task_self_repair, which never detours' do
        warned({ 'nezhiri' => 10_800 }, self_repair: true)
        expect(DRC).not_to have_received(:message).with(/No Zasele task/)
      end

      it 'counts a blank entry as none' do
        warned({ 'nezhiri' => nil, 'zasele' => 43_200 })
        expect(DRC).to have_received(:message).with('task_repair_every has no entry for nezhiri; its tools go for repair after every task.')
        expect(DRC).not_to have_received(:message).with(/is not a whole number/)
      end

      it 'names the three taskmasters cycle picks from' do
        tm = build(settings: { task_repair_every: { 'zasele' => 0 } }, npc: nil)
        tm.warn_repair_intervals(%w[poltu bradyn zasele])
        expect(DRC).to have_received(:message).with(/no entry for poltu/)
        expect(DRC).to have_received(:message).with(/no entry for bradyn/)
        expect(DRC).not_to have_received(:message).with(/no entry for zasele/)
      end

      # A cycle run starts with no taskmaster named (args.npc is nil) and
      # detours all the same.
      it 'in cycle, names the picks whose tools bring no detour for want of an entry, leaving out the fallback itself' do
        tm = build(settings: { task_repair_every: { 'zasele' => 43_200, 'poltu' => 10_800 } }, npc: nil, fallback_npc: 'zasele')
        tm.warn_repair_intervals(%w[poltu bradyn zasele])
        expect(DRC).to have_received(:message).with("No Zasele task is worked while Bradyn's tools are at repair until task_repair_every has entries for both (and Bradyn's is more than 0).")
      end

      it 'in cycle, names every pick when the fallback has no entry' do
        tm = build(settings: { task_repair_every: { 'poltu' => 10_800, 'bradyn' => 10_800, 'zasele' => 43_200 } }, npc: nil, fallback_npc: 'nezhiri')
        tm.warn_repair_intervals(%w[poltu bradyn zasele])
        expect(DRC).to have_received(:message).with("No Nezhiri task is worked while Poltu's, Bradyn's or Zasele's tools are at repair until task_repair_every has entries for Nezhiri and each of them (theirs more than 0).")
      end

      it 'in cycle, leaves the fallback out of the picks it names when it is one of them and has no entry' do
        tm = build(settings: { task_repair_every: { 'poltu' => 10_800, 'bradyn' => 10_800 } }, npc: nil, fallback_npc: 'zasele')
        tm.warn_repair_intervals(%w[poltu bradyn zasele])
        expect(DRC).to have_received(:message).with("No Zasele task is worked while Poltu's or Bradyn's tools are at repair until task_repair_every has entries for Zasele and each of them (theirs more than 0).")
      end
    end
  end

  describe "working the fallback's task while the tools are at repair" do
    let(:offer) { 'You may accept by typing ACCEPT TASK.' }
    let(:rope_task) { ['rope', 2, 4, 'cloth', 'burlap'] }
    let(:daily_max) { '[You have reached the maximum number of TASKs you may complete for Zasele today.  Please try again tomorrow.]' }

    # Notes a tool of each taskmaster left for repair, ago seconds before now.
    def noted(*npcs, ago: 60)
      UserVars.taskmaster_repairs = npcs.map { |npc| { 'npc' => npc, 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => "#{npc} tool", 'item' => "#{npc} tool", 'left_at' => Time.now.to_i - ago } }
    end

    # The real collect_task_tools, down to each repairer's visit: no Rangu
    # ticket carried, the repair replies known, and each task using its
    # taskmaster's noted tool (noted's 'nezhiri tool', or a mortar; noted's
    # 'zasele tool', or scissors). Each visit (collect_tools) yields the notes
    # it waits for, and leaves the notes as they are.
    def stub_pickup(tm, &visit)
      uses = { 'nezhiri' => ['nezhiri tool', 'mortar'], 'zasele' => ['zasele tool', 'scissors'] }
      allow(tm).to receive(:task_tools) { |npc, _task| uses.fetch(npc) }
      allow(tm).to receive(:rangu_ticket_carried?).and_return(false)
      allow(tm).to receive(:repair_replies_known?).and_return(true)
      allow(tm).to receive(:collect_tools) do |_room, _name, records, **|
        visit&.call(records)
        []
      end
    end

    # One pass of run_tasks, with the real get_task asking from asks (per
    # taskmaster, in order). Returns the steps: asks, pickups, work.
    def detour_run(npc: 'nezhiri', fallback: 'zasele', asks: {}, every: { 'nezhiri' => 10_800, 'zasele' => 43_200 }, **ivars)
      tm = build(npc: npc, fallback_npc: fallback, cooldown_poll: 3, settings: { task_repair_every: every }, **ivars)
      events = []
      allow(tm).to receive(:reconcile_hands)
      allow(tm).to receive(:prepare_for_task)
      allow(tm).to receive(:find_npc)
      allow(tm).to receive(:pause)
      allow(DRC).to receive(:bput) do |command, *matchers|
        if (ask = command.match(/\Aask (\w+) for task\z/))
          events << [:ask, ask[1]]
          # One ask's lines: what bput returns is the first a matcher takes.
          lines = asks.fetch(ask[1]).shift || raise("asked #{ask[1]} again")
          Array(lines).map { |line| bput_match(line, matchers) }.find { |reply| !reply.empty? }.to_s
        elsif command == 'accept task'
          'You can check your progress with the TASK verb.'
        else
          ''
        end
      end
      allow(tm).to receive(:finish) { rope_task }
      stub_pickup(tm) { |records| events << [:tool_pickup, records.first['npc']] }
      %i[zasele nezhiri].each { |giver| allow(tm).to receive(giver) { events << [:work, giver] } }
      allow(tm).to receive(:complete_task) { events << [:complete, tm.instance_variable_get(:@npc)] }
      tm.run_tasks(OpenStruct.new)
      [events, tm]
    end

    it "does not detour for a note whose confirming give went unanswered ('ticketed' false: the tool may still be carried), but does for one whose ticket came" do
      noted('nezhiri')
      UserVars.taskmaster_repairs = UserVars.taskmaster_repairs.map { |record| record.merge('ticketed' => false) }
      events, = detour_run(asks: { 'nezhiri' => [offer] })
      expect(events.first).to eq([:ask, 'nezhiri'])

      noted('nezhiri')
      UserVars.taskmaster_repairs = UserVars.taskmaster_repairs.map { |record| record.merge('ticketed' => true) }
      events, = detour_run(asks: { 'zasele' => [offer] })
      expect(events.first).to eq([:ask, 'zasele'])
    end

    it "works one of the fallback's tasks, picking up nothing, when the first one's tools are at repair" do
      noted('nezhiri')
      events, tm = detour_run(asks: { 'zasele' => [offer] })

      expect(events).to eq([[:ask, 'zasele'], [:work, :zasele], [:complete, 'zasele']])
      expect(DRC).to have_received(:message).with("Nezhiri's tools are at repair; working one of Zasele's tasks meanwhile (the next run asks Nezhiri again).")
      expect(tm.instance_variable_get(:@npc)).to eq('nezhiri')
    end

    it 'works the other way round too' do
      noted('zasele')
      events, = detour_run(npc: 'zasele', fallback: 'nezhiri', asks: { 'nezhiri' => [offer] })

      expect(events).to eq([[:ask, 'nezhiri'], [:work, :nezhiri], [:complete, 'nezhiri']])
    end

    it "asks the first one and waits for its tools when the fallback's are at repair too" do
      noted('nezhiri', 'zasele')
      events, = detour_run(asks: { 'nezhiri' => [offer] })

      expect(events).to eq([[:ask, 'nezhiri'], [:tool_pickup, 'nezhiri'], [:work, :nezhiri], [:complete, 'nezhiri']])
    end

    it 'asks the first one and waits for its tools with no fallback set' do
      noted('nezhiri')
      events, = detour_run(fallback: '', asks: { 'nezhiri' => [offer] })

      expect(events).to eq([[:ask, 'nezhiri'], [:tool_pickup, 'nezhiri'], [:work, :nezhiri], [:complete, 'nezhiri']])
    end

    it 'does not switch with task_self_repair, which leaves nothing at a repairer' do
      noted('nezhiri')
      events, = detour_run(self_repair: true, asks: { 'nezhiri' => [offer] })

      expect(events).to eq([[:ask, 'nezhiri'], [:work, :nezhiri], [:complete, 'nezhiri']])
    end

    it 'asks the first one again, and waits for its tools, when the fallback has given all its tasks today' do
      noted('nezhiri')
      events, = detour_run(asks: { 'zasele' => [daily_max], 'nezhiri' => [offer] })

      expect(events).to eq([[:ask, 'zasele'], [:ask, 'nezhiri'], [:tool_pickup, 'nezhiri'], [:work, :nezhiri], [:complete, 'nezhiri']])
      expect(DRC).to have_received(:message).with('Zasele has given you all the tasks allowed today; asking Nezhiri again, whose tools are at repair.')
    end

    # A running clock at midday UTC, away from the game day's turn and its
    # reset grace (RESET_GRACE_SECONDS), for examples that note a limit at
    # Time.now and expect it to hold: run within minutes after 05:00 or
    # 06:00 UTC, such a note lapses at once by design.
    def midday_clock
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      allow(Time).to receive(:now) { Time.utc(2026, 11, 20, 12) + (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) }
    end

    it 'stops when both have given all their tasks today, without asking the fallback again' do
      midday_clock
      noted('nezhiri')
      expect do
        detour_run(asks: { 'zasele' => [daily_max], 'nezhiri' => [daily_max.sub('Zasele', 'Nezhiri')] })
      end.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('Nezhiri has given you all the tasks allowed today, and so did Zasele (task_fallback_npc) earlier this game day (the limit resets at midnight US Central). Stopping.')
    end

    # A fallback note older than REPAIR_READY_SECONDS may be one a pickup
    # already failed on (two tickets fit it, the ticket was refused): a
    # detour would open a fallback task that stops on it, and every run
    # after would finish that task as the fallback's and stop again. A note
    # does not say which, so any note holds the detour back, one left later
    # than now (the clock set back) too.
    it "is held back by the fallback's tools still at repair however long ago they were left, or left later than now" do
      [3600, 7200, 86_400, -3600].each do |ago|
        noted('nezhiri')
        UserVars.taskmaster_repairs += [{ 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'scissors', 'item' => 'scissors', 'left_at' => Time.now.to_i - ago }]
        # 'zasele' => []: a detour would raise "asked zasele again".
        events, = detour_run(asks: { 'nezhiri' => [offer], 'zasele' => [] })

        expect(events).to eq([[:ask, 'nezhiri'], [:tool_pickup, 'nezhiri'], [:work, :nezhiri], [:complete, 'nezhiri']]), "left #{ago} s ago"
        expect(UserVars.taskmaster_repairs.first).not_to have_key('detoured')
      end
    end

    it "is held back by the fallback's tools left in the last 10 minutes" do
      noted('nezhiri')
      UserVars.taskmaster_repairs += [{ 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'scissors', 'item' => 'scissors', 'left_at' => Time.now.to_i - 60 }]
      events, = detour_run(asks: { 'nezhiri' => [offer] })

      expect(events.first).to eq([:ask, 'nezhiri'])
    end

    it 'works the fallback once per leaving: the run after asks the first one and collects its tools' do
      noted('nezhiri')
      first, = detour_run(asks: { 'zasele' => [offer] })
      second, = detour_run(asks: { 'nezhiri' => [offer] })

      expect(first).to eq([[:ask, 'zasele'], [:work, :zasele], [:complete, 'zasele']])
      expect(second).to eq([[:ask, 'nezhiri'], [:tool_pickup, 'nezhiri'], [:work, :nezhiri], [:complete, 'nezhiri']])
      expect(UserVars.taskmaster_repairs.first).to include('detoured' => true)
    end

    it 'works the fallback again when more tools are left later' do
      noted('nezhiri')
      detour_run(asks: { 'zasele' => [offer] })
      UserVars.taskmaster_repairs += [{ 'npc' => 'nezhiri', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'mortar', 'item' => 'stone mortar', 'left_at' => Time.now.to_i }]
      events, = detour_run(asks: { 'zasele' => [offer] })

      expect(events.first).to eq([:ask, 'zasele'])
    end

    it 'leaves a fallback set only for the daily limit alone: no detour without task_repair_every entries for both (default does not stand in for the first one\'s), or with 0 for the first one' do
      noted('nezhiri')
      [{ 'default' => 10_800 }, { 'nezhiri' => 10_800 }, {}, { 'nezhiri' => 0, 'zasele' => 0 },
       { 'zasele' => 43_200 }, { 'zasele' => 43_200, 'default' => 10_800 }].each do |every|
        # 'zasele' => []: a detour would raise "asked zasele again".
        events, = detour_run(every: every, asks: { 'nezhiri' => [offer], 'zasele' => [] })
        expect(events.first).to eq([:ask, 'nezhiri']), every.inspect
      end
    end

    # The re-audit's case: Zasele's 'steel scissors' left two hours ago, and
    # the pickup keeps the note (two tickets fit it). Each run asks Nezhiri
    # and works her task, the note still out after each; a detour would have
    # opened a Zasele task that stops before its work on the scissors.
    it "keeps working the first one's tasks, run after run, while a fallback note a pickup could not settle stays out" do
      scissors = { 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'scissors', 'item' => 'steel scissors', 'left_at' => Time.now.to_i - 7200 }
      2.times do |run|
        noted('nezhiri')
        UserVars.taskmaster_repairs += [scissors]
        events, = detour_run(asks: { 'nezhiri' => [offer], 'zasele' => [] })

        expect(events).to eq([[:ask, 'nezhiri'], [:tool_pickup, 'nezhiri'], [:work, :nezhiri], [:complete, 'nezhiri']]), "run #{run + 1}"
        expect(UserVars.taskmaster_repairs).to include(scissors)
      end
      expect(DRC).not_to have_received(:message).with(/working one of Zasele's tasks meanwhile/)
    end

    it 'does not ask the fallback again, in this run or the next, until the daily rollover after it gave its limit' do
      # Away from the day's turn (06:00 UTC in November), so a minute back is the same game day.
      allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 20, 12))
      noted('nezhiri')
      UserVars.taskmaster_capped = { 'zasele' => Time.now.to_i - 60 }
      events, = detour_run(asks: { 'nezhiri' => [offer] })

      expect(events.first).to eq([:ask, 'nezhiri'])
    end

    it 'asks the fallback when its limit note is later than now (written while the clock was fast)' do
      noted('nezhiri')
      UserVars.taskmaster_capped = { 'zasele' => Time.now.to_i + 86_400 }
      events, = detour_run(asks: { 'zasele' => [offer] })

      expect(events.first).to eq([:ask, 'zasele'])
    end

    it 'notes the limit of a fallback worked for the day, so the next run stops at the first one without walking to it' do
      midday_clock
      nezhiri_max = daily_max.sub('Zasele', 'Nezhiri')
      expect { detour_run(asks: { 'nezhiri' => [nezhiri_max], 'zasele' => [daily_max] }) }.to raise_error(SystemExit)
      expect(UserVars.taskmaster_capped['zasele']).to be_within(5).of(Time.now.to_i)

      # 'zasele' => []: asking Zasele again would raise "asked zasele again".
      expect { detour_run(asks: { 'nezhiri' => [nezhiri_max], 'zasele' => [] }) }.to raise_error(SystemExit)
      expect(DRC).to have_received(:message).with('Nezhiri has given you all the tasks allowed today, and so did Zasele (task_fallback_npc) earlier this game day (the limit resets at midnight US Central). Stopping.')
    end

    it "keeps the fallback's limit until midnight US Central, not an hour early (#game_day_turned_since?)" do
      tm = build
      at = ->(*args) { allow(Time).to receive(:now).and_return(Time.utc(*args)) }
      # November, standard time: the day turns at 06:00 UTC.
      noted = Time.utc(2026, 11, 20, 4, 59).to_i
      at.call(2026, 11, 20, 5, 1)
      expect(tm.game_day_turned_since?(noted)).to be(false)
      at.call(2026, 11, 20, 5, 59)
      expect(tm.game_day_turned_since?(noted)).to be(false)
      at.call(2026, 11, 20, 6, 0)
      expect(tm.game_day_turned_since?(noted)).to be(true)
      # After the turn, the next one is a day later.
      at.call(2026, 11, 21, 5, 59)
      expect(tm.game_day_turned_since?(Time.utc(2026, 11, 20, 6, 30).to_i)).to be(false)
      # July, daylight time: 05:00 UTC.
      at.call(2026, 7, 4, 5, 0)
      expect(tm.game_day_turned_since?(Time.utc(2026, 7, 4, 4, 59).to_i)).to be(true)
      # The changeover days: midnight still on the old offset.
      at.call(2026, 3, 8, 5, 30)
      expect(tm.game_day_turned_since?(Time.utc(2026, 3, 8, 4, 0).to_i)).to be(false)
      at.call(2026, 11, 1, 5, 0)
      expect(tm.game_day_turned_since?(Time.utc(2026, 11, 1, 4, 0).to_i)).to be(true)
      # The day after each change: the first daylight-time midnight (05:00
      # UTC on 2026-03-09) and the first standard-time one (06:00 UTC on
      # 2026-11-02). A rule a day or a month off at either end fails here.
      at.call(2026, 3, 9, 4, 59)
      expect(tm.game_day_turned_since?(Time.utc(2026, 3, 9, 3, 0).to_i)).to be(false)
      at.call(2026, 3, 9, 5, 0)
      expect(tm.game_day_turned_since?(Time.utc(2026, 3, 9, 3, 0).to_i)).to be(true)
      at.call(2026, 11, 2, 5, 59)
      expect(tm.game_day_turned_since?(Time.utc(2026, 11, 2, 4, 0).to_i)).to be(false)
      at.call(2026, 11, 2, 6, 0)
      expect(tm.game_day_turned_since?(Time.utc(2026, 11, 2, 4, 0).to_i)).to be(true)
    end

    # The game resets the limit some seconds after the turn (Nezhiri's limit
    # at 06:00:07 UTC on 2026-11-19, her first offers at 06:00:41): a limit
    # given in the first RESET_GRACE_SECONDS after it is the old day's.
    it 'counts a limit given in the minutes just after the turn as the old day\'s, one given later as the new day\'s (RESET_GRACE_SECONDS)' do
      tm = build
      at = ->(*args) { allow(Time).to receive(:now).and_return(Time.utc(*args)) }
      # November, standard time: the day turns at 06:00 UTC.
      just_after = Time.utc(2026, 11, 20, 6, 0, 20).to_i
      later = Time.utc(2026, 11, 20, 6, 10).to_i
      at.call(2026, 11, 20, 6, 10)
      expect(tm.game_day_turned_since?(just_after)).to be(true)
      at.call(2026, 11, 20, 16, 0)
      expect(tm.game_day_turned_since?(just_after)).to be(true)
      expect(tm.game_day_turned_since?(later)).to be(false)
      at.call(2026, 11, 21, 5, 59)
      expect(tm.game_day_turned_since?(later)).to be(false)
      at.call(2026, 11, 21, 6, 0)
      expect(tm.game_day_turned_since?(later)).to be(true)
      # The edge, 5 minutes (RESET_GRACE_SECONDS) after the turn: a note in
      # the last second of the grace is the old day's (not capped), one at
      # its end the new day's (capped until the next turn).
      last_grace = Time.utc(2026, 11, 20, 6, 4, 59).to_i
      grace_over = Time.utc(2026, 11, 20, 6, 5, 0).to_i
      at.call(2026, 11, 20, 16, 0)
      expect(tm.game_day_turned_since?(last_grace)).to be(true)
      expect(tm.game_day_turned_since?(grace_over)).to be(false)
      at.call(2026, 11, 21, 5, 59, 59)
      expect(tm.game_day_turned_since?(grace_over)).to be(false)
      at.call(2026, 11, 21, 6, 0)
      expect(tm.game_day_turned_since?(grace_over)).to be(true)
      # July, daylight time: 05:00 UTC.
      at.call(2026, 7, 4, 5, 10)
      expect(tm.game_day_turned_since?(Time.utc(2026, 7, 4, 5, 0, 20).to_i)).to be(true)
      expect(tm.game_day_turned_since?(Time.utc(2026, 7, 4, 5, 6).to_i)).to be(false)
    end

    it 'asks the fallback later the same day when its limit came in the seconds after the turn, before the game had reset' do
      nezhiri_max = daily_max.sub('Zasele', 'Nezhiri')
      allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 20, 6, 0, 20))
      UserVars.taskmaster_capped = { 'zasele' => Time.utc(2026, 11, 20, 4, 30).to_i }
      expect { detour_run(asks: { 'nezhiri' => [nezhiri_max], 'zasele' => [daily_max] }) }.to raise_error(SystemExit)
      expect(UserVars.taskmaster_capped['zasele']).to eq(Time.now.to_i)

      allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 20, 16, 0))
      events, = detour_run(asks: { 'nezhiri' => [nezhiri_max], 'zasele' => [offer] })

      expect(events).to eq([[:ask, 'nezhiri'], [:ask, 'zasele'], [:work, :zasele], [:complete, 'zasele']])
    end

    it 'saves the limit note at once, once written (a crash must not lose it, or the next run walks to the capped fallback)' do
      allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 20, 12))
      saved = []
      stub_const('Vars', double('Vars'))
      allow(Vars).to receive(:save) { saved << UserVars.taskmaster_capped }

      build.note_capped('zasele')

      expect(saved).to eq([{ 'zasele' => Time.now.to_i }])
    end

    it 'saves the detoured marks at once, once written (a crash must not lose them, or the next run detours again for the same tools)' do
      noted('nezhiri')
      saved = []
      stub_const('Vars', double('Vars'))
      allow(Vars).to receive(:save) { saved << UserVars.taskmaster_repairs.map { |record| record['detoured'] } }

      build.mark_detoured(UserVars.taskmaster_repairs)

      expect(saved).to eq([[true]])
    end

    it 'counts a limit noted at 04:59 UTC in November as holding at 05:01 (fallback_capped?)' do
      allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 20, 5, 1))
      UserVars.taskmaster_capped = { 'zasele' => Time.utc(2026, 11, 20, 4, 59).to_i }

      expect(build.fallback_capped?('zasele')).to be(true)
    end

    # UserVars keeps whatever value it is given (lich-5 Vars checks no
    # type), so a hand-set taskmaster_capped of the wrong kind persists.
    it 'notes a limit over a taskmaster_capped of the wrong kind (a String set by hand), keeping no junk (#note_capped)' do
      allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 20, 12))
      UserVars.taskmaster_capped = 'x'

      build.note_capped('zasele')

      expect(UserVars.taskmaster_capped).to eq({ 'zasele' => Time.now.to_i })
    end

    it 'counts no limit for a note that is not epoch seconds (a String timestamp set by hand) (#fallback_capped?)' do
      allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 20, 12))
      UserVars.taskmaster_capped = { 'zasele' => (Time.now.to_i - 60).to_s }

      expect(build.fallback_capped?('zasele')).to be(false)
    end

    it 'asks the fallback again once a daily rollover has passed since its limit' do
      noted('nezhiri')
      UserVars.taskmaster_capped = { 'zasele' => Time.now.to_i - (2 * 86_400) }
      events, = detour_run(asks: { 'zasele' => [offer] })

      expect(events.first).to eq([:ask, 'zasele'])
    end

    it 'reads on past a player saying the fallback\'s limit line during a detour, works its task, and notes no limit' do
      noted('nezhiri')
      events, = detour_run(asks: { 'zasele' => [[%(Mags says, "#{daily_max}"), offer]] })

      expect(events).to eq([[:ask, 'zasele'], [:work, :zasele], [:complete, 'zasele']])
      expect(UserVars.taskmaster_capped).to be_nil
    end

    it 'notes the limit, with the time, when the fallback gives it during a detour' do
      noted('nezhiri')
      detour_run(asks: { 'zasele' => [daily_max], 'nezhiri' => [offer] })

      expect(UserVars.taskmaster_capped['zasele']).to be_within(5).of(Time.now.to_i)
    end

    # REPAIR_READY_SECONDS is 600: the literal seconds here pin the value
    # as well as the edge. The clock stands still so the note's age is exact.
    it 'does not detour for tools left long enough ago to be ready (600 s or more, overnight): it asks the first one and collects them' do
      allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 20, 12))
      [600, 601, 86_400].each do |ago|
        noted('nezhiri', ago: ago)
        # 'zasele' => []: a detour would raise "asked zasele again".
        events, = detour_run(asks: { 'nezhiri' => [offer], 'zasele' => [] })

        expect(events).to eq([[:ask, 'nezhiri'], [:tool_pickup, 'nezhiri'], [:work, :nezhiri], [:complete, 'nezhiri']]), "left #{ago} s ago"
        expect(UserVars.taskmaster_repairs.first).not_to have_key('detoured')
      end
    end

    it 'detours for tools left from 0 to 599 s ago (#just_left?)' do
      allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 20, 12))
      [0, 599].each do |ago|
        noted('nezhiri', ago: ago)
        events, = detour_run(asks: { 'zasele' => [offer] })

        expect(events).to eq([[:ask, 'zasele'], [:work, :zasele], [:complete, 'zasele']]), "left #{ago} s ago"
        expect(UserVars.taskmaster_repairs.first).to include('detoured' => true)
      end
    end

    # A note left later than now (the Lich clock set back since, say by an
    # NTP correction) is of unknown age: just_left? counts it as long ago,
    # so the run asks the first one and its pickup collects the tools.
    it "does not count the first one's tools left later than now (the clock set back) as just left" do
      allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 20, 12))
      [-1, -120].each do |ago|
        noted('nezhiri', ago: ago)
        # 'zasele' => []: a detour would raise "asked zasele again".
        events, = detour_run(asks: { 'nezhiri' => [offer], 'zasele' => [] })

        expect(events).to eq([[:ask, 'nezhiri'], [:tool_pickup, 'nezhiri'], [:work, :nezhiri], [:complete, 'nezhiri']]), "left #{-ago} s from now"
        expect(UserVars.taskmaster_repairs.first).not_to have_key('detoured')
      end
    end

    it 'with repeat, does not walk to the fallback again in the run once it has given its daily limit' do
      midday_clock
      noted('nezhiri')
      tm = build(npc: 'nezhiri', fallback_npc: 'zasele', cooldown_poll: 3, settings: { task_repair_every: { 'nezhiri' => 10_800, 'zasele' => 43_200 } })
      asks = []
      replies = { 'zasele' => [daily_max], 'nezhiri' => [offer, offer] }
      completed = 0
      allow(tm).to receive(:reconcile_hands)
      allow(tm).to receive(:prepare_for_task)
      allow(tm).to receive(:find_npc)
      allow(tm).to receive(:pause)
      allow(tm).to receive(:finish) { rope_task }
      stub_pickup(tm)
      allow(DRC).to receive(:bput) do |command, *_|
        if (ask = command.match(/\Aask (\w+) for task\z/))
          asks << ask[1]
          replies.fetch(ask[1]).shift || raise("asked #{ask[1]} again")
        else
          'You can check your progress with the TASK verb.'
        end
      end
      # Each Nezhiri task leaves more tools for repair.
      allow(tm).to receive(:nezhiri) { UserVars.taskmaster_repairs += [{ 'npc' => 'nezhiri', 'tool' => 'mortar', 'item' => 'mortar', 'repairer' => 'Rangu', 'room' => 19_209, 'left_at' => Time.now.to_i }] }
      allow(tm).to receive(:complete_task) do
        completed += 1
        Flags['wrap-up'] = true if completed == 2
      end

      tm.run_tasks(OpenStruct.new(repeat: true))

      expect(asks).to eq(%w[zasele nezhiri nezhiri])
    end

    # run_tasks: in cycle, the task after the detour goes to a taskmaster
    # picked at random (here Poltu), not back to the first one.
    it 'in a cycle run, says the next taskmaster is picked as usual, not that the first one is asked next' do
      noted('zasele')
      tm = build(npc: 'zasele', fallback_npc: 'nezhiri', cooldown_poll: 3, settings: { task_repair_every: { 'zasele' => 43_200, 'nezhiri' => 10_800 } })
      asks = []
      replies = { 'nezhiri' => [offer], 'poltu' => [offer] }
      completed = 0
      allow(tm).to receive(:reconcile_hands)
      allow(tm).to receive(:prepare_for_task)
      allow(tm).to receive(:find_npc)
      allow(tm).to receive(:pause)
      allow(tm).to receive(:finish) { rope_task }
      allow(tm).to receive(:task_tools).and_return([])
      allow(tm).to receive(:collect_task_tools)
      allow(DRC).to receive(:bput) do |command, *matchers|
        if (ask = command.match(/\Aask (\w+) for task\z/))
          asks << ask[1]
          bput_match(replies.fetch(ask[1]).shift || raise("asked #{ask[1]} again"), matchers)
        else
          'You can check your progress with the TASK verb.'
        end
      end
      %i[nezhiri poltu].each { |giver| allow(tm).to receive(giver) }
      allow(tm).to receive(:complete_task) do
        completed += 1
        Flags['wrap-up'] = true if completed == 2
      end
      allow_any_instance_of(Array).to receive(:sample) { |list| list == %w[poltu bradyn zasele] ? 'poltu' : raise("sampled #{list}") }

      tm.run_tasks(OpenStruct.new(cycle: true))

      expect(asks).to eq(%w[nezhiri poltu])
      expect(DRC).to have_received(:message).with("Zasele's tools are at repair; working one of Nezhiri's tasks meanwhile (cycle then picks a taskmaster as usual, and the next task that uses Zasele's tools collects them).")
      expect(DRC).not_to have_received(:message).with(/the next run asks Zasele again/)
    end

    # A cycle detour (Poltu -> Nezhiri) finds a task of Bradyn's open, which
    # check_task_giver takes as the cycle's own. Its instructions turn out
    # short, so cancel_short_task (on by default) throws
    # FOREIGN_TASK_CANCELLED: resume_task stands in for that here, the real
    # check_task_giver first. get_task then asks Bradyn, who has given his
    # limit: the run falls back to Nezhiri, not to Poltu, whose tools the
    # detour was for.
    it "in a cycle run, falls back as usual, not to the first one's tools at repair, after a cycled taskmaster's open task found on a detour is cancelled" do
      allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 20, 12))
      hammer = { 'npc' => 'poltu', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'hammer', 'item' => 'forging hammer', 'left_at' => Time.now.to_i - 60 }
      UserVars.taskmaster_repairs = [hammer]
      tm = build(npc: 'poltu', cycle: true, fallback_npc: 'nezhiri', cooldown_poll: 3,
                 settings: { task_repair_every: { 'poltu' => 10_800, 'nezhiri' => 10_800 }, forging_tools: ['hammer'] })
      asks = []
      replies = { 'nezhiri' => ['You are already on a task.', offer], 'bradyn' => [daily_max.sub('Zasele', 'Bradyn')] }
      allow(tm).to receive(:find_npc)
      allow(tm).to receive(:pause)
      allow(tm).to receive(:finish) { rope_task }
      allow(tm).to receive(:resume_task) do
        tm.instance_variable_set(:@task_giver, 'bradyn')
        tm.check_task_giver
        throw TaskMaster::FOREIGN_TASK_CANCELLED
      end
      allow(DRC).to receive(:bput) do |command, *matchers|
        if (ask = command.match(/\Aask (\w+) for task\z/))
          asks << ask[1]
          bput_match(replies.fetch(ask[1]).shift || raise("asked #{ask[1]} again"), matchers)
        else
          'You can check your progress with the TASK verb.'
        end
      end

      tm.detour_while_tools_repair(cycle: true)

      expect(tm.get_task).to eq(rope_task)
      expect(asks).to eq(%w[nezhiri bradyn nezhiri])
      expect(UserVars.taskmaster_capped).to eq({ 'bradyn' => Time.now.to_i })
      expect(DRC).to have_received(:message).with("Bradyn has given you all the tasks allowed today; working one of Nezhiri's instead (the next run asks Bradyn again).")
      expect(DRC).not_to have_received(:message).with(/asking Poltu again/)
    end

    it "does not detour Poltu's run to Bradyn for the forging tools Bradyn's task left, fresh or long ready (shared tools)" do
      tm_settings = { task_repair_every: { 'poltu' => 10_800, 'bradyn' => 10_800 }, forging_tools: ['forging hammer', 'tongs'] }
      hammer = { 'npc' => 'bradyn', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'forging hammer', 'item' => 'steel forging hammer', 'left_at' => Time.now.to_i - 60 }
      UserVars.taskmaster_repairs = [hammer]
      tm = build(npc: 'poltu', fallback_npc: 'bradyn', settings: tm_settings)

      tm.detour_while_tools_repair

      expect(tm.instance_variable_get(:@npc)).to eq('poltu')
      hammer['left_at'] = Time.now.to_i - 3600
      UserVars.taskmaster_repairs = [hammer]
      tm = build(npc: 'poltu', fallback_npc: 'bradyn', settings: tm_settings)

      tm.detour_while_tools_repair

      expect(tm.instance_variable_get(:@npc)).to eq('poltu')
    end

    describe 'Poltu and Bradyn, who share the forging tools' do
      let(:smith_settings) { { task_repair_every: { 'poltu' => 10_800, 'bradyn' => 10_800 }, forging_tools: ['forging hammer', 'tongs'], shaping_tools: ['drawknife', 'rasp'] } }

      def smith_note(npc, tool, item)
        { 'npc' => npc, 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => tool, 'item' => item, 'left_at' => Time.now.to_i - 60 }
      end

      # A detour into a task that needs the tools at repair would wait for
      # them there, or stop with that task open.
      it "does not detour Poltu's run to Bradyn for the forging tools Poltu's own task left: a metal task of Bradyn's would need them" do
        UserVars.taskmaster_repairs = [smith_note('poltu', 'tongs', 'steel tongs')]
        tm = build(npc: 'poltu', fallback_npc: 'bradyn', settings: smith_settings)

        tm.detour_while_tools_repair

        expect(tm.instance_variable_get(:@npc)).to eq('poltu')
        expect(UserVars.taskmaster_repairs.first).not_to have_key('detoured')
      end

      it "does not detour Bradyn's run to Poltu after a task that left a forging tool" do
        UserVars.taskmaster_repairs = [smith_note('bradyn', 'tongs', 'steel tongs')]
        tm = build(npc: 'bradyn', fallback_npc: 'poltu', settings: smith_settings)

        tm.detour_while_tools_repair

        expect(tm.instance_variable_get(:@npc)).to eq('bradyn')
      end

      it "detours Bradyn's run to Poltu after a task that left only shaping tools" do
        UserVars.taskmaster_repairs = [smith_note('bradyn', 'drawknife', 'balsa drawknife')]
        tm = build(npc: 'bradyn', fallback_npc: 'poltu', settings: smith_settings)

        tm.detour_while_tools_repair

        expect(tm.instance_variable_get(:@npc)).to eq('poltu')
        expect(tm.instance_variable_get(:@primary_npc)).to eq('bradyn')
      end

      # Poltu's task marks with the stamp too (mark_crafted_goods), so a
      # stamp Bradyn's shaping_tools sent holds back a detour to Poltu even
      # after a task that left no forging tool.
      it "does not detour Bradyn's run to Poltu after a task that left a stamp from its shaping tools, with mark_crafted_goods" do
        settings = smith_settings.merge(shaping_tools: ['drawknife', 'iron stamp'], mark_crafted_goods: true)
        UserVars.taskmaster_repairs = [smith_note('bradyn', 'drawknife', 'balsa drawknife'), smith_note('bradyn', 'iron stamp', 'iron stamp')]
        tm = build(npc: 'bradyn', fallback_npc: 'poltu', settings: settings)

        tm.detour_while_tools_repair

        expect(tm.instance_variable_get(:@npc)).to eq('bradyn')
        expect(UserVars.taskmaster_repairs).to all(satisfy { |record| !record.key?('detoured') })
        tm = build(npc: 'bradyn', fallback_npc: 'poltu', settings: settings.merge(mark_crafted_goods: false))

        tm.detour_while_tools_repair

        expect(tm.instance_variable_get(:@npc)).to eq('poltu')
      end

      # Bradyn's tasks use the forging tools Poltu left, so the detour is
      # for them too; left unmarked, every later Bradyn run in those ten
      # minutes would detour again.
      it "marks another taskmaster's shared tool the detour was for, so the next run asks the first one" do
        UserVars.taskmaster_repairs = [smith_note('poltu', 'tongs', 'steel tongs')]
        settings = smith_settings.merge(task_repair_every: { 'bradyn' => 10_800, 'zasele' => 43_200 })
        first = build(npc: 'bradyn', fallback_npc: 'zasele', settings: settings)

        first.detour_while_tools_repair

        expect(first.instance_variable_get(:@npc)).to eq('zasele')
        expect(UserVars.taskmaster_repairs.first).to include('detoured' => true)
        second = build(npc: 'bradyn', fallback_npc: 'zasele', settings: settings)
        second.detour_while_tools_repair
        expect(second.instance_variable_get(:@npc)).to eq('bradyn')
      end
    end

    # The fallback's tools at repair are matched as its own pickup matches
    # them (tools_left_for with the fallback as the worker): a one-word
    # forging_tools "rod" is the stirring rod, so the imbuement rod a Dorhum
    # task left is not one a Poltu task waits for or stops on, and the
    # stirring rod Poltu left is not Dorhum's imbuement rod.
    it "matches the fallback's tools as the fallback's pickup does: a one-word \"rod\" is not another toolset's imbuement or stirring rod" do
      settings = { task_repair_every: { 'dorhum' => 10_800, 'poltu' => 10_800 }, forging_tools: %w[hammer tongs rod], enchanting_tools: ['augment loop', 'brazier', 'burin', 'imbuement rod'] }
      UserVars.taskmaster_repairs = [{ 'npc' => 'dorhum', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'imbuement rod', 'item' => 'cambrinth imbuement rod', 'left_at' => Time.now.to_i - 60 }]
      tm = build(npc: 'dorhum', fallback_npc: 'poltu', settings: settings)

      tm.detour_while_tools_repair

      expect(tm.instance_variable_get(:@npc)).to eq('poltu')
      UserVars.taskmaster_repairs = [{ 'npc' => 'poltu', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'rod', 'item' => 'iron stirring rod', 'left_at' => Time.now.to_i - 60 }]
      tm = build(npc: 'poltu', fallback_npc: 'dorhum', settings: settings)

      tm.detour_while_tools_repair

      expect(tm.instance_variable_get(:@npc)).to eq('dorhum')
    end

    # With mark_crafted_goods a Poltu task waits for, and stops on, a stamp
    # still at repair by any name a tool setting gives it (marking_tools),
    # here one Bradyn's shaping_tools sent long ago: a detour to Poltu would
    # open a task that stops before its work on it.
    it 'is held back by a stamp at repair that the fallback\'s task marks with (mark_crafted_goods), whatever toolset sent it' do
      settings = { task_repair_every: { 'zasele' => 43_200, 'poltu' => 10_800 }, mark_crafted_goods: true, forging_tools: %w[hammer tongs], shaping_tools: ['drawknife', 'iron stamp'] }
      UserVars.taskmaster_repairs = [{ 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'scissors', 'item' => 'steel scissors', 'left_at' => Time.now.to_i - 60 },
                                     { 'npc' => 'bradyn', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'iron stamp', 'item' => 'iron stamp', 'left_at' => Time.now.to_i - 7200 }]
      tm = build(npc: 'zasele', fallback_npc: 'poltu', settings: settings)

      tm.detour_while_tools_repair

      expect(tm.instance_variable_get(:@npc)).to eq('zasele')
      expect(UserVars.taskmaster_repairs.first).not_to have_key('detoured')
      tm = build(npc: 'zasele', fallback_npc: 'poltu', settings: settings.merge(mark_crafted_goods: false))

      tm.detour_while_tools_repair

      expect(tm.instance_variable_get(:@npc)).to eq('poltu')
    end

    # Bradyn's lumber and metal tasks mark with the stamp too (marking_tools
    # leaves it out only for his stone and stack tasks). The task is not
    # known before the ask, so the hold-back counts it for him: here a stamp
    # Nezhiri's toolset sent long ago, which none of Bradyn's settings names.
    it 'is held back by a stamp at repair when the fallback is Bradyn, whose task is not known before the ask (mark_crafted_goods)' do
      settings = { task_repair_every: { 'zasele' => 43_200, 'bradyn' => 10_800 }, mark_crafted_goods: true, forging_tools: %w[hammer tongs], shaping_tools: %w[drawknife rasp] }
      UserVars.taskmaster_repairs = [{ 'npc' => 'zasele', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'scissors', 'item' => 'steel scissors', 'left_at' => Time.now.to_i - 60 },
                                     { 'npc' => 'nezhiri', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'stamp', 'item' => 'iron stamp', 'left_at' => Time.now.to_i - 7200 }]
      tm = build(npc: 'zasele', fallback_npc: 'bradyn', settings: settings)

      tm.detour_while_tools_repair

      expect(tm.instance_variable_get(:@npc)).to eq('zasele')
      expect(UserVars.taskmaster_repairs.first).not_to have_key('detoured')
      tm = build(npc: 'zasele', fallback_npc: 'bradyn', settings: settings.merge(mark_crafted_goods: false))

      tm.detour_while_tools_repair

      expect(tm.instance_variable_get(:@npc)).to eq('bradyn')
    end

    # Zasele's tasks mark with the stamp as well: sew stops the run when it
    # is not in hand (marking_tools). Here a stamp Poltu's forging_tools sent
    # long ago, which outfitting_tools does not name, holds back a detour to
    # her; without mark_crafted_goods it does not.
    it 'is held back by a stamp at repair when the fallback is Zasele, whose sew stops without it (mark_crafted_goods)' do
      settings = { task_repair_every: { 'nezhiri' => 10_800, 'zasele' => 43_200 }, mark_crafted_goods: true, alchemy_tools: %w[bowl mortar], outfitting_tools: ['scissors', 'sewing needles', 'knitting needles'], forging_tools: ['hammer', 'tongs', 'iron stamp'] }
      UserVars.taskmaster_repairs = [{ 'npc' => 'nezhiri', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'bowl', 'item' => 'stone bowl', 'left_at' => Time.now.to_i - 60 },
                                     { 'npc' => 'poltu', 'repairer' => 'Rangu', 'room' => 19_209, 'tool' => 'iron stamp', 'item' => 'iron stamp', 'left_at' => Time.now.to_i - 7200 }]
      tm = build(npc: 'nezhiri', fallback_npc: 'zasele', settings: settings)

      tm.detour_while_tools_repair

      expect(tm.instance_variable_get(:@npc)).to eq('nezhiri')
      expect(UserVars.taskmaster_repairs.first).not_to have_key('detoured')
      tm = build(npc: 'nezhiri', fallback_npc: 'zasele', settings: settings.merge(mark_crafted_goods: false))

      tm.detour_while_tools_repair

      expect(tm.instance_variable_get(:@npc)).to eq('zasele')
      expect(UserVars.taskmaster_repairs.first).to include('detoured' => true)
    end

    it "marks only the notes the detour was for: another taskmaster's fresh note for tools of its own is left as it was" do
      noted('nezhiri', 'poltu')
      detour_run(asks: { 'zasele' => [offer] })

      nezhiri, poltu = UserVars.taskmaster_repairs
      expect(nezhiri).to include('npc' => 'nezhiri', 'detoured' => true)
      expect(poltu).to include('npc' => 'poltu')
      expect(poltu).not_to have_key('detoured')
    end

    it 'does not detour in a run already switched to the fallback for the day (the one asked is then the fallback), whose own tools went for repair' do
      noted('zasele')
      tm = build(npc: 'zasele', primary_npc: 'nezhiri', fallback_npc: 'zasele', settings: { task_repair_every: { 'nezhiri' => 10_800, 'zasele' => 43_200 } })

      tm.detour_while_tools_repair

      expect(tm.instance_variable_get(:@npc)).to eq('zasele')
      expect(tm.instance_variable_get(:@primary_npc)).to eq('nezhiri')
      expect(UserVars.taskmaster_repairs.first).not_to have_key('detoured')
    end

    # get_task mid-detour: the real ask loop, each ask's reply from asks
    # (per taskmaster, in order; any other ask raises), finish returning
    # what Nezhiri's wait left in @stock_survey.
    def asking_mid_detour(asks, **ivars)
      tm = build(cooldown_poll: 3, **ivars)
      sent = []
      allow(tm).to receive(:find_npc)
      allow(tm).to receive(:pause)
      allow(tm).to receive(:finish) { [:accepted, tm.instance_variable_get(:@npc), tm.instance_variable_get(:@stock_survey)] }
      allow(DRC).to receive(:bput) do |command, *matchers|
        ask = command.match(/\Aask (\w+) for task\z/)
        next 'You can check your progress with the TASK verb.' if command == 'accept task'
        raise "unexpected #{command.inspect}" unless ask && asks.key?(ask[1])

        sent << ask[1]
        bput_match(asks[ask[1]].shift || raise("asked #{ask[1]} again"), matchers)
      end
      [tm, sent]
    end

    it "forgets what Nezhiri's wait found when, worked as the fallback, she gives her limit and the first one is asked again" do
      wait = 'Potion Peddler Nezhiri says, "I am sorry, you must wait before I can give you a task."'
      nezhiri_max = daily_max.sub('Zasele', 'Nezhiri')
      tm, sent = asking_mid_detour({ 'nezhiri' => [wait, nezhiri_max], 'zasele' => [offer] },
                                   npc: 'nezhiri', primary_npc: 'zasele', repair_detour: true, fallback_npc: 'nezhiri')
      allow(tm).to receive(:nezhiri_wait_chores) { tm.instance_variable_set(:@stock_survey, { copper: 50_000, missing_tools: [] }) }

      expect(tm.get_task).to eq([:accepted, 'zasele', nil])
      expect(sent).to eq(%w[nezhiri nezhiri zasele])
    end

    it 'clears the detour once the task is done (back_to_primary_npc)' do
      tm = build(npc: 'zasele', primary_npc: 'nezhiri', repair_detour: true)

      tm.back_to_primary_npc

      expect(tm.instance_variable_get(:@npc)).to eq('nezhiri')
      expect(tm.instance_variable_get(:@repair_detour)).to be(false)
    end

    describe 'a task of the first one already open when the fallback is asked (#check_task_giver)' do
      it 'finishes that task, as the first taskmaster, instead of cancelling it' do
        tm = build(npc: 'zasele', primary_npc: 'nezhiri', repair_detour: true, fallback_npc: 'zasele', task_giver: 'nezhiri', cancel_foreign_tasks: true)
        allow(tm).to receive(:cancel_foreign_task)

        tm.check_task_giver

        expect(tm).not_to have_received(:cancel_foreign_task)
        expect(tm.instance_variable_get(:@npc)).to eq('nezhiri')
        expect(tm.instance_variable_get(:@primary_npc)).to be_nil
        expect(tm.instance_variable_get(:@repair_detour)).to be(false)
        expect(DRC).to have_received(:message).with("You are on a task for Nezhiri; finishing it instead of working one of Zasele's.")
      end

      # The first one's task, finished as its own, is cancelled for short
      # instructions (cancel_short_task), and the first one then gives its
      # limit: the run falls back for the day as usual, not as a detour
      # whose first taskmaster it has already gone back to.
      it 'after that task is cancelled, takes the first one\'s limit as an ordinary one and works the fallback for the day' do
        tm, sent = asking_mid_detour({ 'zasele' => ['You are already on a task.', offer], 'nezhiri' => [daily_max.sub('Zasele', 'Nezhiri')] },
                                     npc: 'zasele', primary_npc: 'nezhiri', repair_detour: true, fallback_npc: 'zasele', task_giver: 'nezhiri')
        allow(tm).to receive(:resume_task) do
          tm.check_task_giver
          throw TaskMaster::FOREIGN_TASK_CANCELLED
        end

        expect(tm.get_task).to eq([:accepted, 'zasele', nil])
        expect(sent).to eq(%w[zasele nezhiri zasele])
        expect(tm.instance_variable_get(:@primary_npc)).to eq('nezhiri')
        expect(UserVars.taskmaster_capped).to include('nezhiri')
      end

      it "treats the first one's open task as another's when the run is not on a detour (fallback for the day)" do
        tm = build(npc: 'zasele', primary_npc: 'nezhiri', repair_detour: false, fallback_npc: 'zasele', task_giver: 'nezhiri', cancel_foreign_tasks: false)

        expect { tm.check_task_giver }.to raise_error(SystemExit)
      end

      it "still treats a third taskmaster's task as another's" do
        tm = build(npc: 'zasele', primary_npc: 'nezhiri', repair_detour: true, fallback_npc: 'zasele', task_giver: 'poltu')
        expect { tm.check_task_giver }.to raise_error(SystemExit)
      end
    end
  end

  describe "the knitting needles' repair clock" do
    it "keys a yarn task's needles by outfitting_tools' name for them, the one a cloth task uses" do
      expect(build(settings: { outfitting_tools: ['knitting needle', 'scissors'] }).knitting_needles_name).to eq('knitting needle')
      expect(build(settings: { outfitting_tools: ['scissors'] }).knitting_needles_name).to eq('knitting needles')
    end

    it "sends a yarn task's needles for repair by that name, so yarn and cloth tasks share one clock" do
      tm = build(settings: { outfitting_tools: ['knitting needle', 'scissors'] })
      allow(tm).to receive(:buy_yarn)
      allow(tm).to receive(:tailor_item)
      allow(tm).to receive(:repair)
      allow(tm).to receive(:trash)
      allow(tm).to receive(:bins_task_stock?).and_return(true)

      tm.zasele('hat', 2, 4, 'yarn', 'wool')

      expect(tm).to have_received(:repair).with(['knitting needle'], anything)
    end
  end
end
