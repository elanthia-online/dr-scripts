# frozen_string_literal: true

require 'ostruct'
require 'yaml'

require_relative 'spec_helper'

load_lic_class('remedy.lic', 'Remedy')

# remedy.lic, characterised from its entry point against real log lines.
#
# Every example starts the script the way Lich does: `$script_vars` holds the
# arguments as Lich splits them (ArgParserModel.script_vars for a typed
# `;remedy ...`, ArgParserModel.caller_vars for another script's
# DRC.wait_for_script_to_complete), parse_args runs the ArgParser model, and
# run_lic_entry evals the code after the class. Nothing reaches into an ivar
# or a private method, so these examples keep passing, unchanged, through the
# refactor layers that rebuild the class.
#
# The game is a ReplayGame: every line it sends back is a real line of the
# game logs of 2026-10-25 and 2026-10-26 (the timestamped copies, in
# spec/fixtures/remedy/log_lines.json and transcripts/*.json), cited as
# "<log>:<line>", or a ReplayGame.code line naming the code it was built
# from. A comment marks a real line used for a command it did not answer in
# the log as an "analog". The commons are ReplayCommons; which hand holds what
# is a model assumption (Genie client logs carry no hand data), and the item names in
# hand are the log's names, shortened.
#
# == The contract
# The rule of this change: if a use of remedy.lic works
# today, it must work tomorrow. Every group titled "(the contract)" pins
# three things:
# - the commands remedy sends itself (bput, fput), byte for byte;
# - the items the commons helpers move (ReplayCommons#moves): where each
#   item went, whichever name or hand remedy asked for it by;
# - the end state.
# The commands the commons helpers send (get, put, stow, tie, untie) are
# not pinned as text: ReplayCommons models those helpers at API level and
# sends nothing. A helper call that moves nothing (a stow with empty hands,
# say) leaves no trace in #moves, so the contract does not see it; a few
# examples pin a helper's arguments where the routing matters (the herb
# container, the remed book). The moves alone cannot show the routing: a
# stow by name and a stow by hand position route an item differently when
# the hand's name is not the name remedy routes by. herb2 "jadice" is
# "dried jadice" in hand, which remedy.lic:166 does not take for a herb, so
# the two stows send it to different containers; the herb2 example pins the
# arguments of both its get and its stow.
#
# Later layers may change an example here only when:
# - it is titled `CURRENT (<finding>): ...` and pins a path that is broken
#   today; the layer named in its comment flips it (layer N is the Nth
#   commit of this change);
# - or the layer makes a deliberate behaviour change and says so in its
#   comment (the no-product stop of the callers, the herb put wording,
#   the opt-in stamp repair, the restock in the crafting town).
RSpec.describe Remedy do
  let(:toolbag) { "botanist's toolbag" }
  let(:toolstrap) { 'grass toolstrap' }

  # The character of the logs: every tool on a grass toolstrap,
  # supplies in a botanist's toolbag, no water or alcohol vessel. The keys are
  # every setting remedy.lic reads.
  let(:logged_settings) do
    {
      crafting_container: toolbag,
      crafting_items_in_container: ['alcohol', 'water', 'pewter ingot', 'remed book'],
      alchemy_belt: { 'name'  => toolstrap,
                      'items' => ['heavy cauldron', 'mixing stick', 'turtle-shaped sieve', 'applewood stamp', 'large mortar', 'rounded pestle'] },
      alchemy_tools: ['heavy cauldron', 'mixing stick', 'turtle-shaped sieve', 'large mortar', 'rounded pestle'],
      crafting_training_spells: [],
      hometown: 'Crossing',
      force_crafting_town: nil,
      mark_crafted_goods: true,
      cube_armor_piece: nil,
      herb_container: nil,
      water_container: nil,
      alcohol_container: nil,
      master_crafting_book: nil,
      alchemy_room: nil
    }
  end
  let(:settings) { logged_settings }

  # Tool names as the untie lines of the logs give them (26:5908, 26:10734,
  # 26:10759, 26:10928, 26:11384), shortened.
  let(:logged_tools) do
    {
      'heavy cauldron'                     => toolstrap,
      'luminescent starshine mixing stick' => toolstrap,
      'turtle-shaped sieve'                => toolstrap,
      'Siksrajan applewood-handled stamp'  => toolstrap,
      'diamondique large mortar'           => toolstrap,
      'rounded pestle'                     => toolstrap
    }
  end
  # Supplies as the get lines of the logs give them (26:10825, 26:5987, 26:11112).
  let(:logged_supplies) do
    { 'remed book' => toolbag, 'water' => toolbag, 'grain alcohol' => toolbag, 'pewter ingot' => toolbag }
  end
  let(:inventory) { logged_tools.merge(logged_supplies) }
  # Where every tool is at the end of a success run: where it started.
  let(:expected_tool_locations) { logged_tools }
  let(:lich5) { :current }
  let(:orders) { {} }
  let(:game) { ReplayGame.new }
  let(:commons) { ReplayCommons.new(game: game, lich5: lich5, inventory: inventory, orders: orders) }
  let(:remedies_data) { YAML.load_file(File.expand_path('../data/base-crafting.yaml', __dir__), aliases: true)['remedies'] }
  let(:remedy_messages) { [] }
  let(:exit_hooks) { [] }

  after { $script_vars = nil }

  # @param cite [String] "<log>:<line>"
  # @return [ReplayGame::Line]
  def log(cite)
    ReplayGame.log(cite)
  end

  # @param text [String]
  # @param from [String] the code line it comes from
  # @return [ReplayGame::Line]
  def code(text, from:)
    ReplayGame.code(text, from: from)
  end

  # @param run [String] e.g. "2026-10-26_5598"
  # @return [ReplayTranscript]
  def transcript(run)
    ReplayTranscript.load(self.class.transcript_path(run))
  end

  # @param line [String] the arguments as typed after `;remedy`
  # @return [Array<String>] Lich's `variable`
  def typed(line)
    ArgParserModel.script_vars(line)
  end

  # @param args [Array<Object>] a caller's DRC.wait_for_script_to_complete list
  # @return [Array<String>] Lich's `variable`
  def called_with(args)
    ArgParserModel.caller_vars(args)
  end

  # Runs remedy.lic from its entry point with this example's settings, game
  # and commons. The block runs once the doubles are in place, before the
  # script starts.
  #
  # @param vars [Array<String>] Lich's `variable` for the run
  # @return [Symbol] :exited (the script called exit), :looped (the send
  #   budget ran out) or :returned
  def run_remedy(vars)
    $test_settings = OpenStruct.new(settings)
    $test_data.crafting = { 'remedies' => remedies_data }
    $parse_args_model = true
    $script_vars = vars
    game.install(self)
    commons.install(self)
    # Captures before_dying wherever the script calls it from: the entry code
    # (main) today, a Remedy instance once the entry is split from the work.
    # Stubbed on the callers because a spec elsewhere redefines the top-level
    # before_dying (spec/workorders_spec.rb:10).
    allow(TOPLEVEL_BINDING.receiver).to receive(:before_dying) { |&block| exit_hooks << block }
    allow_any_instance_of(described_class).to receive(:before_dying) { |_remedy, &block| exit_hooks << block }
    allow(DRC).to receive(:message) { |text| remedy_messages << text }
    yield if block_given?
    run_lic_entry('remedy.lic', 'Remedy')
    :returned
  rescue SystemExit
    :exited
  rescue ReplayLoopGuard
    :looped
  end

  # The command remedy puts the gathered herb into the vessel with
  # (remedy.lic:247). CURRENT (H32) wording, without "my": layer 15 changes
  # this one line, on purpose ("put my <herb> in my
  # <vessel>", the form of 26:30995).
  #
  # @param herb [String] herb1 as remedy has it
  # @param vessel [String] the alchemy_tools entry
  # @return [String]
  def herb_put_command(herb, vessel)
    "put #{herb} in my #{vessel}"
  end

  # Scripts a stack of 25 found in the toolbag: the count (25:33679, analog:
  # the reply to `count clubm in smoke bask`, 25:33677), the combine with one
  # stack in hand (25:104590, analog: the reply to `combine`, 25:104589) and
  # the put, after which the game holds the herb.
  #
  # @param herb [String] herb1 as remedy is given it
  # @param vessel [String] the alchemy_tools entry
  # @param put_lines [Array<ReplayGame::Line>] the reply to the put
  # @return [void]
  def script_one_stack(herb, vessel:, put_lines:)
    game.script("count my #{herb}", log('25:33679'))
    game.script("combine my #{herb}", log('25:104590'))
    game.script(herb_put_command(herb, vessel), *put_lines, after: ->(_game) { commons.release(herb) })
  end

  # Scripts the fput that takes the product out of the vessel; the game hands
  # it over.
  #
  # @param command [String] remedy's `get my <noun> from my <vessel>`
  # @param line [ReplayGame::Line] the game's reply
  # @param product [String] the product's name in hand
  # @return [void]
  def script_product(command, line, product)
    game.script(command, line, after: ->(_game) { commons.hold(product) })
  end

  # @return [Hash{String => String}] item => where it is, for every tool
  def tool_locations
    logged_tools.keys.to_h { |tool| [tool, commons.location_of(tool)] }
  end

  # @return [Array<String>] the remedy Flags still registered
  def remedy_flags
    Flags.matchers.keys.grep(/\Aremedy-/)
  end

  # Crafting commands remedy sends itself in a cauldron run, as the log has
  # them (the transcript steps to script). A class method too, for the
  # sweeps that build one example per step.
  #
  # @return [Regexp]
  def self.cauldron_craft_commands
    /\A(?:mix my heavy cauldron|turn my heavy cauldron|pour part (?:water|alcohol) in my heavy cauldron|put my pewter ingot in my heavy cauldron|push my \w+ with my turtle-shaped sieve|smell my|mark my)/
  end

  # Crafting commands remedy sends itself in a mortar run, as the log has them.
  #
  # @return [Regexp]
  def self.mortar_craft_commands
    /\A(?:crush my|turn my large mortar|pour part (?:water|alcohol) in my large mortar|put my pewter ingot in my large mortar|push my \w+ with my turtle-shaped sieve|smell my|mark my)/
  end

  # @param run [String] e.g. "2026-10-26_5598"
  # @return [String] the transcript fixture
  def self.transcript_path(run)
    File.expand_path("fixtures/remedy/transcripts/#{run}.json", __dir__)
  end

  # Log lines of the steps C01 skips (see #script_general_elixir).
  #
  # @return [Array<Integer>]
  def self.general_elixir_skips
    [5948, 6346]
  end

  # Log lines of the steps C02 skips (see #script_head_unguent).
  #
  # @return [Array<Integer>]
  def self.head_unguent_skips
    [10793, 11097]
  end

  # Log lines of the commands the logged runs sent after the final-touches
  # line: C01's mix 26:6770 (answered by the refusal 26:6773) and C02's
  # crush 26:11366 (answered by 26:11368). That one command is the CURRENT
  # (D05) lag, flipped by layer 16, which the CURRENT (D05) examples pin.
  # The C15 sweeps leave these steps out: a wait injected into a command
  # that only exists because of D05 would pin the bug, not the contract.
  #
  # @return [Array<Integer>]
  def self.completion_echo_steps
    [6770, 11366]
  end

  # @return [Regexp] see .cauldron_craft_commands
  def cauldron_craft_commands
    self.class.cauldron_craft_commands
  end

  # @return [Regexp] see .mortar_craft_commands
  def mortar_craft_commands
    self.class.mortar_craft_commands
  end

  # remedy's wording of a logged command (ReplayGame#alias_command):
  # - remedy puts liquids with `put` when no vessel is set (remedy.lic:313,
  #   :333); the log poured;
  # - remedy pushes with "my sieve" (remedy.lic:375) and marks with "my
  #   stamp" (remedy.lic:423); the log named the tool;
  # - the first crush names the alchemy_tools pestle (remedy.lic:63, :261);
  #   the log said "my pestle".
  #
  # @param vessel [String] the alchemy_tools vessel
  # @param noun [String] the product noun
  # @param herb [String, nil] herb1, for the first crush of a mortar run
  # @return [void]
  def alias_remedy_wording(vessel:, noun:, herb: nil)
    game.alias_command("put water in my #{vessel}", as: "pour part water in my #{vessel}")
    game.alias_command("put alcohol in my #{vessel}", as: "pour part alcohol in my #{vessel}")
    game.alias_command("push my #{noun} with my sieve", as: "push my #{noun} with my turtle-shaped sieve")
    game.alias_command("mark my #{noun} with my stamp", as: "mark my #{noun} with my applewood stamp")
    game.alias_command("crush my #{herb} with my rounded pestle", as: "crush my #{herb} with my pestle") if herb
  end

  # C01 (run 26_5598): a general elixir, belradi, in the heavy cauldron,
  # marked. The log mixed again after two cue-only refusals (26:5948 after
  # the alcohol cue, 26:6346 after the catalyst cue); remedy adds the
  # ingredient first, so those two steps are left out.
  #
  # @param inject [Hash] see ReplayTranscript#script
  # @param replace [Hash] see ReplayTranscript#script
  # @return [void]
  def script_general_elixir(inject: {}, replace: {})
    script_one_stack('belradi', vessel: 'heavy cauldron', put_lines: [log('26:5898')])
    transcript('2026-10-26_5598').script(game, commands: cauldron_craft_commands, skip: self.class.general_elixir_skips, inject: inject, replace: replace)
    alias_remedy_wording(vessel: 'heavy cauldron', noun: 'elixir')
    script_product('get my elixir from my heavy cauldron', log('26:6794'), 'belradi elixir')
  end

  # C02 (run 26_10483): some head unguent, nemoih, in the large mortar,
  # marked. The log crushed again after the water cue (26:10793) and pushed
  # while the catalyst was owed (26:11097, refused); remedy does neither.
  #
  # @param inject [Hash] see ReplayTranscript#script
  # @param replace [Hash] see ReplayTranscript#script
  # @return [void]
  def script_head_unguent(inject: {}, replace: {})
    script_one_stack('nemoih', vessel: 'large mortar', put_lines: [log('26:10749')])
    transcript('2026-10-26_10483').script(game, commands: mortar_craft_commands, skip: self.class.head_unguent_skips, inject: inject, replace: replace)
    alias_remedy_wording(vessel: 'large mortar', noun: 'unguent', herb: 'nemoih')
    script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
  end

  # C01's commands through the mix that draws the final-touches line
  # (26:6742), as remedy sends them today. The contract: C01 and the C15
  # sweeps pin them.
  #
  # @return [Array<String>]
  def general_elixir_crafting
    mix = 'mix my heavy cauldron with my mixing stick'
    ['count my belradi',                              # 25:33679 (analog)
     'combine my belradi',                            # 25:104590 (analog)
     herb_put_command('belradi', 'heavy cauldron'),   # 26:5898
     mix,                                             # alcohol cue 26:5918 after Roundtime 26:5915
     'put alcohol in my heavy cauldron',              # 26:5995
     mix,                                             # clumps cue 26:6031
     'turn my heavy cauldron',                        # 26:6086
     mix, mix, mix,                                   # 26:6120, 26:6153, 26:6162
     mix,                                             # clumps cue 26:6218
     'turn my heavy cauldron',                        # 26:6251
     mix,                                             # catalyst cue 26:6313
     'put my pewter ingot in my heavy cauldron',      # 26:6367
     mix, mix, mix,                                   # 26:6427, 26:6462, 26:6495
     mix,                                             # particulate cue 26:6528
     'push my elixir with my sieve',                  # 26:6574
     mix,                                             # particulate cue 26:6649
     'push my elixir with my sieve',                  # 26:6695
     mix]                                             # Roundtime 26:6740, then final touches 26:6742
  end

  # C01's last commands: the product taken out (26:6794) and marked (26:6799).
  #
  # @return [Array<String>]
  def general_elixir_finishing
    ['get my elixir from my heavy cauldron', 'mark my elixir with my stamp']
  end

  # Every item C01 moves (ReplayCommons#moves), in order.
  #
  # @return [Array<String>]
  def general_elixir_moves
    stick = 'luminescent starshine mixing stick'
    sieve = 'turtle-shaped sieve'
    ["remed book: #{toolbag} -> hand", "remed book: hand -> #{toolbag}",
     "heavy cauldron: #{toolstrap} -> hand", 'heavy cauldron: hand -> ground',
     "crushed belradi: #{toolbag} -> hand", 'crushed belradi: hand -> game',
     'heavy cauldron: ground -> hand', "#{stick}: #{toolstrap} -> hand",
     "#{stick}: hand -> #{toolstrap}", "grain alcohol: #{toolbag} -> hand",
     "grain alcohol: hand -> #{toolbag}", "#{stick}: #{toolstrap} -> hand",
     "#{stick}: hand -> #{toolstrap}", "pewter ingot: #{toolbag} -> hand",
     "pewter ingot: hand -> #{toolbag}", "#{stick}: #{toolstrap} -> hand",
     "#{stick}: hand -> #{toolstrap}", "#{sieve}: #{toolstrap} -> hand",
     "#{sieve}: hand -> #{toolstrap}", "#{stick}: #{toolstrap} -> hand",
     "#{stick}: hand -> #{toolstrap}", "#{sieve}: #{toolstrap} -> hand",
     "#{sieve}: hand -> #{toolstrap}", "#{stick}: #{toolstrap} -> hand",
     "#{stick}: hand -> #{toolstrap}", 'belradi elixir: game -> hand',
     "heavy cauldron: hand -> #{toolstrap}",
     "Siksrajan applewood-handled stamp: #{toolstrap} -> hand", "Siksrajan applewood-handled stamp: hand -> #{toolstrap}"]
  end

  # C02's commands through the crush that draws the final-touches line
  # (26:11333), as remedy sends them today. The contract: C02 and the C15
  # sweeps pin them.
  #
  # @return [Array<String>]
  def head_unguent_crafting
    crush = 'crush my unguent with my rounded pestle'
    ['count my nemoih',                               # 25:33679 (analog)
     'combine my nemoih',                             # 25:104590 (analog)
     herb_put_command('nemoih', 'large mortar'),      # 26:10749
     'crush my nemoih with my rounded pestle',        # water cue 26:10769
     'put water in my large mortar',                  # 26:10830
     crush,                                           # 26:10870
     crush,                                           # particulate cue 26:10895
     'push my unguent with my sieve',                 # 26:10933
     crush,                                           # 26:10984
     crush,                                           # colour cue 26:11011
     'smell my unguent',                              # 26:11034
     crush,                                           # particulate 26:11060 and catalyst 26:11065 cues
     'put my pewter ingot in my large mortar',        # 26:11117 (the need before the step)
     'push my unguent with my sieve',                 # 26:11175
     crush, crush, crush, crush, crush,               # 26:11210 ... 26:11308
     crush]                                           # Roundtime 26:11331, then final touches 26:11333
  end

  # C02's last commands: the product taken out (26:11389) and marked (26:11394).
  #
  # @return [Array<String>]
  def head_unguent_finishing
    ['get my unguent from my large mortar', 'mark my unguent with my stamp']
  end

  # Every item C02 moves (ReplayCommons#moves), in order.
  #
  # @return [Array<String>]
  def head_unguent_moves
    pestle = 'rounded pestle'
    mortar = 'diamondique large mortar'
    sieve = 'turtle-shaped sieve'
    ["remed book: #{toolbag} -> hand", "remed book: hand -> #{toolbag}",
     "#{mortar}: #{toolstrap} -> hand", "#{mortar}: hand -> ground",
     "dried nemoih: #{toolbag} -> hand", 'dried nemoih: hand -> game',
     "#{mortar}: ground -> hand", "#{pestle}: #{toolstrap} -> hand",
     "#{pestle}: hand -> #{toolstrap}", "water: #{toolbag} -> hand",
     "water: hand -> #{toolbag}", "#{pestle}: #{toolstrap} -> hand",
     "#{pestle}: hand -> #{toolstrap}", "#{sieve}: #{toolstrap} -> hand",
     "#{sieve}: hand -> #{toolstrap}", "#{pestle}: #{toolstrap} -> hand",
     "#{pestle}: hand -> #{toolstrap}", "pewter ingot: #{toolbag} -> hand",
     "pewter ingot: hand -> #{toolbag}", "#{pestle}: #{toolstrap} -> hand",
     "#{pestle}: hand -> #{toolstrap}", "#{sieve}: #{toolstrap} -> hand",
     "#{sieve}: hand -> #{toolstrap}", "#{pestle}: #{toolstrap} -> hand",
     "#{pestle}: hand -> #{toolstrap}", 'nemoih unguent: game -> hand',
     "#{mortar}: hand -> #{toolstrap}",
     "Siksrajan applewood-handled stamp: #{toolstrap} -> hand", "Siksrajan applewood-handled stamp: hand -> #{toolstrap}"]
  end

  # The argument list workorders.lic:818 builds for a base-recipes.yaml
  # recipe with no herb2. The catalyst is the one the logged run used.
  #
  # @param recipe_name [String]
  # @param chapter [Integer]
  # @param herb1 [String]
  # @param container [String] the recipe's container (mortar or bowl)
  # @param noun [String]
  # @param catalyst [String]
  # @return [Array<String>] Lich's `variable`
  def workorders_call(recipe_name, chapter, herb1, container, noun, catalyst:)
    called_with(['remedies', chapter, recipe_name, herb1, 'na', catalyst, container, noun])
  end

  # ;remedy remedies 3 "some head unguent" nemoih <herb2> "pewter ingot" mortar unguent
  #
  # @param herb2 [String]
  # @return [Array<String>] Lich's `variable`
  def short_unguent(herb2: 'na')
    typed(%(remedies 3 "some head unguent" nemoih #{herb2} "pewter ingot" mortar unguent))
  end

  # A short head unguent run: the stack of C02 (put reply 26:10749), a first
  # crush answered by first_crush (by default the final-touches line
  # 26:11333), any later crush by the completion echo 26:11368, and the
  # product taken out (26:11389). Each handler step gets the reply the logged
  # run got to the same step (analogs where the log's wording differs).
  #
  # @param first_crush [Array<ReplayGame::Line>] the reply to the first crush
  # @param put_lines [Array<ReplayGame::Line>] the reply to the herb put
  # @return [void]
  def script_short_unguent(first_crush: [log('26:11333')], put_lines: [log('26:10749')])
    script_one_stack('nemoih', vessel: 'large mortar', put_lines: put_lines)
    game.script('crush my nemoih with my rounded pestle', *first_crush)
    game.fallback('crush my unguent with my rounded pestle', log('26:11368'))
    game.fallback('put water in my large mortar', log('26:10830'))                  # to `pour part water in my large mortar`
    game.fallback('put alcohol in my large mortar', log('25:10905'))                # to `pour part alcohol in my large mortar`
    game.fallback('put my pewter ingot in my large mortar', log('26:11117'))
    game.fallback('push my unguent with my sieve', log('26:10933'), log('26:10935')) # to `push ... turtle-shaped sieve`
    game.fallback('turn my large mortar', log('25:94795'), log('25:94797')) # the salve run's turn
    game.fallback('smell my unguent', log('26:11034'), log('26:11036'))
    script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
  end

  shared_examples 'a success run replayed from the log' do
    it 'sends the logged crafting commands, byte for byte, through the one that drew the final-touches line' do
      outcome
      expect(game.sent.first(crafting_commands.size)).to eq(crafting_commands), game.report
    end

    it 'takes the product out and marks it, byte for byte, as its last commands' do
      outcome
      expect(game.sent.last(finishing_commands.size)).to eq(finishing_commands), game.report
    end

    it 'moves every item exactly as the log run did' do
      outcome
      expect(commons.moves).to eq(expected_moves)
    end

    it 'ends with the product in hand and every tool back where it started' do
      expect(outcome).to eq(:exited)
      expect(commons.location_of(product)).to eq('left').or eq('right')
      expect(tool_locations).to eq(expected_tool_locations)
    end

    it 'never waits out a bput timeout' do
      outcome
      expect(game.diagnostics).to be_empty
    end

    it 'registers a before_dying block that leaves no remedy Flag behind' do
      outcome
      expect(exit_hooks).not_to be_empty
      exit_hooks.each(&:call)
      expect(remedy_flags).to be_empty
    end
  end

  describe 'success runs replayed from the logs (the contract)' do
    context 'C01: a general elixir in the heavy cauldron, called as workorders.lic:818 calls it (26:5896-6801)' do
      subject(:outcome) { run_remedy(workorders_call('a general elixir', 6, 'belradi', 'bowl', 'elixir', catalyst: 'pewter ingot')) }

      let(:inventory) { logged_tools.merge(logged_supplies, 'crushed belradi' => toolbag) }
      let(:product) { 'belradi elixir' }
      let(:mix) { 'mix my heavy cauldron with my mixing stick' }
      let(:crafting_commands) { general_elixir_crafting }
      let(:finishing_commands) { general_elixir_finishing }
      let(:expected_moves) { general_elixir_moves }

      before { script_general_elixir }

      it_behaves_like 'a success run replayed from the log'

      # flipped by layer 16 (completion from the final-touches line)
      it 'CURRENT (D05): mixes once more after the final-touches line (26:6742) and finishes on the refusal 26:6773' do
        outcome
        expect(game.sent[crafting_commands.size...-finishing_commands.size]).to eq([mix])
        expect(game.trace.select { |event| event.kind == :line }.map(&:label)).to include('26:6742', '26:6773')
      end
    end

    context 'C02: some head unguent in the large mortar (26:10747-11396)' do
      subject(:outcome) { run_remedy(typed('remedies 3 "some head unguent" nemoih na "pewter ingot" mortar unguent')) }

      let(:inventory) { logged_tools.merge(logged_supplies, 'dried nemoih' => toolbag) }
      let(:product) { 'nemoih unguent' }
      let(:crush) { 'crush my unguent with my rounded pestle' }
      let(:crafting_commands) { head_unguent_crafting }
      let(:finishing_commands) { head_unguent_finishing }
      let(:expected_moves) { head_unguent_moves }

      before { script_head_unguent }

      it_behaves_like 'a success run replayed from the log'

      # flipped by layer 16 (completion from the final-touches line)
      it 'CURRENT (D05): crushes once more after the final-touches line (26:11333) and finishes on 26:11368' do
        outcome
        expect(game.sent[crafting_commands.size...-finishing_commands.size]).to eq([crush])
        expect(game.trace.select { |event| event.kind == :line }.map(&:label)).to include('26:11333', '26:11368')
      end
    end

    # A stow by name must route bag tools as a stow by hand
    # does. The log's character ties every tool to a toolstrap; this is C02
    # for a character with no alchemy_belt and every tool in the crafting
    # bag, same replies, same commands.
    context 'C02 with every tool in the crafting bag and no alchemy_belt (26:10747-11396)' do
      subject(:outcome) { run_remedy(typed('remedies 3 "some head unguent" nemoih na "pewter ingot" mortar unguent')) }

      let(:settings) { logged_settings.merge(alchemy_belt: nil) }
      let(:bag_tools) { logged_tools.transform_values { toolbag } }
      let(:inventory) { bag_tools.merge(logged_supplies, 'dried nemoih' => toolbag) }
      let(:expected_tool_locations) { bag_tools }
      let(:product) { 'nemoih unguent' }
      let(:crafting_commands) { head_unguent_crafting }
      let(:finishing_commands) { head_unguent_finishing }
      let(:expected_moves) { head_unguent_moves.map { |move| move.gsub(toolstrap, toolbag) } }

      before { script_head_unguent }

      it_behaves_like 'a success run replayed from the log'
    end

    context 'some eye unguent in the large mortar, finished inside a smell reply (26:11827-12435)' do
      subject(:outcome) { run_remedy(workorders_call('some eye unguent', 3, 'sufil', 'mortar', 'unguent', catalyst: 'pewter ingot')) }

      let(:inventory) { logged_tools.merge(logged_supplies, 'dried sufil' => toolbag) }
      let(:product) { 'sufil unguent' }
      let(:crush) { 'crush my unguent with my rounded pestle' }
      let(:crafting_commands) do
        ['count my sufil',                                # 25:33679 (analog)
         'combine my sufil',                              # 25:104590 (analog)
         herb_put_command('sufil', 'large mortar'),       # 26:11829
         'crush my sufil with my rounded pestle',         # water cue 26:11849
         'put water in my large mortar',                  # 26:11905
         crush, crush, crush,                             # 26:11945, 26:11968, 26:11991
         crush,                                           # particulate cue 26:12016
         'push my unguent with my sieve',                 # 26:12049
         crush,                                           # colour cue 26:12100
         'smell my unguent',                              # catalyst cue 26:12129 after Roundtime 26:12126
         'put my pewter ingot in my large mortar',        # 26:12170
         crush, crush, crush, crush, crush,               # 26:12220 ... 26:12321
         crush,                                           # colour cue 26:12345
         'smell my unguent']                              # Roundtime 26:12371, then final touches 26:12373
      end
      let(:finishing_commands) { ['get my unguent from my large mortar', 'mark my unguent with my stamp'] } # 26:12428, 26:12433
      let(:expected_moves) do
        pestle = 'rounded pestle'
        mortar = 'diamondique large mortar'
        sieve = 'turtle-shaped sieve'
        ["remed book: #{toolbag} -> hand", "remed book: hand -> #{toolbag}",
         "#{mortar}: #{toolstrap} -> hand", "#{mortar}: hand -> ground",
         "dried sufil: #{toolbag} -> hand", 'dried sufil: hand -> game',
         "#{mortar}: ground -> hand", "#{pestle}: #{toolstrap} -> hand",
         "#{pestle}: hand -> #{toolstrap}", "water: #{toolbag} -> hand",
         "water: hand -> #{toolbag}", "#{pestle}: #{toolstrap} -> hand",
         "#{pestle}: hand -> #{toolstrap}", "#{sieve}: #{toolstrap} -> hand",
         "#{sieve}: hand -> #{toolstrap}", "#{pestle}: #{toolstrap} -> hand",
         "#{pestle}: hand -> #{toolstrap}", "pewter ingot: #{toolbag} -> hand",
         "pewter ingot: hand -> #{toolbag}", "#{pestle}: #{toolstrap} -> hand",
         "#{pestle}: hand -> #{toolstrap}", 'sufil unguent: game -> hand',
         "#{mortar}: hand -> #{toolstrap}",
         "Siksrajan applewood-handled stamp: #{toolstrap} -> hand", "Siksrajan applewood-handled stamp: hand -> #{toolstrap}"]
      end

      before do
        script_one_stack('sufil', vessel: 'large mortar', put_lines: [log('26:11829')])
        # The log crushed again after the water cue (26:11870) and after the
        # smell that drew the catalyst cue (26:12150): cue-only refusals.
        transcript('2026-10-26_11582').script(game, commands: mortar_craft_commands, skip: [11870, 12150])
        alias_remedy_wording(vessel: 'large mortar', noun: 'unguent', herb: 'sufil')
        script_product('get my unguent from my large mortar', log('26:12428'), 'sufil unguent')
      end

      it_behaves_like 'a success run replayed from the log'

      # flipped by layer 16 (completion from the final-touches line)
      it 'CURRENT (D05/H16): crushes once more after the smell that completed it (26:12373) and finishes on 26:12394' do
        outcome
        expect(game.sent[crafting_commands.size...-finishing_commands.size]).to eq([crush])
        expect(game.trace.select { |event| event.kind == :line }.map(&:label)).to include('26:12373', '26:12394')
      end
    end

    # remedy has no instructions form yet (layer 20 adds it): this run is
    # entered through the book form, so only its crafting part is the log's.
    context "a marram salve's crush loop, entered through the book form (25:94433-94890)" do
      subject(:outcome) { run_remedy(typed('remedies 3 "a marram salve" marram na "pewter ingot" mortar salve')) }

      let(:inventory) { logged_tools.merge(logged_supplies, 'dried marram' => toolbag) }
      let(:product) { 'marram salve' }
      let(:crush) { 'crush my salve with my rounded pestle' }
      let(:crafting_commands) do
        ['count my marram',                               # 25:33679 (analog)
         'combine my marram',                             # 25:104590 (analog)
         herb_put_command('marram', 'large mortar'),      # 25:94435
         'crush my marram with my rounded pestle',        # water cue 25:94459
         'put water in my large mortar',                  # 25:94500
         crush,                                           # 25:94537
         crush,                                           # particulate cue 25:94558
         'push my salve with my sieve',                   # 25:94585
         crush, crush,                                    # 25:94609, 25:94635
         crush,                                           # catalyst cue 25:94655
         'put my pewter ingot in my large mortar',        # 25:94692
         crush,                                           # colour cue 25:94738
         'smell my salve',                                # 25:94753
         crush,                                           # clumps cue 25:94776
         'turn my large mortar',                          # 25:94795
         crush,                                           # colour cue 25:94822
         'smell my salve']                                # Roundtime 25:94847, then final touches 25:94849
      end
      let(:finishing_commands) { ['get my salve from my large mortar', 'mark my salve with my stamp'] } # 25:94883, 25:94888
      let(:expected_moves) do
        pestle = 'rounded pestle'
        mortar = 'diamondique large mortar'
        sieve = 'turtle-shaped sieve'
        ["remed book: #{toolbag} -> hand", "remed book: hand -> #{toolbag}",
         "#{mortar}: #{toolstrap} -> hand", "#{mortar}: hand -> ground",
         "dried marram: #{toolbag} -> hand", 'dried marram: hand -> game',
         "#{mortar}: ground -> hand", "#{pestle}: #{toolstrap} -> hand",
         "#{pestle}: hand -> #{toolstrap}", "water: #{toolbag} -> hand",
         "water: hand -> #{toolbag}", "#{pestle}: #{toolstrap} -> hand",
         "#{pestle}: hand -> #{toolstrap}", "#{sieve}: #{toolstrap} -> hand",
         "#{sieve}: hand -> #{toolstrap}", "#{pestle}: #{toolstrap} -> hand",
         "#{pestle}: hand -> #{toolstrap}", "pewter ingot: #{toolbag} -> hand",
         "pewter ingot: hand -> #{toolbag}", "#{pestle}: #{toolstrap} -> hand",
         "#{pestle}: hand -> #{toolstrap}", 'marram salve: game -> hand',
         "#{mortar}: hand -> #{toolstrap}",
         "Siksrajan applewood-handled stamp: #{toolstrap} -> hand", "Siksrajan applewood-handled stamp: hand -> #{toolstrap}"]
      end

      before do
        script_one_stack('marram', vessel: 'large mortar', put_lines: [log('25:94435')])
        # The log crushed again after the water cue (25:94476) and after the
        # catalyst cue (25:94671): cue-only refusals.
        transcript('2026-10-25_94219').script(game, commands: mortar_craft_commands, skip: [94476, 94671])
        alias_remedy_wording(vessel: 'large mortar', noun: 'salve', herb: 'marram')
        script_product('get my salve from my large mortar', log('25:94883'), 'marram salve')
      end

      it_behaves_like 'a success run replayed from the log'

      # flipped by layer 16 (completion from the final-touches line)
      it 'CURRENT (D05/H16): crushes once more after the smell that completed it (25:94849) and finishes on 25:94863' do
        outcome
        expect(game.sent[crafting_commands.size...-finishing_commands.size]).to eq([crush])
        expect(game.trace.select { |event| event.kind == :line }.map(&:label)).to include('25:94849', '25:94863')
      end
    end

    context 'the continue form, resuming the head unguent from its analysis (26:11130-11396)' do
      subject(:outcome) { run_remedy(typed('continue na "pewter ingot" mortar unguent')) }

      # The player holds the mortar with the unfinished unguent (26:11127 is
      # the moment of the log the run resumes from).
      let(:inventory) { logged_tools.except('diamondique large mortar').merge(logged_supplies) }
      let(:crush) { 'crush my unguent with my rounded pestle' }

      before do
        $right_hand = 'diamondique large mortar'
        # The analysis (26:11132-11146) carries a froth cue (26:11136).
        transcript('2026-10-26_10483').script(game, commands: /\Aanalyze my unguent\z|#{mortar_craft_commands.source}/, from: 11130)
        alias_remedy_wording(vessel: 'large mortar', noun: 'unguent')
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
      end

      # The commands through the crush that draws the final-touches line.
      let(:crafting_commands) do
        ['analyze my unguent',                      # 26:11132-11146
         'push my unguent with my sieve',           # 26:11175
         crush, crush, crush, crush, crush,         # 26:11210 ... 26:11308
         crush]                                     # Roundtime 26:11331, then final touches 26:11333
      end
      let(:finishing_commands) { ['get my unguent from my large mortar', 'mark my unguent with my stamp'] } # 26:11389, 26:11394

      it 'analyses, answers the froth cue, crushes to the end and marks, byte for byte' do
        expect(outcome).to eq(:exited)
        expect(game.sent.first(crafting_commands.size)).to eq(crafting_commands), game.report
        expect(game.sent.last(finishing_commands.size)).to eq(finishing_commands), game.report
        # at most the one CURRENT (D05) crush between them (pinned below)
        expect(game.sent.size - crafting_commands.size - finishing_commands.size).to be_between(0, 1)
        expect(game.diagnostics).to be_empty
      end

      it 'gets the pestle before the analysis, and moves every item as the head unguent run did from there' do
        outcome
        pestle = 'rounded pestle'
        sieve = 'turtle-shaped sieve'
        stamp = 'Siksrajan applewood-handled stamp'
        expect(commons.moves).to eq(["#{pestle}: #{toolstrap} -> hand",
                                     "#{pestle}: hand -> #{toolstrap}", "#{sieve}: #{toolstrap} -> hand",
                                     "#{sieve}: hand -> #{toolstrap}", "#{pestle}: #{toolstrap} -> hand",
                                     "#{pestle}: hand -> #{toolstrap}", 'nemoih unguent: game -> hand',
                                     "diamondique large mortar: hand -> #{toolstrap}",
                                     "#{stamp}: #{toolstrap} -> hand", "#{stamp}: hand -> #{toolstrap}"])
      end

      # flipped by layer 16 (completion from the final-touches line)
      it 'CURRENT (D05): crushes once more after the final-touches line (26:11333) and finishes on 26:11368' do
        outcome
        expect(game.sent[crafting_commands.size...-finishing_commands.size]).to eq([crush])
        expect(game.trace.select { |event| event.kind == :line }.map(&:label)).to include('26:11333', '26:11368')
      end

      it 'ends with the unguent in hand and the mortar, pestle, sieve and stamp on the toolstrap' do
        outcome
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
        expect(tool_locations).to eq(logged_tools)
      end

      it 'reads no book and gathers no herb' do
        outcome
        expect(commons.calls.map(&:first)).not_to include('DRCC.find_recipe2', 'DRCI.lower_item?')
        expect(game.sent.grep(/\A(?:count|combine) /)).to be_empty
      end
    end
  end

  describe 'other paths that work today (the contract)' do
    let(:settings) { logged_settings.merge(mark_crafted_goods: false) }
    let(:inventory) { logged_tools.merge(logged_supplies, 'dried nemoih' => toolbag) }
    let(:short_run_tail) { ['crush my nemoih with my rounded pestle', 'get my unguent from my large mortar'] } # 26:11333, 26:11389

    describe 'gathering the herb (each of these keeps its command sequence)' do
      it 'takes a stack of 25 from herb_container and counts, combines and puts it' do
        settings[:herb_container] = 'smokewood basket'
        inventory['dried nemoih'] = 'smokewood basket'
        script_short_unguent
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', herb_put_command('nemoih', 'large mortar'), *short_run_tail])
        expect(commons.moves).to include('dried nemoih: smokewood basket -> hand', 'dried nemoih: hand -> game')
        # The routing (herb_container, the herb as its only item, the belt);
        # skip_exit, the fifth argument, changes no success path.
        herb_gets = commons.calls.select { |name, item, *| name == 'DRCC.get_crafting_item' && item == 'nemoih' }
        expect(herb_gets.map { |call| call.first(5) }).to include(['DRCC.get_crafting_item', 'nemoih', 'smokewood basket', ['nemoih'], settings[:alchemy_belt]])
      end

      it 'counts a stack found in neither herb_container nor the crafting bag once, and puts it without combining' do
        inventory['dried nemoih'] = 'seasilk apron'
        script_short_unguent
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent).to eq(['count my nemoih', herb_put_command('nemoih', 'large mortar'), *short_run_tail])
        expect(commons.moves).to include('dried nemoih: seasilk apron -> hand')
      end

      # Two stacks in the toolbag; the second `get my nemoih from my
      # botanist's toolbag` takes the other one. Model assumption: the count
      # with both in hand counts the 75 (which stack the game counts is not in
      # the logs).
      it 'tops up a stack of 21 (25:12538) with a 75 (25:8678), and after "too large" (25:30006) counts each stack' do
        commons.inventory << ReplayCommons::Item.new('dried nemoih', toolbag)
        game.script('count my nemoih', log('25:12538'))
        game.script('combine my nemoih', log('25:104590'))
        game.script('count my nemoih', log('25:8678'))
        game.script('combine my nemoih', log('25:30006'))
        game.script('count my first nemoih', log('25:12538'))
        game.script('count my second nemoih', log('25:8678'))
        game.script(herb_put_command('nemoih', 'large mortar'), log('26:10749'), after: ->(_game) { commons.release('nemoih') })
        game.script('crush my nemoih with my rounded pestle', log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', 'count my nemoih', 'combine my nemoih',
                                 'count my first nemoih', 'count my second nemoih',
                                 herb_put_command('nemoih', 'large mortar'), *short_run_tail])
        expect(game.diagnostics).to be_empty
      end

      # code-derived: remedy.lic:247 /already has something/ and :251-253;
      # no tilt of a vessel appears in either log, so the tilts get silence.
      it 'tilts the vessel twice and puts the herb again when the game says it is not empty' do
        game.script('count my nemoih', log('25:33679'))
        game.script('combine my nemoih', log('25:104590'))
        game.script(herb_put_command('nemoih', 'large mortar'), code('Your large mortar already has something in it.', from: 'R:247 /already has something/'))
        game.script(herb_put_command('nemoih', 'large mortar'), log('26:10749'), after: ->(_game) { commons.release('nemoih') })
        game.script('crush my nemoih with my rounded pestle', log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', herb_put_command('nemoih', 'large mortar'),
                                 'tilt my large mortar', 'tilt my large mortar', herb_put_command('nemoih', 'large mortar'),
                                 *short_run_tail])
      end

      { 'red flower' => 'dried flower', 'blue flower' => 'crushed flower' }.each do |asked, used|
        it "gathers #{used} for herb1 \"#{asked}\" when the character has no #{asked}" do
          inventory.delete('dried nemoih')
          inventory[used] = toolbag
          game.script("count my #{used}", log('25:33679'))
          game.script("combine my #{used}", log('25:104590'))
          run_remedy(typed(%(remedies 2 "some blister cream" "#{asked}" nemoih "pewter ingot" mortar cream)))
          expect(game.sent.first(3)).to eq(["count my #{used}", "combine my #{used}", herb_put_command(used, 'large mortar')])
        end
      end

      # code-derived: remedy.lic:212-231, the 'none' branch of a herb that is
      # in neither herb_container nor the crafting bag. No log shows it. The
      # fput `stow my nemoih` (remedy.lic:219) is not read; it gets an analog
      # reply, 25:13762 (the 21 just went into the vessel). The second stack
      # holds 4 pieces: the merged stack counts 25 (25:33679).
      it 'tops up a stack of 21 found outside both bags by putting it in the vessel, getting another and taking it back out' do
        inventory['dried nemoih'] = 'seasilk apron'
        commons.inventory << ReplayCommons::Item.new('dried nemoih', 'seasilk apron')
        game.script('count my nemoih', log('25:12538'))
        game.script('stow my nemoih', log('25:13762'))
        game.script('combine my nemoih', log('25:11425'))
        game.script('count my nemoih', log('25:33679'))
        game.script(herb_put_command('nemoih', 'large mortar'), log('26:10749'), after: ->(_game) { commons.release('nemoih') })
        game.script('crush my nemoih with my rounded pestle', log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent).to eq(['count my nemoih', 'stow my nemoih', 'combine my nemoih', 'count my nemoih',
                                 herb_put_command('nemoih', 'large mortar'), *short_run_tail])
        expect(game.diagnostics).to be_empty
        # What remedy asks the helpers for, from the herb's first get to its
        # put (remedy.lic:212, :218-226): the herb, then the vessel put away
        # and lowered again around the second get. Item and container only.
        shuffle = %w[DRCC.get_crafting_item DRCC.stow_crafting_item DRCI.put_away_item? DRCI.get_item? DRCI.lower_item?]
        gathering = commons.calls.select { |name, *| shuffle.include?(name) }
                           .drop_while { |name, item, *| !(name == 'DRCC.get_crafting_item' && item == 'nemoih') }
                           .take_while { |name, item, *| !(name == 'DRCC.stow_crafting_item' && item == 'nemoih') }
        expect(gathering.map { |name, item, container| [name, item, container] }).to eq(
          [['DRCC.get_crafting_item', 'nemoih', toolbag],
           ['DRCI.put_away_item?', 'nemoih', 'large mortar'],
           ['DRCC.get_crafting_item', 'large mortar', toolbag],
           ['DRCC.stow_crafting_item', 'large mortar', toolbag],
           ['DRCI.get_item?', 'nemoih', nil],
           ['DRCC.get_crafting_item', 'large mortar', toolbag],
           ['DRCI.lower_item?', 'large mortar', nil],
           ['DRCI.get_item?', 'nemoih', 'large mortar']]
        )
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
        expect(tool_locations).to eq(expected_tool_locations)
      end

      # code-derived: remedy.lic:247-249 take "can only hold" and "You
      # vigorously rub" as a put, like "You put", and put the rest of the
      # stack away. Neither reply answers a herb put in the logs: "can only
      # hold" is in neither log; the one "You vigorously rub" line answers the
      # catalyst put (26:11117, analog). Model assumption: after "can only
      # hold" the stack is still in hand; after the rub the vessel has it.
      {
        'can only hold'      => [-> { ReplayGame.code('Your large mortar can only hold so much.', from: 'R:247 /can only hold/') }, false],
        'You vigorously rub' => [-> { ReplayGame.log('26:11117') }, true]
      }.each do |reply, (line, taken)|
        it "takes \"#{reply}\" as a put, puts the rest of the stack away and crafts on" do
          game.script('count my nemoih', log('25:33679'))
          game.script('combine my nemoih', log('25:104590'))
          game.script(herb_put_command('nemoih', 'large mortar'), line.call, after: ->(_game) { commons.release('nemoih') if taken })
          game.script('crush my nemoih with my rounded pestle', log('26:11333'))
          script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
          expect(run_remedy(short_unguent)).to eq(:exited)
          expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', herb_put_command('nemoih', 'large mortar'), *short_run_tail])
          expect(game.diagnostics).to be_empty
          expect(commons.calls).to include(['DRCC.stow_crafting_item', 'nemoih', toolbag, settings[:alchemy_belt]])
          expect(commons.location_of('dried nemoih')).to eq(taken ? nil : toolbag)
          expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
          expect(tool_locations).to eq(expected_tool_locations)
        end
      end

      # code-derived: remedy.lic:235-242 with no stack at 75 (the logged
      # "too large", 25:30006, came with a 75, 25:30012). Two stacks in the
      # toolbag, counted 21 (25:12538) and 25 (25:33679, analog); after "too
      # large" the ordinal counts read 25 and 21. remedy puts the herb in and
      # the other stack away after the put.
      # The ordinal put-back is not pinned here: an ordinal ("second
      # nemoih") moves nothing in ReplayCommons (see its class comment),
      # and layer 11 puts the smaller stack back whatever its count, a
      # change its ledger records (H27).
      it 'after "too large" (25:30006) with no stack at 75, counts each stack, puts the herb in and the other stack away' do
        commons.inventory << ReplayCommons::Item.new('dried nemoih', toolbag)
        game.script('count my nemoih', log('25:12538'))
        game.script('combine my nemoih', log('25:104590'))
        game.script('count my nemoih', log('25:33679'))
        game.script('combine my nemoih', log('25:30006'))
        game.script('count my first nemoih', log('25:33679'))
        game.script('count my second nemoih', log('25:12538'))
        game.script(herb_put_command('nemoih', 'large mortar'), log('26:10749'), after: ->(_game) { commons.release('nemoih') })
        game.script('crush my nemoih with my rounded pestle', log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', 'count my nemoih', 'combine my nemoih',
                                 'count my first nemoih', 'count my second nemoih',
                                 herb_put_command('nemoih', 'large mortar'), *short_run_tail])
        expect(game.diagnostics).to be_empty
        expect(commons.moves).to include('dried nemoih: hand -> game', "dried nemoih: hand -> #{toolbag}")
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
        expect(tool_locations).to eq(expected_tool_locations)
      end

      # code-derived: remedy.lic:237 reads "I could not find" as the reply to
      # `count my second nemoih` (25:13762, analog), so it goes on at once
      # instead of waiting out a bput timeout. The first stack counts 75
      # (25:8678), as in the logged "too large" (25:30006, 25:30012).
      it 'after "too large" (25:30006), takes "I could not find" (25:13762) for the second stack without a timeout' do
        commons.inventory << ReplayCommons::Item.new('dried nemoih', toolbag)
        game.script('count my nemoih', log('25:12538'))
        game.script('combine my nemoih', log('25:104590'))
        game.script('count my nemoih', log('25:8678'))
        game.script('combine my nemoih', log('25:30006'))
        game.script('count my first nemoih', log('25:8678'))
        game.script('count my second nemoih', log('25:13762'))
        game.script(herb_put_command('nemoih', 'large mortar'), log('26:10749'), after: ->(_game) { commons.release('nemoih') })
        game.script('crush my nemoih with my rounded pestle', log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', 'count my nemoih', 'combine my nemoih',
                                 'count my first nemoih', 'count my second nemoih',
                                 herb_put_command('nemoih', 'large mortar'), *short_run_tail])
        expect(game.diagnostics).to be_empty
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
      end

      # The second herb comes from herb_container (remedy.lic:153-154). What
      # is left of it after its put goes back by its hand name (remedy.lic:366,
      # DRC.left_hand): "dried jadice" is not herb2 "jadice" (remedy.lic:166),
      # so it goes to the crafting bag (remedy.lic:169), not herb_container.
      # A stow by the name "jadice" would route it to herb_container
      # (by name and by hand must route the same).
      # code-derived: no log has the herb cue (remedy.lic:51) or a herb2 put.
      # The put gets the Roundtime 25:10825 (analog); that the stack stays in
      # hand after it is a model assumption.
      it 'takes herb2 from herb_container and puts what is left of it after the put in the crafting bag' do
        settings[:herb_container] = 'smokewood basket'
        inventory['dried jadice'] = 'smokewood basket'
        herb_cue = code('You need another prepared herb to continue crafting some unfinished nemoih unguent.', from: 'R:51 /You need another prepared herb/')
        script_short_unguent(first_crush: [log('26:11057'), log('25:10825'), herb_cue])
        game.script('put my jadice in my large mortar', log('25:10825'))
        game.script('crush my unguent with my rounded pestle', log('26:11333'))
        expect(run_remedy(short_unguent(herb2: 'jadice'))).to eq(:exited)
        expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', herb_put_command('nemoih', 'large mortar'),
                                 'crush my nemoih with my rounded pestle', 'put my jadice in my large mortar',
                                 'crush my unguent with my rounded pestle', 'get my unguent from my large mortar'])
        herb2_calls = commons.calls.select { |name, item, *| name.start_with?('DRCC.') && item.to_s.end_with?('jadice') }
        expect(herb2_calls.map { |call| call.first(4) }).to eq(
          [['DRCC.get_crafting_item', 'jadice', 'smokewood basket', ['jadice']],
           ['DRCC.stow_crafting_item', 'dried jadice', toolbag, settings[:alchemy_belt]]]
        )
        expect(commons.moves).to include('dried jadice: smokewood basket -> hand', "dried jadice: hand -> #{toolbag}")
        expect(commons.location_of('dried jadice')).to eq(toolbag)
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
        expect(tool_locations).to eq(expected_tool_locations)
      end
    end

    describe 'buying a missing liquid or catalyst in the hometown (Crossing, base-crafting.yaml:1388-1416)' do
      let(:settings) { logged_settings.merge(mark_crafted_goods: false, alchemy_room: 8859) }

      # @return [Array<Array>] the bank and travel calls, in order
      def purchase_calls
        commons.calls.select { |name, *| name.start_with?('DRCM.', 'DRCT.') }
      end

      it 'buys water (stock-room 8862, number 1), stows it and walks back to alchemy_room' do
        inventory.delete('water')
        orders[1] = 'water'
        script_short_unguent
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(purchase_calls).to eq([['DRCM.get_money_from_bank', '5 silver'], ['DRCT.order_item', 8862, 1], ['DRCT.walk_to', 8859]])
        expect(commons.moves.first(2)).to eq(['water: shop -> hand', "water: hand -> #{toolbag}"])
        expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', herb_put_command('nemoih', 'large mortar'), *short_run_tail])
      end

      it 'buys alcohol (stock-room 8862, number 2)' do
        inventory.delete('grain alcohol')
        orders[2] = 'alcohol'
        script_short_unguent
        run_remedy(short_unguent)
        expect(purchase_calls).to eq([['DRCM.get_money_from_bank', '5 silver'], ['DRCT.order_item', 8862, 2], ['DRCT.walk_to', 8859]])
        expect(commons.location_of('alcohol')).to eq(toolbag)
      end

      it 'buys a coal nugget catalyst (catalyst-room 8775, number 2)' do
        orders[2] = 'coal nugget'
        script_short_unguent
        run_remedy(typed('remedies 3 "some head unguent" nemoih na "coal nugget" mortar unguent'))
        expect(purchase_calls).to eq([['DRCM.get_money_from_bank', '5 silver'], ['DRCT.order_item', 8775, 2], ['DRCT.walk_to', 8859]])
        expect(commons.location_of('coal nugget')).to eq(toolbag)
      end

      it 'buys nothing when every liquid and the catalyst are on hand' do
        script_short_unguent
        run_remedy(short_unguent)
        expect(purchase_calls).to be_empty
      end
    end

    describe 'the recipe book' do
      it 'turns a master_crafting_book to the recipe and never takes out the remed book' do
        settings[:master_crafting_book] = 'jadeleaf-bound book'
        script_short_unguent
        run_remedy(short_unguent)
        expect(commons.calls).to include(['DRCC.find_recipe2', '3', 'some head unguent', 'jadeleaf-bound book', 'remedies'])
        expect(commons.moves.grep(/remed book/)).to be_empty
      end

      it 'takes the remed book from the crafting bag, finds the recipe in it and puts it back' do
        script_short_unguent
        run_remedy(short_unguent)
        expect(commons.calls).to include(['DRCC.find_recipe2', '3', 'some head unguent'])
        expect(commons.moves.first(2)).to eq(["remed book: #{toolbag} -> hand", "remed book: hand -> #{toolbag}"])
      end

      it 'warns at 175 Alchemy ranks that a journeyman or master book is needed' do
        DRSkill._set_rank('Alchemy', 175)
        script_short_unguent
        run_remedy(short_unguent)
        expect(displayed_messages).to include('*** You will need to upgrade to a journeyman or master book before 176 ranks! ***')
      end
    end

    it 'touches cube_armor_piece before it takes the vessel out' do
      settings[:cube_armor_piece] = 'steel vambraces'
      game.script('touch my steel vambraces', code('A thin cloud of vapor manifests with no particular effect.', from: 'R:198'))
      script_short_unguent
      run_remedy(short_unguent)
      expect(game.sent.first).to eq('touch my steel vambraces')
    end

    it 'releases its spell, mana and symbiosis after the product is out when crafting_training_spells is set' do
      settings[:crafting_training_spells] = { 'Gauge Flow' => {} }
      game.script('release spell', code("You aren't preparing a spell.", from: 'R:416'))
      game.script('release mana', log('25:1316'))
      game.script('release symb', code("But you haven't prepared a symbiosis.", from: 'R:418'))
      script_short_unguent
      expect(run_remedy(short_unguent)).to eq(:exited)
      expect(game.sent.last(4)).to eq(['get my unguent from my large mortar', 'release spell', 'release mana', 'release symb'])
    end

    # remedy.lic:269 and :304 run the routine before and after every pass of
    # work, so at least one call comes between any two crafting commands or
    # steps. A run of a crush with the water cue (25:50210, analog), the
    # water, a crush with Roundtime only, and the crush that finishes.
    # Not pinned: how many calls come between two sends (two today, the
    # second back to back with the first; layer 07 makes it one per pass,
    # a change its ledger records).
    it 'runs the crafting magic routine before every crafting command and step when crafting_training_spells is set' do
      settings[:crafting_training_spells] = { 'Gauge Flow' => {} }
      game.script('release spell', code("You aren't preparing a spell.", from: 'R:416'))
      game.script('release mana', log('25:1316'))
      game.script('release symb', code("But you haven't prepared a symbiosis.", from: 'R:418'))
      script_short_unguent(first_crush: [log('26:11057'), log('25:10825'), log('25:50210')])
      game.script('crush my unguent with my rounded pestle', log('26:11057'), log('25:10825'))
      game.script('crush my unguent with my rounded pestle', log('26:11333'))
      expect(run_remedy(short_unguent)).to eq(:exited)
      magic = '** DRCA.crafting_magic_routine()'
      events = game.timeline.select { |event| event.start_with?('>> ') || event == magic }
      crafting = events.each_index.select { |index| events[index].match?(/\A>> (?:crush my|put water in)/) }
      crush = '>> crush my unguent with my rounded pestle'
      expect(crafting.map { |index| events[index] }).to eq(['>> crush my nemoih with my rounded pestle', '>> put water in my large mortar', crush, crush])
      expect(crafting.map { |index| events[index - 1] }).to all(eq(magic))
      expect(game.sent.last(4)).to eq(['get my unguent from my large mortar', 'release spell', 'release mana', 'release symb'])
    end

    describe ';buff remedy with a remedy waggle set (buff.lic:37-55 casts it; kept)' do
      # A remedy waggle set as buff.lic reads one: spell name => settings.
      let(:settings) { logged_settings.merge(mark_crafted_goods: false, waggle_sets: { 'remedy' => { 'Gauge Flow' => { 'abbrev' => 'gaf', 'mana' => 5 } } }) }

      it 'runs ;buff remedy once, before the crafting magic and the remed book, and crafts as before' do
        script_short_unguent
        expect(run_remedy(short_unguent)).to eq(:exited)
        names = commons.calls.map(&:first)
        expect(commons.calls.count(['DRC.wait_for_script_to_complete', 'buff', ['remedy']])).to eq(1)
        expect(names.index('DRC.wait_for_script_to_complete')).to be < names.index('DRCA.crafting_magic_routine')
        expect(names.index('DRC.wait_for_script_to_complete')).to be < names.index('DRCC.find_recipe2')
        expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', herb_put_command('nemoih', 'large mortar'), *short_run_tail])
      end

      it 'runs ;buff remedy once in the continue form, before the analysis' do
        inventory.delete('diamondique large mortar')
        $right_hand = 'diamondique large mortar'
        game.script('analyze my unguent', log('26:11132'), log('26:11146'))
        game.script('crush my unguent with my rounded pestle', log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        expect(run_remedy(typed('continue na "pewter ingot" mortar unguent'))).to eq(:exited)
        expect(commons.calls.count(['DRC.wait_for_script_to_complete', 'buff', ['remedy']])).to eq(1)
        expect(game.sent.first).to eq('analyze my unguent')
      end
    end

    describe 'finding the vessel in alchemy_tools' do
      # The run stops at the herb, which the character does not carry, so
      # only the vessel get and the stop are seen.
      let(:inventory) { logged_tools.merge(logged_supplies) }

      # Runs remedy with these alchemy_tools and recipe container.
      #
      # @param tools [Array<String>, nil] the alchemy_tools setting
      # @param container [String] the recipe's container word
      # @return [String, nil] the first item asked of get_crafting_item after the book
      def vessel_taken(tools, container)
        settings[:alchemy_tools] = tools
        run_remedy(typed(%(remedies 3 "some head unguent" nemoih na "pewter ingot" #{container} unguent)))
        commons.calls.find { |name, item, *| name == 'DRCC.get_crafting_item' && item != 'remed book' }&.at(1)
      end

      it 'takes the tool that holds the word the recipe asks for' do
        expect(vessel_taken(['rustic mortar', 'rustic pestle', 'mesh sieve'], 'mortar')).to eq('rustic mortar')
      end

      it 'takes a cauldron for a recipe that asks for a bowl' do
        expect(vessel_taken(['rustic mortar', 'rustic pestle', 'iron cauldron'], 'bowl')).to eq('iron cauldron')
      end

      it 'takes a bowl for a recipe that asks for a bowl' do
        expect(vessel_taken(['rustic mortar', 'rustic pestle', 'mesh sieve', 'ceramic bowl'], 'bowl')).to eq('ceramic bowl')
      end

      it 'stops before any command when no tool matches a mortar' do
        settings[:alchemy_tools] = ['ceramic bowl']
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(remedy_messages.first).to include('some head unguent', 'mortar', 'alchemy_tools')
        expect(game.sent).to be_empty
        expect(commons.calls).to be_empty
      end

      it 'takes a word the recipe gives in part (prefix container words such as mort)' do
        expect(vessel_taken(['heavy cauldron', 'large mortar', 'rounded pestle'], 'mort')).to eq('large mortar')
      end

      it 'stops before any command when no tool matches, naming the recipe, the vessel and the setting' do
        settings[:alchemy_tools] = ['rustic mortar', 'rustic pestle', 'mesh sieve']
        expect(run_remedy(typed('remedies 2 "some eye wash" "blue flower" aevaes "pewter ingot" bowl wash'))).to eq(:exited)
        expect(remedy_messages.first).to include('some eye wash', 'bowl', 'alchemy_tools')
        expect(remedy_messages.last).to include('Add your bowl to alchemy_tools')
        expect(game.sent).to be_empty
        expect(commons.calls).to be_empty
      end

      it 'stops before any command when alchemy_tools is empty or unset' do
        [[], nil].product(%w[mortar bowl]).each do |tools, container|
          settings[:alchemy_tools] = tools
          expect(run_remedy(typed(%(remedies 3 "some head unguent" nemoih na "pewter ingot" #{container} unguent)))).to eq(:exited)
          expect(game.sent).to be_empty
        end
      end
    end
  end

  describe 'C14: how Lich hands remedy its arguments (the contract)' do
    recipes = YAML.load_file(File.expand_path('../data/base-recipes.yaml', __dir__), aliases: true)['crafting_recipes']
                  .select { |recipe| recipe['type'] == 'remedies' }
    chaptered = recipes.reject { |recipe| recipe['chapter'].nil? }

    # The fields parse_args returns (read from the ArgParser model); the run
    # is then cut short, before remedy acts on them.
    #
    # @param vars [Array<String>] Lich's `variable`
    # @return [Hash, nil] nil when no form matched (the script stopped)
    def parsed(vars)
      fields = nil
      catch(:remedy_spec_parsed) do
        run_remedy(vars) do
          allow(ArgParserModel).to receive(:parse).and_wrap_original do |original, *args, **options|
            fields = original.call(*args, **options).to_h
            throw :remedy_spec_parsed
          end
        end
      end
      fields
    end

    # The 8-argument fields remedy gets for a recipe, as parse_args downcases them.
    #
    # @param recipe [Hash] a base-recipes.yaml entry
    # @param herb1 [String]
    # @param herb2 [String]
    # @param catalyst [String]
    # @return [Hash{Symbol => String}]
    def book_fields(recipe, herb1:, herb2:, catalyst:)
      { book_type: 'remedies', chapter: recipe['chapter'].to_s, recipe_name: recipe['name'], herb1: herb1.downcase,
        herb2: herb2.downcase, catalyst: catalyst, container: recipe['container'], noun: recipe['noun'] }
    end

    it 'parses the workorders.lic:818/820 and craft.lic:680 call of every chaptered base-recipes remedy into the 8-argument form' do
      mismatches = chaptered.filter_map do |recipe|
        herb2 = recipe['herb2'] || 'na'
        args = ['remedies', recipe['chapter'], recipe['name'], recipe['herb1'], herb2, 'coal nugget', recipe['container'], recipe['noun']]
        expected = book_fields(recipe, herb1: recipe['herb1'], herb2: herb2, catalyst: 'coal nugget')
        [recipe['name'], parsed(called_with(args))] unless parsed(called_with(args)) == expected
      end
      expect(mismatches).to be_empty
    end

    it 'parses the create_remedies.lic:47/49 call (flower herbs swapped, catalyst given) of every chaptered remedy' do
      swap = { 'red flower' => 'dried flower', 'blue flower' => 'crushed flower' }
      mismatches = chaptered.filter_map do |recipe|
        herb1 = swap.fetch(recipe['herb1'], recipe['herb1'])
        herb2 = recipe['herb2'] || 'na'
        args = ['remedies', recipe['chapter'], recipe['name'], herb1, herb2, 'pewter', recipe['container'], recipe['noun']]
        expected = book_fields(recipe, herb1: herb1, herb2: herb2, catalyst: 'pewter')
        [recipe['name'], parsed(called_with(args))] unless parsed(called_with(args)) == expected
      end
      expect(mismatches).to be_empty
    end

    it 'covers all 63 chaptered remedies of base-recipes.yaml' do
      expect(chaptered.size).to eq(63)
    end

    {
      'remedies 2 "blister cream" "red flower" nemoih bar mortar cream' => # remedy.lic:5
        { book_type: 'remedies', chapter: '2', recipe_name: 'blister cream', herb1: 'red flower', herb2: 'nemoih',
          catalyst: 'bar', container: 'mortar', noun: 'cream' },
      'remedies 2 "blister cream" nemoih "not used" bar mortar cream' => # remedy.lic:6
        { book_type: 'remedies', chapter: '2', recipe_name: 'blister cream', herb1: 'nemoih', herb2: 'not used',
          catalyst: 'bar', container: 'mortar', noun: 'cream' },
      'remedies 3 "Some Head Unguent" Nemoih none "Pewter Ingot" mort Unguent' =>
        { book_type: 'remedies', chapter: '3', recipe_name: 'some head unguent', herb1: 'nemoih', herb2: 'none',
          catalyst: 'pewter ingot', container: 'mort', noun: 'unguent' },
      'remedies 6 "a general elixir" belradi na "coal nugget" bowl brew' =>
        { book_type: 'remedies', chapter: '6', recipe_name: 'a general elixir', herb1: 'belradi', herb2: 'na',
          catalyst: 'coal nugget', container: 'bowl', noun: 'brew' },
      'continue none "pewter ingot" mortar unguent' =>
        { continue: 'continue', herb2: 'none', catalyst: 'pewter ingot', container: 'mortar', noun: 'unguent' },
      'continue na pewter cauldron elixir' =>
        { continue: 'continue', herb2: 'na', catalyst: 'pewter', container: 'cauldron', noun: 'elixir' }
    }.each do |line, fields|
      it "parses the typed form ;remedy #{line}" do
        expect(parsed(typed(line))).to eq(fields)
      end
    end

    it 'prints the help and stops before any command when the arguments match no form' do
      expect(run_remedy(typed('remedies 2 "blister cream"'))).to eq(:exited)
      expect(displayed_messages).to include(ArgParserModel::NO_MATCH_MESSAGE)
      expect(game.sent).to be_empty
      expect(commons.calls).to be_empty
    end

    it 'stops the same way for some alyssum tea, whose base-recipes entry has no chapter (a caller passes nil)' do
      tea = recipes.find { |recipe| recipe['name'] == 'some alyssum tea' }
      args = ['remedies', tea['chapter'], tea['name'], tea['herb1'], tea['herb2'], 'coal nugget', tea['container'], tea['noun']]
      expect(parsed(called_with(args))).to be_nil
      expect(game.sent).to be_empty
    end
  end

  describe 'reading the game, not other players' do
    let(:settings) { logged_settings.merge(mark_crafted_goods: false) }
    let(:inventory) { logged_tools.merge(logged_supplies, 'dried nemoih' => toolbag, 'dried jadice' => toolbag) }
    let(:gathered) { ['count my nemoih', 'combine my nemoih', herb_put_command('nemoih', 'large mortar')] }

    # A game line as another player's ESP, speech or whisper shows it: the
    # text follows a double quote, which NO_QUOTE (remedy.lic:9-14) refuses.
    #
    # @param text [String] the game's words
    # @return [Array<ReplayGame::Line>] ESP, speech and whisper
    def spoofs(text)
      [%(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
       %(<preset id='speech'>Mallory says</preset>, "#{text}"),
       %(<pushStream id="whispers"/><preset id="whisper">Mallory whispers,</preset> "#{text}")]
        .map { |spoof| code(spoof, from: 'player ESP, speech and whisper forms (remedy.lic:9-14)') }
    end

    # The game's own line, as is, behind an XML tag, and after other game text
    # on the same line (the forms remedy.lic:9-14 allows).
    #
    # @param line [ReplayGame::Line]
    # @return [Array<ReplayGame::Line>]
    def game_forms(line)
      [line,
       code("<pushBold/>#{line.text}", from: "#{line.cite} behind an XML tag (remedy.lic:9-14)"),
       code("#{log('26:11057').text}  #{line.text}", from: "26:11057 and #{line.cite} on one line (remedy.lic:9-14)")]
    end

    describe 'a cue that asks for a step' do
      herb_cue = 'You need another prepared herb to continue crafting some unfinished nemoih unguent.'
      [['remedy-water', '25:50210', 'put water in my large mortar'],
       ['remedy-alcohol', '25:10873', 'put alcohol in my large mortar'],
       ['remedy-catalyst', '25:11049', 'put my pewter ingot in my large mortar'],
       ['remedy-herb', nil, 'put my jadice in my large mortar'],
       ['remedy-turn', '26:7707', 'turn my large mortar'],
       ['remedy-turn', '26:6031', 'turn my large mortar'],
       ['remedy-smell', '25:11004', 'smell my unguent'],
       ['remedy-smell', '26:12950', 'smell my unguent'],
       ['remedy-sieve', '25:11149', 'push my unguent with my sieve'],
       ['remedy-sieve', '25:11959', 'push my unguent with my sieve']].each do |flag, cite, step|
        # code-derived (remedy.lic:51): no "prepared herb" line is in either log.
        cue = -> { cite ? ReplayGame.log(cite) : ReplayGame.code(herb_cue, from: 'R:51 /You need another prepared herb/') }

        3.times do |form|
          it "#{flag}: sends #{step.inspect} for the game's line #{cite || 'R:51'} (form #{form + 1} of 3)" do
            script_short_unguent(put_lines: [log('26:10749'), game_forms(cue.call)[form]])
            run_remedy(short_unguent(herb2: 'jadice'))
            expect(game.sent).to include(step)
            expect(game.sent.last(2)).to eq(['crush my nemoih with my rounded pestle', 'get my unguent from my large mortar'])
          end

          it "#{flag}: ignores #{cite || 'R:51'} in another player's line (form #{form + 1} of 3)" do
            script_short_unguent(put_lines: [log('26:10749'), spoofs(cue.call.text)[form]])
            run_remedy(short_unguent(herb2: 'jadice'))
            expect(game.sent).to eq([*gathered, 'crush my nemoih with my rounded pestle', 'get my unguent from my large mortar'])
          end
        end
      end
    end

    # The anchored patterns of the herb gathering (remedy.lic:235-237, :247),
    # each with its game line, then the same line as another player's.
    describe 'gathering the herb' do
      let(:short_run_tail) { ['crush my nemoih with my rounded pestle', 'get my unguent from my large mortar'] } # 26:11333, 26:11389

      # One stack of 25 (25:33679) from the toolbag, combined with
      # +combine+, put with +put+, and the short run's end.
      #
      # @param combine [Array<ReplayGame::Line>] the reply to the combine
      # @param put [Array<ReplayGame::Line>] the reply to the first put
      # @return [void]
      def script_one_stack_with(combine:, put: [log('26:10749')])
        game.script('count my nemoih', log('25:33679'))
        game.script('combine my nemoih', *combine)
        game.script(herb_put_command('nemoih', 'large mortar'), *put, after: ->(_game) { commons.release('nemoih') })
        game.fallback(herb_put_command('nemoih', 'large mortar'), log('26:10749'), after: ->(_game) { commons.release('nemoih') })
        game.script('crush my nemoih with my rounded pestle', log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
      end

      # The 21 + 75 path of the contract ("tops up a stack of 21 ..."): two
      # stacks in the toolbag, counted 21 (25:12538) then 75 (25:8678), the
      # second combine "too large" (25:30006), then the two ordinal counts
      # answered as given.
      #
      # @param first_count [Array<ReplayGame::Line>] the reply to `count my first nemoih`
      # @param second_count [Array<ReplayGame::Line>] the reply to `count my second nemoih`
      # @return [void]
      def script_two_stacks(first_count:, second_count:)
        commons.inventory << ReplayCommons::Item.new('dried nemoih', toolbag)
        game.script('count my nemoih', log('25:12538'))
        game.script('combine my nemoih', log('25:104590'))
        game.script('count my nemoih', log('25:8678'))
        game.script('combine my nemoih', log('25:30006'))
        game.script('count my first nemoih', *first_count)
        game.script('count my second nemoih', *second_count)
        game.script(herb_put_command('nemoih', 'large mortar'), log('26:10749'), after: ->(_game) { commons.release('nemoih') })
        game.script('crush my nemoih with my rounded pestle', log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
      end

      # @return [Array<String>] the commands of the 21 + 75 path
      def two_stack_commands
        ['count my nemoih', 'combine my nemoih', 'count my nemoih', 'combine my nemoih',
         'count my first nemoih', 'count my second nemoih', herb_put_command('nemoih', 'large mortar'), *short_run_tail]
      end

      # @param ordinal [String] "first" or "second"
      # @return [Array<Array>] the helper calls naming that stack (the
      #   stack remedy puts away; which helper does it is not pinned)
      def calls_naming(ordinal)
        commons.calls.select { |_name, item, *| item == "#{ordinal} nemoih" }
      end

      3.times do |form|
        it "checks the stacks only on the game's \"too large\" (25:30006), not on another player's line (form #{form + 1} of 3)" do
          script_one_stack_with(combine: [spoofs(log('25:30006').text)[form], log('25:104590')])
          expect(run_remedy(short_unguent)).to eq(:exited)
          expect(game.sent).to eq([*gathered, *short_run_tail])
        end
      end

      it 'puts away the second stack when the game counts 75 in the first (25:8678, then 21 25:12538)' do
        script_two_stacks(first_count: [log('25:8678')], second_count: [log('25:12538')])
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent).to eq(two_stack_commands)
        expect(calls_naming('second')).not_to be_empty
        expect(calls_naming('first')).to be_empty
      end

      3.times do |form|
        it "puts away a stack only when the game counts 75 pieces, not when another player says it (form #{form + 1} of 3)" do
          script_two_stacks(first_count: [spoofs(log('25:8678').text)[form], log('25:12538')], second_count: [log('25:8678')])
          expect(run_remedy(short_unguent)).to eq(:exited)
          expect(game.sent).to eq(two_stack_commands)
          expect(calls_naming('second')).to be_empty
          expect(calls_naming('first')).not_to be_empty
        end
      end

      # code-derived: remedy.lic:247 /already has something/ (the real
      # wording is pinned in "tilts the vessel twice ..." above).
      3.times do |form|
        it "tilts the vessel only when the game says it is not empty, not another player (form #{form + 1} of 3)" do
          full = code('Your large mortar already has something in it.', from: 'R:247 /already has something/')
          script_one_stack_with(combine: [log('25:104590')], put: [spoofs(full.text)[form], log('26:10749')])
          expect(run_remedy(short_unguent)).to eq(:exited)
          expect(game.sent).to eq([*gathered, *short_run_tail])
        end
      end
    end

    describe 'the count of a water vessel' do
      let(:settings) { logged_settings.merge(mark_crafted_goods: false, water_container: 'glass flask') }
      let(:inventory) { logged_tools.merge(logged_supplies, 'dried nemoih' => toolbag, 'glass flask' => toolbag) }
      # code-derived (remedy.lic:74 /parts left of the/): no count of a vessel is in either log.
      let(:parts_left) { code('There are five parts left of the water.', from: 'R:74 /parts left of the/') }

      [nil, 0, 1, 2].each do |form|
        it "refills a vessel the game cannot find (25:13762) and pours from it#{" (a player's line first, form #{form + 1})" if form}" do
          game.script('count water in my glass flask', *[(spoofs(parts_left.text)[form] if form), log('25:13762')].compact)
          game.script('count water in my glass flask', parts_left)
          script_short_unguent(put_lines: [log('26:10749'), log('25:50210')])
          game.fallback('pour glass flask in my large mortar', log('26:10830'))
          run_remedy(short_unguent)
          expect(game.sent).to include('rub my glass flask', 'pour glass flask in my large mortar')
        end

        it "pours from a vessel the game counts without refilling it#{" (a player's line first, form #{form + 1})" if form}" do
          game.script('count water in my glass flask', *[(spoofs(log('25:13762').text)[form] if form), parts_left].compact)
          script_short_unguent(put_lines: [log('26:10749'), log('25:50210')])
          game.fallback('pour glass flask in my large mortar', log('26:10830'))
          run_remedy(short_unguent)
          expect(game.sent).not_to include('rub my glass flask')
          expect(game.sent).to include('pour glass flask in my large mortar')
        end
      end
    end

    describe 'the reply to a crafting command' do
      ['Applying the final touches', 'Interesting thought really... but no.', "you just can't mix",
       'Try as you might', 'That craftable requires more pieces of that plant to begin'].each do |phrase|
        3.times do |form|
          it "keeps crafting when another player says #{phrase.inspect} (form #{form + 1} of 3)" do
            script_short_unguent(first_crush: [spoofs(phrase)[form], log('25:10825')])
            run_remedy(short_unguent)
            expect(game.sent.drop(3)).to eq(['crush my nemoih with my rounded pestle', 'crush my unguent with my rounded pestle',
                                             'get my unguent from my large mortar'])
          end
        end
      end

      3.times do |form|
        it "finishes on the final-touches line (26:11333) after another player says Roundtime: (form #{form + 1} of 3)" do
          script_short_unguent(first_crush: [spoofs('Roundtime: 3 sec.')[form], log('26:11333')])
          run_remedy(short_unguent)
          expect(game.sent.drop(3)).to eq(['crush my nemoih with my rounded pestle', 'get my unguent from my large mortar'])
        end
      end

      # code-derived: the bracketed form the earlier spec used
      # (spec/remedy_spec.rb:297 at 03f11b54); the logs have only
      # "[Roundtime 2 sec.]" (26:111418), outside crafting.
      it 'keeps crafting on a bracketed Roundtime: line' do
        script_short_unguent(first_crush: [code('[Roundtime: 3 sec]', from: 'spec/remedy_spec.rb:297 at 03f11b54')])
        run_remedy(short_unguent)
        expect(game.sent.drop(3)).to eq(['crush my nemoih with my rounded pestle', 'crush my unguent with my rounded pestle',
                                         'get my unguent from my large mortar'])
      end
    end

    describe 'adding water' do
      # code-derived (remedy.lic:313): no such refusal is in either log.
      let(:refused) { code('You cannot find a way to add that as an ingredient.', from: 'R:313') }

      # A short run whose water step is answered by +reply+.
      #
      # @param reply [Array<ReplayGame::Line>]
      # @return [Symbol] how the run ended
      def add_water_with(*reply)
        game.script('put water in my large mortar', *reply)
        script_short_unguent(put_lines: [log('26:10749'), log('25:50210')])
        run_remedy(short_unguent)
      end

      it 'puts the water itself into the vessel when the game refuses the pour' do
        add_water_with(refused)
        expect(commons.calls).to include(['DRCI.put_away_item?', 'water', 'large mortar'])
      end

      3.times do |form|
        it "does not fall back when only another player's line says it (form #{form + 1} of 3)" do
          add_water_with(spoofs(refused.text)[form], log('25:10825'))
          expect(commons.calls).not_to include(['DRCI.put_away_item?', 'water', 'large mortar'])
        end

        it "still falls back when another player says Roundtime before the refusal (form #{form + 1} of 3)" do
          add_water_with(spoofs('Roundtime: 2 sec.')[form], refused)
          expect(commons.calls).to include(['DRCI.put_away_item?', 'water', 'large mortar'])
        end
      end
    end
  end

  describe 'paths that are broken today (CURRENT; each is flipped by the layer its comment names)' do
    let(:settings) { logged_settings.merge(mark_crafted_goods: false) }
    let(:inventory) { logged_tools.merge(logged_supplies, 'dried nemoih' => toolbag) }
    let(:first_crush) { 'crush my nemoih with my rounded pestle' }

    describe 'the crafting loop' do
      # layer 08: the refusal stops the run (25:50933 is the whole reply to
      # the crush 25:50932)
      it 'H02: stops after the one crush that "You need a more suitable type of herb" (25:50933) refuses, naming the herb' do
        game.override(first_crush, log('25:50933'), times: nil)
        script_short_unguent
        expect(run_remedy(short_unguent) { allow(DRC).to receive(:beep) }).to eq(:exited)
        expect(DRC).to have_received(:beep).once
        expect(game.sent.drop(3)).to eq([first_crush])
        expect(game.diagnostics).to be_empty
        expect(game.trace.select { |event| event.kind == :stall }).to be_empty
        expect(remedy_messages).to eq(["Remedy: the game wants a more suitable type of herb than nemoih: it refused #{first_crush.inspect}. Stopping."])
        expect(commons.location_of('diamondique large mortar')).to eq('left').or eq('right')
      end

      # layer 07: the loop is bounded
      it 'D06: stops with a beep and a Remedy line naming the first crush once four sends of it go unanswered, the mortar still in hand' do
        script_short_unguent(first_crush: [])
        expect(run_remedy(short_unguent) { allow(DRC).to receive(:beep) }).to eq(:exited)
        expect(DRC).to have_received(:beep).once
        expect(game.sent.drop(3)).to eq([first_crush] * 4)
        expect(game.diagnostics).to eq(["DRC: No match was found after 15 seconds for command '#{first_crush}' (0 lines seen)"] * 4)
        expect(remedy_messages).to eq(["Remedy: the game did not answer #{first_crush.inspect} 4 times in a row. Stopping."])
        expect(commons.location_of('diamondique large mortar')).to eq('left').or eq('right')
        expect(commons.location_of('unguent')).to be_nil
      end

      context 'with a larger send budget' do
        let(:game) { ReplayGame.new(send_budget: 200) }

        # layer 07: the loop is bounded
        it 'stops with a Remedy line after 100 crafting commands when every one is answered by Roundtime alone (25:10825)' do
          script_short_unguent(first_crush: [log('25:10825')])
          game.override('crush my unguent with my rounded pestle', log('25:10825'), times: nil)
          expect(run_remedy(short_unguent)).to eq(:exited)
          expect(game.sent.drop(3)).to eq([first_crush] + (['crush my unguent with my rounded pestle'] * 99))
          expect(game.diagnostics).to be_empty
          expect(remedy_messages).to eq(['Remedy: the unguent is not done after 100 crafting commands. Stopping.'])
          expect(commons.location_of('diamondique large mortar')).to eq('left').or eq('right')
        end
      end

      # layer 08: MORE_PIECES stops the run, so no product get is sent and
      # layer 12 has no product get to check here. Only the end state that
      # stays is pinned: what happens to the stirrer on a stop belongs to
      # the before_dying cleanup (layer 12).
      it 'D08: stops on "requires more pieces of that plant" with a Remedy line and no product get, the mortar still in hand' do
        game.override(first_crush, code('That craftable requires more pieces of that plant to begin.', from: 'R:290'))
        game.override('get my unguent from my large mortar', log('26:39162')) # analog: the not-found reply to a get
        script_short_unguent
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent.drop(3)).to eq([first_crush])
        expect(commons.location_of('unguent')).to be_nil
        expect(commons.location_of('diamondique large mortar')).to eq('left').or eq('right')
        expect(remedy_messages).to eq(["Remedy: the unguent needs more pieces of nemoih to begin: the game refused #{first_crush.inspect}. Stopping."])
      end

      # layer 08: STEP_UNSUITABLE ends the handler's wait. The second turn
      # stays: a cue in a step's own reply is kept for the next pass (the
      # Handlers unit specs), and remedy cannot tell a repeated cue from a
      # new one.
      it "D11: turns again when the clumps cue repeats after the turn, and the game's refusal (26:25113) ends the wait at once" do
        script_general_elixir(replace: { 6084 => [log('26:6086'), log('26:6088'), log('26:6031')] }, inject: { 6249 => [log('26:25113')] })
        settings[:mark_crafted_goods] = true
        inventory['crushed belradi'] = toolbag
        expect(run_remedy(workorders_call('a general elixir', 6, 'belradi', 'bowl', 'elixir', catalyst: 'pewter ingot'))).to eq(:exited)
        first_turn = game.sent.index('turn my heavy cauldron')
        expect(game.sent[first_turn, 3]).to eq(['turn my heavy cauldron', 'turn my heavy cauldron', 'mix my heavy cauldron with my mixing stick'])
        expect(game.diagnostics).to be_empty
        expect(game.trace.select { |event| event.kind == :stall }).to be_empty
        expect(commons.location_of('belradi elixir')).to eq('left').or eq('right')
      end
    end

    describe 'a missing ingredient (C04: the catalyst get answered "What were you referring to?", 26:39162)' do
      let(:settings) { logged_settings }
      let(:inventory) { logged_tools.merge(logged_supplies.except('pewter ingot'), 'crushed belradi' => toolbag) }
      let(:mix) { 'mix my heavy cauldron with my mixing stick' }

      # C01 with no pewter ingot anywhere.
      #
      # @return [Symbol] how the run ended
      def run_without_the_catalyst
        script_general_elixir
        # The put with no ingot in hand is answered as in run 26_38755
        # (26:39194); from then on the game refuses each mix with the
        # catalyst cue alone (26:39150, analog: the same refusal to a push).
        refuse_mixes = ->(replay) { replay.override(mix, log('26:39150'), log('26:39152'), times: nil) }
        game.override('put my pewter ingot in my heavy cauldron', log('26:39194'), times: nil, after: refuse_mixes)
        run_remedy(workorders_call('a general elixir', 6, 'belradi', 'bowl', 'elixir', catalyst: 'pewter ingot'))
      end

      # layer 09 (guarded gets): one clean stop, the same on every release
      ReplayCommons::LICH5_RELEASES.each do |release|
        context "on lich-5 #{release}" do
          let(:lich5) { release }

          it 'D14/D02/D15: stops with one Remedy line naming the pewter ingot, before any put, the stick put away and the cauldron in hand' do
            allow(DRC).to receive(:beep)
            expect(run_without_the_catalyst).to eq(:exited)
            # DRCC's beep before its missing line (v5.21.0 and v5.22.0
            # common-crafting.rb:344, 480bdee3 :517), then Remedy.stop's.
            expect(DRC).to have_received(:beep).twice
            expect(remedy_messages).to eq(['Remedy: could not get pewter ingot. Stopping.'])
            expect(commons.messages).to eq(['DRCC: You seem to be missing: pewter ingot'])
            expect(commons.calls).to include(['DRCC.get_crafting_item', 'pewter ingot', toolbag, logged_settings[:crafting_items_in_container],
                                              logged_settings[:alchemy_belt], true])
            expect(game.sent.last).to eq(mix) # the mix that drew the catalyst cue (26:6313)
            expect(game.sent).not_to include('put my pewter ingot in my heavy cauldron')
            expect(commons.location_of('heavy cauldron')).to eq('left').or eq('right')
            expect(commons.location_of('luminescent starshine mixing stick')).to eq(toolstrap)
            expect(exit_hooks).not_to be_empty
            exit_hooks.each(&:call)
            expect(remedy_flags).to be_empty
          end
        end
      end
    end

    describe 'liquids and their vessels' do
      let(:settings) { logged_settings.merge(mark_crafted_goods: false, water_container: 'glass flask') }
      let(:inventory) { logged_tools.merge(logged_supplies, 'dried nemoih' => toolbag, 'glass flask' => toolbag) }

      # Not CURRENT: remedy keeps a timed-out count meaning "the
      # vessel has liquid" (the only positive pattern has no log hit).
      it 'takes a vessel whose count gets no reply as holding water, and pours from it without a refill' do
        script_short_unguent(put_lines: [log('26:10749'), log('25:50210')])
        game.fallback('pour glass flask in my large mortar', log('26:10830'))
        run_remedy(short_unguent)
        expect(game.sent).not_to include('rub my glass flask')
        expect(game.sent).to include('pour glass flask in my large mortar')
      end

      # Not CURRENT: remedy.lic:79 keeps its wording unless real text proves
      # another.
      it 'rubs a vessel the game cannot find, gets water from the crafting bag into it and counts again' do
        game.script('count water in my glass flask', log('25:13762'))
        game.script('count water in my glass flask', log('25:13762'))
        script_short_unguent
        run_remedy(short_unguent)
        expect(game.sent.first(5)).to eq(['count water in my glass flask', 'rub my glass flask', "get water from #{toolbag}",
                                          'put water in my glass flask', 'count water in my glass flask'])
      end

      # The alcohol vessel: the same code as the water vessel (remedy.lic:90-105).
      context 'with an alcohol_container and no water_container' do
        let(:settings) { logged_settings.merge(mark_crafted_goods: false, alcohol_container: 'moonshine jug') }
        let(:inventory) { logged_tools.merge(logged_supplies, 'dried nemoih' => toolbag, 'moonshine jug' => toolbag) }
        # code-derived (remedy.lic:92 /parts left of the/): no count of a vessel is in either log.
        let(:parts_left) { code('There are five parts left of the alcohol.', from: 'R:92 /parts left of the/') }

        # A short run whose first crush draws the alcohol cue 25:10873; the
        # jug's pour is answered as the logged pour of alcohol (25:10905).
        #
        # @return [void]
        def script_alcohol_run
          script_short_unguent(put_lines: [log('26:10749'), log('25:10873')])
          game.fallback('pour moonshine jug in my large mortar', log('25:10905'))
        end

        it 'pours from a jug the game counts, without refilling it' do
          game.script('count alcohol in my moonshine jug', parts_left)
          script_alcohol_run
          expect(run_remedy(short_unguent)).to eq(:exited)
          expect(game.sent.first).to eq('count alcohol in my moonshine jug')
          expect(game.sent).not_to include('rub my moonshine jug')
          expect(game.sent).to include('pour moonshine jug in my large mortar')
          expect(commons.location_of('moonshine jug')).to eq(toolbag)
        end

        # Not CURRENT: kept on purpose, as for the water vessel.
        it 'takes a jug whose count gets no reply as holding alcohol, and pours from it without a refill' do
          script_alcohol_run
          expect(run_remedy(short_unguent)).to eq(:exited)
          expect(game.sent).not_to include('rub my moonshine jug')
          expect(game.sent).to include('pour moonshine jug in my large mortar')
        end

        it 'rubs a jug the game cannot find (25:13762), gets alcohol from the crafting bag into it, counts again and pours' do
          game.script('count alcohol in my moonshine jug', log('25:13762'))
          game.script('count alcohol in my moonshine jug', parts_left)
          script_alcohol_run
          expect(run_remedy(short_unguent)).to eq(:exited)
          expect(game.sent.first(5)).to eq(['count alcohol in my moonshine jug', 'rub my moonshine jug', "get alcohol from #{toolbag}",
                                            'put alcohol in my moonshine jug', 'count alcohol in my moonshine jug'])
          expect(game.sent).to include('pour moonshine jug in my large mortar')
        end
      end

      # layer 10 (H07): an empty vessel is stowed by name
      it 'H07: after two failed counts (25:13762), puts the flask away by name before crafting and adds plain water' do
        game.script('count water in my glass flask', log('25:13762'))
        game.script('count water in my glass flask', log('25:13762'))
        script_short_unguent(put_lines: [log('26:10749'), log('25:50210')])
        expect(run_remedy(short_unguent)).to eq(:exited)
        stows = commons.calls.select { |name, *| name == 'DRCC.stow_crafting_item' }.map { |call| call[1] }
        expect(stows.first).to eq('glass flask')
        flask_stowed = commons.calls.index { |name, item, *| name == 'DRCC.stow_crafting_item' && item == 'glass flask' }
        expect(flask_stowed).to be < commons.calls.index(['DRCA.crafting_magic_routine'])
        expect(commons.location_of('glass flask')).to eq(toolbag)
        expect(game.sent).to include('put water in my large mortar')
        expect(game.sent).not_to include('pour glass flask in my large mortar')
      end

      # layer 10 (H18): no `get my water from my water`
      it 'H18: with no vessel, the refused-put fallback gets water from the crafting bag (26:10824), never from "water"' do
        settings[:water_container] = nil
        game.script('put water in my large mortar', code('You cannot find a way to add that as an ingredient.', from: 'R:313'))
        script_short_unguent(put_lines: [log('26:10749'), log('25:50210')])
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(commons.calls).not_to include(['DRCI.get_item?', 'water', 'water'])
        water_gets = commons.calls.each_index.select { |at| commons.calls[at][0, 2] == ['DRCC.get_crafting_item', 'water'] }
        expect(water_gets.size).to eq(2) # the add's own get, then the fallback's
        expect(commons.calls[water_gets.last]).to eq(['DRCC.get_crafting_item', 'water', toolbag, logged_settings[:crafting_items_in_container],
                                                      logged_settings[:alchemy_belt], false])
        expect(commons.calls[water_gets.last + 1]).to eq(['DRCI.put_away_item?', 'water', 'large mortar'])
      end

      # layer 10 (D03): "Pour what?" refills, then stops
      it 'D03: an empty alcohol vessel answered "Pour what?" (26:22405) is rubbed and refilled once, then remedy stops with no loop' do
        settings.merge!(alcohol_container: 'moonshine jug', water_container: nil)
        inventory['moonshine jug'] = toolbag
        inventory['crushed belradi'] = toolbag
        allow(DRC).to receive(:beep)
        # The jug's count gets no reply (no vessel count is in the logs), so
        # remedy pours from it (H06, kept by A4). "Pour what?" is the reply
        # to `pour part alcohol in my heavy cauldron` with the jug in hand
        # (26:22403, analog); while the alcohol is owed the game refuses each
        # mix with the cue alone (26:22342, the reply to a mix at 26:22337).
        # The rub's reply is the jug's (26:22410); the refill does not help.
        refuse_mixes = ->(replay) { replay.override('mix my heavy cauldron with my mixing stick', log('26:22342'), log('26:22344'), times: nil) }
        script_one_stack('belradi', vessel: 'heavy cauldron', put_lines: [log('26:5898')])
        game.script('mix my heavy cauldron with my mixing stick', log('26:5913'), log('26:5915'), log('26:5918'), log('26:5920'))
        game.override('pour moonshine jug in my heavy cauldron', log('26:22405'), times: nil, after: refuse_mixes)
        game.script('rub my moonshine jug', log('26:22410'))
        expect(run_remedy(typed('remedies 6 "a general elixir" belradi na "pewter ingot" bowl elixir'))).to eq(:exited)
        expect(game.sent.count('pour moonshine jug in my heavy cauldron')).to eq(2)
        expect(game.sent.last(6)).to eq(['pour moonshine jug in my heavy cauldron', 'rub my moonshine jug', "get alcohol from #{toolbag}",
                                         'put alcohol in my moonshine jug', 'count alcohol in my moonshine jug',
                                         'pour moonshine jug in my heavy cauldron'])
        expect(remedy_messages).to eq(["Remedy: the moonshine jug has no alcohol to pour, even after rubbing it and filling it from the #{toolbag}. Stopping."])
        expect(commons.location_of('moonshine jug')).to eq('left').or eq('right')
        expect(exit_hooks).not_to be_empty
        exit_hooks.each(&:call)
        expect(remedy_flags).to be_empty
      end

      it 'D03: goes on crafting when the refill gives the jug alcohol to pour (26:7687)' do
        settings.merge!(alcohol_container: 'moonshine jug', water_container: nil)
        inventory['moonshine jug'] = toolbag
        inventory['crushed belradi'] = toolbag
        # As the example above, but the second pour is taken: "You toss the
        # alcohol into the cauldron ..." (26:7687, the reply to
        # `pour part alcohol in my heavy cauldron` at 26:7686, analog).
        script_one_stack('belradi', vessel: 'heavy cauldron', put_lines: [log('26:5898')])
        game.script('mix my heavy cauldron with my mixing stick', log('26:5913'), log('26:5915'), log('26:5918'), log('26:5920'))
        game.script('pour moonshine jug in my heavy cauldron', log('26:22405'))
        game.script('rub my moonshine jug', log('26:22410'))
        game.script('pour moonshine jug in my heavy cauldron', log('26:7687'))
        game.fallback('mix my heavy cauldron with my mixing stick', log('26:6742'))
        script_product('get my elixir from my heavy cauldron', log('26:6794'), 'belradi elixir')
        allow(DRC).to receive(:beep)
        expect(run_remedy(typed('remedies 6 "a general elixir" belradi na "pewter ingot" bowl elixir'))).to eq(:exited)
        expect(game.sent.count('pour moonshine jug in my heavy cauldron')).to eq(2)
        expect(game.sent.count('rub my moonshine jug')).to eq(1)
        expect(remedy_messages).to be_empty
        expect(commons.location_of('belradi elixir')).to eq('left').or eq('right')
      end
    end

    describe 'gathering the herb' do
      # layer 11 (count only what is held): the commands are today's; the 21
      # pieces are no longer taken for 25
      it 'H04: says it gathered only 21 pieces when "You must be holding both" (25:18266) ends the gathering, and crafts with them' do
        inventory['dried nemoih'] = 'seasilk apron'
        game.script('count my nemoih', log('25:12538'))
        game.script('combine my nemoih', log('25:18266'))
        game.script(herb_put_command('nemoih', 'large mortar'), log('26:10749'), after: ->(_game) { commons.release('nemoih') })
        game.script(first_crush, log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent).to eq(['count my nemoih', 'stow my nemoih', 'combine my nemoih',
                                 herb_put_command('nemoih', 'large mortar'), first_crush, 'get my unguent from my large mortar'])
        expect(remedy_messages).to eq(['Remedy: gathered only 21 pieces of nemoih (a remedy takes 25); crafting with what is in hand.'])
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
      end

      # layer 11 (a deliberate change: one extra
      # count in the combine path only). Assumption (unverified,
      # H05): with two stacks in hand `count` counts the one picked up first,
      # so today the 10 + 10 + 20 = 40 counted ended the gathering with 22
      # held and the remedy was crafted short. A count after each merge reads
      # the one merged stack. The counts of a merged stack (20, 22, 32) are
      # 25:104726 with the number changed.
      it 'H05: counts the merged stack once more after each merge in the bags and gathers on to 32 held (stacks of 10, 10, 2 and 10)' do
        3.times { commons.inventory << ReplayCommons::Item.new('dried nemoih', toolbag) }
        merged = ->(_replay) { commons.release('nemoih') }
        merged_count = ->(pieces) { code("You count out #{pieces} pieces of material there.", from: '25:104726, count changed to the merged stack (H05 assumption)') }
        game.script('count my nemoih', log('25:104726'))
        game.script('combine my nemoih', log('25:104590'))
        game.script('count my nemoih', log('25:104726'))
        game.script('combine my nemoih', log('25:11425'), after: merged)
        game.script('count my nemoih', merged_count.call(20))
        game.script('count my nemoih', merged_count.call(20))
        game.script('combine my nemoih', log('25:11425'), after: merged)
        game.script('count my nemoih', merged_count.call(22))
        game.script('count my nemoih', merged_count.call(22))
        game.script('combine my nemoih', log('25:11425'), after: merged)
        game.script('count my nemoih', merged_count.call(32))
        game.script(herb_put_command('nemoih', 'large mortar'), log('26:10749'), after: ->(_game) { commons.release('nemoih') })
        game.script(first_crush, log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent.first(12)).to eq(['count my nemoih', 'combine my nemoih',
                                           'count my nemoih', 'combine my nemoih', 'count my nemoih',
                                           'count my nemoih', 'combine my nemoih', 'count my nemoih',
                                           'count my nemoih', 'combine my nemoih', 'count my nemoih',
                                           herb_put_command('nemoih', 'large mortar')])
        expect(remedy_messages).to be_empty
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
      end

      context 'on lich-5 v5_21' do
        let(:lich5) { :v5_21 }
        let(:inventory) { logged_tools.merge(logged_supplies) }

        # layer 11 (bounded gathering): the first get is read from the hands,
        # looked at again for STOP_LOOKS (30 s) seconds before the stop
        it 'H26: stops after looking at the hands for 30 s, sending nothing, when the bag says it has the herb but the get brings nothing, the mortar picked up again' do
          game.fallback('count my nemoih', log('25:13762')) # analog: the not-found reply to a tap
          expect(run_remedy(short_unguent) { allow(DRCI).to receive(:exists?).and_return(true) }).to eq(:exited)
          expect(game.sent).to be_empty
          expect(remedy_messages).to eq(['Remedy: could not get nemoih. Stopping.'])
          expect(commons.location_of('diamondique large mortar')).to eq('left').or eq('right')
        end
      end

      # Kept by layer 11: the plain stow succeeds today (the
      # stack goes to the STOW container), so the gathering keeps its commands.
      it 'CURRENT (H27): puts the smaller of two stacks away with a plain stow, not into herb_container' do
        settings[:herb_container] = 'smokewood basket'
        inventory['dried nemoih'] = 'smokewood basket'
        commons.inventory << ReplayCommons::Item.new('dried nemoih', 'smokewood basket')
        game.script('count my nemoih', log('25:12538'))
        game.script('combine my nemoih', log('25:104590'))
        game.script('count my nemoih', log('25:8678'))
        game.script('combine my nemoih', log('25:30006'))
        game.script('count my first nemoih', log('25:12538'))
        game.script('count my second nemoih', log('25:8678'))
        script_short_unguent
        run_remedy(short_unguent)
        expect(commons.calls).to include(['DRCI.put_away_item?', 'first nemoih', nil])
      end

      # The leftover stow: lich-5 reports success on "That stack of herbs is
      # too large to add more to." (26:32077; F3), so the model's stow leaves
      # the herb in hand and answers true. Assumption: the put left part of
      # the stack in hand (in the logs every put took the whole stack).
      #
      # @param container [String, nil] the one container that refuses the
      #   herb; nil for every container
      # @return [void]
      def keep_the_leftover_in_hand(container = nil)
        allow(DRCC).to receive(:stow_crafting_item) do |*args|
          refused = args.first == 'nemoih' && (container.nil? || args[1] == container)
          refused || commons.stow_crafting_item(*args)
        end
      end

      # layer 11 (the leftover stow is checked)
      it 'D12: stops before the pestle get when the herb left after the put stays in hand, the mortar picked up beside it' do
        game.script('count my nemoih', log('25:33679'))
        game.script('combine my nemoih', log('25:104590'))
        game.script(herb_put_command('nemoih', 'large mortar'), log('26:10749'))
        expect(run_remedy(short_unguent) { keep_the_leftover_in_hand }).to eq(:exited)
        expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', herb_put_command('nemoih', 'large mortar')])
        expect(remedy_messages).to eq(['Remedy: could not put away the nemoih left in hand after the put, and crafting needs that hand. Stopping.'])
        expect(DRCC).to have_received(:stow_crafting_item).with('nemoih', anything, anything).once
        expect(commons.calls).not_to include(include('rounded pestle'))
        expect([commons.location_of('nemoih'), commons.location_of('diamondique large mortar')]).to contain_exactly('left', 'right')
      end

      # layer 11: herb_container first, then the crafting bag (26:32077 is
      # herb_container's reply here)
      it 'puts the herb left after the put into the crafting bag when herb_container leaves it in hand, and crafts on to the product' do
        settings[:herb_container] = 'smokewood basket'
        inventory['dried nemoih'] = 'smokewood basket'
        game.script('count my nemoih', log('25:33679'))
        game.script('combine my nemoih', log('25:104590'))
        game.script(herb_put_command('nemoih', 'large mortar'), log('26:10749'))
        game.script(first_crush, log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        expect(run_remedy(short_unguent) { keep_the_leftover_in_hand('smokewood basket') }).to eq(:exited)
        expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', herb_put_command('nemoih', 'large mortar'),
                                 first_crush, 'get my unguent from my large mortar'])
        expect(DRCC).to have_received(:stow_crafting_item).with('nemoih', 'smokewood basket', settings[:alchemy_belt]).once.ordered
        expect(DRCC).to have_received(:stow_crafting_item).with('nemoih', toolbag, settings[:alchemy_belt]).once.ordered
        expect(commons.location_of('dried nemoih')).to eq(toolbag)
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
        expect(remedy_messages).to be_empty
      end
    end

    describe 'restocking (C12)' do
      let(:inventory) { logged_tools.merge(logged_supplies.except('water'), 'dried nemoih' => toolbag) }
      let(:orders) { { 1 => 'water' } }

      # layer 13 (restock in the crafting town)
      it 'H09: buys in force_crafting_town (Crossing stock-room 8862, base-crafting.yaml:1401), not in the Shard hometown' do
        settings.merge!(hometown: 'Shard', force_crafting_town: 'Crossing')
        script_short_unguent
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(commons.calls).to include(['DRCT.order_item', 8862, 1])
        expect(commons.calls).not_to include(['DRCT.order_item', 19288, 1])
        expect(DRCM).to have_received(:get_money_from_bank).with('5 silver', anything, 'Crossing')
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
      end

      # layer 13
      it 'H09: stops with a Remedy line, buying nothing, for a hometown with no remedies data (Aesry)' do
        settings[:hometown] = 'Aesry'
        script_short_unguent
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(remedy_messages).to eq(['Remedy: no water on hand, and no alchemy shop is known in Aesry to buy it from: put water in your crafting_container, or set force_crafting_town to a town with one. Stopping.'])
        expect(commons.calls.map(&:first)).not_to include('DRCM.get_money_from_bank', 'DRCT.order_item', 'DRCT.walk_to')
        expect(game.sent).to be_empty
      end
    end

    describe 'marking the product (C09)' do
      let(:settings) { logged_settings }

      # flipped by layer 18 (opt-in stamp repair; off by default it says so)
      it 'CURRENT (D10): ignores "too badly damaged": no repair, no message, the product left unmarked' do
        game.script('mark my unguent with my stamp', code('Your stamp is too badly damaged to be used.', from: 'R:423 /too badly damaged/'))
        script_short_unguent
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent.last(2)).to eq(['get my unguent from my large mortar', 'mark my unguent with my stamp'])
        expect(commons.calls.map(&:first)).not_to include('DRCC.repair_own_tools')
        expect(commons.location_of('Siksrajan applewood-handled stamp')).to eq(toolstrap)
        expect(remedy_messages).to be_empty
      end
    end

    describe 'sharp corners (C13)' do
      # flipped by layer 14 (the swap needs herb1 to be the whole flower name)
      it 'CURRENT (H10): swaps herb1 "flower" for dried flower' do
        inventory['dried flower'] = toolbag
        game.script('count my dried flower', log('25:33679'))
        run_remedy(typed('remedies 2 "some blister cream" flower nemoih "pewter ingot" mortar cream'))
        expect(game.sent.first).to eq('count my dried flower')
      end

      # flipped by layer 14 (anchored recipe name); the real find_recipe2
      # raises RegexpError on it (H11)
      it 'CURRENT (H11): accepts a recipe name holding "[" and hands it to find_recipe2' do
        script_short_unguent
        run_remedy(typed('remedies 3 "some [x" nemoih na "pewter ingot" mortar unguent'))
        expect(commons.calls).to include(['DRCC.find_recipe2', '3', 'some [x'])
      end

      # flipped by layer 15 (the container word is escaped)
      it 'CURRENT (H12): raises RegexpError for the container "mortar("' do
        expect { run_remedy(typed('remedies 3 "some head unguent" nemoih na "pewter ingot" "mortar(" unguent')) }.to raise_error(RegexpError)
      end

      # flipped by layer 15 (word-prefix match; "mort"
      # still finds "large mortar", pinned above)
      it 'CURRENT (H12): takes the first tool holding the container word anywhere: "r" takes the heavy cauldron' do
        run_remedy(typed('remedies 3 "some head unguent" nemoih na "pewter ingot" r unguent'))
        expect(commons.moves).to include("heavy cauldron: #{toolstrap} -> hand")
      end

      # flipped by layer 15 (buff only with a remedy waggle set)
      it 'CURRENT (H21): runs ;buff remedy with no waggle_sets setting' do
        script_short_unguent
        run_remedy(short_unguent)
        expect(commons.calls).to include(['DRC.wait_for_script_to_complete', 'buff', ['remedy']])
      end

      # flipped by layer 15 (the book uses alchemy_belt)
      it 'CURRENT (H08): gets and stows the remed book with no belt' do
        script_short_unguent
        run_remedy(short_unguent)
        expect(commons.calls).to include(['DRCC.get_crafting_item', 'remed book', toolbag, logged_settings[:crafting_items_in_container], nil, false],
                                         ['DRCC.stow_crafting_item', 'remed book', toolbag, nil])
      end

      # flipped by layer 15 (warn at 175 and above)
      it 'CURRENT (H33): gives no book warning above 175 ranks' do
        DRSkill._set_rank('Alchemy', 180)
        script_short_unguent
        run_remedy(short_unguent)
        expect(displayed_messages.grep(/journeyman or master book/)).to be_empty
      end

      # flipped by layer 15
      it 'CURRENT (H32): puts the herb in without "my": "put nemoih in my large mortar"' do
        script_short_unguent
        run_remedy(short_unguent)
        expect(game.sent[2]).to eq('put nemoih in my large mortar')
      end

      # layer 12: the stirrer and the vessel are put away by name
      it 'H14: in the continue form with the vessel in the left hand, finish puts the pestle away, takes the product out, then puts the vessel away' do
        inventory.delete('diamondique large mortar')
        $left_hand = 'diamondique large mortar'
        game.script('analyze my unguent', log('26:11132'), log('26:11146'))
        game.script('crush my unguent with my rounded pestle', log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        expect(run_remedy(typed('continue na "pewter ingot" mortar unguent'))).to eq(:exited)
        expect(commons.moves.last(3)).to eq(["rounded pestle: hand -> #{toolstrap}", 'nemoih unguent: game -> hand',
                                             "diamondique large mortar: hand -> #{toolstrap}"])
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
        expect(remedy_messages).to be_empty
      end

      # layer 12: the before_dying cleanup releases the magic
      it 'H15: after DRCC.get_crafting_item stops the script (no nemoih), its before_dying releases the spell, mana and symbiosis and deletes the Flags' do
        settings[:crafting_training_spells] = { 'Gauge Flow' => {} }
        inventory.delete('dried nemoih')
        game.script('release spell', log('25:52773'))
        game.script('release mana', log('25:1316'))
        game.script('release symb', code("But you haven't prepared a symbiosis.", from: 'R:418'))
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(commons.messages).to eq(['DRCC: You seem to be missing: nemoih', ReplayCommons::STOP_MESSAGE])
        sent = game.sent.dup
        exit_hooks.each(&:call)
        expect(game.sent).to eq(sent + ['release spell', 'release mana', 'release symb'])
        expect(game.diagnostics).to be_empty
        expect(remedy_flags).to be_empty
      end
    end
  end

  # C15: the order of events must not matter where the game's
  # order is not fixed. Each example changes one reply of C01 or C02 and
  # checks the contract still holds: same commands (plus one resend for a
  # wait), same moves, no timeout. The CURRENT (D05) command after the
  # final-touches line is not swept (.completion_echo_steps).
  describe 'C15: event-order sweeps over C01 and C02 (the contract)' do
    cue_line = /\A(?:You need another|Once finished you notice clumps|Clumps of material|As you finish, the mixture|Upon completion you see|A thick froth|The \S+ takes on an odd hue)/
    sweeps = [
      { name: 'C01', run: '2026-10-26_5598', commands: cauldron_craft_commands, skips: general_elixir_skips,
        script: :script_general_elixir, prefix: 'general_elixir', herb: 'crushed belradi',
        line: 'remedies 6 "a general elixir" belradi na "pewter ingot" bowl elixir' },
      { name: 'C02', run: '2026-10-26_10483', commands: mortar_craft_commands, skips: head_unguent_skips,
        script: :script_head_unguent, prefix: 'head_unguent', herb: 'dried nemoih',
        line: 'remedies 3 "some head unguent" nemoih na "pewter ingot" mortar unguent' }
    ]

    sweeps.each do |sweep|
      steps = ReplayTranscript.load(transcript_path(sweep[:run])).steps.select do |step|
        sweep[:commands].match?(step.command) && !sweep[:skips].include?(step.line) && !completion_echo_steps.include?(step.line)
      end

      context "over #{sweep[:name]} (#{sweep[:run]})" do
        let(:inventory) { logged_tools.merge(logged_supplies, sweep[:herb] => toolbag) }
        let(:crafting_commands) { send("#{sweep[:prefix]}_crafting") }
        let(:finishing_commands) { send("#{sweep[:prefix]}_finishing") }
        let(:expected_moves) { send("#{sweep[:prefix]}_moves") }

        # The contract parts of the run: the crafting commands first, the
        # finishing commands last, at most the one CURRENT (D05) command
        # between them; the same moves; no timeout.
        #
        # @param sends [Array<String>] the commands sent
        # @return [void]
        def expect_the_contract(sends)
          expect(sends.first(crafting_commands.size)).to eq(crafting_commands), game.report
          expect(sends.last(finishing_commands.size)).to eq(finishing_commands), game.report
          expect(sends.size - crafting_commands.size - finishing_commands.size).to be_between(0, 1)
          expect(commons.moves).to eq(expected_moves)
          expect(game.diagnostics).to be_empty
        end

        steps.each do |step|
          it "resends once and changes nothing else when \"...wait 1 seconds.\" (25:11582) answers #{step.command.inspect} (#{step.line})" do
            send(sweep[:script], inject: { step.line => [log('25:11582')] })
            expect(run_remedy(typed(sweep[:line]))).to eq(:exited)
            waits = game.trace.select { |event| event.kind == :stall }
            expect(waits.map(&:label)).to eq([1])
            resend = game.trace.take_while { |event| !event.equal?(waits.first) }.count { |event| event.kind == :send }
            sends = game.sent.dup
            expect(sends[resend]).to eq(sends[resend - 1])
            sends.delete_at(resend)
            expect_the_contract(sends)
          end
        end

        steps.each do |step|
          rt = step.lines.index { |line| line.text.start_with?('Roundtime') }
          cues = step.lines.select { |line| cue_line.match?(line.text) }
          next unless rt && cues.any? { |line| step.lines.index(line) > rt }

          rest = step.lines - cues
          reordered = rest.dup.insert(rest.index { |line| line.text.start_with?('Roundtime') }, *cues)

          it "changes nothing when the cue of #{step.command.inspect} (#{step.line}) arrives before its Roundtime" do
            send(sweep[:script], replace: { step.line => reordered })
            expect(run_remedy(typed(sweep[:line]))).to eq(:exited)
            expect_the_contract(game.sent)
          end
        end
      end
    end
  end

  # Layer 07: the crafting loop gives up after more than
  # Remedy::CraftLoop::MAX_SILENT_REPLIES (3) unanswered sends of one command
  # in a row. These sweeps check that lag below that bound changes nothing:
  # three bput timeouts (15 s each, no line at all) before the logged reply
  # of a crafting command only add three resends of it.
  describe 'C16: a game that answers late, below the silence bound, over C01 and C02 (the contract)' do
    silences = [[], [], []]
    sweeps = [
      { name: 'C01', run: '2026-10-26_5598', commands: cauldron_craft_commands, skips: general_elixir_skips,
        script: :script_general_elixir, prefix: 'general_elixir', herb: 'crushed belradi', product: 'belradi elixir',
        line: 'remedies 6 "a general elixir" belradi na "pewter ingot" bowl elixir' },
      { name: 'C02', run: '2026-10-26_10483', commands: mortar_craft_commands, skips: head_unguent_skips,
        script: :script_head_unguent, prefix: 'head_unguent', herb: 'dried nemoih', product: 'nemoih unguent',
        line: 'remedies 3 "some head unguent" nemoih na "pewter ingot" mortar unguent' }
    ]

    sweeps.each do |sweep|
      # The crafting commands the loop sends itself (mix or crush); the
      # handlers' steps are not counted by the silence bound.
      steps = ReplayTranscript.load(transcript_path(sweep[:run])).steps.select do |step|
        sweep[:commands].match?(step.command) && !sweep[:skips].include?(step.line) && step.command.start_with?('mix ', 'crush ')
      end

      context "over #{sweep[:name]} (#{sweep[:run]})" do
        let(:inventory) { logged_tools.merge(logged_supplies, sweep[:herb] => toolbag) }
        let(:crafting_commands) { send("#{sweep[:prefix]}_crafting") }
        let(:finishing_commands) { send("#{sweep[:prefix]}_finishing") }
        let(:expected_moves) { send("#{sweep[:prefix]}_moves") }

        # The contract parts of the run, as C15 checks them: the crafting
        # commands first, the finishing commands last, at most the one
        # CURRENT (D05) command between them; the same moves; the product in
        # hand and no Remedy line.
        #
        # @param sends [Array<String>] the commands sent, resends removed
        # @return [void]
        def expect_the_contract(sends)
          expect(sends.first(crafting_commands.size)).to eq(crafting_commands), game.report
          expect(sends.last(finishing_commands.size)).to eq(finishing_commands), game.report
          expect(sends.size - crafting_commands.size - finishing_commands.size).to be_between(0, 1)
          expect(commons.moves).to eq(expected_moves)
          expect(remedy_messages).to be_empty
        end

        it 'has crafting commands to sweep' do
          expect(steps.size).to be > 5
        end

        steps.each do |step|
          it "resends #{step.command.inspect} (#{step.line}) three times when three sends go unanswered, and changes nothing else" do
            send(sweep[:script], inject: { step.line => silences })
            expect(run_remedy(typed(sweep[:line]))).to eq(:exited)
            silent_send = game.trace.take_while { |event| event.kind != :stall }.count { |event| event.kind == :send } - 1
            sends = game.sent.dup
            expect(sends[silent_send, 4].uniq.size).to eq(1), game.report
            expect(game.diagnostics).to eq(["DRC: No match was found after 15 seconds for command '#{sends[silent_send]}' (0 lines seen)"] * 3)
            3.times { sends.delete_at(silent_send) }
            expect_the_contract(sends)
            expect(commons.location_of(sweep[:product])).to eq('left').or eq('right')
          end
        end

        context 'with a larger send budget' do
          let(:game) { ReplayGame.new(send_budget: 200) }

          it 'finishes with the same commands when every crafting command first goes unanswered three times' do
            send(sweep[:script], inject: steps.to_h { |step| [step.line, silences] })
            expect(run_remedy(typed(sweep[:line]))).to eq(:exited)
            expect(game.diagnostics.size).to eq(steps.size * 3)
            # Each unanswered send is the send just before a timeout.
            sent = -1
            silent = game.trace.each_with_object([]) do |event, found|
              sent += 1 if event.kind == :send
              found << sent if event.kind == :stall
            end
            expect(silent.size).to eq(steps.size * 3)
            expect_the_contract(game.sent.reject.with_index { |_command, index| silent.include?(index) })
            expect(commons.location_of(sweep[:product])).to eq('left').or eq('right')
          end
        end
      end
    end
  end

  # Layer 08: the game's refusals end the run at once, and
  # instructions that faded before crafting began stop it before the first
  # crafting command. The success runs above are unchanged.
  describe 'refusals and faded instructions (layer 08)' do
    let(:settings) { logged_settings.merge(mark_crafted_goods: false) }
    let(:inventory) { logged_tools.merge(logged_supplies, 'dried nemoih' => toolbag) }
    let(:gathered) { ['count my nemoih', 'combine my nemoih', herb_put_command('nemoih', 'large mortar')] }
    let(:first_crush) { 'crush my nemoih with my rounded pestle' }
    let(:next_crush) { 'crush my unguent with my rounded pestle' }
    let(:faded_message) { 'Remedy: the instructions for some head unguent faded from memory before crafting began; run remedy again to study them. Stopping.' }

    # A game line as another player's speech shows it: the text follows a
    # double quote, which NO_QUOTE and the ^[^"]*? patterns refuse.
    #
    # @param line [ReplayGame::Line] the game's line
    # @return [ReplayGame::Line]
    def spoken(line)
      code(%(<preset id='speech'>Mallory says</preset>, "#{line.text}"), from: "#{line.cite} as player speech (Remedy::NO_QUOTE)")
    end

    describe 'instructions that fade (25:37919, 25:51002)' do
      %w[25:37919 25:51002].each do |cite|
        it "stops before the first crush when #{cite} arrives while the herb is gathered, the mortar and pestle in hand" do
          script_short_unguent(put_lines: [log('26:10749'), log(cite)])
          expect(run_remedy(short_unguent) { allow(DRC).to receive(:beep) }).to eq(:exited)
          expect(game.sent).to eq(gathered)
          expect(DRC).to have_received(:beep).once
          expect(remedy_messages).to eq([faded_message])
          expect(commons.location_of('diamondique large mortar')).to eq('left').or eq('right')
          expect(commons.location_of('rounded pestle')).to eq('left').or eq('right')
        end
      end

      it 'stops when the fade comes behind an XML tag, a form of the game line NO_QUOTE allows' do
        tagged = code("<pushBold/>#{log('25:37919').text}", from: '25:37919 behind an XML tag (Remedy::NO_QUOTE)')
        script_short_unguent(put_lines: [log('26:10749'), tagged])
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent).to eq(gathered)
        expect(remedy_messages).to eq([faded_message])
      end

      it 'crafts on when another player says the fade line' do
        script_short_unguent(put_lines: [log('26:10749'), spoken(log('25:37919'))])
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent).to eq([*gathered, first_crush, 'get my unguent from my large mortar'])
        expect(remedy_messages).to be_empty
      end

      it 'crafts on when the fade of an earlier study arrives before this run studies the recipe' do
        script_short_unguent
        outcome = run_remedy(short_unguent) do
          allow(DRCC).to receive(:find_recipe2) do |*args|
            game.unprompted(log('25:37919'))
            commons.find_recipe2(*args)
          end
        end
        expect(outcome).to eq(:exited)
        expect(game.sent).to eq([*gathered, first_crush, 'get my unguent from my large mortar'])
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
        expect(remedy_messages).to be_empty
      end

      it 'crafts on to the end when the fade arrives after the first crush drew Roundtime (25:10825)' do
        script_short_unguent(first_crush: [log('25:10825'), log('25:37919')])
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent.drop(3)).to eq([first_crush, next_crush, 'get my unguent from my large mortar'])
        expect(remedy_messages).to be_empty
      end

      context 'in the continue form, which studies nothing (26:11130-11396)' do
        let(:inventory) { logged_tools.except('diamondique large mortar').merge(logged_supplies) }

        before do
          $right_hand = 'diamondique large mortar'
          transcript('2026-10-26_10483').script(game, commands: /\Aanalyze my unguent\z|#{mortar_craft_commands.source}/, from: 11130)
          alias_remedy_wording(vessel: 'large mortar', noun: 'unguent')
          script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        end

        it 'analyses and crafts to the end although the fade arrived as it started' do
          outcome = run_remedy(typed('continue na "pewter ingot" mortar unguent')) do
            allow(DRC).to receive(:wait_for_script_to_complete) { game.unprompted(log('25:37919')) }
          end
          expect(outcome).to eq(:exited)
          expect(game.sent).to eq(['analyze my unguent', 'push my unguent with my sieve', *([next_crush] * 7),
                                   'get my unguent from my large mortar'])
          expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
          expect(remedy_messages).to be_empty
        end
      end
    end

    describe 'a refused herb' do
      it 'crafts on when another player says "You need a more suitable type of herb" (25:50933) before the Roundtime' do
        script_short_unguent(first_crush: [spoken(log('25:50933')), log('25:10825')])
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent.drop(3)).to eq([first_crush, next_crush, 'get my unguent from my large mortar'])
        expect(remedy_messages).to be_empty
      end

      it 'names the herb in the vessel when the continue form, which is not told the herb, is refused' do
        inventory.delete('diamondique large mortar')
        $right_hand = 'diamondique large mortar'
        game.script('analyze my unguent', log('25:50933')) # analog: the refusal answered a crush (25:50932)
        expect(run_remedy(typed('continue na "pewter ingot" mortar unguent'))).to eq(:exited)
        expect(game.sent).to eq(['analyze my unguent'])
        expect(remedy_messages).to eq(['Remedy: the game wants a more suitable type of herb than the herb in the large mortar: it refused "analyze my unguent". Stopping.'])
      end
    end

    describe 'a refused step (D04, D11)' do
      # The first crush draws the particulate cue (25:11149) and Roundtime
      # (25:10825), so remedy pushes with the sieve next.
      let(:sieve_cue_crush) { [log('25:11149'), log('25:10825')] }

      it 'adds the catalyst at once when the push is refused with the catalyst cue alone (26:39150-39152), with no 15 s wait' do
        script_short_unguent(first_crush: sieve_cue_crush)
        # analog: the whole reply to `push my curative with my turtle-shaped sieve` (26:39148)
        game.override('push my unguent with my sieve', log('26:39150'), log('26:39152'))
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent.drop(3)).to eq([first_crush, 'push my unguent with my sieve', 'put my pewter ingot in my large mortar',
                                         next_crush, 'get my unguent from my large mortar'])
        expect(game.diagnostics).to be_empty
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
      end

      it 'crafts on at once when the game says the sieve "doesn\'t appear suitable" (26:24873)' do
        script_short_unguent(first_crush: sieve_cue_crush)
        game.override('push my unguent with my sieve', log('26:24873')) # the reply to `push my tonic with my sieve` (26:24872)
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent.drop(3)).to eq([first_crush, 'push my unguent with my sieve', next_crush, 'get my unguent from my large mortar'])
        expect(game.diagnostics).to be_empty
        expect(tool_locations).to eq(logged_tools)
      end

      it 'still waits for a step reply when another player says "doesn\'t appear suitable" before the Roundtime' do
        script_short_unguent(first_crush: sieve_cue_crush)
        game.override('push my unguent with my sieve', spoken(log('26:24873')), log('26:10935'))
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent.drop(3)).to eq([first_crush, 'push my unguent with my sieve', next_crush, 'get my unguent from my large mortar'])
        expect(game.diagnostics).to be_empty
      end
    end
  end

  describe 'guarded gets and a missing second herb (layer 09)' do
    let(:settings) { logged_settings.merge(mark_crafted_goods: false) }
    let(:inventory) { logged_tools.merge(logged_supplies, 'dried nemoih' => toolbag) }
    let(:gathered) { ['count my nemoih', 'combine my nemoih', herb_put_command('nemoih', 'large mortar')] }
    # code-derived (R:51 /You need another prepared herb/): no "prepared herb"
    # line is in either log (both logged characters made one-herb recipes).
    let(:herb_cue) { code('You need another prepared herb to continue crafting some unfinished nemoih unguent.', from: 'R:51 /You need another prepared herb/') }

    describe 'the second herb the game asks for (H19, H30)' do
      [%w[na na], %w[none none], ['"not used"', 'not used']].each do |typed_herb2, herb2|
        it "stops at the cue (R:51) when herb2 is #{herb2.inspect}, asking for no item of that name, the mortar and pestle in hand" do
          script_short_unguent(put_lines: [log('26:10749'), herb_cue])
          expect(run_remedy(short_unguent(herb2: typed_herb2)) { allow(DRC).to receive(:beep) }).to eq(:exited)
          expect(game.sent).to eq(gathered)
          expect(DRC).to have_received(:beep).once
          expect(remedy_messages).to eq(["Remedy: the game asks for a second herb, and herb2 is #{herb2.inspect}, which names none. Stopping."])
          expect(commons.calls.select { |_name, item, *| item == herb2 }).to be_empty
          expect(commons.location_of('diamondique large mortar')).to eq('left').or eq('right')
          expect(commons.location_of('rounded pestle')).to eq('left').or eq('right')
        end
      end

      it 'gets a named second herb (jadice) from the crafting bag with skip_exit, puts it in and crafts on to the product' do
        inventory['dried jadice'] = toolbag
        script_short_unguent(put_lines: [log('26:10749'), herb_cue])
        expect(run_remedy(short_unguent(herb2: 'jadice'))).to eq(:exited)
        expect(commons.calls).to include(['DRCC.get_crafting_item', 'jadice', toolbag, ['jadice'], logged_settings[:alchemy_belt], true])
        expect(game.sent).to eq([*gathered, 'put my jadice in my large mortar', 'crush my nemoih with my rounded pestle', 'get my unguent from my large mortar'])
        expect(remedy_messages).to be_empty
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
      end

      ReplayCommons::LICH5_RELEASES.each do |release|
        context "on lich-5 #{release}" do
          let(:lich5) { release }

          it 'stops with a Remedy line, putting nothing in, when the named second herb (jadice) is nowhere' do
            script_short_unguent(put_lines: [log('26:10749'), herb_cue])
            expect(run_remedy(short_unguent(herb2: 'jadice'))).to eq(:exited)
            expect(remedy_messages).to eq(['Remedy: could not get jadice. Stopping.'])
            expect(commons.messages).to eq(['DRCC: You seem to be missing: jadice'])
            expect(game.sent).to eq(gathered)
            expect(commons.location_of('diamondique large mortar')).to eq('left').or eq('right')
          end
        end
      end
    end

    describe 'the catalyst put (D02)' do
      let(:inventory) { logged_tools.merge(logged_supplies, 'crushed belradi' => toolbag) }
      let(:put_ingot) { 'put my pewter ingot in my heavy cauldron' }

      ReplayCommons::LICH5_RELEASES.each do |release|
        context "on lich-5 #{release}" do
          let(:lich5) { release }

          it 'stops at once when the game finds no pewter ingot to put in (26:39194), with no mix after the put' do
            script_general_elixir
            game.override(put_ingot, log('26:39194'))
            expect(run_remedy(workorders_call('a general elixir', 6, 'belradi', 'bowl', 'elixir', catalyst: 'pewter ingot'))).to eq(:exited)
            expect(game.sent.last).to eq(put_ingot)
            expect(game.sent.count(put_ingot)).to eq(1)
            expect(game.diagnostics).not_to include(a_string_including(put_ingot))
            expect(remedy_messages).to eq(['Remedy: the game found no pewter ingot to put in the heavy cauldron. Stopping.'])
            expect(commons.location_of('heavy cauldron')).to eq('left').or eq('right')
          end
        end
      end
    end

    describe 'a tool, the book or the stamp that is nowhere' do
      ReplayCommons::LICH5_RELEASES.each do |release|
        context "on lich-5 #{release}" do
          let(:lich5) { release }

          it 'stops before the herb is gathered when the mortar is nowhere, sending nothing' do
            inventory.delete('diamondique large mortar')
            script_short_unguent
            expect(run_remedy(short_unguent)).to eq(:exited)
            expect(game.sent).to be_empty
            expect(remedy_messages).to eq(['Remedy: could not get large mortar. Stopping.'])
            expect(commons.calls.map(&:first)).not_to include('DRCI.lower_item?')
          end

          it 'stops after the herb is gathered, crushing nothing, when the pestle is nowhere' do
            inventory.delete('rounded pestle')
            script_short_unguent
            expect(run_remedy(short_unguent)).to eq(:exited)
            expect(game.sent).to eq(gathered)
            expect(remedy_messages).to eq(['Remedy: could not get rounded pestle. Stopping.'])
            expect(commons.messages).to eq(['DRCC: You seem to be missing: rounded pestle'])
            expect(commons.location_of('diamondique large mortar')).to eq('left').or eq('right')
          end

          it 'stops before the analysis in the continue form when the pestle is nowhere, sending nothing' do
            inventory.delete('diamondique large mortar')
            inventory.delete('rounded pestle')
            $right_hand = 'diamondique large mortar' # the vessel with the unfinished unguent, as 26:11127
            expect(run_remedy(typed('continue na "pewter ingot" mortar unguent'))).to eq(:exited)
            expect(game.sent).to be_empty
            expect(remedy_messages).to eq(['Remedy: could not get rounded pestle. Stopping.'])
            expect(commons.messages).to eq(['DRCC: You seem to be missing: rounded pestle'])
            expect($right_hand).to eq('diamondique large mortar')
          end

          it 'finishes with the product in hand, unmarked, and says why, when the stamp is nowhere' do
            settings[:mark_crafted_goods] = true
            inventory.delete('Siksrajan applewood-handled stamp')
            script_short_unguent
            allow(DRC).to receive(:beep)
            expect(run_remedy(short_unguent)).to eq(:exited)
            expect(game.sent.last(2)).to eq(['crush my nemoih with my rounded pestle', 'get my unguent from my large mortar'])
            expect(remedy_messages).to eq(['Remedy: could not get the stamp; the unguent is left unmarked.'])
            # Only DRCC's beep before its missing line (v5.21.0 and v5.22.0
            # common-crafting.rb:344, 480bdee3 :517): remedy adds none.
            expect(DRC).to have_received(:beep).once
            expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
            expect(commons.location_of('diamondique large mortar')).to eq(toolstrap)
          end
        end
      end

      context 'on lich-5 v5_21, where a missing item does not stop the script' do
        let(:lich5) { :v5_21 }

        it 'stops before the study when the remed book is nowhere' do
          inventory.delete('remed book')
          script_short_unguent
          expect(run_remedy(short_unguent)).to eq(:exited)
          expect(remedy_messages).to eq(['Remedy: could not get remed book. Stopping.'])
          expect(commons.calls.map(&:first)).not_to include('DRCC.find_recipe2')
          expect(game.sent).to be_empty
        end

        it 'looks at the hands for the 15 s of a late reply before it stops on the missing remed book' do
          inventory.delete('remed book')
          script_short_unguent
          expect(run_remedy(short_unguent)).to eq(:exited)
          expect(game.clock).to eq(0.2 + Remedy::Inventory::LATE_GET_LOOKS) # the pause after the stows, then a look a second
          expect(remedy_messages).to eq(['Remedy: could not get remed book. Stopping.'])
        end
      end

      %i[current v5_22].each do |release|
        context "on lich-5 #{release}" do
          let(:lich5) { release }

          # The book get keeps its four arguments until layer 15 (CURRENT H08).
          it 'leaves a missing remed book to DRCC, which stops the script as before' do
            inventory.delete('remed book')
            script_short_unguent
            expect(run_remedy(short_unguent)).to eq(:exited)
            expect(commons.messages).to eq(['DRCC: You seem to be missing: remed book', ReplayCommons::STOP_MESSAGE])
            expect(remedy_messages).to be_empty
            expect(commons.calls.map(&:first)).not_to include('DRCC.find_recipe2')
          end
        end
      end
    end
  end

  describe 'gathering the herb by what is held (layer 11)' do
    let(:settings) { logged_settings.merge(mark_crafted_goods: false) }
    let(:inventory) { logged_tools.merge(logged_supplies, 'dried nemoih' => toolbag) }
    let(:first_crush) { 'crush my nemoih with my rounded pestle' }
    let(:herb_put) { herb_put_command('nemoih', 'large mortar') }
    let(:short_run_tail) { [first_crush, 'get my unguent from my large mortar'] } # 26:11333, 26:11389

    # Scripts the herb put (26:10749, after which the game holds the herb),
    # the first crush (26:11333) and the product taken out (26:11389).
    #
    # @return [void]
    def script_put_and_craft
      game.script(herb_put, log('26:10749'), after: ->(_game) { commons.release('nemoih') })
      game.script(first_crush, log('26:11333'))
      script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
    end

    # Two stacks in the toolbag. Model assumption, as in the contract's
    # 21 + 75: the count with both in hand reads the stack just got, so the
    # 10 cannot be the 21 held. Today's commands plus one count after the
    # merge (H05, a deliberate change): it reads the merged 31
    # (25:104726 with the number changed).
    it 'tops up the 21 held (25:12538) with a second stack of 10 (25:104726), counting the merged stack once after the merge (25:11425)' do
      commons.inventory << ReplayCommons::Item.new('dried nemoih', toolbag)
      game.script('count my nemoih', log('25:12538'))
      game.script('combine my nemoih', log('25:104590'))
      game.script('count my nemoih', log('25:104726'))
      game.script('combine my nemoih', log('25:11425'), after: ->(_game) { commons.release('nemoih') })
      game.script('count my nemoih', code('You count out 31 pieces of material there.', from: '25:104726, count changed to the merged stack'))
      script_put_and_craft
      expect(run_remedy(short_unguent)).to eq(:exited)
      expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', 'count my nemoih', 'combine my nemoih', 'count my nemoih',
                               herb_put, *short_run_tail])
      expect(remedy_messages).to be_empty
      expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
    end

    # Code-derived timing, as layer 09's LATE_GET_LOOKS: no get in the logs
    # timed out. The herb get's bput gives up, current lich-5 returns
    # DRCI.in_hands? (false) without exiting (480bdee3
    # common-crafting.rb:531-532), and the herb reaches a hand 3, 16 or 30 s
    # later. Today the `count my nemoih` sent at once waited behind it, so
    # the late "You get" came first and the run crafted on however late it
    # was; remedy now looks at the hands for STOP_LOOKS (30 s), which with
    # the get's own 15 s bput is three 15 s silences.
    [3, 16, 30].each do |late|
      it "crafts on with the commands of today when the first herb get is answered #{late} s late (25:33679, 25:104590)" do
        game.script('count my nemoih', log('25:33679'))
        game.script('combine my nemoih', log('25:104590'))
        script_put_and_craft
        outcome = run_remedy(short_unguent) do
          arrives = nil
          allow(DRCC).to receive(:get_crafting_item) do |*args|
            next commons.get_crafting_item(*args) unless args.first == 'nemoih' && arrives.nil?

            arrives = game.clock + late
            false
          end
          allow(DRCI).to receive(:in_hands?) do |item|
            if arrives && game.clock >= arrives && commons.location_of('dried nemoih') == toolbag
              commons.inventory.delete_if { |owned| owned.name == 'dried nemoih' }
              commons.hold('dried nemoih')
            end
            commons.in_hands?(item)
          end
        end
        expect(outcome).to eq(:exited)
        expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', herb_put, *short_run_tail])
        expect(remedy_messages).to be_empty
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
      end
    end

    context 'with a larger send budget' do
      let(:game) { ReplayGame.new(send_budget: 200) }

      # Every count and combine goes unanswered (15 s bput timeouts); the bag
      # always says it has the herb and the one stack stays in hand.
      it 'gets the herb 25 times at most (MAX_FETCHES) when no count or combine is answered, then says so and crafts with what is in hand' do
        script_put_and_craft
        expect(run_remedy(short_unguent) { allow(DRCI).to receive(:exists?).and_return(true) }).to eq(:exited)
        herb_gets = commons.calls.select { |call| call.first == 'DRCC.get_crafting_item' && call[1] == 'nemoih' }
        expect(herb_gets.size).to eq(25)
        expect(game.sent.count('combine my nemoih')).to eq(25)
        expect(game.sent.last(3)).to eq([herb_put, *short_run_tail])
        expect(remedy_messages).to eq(['Remedy: could not count the nemoih gathered (a remedy takes 25); crafting with what is in hand.'])
      end
    end
  end

  # Layer 12: the product taken out is checked,
  # the stirrer and the vessel are put away by name, and the before_dying
  # cleanup runs on every exit. The specs capture the before_dying blocks
  # (run_remedy) and call them as Lich does once the script has ended.
  describe 'the product, the stows by name and the cleanup on every exit (layer 12)' do
    let(:settings) { logged_settings.merge(mark_crafted_goods: false) }
    let(:inventory) { logged_tools.merge(logged_supplies, 'dried nemoih' => toolbag) }
    let(:first_crush) { 'crush my nemoih with my rounded pestle' }
    let(:crush) { 'crush my unguent with my rounded pestle' }
    let(:spells) { { 'Gauge Flow' => {} } }

    # The replies to the three releases: 25:52773, 25:1316, and the
    # symbiosis reply as the existing contract example has it (code-derived,
    # R:418).
    #
    # @return [void]
    def script_releases
      game.script('release spell', log('25:52773'))
      game.script('release mana', log('25:1316'))
      game.script('release symb', code("But you haven't prepared a symbiosis.", from: 'R:418'))
    end

    # Runs the captured before_dying blocks, as Lich does when the script ends.
    #
    # @return [Array<String>] the commands they sent
    def run_exit_hooks
      before = game.sent.size
      exit_hooks.each(&:call)
      game.sent.drop(before)
    end

    describe 'the product taken out of the vessel (D09, H03)' do
      before { allow(DRC).to receive(:beep) }

      # "What were you referring to?" (25:10857), analog: the reply to `put
      # my clubmoss in my smokewood basket` (25:10855) with no clubmoss in
      # hand; the same text answered a get at 26:39162.
      it 'stops, instead of finishing, when the get of the product is answered "What were you referring to?" (25:10857)' do
        script_short_unguent
        game.override('get my unguent from my large mortar', log('25:10857'))
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(DRC).to have_received(:beep).once
        expect(remedy_messages).to eq(['Remedy: the unguent is not in hand after taking it out of the large mortar. Stopping.'])
        expect(game.sent.last(2)).to eq([first_crush, 'get my unguent from my large mortar'])
        expect(commons.location_of('diamondique large mortar')).to eq('left').or eq('right')
        expect(commons.location_of('rounded pestle')).to eq(toolstrap)
        expect(commons.location_of('unguent')).to be_nil
      end

      it 'sends no mark after that stop, even with mark_crafted_goods set' do
        settings[:mark_crafted_goods] = true
        script_short_unguent
        game.override('get my unguent from my large mortar', log('25:10857'))
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent.grep(/\Amark /)).to be_empty
        expect(commons.calls.map { |call| call[1] }).not_to include('stamp')
      end

      it 'prints no ;remedy continue line after that stop: the game called the remedy done' do
        script_short_unguent
        game.override('get my unguent from my large mortar', log('25:10857'))
        run_remedy(short_unguent)
        run_exit_hooks
        expect(remedy_messages.grep(/continue/)).to be_empty
        expect(remedy_flags).to be_empty
      end

      # Real order, timestamped copies: an unrelated line came between a
      # product get and its reply. 25:27825 `get my liniment from my large
      # mortar` [10:31:31] -> 25:27826 " * Venras joins the adventure."
      # [10:31:32] -> 25:27830 "You get a clubmoss liniment from inside ..."
      # [10:31:32]. 26:27349 `get my unguent from my large mortar` -> 26:27350
      # "Osrel Meraud  (0%)" -> 26:27353 "You get some aloe unguent from
      # inside ...", all [10:51:46]. (logged runs; the order is the
      # server's.) The pattern-less fput returns that first line (lich-5
      # global_defs.rb:1625-1628), and the hands change only when the reply's
      # own line is parsed (games.rb:1139-1153): modelled as the hand showing
      # the unguent one second after the get, the first late look. Today
      # fput's answer was not read and such a run finished.
      { '25:27826' => 'a logon notice', '26:27350' => 'a percWindow spell line' }.each do |cite, kind|
        it "finishes as today, putting the mortar away and marking the unguent, when #{kind} (#{cite}) comes before the product reply (26:11389)" do
          settings[:mark_crafted_goods] = true
          script_short_unguent
          game.script('mark my unguent with my stamp', log('25:11294'))
          arrives = nil
          game.override('get my unguent from my large mortar', log(cite), log('26:11389'), after: ->(replay) { arrives = replay.clock + 1 })
          outcome = run_remedy(short_unguent) do
            allow(DRCI).to receive(:in_hands?) do |item|
              commons.hold('nemoih unguent') if arrives && game.clock >= arrives && commons.location_of('nemoih unguent').nil?
              commons.in_hands?(item)
            end
          end
          expect(outcome).to eq(:exited)
          expect(remedy_messages).to be_empty
          expect(game.sent.last(3)).to eq([first_crush, 'get my unguent from my large mortar', 'mark my unguent with my stamp'])
          expect(commons.location_of('diamondique large mortar')).to eq(toolstrap)
          expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
        end
      end

      it 'stops only after looking at the hands for LATE_GET_LOOKS seconds when an unrelated line (25:27826) comes first and no unguent ever reaches a hand' do
        script_short_unguent
        asked_at = nil
        stopped_at = nil
        game.override('get my unguent from my large mortar', log('25:27826'), after: ->(replay) { asked_at = replay.clock })
        outcome = run_remedy(short_unguent) { allow(DRC).to receive(:beep) { stopped_at = game.clock } }
        expect(outcome).to eq(:exited)
        expect(stopped_at - asked_at).to eq(Remedy::Inventory::LATE_GET_LOOKS)
        expect(remedy_messages).to eq(['Remedy: the unguent is not in hand after taking it out of the large mortar. Stopping.'])
        expect(game.sent.last(2)).to eq([first_crush, 'get my unguent from my large mortar'])
        expect(commons.location_of('diamondique large mortar')).to eq('left').or eq('right')
      end

      # H03: "Interesting thought really... but no." (25:11264) also answers
      # a vessel with nothing to craft; the continue form then used to put
      # the mortar away and end as if it had made the remedy.
      it 'stops in the continue form when the analysis is answered "Interesting thought really... but no." (25:11264) and no unguent comes out' do
        $right_hand = 'diamondique large mortar'
        inventory.delete('diamondique large mortar')
        game.script('analyze my unguent', log('25:11264'))
        game.script('get my unguent from my large mortar', log('25:10857'))
        expect(run_remedy(typed('continue na "pewter ingot" mortar unguent'))).to eq(:exited)
        expect(game.sent).to eq(['analyze my unguent', 'get my unguent from my large mortar'])
        expect(remedy_messages).to eq(['Remedy: the unguent is not in hand after taking it out of the large mortar. Stopping.'])
        expect(commons.location_of('diamondique large mortar')).to eq('right')
        expect(commons.location_of('rounded pestle')).to eq(toolstrap)
      end
    end

    describe 'the stows by name (H14)' do
      # The contract's continue run (26:11130-11396), with the mortar in the
      # left hand: the push with the sieve (the froth cue, 26:11136) and the
      # finish each put the pestle away, never the mortar.
      it 'sends the contract continue run byte for byte with the mortar in the left hand, and moves the mortar only at the end' do
        inventory.delete('diamondique large mortar')
        settings[:mark_crafted_goods] = true
        $left_hand = 'diamondique large mortar'
        transcript('2026-10-26_10483').script(game, commands: /\Aanalyze my unguent\z|#{mortar_craft_commands.source}/, from: 11130)
        alias_remedy_wording(vessel: 'large mortar', noun: 'unguent')
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        expect(run_remedy(typed('continue na "pewter ingot" mortar unguent'))).to eq(:exited)
        expect(game.sent).to eq(['analyze my unguent', 'push my unguent with my sieve', *([crush] * 7),
                                 'get my unguent from my large mortar', 'mark my unguent with my stamp'])
        mortar_moves = commons.moves.grep(/\Adiamondique large mortar:/)
        expect(mortar_moves).to eq(["diamondique large mortar: hand -> #{toolstrap}"])
        expect(commons.moves.index(mortar_moves.first)).to be > commons.moves.index('nemoih unguent: game -> hand')
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
        expect(tool_locations).to eq(logged_tools)
      end

      context 'with every tool in the crafting container and no alchemy_belt' do
        let(:settings) { logged_settings.merge(mark_crafted_goods: false, alchemy_belt: nil) }
        let(:inventory) { logged_tools.transform_values { toolbag }.merge(logged_supplies, 'dried nemoih' => toolbag) }

        # A6: the stow is given what the hand holds, as before, so
        # DRCC.stow_crafting_item puts a bag tool back in the bag.
        it 'gives DRCC.stow_crafting_item the full names the hands show, and puts the pestle and the mortar back in the toolbag' do
          script_short_unguent
          expect(run_remedy(short_unguent)).to eq(:exited)
          stows = commons.calls.select { |call| call.first == 'DRCC.stow_crafting_item' }
          expect(stows.last(2)).to eq([['DRCC.stow_crafting_item', 'rounded pestle', toolbag, nil],
                                       ['DRCC.stow_crafting_item', 'diamondique large mortar', toolbag, nil]])
          expect(commons.location_of('rounded pestle')).to eq(toolbag)
          expect(commons.location_of('diamondique large mortar')).to eq(toolbag)
          expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
        end
      end

      # A6: with the belt, the stows tie the tools back, as the contract
      # runs (C01, C02) pin move by move.
      it 'gives DRCC.stow_crafting_item the full names the hands show with the belt too, and ties both back on the toolstrap' do
        script_short_unguent
        expect(run_remedy(short_unguent)).to eq(:exited)
        stows = commons.calls.select { |call| call.first == 'DRCC.stow_crafting_item' }
        expect(stows.last(2)).to eq([['DRCC.stow_crafting_item', 'rounded pestle', toolbag, settings[:alchemy_belt]],
                                     ['DRCC.stow_crafting_item', 'diamondique large mortar', toolbag, settings[:alchemy_belt]]])
        expect(tool_locations).to eq(logged_tools)
      end

      # The continue form with the mortar still tied on the
      # toolstrap. The product get works from there (26:11389 says "which is
      # on your grass toolstrap"), and analyze and crush never name the
      # mortar. Before layer 12 the finish put away DRC.right_hand after the
      # get: the pestle. With the mortar in neither hand that stow is kept.
      it 'in the continue form with the mortar in neither hand, puts the pestle away after the product get, as before, and leaves the mortar on the toolstrap' do
        settings[:mark_crafted_goods] = false
        game.script('analyze my unguent', log('26:11132'), log('26:11146'))
        game.script('crush my unguent with my rounded pestle', log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        expect(run_remedy(typed('continue na "pewter ingot" mortar unguent'))).to eq(:exited)
        expect(game.sent).to eq(['analyze my unguent', 'crush my unguent with my rounded pestle', 'get my unguent from my large mortar'])
        expect(commons.moves).to eq(["rounded pestle: #{toolstrap} -> hand", 'nemoih unguent: game -> hand',
                                     "rounded pestle: hand -> #{toolstrap}"])
        expect([$left_hand, $right_hand]).to eq(['nemoih unguent', nil])
        expect(tool_locations).to eq(logged_tools)
        expect(remedy_messages).to be_empty
      end
    end

    describe 'the cleanup on every exit (H15)' do
      # A run that has begun (Roundtime to the first crush, 25:10825) and
      # then gets no answer to four crushes in a row: remedy stops with the
      # mortar and the pestle in hand.
      #
      # @return [Symbol] how the run ended
      def run_unanswered_after_progress
        script_short_unguent(first_crush: [log('25:10825')])
        game.override(crush, times: nil)
        run_remedy(short_unguent) { allow(DRC).to receive(:beep) }
      end

      it 'after a stop, puts the pestle away by its name in hand and leaves the mortar with the unfinished unguent in hand' do
        expect(run_unanswered_after_progress).to eq(:exited)
        expect(remedy_messages).to eq(["Remedy: the game did not answer #{crush.inspect} 4 times in a row. Stopping."])
        expect(commons.location_of('rounded pestle')).to eq('left').or eq('right')
        expect(run_exit_hooks).to be_empty
        expect(commons.calls.last).to eq(['DRCC.stow_crafting_item', 'rounded pestle', toolbag, settings[:alchemy_belt]])
        expect(commons.location_of('rounded pestle')).to eq(toolstrap)
        expect(commons.location_of('diamondique large mortar')).to eq('left').or eq('right')
        expect(remedy_flags).to be_empty
      end

      it 'after a stop once crafting has begun, prints the ;remedy continue line that carries the unguent on' do
        run_unanswered_after_progress
        run_exit_hooks
        expect(remedy_messages.last).to eq('Remedy: the unfinished unguent is in the large mortar; to carry on with it, ' \
                                           'run ;remedy continue na "pewter ingot" mortar unguent')
      end

      it 'prints a ;remedy continue line that parses back into the continue form with the same herb2, catalyst, vessel and noun' do
        run_unanswered_after_progress
        run_exit_hooks
        line = remedy_messages.last[/;remedy (.*)\z/, 1]
        parsed = ArgParserModel.parse(Remedy::ARG_DEFINITIONS, typed(line).drop(1))
        expect(parsed.to_h).to eq(continue: 'continue', herb2: 'na', catalyst: 'pewter ingot', container: 'mortar', noun: 'unguent')
      end

      it 'keeps herb2 "not used" and the vessel word mort as given in the ;remedy continue line' do
        script_short_unguent(first_crush: [log('25:10825')])
        game.override(crush, times: nil)
        run_remedy(typed('remedies 3 "some head unguent" nemoih "not used" "pewter ingot" mort unguent')) { allow(DRC).to receive(:beep) }
        run_exit_hooks
        expect(remedy_messages.last).to end_with('run ;remedy continue "not used" "pewter ingot" mort unguent')
      end

      it 'prints no ;remedy continue line after a stop before crafting began (the first crush never answered)' do
        script_short_unguent(first_crush: [])
        expect(run_remedy(short_unguent) { allow(DRC).to receive(:beep) }).to eq(:exited)
        run_exit_hooks
        expect(remedy_messages).to eq(["Remedy: the game did not answer #{first_crush.inspect} 4 times in a row. Stopping."])
      end

      it 'prints no ;remedy continue line after the game refused the herb (25:50933)' do
        game.override(first_crush, log('25:50933'), times: nil)
        script_short_unguent
        run_remedy(short_unguent) { allow(DRC).to receive(:beep) }
        run_exit_hooks
        expect(remedy_messages.grep(/continue/)).to be_empty
      end

      context 'with crafting_training_spells set' do
        let(:settings) { logged_settings.merge(mark_crafted_goods: false, crafting_training_spells: spells) }

        it 'releases the spell, mana and symbiosis with fput after a Remedy stop, after putting the pestle away' do
          script_releases
          run_unanswered_after_progress
          expect(run_exit_hooks).to eq(['release spell', 'release mana', 'release symb'])
          expect(game.diagnostics.grep(/fput/)).to be_empty
          stow_at = commons.calls.index(['DRCC.stow_crafting_item', 'rounded pestle', toolbag, settings[:alchemy_belt]])
          expect(stow_at).not_to be_nil
        end

        it 'releases with fput after DRCC.get_crafting_item stops the script (no remed book, lich-5 :current)' do
          inventory.delete('remed book')
          script_releases
          expect(run_remedy(short_unguent)).to eq(:exited)
          expect(commons.messages.last).to eq(ReplayCommons::STOP_MESSAGE)
          expect(run_exit_hooks).to eq(['release spell', 'release mana', 'release symb'])
          expect(remedy_flags).to be_empty
        end

        it 'releases once at the normal end, after the product is out, and the before_dying cleanup sends nothing more' do
          script_releases
          script_short_unguent
          expect(run_remedy(short_unguent)).to eq(:exited)
          expect(game.sent.last(4)).to eq(['get my unguent from my large mortar', 'release spell', 'release mana', 'release symb'])
          expect(run_exit_hooks).to be_empty
          expect(remedy_flags).to be_empty
        end

        it 'releases with fput when the product is not in hand after its get (the finish never reached its release)' do
          script_releases
          script_short_unguent
          game.override('get my unguent from my large mortar', log('25:10857'))
          allow(DRC).to receive(:beep)
          expect(run_remedy(short_unguent)).to eq(:exited)
          expect(game.sent.last).to eq('get my unguent from my large mortar')
          expect(run_exit_hooks).to eq(['release spell', 'release mana', 'release symb'])
        end

        it 'releases only once when the before_dying blocks run twice' do
          script_releases
          run_unanswered_after_progress
          expect(run_exit_hooks).to eq(['release spell', 'release mana', 'release symb'])
          expect(run_exit_hooks).to be_empty
        end
      end

      # A6: nothing is sent when the setting is unset: nil is its
      # profiles/base.yaml default, [] the contract characters'.
      [nil, [], {}].each do |unset|
        context "with crafting_training_spells #{unset.inspect}" do
          let(:settings) { logged_settings.merge(mark_crafted_goods: false, crafting_training_spells: unset) }

          it 'sends nothing from the before_dying cleanup after a DRCC stop' do
            inventory.delete('remed book')
            expect(run_remedy(short_unguent)).to eq(:exited)
            expect(run_exit_hooks).to be_empty
            expect(remedy_flags).to be_empty
          end
        end
      end

      it 'releases nothing, with the spells set, when the run stopped before the crafting magic ran (alchemy_tools lists no mortar)' do
        settings[:alchemy_tools] = ['heavy cauldron']
        settings[:crafting_training_spells] = spells
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(commons.calls.map(&:first)).not_to include('DRCA.crafting_magic_routine')
        expect(run_exit_hooks).to be_empty
        expect(remedy_flags).to be_empty
      end
    end
  end

  # Layer 13 (a deliberate behaviour change): water, alcohol and
  # the coal nugget are bought at the alchemy shop of the crafting town
  # (force_crafting_town, otherwise hometown), with coins from that town's
  # bank, and remedy walks back to alchemy_room or, when that is not set, to
  # the room it was started in. The shop rooms and order numbers are
  # base-crafting.yaml's remedies data (Crossing :1388-1416, Shard :1460-1484).
  describe 'buying supplies in the crafting town and walking back (layer 13)' do
    let(:settings) { logged_settings.merge(mark_crafted_goods: false, alchemy_room: 8859) }
    let(:inventory) { logged_tools.merge(logged_supplies.except('water'), 'dried nemoih' => toolbag) }
    let(:orders) { { 1 => 'water' } }

    # @return [Array<Array>] the bank and travel calls, in order
    def purchase_calls
      commons.calls.select { |name, *| name.start_with?('DRCM.', 'DRCT.') }
    end

    # Expects every withdrawal to be in +town+: DRCM.get_money_from_bank's
    # third argument (lich-5 common-money.rb:140, hometown).
    #
    # @param town [String]
    # @param times [Integer] the withdrawals made
    # @return [void]
    def expect_banked_in(town, times: 1)
      expect(DRCM).to have_received(:get_money_from_bank).exactly(times).times
      expect(DRCM).to have_received(:get_money_from_bank).with('5 silver', anything, town).exactly(times).times
    end

    {
      { hometown: 'Shard', force_crafting_town: 'Crossing' }    => ['Crossing', 8862],
      { hometown: 'Crossing', force_crafting_town: 'Shard' }    => ['Shard', 19_288],
      { hometown: 'Shard', force_crafting_town: nil }           => ['Shard', 19_288],
      { hometown: 'Crossing', force_crafting_town: 'Crossing' } => ['Crossing', 8862]
    }.each do |towns, (shop_town, stock_room)|
      it "buys the water in #{shop_town} (stock-room #{stock_room}) with #{towns.inspect}, banks there, walks back and crafts as before" do
        settings.merge!(towns)
        script_short_unguent
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(purchase_calls).to eq([['DRCM.get_money_from_bank', '5 silver'], ['DRCT.order_item', stock_room, 1], ['DRCT.walk_to', 8859]])
        expect_banked_in(shop_town)
        expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', herb_put_command('nemoih', 'large mortar'),
                                 'crush my nemoih with my rounded pestle', 'get my unguent from my large mortar'])
        expect(commons.location_of('water')).to eq(toolbag)
        expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
        expect(remedy_messages).to be_empty
      end
    end

    it 'buys in hometown, as it always has, when force_crafting_town has no alchemy shop in base-crafting.yaml (Aesry)' do
      settings.merge!(hometown: 'Crossing', force_crafting_town: 'Aesry')
      script_short_unguent
      expect(run_remedy(short_unguent)).to eq(:exited)
      expect(purchase_calls).to eq([['DRCM.get_money_from_bank', '5 silver'], ['DRCT.order_item', 8862, 1], ['DRCT.walk_to', 8859]])
      expect_banked_in('Crossing')
      expect(remedy_messages).to be_empty
    end

    # Before layer 13 this pair withdrew at the Aesry bank, then raised
    # NoMethodError on @stock['stock-room'] (no Aesry remedies data in
    # base-crafting.yaml), so no Aesry-hometown character could buy at all.
    it 'buys in force_crafting_town (Crossing) and crafts when hometown (Aesry) has no alchemy shop, where it used to crash' do
      settings.merge!(hometown: 'Aesry', force_crafting_town: 'Crossing')
      script_short_unguent
      expect(run_remedy(short_unguent)).to eq(:exited)
      expect(purchase_calls).to eq([['DRCM.get_money_from_bank', '5 silver'], ['DRCT.order_item', 8862, 1], ['DRCT.walk_to', 8859]])
      expect_banked_in('Crossing')
      expect(commons.location_of('water')).to eq(toolbag)
      expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
      expect(remedy_messages).to be_empty
    end

    it 'names both towns when neither force_crafting_town (Aesry) nor hometown (Mer\'Kresh) has an alchemy shop, and stops before the bank' do
      settings.merge!(hometown: "Mer'Kresh", force_crafting_town: 'Aesry')
      expect(run_remedy(short_unguent)).to eq(:exited)
      expect(remedy_messages).to eq(["Remedy: no water on hand, and no alchemy shop is known in Aesry or Mer'Kresh to buy it from: put water in your crafting_container, or set force_crafting_town to a town with one. Stopping."])
      expect(purchase_calls).to be_empty
      expect(game.sent).to be_empty
    end

    it 'crafts as before, buying nothing and saying nothing, with an Aesry hometown when every supply is on hand' do
      inventory['water'] = toolbag
      settings[:hometown] = 'Aesry'
      script_short_unguent
      expect(run_remedy(short_unguent)).to eq(:exited)
      expect(purchase_calls).to be_empty
      expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
      expect(remedy_messages).to be_empty
    end

    it 'buys water, alcohol and the coal nugget all in force_crafting_town, walking back after each, as remedy always walked' do
      inventory.delete('grain alcohol')
      orders.merge!(2 => 'alcohol')
      settings.merge!(hometown: 'Shard', force_crafting_town: 'Crossing')
      script_short_unguent
      expect(run_remedy(typed('remedies 3 "some head unguent" nemoih na "coal nugget" mortar unguent'))).to eq(:exited)
      expect(purchase_calls).to eq([['DRCM.get_money_from_bank', '5 silver'], ['DRCT.order_item', 8862, 1], ['DRCT.walk_to', 8859],
                                    ['DRCM.get_money_from_bank', '5 silver'], ['DRCT.order_item', 8862, 2], ['DRCT.walk_to', 8859],
                                    ['DRCM.get_money_from_bank', '5 silver'], ['DRCT.order_item', 8775, 2], ['DRCT.walk_to', 8859]])
      expect_banked_in('Crossing', times: 3)
    end

    context 'when alchemy_room is not set' do
      let(:settings) { logged_settings.merge(mark_crafted_goods: false, alchemy_room: nil) }

      it 'walks back to the room remedy was started in, read before the walk to the shop' do
        # Room ids from base-crafting.yaml:1392-1397 (Crossing npc-rooms): the
        # character starts in 8863; Room.current would answer the shop room
        # 8862 if it were read again after the order.
        allow(Room).to receive(:current).and_return(instance_double(Map, id: 8863), instance_double(Map, id: 8862))
        script_short_unguent
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(purchase_calls).to eq([['DRCM.get_money_from_bank', '5 silver'], ['DRCT.order_item', 8862, 1], ['DRCT.walk_to', 8863]])
        expect(Room).to have_received(:current).once
      end

      it 'asks walk_to for no room, as before, when the map does not know the room remedy was started in' do
        allow(Room).to receive(:current).and_return(nil)
        script_short_unguent
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(purchase_calls.last).to eq(['DRCT.walk_to', nil])
      end
    end

    it 'never reads the start room when alchemy_room is set' do
      allow(Room).to receive(:current)
      script_short_unguent
      run_remedy(short_unguent)
      expect(Room).not_to have_received(:current)
    end

    it 'says so and crafts on when the purchase leaves no water on hand: this recipe never asks for water' do
      orders.clear
      script_short_unguent
      expect(run_remedy(short_unguent)).to eq(:exited)
      expect(purchase_calls).to eq([['DRCM.get_money_from_bank', '5 silver'], ['DRCT.order_item', 8862, 1], ['DRCT.walk_to', 8859]])
      expect(remedy_messages).to eq(['Remedy: could not buy water at the Crossing alchemy shop; crafting on without it.'])
      expect(commons.location_of('nemoih unguent')).to eq('left').or eq('right')
    end
  end
end

# Layer 03: the named patterns, the Flag list and the split of
# Remedy.new from Remedy#run, tested as units. Only lines remedy already
# reads correctly are here; every game line is a real log cite.
RSpec.describe 'Remedy patterns, Flags and entry' do
  let(:game) { ReplayGame.new }

  # @param cite [String] "<log>:<line>"
  # @return [ReplayGame::Line]
  def log(cite)
    ReplayGame.log(cite)
  end

  # The remedy Flags a raw game line sets, as DRParser.check_events does
  # (lich-5 480bdee3 drparser.rb:145-155): a Flag is set when any one of its
  # patterns matches.
  #
  # @param flags [Hash{String => Array<Regexp>}] name => patterns
  # @param text [String] the raw line
  # @return [Array<String>] the Flags set, in the list's order
  def flags_set_by(flags, text)
    flags.select { |_name, patterns| patterns.any? { |pattern| pattern.match?(text) } }.keys
  end

  # Every real line the remedy fixtures hold: the cited lines and every reply
  # line of every transcript.
  #
  # @return [Array<ReplayGame::Line>]
  def every_fixture_line
    cited = ReplayGame.log_lines.keys.select { |cite| cite.start_with?('25:', '26:') }.map { |cite| log(cite) }
    transcripts = Dir[File.expand_path('fixtures/remedy/transcripts/*.json', __dir__)].sort
    replies = transcripts.flat_map { |path| ReplayTranscript.load(path).steps.flat_map(&:lines) }
    cited + replies
  end

  describe 'Remedy::FLAGS' do
    it 'lists the Flags in the order the crafting loop handles them: the ingredients, then the steps' do
      expect(Remedy::FLAGS.keys).to eq(%w[remedy-water remedy-alcohol remedy-catalyst remedy-herb remedy-sieve remedy-turn remedy-smell])
    end

    [['25:50210', 'remedy-water'],
     ['25:10873', 'remedy-alcohol'],
     ['26:5918', 'remedy-alcohol'],
     ['25:11049', 'remedy-catalyst'],
     ['26:39150', 'remedy-catalyst'],
     ['26:7707', 'remedy-turn'],
     ['26:6031', 'remedy-turn'],
     ['25:11004', 'remedy-smell'],
     ['26:12950', 'remedy-smell'],
     ['25:11149', 'remedy-sieve'],
     ['25:11959', 'remedy-sieve']].each do |cite, flag|
      it "sets #{flag}, and no other remedy Flag, on the game's line #{cite}" do
        expect(flags_set_by(Remedy::FLAGS, log(cite).text)).to eq([flag])
      end
    end

    %w[25:10825 26:5913 26:5920 26:6742 26:11057 26:11117].each do |cite|
      it "sets no remedy Flag on #{cite}, which asks for nothing" do
        expect(flags_set_by(Remedy::FLAGS, log(cite).text)).to be_empty
      end
    end

    it 'sets the same Flags as the list remedy registered before, on every real line of the fixtures' do
      no_quote = Remedy::NO_QUOTE
      # remedy.lic:48-54 at 03f11b54, the Flags.add calls this list replaced;
      # remedy-smell still has the "you should smell the mixture" pattern that
      # "smell the mixture" covers.
      before = {
        'remedy-water'    => [/#{no_quote}You need another splash of water/i],
        'remedy-alcohol'  => [/#{no_quote}You need another splash of alcohol/i],
        'remedy-catalyst' => [/#{no_quote}You need another catalyst material/i],
        'remedy-herb'     => [/#{no_quote}You need another prepared herb/i],
        'remedy-turn'     => [/#{no_quote}Clumps of material stick to the sides/i, /#{no_quote}Once finished you notice clumps of material/i],
        'remedy-smell'    => [/#{no_quote}begins to transition colors/i, /#{no_quote}you should smell the mixture/i, /#{no_quote}smell the mixture/i],
        'remedy-sieve'    => [/#{no_quote}Upon completion you see some particulate clouding up the mixture./i, /#{no_quote}with a sieve/i]
      }
      lines = every_fixture_line
      # The sweep is not vacuous: real lines set every Flag but remedy-herb,
      # whose cue is in no log.
      expect(lines.flat_map { |line| flags_set_by(Remedy::FLAGS, line.text) }.uniq).to match_array(Remedy::FLAGS.keys - ['remedy-herb'])
      changed = lines.reject { |line| flags_set_by(before, line.text).sort == flags_set_by(Remedy::FLAGS, line.text).sort }
      expect(changed.map(&:label)).to be_empty
    end

    it 'still sets remedy-smell on 26:12950, the "you should smell the mixture" line, behind an XML tag' do
      # code-derived: 26:12950 behind a bold tag, the form NO_QUOTE allows.
      tagged = ReplayGame.code("<pushBold/>#{log('26:12950').text}", from: '26:12950 behind an XML tag (Remedy::NO_QUOTE)')
      expect(flags_set_by(Remedy::FLAGS, tagged.text)).to eq(['remedy-smell'])
    end

    it 'keeps the broader "smell the mixture" pattern, so a wording without "you should" still sets remedy-smell' do
      # code-derived: remedy.lic:53 at 03f11b54 listed /smell the mixture/
      # beside /you should smell the mixture/; this keeps the broader one.
      variant = ReplayGame.code('To avoid a problem you must smell the mixture.', from: 'R:53 /smell the mixture/ at 03f11b54')
      expect(flags_set_by(Remedy::FLAGS, variant.text)).to eq(['remedy-smell'])
    end

    it 'ignores 26:12950 when another player says it' do
      # code-derived: the speech form other players' lines take (Remedy::NO_QUOTE).
      spoof = ReplayGame.code(%(<preset id='speech'>Mallory says</preset>, "#{log('26:12950').text}"), from: 'player speech form (Remedy::NO_QUOTE)')
      expect(flags_set_by(Remedy::FLAGS, spoof.text)).to be_empty
    end
  end

  describe 'Remedy::REGISTERED_FLAGS' do
    it 'registers the cues of Remedy::FLAGS, in their order, then the faded-instructions Flag' do
      expect(Remedy::REGISTERED_FLAGS.keys).to eq([*Remedy::FLAGS.keys, 'remedy-forgot'])
      expect(Remedy::FADED_FLAG).to eq('remedy-forgot')
    end

    %w[25:37919 25:51002].each do |cite|
      it "sets remedy-forgot, and no other remedy Flag, on the game's line #{cite}" do
        expect(flags_set_by(Remedy::REGISTERED_FLAGS, log(cite).text)).to eq(['remedy-forgot'])
      end
    end

    it 'sets remedy-forgot on no other real line of the fixtures' do
      lines = every_fixture_line.reject { |line| %w[25:37919 25:51002].include?(line.cite) }
      expect(lines.select { |line| flags_set_by(Remedy::REGISTERED_FLAGS, line.text).include?('remedy-forgot') }.map(&:label)).to be_empty
    end

    it 'ignores 25:37919 when another player says it' do
      # code-derived: the speech form other players' lines take (Remedy::NO_QUOTE).
      spoof = ReplayGame.code(%(<preset id='speech'>Mallory says</preset>, "#{log('25:37919').text}"), from: 'player speech form (Remedy::NO_QUOTE)')
      expect(flags_set_by(Remedy::REGISTERED_FLAGS, spoof.text)).to be_empty
    end

    it 'is frozen' do
      expect(Remedy::REGISTERED_FLAGS).to be_frozen
    end
  end

  describe 'Remedy.delete_flags' do
    it 'deletes every remedy Flag and leaves the Flags of other scripts alone' do
      Flags.add('workorders-done', /You hand/i)
      Remedy::FLAGS.each { |name, patterns| Flags.add(name, *patterns) }
      Remedy.delete_flags
      expect(Flags.matchers.keys).to eq(['workorders-done'])
    end

    it 'deletes the faded-instructions Flag too' do
      Remedy::REGISTERED_FLAGS.each { |name, patterns| Flags.add(name, *patterns) }
      Remedy.delete_flags
      expect(Flags.matchers).to be_empty
    end

    it 'does nothing when no remedy Flag is registered, as on a run stopped by parse_args' do
      expect { Remedy.delete_flags }.not_to raise_error
      expect(Flags.matchers).to be_empty
    end
  end

  describe 'Remedy::Patterns, as DRC.bput reads the real reply' do
    [[:VESSEL_COUNT_REPLIES, 'count water in my glass flask', '25:13762', 'I could not find what you were referring to.'],
     [:HERB_COUNT_REPLIES, 'count my nemoih', '25:8678', 'You count out 75'],
     [:HERB_COUNT_REPLIES, 'count my nemoih', '25:12538', 'You count out 21'],
     [:FIRST_STACK_COUNT_REPLIES, 'count my first nemoih', '25:8678', 'You count out 75 pieces'],
     [:SECOND_STACK_COUNT_REPLIES, 'count my second nemoih', '25:13762', 'I could not find'],
     [:SECOND_STACK_COUNT_REPLIES, 'count my second nemoih', '25:33679', 'You count out 25 pieces'],
     [:COMBINE_REPLIES, 'combine my nemoih', '25:11425', 'You combine'],
     [:COMBINE_REPLIES, 'combine my nemoih', '26:32077', 'That stack of herbs is too large to add'],
     [:COMBINE_REPLIES, 'combine my nemoih', '25:18266', 'You must be holding both'],
     [:HERB_PUT_REPLIES, 'put nemoih in my large mortar', '26:10749', 'You put'],
     [:CRAFT_REPLIES, 'crush my unguent with my rounded pestle', '25:10825', 'Roundtime:'],
     [:CRAFT_REPLIES, 'crush my unguent with my rounded pestle', '26:6742', 'Applying the final touches'],
     [:CRAFT_REPLIES, 'crush my unguent with my rounded pestle', '25:11264', 'Interesting thought really... but no.'],
     [:CRAFT_REPLIES, 'mix my heavy cauldron with my mixing stick', '25:58002', "Try as you might, you just can't mix"],
     [:LIQUID_ADD_REPLIES, 'put alcohol in my large mortar', '25:10905', 'You toss'],
     [:INGREDIENT_PUT_REPLIES, 'put my pewter ingot in my large mortar', '25:11081', 'You vigorously'],
     [:STEP_REPLIES, 'push my unguent with my sieve', '26:10935', 'Roundtime'],
     [:RELEASE_SPELL_REPLIES, 'release spell', '25:52773', 'You let your concentration lapse'],
     [:RELEASE_SPELL_REPLIES, 'release spell', '26:92609', "You aren't preparing a spell"],
     [:RELEASE_MANA_REPLIES, 'release mana', '25:1316', "You aren't harnessing any mana"],
     [:MARK_REPLIES, 'mark my liniment with my stamp', '25:11294', 'score the surface with the stamp']].each do |name, command, cite, text|
      it "#{name}: bput returns #{text.inspect} for #{command.inspect} answered by #{cite}" do
        game.install(self)
        game.script(command, log(cite))
        expect(DRC.bput(command, *Remedy::Patterns.const_get(name))).to eq(text)
        expect(game.diagnostics).to be_empty
      end
    end

    it 'names the text bput returns for "I could not find" (25:13762), which the vessel check compares against' do
      game.install(self)
      game.script('count alcohol in my glass flask', log('25:13762'))
      expect(DRC.bput('count alcohol in my glass flask', *Remedy::Patterns::VESSEL_COUNT_REPLIES)).to eq(Remedy::Patterns::NO_SUCH_ITEM_REPLY)
    end

    it 'INGREDIENT_PUT_REPLIES: returns NOT_FOUND_REPLY for a put the game answers "What were you referring to?" (26:39192 -> 26:39194)' do
      game.install(self)
      game.script('put my pewter ingot in my heavy cauldron', log('26:39194'))
      expect(DRC.bput('put my pewter ingot in my heavy cauldron', *Remedy::Patterns::INGREDIENT_PUT_REPLIES)).to eq(Remedy::Patterns::NOT_FOUND_REPLY)
      expect(game.diagnostics).to be_empty
    end

    it 'LIQUID_ADD_REPLIES: returns POUR_WHAT_REPLY for a pour the game answers "Pour what?" (26:22403 -> 26:22405, analog)' do
      game.install(self)
      game.script('pour moonshine jug in my heavy cauldron', log('26:22405'))
      expect(DRC.bput('pour moonshine jug in my heavy cauldron', *Remedy::Patterns::LIQUID_ADD_REPLIES)).to eq(Remedy::Patterns::POUR_WHAT_REPLY)
      expect(game.diagnostics).to be_empty
    end

    it "LIQUID_ADD_REPLIES: ignores \"Pour what?\" (26:22405) in another player's speech, waiting for the real reply" do
      game.install(self)
      spoken = ReplayGame.code(%(<preset id='speech'>Mallory says</preset>, "#{log('26:22405').text}"), from: '26:22405 as player speech')
      game.script('pour moonshine jug in my heavy cauldron', spoken, log('26:7687'))
      expect(DRC.bput('pour moonshine jug in my heavy cauldron', *Remedy::Patterns::LIQUID_ADD_REPLIES)).to eq('You toss')
    end

    it "INGREDIENT_PUT_REPLIES: ignores \"What were you referring to?\" (26:39194) in another player's speech" do
      game.install(self)
      spoken = ReplayGame.code(%(<preset id='speech'>Mallory says</preset>, "#{log('26:39194').text}"), from: '26:39194 as player speech')
      game.script('put my pewter ingot in my heavy cauldron', spoken)
      expect(DRC.bput('put my pewter ingot in my heavy cauldron', *Remedy::Patterns::INGREDIENT_PUT_REPLIES)).to eq('')
    end

    it 'CRAFT_REPLIES: returns Roundtime for a crush answered by the crush line 26:11057 and then Roundtime 25:10825' do
      game.install(self)
      game.script('crush my unguent with my rounded pestle', log('26:11057'), log('25:10825'))
      expect(DRC.bput('crush my unguent with my rounded pestle', *Remedy::Patterns::CRAFT_REPLIES)).to eq('Roundtime:')
    end

    it 'CRAFT_REPLIES: returns Roundtime, not the final-touches line, when Roundtime 26:6740 comes before final touches 26:6742 in one reply' do
      game.install(self)
      # The real mix at 07:25:08: "Roundtime: 9 sec." (26:6740), then
      # "Applying the final touches ..." (26:6742). bput stops at the first
      # line any pattern matches, so remedy sees Roundtime and crafts one
      # command more before it sees the remedy is done.
      game.script('mix my heavy cauldron with my mixing stick', log('26:6740'), log('26:6742'))
      expect(DRC.bput('mix my heavy cauldron with my mixing stick', *Remedy::Patterns::CRAFT_REPLIES)).to eq('Roundtime:')
    end

    it 'COMBINE_REPLIES: ignores another player saying "You combine", then reads the game line 26:32077' do
      game.install(self)
      # code-derived: the speech form other players' lines take (Remedy::NO_QUOTE).
      spoof = ReplayGame.code(%(Mallory says, "You combine the stacks of herbs together."), from: 'player speech form (Remedy::NO_QUOTE)')
      game.script('combine my nemoih', spoof, log('26:32077'))
      expect(DRC.bput('combine my nemoih', *Remedy::Patterns::COMBINE_REPLIES)).to eq('That stack of herbs is too large to add')
    end

    it 'CRAFT_REPLIES: returns the refusal "You need a more suitable type of herb" for the crush it answered (25:50933)' do
      game.install(self)
      game.script('crush my georin with my rounded pestle', log('25:50933'))
      expect(DRC.bput('crush my georin with my rounded pestle', *Remedy::Patterns::CRAFT_REPLIES)).to eq('You need a more suitable type of herb')
    end

    [['push my tonic with my sieve', '26:24873', "The sieve doesn't appear suitable for working on"],
     ['turn my heavy cauldron', '26:25113', "The cauldron doesn't appear suitable for working on"],
     ['push my curative with my sieve', '26:39150', 'You need another catalyst material'],
     ['push my tonic with my sieve', '26:24636', 'You need another splash of water'],
     ['turn my large mortar', '26:21642', 'You need another splash of alcohol']].each do |command, cite, text|
      it "STEP_REPLIES: returns #{text.inspect} at once for #{command.inspect} refused by #{cite}" do
        game.install(self)
        game.script(command, log(cite))
        expect(DRC.bput(command, *Remedy::Patterns::STEP_REPLIES)).to eq(text)
        expect(game.clock).to eq(0)
      end
    end

    it 'STEP_REPLIES: returns "You need another prepared herb" at once for a smell refused with the herb cue alone' do
      game.install(self)
      # code-derived (remedy.lic:51): no "prepared herb" cue is in either log.
      herb_cue = ReplayGame.code('You need another prepared herb to continue crafting some unfinished nemoih unguent.', from: 'R:51 /You need another prepared herb/')
      game.script('smell my unguent', herb_cue)
      expect(DRC.bput('smell my unguent', *Remedy::Patterns::STEP_REPLIES)).to eq('You need another prepared herb')
      expect(game.clock).to eq(0)
    end

    it 'STEP_REPLIES: still returns the Roundtime of a done step when a need cue follows it (the order of 26:6310-6313)' do
      game.install(self)
      game.script('push my unguent with my sieve', log('26:10935'), log('26:39150'))
      expect(DRC.bput('push my unguent with my sieve', *Remedy::Patterns::STEP_REPLIES)).to eq('Roundtime')
    end

    it 'STEP_REPLIES: skips another player saying the refusal, then reads the Roundtime (26:10935)' do
      game.install(self)
      # code-derived: the speech form other players' lines take (Remedy::NO_QUOTE).
      spoof = ReplayGame.code(%(Mallory says, "#{log('26:24873').text}"), from: 'player speech form (Remedy::NO_QUOTE)')
      game.script('push my unguent with my sieve', spoof, log('26:10935'))
      expect(DRC.bput('push my unguent with my sieve', *Remedy::Patterns::STEP_REPLIES)).to eq('Roundtime')
    end

    it 'freezes every pattern list, so no caller can change what remedy reads' do
      lists = Remedy::Patterns.constants.map { |name| Remedy::Patterns.const_get(name) }
      expect(lists).to all(be_frozen)
    end
  end

  describe 'Remedy::Patterns, against the lists remedy gave DRC.bput and Flags.add at 03f11b54' do
    # A String in a match list is read as /<string>/i: lich-5 DRC.bput
    # (common.rb:197) and Flags.add (events.rb:27) both convert it
    # with `item.is_a?(Regexp) ? item : /#{item}/i`.
    #
    # @param patterns [Array<String, Regexp>] a match list as remedy wrote it
    # @return [Array<Regexp>] the list bput or Flags.add matches lines with
    def as_bput_reads(patterns)
      patterns.map { |item| item.is_a?(Regexp) ? item : /#{item}/i }
    end

    # The members of a list that are old patterns, in the list's order.
    #
    # @param list [Array<Regexp>] a Remedy pattern list
    # @param before [Array<Regexp>] the old list, as bput reads it
    # @return [Array<Regexp>] list's members found in before
    def old_members(list, before)
      list.select { |pattern| before.include?(pattern) }
    end

    # Every old pattern is compared element by element (source, case option
    # and anchors), so the code-derived members no log exercises are pinned
    # too: dropping, narrowing or reordering one fails. A fix layer may add
    # a reply the old list did not wait for; bput reads the lines in order
    # and, on each line, returns the first pattern that matches
    # (common.rb:273-276), so an added pattern changes no line an old one
    # answered unless both match that same line.
    no_quote = Remedy::NO_QUOTE
    {
      'VESSEL_COUNT_REPLIES'       => ['R:74 (and 81, 92, 99)', [/^[^"]*?parts left of the/i, /^[^"]*?part left of the/i, '^I could not find what you were referring to.']],
      'CUBE_TOUCH_REPLIES'         => ['R:198', [/^Warm vapor swirls around your head in a misty halo/, /^A thin cloud of vapor manifests with no particular effect./, /^Touch what/]],
      'HERB_COUNT_REPLIES'         => ['R:216 (and 230, 234)', ['^You count out \d+']],
      'COMBINE_REPLIES'            => ['R:227 (and 235)', [/^[^"]*?You combine/i, /^[^"]*?too large to add/i, '^You must be holding both']],
      'FIRST_STACK_COUNT_REPLIES'  => ['R:236', ['^You count out \d+ pieces']],
      'SECOND_STACK_COUNT_REPLIES' => ['R:237', ['^I could not find', '^You count out \d+ pieces']],
      'HERB_PUT_REPLIES'           => ['R:247', ['^You put', /^[^"]*?already has something/i, /^[^"]*?can only hold/i, '^You realize the', /^[^"]*?You vigorously rub/i]],
      'TILT_REPLIES'               => ['R:251', ['You grab']],
      'TILT_AGAIN_REPLIES'         => ['R:252', ['You grab', 'Roundtime']],
      'HERB_PUT_AGAIN_REPLIES'     => ['R:253', ['You put', 'can only hold']],
      'CRAFT_REPLIES'              => ['R:285-291', ['^Applying the final touches', /^[^"]*?Interesting thought really... but no./i, /^[^"]*?you just can't mix/i,
                                                     /^[^"]*?Try as you might/i, /^[^"]*?That craftable requires more pieces of that plant to begin/i, /^[^"]*?Roundtime:/i]],
      'LIQUID_ADD_REPLIES'         => ['R:313 (and 333)', [/^[^"]*?Roundtime/i, /^[^"]*?You toss/i, /^[^"]*?You cannot find a way to add that as an ingredient/i]],
      'INGREDIENT_PUT_REPLIES'     => ['R:353 (and 364)', ['Roundtime', 'You vigorously']],
      'STEP_REPLIES'               => ['R:375 (and 384, 391)', ['Roundtime']],
      'RELEASE_SPELL_REPLIES'      => ['R:416', ['You let your concentration lapse', "You aren't preparing a spell"]],
      'RELEASE_MANA_REPLIES'       => ['R:417', ['You release all', "You aren't harnessing any mana"]],
      'RELEASE_SYMBIOSIS_REPLIES'  => ['R:418', ["But you haven't", 'You release', 'Repeat this command']],
      'MARK_REPLIES'               => ['R:423', ['carefully hammer the stamp', 'You cannot figure out how to do that', 'too badly damaged', /score the surface with the stamp/]]
    }.each do |name, (source, before)|
      it "#{name} keeps the list remedy.lic gave bput at #{source} (03f11b54), element by element, in order" do
        expected = as_bput_reads(before)
        expect(old_members(Remedy::Patterns.const_get(name), expected)).to eq(expected)
      end
    end

    {
      'remedy-water'    => ['R:48', [/#{no_quote}You need another splash of water/i]],
      'remedy-alcohol'  => ['R:49', [/#{no_quote}You need another splash of alcohol/i]],
      'remedy-catalyst' => ['R:50', [/#{no_quote}You need another catalyst material/i]],
      'remedy-herb'     => ['R:51', [/#{no_quote}You need another prepared herb/i]],
      'remedy-turn'     => ['R:52', [/#{no_quote}Clumps of material stick to the sides/i, /#{no_quote}Once finished you notice clumps of material/i]],
      'remedy-sieve'    => ['R:54', [/#{no_quote}Upon completion you see some particulate clouding up the mixture./i, /#{no_quote}with a sieve/i]]
    }.each do |flag, (source, before)|
      it "#{flag} keeps the patterns remedy.lic gave Flags.add at #{source} (03f11b54), element by element" do
        expected = as_bput_reads(before)
        expect(old_members(Remedy::FLAGS[flag], expected)).to eq(expected)
      end
    end

    it 'remedy-smell keeps R:53 (03f11b54) except "you should smell the mixture", which "smell the mixture" covers' do
      # R:53 listed begins-to-transition, you-should-smell and smell-the-mixture;
      # every line the middle one matches, the last one matches too.
      kept = [/#{Remedy::NO_QUOTE}begins to transition colors/i, /#{Remedy::NO_QUOTE}smell the mixture/i]
      dropped = /#{Remedy::NO_QUOTE}you should smell the mixture/i
      expect(old_members(Remedy::FLAGS['remedy-smell'], kept + [dropped])).to eq(kept)
    end
  end

  describe 'Remedy::ARG_DEFINITIONS' do
    it 'offers the book form and the continue form, in that order' do
      expect(Remedy::ARG_DEFINITIONS.map { |form| form.map { |definition| definition[:name] } })
        .to eq([%w[book_type chapter recipe_name herb1 herb2 catalyst container noun], %w[continue herb2 catalyst container noun]])
    end

    it 'gives both forms the same herb2, catalyst, container and noun definitions' do
      book, continuing = Remedy::ARG_DEFINITIONS
      expect(book.last(4)).to eq(continuing.last(4))
    end

    it 'is frozen through every form and definition, as lich-5 ArgParser only reads it' do
      expect(Remedy::ARG_DEFINITIONS).to be_frozen
      expect(Remedy::ARG_DEFINITIONS).to all(be_frozen)
      expect(Remedy::ARG_DEFINITIONS.flatten).to all(be_frozen)
    end
  end

  describe 'Remedy.new and Remedy#run' do
    let(:settings) do
      OpenStruct.new(crafting_container: "botanist's toolbag", crafting_items_in_container: [], alchemy_belt: nil,
                     alchemy_tools: [], crafting_training_spells: [], hometown: 'Crossing', mark_crafted_goods: false,
                     cube_armor_piece: nil, herb_container: nil, water_container: nil, alcohol_container: nil)
    end
    let(:args) do
      OpenStruct.new(book_type: 'remedies', chapter: '3', recipe_name: 'some head unguent', herb1: 'nemoih', herb2: 'na',
                     catalyst: 'pewter ingot', container: 'mortar', noun: 'unguent')
    end
    let(:exit_hooks) { [] }
    let(:messages) { [] }

    before do
      game.install(self)
      $test_data.crafting = { 'remedies' => {} }
      allow(DRC).to receive(:message) { |text| messages << text }
    end

    it 'sends nothing, registers no Flag and no before_dying block when built' do
      allow_any_instance_of(Remedy).to receive(:before_dying) { |_remedy, &block| exit_hooks << block }
      Remedy.new(settings, args)
      expect(game.sent).to be_empty
      expect(Flags.matchers).to be_empty
      expect(exit_hooks).to be_empty
    end

    it 'registers its before_dying block first, before any Flag or command, so a stop at the first check still cleans up' do
      state_at_hook = nil
      allow_any_instance_of(Remedy).to receive(:before_dying) do |_remedy, &block|
        state_at_hook = { flags: Flags.matchers.keys, sent: game.sent.dup }
        exit_hooks << block
      end
      # alchemy_tools lists no mortar: run stops in its first check.
      expect { Remedy.new(settings, args).run }.to raise_error(SystemExit)
      expect(state_at_hook).to eq(flags: [], sent: [])
      expect(Flags.matchers.keys).to eq(Remedy::REGISTERED_FLAGS.keys)
      expect(messages.first).to eq('*** some head unguent needs a mortar, and your alchemy_tools setting lists none. ***')
      exit_hooks.each(&:call)
      expect(Flags.matchers).to be_empty
      expect(game.sent).to be_empty
    end
  end
end

# Layer 04: the request, the vessel and stirrer, and the gets
# and stows, tested as units. The commands these objects build are the ones
# the contract groups above pin from the logs (the crush of 26:10750's run,
# the mix of 26:5915's run); the gets and stows are the DRCC/DRCI calls
# remedy.lic:148-171 at 03f11b54 made.
RSpec.describe 'Remedy order, tools and inventory' do
  # Lich evals the whole script again on every run and keeps the constants
  # an earlier run defined (lich-5 lib/common/script.rb:17-27, 169-174, 209;
  # no remove_const), and callers run remedy many times in one session:
  # workorders.lic:816-820 at 03f11b54 once per remedy ordered,
  # create_remedies.lic:47/49 once per recipe. load_lic_class evals the class
  # once per process, so this example evals it twice itself, in a module of
  # its own, leaving the Remedy the other examples use untouched.
  describe 'a second run in the same Lich session' do
    let(:session) { Module.new }

    # Evals remedy.lic's class body inside session, as one run of the script
    # does.
    #
    # @return [void]
    def run_class_body
      lines = File.readlines(lic_path('remedy.lic'))
      range = lic_definition_range(lines, 'class', 'Remedy', 'remedy.lic')
      session.module_eval(lines[range].join, lic_path('remedy.lic'), range.begin + 1)
    end

    around do |example|
      verbose = $VERBOSE
      $VERBOSE = nil # the second run re-assigns every constant, which only warns
      example.run
    ensure
      $VERBOSE = verbose
    end

    it 'loads the class body again without an error (a superclass mismatch would stop every run after the first)' do
      run_class_body
      expect { run_class_body }.not_to raise_error
    end

    it 'keeps Order and Tools Data classes with their own constants and methods after the second run' do
      2.times { run_class_body }
      tools = session::Remedy::Tools.new(container: 'large mortar', stirrer: 'rounded pestle', verb: 'crush')
      expect(session::Remedy::Order.ancestors).to include(Data)
      expect(session::Remedy::Tools::MORTAR).to eq(/mort/)
      expect(session::Remedy.const_defined?(:MORTAR, false)).to be(false)
      expect(tools.first_command('nemoih')).to eq('crush my nemoih with my rounded pestle')
    end
  end

  let(:toolbag) { "botanist's toolbag" }
  let(:toolstrap) { { 'name' => 'grass toolstrap', 'items' => ['heavy cauldron', 'mixing stick', 'large mortar', 'rounded pestle'] } }
  let(:bag_items) { ['alcohol', 'water', 'pewter ingot', 'remed book'] }
  let(:logged_tools) { ['heavy cauldron', 'mixing stick', 'turtle-shaped sieve', 'large mortar', 'rounded pestle'] }
  let(:game) { ReplayGame.new }
  let(:messages) { [] }

  # The arguments a caller's list reaches remedy with, as Lich splits them
  # and parse_args matches them.
  #
  # @param args [Array<Object>] the caller's DRC.wait_for_script_to_complete list
  # @return [OpenStruct] parse_args' result
  def parsed_call(args)
    ArgParserModel.parse(Remedy::ARG_DEFINITIONS, ArgParserModel.caller_vars(args).drop(1))
  end

  # The arguments a typed `;remedy ...` reaches remedy with.
  #
  # @param line [String] the arguments as typed
  # @return [OpenStruct] parse_args' result
  def parsed_typed(line)
    ArgParserModel.parse(Remedy::ARG_DEFINITIONS, ArgParserModel.script_vars(line).drop(1))
  end

  # @param container [String] the vessel word
  # @param recipe_name [String, nil]
  # @return [Remedy::Order] a book-form order for some head unguent
  def order_for(container, recipe_name: 'some head unguent')
    Remedy::Order.new(mode: :book, book_type: 'remedies', chapter: '3', recipe_name: recipe_name, herb1: 'nemoih',
                      herb2: 'na', catalyst: 'pewter ingot', container_request: container, noun: 'unguent')
  end

  describe 'Remedy::Order.from_args' do
    it 'reads every field of the workorders.lic:818 call for some head unguent (base-recipes.yaml:8520)' do
      order = Remedy::Order.from_args(parsed_call(['remedies', 3, 'some head unguent', 'nemoih', 'na', 'pewter ingot', 'mortar', 'unguent']))
      expect(order.to_h).to eq(mode: :book, book_type: 'remedies', chapter: '3', recipe_name: 'some head unguent', herb1: 'nemoih',
                               herb2: 'na', catalyst: 'pewter ingot', container_request: 'mortar', noun: 'unguent')
      expect(order).not_to be_continue
    end

    it 'reads a two-herb recipe, some blister cream (base-recipes.yaml:8295), with both herbs as the caller gave them' do
      order = Remedy::Order.from_args(parsed_call(['remedies', 2, 'some blister cream', 'red flower', 'nemoih', 'coal nugget', 'mortar', 'cream']))
      expect(order.herbs).to eq(['red flower', 'nemoih'])
      expect(order.catalyst).to eq('coal nugget')
    end

    ['na', 'none', 'not used'].each do |herb2|
      it "keeps herb2 #{herb2.inspect} exactly as typed (normalising it is layer 09's change)" do
        quoted = herb2.include?(' ') ? %("#{herb2}") : herb2
        order = Remedy::Order.from_args(parsed_typed(%(remedies 3 "some head unguent" nemoih #{quoted} "pewter ingot" mortar unguent)))
        expect(order.herb2).to eq(herb2)
        expect(order.herbs).to eq(['nemoih', herb2])
      end
    end

    it 'keeps the vessel word as given, a prefix such as mort included, for Tools.resolve to look up' do
      order = Remedy::Order.from_args(parsed_typed('remedies 3 "Some Head Unguent" Nemoih none "Pewter Ingot" mort Unguent'))
      expect(order.container_request).to eq('mort')
      expect(order.recipe_name).to eq('some head unguent')
    end

    it 'reads the continue form as :continue, with no book type, chapter, recipe name or herb1' do
      order = Remedy::Order.from_args(parsed_typed('continue none "pewter ingot" mortar unguent'))
      expect(order).to be_continue
      expect(order.to_h).to eq(mode: :continue, book_type: nil, chapter: nil, recipe_name: nil, herb1: nil,
                               herb2: 'none', catalyst: 'pewter ingot', container_request: 'mortar', noun: 'unguent')
      expect(order.herbs).to eq([nil, 'none'])
    end

    it 'is immutable: swapping herb1 makes a new order and leaves the one parsed alone' do
      parsed = order_for('mortar')
      swapped = parsed.with(herb1: 'dried flower')
      expect(parsed).to be_frozen
      expect(parsed.herb1).to eq('nemoih')
      expect(swapped.herbs).to eq(['dried flower', 'na'])
    end
  end

  describe 'Remedy::Order#continue_command (layer 12)' do
    {
      'remedies 3 "some head unguent" nemoih na "pewter ingot" mortar unguent'       => ';remedy continue na "pewter ingot" mortar unguent',
      'remedies 3 "some head unguent" nemoih "not used" "pewter ingot" mort unguent' => ';remedy continue "not used" "pewter ingot" mort unguent',
      'remedies 6 "a general elixir" belradi none coal bowl elixir'                  => ';remedy continue none coal bowl elixir',
      'continue na "pewter ingot" mortar unguent'                                    => ';remedy continue na "pewter ingot" mortar unguent'
    }.each do |typed_line, command|
      it "gives #{command} for ;remedy #{typed_line}" do
        expect(Remedy::Order.from_args(parsed_typed(typed_line)).continue_command).to eq(command)
      end

      it "gives a command for ;remedy #{typed_line} that parses back to the same herb2, catalyst, vessel and noun" do
        order = Remedy::Order.from_args(parsed_typed(typed_line))
        resumed = Remedy::Order.from_args(parsed_typed(order.continue_command.delete_prefix(';remedy ')))
        expect(resumed).to be_continue
        expect(resumed.to_h.slice(:herb2, :catalyst, :container_request, :noun)).to eq(order.to_h.slice(:herb2, :catalyst, :container_request, :noun))
      end
    end
  end

  describe 'Remedy::Order#second_herb (layer 09)' do
    ['na', 'none', 'not used'].each do |herb2|
      it "reads herb2 #{herb2.inspect}, as typed, as no second herb, and keeps herb2 and herbs as given" do
        quoted = herb2.include?(' ') ? %("#{herb2}") : herb2
        order = Remedy::Order.from_args(parsed_typed(%(remedies 3 "some head unguent" nemoih #{quoted} "pewter ingot" mortar unguent)))
        expect(order.second_herb).to be_nil
        expect(order.herb2).to eq(herb2)
        expect(order.herbs).to eq(['nemoih', herb2])
      end
    end

    it 'reads NA typed in capitals as none too, because Lich lowercases every value' do
      order = Remedy::Order.from_args(parsed_typed('remedies 3 "some head unguent" nemoih NA "pewter ingot" mortar unguent'))
      expect(order.second_herb).to be_nil
    end

    it 'reads the na of the workorders.lic:820 call for some head unguent as none' do
      order = Remedy::Order.from_args(parsed_call(['remedies', 3, 'some head unguent', 'nemoih', 'na', 'pewter ingot', 'mortar', 'unguent']))
      expect(order.second_herb).to be_nil
    end

    it 'gives the second herb of a two-herb recipe, some blister cream (base-recipes.yaml:8295)' do
      order = Remedy::Order.from_args(parsed_call(['remedies', 2, 'some blister cream', 'red flower', 'nemoih', 'coal nugget', 'mortar', 'cream']))
      expect(order.second_herb).to eq('nemoih')
    end

    it 'takes a missing herb2 as none' do
      expect(order_for('mortar').with(herb2: nil).second_herb).to be_nil
    end

    it 'takes only the whole value as none: a herb whose name holds "none" or "na" is a herb' do
      expect(order_for('mortar').with(herb2: 'nightshade').second_herb).to eq('nightshade')
      expect(order_for('mortar').with(herb2: 'none such').second_herb).to eq('none such')
    end
  end

  describe 'Remedy::Tools.resolve' do
    before do
      game.install(self)
      allow(DRC).to receive(:message) { |text| messages << text }
    end

    # @param tools [Array<String>, nil] alchemy_tools
    # @return [OpenStruct]
    def settings_with(tools)
      OpenStruct.new(alchemy_tools: tools)
    end

    it 'takes the large mortar, the rounded pestle and crush for a recipe asking for a mortar' do
      tools = Remedy::Tools.resolve(settings_with(logged_tools), order_for('mortar'))
      expect(tools.to_h).to eq(container: 'large mortar', stirrer: 'rounded pestle', verb: 'crush')
      expect(tools).to be_mortar
    end

    it 'finds the large mortar from the prefix mort' do
      expect(Remedy::Tools.resolve(settings_with(logged_tools), order_for('mort')).container).to eq('large mortar')
    end

    it 'takes the heavy cauldron, the mixing stick and mix for a recipe asking for a bowl, though a pestle is listed' do
      tools = Remedy::Tools.resolve(settings_with(logged_tools), order_for('bowl'))
      expect(tools.to_h).to eq(container: 'heavy cauldron', stirrer: 'mixing stick', verb: 'mix')
      expect(tools).not_to be_mortar
    end

    it 'takes the first bowl-like entry, a ceramic bowl, when it comes before any cauldron' do
      tools = Remedy::Tools.resolve(settings_with(['rustic mortar', 'ceramic bowl', 'iron cauldron']), order_for('bowl'))
      expect(tools.container).to eq('ceramic bowl')
    end

    it 'names the stirrer pestle when alchemy_tools lists a mortar but no pestle' do
      tools = Remedy::Tools.resolve(settings_with(['rustic mortar', 'mesh sieve']), order_for('mortar'))
      expect(tools.stirrer).to eq('pestle')
    end

    it 'stops with both messages, and sends nothing, when alchemy_tools lists no such vessel' do
      expect { Remedy::Tools.resolve(settings_with(['rustic mortar', 'rustic pestle']), order_for('bowl')) }.to raise_error(SystemExit)
      expect(messages).to eq(['*** some head unguent needs a bowl, and your alchemy_tools setting lists none. ***',
                              '*** Add your bowl to alchemy_tools, then run this again. ***'])
      expect(game.sent).to be_empty
    end

    it 'stops the same way when alchemy_tools is not set at all' do
      expect { Remedy::Tools.resolve(settings_with(nil), order_for('mortar')) }.to raise_error(SystemExit)
      expect(messages.first).to eq('*** some head unguent needs a mortar, and your alchemy_tools setting lists none. ***')
    end

    it 'keeps the blank recipe name of the continue form in the stop message, as before' do
      expect { Remedy::Tools.resolve(settings_with([]), order_for('mortar', recipe_name: nil)) }.to raise_error(SystemExit)
      expect(messages.first).to eq('***  needs a mortar, and your alchemy_tools setting lists none. ***')
    end

    it 'CURRENT (H12): matches the vessel word anywhere and unescaped, so r takes the heavy cauldron (layer 15 escapes it)' do
      # flipped by layer 15 (escaped, still a prefix match).
      expect(Remedy::Tools.resolve(settings_with(logged_tools), order_for('r')).container).to eq('heavy cauldron')
    end
  end

  describe 'Remedy::Tools crafting commands' do
    let(:mortar) { Remedy::Tools.new(container: 'large mortar', stirrer: 'rounded pestle', verb: 'crush') }
    let(:cauldron) { Remedy::Tools.new(container: 'heavy cauldron', stirrer: 'mixing stick', verb: 'mix') }

    it 'crushes the herb first, then the product, in a mortar (the C02 run, 26:10747-11396)' do
      expect(mortar.first_command('nemoih')).to eq('crush my nemoih with my rounded pestle')
      expect(mortar.next_command('unguent')).to eq('crush my unguent with my rounded pestle')
    end

    it 'mixes the vessel itself, first and after, in a cauldron (the C01 run, 26:5896-6801)' do
      expect(cauldron.first_command('belradi')).to eq('mix my heavy cauldron with my mixing stick')
      expect(cauldron.next_command('elixir')).to eq('mix my heavy cauldron with my mixing stick')
    end

    it 'treats any vessel whose name holds mort as a mortar, as remedy always has' do
      rustic = Remedy::Tools.new(container: 'rustic mortar', stirrer: 'rustic pestle', verb: 'crush')
      expect(rustic).to be_mortar
      expect(rustic.first_command('aevaes')).to eq('crush my aevaes with my rustic pestle')
    end
  end

  describe 'Remedy::Inventory' do
    let(:herb_container) { nil }
    let(:settings) do
      OpenStruct.new(crafting_container: toolbag, crafting_items_in_container: bag_items, alchemy_belt: toolstrap,
                     herb_container: herb_container)
    end
    let(:inventory) { Remedy::Inventory.new(settings, herbs: %w[nemoih na]) }

    before do
      game.install(self)
      allow(DRCC).to receive(:get_crafting_item).and_return(true)
      allow(DRCC).to receive(:stow_crafting_item).and_return(true)
      allow(DRCI).to receive(:exists?).and_return(false)
      allow(DRCI).to receive(:lower_item?).and_return(true)
    end

    it 'sends nothing and asks nothing when built' do
      inventory
      expect(game.sent).to be_empty
      expect(DRCI).not_to have_received(:exists?)
    end

    context 'with a herb_container' do
      let(:herb_container) { 'smokewood basket' }

      it 'gets herb1 from the herb_container when it holds some, asking for that herb only' do
        allow(DRCI).to receive(:exists?).with('nemoih', 'smokewood basket').and_return(true)
        expect(inventory.get('nemoih')).to be(true)
        expect(DRCC).to have_received(:get_crafting_item).with('nemoih', 'smokewood basket', ['nemoih'], toolstrap)
      end

      it 'gets herb1 from the crafting container when only it holds some' do
        allow(DRCI).to receive(:exists?).with('nemoih', toolbag).and_return(true)
        inventory.get('nemoih')
        expect(DRCC).to have_received(:get_crafting_item).with('nemoih', toolbag, ['nemoih'], toolstrap)
      end

      it 'stows herb1 in the herb_container' do
        inventory.stow('nemoih')
        expect(DRCC).to have_received(:stow_crafting_item).with('nemoih', 'smokewood basket', toolstrap)
      end

      it 'stows anything else in the crafting container, by way of the belt' do
        inventory.stow('rounded pestle')
        expect(DRCC).to have_received(:stow_crafting_item).with('rounded pestle', toolbag, toolstrap)
      end

      describe 'the leftover stow after the vessel put (layer 11)' do
        it 'puts the herb in the herb_container and answers true at once when the hand is then free of it' do
          allow(DRCI).to receive(:in_hands?).with('nemoih').and_return(false)
          expect(inventory.stow_leftover('nemoih')).to be(true)
          expect(DRCC).to have_received(:stow_crafting_item).once
          expect(DRCC).to have_received(:stow_crafting_item).with('nemoih', 'smokewood basket', toolstrap)
          expect(game.clock).to eq(0)
        end

        # The late reply is code-derived, as for a get (LATE_GET_LOOKS): no
        # put in the logs timed out. Today the run went on after such a stow,
        # however late its reply: the next command waited behind it. The
        # looks after the first stow last STOP_LOOKS (30 s), so with the
        # stow's own 15 s bput three silences pass.
        [3, 16, 30].each do |late|
          it "answers true with the one stow when the herb leaves the hand #{late} s after the herb_container stow, a reply that came late" do
            allow(DRCI).to receive(:in_hands?).with('nemoih') { game.clock < late }
            expect(inventory.stow_leftover('nemoih')).to be(true)
            expect(DRCC).to have_received(:stow_crafting_item).once
            expect(game.clock).to eq(late)
          end
        end

        it 'looks for 30 s (STOP_LOOKS), twice the bput wait, after the herb_container stow' do
          expect(Remedy::Inventory::STOP_LOOKS).to eq(2 * Remedy::Inventory::LATE_GET_LOOKS)
          expect(Remedy::Inventory::STOP_LOOKS).to eq(30)
        end

        it 'puts the herb in the crafting container only after looking for 30 s while the herb_container left it in hand (26:32077), and answers true when that frees the hand' do
          bags = []
          allow(DRCC).to receive(:stow_crafting_item) { |_name, bag, _belt| bags << bag && true }
          allow(DRCI).to receive(:in_hands?).with('nemoih') { !bags.include?(toolbag) }
          expect(inventory.stow_leftover('nemoih')).to be(true)
          expect(bags).to eq(['smokewood basket', toolbag])
          expect(game.clock).to eq(Remedy::Inventory::STOP_LOOKS)
        end

        it 'puts the herb in the crafting container when it leaves the hand only 31 s after the herb_container stow, one look too late' do
          bags = []
          allow(DRCC).to receive(:stow_crafting_item) { |_name, bag, _belt| bags << bag && true }
          allow(DRCI).to receive(:in_hands?).with('nemoih') { game.clock < 31 }
          expect(inventory.stow_leftover('nemoih')).to be(true)
          expect(bags).to eq(['smokewood basket', toolbag])
          expect(game.clock).to eq(31)
        end

        it 'answers false when the crafting container leaves the herb in hand too, after looking for 30 s after the first stow and 15 s after the second' do
          allow(DRCI).to receive(:in_hands?).with('nemoih').and_return(true)
          expect(inventory.stow_leftover('nemoih')).to be(false)
          expect(DRCC).to have_received(:stow_crafting_item).twice
          expect(game.clock).to eq(Remedy::Inventory::STOP_LOOKS + Remedy::Inventory::LATE_GET_LOOKS)
        end

        it 'reads the hand by the last word of a herb of several words, the noun the put matched' do
          allow(DRCI).to receive(:in_hands?).with('flower').and_return(false)
          expect(inventory.with_herbs(['dried flower', 'na']).stow_leftover('dried flower')).to be(true)
          expect(DRCC).to have_received(:stow_crafting_item).with('dried flower', 'smokewood basket', toolstrap)
        end
      end
    end

    it 'gets a herb found in neither container from wherever DRCC finds it, and says so with UNROUTED' do
      expect(inventory.get('nemoih')).to eq(Remedy::Inventory::UNROUTED)
      expect(Remedy::Inventory::UNROUTED).to eq('none')
      expect(DRCI).to have_received(:exists?).with('nemoih', toolbag)
      expect(DRCC).to have_received(:get_crafting_item).with('nemoih', toolbag, bag_items, toolstrap)
    end

    it 'never asks where a tool is: it gets it from the belt or the crafting container' do
      expect(inventory.get('rounded pestle')).to eq('none')
      expect(DRCI).not_to have_received(:exists?)
      expect(DRCC).to have_received(:get_crafting_item).with('rounded pestle', toolbag, bag_items, toolstrap)
    end

    it 'routes herb2 as given, even na, as remedy always has' do
      inventory.get('na')
      expect(DRCI).to have_received(:exists?).with('na', toolbag)
    end

    # layer 09: the pick-up is guarded, so it passes skip_exit and reads the hands
    it 'picks the lowered vessel up with no bag items, so DRCC looks on the ground' do
      allow(DRCI).to receive(:in_hands?).with('mortar').and_return(true)
      expect(inventory.pick_up('large mortar')).to be(true)
      expect(DRCC).to have_received(:get_crafting_item).with('large mortar', toolbag, nil, toolstrap, true)
    end

    it 'lowers the vessel with DRCI.lower_item?' do
      inventory.lower('large mortar')
      expect(DRCI).to have_received(:lower_item?).with('large mortar')
    end

    it 'stows herb1 in the crafting container when no herb_container is set' do
      inventory.stow('nemoih')
      expect(DRCC).to have_received(:stow_crafting_item).with('nemoih', toolbag, toolstrap)
    end

    # layer 11: with no herb_container the first stow already went to the
    # crafting container, so it is not tried again
    it 'answers false after one stow, and 30 s of looking (STOP_LOOKS), when no herb_container is set and the herb stays in hand' do
      allow(DRCI).to receive(:in_hands?).with('nemoih').and_return(true)
      expect(inventory.stow_leftover('nemoih')).to be(false)
      expect(DRCC).to have_received(:stow_crafting_item).once
      expect(DRCC).to have_received(:stow_crafting_item).with('nemoih', toolbag, toolstrap)
      expect(game.clock).to eq(Remedy::Inventory::STOP_LOOKS)
    end

    # Code-derived, as for a get (LATE_GET_LOOKS): a stow answered after
    # DRC.bput gave up still takes the herb, and today the run went on
    # however late the reply came.
    [3, 16, 30].each do |late|
      it "answers true when no herb_container is set and the herb leaves the hand #{late} s after the stow, a reply that came late" do
        allow(DRCI).to receive(:in_hands?).with('nemoih') { game.clock < late }
        expect(inventory.stow_leftover('nemoih')).to be(true)
        expect(DRCC).to have_received(:stow_crafting_item).once
        expect(game.clock).to eq(late)
      end
    end

    it 'answers false when no herb_container is set and the herb leaves the hand only 31 s after the stow, one look too late' do
      allow(DRCI).to receive(:in_hands?).with('nemoih') { game.clock < 31 }
      expect(inventory.stow_leftover('nemoih')).to be(false)
      expect(DRCC).to have_received(:stow_crafting_item).once
      expect(game.clock).to eq(Remedy::Inventory::STOP_LOOKS)
    end

    it 'hands an empty hand (nil) to DRCC to stow, as the stow by hand always has' do
      inventory.stow(nil)
      expect(DRCC).to have_received(:stow_crafting_item).with(nil, toolbag, toolstrap)
    end

    it 'gets and stows the remed book with no belt, as remedy always has (H08, layer 15)' do
      inventory.get_tool(Remedy::REMED_BOOK, belt: nil)
      inventory.stow_tool(Remedy::REMED_BOOK, belt: nil)
      expect(DRCC).to have_received(:get_crafting_item).with('remed book', toolbag, bag_items, nil)
      expect(DRCC).to have_received(:stow_crafting_item).with('remed book', toolbag, nil)
    end

    it 'routes the swapped herb1 as a herb, and no longer the one asked for, after with_herbs' do
      swapped = inventory.with_herbs(['dried flower', 'na'])
      swapped.get('dried flower')
      swapped.get('red flower')
      expect(DRCI).to have_received(:exists?).with('dried flower', toolbag)
      expect(DRCI).not_to have_received(:exists?).with('red flower', anything)
      expect(swapped.bag).to eq(toolbag)
    end

    it 'leaves the original inventory routing the old names after with_herbs' do
      inventory.with_herbs(['dried flower', 'na'])
      inventory.get('dried flower')
      expect(DRCI).not_to have_received(:exists?)
    end

    # layer 12: the stows by name give DRCC.stow_crafting_item what the hand
    # holds, as the stows by hand position did
    describe 'the stows by name (layer 12)' do
      before do
        allow(DRCI).to receive(:in_left_hand?) { |item| ReplayCommons.matches?($left_hand, item) }
        allow(DRCI).to receive(:in_right_hand?) { |item| ReplayCommons.matches?($right_hand, item) }
      end

      it 'stow_held puts away the hand holding the vessel, by the full name that hand shows' do
        $left_hand = 'luminescent starshine mixing stick'
        $right_hand = 'heavy cauldron with twisted Dwarven iron handles'
        expect(inventory.stow_held('heavy cauldron')).to be(true)
        expect(DRCC).to have_received(:stow_crafting_item).with('heavy cauldron with twisted Dwarven iron handles', toolbag, toolstrap).once
      end

      it 'stow_held finds the item by the last word of its name, as the guarded gets do' do
        $left_hand = 'diamondique large mortar'
        expect(inventory.stow_held('rustic mortar')).to be(true)
        expect(DRCI).to have_received(:in_left_hand?).with('mortar')
        expect(DRCC).to have_received(:stow_crafting_item).with('diamondique large mortar', toolbag, toolstrap)
      end

      it 'stow_held sends nothing and answers false when neither hand holds the item' do
        $left_hand = 'nemoih unguent'
        expect(inventory.stow_held('rounded pestle')).to be(false)
        expect(DRCC).not_to have_received(:stow_crafting_item)
      end

      it 'stow_beside puts away the left hand when the vessel is in the right, as remedy always has' do
        $left_hand = 'rounded pestle'
        $right_hand = 'diamondique large mortar'
        inventory.stow_beside('large mortar')
        expect(DRCC).to have_received(:stow_crafting_item).with('rounded pestle', toolbag, toolstrap).once
      end

      it 'stow_beside puts away the right hand when the vessel is in the left' do
        $left_hand = 'diamondique large mortar'
        $right_hand = 'rounded pestle'
        inventory.stow_beside('large mortar')
        expect(DRCC).to have_received(:stow_crafting_item).with('rounded pestle', toolbag, toolstrap).once
      end

      it 'stow_beside falls back to the left hand when neither hand shows the vessel, as remedy always has' do
        $left_hand = 'turtle-shaped sieve'
        $right_hand = 'pewter ingot'
        inventory.stow_beside('large mortar')
        expect(DRCC).to have_received(:stow_crafting_item).with('turtle-shaped sieve', toolbag, toolstrap).once
      end

      it 'stow_beside gives an empty hand (nil) to DRCC.stow_crafting_item, which returns at once, as a stow by hand did' do
        $right_hand = 'diamondique large mortar'
        inventory.stow_beside('large mortar')
        expect(DRCC).to have_received(:stow_crafting_item).with(nil, toolbag, toolstrap).once
      end

      it 'stow_vessel puts the vessel away by its name from the left hand, and nothing else' do
        $left_hand = 'diamondique large mortar'
        $right_hand = 'nemoih unguent'
        inventory.stow_vessel('large mortar')
        expect(DRCC).to have_received(:stow_crafting_item).with('diamondique large mortar', toolbag, toolstrap).once
        expect(DRCC).not_to have_received(:stow_crafting_item).with('nemoih unguent', anything, anything)
      end

      # The vessel tied on the belt in the continue form
      it 'stow_vessel falls back to the right hand when neither hand shows the vessel, as the finish always stowed' do
        $left_hand = 'nemoih unguent'
        $right_hand = 'rounded pestle'
        inventory.stow_vessel('large mortar')
        expect(DRCC).to have_received(:stow_crafting_item).with('rounded pestle', toolbag, toolstrap).once
        expect(DRCC).not_to have_received(:stow_crafting_item).with('nemoih unguent', anything, anything)
      end

      context 'with no alchemy_belt' do
        let(:toolstrap) { nil }

        it 'stow_held gives the full name and no belt, so the tool goes back in the crafting container' do
          $left_hand = 'rounded pestle'
          inventory.stow_held('pestle')
          expect(DRCC).to have_received(:stow_crafting_item).with('rounded pestle', toolbag, nil)
        end
      end
    end

    describe 'the guarded gets (layer 09)' do
      before do
        allow(DRC).to receive(:beep)
        allow(DRC).to receive(:message) { |text| messages << text }
      end

      it 'gets a tool with skip_exit and answers from the hands, by the last word of its name' do
        allow(DRCI).to receive(:in_hands?).with('pestle').and_return(true)
        expect(inventory.fetch?('rounded pestle')).to be(true)
        expect(DRCC).to have_received(:get_crafting_item).with('rounded pestle', toolbag, bag_items, toolstrap, true)
      end

      it 'answers false when the hands do not hold it, whatever DRCC returned' do
        allow(DRCI).to receive(:in_hands?).and_return(false)
        expect(inventory.fetch?('rounded pestle')).to be(false)
      end

      it 'answers true when the hands hold it, even when DRCC returned nil, as lich-5 v5.20.0 to v5.22.0 do on success' do
        allow(DRCC).to receive(:get_crafting_item).and_return(nil)
        allow(DRCI).to receive(:in_hands?).with('ingot').and_return(true)
        expect(inventory.fetch?('pewter ingot')).to be(true)
      end

      it 'gets herb2 from the crafting container with skip_exit when it holds some' do
        allow(DRCI).to receive(:exists?).with('na', toolbag).and_return(true)
        allow(DRCI).to receive(:in_hands?).and_return(true)
        inventory.fetch?('na')
        expect(DRCC).to have_received(:get_crafting_item).with('na', toolbag, ['na'], toolstrap, true)
      end

      it 'picks the vessel up from the ground with skip_exit' do
        allow(DRCI).to receive(:in_hands?).and_return(true)
        inventory.fetch?('large mortar', at_feet: true)
        expect(DRCC).to have_received(:get_crafting_item).with('large mortar', toolbag, nil, toolstrap, true)
      end

      it 'stops with a beep and "Remedy: could not get <name>. Stopping." when the item is not in hand' do
        allow(DRCI).to receive(:in_hands?).and_return(false)
        expect { inventory.fetch!('turtle-shaped sieve') }.to raise_error(SystemExit)
        expect(DRC).to have_received(:beep).once
        expect(messages).to eq(['Remedy: could not get turtle-shaped sieve. Stopping.'])
      end

      it 'returns true and says nothing when the item is in hand' do
        allow(DRCI).to receive(:in_hands?).and_return(true)
        expect(inventory.fetch!('turtle-shaped sieve')).to be(true)
        expect(messages).to be_empty
      end

      it 'looks at the hands once and waits no time when the get brought the item' do
        allow(DRCI).to receive(:in_hands?).and_return(true)
        inventory.fetch?('turtle-shaped sieve')
        expect(DRCI).to have_received(:in_hands?).once
        expect(game.clock).to eq(0)
      end

      # The late reply is code-derived: no get in the logs timed out. lich-5
      # says a get reply after DRC.bput's 15 s "may still deliver it"
      # (480bdee3 common-crafting.rb:430-432); v5.21.0 and v5.22.0 return nil
      # on that timeout (:339-363, no branch matches '').
      [nil, false].each do |timed_out|
        it "carries on with no stop when the item reaches a hand 3 s after a get that returned #{timed_out.inspect}" do
          allow(DRCC).to receive(:get_crafting_item).and_return(timed_out)
          allow(DRCI).to receive(:in_hands?) { game.clock >= 3 }
          got = nil
          expect { got = inventory.fetch!('pewter ingot') }.not_to raise_error
          expect(got).to be(true)
          expect(game.clock).to eq(3)
          expect(DRCC).to have_received(:get_crafting_item).once
          expect(messages).to be_empty
        end
      end

      it 'stops only after looking a second apart for 15 s, the bput wait, without getting again' do
        allow(DRCI).to receive(:in_hands?).and_return(false)
        expect { inventory.fetch!('pewter ingot') }.to raise_error(SystemExit)
        expect(Remedy::Inventory::LATE_GET_LOOKS).to eq(15)
        expect(game.clock).to eq(15)
        expect(DRCI).to have_received(:in_hands?).exactly(16).times
        expect(DRCC).to have_received(:get_crafting_item).once
        expect(game.sent).to be_empty
        expect(messages).to eq(['Remedy: could not get pewter ingot. Stopping.'])
      end

      it 'still finds an item that reaches a hand on the last look, at 15 s' do
        allow(DRCI).to receive(:in_hands?) { game.clock >= 15 }
        expect(inventory.fetch?('pewter ingot')).to be(true)
      end

      it 'finds the remed book by its noun: the book the logs got by that name is "a jadeleaf-bound book of master remedies instructions" (26:5825 -> 26:5832)' do
        $left_hand = 'jadeleaf-bound book of master remedies instructions'
        allow(DRCI).to receive(:in_hands?) { |item| ReplayCommons.held?(item) }
        expect(inventory.held?(Remedy::REMED_BOOK)).to be(true)
        # The whole name misses it: "remed" comes after "book" (lich-5 DRCI.in_hands? short_regex).
        expect(ReplayCommons.held?(Remedy::REMED_BOOK)).to be(false)
      end

      it 'finds a tool by its noun under the longer name the game gives it (26:5908)' do
        $right_hand = 'luminescent starshine mixing stick etched with stars'
        allow(DRCI).to receive(:in_hands?) { |item| ReplayCommons.held?(item) }
        expect(inventory.held?('mixing stick')).to be(true)
        expect(inventory.held?('rounded pestle')).to be(false)
      end

      ReplayCommons::LICH5_RELEASES.each do |release|
        context "with the lich-5 #{release} get" do
          let(:commons) { ReplayCommons.new(lich5: release, inventory: { 'rounded pestle' => 'grass toolstrap' }) }

          before { commons.install(self) }

          it 'gets an item it has, and says so' do
            got = nil
            expect { got = inventory.fetch?('rounded pestle') }.not_to raise_error
            expect(got).to be(true)
            expect($right_hand).to eq('rounded pestle')
          end

          it 'answers false for an item it lacks, never stopping inside DRCC' do
            got = nil
            expect { got = inventory.fetch?('pewter ingot') }.not_to raise_error
            expect(got).to be(false)
            expect(commons.messages).to eq(['DRCC: You seem to be missing: pewter ingot'])
          end

          it 'stops with its own line for an item it lacks' do
            expect { inventory.fetch!('pewter ingot') }.to raise_error(SystemExit)
            expect(messages).to eq(['Remedy: could not get pewter ingot. Stopping.'])
            expect(commons.messages).not_to include(ReplayCommons::STOP_MESSAGE)
          end
        end
      end
    end
  end
end

# Layer 05: the crafting loop, the Flag handlers, the liquids,
# the herb gathering, the finish and the magic, tested as units. The
# commands are the ones the contract groups above pin from the logs; every
# game line is a real log cite, or a ReplayGame.code line naming the code it
# was taken from.
RSpec.describe 'Remedy craft loop, liquids, herbs and finishing' do
  let(:toolbag) { "botanist's toolbag" }
  let(:toolstrap) { { 'name' => 'grass toolstrap', 'items' => ['heavy cauldron', 'mixing stick', 'large mortar', 'rounded pestle'] } }
  let(:bag_items) { ['alcohol', 'water', 'pewter ingot', 'remed book'] }
  let(:herb_container) { nil }
  let(:training_spells) { [] }
  let(:settings) do
    OpenStruct.new(crafting_container: toolbag, crafting_items_in_container: bag_items, alchemy_belt: toolstrap,
                   herb_container: herb_container, crafting_training_spells: training_spells)
  end
  let(:inventory) { Remedy::Inventory.new(settings, herbs: %w[nemoih na]) }
  let(:mortar) { Remedy::Tools.new(container: 'large mortar', stirrer: 'rounded pestle', verb: 'crush') }
  let(:cauldron) { Remedy::Tools.new(container: 'heavy cauldron', stirrer: 'mixing stick', verb: 'mix') }
  let(:order) do
    Remedy::Order.new(mode: :book, book_type: 'remedies', chapter: '3', recipe_name: 'some head unguent', herb1: 'nemoih',
                      herb2: 'na', catalyst: 'pewter ingot', container_request: 'mortar', noun: 'unguent')
  end
  let(:plain_water) { Remedy::Liquid.new(kind: 'water', source: 'water', verb: 'put') }
  let(:plain_alcohol) { Remedy::Liquid.new(kind: 'alcohol', source: 'alcohol', verb: 'put') }
  let(:game) { ReplayGame.new }
  # The commons calls, in order: [method, *arguments].
  let(:calls) { [] }

  before do
    game.install(self)
    allow(DRCC).to receive(:get_crafting_item) { |*args| calls << [:get, *args] && true }
    allow(DRCC).to receive(:stow_crafting_item) { |*args| calls << [:stow, *args] && true }
    allow(DRCI).to receive(:exists?).and_return(false)
    allow(DRCI).to receive(:lower_item?) { |*args| calls << [:lower, *args] && true }
    allow(DRCI).to receive(:get_item?) { |*args| calls << [:get_item?, *args] && true }
    allow(DRCI).to receive(:put_away_item?) { |*args| calls << [:put_away_item?, *args] && true }
    # Every guarded get (layer 09) finds its item in hand, as the gets here
    # always bring it.
    allow(DRCI).to receive(:in_hands?).and_return(true)
    allow(DRCA).to receive(:crafting_magic_routine)
  end

  # @param cite [String] "<log>:<line>"
  # @return [ReplayGame::Line]
  def log(cite)
    ReplayGame.log(cite)
  end

  # @param text [String]
  # @param from [String] the code line it comes from
  # @return [ReplayGame::Line]
  def code(text, from:)
    ReplayGame.code(text, from: from)
  end

  # Registers the remedy Flags, as Remedy#run does.
  #
  # @return [void]
  def add_remedy_flags
    Remedy::FLAGS.each { |name, patterns| Flags.add(name, *patterns) }
  end

  # Lets the game send lines, so the Flags see them as they arrive: the
  # reply to a `look` remedy never sends, read by a bput that waits for none
  # of them (it times out; only the Flags matter here).
  #
  # @param lines [Array<ReplayGame::Line>]
  # @return [void]
  def game_says(*lines)
    game.script('look', *lines)
    DRC.bput('look', /\A\z/)
  end

  # @param water [Remedy::Liquid]
  # @param alcohol [Remedy::Liquid]
  # @param tools [Remedy::Tools]
  # @return [Remedy::Handlers]
  def handlers_for(water: plain_water, alcohol: plain_alcohol, tools: mortar)
    Remedy::Handlers.new(order: order, tools: tools, inventory: inventory, water: water, alcohol: alcohol)
  end

  describe 'Remedy::Handlers' do
    it 'answers the same Flags as Remedy::FLAGS, in the same order: the ingredients, then the steps' do
      expect(Remedy::Handlers::TABLE.keys).to eq(Remedy::FLAGS.keys)
    end

    it 'has a private method behind every Flag of its table' do
      expect(Remedy::Handlers::TABLE.values).to all(satisfy { |name| Remedy::Handlers.private_method_defined?(name) })
    end

    it 'has nothing pending while no Flag is set' do
      add_remedy_flags
      expect(handlers_for.pending).to be_nil
    end

    it 'answers the alcohol (26:5918) before the turn (26:6031) when one reply sets both, then the turn' do
      add_remedy_flags
      game_says(log('26:6031'), log('26:5918'))
      handlers = handlers_for
      expect(handlers.pending).to eq('remedy-alcohol')
      Flags.reset('remedy-alcohol')
      expect(handlers.pending).to eq('remedy-turn')
    end

    # layer 09: the ingot and pestle gets are guarded (skip_exit, then the hands)
    it 'adds the catalyst (25:11049): puts the left hand away, gets the ingot, puts it in, then gets the pestle back' do
      add_remedy_flags
      game_says(log('25:11049'))
      $left_hand = 'rounded pestle'
      game.script('put my pewter ingot in my large mortar', log('25:11081'))
      handlers_for.run('remedy-catalyst')
      expect(game.sent.last).to eq('put my pewter ingot in my large mortar')
      expect(calls).to eq([[:stow, 'rounded pestle', toolbag, toolstrap], [:get, 'pewter ingot', toolbag, bag_items, toolstrap, true],
                           [:stow, 'rounded pestle', toolbag, toolstrap], [:get, 'rounded pestle', toolbag, bag_items, toolstrap, true]])
      expect(DRCI).to have_received(:in_hands?).with('ingot').ordered
      expect(DRCI).to have_received(:in_hands?).with('pestle').ordered
      expect(Flags['remedy-catalyst']).to be(false)
    end

    it 'adds plain water (25:50210) with "put water in", and nothing more when the game takes it (26:10830)' do
      add_remedy_flags
      game_says(log('25:50210'))
      game.script('put water in my large mortar', log('26:10830'))
      handlers_for.run('remedy-water')
      expect(game.sent.last).to eq('put water in my large mortar')
      expect(calls.map(&:first)).to eq(%i[stow get stow get])
      expect(calls[1][1]).to eq('water')
      expect(Flags['remedy-water']).to be(false)
    end

    it 'pours alcohol from its vessel (25:10873) with the vessel in hand' do
      jug = Remedy::Liquid.new(kind: 'alcohol', source: 'moonshine jug', verb: 'pour')
      game.script('pour moonshine jug in my heavy cauldron', log('25:10905'))
      handlers_for(alcohol: jug, tools: cauldron).run('remedy-alcohol')
      expect(game.sent.last).to eq('pour moonshine jug in my heavy cauldron')
      expect(calls[1][0, 2]).to eq([:get, 'moonshine jug'])
    end

    it 'pushes the product with the sieve, then gets the stirrer back' do
      game.script('push my unguent with my sieve', log('26:10933'), log('26:10935'))
      handlers_for.run('remedy-sieve')
      expect(game.sent).to eq(['push my unguent with my sieve'])
      expect(calls.select { |call| call.first == :get }.map { |call| call[1] }).to eq(['sieve', 'rounded pestle'])
    end

    it 'turns the vessel and smells the product without getting or stowing anything' do
      game.script('turn my heavy cauldron', log('26:6086'), log('26:6088'))
      game.script('smell my unguent', log('26:11034'), log('26:11036'))
      handlers = handlers_for(tools: cauldron)
      handlers.run('remedy-turn')
      handlers.run('remedy-smell')
      expect(game.sent).to eq(['turn my heavy cauldron', 'smell my unguent'])
      expect(calls).to be_empty
    end

    it "resets its Flag before it sends, so a cue in the step's own reply is kept for the next pass" do
      add_remedy_flags
      game_says(log('26:7707'))
      # 26:7707 again as the reply to the turn: an analog (it answered a
      # crush in the log), the order a repeated cue arrives in (26:6084-6088).
      game.script('turn my large mortar', log('26:7707'), log('26:10935'))
      handlers_for.run('remedy-turn')
      expect(Flags['remedy-turn']).to be_a(MatchData)
    end

    [['remedy-turn', 'turn my large mortar', '26:25113'],
     ['remedy-smell', 'smell my unguent', '26:25113'],
     ['remedy-sieve', 'push my unguent with my sieve', '26:24873']].each do |flag, command, cite|
      it "returns at once when the game refuses #{command.inspect} as not suitable (#{cite})" do
        # 26:25113 answered a turn of a cauldron; for the mortar and the
        # smell it is an analog.
        game.script(command, log(cite))
        handlers_for.run(flag)
        expect(game.sent).to eq([command])
        expect([game.clock, game.diagnostics]).to eq([0, []])
      end
    end

    it 'returns at once from a push refused with the catalyst cue alone (26:39150-39152), the catalyst Flag set and the stirrer back' do
      add_remedy_flags
      game.script('push my unguent with my sieve', log('26:39150'), log('26:39152'))
      handlers = handlers_for
      handlers.run('remedy-sieve')
      expect([game.clock, game.diagnostics]).to eq([0, []])
      expect(handlers.pending).to eq('remedy-catalyst')
      expect(calls.select { |call| call.first == :get }.map { |call| call[1] }).to eq(['sieve', 'rounded pestle'])
    end

    describe 'guarded gets and the ingredient puts (layer 09)' do
      let(:messages) { [] }
      # code-derived (R:51 /You need another prepared herb/): in neither log.
      let(:herb_cue) { code('You need another prepared herb to continue crafting some unfinished nemoih unguent.', from: 'R:51 /You need another prepared herb/') }

      before do
        add_remedy_flags
        allow(DRC).to receive(:beep)
        allow(DRC).to receive(:message) { |text| messages << text }
      end

      # @param herb2 [String]
      # @return [Remedy::Handlers] for an order with that herb2, which the
      #   inventory routes as a herb
      def handlers_with_herb2(herb2)
        Remedy::Handlers.new(order: order.with(herb2: herb2), tools: mortar, inventory: Remedy::Inventory.new(settings, herbs: ['nemoih', herb2]),
                             water: plain_water, alcohol: plain_alcohol)
      end

      ['na', 'none', 'not used'].each do |herb2|
        it "stops at the second-herb cue (R:51) when herb2 is #{herb2.inspect}, getting and sending nothing, the Flag left set" do
          game_says(herb_cue)
          expect { handlers_with_herb2(herb2).run('remedy-herb') }.to raise_error(SystemExit)
          expect(messages).to eq(["Remedy: the game asks for a second herb, and herb2 is #{herb2.inspect}, which names none. Stopping."])
          expect(DRC).to have_received(:beep).once
          expect(calls).to be_empty
          expect(game.sent).to eq(['look'])
          expect(Flags['remedy-herb']).to be_a(MatchData)
        end
      end

      it 'adds a named second herb: a guarded get of jadice, then "put my jadice in my large mortar", then the pestle back' do
        game_says(herb_cue)
        expect { handlers_with_herb2('jadice').run('remedy-herb') }.not_to raise_error
        expect(game.sent.last).to eq('put my jadice in my large mortar')
        expect(calls).to include([:get, 'jadice', toolbag, bag_items, toolstrap, true], [:get, 'rounded pestle', toolbag, bag_items, toolstrap, true])
        expect(Flags['remedy-herb']).to be(false)
      end

      it 'stops before it resets the Flag or sends when the catalyst is not in hand after its get' do
        allow(DRCI).to receive(:in_hands?) { |item| item != 'ingot' }
        game_says(log('25:11049'))
        expect { handlers_for.run('remedy-catalyst') }.to raise_error(SystemExit)
        expect(messages).to eq(['Remedy: could not get pewter ingot. Stopping.'])
        expect(game.sent).to eq(['look'])
        expect(Flags['remedy-catalyst']).to be_a(MatchData)
      end

      it 'stops at once when the put finds no pewter ingot (26:39194), without getting the pestle back' do
        game.script('put my pewter ingot in my large mortar', log('26:39194'))
        expect { handlers_for.run('remedy-catalyst') }.to raise_error(SystemExit)
        expect(messages).to eq(['Remedy: the game found no pewter ingot to put in the large mortar. Stopping.'])
        expect([game.clock, game.diagnostics]).to eq([0, []])
        expect(calls.map { |call| call[0, 2] }).not_to include([:get, 'rounded pestle'])
      end

      it 'crafts on when the put gets no reply at all, as remedy always has' do
        game.script('put my pewter ingot in my large mortar')
        expect { handlers_for.run('remedy-catalyst') }.not_to raise_error
        expect(messages).to be_empty
        expect(calls.last).to eq([:get, 'rounded pestle', toolbag, bag_items, toolstrap, true])
      end

      it "gets a liquid's source with no guard, never asking the hands for water" do
        game.script('put water in my large mortar', log('26:10830'))
        allow(DRCI).to receive(:in_hands?) { |item| item != 'water' }
        expect { handlers_for.run('remedy-water') }.not_to raise_error
        expect(calls[1]).to eq([:get, 'water', toolbag, bag_items, toolstrap])
        expect(DRCI).not_to have_received(:in_hands?).with('water')
        expect(messages).to be_empty
      end

      it 'stops before the push when the sieve is not in hand after its get' do
        allow(DRCI).to receive(:in_hands?) { |item| item != 'sieve' }
        expect { handlers_for.run('remedy-sieve') }.to raise_error(SystemExit)
        expect(game.sent).to be_empty
        expect(messages).to eq(['Remedy: could not get sieve. Stopping.'])
      end

      it 'stops after the push when the pestle is not in hand again' do
        allow(DRCI).to receive(:in_hands?) { |item| item != 'pestle' }
        game.script('push my unguent with my sieve', log('26:10933'), log('26:10935'))
        expect { handlers_for.run('remedy-sieve') }.to raise_error(SystemExit)
        expect(game.sent).to eq(['push my unguent with my sieve'])
        expect(messages).to eq(['Remedy: could not get rounded pestle. Stopping.'])
      end
    end

    it 'refuses a Flag it has no method for' do
      expect { handlers_for.run('remedy-done') }.to raise_error(KeyError)
    end
  end

  describe 'Remedy::Liquid.find' do
    it 'puts plain water when no water_container is set, sending nothing and getting nothing' do
      water = Remedy::Liquid.find('water', nil, inventory)
      expect(water.to_h).to eq(kind: 'water', source: 'water', verb: 'put')
      expect(water).to be_plain
      expect(water.flag).to eq('remedy-water')
      expect(game.sent).to be_empty
      expect(calls).to be_empty
    end

    it 'pours from a vessel whose count gets no reply, without a rub, and stows the vessel' do
      water = Remedy::Liquid.find('water', 'glass flask', inventory)
      expect(water.to_h).to eq(kind: 'water', source: 'glass flask', verb: 'pour')
      expect(water).not_to be_plain
      expect(game.sent).to eq(['count water in my glass flask'])
      expect(calls).to eq([[:get, 'glass flask', toolbag, bag_items, toolstrap], [:stow, 'glass flask', toolbag, toolstrap]])
    end

    it 'rubs and fills a vessel the first count cannot find (25:13762), and pours from it when the second count gets no reply' do
      game.script('count alcohol in my moonshine jug', log('25:13762'))
      alcohol = Remedy::Liquid.find('alcohol', 'moonshine jug', inventory)
      expect(alcohol.verb).to eq('pour')
      expect(alcohol.flag).to eq('remedy-alcohol')
      expect(game.sent).to eq(['count alcohol in my moonshine jug', 'rub my moonshine jug', "get alcohol from #{toolbag}",
                               'put alcohol in my moonshine jug', 'count alcohol in my moonshine jug'])
    end

    # layer 10 (H07): an empty vessel is stowed by name
    it 'H07: puts plain water when both counts find nothing (25:13762), and stows the flask by name' do
      2.times { game.script('count water in my glass flask', log('25:13762')) }
      water = Remedy::Liquid.find('water', 'glass flask', inventory)
      expect(water.to_h).to eq(kind: 'water', source: 'water', verb: 'put')
      expect(water).to be_plain
      expect(calls).to eq([[:get, 'glass flask', toolbag, bag_items, toolstrap], [:stow, 'glass flask', toolbag, toolstrap]])
    end

    it 'stows the vessel by name after a refill the second count finds, and pours from it' do
      game.script('count alcohol in my moonshine jug', log('25:13762'))
      alcohol = Remedy::Liquid.find('alcohol', 'moonshine jug', inventory)
      expect(alcohol.to_h).to eq(kind: 'alcohol', source: 'moonshine jug', verb: 'pour')
      expect(calls.last).to eq([:stow, 'moonshine jug', toolbag, toolstrap])
    end
  end

  describe 'Remedy::Liquid#add' do
    let(:flask) { Remedy::Liquid.new(kind: 'water', source: 'glass flask', verb: 'pour') }
    # code-derived: the refusal remedy.lic:313 at 03f11b54 reads; in no log.
    let(:refusal) { code('You cannot find a way to add that as an ingredient.', from: 'R:313') }

    it 'pours from the vessel and does nothing more when the game takes it (26:10830)' do
      game.script('pour glass flask in my large mortar', log('26:10830'))
      flask.add('large mortar', inventory)
      expect(game.sent).to eq(['pour glass flask in my large mortar'])
      expect(calls).to be_empty
    end

    it 'gets the water out of the vessel and puts it in by name when the vessel is refused' do
      game.script('pour glass flask in my large mortar', refusal)
      flask.add('large mortar', inventory)
      expect(calls).to eq([[:stow, nil, toolbag, toolstrap], [:get_item?, 'water', 'glass flask'], [:put_away_item?, 'water', 'large mortar']])
    end

    it 'puts the water back in the vessel when the crafting vessel will not take it either' do
      game.script('pour glass flask in my large mortar', refusal)
      allow(DRCI).to receive(:put_away_item?) { |*args| calls << [:put_away_item?, *args] && args.last == 'glass flask' }
      flask.add('large mortar', inventory)
      expect(calls.last(2)).to eq([[:put_away_item?, 'water', 'large mortar'], [:put_away_item?, 'water', 'glass flask']])
    end

    it 'gets plain water from the crafting container when the vessel has none to give' do
      game.script('pour glass flask in my large mortar', refusal)
      allow(DRCI).to receive(:get_item?) { |*args| calls << [:get_item?, *args] && false }
      flask.add('large mortar', inventory)
      expect(calls[2]).to eq([:get, 'water', toolbag, bag_items, toolstrap])
    end

    # layer 10 (H18): no `get my water from my water`
    it 'H18: gets refused plain water straight from the crafting container, never from "water"' do
      plain = Remedy::Liquid.new(kind: 'water', source: 'water', verb: 'put')
      game.script('put water in my large mortar', refusal)
      plain.add('large mortar', inventory)
      expect(calls).to eq([[:stow, nil, toolbag, toolstrap], [:get, 'water', toolbag, bag_items, toolstrap],
                           [:put_away_item?, 'water', 'large mortar']])
      expect(calls).not_to include([:get_item?, 'water', 'water'])
    end

    describe 'from a vessel with nothing to pour ("Pour what?", 26:22405)' do
      let(:jug) { Remedy::Liquid.new(kind: 'alcohol', source: 'moonshine jug', verb: 'pour') }
      let(:pour) { 'pour moonshine jug in my heavy cauldron' }
      let(:refill) { ['rub my moonshine jug', "get alcohol from #{toolbag}", 'put alcohol in my moonshine jug', 'count alcohol in my moonshine jug'] }
      let(:messages) { [] }

      before do
        allow(DRC).to receive(:beep)
        allow(DRC).to receive(:message) { |text| messages << text }
        game.script(pour, log('26:22405'))
        game.script('rub my moonshine jug', log('26:22410'))
      end

      it 'rubs and refills the vessel once, then pours again and goes on when the game takes it (26:7687)' do
        game.script(pour, log('26:7687'))
        jug.add('heavy cauldron', inventory)
        expect(game.sent).to eq([pour, *refill, pour])
        expect(messages).to be_empty
      end

      it 'stops, with the vessel named, when the second pour gets "Pour what?" too' do
        game.script(pour, log('26:22405'))
        expect { jug.add('heavy cauldron', inventory) }.to raise_error(SystemExit)
        expect(game.sent).to eq([pour, *refill, pour])
        expect(messages).to eq(["Remedy: the moonshine jug has no alcohol to pour, even after rubbing it and filling it from the #{toolbag}. Stopping."])
        expect(DRC).to have_received(:beep).once
      end

      it 'stops without pouring again when the count after the refill finds nothing (25:13762)' do
        game.script('count alcohol in my moonshine jug', log('25:13762'))
        expect { jug.add('heavy cauldron', inventory) }.to raise_error(SystemExit)
        expect(game.sent).to eq([pour, *refill])
        expect(messages.size).to eq(1)
      end

      it 'recovers by name when the second pour is refused, as after a first refusal' do
        game.script(pour, refusal)
        jug.add('heavy cauldron', inventory)
        expect(calls).to eq([[:stow, nil, toolbag, toolstrap], [:get_item?, 'alcohol', 'moonshine jug'], [:put_away_item?, 'alcohol', 'heavy cauldron']])
        expect(messages).to be_empty
      end
    end

    it 'never refills the plain liquid, which is put, not poured, even on a "Pour what?" reply' do
      plain = Remedy::Liquid.new(kind: 'alcohol', source: 'alcohol', verb: 'put')
      game.script('put alcohol in my large mortar', log('26:22405')) # analog: the jug pour's reply (26:22403)
      plain.add('large mortar', inventory)
      expect(game.sent).to eq(['put alcohol in my large mortar'])
      expect(calls).to be_empty
    end
  end

  describe 'Remedy::CraftLoop' do
    let(:magic) { Remedy::Magic.new(settings) }
    let(:first_crush) { 'crush my nemoih with my rounded pestle' }
    let(:next_crush) { 'crush my unguent with my rounded pestle' }

    # @param tools [Remedy::Tools]
    # @return [Remedy::CraftLoop]
    def craft_loop(tools: mortar)
      Remedy::CraftLoop.new(tools: tools, noun: 'unguent', handlers: handlers_for(tools: tools), magic: magic)
    end

    it 'gives up after 100 crafting commands, or after more than 3 unanswered in a row' do
      expect([Remedy::CraftLoop::MAX_CRAFT_STEPS, Remedy::CraftLoop::MAX_SILENT_REPLIES]).to eq([100, 3])
    end

    it 'crushes the herb, then the product after Roundtime (25:10825), until the final touches (26:11333)' do
      game.script(first_crush, log('26:11057'), log('25:10825'))
      game.script(next_crush, log('26:11333'))
      expect(craft_loop.run(first_crush)).to eq(:done)
      expect(game.sent).to eq([first_crush, next_crush])
    end

    it 'runs the magic routine once at the start of every pass' do
      game.script(first_crush, log('26:11057'), log('25:10825'))
      game.script(next_crush, log('26:11333'))
      craft_loop.run(first_crush)
      expect(DRCA).to have_received(:crafting_magic_routine).with(settings).twice
    end

    it 'runs the magic routine for a handler pass too, before the handler sends' do
      add_remedy_flags
      routine_calls = []
      allow(DRCA).to receive(:crafting_magic_routine) { routine_calls << game.sent.dup }
      # 26:7707 after the crush's Roundtime: the order of 26:7705-7707.
      game.script(first_crush, log('26:11057'), log('25:10825'), log('26:7707'))
      game.script('turn my large mortar', log('26:6086'), log('26:6088'))
      game.script(next_crush, log('26:11333'))
      craft_loop.run(first_crush)
      expect(routine_calls).to eq([[], [first_crush], [first_crush, 'turn my large mortar']])
    end

    [['25:11264', 'crush my unguent with my rounded pestle'],
     ['26:6773', 'mix my heavy cauldron with my mixing stick'],
     ['25:58002', 'mix my heavy cauldron with my mixing stick']].each do |cite, command|
      it "is done when #{command.inspect} is answered by #{cite}, a line that follows a finished remedy" do
        tools = command.start_with?('mix') ? cauldron : mortar
        game.script(command, log(cite))
        expect(craft_loop(tools: tools).run(command)).to eq(:done)
        expect(game.sent).to eq([command])
      end
    end

    # layer 08 (D08): MORE_PIECES is a refusal, not a finished remedy
    it 'ends as :more_pieces on "requires more pieces of that plant", after that one command' do
      game.script(first_crush, code('That craftable requires more pieces of that plant to begin.', from: 'R:290'))
      expect(craft_loop.run(first_crush)).to eq(:more_pieces)
      expect(game.sent).to eq([first_crush])
    end

    it 'ends as :unsuitable_herb on "You need a more suitable type of herb" (25:50933), after that one command' do
      game.script(first_crush, log('25:50933'))
      loop_under_test = craft_loop
      expect(loop_under_test.run(first_crush)).to eq(:unsuitable_herb)
      expect(game.sent).to eq([first_crush])
      expect(loop_under_test.command).to eq(first_crush)
      expect(game.clock).to eq(0)
    end

    it 'ends as :unsuitable_herb when the refusal answers a later crush, naming that crush' do
      game.script(first_crush, log('25:10825'))
      game.script(next_crush, log('25:50933')) # analog: the refusal answered a first crush (25:50932)
      loop_under_test = craft_loop
      expect(loop_under_test.run(first_crush)).to eq(:unsuitable_herb)
      expect(loop_under_test.command).to eq(next_crush)
    end

    context 'when the instructions fade (25:37919)' do
      before { Remedy::REGISTERED_FLAGS.each { |name, patterns| Flags.add(name, *patterns) } }

      it 'ends as :faded, sending nothing, after a study when the fade came before the first command' do
        game.unprompted(log('25:37919'))
        expect(craft_loop.run(first_crush, studied: true)).to eq(:faded)
        expect(game.sent).to be_empty
      end

      # layer 12: what the cleanup reads to print the ;remedy continue line
      describe '#resumable?' do
        it 'is false before the loop runs' do
          expect(craft_loop.resumable?).to be(false)
        end

        it 'is false when the remedy is done (26:11333)' do
          loop_run = craft_loop
          game.script(first_crush, log('26:11057'), log('25:10825'))
          game.script(next_crush, log('26:11333'))
          loop_run.run(first_crush, studied: true)
          expect(loop_run.resumable?).to be(false)
        end

        it 'is false when the game refused the herb (25:50933) before crafting began' do
          loop_run = craft_loop
          game.script(first_crush, log('25:50933'))
          expect(loop_run.run(first_crush, studied: true)).to eq(:unsuitable_herb)
          expect(loop_run.resumable?).to be(false)
        end

        it 'is false when the first command of a studied run is never answered (crafting never began)' do
          loop_run = craft_loop
          expect(loop_run.run(first_crush, studied: true)).to eq(:unanswered)
          expect(loop_run.resumable?).to be(false)
        end

        it 'is true when the game stops answering after a Roundtime (25:10825)' do
          loop_run = craft_loop
          game.script(first_crush, log('26:11057'), log('25:10825'))
          expect(loop_run.run(first_crush, studied: true)).to eq(:unanswered)
          expect(loop_run.resumable?).to be(true)
        end

        it 'is true in the continue form, which resumes a remedy already begun, when the analysis is never answered' do
          loop_run = craft_loop
          expect(loop_run.run('analyze my unguent')).to eq(:unanswered)
          expect(loop_run.resumable?).to be(true)
        end

        it 'is false in the continue form when the analysis is refused (25:50933)' do
          loop_run = craft_loop
          game.script('analyze my unguent', log('25:50933'))
          expect(loop_run.run('analyze my unguent')).to eq(:unsuitable_herb)
          expect(loop_run.resumable?).to be(false)
        end

        it 'is true when a handler stops the script mid-run, which leaves no outcome' do
          add_remedy_flags
          loop_run = craft_loop
          allow(DRC).to receive(:beep)
          allow(DRC).to receive(:message)
          # The catalyst cue after the crush's Roundtime (26:6313's order),
          # then the catalyst's get leaves nothing in hand.
          game.script(first_crush, log('26:11057'), log('25:10825'), log('26:39150'))
          allow(DRCI).to receive(:in_hands?).with('ingot').and_return(false)
          expect { loop_run.run(first_crush, studied: true) }.to raise_error(SystemExit)
          expect(loop_run.resumable?).to be(true)
        end
      end

      it 'ignores the fade when nothing was studied for this run (the continue form)' do
        game.unprompted(log('25:37919'))
        game.script(first_crush, log('26:11333'))
        expect(craft_loop.run(first_crush)).to eq(:done)
        expect(game.sent).to eq([first_crush])
      end

      it 'crafts on when the fade comes after a crafting command drew Roundtime (25:10825)' do
        game.script(first_crush, log('26:11057'), log('25:10825'), log('25:37919'))
        game.script(next_crush, log('26:11333'))
        expect(craft_loop.run(first_crush, studied: true)).to eq(:done)
        expect(game.sent).to eq([first_crush, next_crush])
      end

      it 'crafts on when the fade comes with a cue for the unfinished remedy (26:39150), which it answers first' do
        # The crush refused with the catalyst cue alone (26:39150-39152,
        # analog: the reply to a push), then the fade.
        game.script(first_crush, log('26:39150'), log('26:39152'), log('25:37919'))
        game.script('put my pewter ingot in my large mortar', log('26:11117'))
        game.script(first_crush, log('26:11333'))
        expect(craft_loop.run(first_crush, studied: true)).to eq(:done)
        expect(game.sent).to eq([first_crush, 'put my pewter ingot in my large mortar', first_crush])
      end

      it 'ends as :faded before a resend when the fade came during an unanswered first command' do
        game.script(first_crush, log('25:37919'))
        expect(craft_loop.run(first_crush, studied: true)).to eq(:faded)
        expect(game.sent).to eq([first_crush])
      end
    end

    it 'sends the same command again when the game does not answer it' do
      game.script(first_crush)
      game.script(first_crush, log('26:11333'))
      expect(craft_loop.run(first_crush)).to eq(:done)
      expect(game.sent).to eq([first_crush, first_crush])
      expect(game.diagnostics.size).to eq(1)
    end

    it 'answers a cue that came with a reply before it sends the next crafting command (26:7707 then a turn)' do
      add_remedy_flags
      # 26:7707 after the crush's Roundtime: the order of 26:7705-7707.
      game.script(first_crush, log('26:11057'), log('25:10825'), log('26:7707'))
      game.script('turn my large mortar', log('26:6086'), log('26:6088'))
      game.script(next_crush, log('26:11333'))
      expect(craft_loop.run(first_crush)).to eq(:done)
      expect(game.sent).to eq([first_crush, 'turn my large mortar', next_crush])
    end

    it 'gives up as :unanswered on the fourth unanswered send of a command, naming that command' do
      loop_under_test = craft_loop
      expect(loop_under_test.run(first_crush)).to eq(:unanswered)
      expect(game.sent).to eq([first_crush] * 4)
      expect(game.clock).to eq(60)
      expect(loop_under_test.command).to eq(first_crush)
    end

    it 'keeps going through three unanswered sends of a command when the fourth is answered' do
      3.times { game.script(first_crush) }
      game.script(first_crush, log('26:11333'))
      expect(craft_loop.run(first_crush)).to eq(:done)
      expect(game.sent).to eq([first_crush] * 4)
      expect(game.diagnostics.size).to eq(3)
    end

    it 'names the product command as the one unanswered when silence follows a Roundtime' do
      game.script(first_crush, log('25:10825'))
      loop_under_test = craft_loop
      expect(loop_under_test.run(first_crush)).to eq(:unanswered)
      expect(game.sent).to eq([first_crush] + ([next_crush] * 4))
      expect(loop_under_test.command).to eq(next_crush)
    end

    it 'does not count a reply that brings only a cue as silence: the step is handled and the silence counted afresh' do
      add_remedy_flags
      3.times { game.script(first_crush) }
      # The crush refused with the catalyst cue alone (26:39150-39152,
      # analog: the reply to a push), which no crafting pattern matches.
      game.script(first_crush, log('26:39150'), log('26:39152'))
      game.script('put my pewter ingot in my large mortar', log('26:11117'))
      3.times { game.script(first_crush) }
      game.script(first_crush, log('26:11333'))
      expect(craft_loop.run(first_crush)).to eq(:done)
      expect(game.sent).to eq(([first_crush] * 4) + ['put my pewter ingot in my large mortar'] + ([first_crush] * 4))
      expect(game.diagnostics.size).to eq(7)
    end

    it 'tolerates three unanswered sends of each command in turn, with a handled step between them' do
      add_remedy_flags
      3.times { game.script(first_crush) }
      game.script(first_crush, log('26:11057'), log('25:10825'), log('26:7707'))
      game.script('turn my large mortar', log('26:6086'), log('26:6088'))
      3.times { game.script(next_crush) }
      game.script(next_crush, log('26:11333'))
      expect(craft_loop.run(first_crush)).to eq(:done)
      expect(game.sent).to eq(([first_crush] * 4) + ['turn my large mortar'] + ([next_crush] * 4))
    end

    it 'counts silence afresh after a Roundtime, so one answered command between silences keeps it going' do
      stub_const('Remedy::CraftLoop::MAX_SILENT_REPLIES', 1)
      game.script(first_crush)
      game.script(first_crush, log('25:10825'))
      game.script(next_crush)
      game.script(next_crush, log('26:11333'))
      expect(craft_loop.run(first_crush)).to eq(:done)
    end

    it 'gives up as :too_long after MAX_CRAFT_STEPS crafting commands, not counting the handled cues' do
      stub_const('Remedy::CraftLoop::MAX_CRAFT_STEPS', 3)
      add_remedy_flags
      game.script(first_crush, log('25:10825'), log('26:7707'))
      game.script('turn my large mortar', log('26:6088'))
      game.fallback(next_crush, log('25:10825'))
      expect(craft_loop.run(first_crush)).to eq(:too_long)
      expect(game.sent).to eq([first_crush, 'turn my large mortar', next_crush, next_crush])
    end

    it 'counts the unanswered resends as crafting commands towards MAX_CRAFT_STEPS' do
      stub_const('Remedy::CraftLoop::MAX_CRAFT_STEPS', 3)
      2.times { game.script(first_crush) }
      expect(craft_loop.run(first_crush)).to eq(:too_long)
      expect(game.sent).to eq([first_crush] * 3)
    end

    it 'is done, not too long, when the last allowed crafting command draws the final touches (26:11333)' do
      stub_const('Remedy::CraftLoop::MAX_CRAFT_STEPS', 2)
      game.script(first_crush, log('25:10825'))
      game.script(next_crush, log('26:11333'))
      expect(craft_loop.run(first_crush)).to eq(:done)
    end
  end

  describe 'Remedy::HerbGatherer' do
    let(:herb_container) { 'smokewood basket' }
    let(:basket) { 'smokewood basket' }
    let(:commons) { ReplayCommons.new(game: game, inventory: { 'large mortar' => 'grass toolstrap', 'dried nemoih' => basket }) }
    let(:gatherer) { Remedy::HerbGatherer.new(inventory) }
    let(:messages) { [] }
    let(:put) { 'put nemoih in my large mortar' }

    # The hands and the commons are ReplayCommons' model, so each check of
    # the hands reads what the gets and stows did.
    before do
      commons.install(self)
      allow(DRC).to receive(:beep)
      allow(DRC).to receive(:message) { |text| messages << text }
    end

    # Scripts the herb put (26:10749); the game takes the stack in hand.
    #
    # @return [void]
    def script_put
      game.script(put, log('26:10749'), after: ->(_game) { commons.release('nemoih') })
    end

    # Scripts a second stack in a bag: the first count, the combine with
    # one stack in hand (25:104590), the second count and the combine.
    #
    # @param first [String] the cite of the first count
    # @param second [String] the cite of the second count
    # @param combine [ReplayGame::Line] the reply to the second combine
    # @param bag [String] where the second stack is
    # @return [void]
    def script_two_stacks(first:, second:, combine:, bag: basket)
      commons.inventory << ReplayCommons::Item.new('dried nemoih', bag)
      game.script('count my nemoih', log(first))
      game.script('combine my nemoih', log('25:104590'))
      game.script('count my nemoih', log(second))
      game.script('combine my nemoih', combine)
    end

    # @return [Array<Array>] the DRCC.stow_crafting_item calls, as [name, bag]
    def stows
      commons.calls.select { |call| call.first == 'DRCC.stow_crafting_item' }.map { |call| call[1, 2] }
    end

    it 'gathers a stack of 25 from the herb_container (25:33679), puts it in the lowered mortar and picks the mortar up' do
      game.script('count my nemoih', log('25:33679'))
      game.script('combine my nemoih', log('25:104590'))
      script_put
      gatherer.gather('nemoih', 'large mortar')
      expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', put])
      expect(commons.moves).to eq(['large mortar: grass toolstrap -> hand', 'large mortar: hand -> ground',
                                   "dried nemoih: #{basket} -> hand", 'dried nemoih: hand -> game', 'large mortar: ground -> hand'])
      expect(stows).to eq([['nemoih', basket]])
      expect(messages).to be_empty
    end

    # As remedy always has (CURRENT H27, kept on purpose): the
    # stack beside the 75 goes to DRCI.put_away_item? with no container,
    # which sends `stow my first nemoih`, even with herb_container set.
    # ReplayCommons finds no item by its place in hand ("first nemoih"), so
    # the put-back moves nothing here; the leftover stow after the put then
    # puts the other stack away.
    it 'gets another stack after 21 (25:12538), and puts the first back with the plain stow when the second counts 75 (25:8678) after too large a combine (25:30006)' do
      script_two_stacks(first: '25:12538', second: '25:8678', combine: log('25:30006'))
      game.script('count my first nemoih', log('25:12538'))
      game.script('count my second nemoih', log('25:8678'))
      script_put
      gatherer.gather('nemoih', 'large mortar')
      expect(game.sent.last(3)).to eq(['count my first nemoih', 'count my second nemoih', put])
      expect(commons.calls).to include(['DRCI.put_away_item?', 'first nemoih', nil])
      expect(stows.map(&:first)).not_to include('first nemoih')
      expect(messages).to be_empty
    end

    it 'puts the second stack back with the plain stow when the first counts 75 (25:8678, then 21, 25:12538)' do
      script_two_stacks(first: '25:12538', second: '25:8678', combine: log('25:30006'))
      game.script('count my first nemoih', log('25:8678'))
      game.script('count my second nemoih', log('25:12538'))
      script_put
      gatherer.gather('nemoih', 'large mortar')
      expect(commons.calls).to include(['DRCI.put_away_item?', 'second nemoih', nil])
      expect(commons.calls).not_to include(['DRCI.put_away_item?', 'first nemoih', nil])
    end

    # As remedy always has: the rule is the first count of 75, whatever the
    # second count says (here "I could not find what you were referring
    # to.", 25:13762).
    it 'puts the second stack back when the first counts 75 (25:8678) even when the second count finds none (25:13762)' do
      script_two_stacks(first: '25:12538', second: '25:8678', combine: log('25:30006'))
      game.script('count my first nemoih', log('25:8678'))
      game.script('count my second nemoih', log('25:13762'))
      script_put
      gatherer.gather('nemoih', 'large mortar')
      expect(game.sent.last(3)).to eq(['count my first nemoih', 'count my second nemoih', put])
      expect(commons.calls).to include(['DRCI.put_away_item?', 'second nemoih', nil])
      expect(messages).to be_empty
    end

    # As remedy always has: with neither stack at 75 the
    # put-back is not tried, and the count so far (21 + 75 = 96) ends the
    # gathering. The ordinal counts are 21 (25:12538) and 10 (25:104726).
    it 'puts no stack back after too large a combine (25:30006) when neither stack counts 75' do
      script_two_stacks(first: '25:12538', second: '25:8678', combine: log('25:30006'))
      game.script('count my first nemoih', log('25:12538'))
      game.script('count my second nemoih', log('25:104726'))
      script_put
      expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
      expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', 'count my nemoih', 'combine my nemoih',
                               'count my first nemoih', 'count my second nemoih', put])
      expect(stows.map(&:first)).to eq(['nemoih'])
      expect(commons.calls.map(&:first)).not_to include('DRCI.put_away_item?')
    end

    context 'with no herb_container' do
      let(:herb_container) { nil }
      let(:commons) { ReplayCommons.new(game: game, inventory: { 'large mortar' => 'grass toolstrap', 'dried nemoih' => toolbag }) }

      # The contract's 21 + 75 ('tops up a stack of 21 ...'): remedy has
      # always put the stack beside the 75 back with DRCI.put_away_item? and
      # no container, which sends `stow my first nemoih` (lich-5
      # common-items.rb put_away_item_unsafe?), not a put into the toolbag.
      it 'puts the first stack back with the plain stow remedy has always sent when the second counts 75 (25:12538, 25:8678, 25:30006)' do
        script_two_stacks(first: '25:12538', second: '25:8678', combine: log('25:30006'), bag: toolbag)
        game.script('count my first nemoih', log('25:12538'))
        game.script('count my second nemoih', log('25:8678'))
        script_put
        expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
        expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', 'count my nemoih', 'combine my nemoih',
                                 'count my first nemoih', 'count my second nemoih', put])
        expect(commons.calls).to include(['DRCI.put_away_item?', 'first nemoih', nil])
        expect(stows.map(&:first)).not_to include('first nemoih')
      end
    end

    # @param pieces [Integer] the pieces of the merged stack
    # @return [ReplayGame::Line] 25:104726 with the number changed
    def merged_stack_count(pieces)
      code("You count out #{pieces} pieces of material there.", from: '25:104726, count changed to the merged stack')
    end

    # H05 (a deliberate change): today
    # the 21 + 21 = 42 summed was sent with no count after the merge. One
    # more count reads the merged stack and is the count that ends the
    # gathering.
    it 'counts the merged stack once after a merge in the bags (21 and 21, 25:12538, then the merged 42)' do
      script_two_stacks(first: '25:12538', second: '25:12538', combine: log('25:11425'))
      game.script('count my nemoih', merged_stack_count(42))
      script_put
      expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
      expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', 'count my nemoih', 'combine my nemoih', 'count my nemoih', put])
      expect(messages).to be_empty
    end

    # H05 under its assumption: the count with two stacks in hand
    # reads the stack picked up first. Stacks of 10 (25:104726), 2 and 21:
    # the second count reads the 10 again, the merge holds 12, and the count
    # before the third merge reads that 12. Today's sums (20, then 32)
    # counted the 10 twice; the counts after the merges (12, then 33) are
    # what is held.
    it 'goes by the count of each merged stack, not the sum, and gets another stack when it is short (10, 10 again, merged 12, 12 again, merged 33)' do
      allow(DRCI).to receive(:exists?).and_return(true)
      script_two_stacks(first: '25:104726', second: '25:104726', combine: log('25:11425'))
      game.script('count my nemoih', merged_stack_count(12))
      game.script('count my nemoih', merged_stack_count(12))
      game.script('combine my nemoih', log('25:11425'))
      game.script('count my nemoih', merged_stack_count(33))
      script_put
      expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
      expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', 'count my nemoih', 'combine my nemoih', 'count my nemoih',
                               'count my nemoih', 'combine my nemoih', 'count my nemoih', put])
      expect(messages).to be_empty
    end

    # As remedy always has: a round that does not merge
    # goes by the sum of every count, even after a merge set the count so
    # far. Under H05's assumption the count before the third combine reads
    # the merged 12 again (code-derived), and that combine is too large
    # (25:30006; the counts by place, 21 and 10, put nothing back). Today's
    # 10 + 10 + 12 = 32 ends the gathering, and so does this one, with
    # today's commands and the one count after the merge (H05); the merged
    # 12 + 12 = 24 would have fetched again.
    it 'goes by the sum of every count after too large a combine (25:30006) that follows a merge in the bags (25:11425), as today (10, 10, merged 12, 12 again)' do
      allow(DRCI).to receive(:exists?).and_return(true)
      script_two_stacks(first: '25:104726', second: '25:104726', combine: log('25:11425'))
      game.script('count my nemoih', merged_stack_count(12))
      game.script('count my nemoih', merged_stack_count(12))
      game.script('combine my nemoih', log('25:30006'))
      game.script('count my first nemoih', log('25:12538'))
      game.script('count my second nemoih', log('25:104726'))
      script_put
      expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
      expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', 'count my nemoih', 'combine my nemoih', 'count my nemoih',
                               'count my nemoih', 'combine my nemoih', 'count my first nemoih', 'count my second nemoih', put])
      expect(messages).to be_empty
    end

    # Whichever stack the count before the merge read, 25 (25:33679) is a
    # handful by itself, so the gathering ends with today's commands.
    it 'sends no count after the merge when the count before it reads a handful by itself (10, 25:104726, then 25, 25:33679)' do
      script_two_stacks(first: '25:104726', second: '25:33679', combine: log('25:11425'))
      script_put
      expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
      expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', 'count my nemoih', 'combine my nemoih', put])
      expect(messages).to be_empty
    end

    # A count after the merge that holds no number ("I could not find what
    # you were referring to.", 25:13762, analog) leaves the sum as today:
    # 21 + 10 = 31 ends the gathering.
    it 'goes by the sum, as today, when the count after the merge holds no number (21 and 10, then 25:13762)' do
      script_two_stacks(first: '25:12538', second: '25:104726', combine: log('25:11425'))
      game.script('count my nemoih', log('25:13762'))
      script_put
      expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
      expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', 'count my nemoih', 'combine my nemoih', 'count my nemoih', put])
      expect(messages).to be_empty
    end

    # The same with no reply at all (bput gives up and returns '').
    it 'goes by the sum, as today, when the count after the merge goes unanswered (21 and 10)' do
      script_two_stacks(first: '25:12538', second: '25:104726', combine: log('25:11425'))
      script_put
      expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
      expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', 'count my nemoih', 'combine my nemoih', 'count my nemoih', put])
      expect(messages).to be_empty
    end

    describe 'a herb found outside both bags' do
      let(:apron) { 'seasilk apron' }
      let(:commons) { ReplayCommons.new(game: game, inventory: { 'large mortar' => 'grass toolstrap', 'dried nemoih' => apron }) }

      # Scripts the first count and, per later get, the fput `stow my
      # nemoih` (not read; the analog reply 25:13762, as in the contract's
      # 'tops up a stack of 21 found outside both bags'), the combine and
      # the count after it. Each later stack waits in the apron.
      #
      # @param first [ReplayGame::Line] the reply to the first count
      # @param rounds [Array<Array(ReplayGame::Line, ReplayGame::Line)>] the
      #   combine's and the count's replies of each later get
      # @return [void]
      def script_outside(first, rounds)
        game.script('count my nemoih', first)
        rounds.each do |combine, count|
          commons.inventory << ReplayCommons::Item.new('dried nemoih', apron)
          game.script('stow my nemoih', log('25:13762'))
          game.script('combine my nemoih', combine, after: ->(_game) { combine.text.start_with?('You combine') && commons.release('nemoih') })
          game.script('count my nemoih', count)
        end
      end

      # @param pieces [Integer] the pieces of the merged stack
      # @return [ReplayGame::Line] 25:104726 with the number changed
      def merged_count(pieces)
        code("You count out #{pieces} pieces of material there.", from: '25:104726, count changed to the merged stack')
      end

      # layer 11: today the 10 + 20 = 30 counted ends the gathering with 20
      # in hand. The count after a merge reads the one merged stack.
      it 'goes by the count after a merge (25:11425), not the sum with the count before it, and gets another stack (10, 20, 30)' do
        script_outside(log('25:104726'), [[log('25:11425'), merged_count(20)], [log('25:11425'), merged_count(30)]])
        script_put
        expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
        expect(game.sent).to eq(['count my nemoih', 'stow my nemoih', 'combine my nemoih', 'count my nemoih',
                                 'stow my nemoih', 'combine my nemoih', 'count my nemoih', put])
        expect(messages).to be_empty
      end

      # As remedy always has: after "too large" the one
      # count is added (21 + 75), and the stacks are not counted by place.
      it 'adds the one count after too large a combine (25:30006) to the count so far (21, 25:12538, and 75, 25:8678), as today' do
        script_outside(log('25:12538'), [[log('25:30006'), log('25:8678')]])
        script_put
        expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
        expect(game.sent).to eq(['count my nemoih', 'stow my nemoih', 'combine my nemoih', 'count my nemoih', put])
        expect(game.sent).not_to include('count my first nemoih')
      end

      # As remedy always has: a round that does not merge
      # goes by the sum of every count, even after a merge replaced the count
      # so far. Here `count` reads the stack taken back out of the vessel
      # (code-derived: the logs do not show which of two stacks it reads),
      # the 12 the merge counted: today's 10 + 12 + 12 = 34 ends the
      # gathering, and so does this one. The merged 12 + 12 = 24 would have
      # fetched again.
      it 'goes by the sum of every count after too large a combine (25:30006) that follows a merge (25:11425), as today (10, 12, 12)' do
        script_outside(log('25:104726'), [[log('25:11425'), merged_count(12)], [log('25:30006'), merged_count(12)]])
        script_put
        expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
        expect(game.sent).to eq(['count my nemoih', 'stow my nemoih', 'combine my nemoih', 'count my nemoih',
                                 'stow my nemoih', 'combine my nemoih', 'count my nemoih', put])
        expect(messages).to be_empty
      end

      # layer 11 (H04): today "You must be holding both" set the
      # count to 25. The commands are today's.
      it 'ends at the count held when the combine finds one stack (25:18266), sending no count after it, and says so' do
        game.script('count my nemoih', log('25:12538'))
        game.script('stow my nemoih', log('25:13762'))
        game.script('combine my nemoih', log('25:18266'))
        script_put
        expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
        expect(game.sent).to eq(['count my nemoih', 'stow my nemoih', 'combine my nemoih', put])
        expect(messages).to eq(['Remedy: gathered only 21 pieces of nemoih (a remedy takes 25); crafting with what is in hand.'])
      end
    end

    it 'ends the gathering when the combine after a get finds one stack in hand (25:104590), and says how few pieces it holds' do
      allow(DRCI).to receive(:exists?).and_return(true)
      game.script('count my nemoih', log('25:12538'))
      game.script('combine my nemoih', log('25:104590'))
      game.script('count my nemoih', log('25:12538'))
      game.script('combine my nemoih', log('25:104590'))
      script_put
      gatherer.gather('nemoih', 'large mortar')
      expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', 'count my nemoih', 'combine my nemoih', put])
      expect(messages).to eq(['Remedy: gathered only 21 pieces of nemoih (a remedy takes 25); crafting with what is in hand.'])
    end

    describe 'the herb left in hand after the put' do
      # The put took part of the stack (assumption: every logged put took
      # all of it). lich-5 counts herb_container's "That stack of herbs is
      # too large to add more to." (26:32077) as stowed (F3): the model's
      # stow there leaves the herb in hand.
      #
      # @param bags [Array<String>] the containers that refuse the herb
      # @return [void]
      def refuse_the_leftover_in(*bags)
        allow(DRCC).to receive(:stow_crafting_item) do |name, bag, belt|
          (name == 'nemoih' && bags.include?(bag)) || commons.stow_crafting_item(name, bag, belt)
        end
      end

      before do
        game.script('count my nemoih', log('25:33679'))
        game.script('combine my nemoih', log('25:104590'))
        game.script(put, log('26:10749'))
      end

      it 'puts it in the crafting container when the herb_container leaves it in hand, and picks the mortar up' do
        refuse_the_leftover_in(basket)
        gatherer.gather('nemoih', 'large mortar')
        expect(DRCC).to have_received(:stow_crafting_item).with('nemoih', basket, toolstrap).once.ordered
        expect(DRCC).to have_received(:stow_crafting_item).with('nemoih', toolbag, toolstrap).once.ordered
        expect(commons.location_of('dried nemoih')).to eq(toolbag)
        expect(commons.location_of('large mortar')).to eq('right').or eq('left')
        expect(messages).to be_empty
      end

      it 'stops with a Remedy line, the mortar picked up beside the herb, when the crafting container leaves it in hand too' do
        refuse_the_leftover_in(basket, toolbag)
        expect { gatherer.gather('nemoih', 'large mortar') }.to raise_error(SystemExit)
        expect(messages).to eq(['Remedy: could not put away the nemoih left in hand after the put, and crafting needs that hand. Stopping.'])
        expect([commons.location_of('nemoih'), commons.location_of('large mortar')]).to contain_exactly('left', 'right')
      end

      context 'with no herb_container' do
        let(:herb_container) { nil }

        before { commons.inventory.find { |item| item.name == 'dried nemoih' }.location = toolbag }

        it 'stops after the one stow in the crafting container, which the herb went to first' do
          refuse_the_leftover_in(toolbag)
          expect { gatherer.gather('nemoih', 'large mortar') }.to raise_error(SystemExit)
          expect(DRCC).to have_received(:stow_crafting_item).with('nemoih', anything, anything).once
          expect(messages).to eq(['Remedy: could not put away the nemoih left in hand after the put, and crafting needs that hand. Stopping.'])
        end
      end
    end

    # Code-derived timing, as layer 09's LATE_GET_LOOKS: no get or put in
    # the logs timed out. A get or stow whose bput gave up still moves the
    # herb when its reply comes, here 3, 16 or 30 s later; today remedy's
    # next command waited behind it, so the late one came first and the run
    # went on however late it was. The gathering looks at the hands for
    # STOP_LOOKS (30 s) before it stops: with the bput's own 15 s, the three
    # silences of the lag floor.
    describe 'a herb get or stow answered late' do
      # The first `nemoih` get returns false (current lich-5 returns
      # DRCI.in_hands?, 480bdee3 common-crafting.rb:531-532) and the stack
      # reaches a hand +late+ seconds later.
      #
      # @param late [Integer] the seconds after the get's bput gave up
      # @return [void]
      def answer_the_first_herb_get_late(late = 3)
        arrives = nil
        allow(DRCC).to receive(:get_crafting_item) do |*args|
          next commons.get_crafting_item(*args) unless args.first == 'nemoih' && arrives.nil?

          arrives = game.clock + late
          false
        end
        allow(DRCI).to receive(:in_hands?) do |item|
          if arrives && game.clock >= arrives && (stack = commons.inventory.find { |owned| owned.name == 'dried nemoih' })
            commons.inventory.delete(stack)
            commons.hold(stack.name)
          end
          commons.in_hands?(item)
        end
      end

      [3, 16, 30].each do |late|
        it "gathers from the herb_container with the commands of today when the first get is answered #{late} s late (25:33679)" do
          answer_the_first_herb_get_late(late)
          game.script('count my nemoih', log('25:33679'))
          game.script('combine my nemoih', log('25:104590'))
          script_put
          expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
          expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', put])
          expect(game.clock).to be >= late
          expect(messages).to be_empty
          expect(commons.location_of('large mortar')).to eq('right').or eq('left')
        end
      end

      it 'stops, sending nothing, when the first get is answered 31 s late, after the last of its 30 s of looks' do
        answer_the_first_herb_get_late(31)
        expect { gatherer.gather('nemoih', 'large mortar') }.to raise_error(SystemExit)
        expect(game.sent).to be_empty
        expect(game.clock).to eq(Remedy::Inventory::STOP_LOOKS)
        expect(messages).to eq(['Remedy: could not get nemoih. Stopping.'])
      end

      context 'with the herb outside both bags' do
        let(:commons) { ReplayCommons.new(game: game, inventory: { 'large mortar' => 'grass toolstrap', 'dried nemoih' => 'seasilk apron' }) }

        [3, 30].each do |late|
          it "gathers with the commands of today when the first get is answered #{late} s late (25:33679)" do
            answer_the_first_herb_get_late(late)
            game.script('count my nemoih', log('25:33679'))
            script_put
            expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
            expect(game.sent).to eq(['count my nemoih', put])
            expect(messages).to be_empty
          end
        end
      end

      context 'with no herb_container, the put leaving part of the stack in hand' do
        let(:herb_container) { nil }
        let(:commons) { ReplayCommons.new(game: game, inventory: { 'large mortar' => 'grass toolstrap', 'dried nemoih' => toolbag }) }

        # The leftover stow's reply comes +late+ seconds after its bput gave
        # up: the herb leaves the hand then. Assumption: the put left part
        # of the stack in hand (in the logs every put took the whole stack).
        #
        # @param late [Integer] the seconds after the stow returned
        # @return [void]
        def answer_the_leftover_stow_late(late)
          leaves = nil
          allow(DRCC).to receive(:stow_crafting_item) do |name, bag, belt|
            next commons.stow_crafting_item(name, bag, belt) unless name == 'nemoih'

            leaves = game.clock + late
            true
          end
          allow(DRCI).to receive(:in_hands?) do |item|
            commons.release('nemoih') if leaves && game.clock >= leaves
            commons.in_hands?(item)
          end
        end

        before do
          game.script('count my nemoih', log('25:33679'))
          game.script('combine my nemoih', log('25:104590'))
          game.script(put, log('26:10749'))
        end

        [3, 16, 30].each do |late|
          it "picks the mortar up and goes on, with the one stow, when the stow of the herb left after the put is answered #{late} s late" do
            answer_the_leftover_stow_late(late)
            expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
            expect(DRCC).to have_received(:stow_crafting_item).with('nemoih', anything, anything).once
            expect(game.sent).to eq(['count my nemoih', 'combine my nemoih', put])
            expect(messages).to be_empty
            expect(commons.location_of('large mortar')).to eq('right').or eq('left')
          end
        end

        it 'stops, the mortar picked up, when the stow of the herb left after the put is answered 31 s late, after the last of its 30 s of looks' do
          answer_the_leftover_stow_late(31)
          expect { gatherer.gather('nemoih', 'large mortar') }.to raise_error(SystemExit)
          expect(DRCC).to have_received(:stow_crafting_item).with('nemoih', anything, anything).once
          expect(messages).to eq(['Remedy: could not put away the nemoih left in hand after the put, and crafting needs that hand. Stopping.'])
        end
      end

      context 'with herb_container, the put leaving part of the stack in hand' do
        # As above, with the herb_container stow answered late: the
        # crafting container is not tried while the looks last.
        it 'sends no stow to the crafting container when the herb_container stow of the herb left after the put is answered 30 s late' do
          game.script('count my nemoih', log('25:33679'))
          game.script('combine my nemoih', log('25:104590'))
          game.script(put, log('26:10749'))
          leaves = nil
          allow(DRCC).to receive(:stow_crafting_item) do |name, bag, belt|
            next commons.stow_crafting_item(name, bag, belt) unless name == 'nemoih'

            leaves = game.clock + 30
            true
          end
          allow(DRCI).to receive(:in_hands?) do |item|
            commons.release('nemoih') if leaves && game.clock >= leaves
            commons.in_hands?(item)
          end
          expect { gatherer.gather('nemoih', 'large mortar') }.not_to raise_error
          expect(DRCC).to have_received(:stow_crafting_item).with('nemoih', anything, anything).once
          expect(DRCC).to have_received(:stow_crafting_item).with('nemoih', basket, anything)
          expect(messages).to be_empty
        end
      end
    end

    context 'on lich-5 v5_21, where a missing herb does not stop the script' do
      let(:commons) { ReplayCommons.new(game: game, lich5: :v5_21, inventory: { 'large mortar' => 'grass toolstrap' }) }

      it 'stops at the first get that leaves no herb in hand, sending nothing, after 30 s of looks, with the mortar picked up again' do
        allow(DRCI).to receive(:exists?).and_return(true)
        expect { gatherer.gather('nemoih', 'large mortar') }.to raise_error(SystemExit)
        expect(game.sent).to be_empty
        expect(game.clock).to eq(Remedy::Inventory::STOP_LOOKS)
        expect(messages).to eq(['Remedy: could not get nemoih. Stopping.'])
        expect(commons.location_of('large mortar')).to eq('right')
      end
    end
  end

  describe 'Remedy::Finisher' do
    before do
      # The vessel in the right hand and the stirrer in the left, as a
      # book-form run has them; the stows empty the hand they are given.
      $right_hand = 'diamondique large mortar'
      $left_hand = 'rounded pestle'
      allow(DRCC).to receive(:stow_crafting_item) do |*args|
        calls << [:stow, *args]
        $left_hand = nil if $left_hand == args.first
        $right_hand = nil if $right_hand == args.first
        true
      end
      allow(DRCI).to receive(:in_left_hand?) { |item| ReplayCommons.matches?($left_hand, item) }
      allow(DRCI).to receive(:in_right_hand?) { |item| ReplayCommons.matches?($right_hand, item) }
      game.script('get my unguent from my large mortar', log('26:11389'), after: ->(_game) { $left_hand = 'nemoih unguent' })
    end

    it 'puts the stirrer away, takes the product out (26:11389) and puts the vessel away, with no stamp when marking is off' do
      Remedy::Finisher.new(inventory: inventory, tools: mortar, noun: 'unguent', mark: nil).finish
      expect(game.sent).to eq(['get my unguent from my large mortar'])
      expect(calls).to eq([[:stow, 'rounded pestle', toolbag, toolstrap], [:stow, 'diamondique large mortar', toolbag, toolstrap]])
      expect([$left_hand, $right_hand]).to eq(['nemoih unguent', nil])
    end

    # layer 12 (H14): with the vessel in the left hand (the continue form),
    # the stirrer in the right hand is put away first and the product never
    it 'puts the stirrer in the right hand away when the vessel is in the left, and never the product' do
      $left_hand = 'diamondique large mortar'
      $right_hand = 'rounded pestle'
      game.override('get my unguent from my large mortar', log('26:11389'), after: ->(_game) { $right_hand = 'nemoih unguent' })
      Remedy::Finisher.new(inventory: inventory, tools: mortar, noun: 'unguent', mark: nil).finish
      expect(calls).to eq([[:stow, 'rounded pestle', toolbag, toolstrap], [:stow, 'diamondique large mortar', toolbag, toolstrap]])
      expect([$left_hand, $right_hand]).to eq([nil, 'nemoih unguent'])
    end

    # The vessel tied on the belt (the continue form; the get
    # from there is 26:11389) and the stirrer in the right hand. Neither
    # hand shows the vessel, so the right hand is put away after the get,
    # as the Finisher always did, and the empty left hand before it.
    it 'puts the right hand (the stirrer) away after the get when neither hand shows the vessel' do
      $right_hand = 'rounded pestle'
      $left_hand = nil
      Remedy::Finisher.new(inventory: inventory, tools: mortar, noun: 'unguent', mark: nil).finish
      expect(game.sent).to eq(['get my unguent from my large mortar'])
      expect(calls).to eq([[:stow, nil, toolbag, toolstrap], [:stow, 'rounded pestle', toolbag, toolstrap]])
      expect([$left_hand, $right_hand]).to eq(['nemoih unguent', nil])
    end

    # layer 12 (D09, H03): the product get is checked
    context 'when the product is not in hand after its get' do
      let(:messages) { [] }

      before do
        allow(DRC).to receive(:message) { |text| messages << text }
        allow(DRC).to receive(:beep)
        allow(DRCI).to receive(:in_hands?).with('unguent').and_return(false)
      end

      it 'stops with a Remedy line, the vessel still in hand, the stirrer put away, and no mark, after looking at the hands for LATE_GET_LOOKS seconds' do
        # "What were you referring to?" (25:10857, analog: the reply to
        # `put my clubmoss in my smokewood basket`, 25:10855, with no
        # clubmoss in hand).
        game.override('get my unguent from my large mortar', log('25:10857'))
        expect { Remedy::Finisher.new(inventory: inventory, tools: mortar, noun: 'unguent', mark: true).finish }.to raise_error(SystemExit)
        expect(messages).to eq(['Remedy: the unguent is not in hand after taking it out of the large mortar. Stopping.'])
        expect(game.clock).to eq(Remedy::Inventory::LATE_GET_LOOKS)
        expect(game.sent).to eq(['get my unguent from my large mortar'])
        expect(calls).to eq([[:stow, 'rounded pestle', toolbag, toolstrap]])
        expect($right_hand).to eq('diamondique large mortar')
      end

      it 'stops the same when the game does not answer the get (fput gives up and returns false)' do
        game.override('get my unguent from my large mortar')
        expect { Remedy::Finisher.new(inventory: inventory, tools: mortar, noun: 'unguent', mark: nil).finish }.to raise_error(SystemExit)
        expect(messages).to eq(['Remedy: the unguent is not in hand after taking it out of the large mortar. Stopping.'])
        expect(game.clock).to eq(ReplayGame::FPUT_TIMEOUT + Remedy::Inventory::LATE_GET_LOOKS)
        expect(game.sent).to eq(['get my unguent from my large mortar'])
        expect($right_hand).to eq('diamondique large mortar')
      end
    end

    # layer 12: either sign is enough, so a product whose name in hand the
    # noun does not find is still taken as made when the game handed it over
    it "takes the product as made on the game's own line (26:6794) even when the hands do not show the noun" do
      allow(DRCI).to receive(:in_hands?).with('elixir').and_return(false)
      game.script('get my elixir from my large mortar', log('26:6794'))
      expect { Remedy::Finisher.new(inventory: inventory, tools: mortar, noun: 'elixir', mark: nil).finish }.not_to raise_error
      expect(calls.last).to eq([:stow, 'diamondique large mortar', toolbag, toolstrap])
    end

    # layer 12: the first line fput returns may be an unrelated one that came
    # before the reply (" * Venras joins the adventure.", 25:27826, between
    # the get at 25:27825 and its reply at 25:27830); the hands decide then.
    context 'when an unrelated line (25:27826) is the first line after the get' do
      # @return [void]
      def finish
        Remedy::Finisher.new(inventory: inventory, tools: mortar, noun: 'unguent', mark: nil).finish
      end

      before do
        allow(DRC).to receive(:message)
        allow(DRC).to receive(:beep)
      end

      it 'takes the product as made, with no wait, when a hand already shows it' do
        allow(DRCI).to receive(:in_hands?).with('unguent') { ReplayCommons.matches?($left_hand, 'unguent') }
        game.override('get my unguent from my large mortar', log('25:27826'), log('26:11389'), after: ->(_game) { $left_hand = 'nemoih unguent' })
        expect { finish }.not_to raise_error
        expect(calls.last).to eq([:stow, 'diamondique large mortar', toolbag, toolstrap])
        expect(game.clock).to eq(0)
      end

      it 'takes the product as made when a hand shows it a second later, the first late look' do
        arrives = nil
        game.override('get my unguent from my large mortar', log('25:27826'), log('26:11389'), after: ->(replay) { arrives = replay.clock + 1 })
        allow(DRCI).to receive(:in_hands?).with('unguent') { !arrives.nil? && game.clock >= arrives }
        expect { finish }.not_to raise_error
        expect(calls.last).to eq([:stow, 'diamondique large mortar', toolbag, toolstrap])
        expect(game.clock).to eq(1)
      end

      it 'stops, with the vessel in hand, after LATE_GET_LOOKS seconds when no hand ever shows it' do
        allow(DRCI).to receive(:in_hands?).with('unguent').and_return(false)
        game.override('get my unguent from my large mortar', log('25:27826'))
        expect { finish }.to raise_error(SystemExit)
        expect(game.clock).to eq(Remedy::Inventory::LATE_GET_LOOKS)
        expect($right_hand).to eq('diamondique large mortar')
      end
    end

    it 'does not take speech that quotes the product line (a name before "You get") as the product handed over' do
      allow(DRCI).to receive(:in_hands?).with('unguent').and_return(false)
      allow(DRC).to receive(:beep)
      allow(DRC).to receive(:message)
      quoted = code(%(<preset id='speech'>Mallory says</preset>, "#{log('26:11389').text}"), from: 'player speech form (remedy.lic:55-60, NO_QUOTE) around 26:11389')
      game.override('get my unguent from my large mortar', quoted)
      expect { Remedy::Finisher.new(inventory: inventory, tools: mortar, noun: 'unguent', mark: nil).finish }.to raise_error(SystemExit)
    end

    # layer 09: the stamp get is guarded (skip_exit, then the hands)
    it 'marks the product (25:11294) with the stamp from the belt or bag, and puts the stamp away' do
      game.script('mark my unguent with my stamp', log('25:11294'))
      Remedy::Finisher.new(inventory: inventory, tools: mortar, noun: 'unguent', mark: true).finish
      expect(game.sent).to eq(['get my unguent from my large mortar', 'mark my unguent with my stamp'])
      expect(calls.last(2)).to eq([[:get, 'stamp', toolbag, bag_items, toolstrap, true], [:stow, 'stamp', toolbag, toolstrap]])
    end

    # layer 09: the stamp get is guarded; a missing stamp leaves the product unmarked
    it 'says the product is left unmarked, and sends no mark, when the stamp is not in hand after its get' do
      messages = []
      allow(DRC).to receive(:message) { |text| messages << text }
      allow(DRCI).to receive(:in_hands?).with('stamp').and_return(false)
      expect { Remedy::Finisher.new(inventory: inventory, tools: mortar, noun: 'unguent', mark: true).finish }.not_to raise_error
      expect(game.sent).to eq(['get my unguent from my large mortar'])
      expect(messages).to eq(['Remedy: could not get the stamp; the unguent is left unmarked.'])
      expect(calls.last).to eq([:get, 'stamp', toolbag, bag_items, toolstrap, true])
    end
  end

  describe 'Remedy::Magic' do
    it 'releases nothing when crafting_training_spells is empty' do
      Remedy::Magic.new(settings).release
      expect(game.sent).to be_empty
    end

    context 'with crafting_training_spells' do
      let(:training_spells) { { 'Gauge Flow' => {} } }

      it 'releases the spell (25:52773), the mana (25:1316) and the symbiosis' do
        game.script('release spell', log('25:52773'))
        game.script('release mana', log('25:1316'))
        Remedy::Magic.new(settings).release
        expect(game.sent).to eq(['release spell', 'release mana', 'release symb'])
      end
    end

    it 'runs the commons routine with the settings' do
      Remedy::Magic.new(settings).routine
      expect(DRCA).to have_received(:crafting_magic_routine).with(settings)
    end

    # layer 12 (H15): the release from the before_dying
    # cleanup
    describe '#release_on_exit' do
      context 'with crafting_training_spells' do
        let(:training_spells) { { 'Gauge Flow' => {} } }

        it 'releases with fput, waiting for no particular reply, once the routine has run' do
          magic = Remedy::Magic.new(settings)
          magic.routine
          magic.release_on_exit
          expect(game.sent).to eq(['release spell', 'release mana', 'release symb'])
          expect(DRC).not_to have_received(:bput).with('release spell', any_args)
        end

        it 'releases nothing when the routine never ran, so nothing can be prepared' do
          Remedy::Magic.new(settings).release_on_exit
          expect(game.sent).to be_empty
        end

        it 'releases nothing more after the release at the end of a finished run' do
          game.script('release spell', log('25:52773'))
          game.script('release mana', log('25:1316'))
          magic = Remedy::Magic.new(settings)
          magic.routine
          magic.release
          magic.release_on_exit
          expect(game.sent).to eq(['release spell', 'release mana', 'release symb'])
        end

        it 'releases only once when called twice' do
          magic = Remedy::Magic.new(settings)
          magic.routine
          2.times { magic.release_on_exit }
          expect(game.sent).to eq(['release spell', 'release mana', 'release symb'])
        end
      end

      [nil, [], {}].each do |unset|
        context "with crafting_training_spells #{unset.inspect}" do
          let(:training_spells) { unset }

          it 'sends nothing, even after the routine ran' do
            magic = Remedy::Magic.new(settings)
            magic.routine
            magic.release_on_exit
            expect(game.sent).to be_empty
          end
        end
      end
    end
  end

  # Layer 13: the shop town and the purchase, as units, against
  # base-crafting.yaml's real remedies data.
  describe 'Remedy::Supplies' do
    let(:remedies) { YAML.load_file(File.expand_path('../data/base-crafting.yaml', __dir__), aliases: true)['remedies'] }

    describe '.shop_town' do
      # @param hometown [String]
      # @param force [String, nil] force_crafting_town
      # @return [String, nil]
      def shop_town(hometown, force)
        Remedy::Supplies.shop_town(OpenStruct.new(hometown: hometown, force_crafting_town: force), remedies)
      end

      it 'is the crafting town for every town base-crafting.yaml has a remedies shop for, whatever the hometown' do
        remedies.each_key do |town|
          expect(shop_town('Aesry', town)).to eq(town)
          expect(shop_town('Crossing', town)).to eq(town)
        end
      end

      it 'is the hometown when force_crafting_town is not set' do
        expect(shop_town('Shard', nil)).to eq('Shard')
      end

      it "falls back to the hometown when force_crafting_town has no remedies shop (Aesry, Shadow's Reach, Mer'Kresh)" do
        ['Aesry', "Shadow's Reach", "Mer'Kresh"].each { |town| expect(shop_town('Riverhaven', town)).to eq('Riverhaven') }
      end

      it 'is nil when neither town has a remedies shop, or the settings name none' do
        expect(shop_town('Aesry', nil)).to be_nil
        expect(shop_town('Aesry', "Mer'Kresh")).to be_nil
        expect(shop_town(nil, nil)).to be_nil
      end
    end

    describe '#buy_missing' do
      let(:town_settings) { OpenStruct.new(crafting_container: toolbag, crafting_items_in_container: bag_items, alchemy_belt: toolstrap, hometown: 'Shard', force_crafting_town: 'Riverhaven') }
      let(:supplies) { Remedy::Supplies.new(settings: town_settings, remedies: remedies, inventory: Remedy::Inventory.new(town_settings, herbs: %w[nemoih na]), return_room: 4321) }
      let(:messages) { [] }

      before do
        allow(DRCM).to receive(:get_money_from_bank) { |*args| calls << [:bank, args[0], args[2]] && true }
        allow(DRCT).to receive(:order_item) { |*args| calls << [:order, *args] }
        allow(DRCT).to receive(:walk_to) { |*args| calls << [:walk, *args] && true }
        allow(DRC).to receive(:message) { |text| messages << text }
      end

      it 'buys nothing, and sends nothing, when the water, the alcohol and the catalyst are on hand' do
        allow(DRCI).to receive(:exists?).and_return(true)
        supplies.buy_missing(water: plain_water, alcohol: plain_alcohol, catalyst: 'coal nugget')
        expect(calls).to be_empty
        expect(game.sent).to be_empty
      end

      it 'never buys for a liquid poured from a vessel, nor for a catalyst other than coal' do
        poured = Remedy::Liquid.new(kind: 'water', source: 'moonshine jug', verb: 'pour')
        supplies.buy_missing(water: poured, alcohol: Remedy::Liquid.new(kind: 'alcohol', source: 'flask', verb: 'pour'), catalyst: 'pewter ingot')
        expect(calls).to be_empty
      end

      it 'buys the coal nugget for the catalyst "nugget" too, at the Riverhaven catalyst-room (8785, base-crafting.yaml:1450)' do
        allow(DRCI).to receive(:exists?) { |item, *| item != 'nugget' }
        supplies.buy_missing(water: plain_water, alcohol: plain_alcohol, catalyst: 'nugget')
        expect(calls).to eq([[:bank, '5 silver', 'Riverhaven'], [:order, 8785, 2], [:stow, 'coal nugget', toolbag, toolstrap], [:walk, 4321]])
      end

      it 'checks the purchase by the name it was stowed by, after the stow, and says nothing when it is on hand' do
        ordered = false
        allow(DRCT).to receive(:order_item) { |*args| calls << [:order, *args] && (ordered = true) && nil }
        allow(DRCI).to receive(:exists?) do |item, *|
          calls << [:exists?, item]
          item != 'coal nugget' || ordered
        end
        supplies.buy_missing(water: plain_water, alcohol: plain_alcohol, catalyst: 'coal nugget')
        expect(calls).to eq([[:exists?, 'water'], [:exists?, 'alcohol'], [:exists?, 'coal nugget'],
                             [:bank, '5 silver', 'Riverhaven'], [:order, 8785, 2], [:stow, 'coal nugget', toolbag, toolstrap],
                             [:exists?, 'coal nugget'], [:walk, 4321]])
        expect(messages).to be_empty
      end

      it 'reports each purchase that leaves nothing on hand, and buys on' do
        supplies.buy_missing(water: plain_water, alcohol: plain_alcohol, catalyst: 'pewter ingot')
        expect(calls.map(&:first)).to eq(%i[bank order stow walk bank order stow walk])
        expect(messages).to eq(['Remedy: could not buy water at the Riverhaven alchemy shop; crafting on without it.',
                                'Remedy: could not buy alcohol at the Riverhaven alchemy shop; crafting on without it.'])
      end

      it 'stops at the first missing supply when no town has a shop, before the bank' do
        town_settings.hometown = 'Aesry'
        town_settings.force_crafting_town = nil
        expect { supplies.buy_missing(water: plain_water, alcohol: plain_alcohol, catalyst: 'pewter ingot') }.to raise_error(SystemExit)
        expect(messages).to eq(['Remedy: no water on hand, and no alchemy shop is known in Aesry to buy it from: put water in your crafting_container, or set force_crafting_town to a town with one. Stopping.'])
        expect(calls).to be_empty
      end
    end
  end
end
