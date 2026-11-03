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
      # flipped by layer 07 (bounded loop), then by layer 08 (stop on the refusal)
      it 'CURRENT (H01/H02): resends the crush forever on "You need a more suitable type of herb" (25:50933)' do
        game.override(first_crush, log('25:50933'), times: nil)
        script_short_unguent
        expect(run_remedy(short_unguent)).to eq(:looped)
        expect(game.sent.drop(3).uniq).to eq([first_crush])
        expect(game.diagnostics.uniq).to eq(["DRC: No match was found after 15 seconds for command '#{first_crush}' (1 lines seen)"])
        expect(remedy_messages).to be_empty
      end

      # flipped by layer 07 (bounded loop)
      it 'CURRENT (D06): resends the first crush forever when its reply never comes' do
        script_short_unguent(first_crush: [])
        expect(run_remedy(short_unguent)).to eq(:looped)
        expect(game.sent.drop(3).uniq).to eq([first_crush])
      end

      # flipped by layer 08 (MORE_PIECES stops) and layer 12 (the product get is checked)
      it 'CURRENT (D08): finishes on "requires more pieces of that plant" and puts the mortar away with no product and no message' do
        game.override(first_crush, code('That craftable requires more pieces of that plant to begin.', from: 'R:290'))
        game.override('get my unguent from my large mortar', log('26:39162')) # analog: the not-found reply to a get
        script_short_unguent
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent.drop(3)).to eq([first_crush, 'get my unguent from my large mortar'])
        expect(commons.location_of('unguent')).to be_nil
        expect(commons.location_of('diamondique large mortar')).to eq(toolstrap)
        expect(remedy_messages).to be_empty
      end

      # flipped by layer 08 (STEP_UNSUITABLE ends the handler's wait)
      it 'CURRENT (D11): turns again when the clumps cue repeats after the turn, and waits out 15 s on the refusal (26:25113)' do
        script_general_elixir(replace: { 6084 => [log('26:6086'), log('26:6088'), log('26:6031')] }, inject: { 6249 => [log('26:25113')] })
        settings[:mark_crafted_goods] = true
        inventory['crushed belradi'] = toolbag
        expect(run_remedy(workorders_call('a general elixir', 6, 'belradi', 'bowl', 'elixir', catalyst: 'pewter ingot'))).to eq(:exited)
        first_turn = game.sent.index('turn my heavy cauldron')
        expect(game.sent[first_turn, 2]).to eq(['turn my heavy cauldron', 'turn my heavy cauldron'])
        expect(game.diagnostics).to eq(["DRC: No match was found after 15 seconds for command 'turn my heavy cauldron' (1 lines seen)"])
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

      %i[current v5_22].each do |release|
        context "on lich-5 #{release}" do
          let(:lich5) { release }

          # flipped by layer 09 (guarded gets)
          it 'CURRENT (D14): is stopped inside DRCC, with no remedy line, the stick put away and the cauldron left in hand' do
            expect(run_without_the_catalyst).to eq(:exited)
            expect(commons.messages).to eq(['DRCC: You seem to be missing: pewter ingot', ReplayCommons::STOP_MESSAGE])
            expect(remedy_messages).to be_empty
            expect(game.sent.last).to eq(mix) # the mix that drew the catalyst cue (26:6313)
            expect(commons.location_of('heavy cauldron')).to eq('left').or eq('right')
            expect(commons.location_of('luminescent starshine mixing stick')).to eq(toolstrap)
          end
        end
      end

      context 'on lich-5 v5_21' do
        let(:lich5) { :v5_21 }

        # flipped by layer 09 (guarded gets)
        it 'CURRENT (D02/D15): carries on after the failed get and loops: put, refused mix, get, put ...' do
          expect(run_without_the_catalyst).to eq(:looped)
          expect(game.sent.count('put my pewter ingot in my heavy cauldron')).to be > 3
          expect(commons.messages.uniq).to eq(['DRCC: You seem to be missing: pewter ingot', ReplayCommons::STOP_MESSAGE])
          expect(remedy_messages).to be_empty
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

      # flipped by layer 10 (an empty vessel is stowed by name)
      it 'CURRENT (H07): after two failed counts, puts away "water" instead of the vessel' do
        game.script('count water in my glass flask', log('25:13762'))
        game.script('count water in my glass flask', log('25:13762'))
        script_short_unguent
        run_remedy(short_unguent)
        stows = commons.calls.select { |name, *| name == 'DRCC.stow_crafting_item' }.map { |call| call[1] }
        expect(stows.first).to eq('water')
        # The flask stays in hand until create_item puts away whatever the hands hold.
        flask_stowed = commons.calls.index { |name, item, *| name == 'DRCC.stow_crafting_item' && item == 'glass flask' }
        expect(flask_stowed).to be > commons.calls.index(['DRCA.crafting_magic_routine'])
      end

      # flipped by layer 10 (no `get my water from my water`)
      it 'CURRENT (H18): with no vessel, the refused-pour fallback asks for water from "water" (remedy.lic:315)' do
        settings[:water_container] = nil
        game.script('put water in my large mortar', code('You cannot find a way to add that as an ingredient.', from: 'R:313'))
        script_short_unguent(put_lines: [log('26:10749'), log('25:50210')])
        run_remedy(short_unguent)
        expect(commons.calls).to include(['DRCI.get_item?', 'water', 'water'])
      end

      # flipped by layer 10 ("Pour what?" refills, then stops)
      it 'CURRENT (D03): pours from an empty alcohol vessel forever: "Pour what?" (26:22405) counts as added' do
        settings.merge!(alcohol_container: 'moonshine jug', water_container: nil)
        inventory['moonshine jug'] = toolbag
        inventory['crushed belradi'] = toolbag
        # The jug's count gets no reply (no vessel count is in the logs), so
        # remedy pours from it (H06, kept by A4). "Pour what?" is the reply
        # to `pour part alcohol in my heavy cauldron` with the jug in hand
        # (26:22403, analog); while the alcohol is owed the game refuses each
        # mix with the cue alone (26:22342, the reply to a mix at 26:22337).
        refuse_mixes = ->(replay) { replay.override('mix my heavy cauldron with my mixing stick', log('26:22342'), log('26:22344'), times: nil) }
        script_one_stack('belradi', vessel: 'heavy cauldron', put_lines: [log('26:5898')])
        game.script('mix my heavy cauldron with my mixing stick', log('26:5913'), log('26:5915'), log('26:5918'), log('26:5920'))
        game.override('pour moonshine jug in my heavy cauldron', log('26:22405'), times: nil, after: refuse_mixes)
        expect(run_remedy(typed('remedies 6 "a general elixir" belradi na "pewter ingot" bowl elixir'))).to eq(:looped)
        expect(game.sent.count('pour moonshine jug in my heavy cauldron')).to be > 3
        expect(game.sent).not_to include('rub my moonshine jug')
      end
    end

    describe 'gathering the herb' do
      # flipped by layer 11 (count only what is held)
      it 'CURRENT (H04): takes "You must be holding both" (25:18266) as 25 pieces after counting 21 (25:12538)' do
        inventory['dried nemoih'] = 'seasilk apron'
        game.script('count my nemoih', log('25:12538'))
        game.script('combine my nemoih', log('25:18266'))
        game.script(herb_put_command('nemoih', 'large mortar'), log('26:10749'), after: ->(_game) { commons.release('nemoih') })
        game.script(first_crush, log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent).to eq(['count my nemoih', 'stow my nemoih', 'combine my nemoih',
                                 herb_put_command('nemoih', 'large mortar'), first_crush, 'get my unguent from my large mortar'])
      end

      # flipped by layer 11. Assumption (unverified, H05): with two
      # stacks in hand `count` counts the one picked up first. The third count
      # is 25:104726 with the number changed to the merged 10 + 10.
      it 'CURRENT (H05): counts a merged stack again, ending at 40 counted with 22 held (stacks of 10, 10 and 2)' do
        2.times { commons.inventory << ReplayCommons::Item.new('dried nemoih', toolbag) }
        merged = ->(_replay) { commons.release('nemoih') }
        game.script('count my nemoih', log('25:104726'))
        game.script('combine my nemoih', log('25:104590'))
        game.script('count my nemoih', log('25:104726'))
        game.script('combine my nemoih', log('25:11425'), after: merged)
        game.script('count my nemoih', code('You count out 20 pieces of material there.', from: '25:104726, count changed (H05 assumption)'))
        game.script('combine my nemoih', log('25:11425'), after: merged)
        game.script(herb_put_command('nemoih', 'large mortar'), log('26:10749'), after: ->(_game) { commons.release('nemoih') })
        game.script(first_crush, log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        expect(run_remedy(short_unguent)).to eq(:exited)
        expect(game.sent.first(7)).to eq(['count my nemoih', 'combine my nemoih', 'count my nemoih', 'combine my nemoih',
                                          'count my nemoih', 'combine my nemoih', herb_put_command('nemoih', 'large mortar')])
      end

      context 'on lich-5 v5_21' do
        let(:lich5) { :v5_21 }
        let(:inventory) { logged_tools.merge(logged_supplies) }

        # flipped by layer 11 (bounded gathering)
        it 'CURRENT (H26): counts and combines forever when the bag says it has the herb but the get brings nothing' do
          game.fallback('count my nemoih', log('25:13762')) # analog: the not-found reply to a tap
          expect(run_remedy(short_unguent) { allow(DRCI).to receive(:exists?).and_return(true) }).to eq(:looped)
          expect(game.sent.uniq).to eq(['count my nemoih', 'combine my nemoih'])
        end
      end

      # flipped by layer 11 (the leftover goes to herb_container, then the bag)
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
      # @return [void]
      def keep_the_leftover_in_hand
        allow(DRCC).to receive(:stow_crafting_item) do |*args|
          args.first == 'nemoih' ? true : commons.stow_crafting_item(*args)
        end
      end

      # flipped by layer 11 (the leftover stow is checked)
      it 'CURRENT (D12): on lich-5 current, the pestle get finds no free hand and DRCC stops with herb and mortar in hand' do
        game.script('count my nemoih', log('25:33679'))
        game.script('combine my nemoih', log('25:104590'))
        game.script(herb_put_command('nemoih', 'large mortar'), log('26:10749'))
        expect(run_remedy(short_unguent) { keep_the_leftover_in_hand }).to eq(:exited)
        expect(commons.messages).to include('DRCC: No free hand to get: rounded pestle')
        expect([commons.location_of('nemoih'), commons.location_of('diamondique large mortar')]).to contain_exactly('left', 'right')
      end
    end

    describe 'restocking (C12)' do
      let(:inventory) { logged_tools.merge(logged_supplies.except('water'), 'dried nemoih' => toolbag) }
      let(:orders) { { 1 => 'water' } }

      # flipped by layer 13 (restock in the crafting town)
      it 'CURRENT (H09): buys in the hometown (Shard stock-room 19288) although force_crafting_town is Crossing' do
        settings.merge!(hometown: 'Shard', force_crafting_town: 'Crossing')
        script_short_unguent
        run_remedy(short_unguent)
        expect(commons.calls).to include(['DRCT.order_item', 19288, 1])
      end

      # flipped by layer 13
      it 'CURRENT (H09): raises NoMethodError for a hometown with no remedies data (Aesry)' do
        settings[:hometown] = 'Aesry'
        script_short_unguent
        expect { run_remedy(short_unguent) }.to raise_error(NoMethodError)
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

      # flipped by layer 12 (stow by name)
      it 'CURRENT (H14): in the continue form with the vessel in the left hand, finish puts the vessel away before taking the product out' do
        inventory.delete('diamondique large mortar')
        $left_hand = 'diamondique large mortar'
        game.script('analyze my unguent', log('26:11132'), log('26:11146'))
        game.script('crush my unguent with my rounded pestle', log('26:11333'))
        script_product('get my unguent from my large mortar', log('26:11389'), 'nemoih unguent')
        run_remedy(typed('continue na "pewter ingot" mortar unguent'))
        expect(commons.moves.last(3)).to eq(["diamondique large mortar: hand -> #{toolstrap}", 'nemoih unguent: game -> hand',
                                             "rounded pestle: hand -> #{toolstrap}"])
      end

      # flipped by layer 12 (cleanup in before_dying releases magic)
      it 'CURRENT (H15): its before_dying only deletes Flags, releasing nothing after a DRCC stop' do
        settings[:crafting_training_spells] = { 'Gauge Flow' => {} }
        inventory.delete('dried nemoih')
        expect(run_remedy(short_unguent)).to eq(:exited)
        sent = game.sent.dup
        exit_hooks.each(&:call)
        expect(game.sent).to eq(sent)
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
end
