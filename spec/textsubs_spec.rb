require 'delegate'
require 'fileutils'
require 'json'
require 'prism'
require 'stringio'
require 'tmpdir'
require 'yaml'
require_relative '../test/textsubs_corpus'

# textsubs.lic builds its whole substitution catalog when it starts: the entry
# point adds the shit-list and private_textsubs entries, then the ~1,600
# built-in subs TextSubs::Catalog reads from data/base-textsubs.yaml, gated by
# the guild and three settings, and then registers the 'textsub'
# DownstreamHook. These specs pin that catalog so a change to the script or
# the data file has to reproduce every entry, in order, for every combination
# a player can run. The golden fixture is JSON, so it does not lean on the YAML
# reader it checks.
#
# The golden fixture lives in spec/fixtures/textsubs/:
#   - catalog_entries.jsonl holds every distinct [source, options, replacement]
#     entry once, one JSON array per line, in first-appearance order;
#   - catalog_combos.json lists, per guild x textsubs_spell_links x herb_textsubs
#     x textsubs_use_plat_grouping combination, the inclusive index ranges of
#     catalog_entries.jsonl that make up that combination's ordered catalog.
#
# Regenerate it (only in a commit that changes the catalog on purpose) with
#   TEXTSUBS_GOLDEN_WRITE=1 bundle exec rspec spec/textsubs_spec.rb
# and review the fixture diff: it names every entry the change touched.
#
# A nil guild (textsubs started before DRStats knows the guild) is not part of
# the golden set; 'a guild DRStats does not know yet' covers it, holding the
# catalog built once the guild turns up to the golden one.
#
# The golden catalog says WHAT the hook applies; the reference-engine oracle
# below says HOW. reference_apply keeps today's matching engine verbatim, and
# the hook has to give the same output for every guild catalog over two
# committed inputs, both synthetic (no real player names):
#   - samples.jsonl holds one JSON string per line, expanded from the catalog's
#     own regex sources (up to two alternatives per entry), so every key of
#     every guild catalog is matched by at least one sample. Then come
#     composite lines, each two of those samples joined by a space, that two or
#     more keys of every guild catalog match; in a few of them the order the
#     keys run in changes the output (a coin amount before a spell link, whose
#     '>' turns the coin rule off), so the per-guild sweeps also pin the order
#     of real keys, not just each key. A scroll label before a link to the
#     same spell gives one output in either order: the label keeps the full
#     stop after the title, so the link rule's '..\(' cannot match inside it.
#     The lines of samples_hand_added.jsonl come last;
#   - synthetic_stream.xml is a hand-written XML stream (inv pushStream dump,
#     room objs with exist ids, prompts, roundTime, coin and wealth lines and a
#     49 KB digit-heavy inventoryManager line), every line ending in \r\n.
# test/textsubs_corpus.rb generates both: the samples from catalog_entries.jsonl,
# the stream from its own text. 'corpus fixtures' checks that each file is the
# generator's output (for samples.jsonl, followed by the lines of
# samples_hand_added.jsonl, each line once). A commit that changes the catalog
# regenerates the golden fixture first, then these two, in a separate run
# (the corpus writer refuses to run beside the golden writer):
#   TEXTSUBS_GOLDEN_WRITE=1 bundle exec rspec spec/textsubs_spec.rb
#   TEXTSUBS_CORPUS_WRITE=1 bundle exec rspec spec/textsubs_spec.rb
# and reviews the diff. To pin a pattern with a line the generator does not
# make, add it to samples_hand_added.jsonl (one JSON string per line, matched
# by some key of some guild catalog) and regenerate; nothing writes that file,
# so a hand-added line is never dropped. A line added straight to
# samples.jsonl is: the every-run check names it before it says to regenerate,
# and the writer names every line it drops.
#
# What the real catalogs cannot pin: on no corpus line does a key create a
# match for a key that runs after it (the only two such pairs a search of every
# key's output on its own samples found run the other way round), so an engine
# that checks each key against the changing line instead of the original gives
# the same output on every corpus line. The hand-made catalogs in 'hook engine
# semantics' pin that rule.
#
# The hook proc is the front end guard plus TextSubs.apply(line), which runs
# TextSubs::Engine over TextSubs.subs with a TokenIndex built over its keys
# and the installed Registry's requires_any gates. 'TextSubs.apply' calls that
# engine straight, with hand-made catalogs and no hook; 'the coin-comma gate'
# holds the one gated section to the oracle and checks that its gate is sound.
#
# The index only picks which keys run on a line, so every oracle sweep above
# also holds it to reference_apply. On top of those, 'every catalog, through
# one index over all their keys' covers the keys of all 96 catalogs on every
# corpus line and on mutated samples, and 'TextSubs::TokenIndex' pins each
# tier, every construct the parser refuses (with a line a naive reading of the
# source would wrongly skip) and a seeded fuzz of 2,000 generated regexes.
#
# The hook skips every key when no front end is attached (TextSubs.client_attached?
# is false), and the harness has none, so the examples that send lines through
# the hook stub that predicate to true; 'front end guard' covers both branches.
#
# Hooks run through run_hooks, never DownstreamHook.run directly: a `return`
# in the hook proc (where `next` belongs) is a top-level return in this spec
# and would end rspec silently with status 0.

load_lic_class('textsubs.lic', 'TextSubs')

RSpec.describe 'textsubs.lic' do
  # The twelve guilds DRStats can report, in fixture order.
  guilds = ['Barbarian', 'Bard', 'Cleric', 'Commoner', 'Empath', 'Moon Mage',
            'Necromancer', 'Paladin', 'Ranger', 'Thief', 'Trader', 'Warrior Mage']
  # Every guild x textsubs_spell_links x herb_textsubs x textsubs_use_plat_grouping.
  combinations = guilds.product([false, true], [false, true], [false, true]).map do |guild, spell_links, herb, plat|
    { 'guild' => guild, 'textsubs_spell_links' => spell_links, 'herb_textsubs' => herb,
      'textsubs_use_plat_grouping' => plat }
  end
  fixture_dir = File.expand_path('fixtures/textsubs', __dir__)
  entries_path = File.join(fixture_dir, 'catalog_entries.jsonl')
  combos_path = File.join(fixture_dir, 'catalog_combos.json')
  samples_path = File.join(fixture_dir, 'samples.jsonl')
  stream_path = File.join(fixture_dir, 'synthetic_stream.xml')
  hand_added_path = File.join(fixture_dir, 'samples_hand_added.jsonl')
  # @return [Array<Array(String, Integer, String)>] the rows of catalog_entries.jsonl
  read_entries = -> { File.readlines(entries_path).map { |line| JSON.parse(line) } }
  # Every key of every catalog a player can run: the keys of
  # catalog_entries.jsonl, once each. The golden examples hold that file to
  # what the 96 builds write.
  every_key = read_entries.call.map { |source, options, _replacement| Regexp.new(source, options) }.uniq
  catalog_path = File.expand_path('../data/base-textsubs.yaml', __dir__)
  # Read once, the way lich-5's SetupFiles reads it (YAML.unsafe_load_file),
  # and frozen, so a catalog reader that changed its data would raise.
  shipped_catalog = YAML.unsafe_load_file(catalog_path, freeze: true)

  # Every example starts as a fresh install: get_data('textsubs') answers with
  # the shipped file, as an OpenStruct of its top-level keys like lich-5's, and
  # SCRIPT_DIR points nowhere, so there is no data/custom copy.
  #
  # The entry point ends in TextSubs.watch, which waits as long as the
  # 'textsub' hook is registered: stubbed here so run_lic_entry returns with
  # the hook still in place. 'TextSubs.watch' runs the real one.
  before do
    stub_const('SCRIPT_DIR', '/nonexistent-textsubs-spec')
    $test_data[:textsubs] = OpenStruct.new(shipped_catalog)
    allow(TextSubs).to receive(:watch)
  end

  # Each key's tier, as the real TokenIndex.tier gave it the first time any
  # example asked. A tier depends on nothing but the key's source and options,
  # which Regexp#eql? compares, so a key built again gets the very tier the
  # parser gave it. Every TokenIndex.tier call in the file goes through this,
  # the parser examples' included: the real parser answers the first call for
  # each key in the run, and later calls for that key get its answer back.
  # The first apply after every catalog build indexes ~1,600 keys, ~70 ms of
  # parsing each time. Without the memo the file ran in 12.9-13.3 s wall
  # (seeds 1-3) instead of 8.2-8.5 s: the 10 s budget for this file holds
  # only because of it, so it is not a cosmetic speed-up to drop.
  parsed_tiers = {}
  before do
    allow(TextSubs::TokenIndex).to(receive(:tier).and_wrap_original { |original, key| parsed_tiers[key] ||= original.call(key) })
  end

  # Runs the real textsubs.lic entry point for one combination and returns the
  # catalog it built.
  #
  # Nothing is cleared first: load_lic_class evaluates the class body only once
  # per process, so each run starts from whatever the run before it left, and
  # the entry point's own fresh Registry is what keeps the catalogs apart.
  #
  # Every textsubs key gets a value on each call, so a catalog never inherits
  # a setting from an earlier build_catalog call in the same example.
  #
  # @param guild [String] what DRStats.guild reports
  # @param settings [Hash{String=>Object}] settings keys for get_settings,
  #   merged over textsubs_defaults
  # @return [Array<Array(String, Integer, String)>] [source, options, replacement]
  #   for each entry of TextSubs.subs, in insertion order
  def build_catalog(guild, settings = {})
    DRStats.guild = guild
    textsubs_defaults.merge(settings).each { |key, value| $test_settings[key] = value }
    run_lic_entry('textsubs.lic', 'TextSubs')
    TextSubs.subs.map { |pattern, replacement| [pattern.source, pattern.options, replacement] }
  end

  # The textsubs settings as profiles/base.yaml ships them: private_textsubs
  # is nil, as base.yaml leaves it empty, and every flag is false.
  # 'the settings textsubs reads' holds this table to the file.
  #
  # @return [Hash{String=>Object}] frozen default for every key textsubs.lic reads
  def textsubs_defaults
    { 'private_textsubs' => nil, 'integrate_shit_list_with_textsubs' => false, 'textsubs_spell_links' => false,
      'herb_textsubs' => false, 'textsubs_use_plat_grouping' => false }.freeze
  end

  # Runs the block inside a new temporary directory that holds
  # "<checkname>_shit.list" with the given content, or no such file when
  # content is nil: the entry point reads the shit list from the current
  # directory, so a build in the block sees exactly this file.
  #
  # @param content [String, nil] the shit-list file body, or nil for no file
  # @yield with the temporary directory as the current directory
  # @yieldreturn [Object] what the block builds
  # @return [Object] what the block returned
  def with_shit_list(content, &)
    Dir.mktmpdir('textsubs-shit-list') do |dir|
      File.write(File.join(dir, "#{checkname}_shit.list"), content) if content
      Dir.chdir(dir, &)
    end
  end

  # @param combination [Hash{String=>Object}] one element of `combinations`
  # @return [Array<Array(String, Integer, String)>] that combination's catalog
  def build_combination(combination)
    build_catalog(combination['guild'], combination.except('guild'))
  end

  # Each combination's traced build (see traced_build), made once per run by
  # whichever example asks first. The examples that only read a catalog, or
  # the writes that made it, share these builds, so the 96 catalogs are not
  # rebuilt once per such example. The examples that need TextSubs.subs to
  # hold the catalog call build_combination instead.
  built_catalogs = {}

  # The stubs active in this example that could change what build_catalog
  # builds: any stub on DRStats (the guild predicates), File (run_lic_entry
  # reads the script through it, and the shit-list branch reads a file), or the
  # top-level object (get_settings), and any stub on TextSubs except
  # client_attached?, which the script reads only inside the hook, and watch,
  # which the entry point calls only after it has built the catalog (and which
  # the before block above stubs for every example alike).
  #
  # @return [Array<String>] one label per stubbed object or TextSubs method;
  #   empty when nothing that catalog building reads is stubbed
  def stubs_on_catalog_reads
    space = RSpec::Mocks.space
    stubbed = { 'DRStats' => DRStats, 'File' => File, 'the top-level object' => TOPLEVEL_BINDING.receiver }
              .select { |_label, input| space.registered?(input) }.keys
    return stubbed unless space.registered?(TextSubs)

    proxy = space.proxy_for(TextSubs)
    stubbed + (TextSubs.singleton_methods - %i[client_attached? watch])
              .select { |name| proxy.method_double_if_exists_for_message(name) }
              .map { |name| "TextSubs.#{name}" }
  end

  # build_combination, recording the source of every key written to a
  # Registry while it builds. Every writer, add, elanthipedia and the catalog
  # data alike, ends in Registry#add, which on_registry_write watches; the
  # catalog data does not pass through add, as it stores the keys its check
  # compiled. on_registry_write's TracePoint leaves Registry#add as it is;
  # rspec-mocks wrappers on the ~100,000 writes of the 96 builds doubled the
  # time of the builds. The observer also keeps the Registry written last,
  # the fresh one the entry point installs and then fills, to read its gates
  # from; the build raises if that Registry is not the installed one.
  #
  # @param combination [Hash{String=>Object}] one element of `combinations`
  # @return [Hash{Symbol=>Object}] deep-frozen, because every caller shares it.
  #   It shares no mutable string with TextSubs.subs or the script: each
  #   replacement, and each list of gate words, is the frozen one the
  #   Registry keeps, shared as it is, and each source is a new String
  #   (Regexp#source returns one per call), kept frozen (see frozen_copy).
  #   :catalog, as build_combination returns it; :write_sources
  #   [Array<String>], the source of the key of each Registry#add call, in
  #   call order; :gates [Hash{Array(String, Integer)=>Array<String>}], the
  #   [source, options] of each key the built Registry gates and its
  #   requires_any words, as Registry#gates holds them once the build is done
  # @raise [RuntimeError] when the Registry written last is not the one
  #   TextSubs.subs reads, so its gates would not be the installed ones
  def traced_build(combination)
    sources = []
    registry = nil
    record = lambda do |key, _replacement, _requires_any, written|
      registry = written
      sources << key.source.freeze
    end
    catalog = on_registry_write(record) { build_combination(combination) }
    raise 'traced_build: the Registry written last is not the installed one' unless registry.snapshot.equal?(TextSubs.subs)

    { catalog: catalog.map { |entry| entry.map { |value| frozen_copy(value) }.freeze }.freeze,
      write_sources: sources.freeze,
      gates: registry.gates.to_h { |key, words| [[key.source.freeze, key.options].freeze, words] }.freeze }.freeze
  end

  # A frozen value that shares no mutable object with the one given: a frozen
  # value as it is, anything else a frozen copy. A catalog entry holds a new
  # source String, an Integer and the frozen replacement the Registry keeps,
  # so today only the source is copied. The copy, rather than freezing the
  # given object, keeps the record from freezing a String someone else holds,
  # should build_catalog ever return one (a later `<<` on it would raise
  # FrozenError in whichever example built that combination first).
  #
  # @param value [Object] a catalog value (String or Integer)
  # @return [Object] `value` when frozen, else a frozen dup of it
  def frozen_copy(value)
    value.frozen? ? value : value.dup.freeze
  end

  # Memoized traced_build, for examples that only read the returned catalog or
  # writes. Whether TextSubs.subs holds that catalog afterwards depends on
  # whether this call built it, so callers must not rely on TextSubs.subs
  # either way; examples that need it call build_combination.
  #
  # Under --order random (as the seed gate runs it) any caller may be the first
  # to ask for a combination, and the first caller builds it in its own
  # context, so a stub on something catalog building reads would leak into
  # every later caller's record. Every call therefore refuses to run while
  # such a stub is active (see stubs_on_catalog_reads), cached or not, so a
  # caller in a stubbing group fails on every run, whatever the order.
  #
  # @param combination [Hash{String=>Object}] one element of `combinations`
  # @return [Hash{Symbol=>Object}] that combination's shared, deep-frozen
  #   record, as traced_build returns it
  # @raise [RuntimeError] when a stub on something catalog building reads is
  #   active in the calling example
  define_method(:catalog_build_of) do |combination|
    stubbed = stubs_on_catalog_reads
    unless stubbed.empty?
      raise "catalog_build_of: #{stubbed.join(', ')} stubbed here would change the shared catalog; " \
            'call build_combination in this group instead'
    end

    built_catalogs[combination] ||= traced_build(combination)
  end

  # The catalog half of catalog_build_of, for examples that only read entries.
  #
  # @param combination [Hash{String=>Object}] one element of `combinations`
  # @return [Array<Array(String, Integer, String)>] that combination's shared,
  #   deep-frozen catalog (see catalog_build_of)
  # @raise [RuntimeError] as catalog_build_of does
  def catalog_of(combination)
    catalog_build_of(combination)[:catalog]
  end

  # Expands a list of inclusive [first, last] index ranges into entries.
  #
  # @param entries [Array<Array>] every fixture entry
  # @param ranges [Array<Array(Integer, Integer)>]
  # @return [Array<Array>] the selected entries, in range order
  def expand_ranges(entries, ranges)
    ranges.flat_map { |first, last| entries[first..last] }
  end

  # Compresses a list of indexes into inclusive [first, last] runs.
  #
  # @param indexes [Array<Integer>]
  # @return [Array<Array(Integer, Integer)>]
  def compress_ranges(indexes)
    indexes.slice_when { |a, b| b != a + 1 }.map { |run| [run.first, run.last] }
  end

  # A failure message naming the combination, the first index where the
  # catalogs part, and both entries there.
  #
  # @param combination [Hash] the combination under test
  # @param expected [Array<Array>] the golden catalog
  # @param actual [Array<Array>] the catalog the script built
  # @return [String]
  def catalog_difference(combination, expected, actual)
    index = (0...[expected.size, actual.size].max).find { |i| expected[i] != actual[i] }
    "catalog differs for #{combination.inspect} at entry #{index} " \
      "(expected #{expected.size} entries, got #{actual.size}):\n" \
      "  expected: #{expected[index].inspect}\n" \
      "  actual:   #{actual[index].inspect}"
  end

  # Today's matching engine, kept verbatim as the oracle the hook is held to:
  # select every key that matches the ORIGINAL line, then gsub! each selected
  # key, in insertion order, on the line as it changes. It is deliberately a
  # copy, not a call: later changes rewrite the hook's engine, and this is the
  # behaviour they must keep.
  #
  # @param subs [Hash{Regexp=>String}] ordered catalog (TextSubs.subs)
  # @param line [String] a server line
  # @return [String] the line after substitution; `line` is not modified
  def reference_apply(subs, line)
    client_string = line.dup
    matches = subs.select { |key, _| key =~ client_string }
    matches.each { |target, result| client_string.gsub!(target, result) }
    client_string
  end

  # Sends a line through every registered DownstreamHook, as Lich does.
  #
  # run_lic_entry evaluates the entry in a copy of TOPLEVEL_BINDING, so a
  # `return` inside the hook proc (where `next` belongs) is a top-level return:
  # Ruby unwinds the whole rspec process and exits with status 0, skipping
  # every example after it, and neither `rescue Exception` nor the SystemExit
  # guard in spec_helper sees it. The ensure clause still runs on that unwind,
  # and raising there turns it into an ordinary failure of this example.
  #
  # The rescue clause only notes that the hooks raised, and re-raises the same
  # exception. $! cannot tell the two exits apart: run_hooks called while an
  # exception is being rescued sees that exception in $! on a top-level return.
  #
  # @param line [String] a binary server line
  # @return [String, nil] what the hooks pass on to the client
  # @raise [RuntimeError] when the hooks neither returned nor raised
  # @raise [Exception] whatever a hook raises that DownstreamHook.run does not
  #   rescue (it rescues StandardError), unchanged
  # @example With a front end attached (TextSubs.client_attached? stubbed to true)
  #   run_hooks("You feel fine.\r\n".b) # => "You feel FINE.\r\n"
  def run_hooks(line)
    exit_by = :unwind
    output = DownstreamHook.run(line)
    exit_by = :return
    output
  rescue Exception # rubocop:disable Lint/RescueException
    exit_by = :raise
    raise
  ensure
    if exit_by == :unwind
      raise "a DownstreamHook left without returning (a `return` in the hook proc where `next` belongs?); " \
            'unchecked, that would end the whole rspec run with status 0'
    end
  end

  # The harness has no front end, and the hook skips every key without one
  # (see 'front end guard'), so groups that send lines through the hook
  # include this.
  shared_context 'with a front end attached' do
    before { allow(TextSubs).to receive(:client_attached?).and_return(true) }
  end

  # Runs the block, calling observer after every write to a Registry while
  # it runs (the entry point stages a fresh Registry on every start, fills
  # it, then installs it). Every writer, add, elanthipedia and the catalog
  # data alike, ends in Registry#add, so observer sees each sub as it lands.
  # A TracePoint on the return of Registry#add watches the writes, enabled
  # only while the block runs, so nothing outlives it: no stub on TextSubs
  # and no singleton method on any Registry, the one the after hook installs
  # for the next example included. The key, the replacement and the gate are
  # read by their positions, so renaming Registry#add's parameters does not
  # break it; their names are looked up once per call of this helper, not
  # once per write. Registry#add raises only for a key that is not a Regexp
  # or a malformed gate, which these builds never write.
  #
  # @param observer [#call] called with the key [Regexp], the replacement
  #   [String] and the requires_any words [Array<String>, nil] of each write,
  #   and the TextSubs::Registry written to, after the write
  # @yieldreturn [Object] the build to watch
  # @return [Object] what the block returns
  def on_registry_write(observer)
    write = TextSubs::Registry.instance_method(:add)
    key_param, value_param, gate_param = write.parameters.map(&:last)
    writes = TracePoint.new(:return) do |trace|
      observer.call(*[key_param, value_param, gate_param].map { |name| trace.binding.local_variable_get(name) }, trace.self)
    end
    writes.enable(target: write) { yield }
  end

  let(:golden_entries) { File.readlines(entries_path).map { |line| JSON.parse(line) } }
  let(:golden_combinations) { JSON.parse(File.read(combos_path))['combinations'] }

  # @param combination [Hash{String=>Object}] one element of `combinations`
  # @return [Array<Array(String, Integer, String)>] its catalog as the golden
  #   fixture holds it
  def golden_catalog(combination)
    golden = golden_combinations.find { |c| c.except('ranges') == combination }
    expand_ranges(golden_entries, golden.fetch('ranges'))
  end

  # Installing a freshly staged Registry empties the catalog and ends any
  # staging an example left behind, and this thread's own build with it
  # (TextSubs.clear alone keeps both), so no example's adds land in a
  # Registry staged by an earlier one. A start_run no example holds the
  # token of supersedes the run of the last start, so no example's token
  # stays current in the next one.
  #
  # RSpec runs this hook before it removes the example's stubs, so a stub on
  # stage or install still runs here, on the Registry the next example
  # starts with. That Registry must come out as plain as it went in: an
  # example's stub that gave it singleton methods (an add that calls back
  # into the example, say) would carry the example into the next one.
  after do
    DownstreamHook.remove('textsub')
    TextSubs.start_run
    fresh = TextSubs::Registry.new
    TextSubs.install(TextSubs.stage(fresh))
    expect(fresh.singleton_methods).to be_empty, -> { "a stub left #{fresh.singleton_methods.inspect} on the next example's Registry" }
  end

  if ENV['TEXTSUBS_GOLDEN_WRITE'] == '1'
    it 'writes the golden catalog fixture' do
      catalogs = combinations.map { |combination| [combination, build_combination(combination)] }
      index = {}
      catalogs.each { |_, catalog| catalog.each { |entry| index[entry] ||= index.size } }

      FileUtils.mkdir_p(fixture_dir)
      File.write(entries_path, index.keys.map { |entry| "#{JSON.generate(entry)}\n" }.join)
      rows = catalogs.map do |combination, catalog|
        "    #{JSON.generate(combination.merge('ranges' => compress_ranges(catalog.map { |entry| index[entry] })))}"
      end
      File.write(combos_path, "{\n  \"regenerate\": \"TEXTSUBS_GOLDEN_WRITE=1 bundle exec rspec spec/textsubs_spec.rb\",\n  " \
                              "\"combinations\": [\n#{rows.join(",\n")}\n  ]\n}\n")
      expect(File.size(entries_path)).to be > 0
    end
  else
    describe 'golden catalog' do
      before(:all) do
        @golden_entries = read_entries.call
        @golden_combinations = JSON.parse(File.read(combos_path))['combinations']
      end

      it 'lists exactly the combinations this spec builds' do
        expect(@golden_combinations.map { |c| c.except('ranges') }).to eq(combinations)
      end

      it 'holds each entry once and uses every entry and only real indexes' do
        used = @golden_combinations.flat_map { |c| c['ranges'].flat_map { |first, last| (first..last).to_a } }
        expect(@golden_entries.uniq.size).to eq(@golden_entries.size)
        expect(used.uniq.sort).to eq((0...@golden_entries.size).to_a)
      end

      it 'rebuilds from nothing on a restart, keeping no herb, shit-list or private key of the run before' do
        with_shit_list("zorvex,stole my kill\n") do
          first = build_catalog('Ranger', 'herb_textsubs' => true, 'integrate_shit_list_with_textsubs' => true,
                                          'private_textsubs' => { 'You feel fine' => 'You feel FINE' })
          expect(first.map(&:first)).to include('\\bZorvex\\b', 'You feel fine', 'nilos')
        end

        combination = { 'guild' => 'Ranger', 'textsubs_spell_links' => false, 'herb_textsubs' => false,
                        'textsubs_use_plat_grouping' => false }
        golden = @golden_combinations.find { |c| c.except('ranges') == combination }
        expected = expand_ranges(@golden_entries, golden['ranges'])
        actual = build_combination(combination)
        expect(actual == expected).to be(true), -> { catalog_difference(combination, expected, actual) }
      end

      combinations.each do |combination|
        flags_label = combination.except('guild').map { |flag, on| "#{flag} #{on ? 'on' : 'off'}" }.join(', ')
        it "reproduces the #{combination['guild']} catalog with #{flags_label}" do
          golden = @golden_combinations.find { |c| c.except('ranges') == combination }
          expected = expand_ranges(@golden_entries, golden['ranges'])
          actual = catalog_of(combination)
          expect(actual == expected).to be(true), -> { catalog_difference(combination, expected, actual) }
        end
      end
    end
  end

  # The checks yamllint does not make: its key-duplicates rule only warns, and
  # Psych keeps the last of two equal keys without a word. They read the
  # file's syntax tree, so they see how each scalar is written, not just what
  # it loads as.
  describe 'data/base-textsubs.yaml' do
    let(:document) { Psych.parse_file(catalog_path) }
    let(:data) { shipped_catalog['textsubs'] }

    # Every scalar of a parsed YAML stream that is a value, not a mapping key.
    #
    # @param tree [Psych::Nodes::Node] a parsed stream or document
    # @return [Array<Psych::Nodes::Scalar>]
    def value_scalars(tree)
      keys = tree.each.grep(Psych::Nodes::Mapping).flat_map { |mapping| mapping.children.each_slice(2).map(&:first) }
      tree.each.grep(Psych::Nodes::Scalar).reject { |scalar| keys.any? { |key| key.equal?(scalar) } }
    end

    # @param tree [Psych::Nodes::Node]
    # @return [Array<String>] "line N: value" for each value scalar not in
    #   single quotes, but the number under a schema key
    def unquoted_values(tree)
      schema_numbers = tree.each.grep(Psych::Nodes::Mapping).flat_map do |mapping|
        mapping.children.each_slice(2).select { |key, _| key.value == 'schema' }.map(&:last)
      end
      value_scalars(tree).reject { |scalar| scalar.style == Psych::Nodes::Scalar::SINGLE_QUOTED || schema_numbers.any? { |number| number.equal?(scalar) } }
                         .map { |scalar| "line #{scalar.start_line + 1}: #{scalar.value}" }
    end

    # @param tree [Psych::Nodes::Node]
    # @return [Array<String>] "line N: key" for each key a mapping repeats
    def repeated_keys(tree)
      tree.each.grep(Psych::Nodes::Mapping).flat_map do |mapping|
        keys = mapping.children.each_slice(2).map(&:first)
        keys.group_by(&:value).values.select { |same| same.size > 1 }.map { |same| "line #{same.last.start_line + 1}: #{same.last.value}" }
      end
    end

    it 'writes every pattern, replacement, name, guild and setting in single quotes' do
      expect(unquoted_values(document)).to be_empty, -> { "not single-quoted:\n  #{unquoted_values(document).first(10).join("\n  ")}" }
      expect(value_scalars(document).size).to be > 3000
    end

    it 'takes a plain, a double-quoted and a block scalar for unquoted, but not the schema number' do
      tree = Psych.parse(<<~YAML)
        textsubs:
          schema: 1
          sections:
            - name: plain
              when:
                setting: |
                  block
              subs:
                - ["\\\\1", 'ok']
                - [1, 'one']
      YAML
      expect(unquoted_values(tree)).to eq(['line 4: plain', "line 6: block\n", 'line 9: \\1', 'line 10: 1'])
    end

    it 'repeats no key in any mapping' do
      expect(repeated_keys(document)).to be_empty, -> { "repeated keys:\n  #{repeated_keys(document).join("\n  ")}" }
    end

    it 'finds a repeated key, which Psych would load as the last one alone' do
      tree = Psych.parse("textsubs:\n  schema: 1\n  sections:\n    - name: 'a'\n      subs: []\n      name: 'b'\n")
      expect(repeated_keys(tree)).to eq(['line 6: name'])
    end

    it 'uses no anchor, alias or tag, so every sub is written out where it applies' do
      nodes = document.each.to_a
      expect(nodes.grep(Psych::Nodes::Alias)).to be_empty
      expect(nodes.select { |node| node.respond_to?(:anchor) && node.anchor }).to be_empty
      expect(nodes.select { |node| node.respond_to?(:tag) && node.tag }).to be_empty
    end

    it 'gives every section its own name' do
      names = data['sections'].map { |section| section['name'] }
      expect(names.tally.select { |_, count| count > 1 }).to be_empty
    end

    it 'holds only patterns that compile' do
      patterns = data['sections'].flat_map { |section| section.key?('subs') ? section['subs'].map(&:first) : [section['pattern']] }
      broken = patterns.reject do |pattern|
        Regexp.new(pattern)
      rescue RegexpError
        false
      end
      expect(broken).to be_empty
      expect(patterns.size).to be > 1500
    end

    it 'gates the two coin-comma sections, and only them, on the three currency words' do
      gated = data['sections'].select { |section| section.key?('requires_any') }
      expect(gated.to_h { |section| [section['name'], section['requires_any']] })
        .to eq('coin commas with platinum grouping' => %w[Kronar Dokora Lirum], 'coin commas' => %w[Kronar Dokora Lirum])
      expect(gated.flat_map { |section| section['subs'].map(&:first) }).to all(end_with('.*(Kronar|Dokora|Lirum))'))
    end

    it 'is schema 1, the schema this textsubs.lic reads' do
      expect(data['schema']).to eq(TextSubs::Catalog.schema)
    end
  end

  # profiles/base.yaml is where a player looks up what a setting does, and
  # what get_settings answers for a key the player has not set, and the
  # script's own header lists the settings it reads. Every key textsubs reads
  # has to be in both.
  #
  # The keys are found by running the real entry point with get_settings
  # answering a recorder, four ways. The all-on path: once for each of the
  # 96 combinations and once more with no guild known, each with a shit list
  # on disk, integrate_shit_list_with_textsubs on and a private sub; in the
  # run with no guild known TextSubs.watch yields 'Bard', so the block the
  # entry point hands watch runs and builds again with every flag on. The
  # shipped-defaults path: once with textsubs_defaults (which the third
  # example pins to base.yaml: the flags off, private_textsubs nil) and no
  # shit list file, so the branches that run when a setting is off or empty
  # read through the recorder too; watch yields 'Bard' there as well. The
  # error path: a private sub that is not valid regex source, a data/custom
  # copy of the catalog in place of the shipped one, catalog data of an
  # older schema, and a watch that yields no guild and whose rebuild a newer
  # start refuses (TextSubs.reinstall answers false), so the warnings, the
  # override notice, the build message and the refused branch run. After
  # every run a line goes through the 'textsub' hook the run registered,
  # with a front end attached and with none, so a key the hook proc reads
  # for each line is recorded as well.
  #
  # textsubs reads its settings by name (settings.<key>) and by index
  # (settings[key], in Context#setting? for a section's when: gate). The
  # recorder answers those two and dig. Any other call that takes arguments
  # (fetch, a setter, respond_to?) raises, so a new way of reading a key
  # fails here instead of passing by unseen, and one that takes none (to_h,
  # each_pair) is recorded as a key, which base.yaml does not define.
  describe 'the settings textsubs reads' do
    base_profile = YAML.unsafe_load_file(File.expand_path('../profiles/base.yaml', __dir__), freeze: true)
    # A stand-in for the OpenStruct get_settings returns: it answers values
    # (nil for a key values lacks) and adds the name of each key read to read.
    # It is a BasicObject, so a call Object would answer (respond_to?, nil?,
    # inspect, send, public_send) reaches method_missing instead of passing by
    # unrecorded.
    recorder = Class.new(BasicObject) do
      # @param values [Hash{String=>Object}] the value of each key, by name
      # @param read [Array<String>] where each key read is added, shared by
      #   every recorder of one record_reads run
      define_method(:initialize) do |values, read|
        @values = values
        @read = read
      end

      # Reads a key by index, as Context#setting? does for a when: gate.
      #
      # @param key [String, Symbol] the key's name
      # @return [Object, nil] its value, nil when values lacks it
      define_method(:[]) do |key|
        @read << key.to_s
        @values[key.to_s]
      end

      # Reads key, as #[] does, and digs the rest into its value.
      #
      # @param key [String, Symbol] the key's name
      # @param rest [Array<Object>] the keys or indexes inside its value
      # @return [Object, nil] the value found, nil when any step is missing
      define_method(:dig) { |key, *rest| rest.empty? ? self[key] : self[key]&.dig(*rest) }

      # Reads a key by name (settings.<key>), as #[] does.
      #
      # @param name [Symbol] the key's name
      # @param args [Array<Object>] must be empty
      # @return [Object, nil] the key's value, nil when values lacks it
      # @raise [NoMethodError] for any call with arguments (fetch, setters,
      #   respond_to?), so a way of reading a key this recorder cannot see
      #   fails the examples instead of passing by unseen
      define_method(:method_missing) do |name, *args|
        ::Kernel.raise ::NoMethodError, "the settings recorder reads no key through #{name}(...)" unless args.empty?

        self[name]
      end
    end
    reads = nil

    # Runs the real entry point once with get_settings answering a recorder
    # over values, then sends one line through the 'textsub' hook it
    # registered, with a front end attached and with none, so a setting the
    # hook proc reads, on either side of its front-end guard, is recorded
    # too. The hook has to be registered still: DownstreamHook.run removes a
    # hook that raises, as the recorder does for a call it cannot see a key
    # in, and only says so in a line, so a removed hook fails the examples.
    #
    # @param values [Hash{String=>Object}] the value of each setting
    # @param read [Array<String>] where each key read is added
    # @return [void]
    # @raise [RuntimeError] when the hook raised on the line
    define_method(:record_run) do |values, read|
      allow(TOPLEVEL_BINDING.receiver).to receive(:get_settings).and_return(recorder.new(values, read))
      run_lic_entry('textsubs.lic', 'TextSubs')
      [true, false].each do |attached|
        allow(TextSubs).to receive(:client_attached?).and_return(attached)
        run_hooks("You feel fine.\r\n".b)
        next if DownstreamHook.list.include?('textsub')

        raise "the 'textsub' hook raised on a line (front end attached: #{attached}), so what it read there went unrecorded"
      end
    end

    # Runs the real entry point with get_settings answering a recorder, in the
    # ways the comment above describes: the all-on path, the shipped-defaults
    # path, a rebuild for a new guild through watch, and the error path. Each
    # run passes a line through its hook (see record_run).
    #
    # @return [Array<String>] each key read, once
    define_method(:record_reads) do
      read = []
      allow(TextSubs).to receive(:pause)
      with_shit_list("zorvex,stole my kill\n") do
        [{ 'guild' => nil }, *combinations].each do |combination|
          values = combination.except('guild')
                              .merge('integrate_shit_list_with_textsubs' => true, 'private_textsubs' => { 'You feel fine' => 'You feel FINE' })
          # The run with no guild known rebuilds for 'Bard' through watch,
          # so the watch block reads with every flag on too.
          rebuild = receive(:watch)
          rebuild = rebuild.and_yield('Bard') unless combination['guild']
          allow(TextSubs).to rebuild
          DRStats.guild = combination['guild']
          record_run(values, read)
        end
      end
      with_shit_list(nil) do
        allow(TextSubs).to receive(:watch).and_yield('Bard')
        DRStats.guild = nil
        record_run(textsubs_defaults, read)
      end
      # The error path: a private sub that cannot be used, a data/custom copy
      # in place of the shipped data, catalog data of an older schema, and a
      # rebuild for a guild no longer known that a newer start refuses.
      with_shit_list(nil) do
        allow(TextSubs).to receive(:catalog_override).and_return('/nonexistent-textsubs-spec/data/custom/base-textsubs.yaml')
        $test_data[:textsubs] = OpenStruct.new(textsubs: { 'schema' => 0 })
        allow(TextSubs).to receive(:reinstall).and_return(false)
        allow(TextSubs).to receive(:watch).and_yield(nil)
        DRStats.guild = 'Bard'
        record_run(textsubs_defaults.merge('private_textsubs' => { '(' => 'x' }), read)
      end
      read.uniq
    end
    # Made once, by whichever example asks first.
    let(:read) { reads ||= record_reads }

    it 'reads exactly the keys textsubs_defaults lists' do
      expect(read).to match_array(textsubs_defaults.keys)
    end

    it 'defines every settings key textsubs reads, and reads every textsubs key base.yaml defines' do
      expect(read.reject { |key| base_profile.key?(key) }).to be_empty
      expect(base_profile.keys.grep(/textsubs/) - read).to be_empty
    end

    it 'ships each of those keys with the value the specs build a default catalog with' do
      expect(base_profile.slice(*read)).to eq(textsubs_defaults)
    end

    it "lists every one of them in the script's =begin header, each as a key - what it does line" do
      header = File.read(File.expand_path('../textsubs.lic', __dir__))[/^=begin\n(.*?)^=end\n/m, 1]
      expect(read.reject { |key| header.match?(/^ +#{key} - \S/) }).to be_empty
    end
  end

  # Lich's Script splits a script into goto labels at every line that is a
  # word and a colon alone (/^(\w+):$/), with no regard for =begin blocks, so
  # a 'Settings:' line in the header would start a label. The check is broader
  # than Lich's, indented and with trailing spaces, so a reindent or an
  # editor cannot turn a near miss into one.
  describe 'textsubs.lic source' do
    it 'has no line Lich would read as a label' do
      lines = File.readlines(File.expand_path('../textsubs.lic', __dir__)).each_with_index
      expect(lines.filter_map { |line, index| "#{index + 1}: #{line.strip}" if line.match?(/^\s*\w+:\s*$/) }).to be_empty
    end
  end

  describe 'settings gating' do
    flags = %w[textsubs_spell_links herb_textsubs textsubs_use_plat_grouping]

    # The one contiguous run where two catalogs part: what only `off` holds
    # there and what only `on` holds there. Everything before and after the run
    # is identical in both, so a flag that touched two separate places would
    # show the untouched entries between them in both :removed and :added.
    #
    # @param off [Array<Array>] catalog with the flag off
    # @param on [Array<Array>] catalog with the flag on
    # @return [Hash{Symbol=>Array<Array>}] :removed and :added entries
    def changed_run(off, on)
      prefix = off.zip(on).take_while { |a, b| a == b }.size
      room = [off.size, on.size].min - prefix
      suffix = off.reverse.zip(on.reverse).first(room).take_while { |a, b| a == b }.size
      { removed: off[prefix...(off.size - suffix)], added: on[prefix...(on.size - suffix)] }
    end

    # Builds `guild`'s catalog with `flag` off and then on, the other two flags
    # held at `others`. Defined with define_method so the body sees `flags`.
    #
    # @param guild [String]
    # @param flag [String] the flag to toggle
    # @param others [Boolean] the value of the other two flags
    # @return [Hash{Symbol=>Array<Array>}] changed_run for toggling `flag`
    define_method(:toggle) do |guild, flag, others:|
      base = (flags - [flag]).to_h { |other| [other, others] }
      changed_run(build_catalog(guild, base.merge(flag => false)), build_catalog(guild, base.merge(flag => true)))
    end

    it 'textsubs_spell_links inserts one block of Elanthipedia links and removes nothing' do
      run = toggle('Trader', 'textsubs_spell_links', others: false)
      expect(run[:removed]).to eq([])
      expect(run[:added]).not_to be_empty
      expect(run[:added].map(&:last)).to all(include('<a href="https://elanthipedia.play.net/'))
    end

    # A herb's annotation repeats the herb's name, or writes \0 (the matched
    # text) where the key takes more than one form ('jadice flowers?').
    it 'herb_textsubs inserts one block of "<herb> (<area>)" annotations and removes nothing' do
      run = toggle('Trader', 'herb_textsubs', others: false)
      expect(run[:removed]).to eq([])
      expect(run[:added]).not_to be_empty
      expect(run[:added]).to all(satisfy { |source, _options, replacement|
        replacement.start_with?("#{source} (", '\0 (')
      })
    end

    it 'textsubs_use_plat_grouping swaps the one coin-comma rule for two platinum-aware ones' do
      run = toggle('Trader', 'textsubs_use_plat_grouping', others: false)
      expect(run[:removed].size).to eq(1)
      expect(run[:added].size).to eq(2)
      expect((run[:removed] + run[:added]).map(&:last)).to all(eq('\\&,'))
      expect(run[:removed].first.first).not_to include('platinum')
      expect(run[:added].map(&:first)).to all(include('platinum'))
    end

    flags.each do |flag|
      it "#{flag} changes the same entries when the other two flags are on" do
        expect(toggle('Empath', flag, others: true)).to eq(toggle('Empath', flag, others: false))
      end
    end

    flags.each do |flag|
      it "treats #{flag} unset (nil, as a key written with no value gives) like false" do
        others = (flags - [flag]).to_h { |other| [other, false] }
        expect(build_catalog('Cleric', others.merge(flag => nil))).to eq(build_catalog('Cleric', others.merge(flag => false)))
      end
    end

    it 'links the guild spell list to the guild category only with textsubs_spell_links on' do
      sources = build_catalog('Moon Mage', 'textsubs_spell_links' => true).map(&:last)
      expect(sources).to include(a_string_including('Category:Moon_Mage_spells">Moon Mage</a> training.'))
      expect(build_catalog('Moon Mage', 'textsubs_spell_links' => false).map(&:last))
        .not_to include(a_string_including('Category:Moon_Mage_spells'))
    end
  end

  describe 'shit list' do
    # Builds the Commoner catalog with "<checkname>_shit.list" holding the
    # given content (or no file when nil); see with_shit_list.
    #
    # @param content [String, nil] the shit-list file body
    # @param integrate [Boolean] integrate_shit_list_with_textsubs
    # @return [Array<Array>] the catalog built
    def catalog_with_shit_list(content, integrate:)
      with_shit_list(content) { build_catalog('Commoner', 'integrate_shit_list_with_textsubs' => integrate) }
    end

    let(:plain_catalog) { build_catalog('Commoner') }

    it 'adds a capitalized "(SL)" entry per name, ahead of the built-in catalog' do
      catalog = catalog_with_shit_list("zorvex,stole my kill\nqUIMBLE,spammer\n", integrate: true)
      expect(catalog.first(2)).to eq([['\\bZorvex\\b', 0, 'Zorvex (SL)'], ['\\bQuimble\\b', 0, 'Quimble (SL)']])
      expect(catalog.drop(2)).to eq(plain_catalog)
    end

    it 'adds nothing when integrate_shit_list_with_textsubs is off, even with a file present' do
      expect(catalog_with_shit_list("zorvex,stole my kill\n", integrate: false)).to eq(plain_catalog)
    end

    it 'adds nothing, and does not fail, when the flag is on but the file is missing' do
      expect(catalog_with_shit_list(nil, integrate: true)).to eq(plain_catalog)
    end

    it 'skips a blank line, a line of spaces and a note with no name, keeping the names around them' do
      catalog = catalog_with_shit_list("zorvex,stole my kill\n\n \t \n, no name here\nquimble,spammer\n\n", integrate: true)
      expect(catalog.first(2)).to eq([['\\bZorvex\\b', 0, 'Zorvex (SL)'], ['\\bQuimble\\b', 0, 'Quimble (SL)']])
      expect(catalog.drop(2)).to eq(plain_catalog)
    end

    context 'with lines sent through the hook' do
      include_context 'with a front end attached'

      it 'leaves a line naming nobody alone when the file has empty lines and an empty name' do
        catalog_with_shit_list("\n   \r\n, note\nzorvex\n", integrate: true)
        expect(run_hooks("You feel fine.\r\n".b)).to eq("You feel fine.\r\n")
        expect(run_hooks("Zorvex waves.\r\n".b)).to eq("Zorvex (SL) waves.\r\n")
      end

      it 'tags a name written with no comma, whatever the line ending' do
        catalog_with_shit_list("bob\nquimble\r\nzorvex", integrate: true)
        expect(run_hooks("Bob just arrived.\r\n".b)).to eq("Bob (SL) just arrived.\r\n")
        expect(run_hooks("Quimble just arrived.\r\n".b)).to eq("Quimble (SL) just arrived.\r\n")
        expect(run_hooks("Zorvex just arrived.\r\n".b)).to eq("Zorvex (SL) just arrived.\r\n")
      end

      it 'tags a name only as a whole word' do
        catalog_with_shit_list("bob,stole my kill\n", integrate: true)
        expect(run_hooks("Bobby and McBob just arrived.\r\n".b)).to eq("Bobby and McBob just arrived.\r\n")
        expect(run_hooks("Bob's friend Bobby waves to Bob.\r\n".b)).to eq("Bob (SL)'s friend Bobby waves to Bob (SL).\r\n")
      end

      it 'matches a name as plain text, so a regex character in it stands for itself' do
        catalog_with_shit_list("o.k,odd name\n", integrate: true)
        expect(run_hooks("Oxk waves.\r\n".b)).to eq("Oxk waves.\r\n")
        expect(run_hooks("O.k waves.\r\n".b)).to eq("O.k (SL) waves.\r\n")
      end

      it 'still tags the other names when a hand edit left a byte that is not UTF-8' do
        catalog = catalog_with_shit_list("#{0xE9.chr}lise,note\nbob\nzorvex,stole my kill\n", integrate: true)
        expect(catalog.first(3).map(&:last)).to eq(["#{0xE9.chr}lise (SL)", 'Bob (SL)', 'Zorvex (SL)'])
        expect(run_hooks("Bob just arrived.\r\n".b)).to eq("Bob (SL) just arrived.\r\n")
        expect(run_hooks("Zorvex just arrived.\r\n".b)).to eq("Zorvex (SL) just arrived.\r\n")
      end

      it 'drops a UTF-8 byte order mark in front of the first name' do
        catalog = catalog_with_shit_list("#{[0xEF, 0xBB, 0xBF].pack('C*')}bob,stole my kill\nzorvex\n", integrate: true)
        expect(catalog.first(2).map(&:last)).to eq(['Bob (SL)', 'Zorvex (SL)'])
        expect(run_hooks("Bob just arrived.\r\n".b)).to eq("Bob (SL) just arrived.\r\n")
      end
    end
  end

  describe 'private_textsubs' do
    include_context 'with a front end attached'

    # A built-in sub every guild gets, some way into the catalog.
    durability = 'Assessing the (.*) durability, you determine (it is|is|they are|are) extremely weak and easily damaged'

    it 'adds each private pair, in order, ahead of the built-in catalog, saying nothing' do
      private_subs = { 'You feel fine' => 'You feel FINE', 'a (\w+) widget' => 'a \1 gadget' }
      catalog = build_catalog('Commoner', 'private_textsubs' => private_subs)
      expect(displayed_messages).to be_empty
      expect(catalog.first(2)).to eq([['You feel fine', 0, 'You feel FINE'], ['a (\w+) widget', 0, 'a \1 gadget']])
      expect(catalog.drop(2)).to eq(build_catalog('Commoner'))
    end

    it 'compiles each private key with a one-second match timeout, and no built-in key' do
      build_catalog('Commoner', 'private_textsubs' => { 'You feel fine' => 'You feel FINE' })
      keys = TextSubs.subs.keys
      expect(keys.first).to eq(/You feel fine/)
      expect(keys.first.timeout).to eq(1.0)
      expect(keys.drop(1).map(&:timeout).uniq).to eq([nil])
    end

    it 'adds nothing and says nothing when private_textsubs is unset, as base.yaml leaves it (nil)' do
      catalog = build_catalog('Commoner', 'private_textsubs' => nil)
      said = displayed_messages.dup
      expect(DownstreamHook.list).to include('textsub')
      expect(said).to be_empty
      expect(catalog).to eq(build_catalog('Commoner'))
    end

    # Each bad entry sits beside a good one, and the line sent through the
    # hook holds text the bad key matches, so a bad entry that got in would
    # either corrupt the line or raise in the hook.
    {
      'a blank value (Bob:)'           => [{ 'Bob' => nil }, 'Bob waves.',
                                           "private_textsubs \"Bob\" is skipped: its replacement is empty (nil); write '' to delete the text it matches."],
      'an Integer value (health: 100)' => [{ 'health' => 100 }, 'Your health is good.',
                                           'private_textsubs "health" is skipped: its replacement 100 is an Integer, not a quoted string; quote the replacement in your YAML.'],
      'a key that is not valid regex'  => [{ '(' => 'y' }, 'You smile (warmly).',
                                           'private_textsubs "(" is skipped: it is not a valid regex (end pattern with unmatched parenthesis: /(/).'],
      'a key YAML reads as an Integer' => [{ 100 => 'a hundred' }, 'You count 100 coins.',
                                           'private_textsubs 100 is skipped: it is an Integer, not a quoted string; quote it in your YAML.'],
      'an empty key'                   => [{ '' => '-' }, 'Bob waves.',
                                           'private_textsubs "" is skipped: an empty pattern matches between every two characters of every line.']
    }.each do |label, (bad, line, warning)|
      it "skips #{label} with one warning, keeps the good entry first, and keeps the hook on a line the key matches" do
        catalog = build_catalog('Commoner', 'private_textsubs' => bad.merge('You feel fine' => 'You feel FINE'))

        expect(displayed_messages).to eq([warning])
        expect(DownstreamHook.list).to include('textsub')
        expect(run_hooks("#{line} You feel fine.\r\n".b)).to eq("#{line} You feel FINE.\r\n")
        expect(DownstreamHook.list).to include('textsub')
        expect(displayed_messages).to eq([warning])
        expect(catalog.first).to eq(['You feel fine', 0, 'You feel FINE'])
        expect(catalog.drop(1)).to eq(build_catalog('Commoner'))
      end
    end

    {
      'a String'                             => ['Bob', 'private_textsubs is a String'],
      'a list, which YAML gives for - lines' => [%w[Bob Alice], 'private_textsubs is an Array']
    }.each do |label, (value, warning)|
      it "ignores a private_textsubs that is #{label}, not a mapping, with one warning" do
        catalog = build_catalog('Commoner', 'private_textsubs' => value)
        expect(displayed_messages).to eq(["#{warning}, not a mapping of 'old text': 'new text'; it is ignored."])
        expect(DownstreamHook.list).to include('textsub')
        expect(catalog).to eq(build_catalog('Commoner'))
      end
    end

    describe 'a key that is also a built-in sub' do
      it 'keeps the private slot and the private value, and says so once' do
        plain = build_catalog('Commoner')
        expect(plain.index { |source, _, _| source == durability }).to be > 10

        catalog = build_catalog('Commoner', 'private_textsubs' => { durability => 'MINE: \1 (1/18)' })

        expect(catalog.first).to eq([durability, 0, 'MINE: \1 (1/18)'])
        expect(catalog.drop(1)).to eq(plain.reject { |source, _, _| source == durability })
        expect(TextSubs.subs.keys.first.timeout).to eq(1.0)
        expect(displayed_messages).to eq(["private_textsubs #{durability.inspect} is also a built-in sub; " \
                                          'your replacement is used instead of the built-in one.'])
        line = "Assessing the sword durability, you determine it is extremely weak and easily damaged.\r\n".b
        expect(run_hooks(line)).to eq("MINE: sword (1/18).\r\n")
      end

      it 'says nothing when the private replacement is the built-in one' do
        builtin = build_catalog('Commoner').find { |source, _, _| source == durability }.last
        catalog = build_catalog('Commoner', 'private_textsubs' => { durability => builtin })
        expect(catalog.first).to eq([durability, 0, builtin])
        expect(displayed_messages).to be_empty
      end
    end

    # A YAML key written as !ruby/regexp /.../i arrives as a Regexp, which
    # YAML.unsafe_load gives with its flags.
    describe 'a !ruby/regexp key' do
      it 'is added with its flags and the timeout, saying nothing, and rewrites a line in any case through the hook' do
        plain = build_catalog('Commoner')

        catalog = build_catalog('Commoner', 'private_textsubs' => { /you feel fine/i => 'MINE' })

        expect(displayed_messages).to be_empty
        expect(catalog.first).to eq(['you feel fine', Regexp::IGNORECASE, 'MINE'])
        expect(catalog.drop(1)).to eq(plain)
        key = TextSubs.subs.keys.first
        expect(key.timeout).to eq(1.0)
        line = "YOU Feel FINE.\r\n".b
        expect(TextSubs::TokenIndex.new(TextSubs.subs.keys).candidates(line)).to include(key)
        expect(TextSubs.apply(line.dup)).to eq("MINE.\r\n")
        expect(run_hooks(line)).to eq("MINE.\r\n")
      end

      # Regexp#== compares the flags, so /source/i is a key of its own beside
      # the built-in /source/: both stay in the catalog and both run, the
      # private one first, as they did when a key was interpolated whole.
      it 'with a flag is not the built-in key of the same source: both run, the private one first, saying nothing' do
        plain = build_catalog('Commoner')
        builtin = plain.find { |source, _, _| source == durability }

        catalog = build_catalog('Commoner', 'private_textsubs' => { Regexp.new(durability, Regexp::IGNORECASE) => 'MINE: \1' })

        expect(displayed_messages).to be_empty
        expect(catalog.first).to eq([durability, Regexp::IGNORECASE, 'MINE: \1'])
        expect(catalog.drop(1)).to eq(plain)
        expect(catalog).to include(builtin)
        line = "ASSESSING the sword durability, you determine it is extremely weak and easily damaged.\r\n".b
        expect(run_hooks(line)).to eq("MINE: sword.\r\n")
        line = "Assessing the sword durability, you determine it is extremely weak and easily damaged.\r\n".b
        expect(run_hooks(line)).to eq("MINE: sword.\r\n")
      end

      it 'without a flag is the built-in key of the same source: it keeps the private slot and value, and says so once' do
        plain = build_catalog('Commoner')

        catalog = build_catalog('Commoner', 'private_textsubs' => { Regexp.new(durability) => 'MINE: \1' })

        expect(catalog.first).to eq([durability, 0, 'MINE: \1'])
        expect(catalog.drop(1)).to eq(plain.reject { |source, _, _| source == durability })
        expect(displayed_messages).to eq(["private_textsubs #{Regexp.new(durability).inspect} is also a built-in sub; " \
                                          'your replacement is used instead of the built-in one.'])
      end

      # YAML gives !ruby/regexp /text/n as Regexp::NOENCODING. On an ASCII-only
      # source that is the same Regexp as the flagless key (== and #hash
      # agree), so it is the built-in key, not a key of its own like /i.
      it 'with only /n on an ASCII source is the built-in key of the same source: it keeps the private slot and value, and says so once' do
        plain = build_catalog('Commoner')
        key = Regexp.new(durability, Regexp::NOENCODING)

        catalog = build_catalog('Commoner', 'private_textsubs' => { key => 'MINE: \1' })

        expect(catalog.first).to eq([durability, Regexp::NOENCODING, 'MINE: \1'])
        expect(catalog.drop(1)).to eq(plain.reject { |source, _, _| source == durability })
        expect(displayed_messages).to eq(["private_textsubs /#{durability}/n is also a built-in sub; " \
                                          'your replacement is used instead of the built-in one.'])
      end
    end

    # A quoted key compiles with no flags, so it is the same Regexp as a
    # flagless !ruby/regexp key of the same source: the catalog can hold only
    # one of them, and the first one written is the one kept.
    describe 'a quoted key and a flagless !ruby/regexp key of the same source' do
      it 'keeps the first one, skips the other naming both, and gives nothing else a message' do
        plain = build_catalog('Commoner')

        catalog = build_catalog('Commoner', 'private_textsubs' => { 'zorvexqq' => 'A', /zorvexqq/ => 'B' })

        expect(catalog.first).to eq(['zorvexqq', 0, 'A'])
        expect(catalog.drop(1)).to eq(plain)
        expect(displayed_messages).to eq(['private_textsubs /zorvexqq/ is skipped: it is the same pattern as "zorvexqq", which is used instead.'])
      end

      it 'keeps the first one written when the !ruby/regexp key comes first' do
        plain = build_catalog('Commoner')

        catalog = build_catalog('Commoner', 'private_textsubs' => { /zorvexqq/ => 'B', 'zorvexqq' => 'A' })

        expect(catalog.first).to eq(['zorvexqq', 0, 'B'])
        expect(catalog.drop(1)).to eq(plain)
        expect(displayed_messages).to eq(['private_textsubs "zorvexqq" is skipped: it is the same pattern as /zorvexqq/, which is used instead.'])
      end

      it 'says once that the kept one replaces a built-in sub of that source, naming it as written' do
        plain = build_catalog('Commoner')

        catalog = build_catalog('Commoner', 'private_textsubs' => { Regexp.new(durability) => 'MINE: \1', durability => 'OTHER: \1' })

        expect(catalog.first).to eq([durability, 0, 'MINE: \1'])
        expect(catalog.drop(1)).to eq(plain.reject { |source, _, _| source == durability })
        expect(displayed_messages).to eq(["private_textsubs #{durability.inspect} is skipped: it is the same pattern as " \
                                          "#{Regexp.new(durability).inspect}, which is used instead.",
                                          "private_textsubs #{Regexp.new(durability).inspect} is also a built-in sub; " \
                                          'your replacement is used instead of the built-in one.'])
      end
    end

    it 'puts shit-list entries before private ones' do
      settings = { 'integrate_shit_list_with_textsubs' => true, 'private_textsubs' => { 'You feel fine' => 'You feel FINE' } }
      catalog = with_shit_list("zorvex,reason\n") { build_catalog('Commoner', settings) }
      expect(catalog.first(2)).to eq([['\\bZorvex\\b', 0, 'Zorvex (SL)'], ['You feel fine', 0, 'You feel FINE']])
    end
  end

  # get_data answers a missing data/base-textsubs.yaml and one that did not
  # parse alike (lich-5 SetupFiles: no cache entry, or {} after printing the
  # parse error), with an OpenStruct that has no textsubs key.
  describe 'catalog data it cannot use' do
    include_context 'with a front end attached'

    shipped = lambda do
      Marshal.load(Marshal.dump(shipped_catalog))
    end
    stale = shipped.call.tap { |copy| copy['textsubs']['schema'] = 2 }
    unknown_kind = shipped.call.tap { |copy| copy['textsubs']['sections'].last['kind'] = 'ladder' }
    {
      'a missing file or one that did not parse' => [OpenStruct.new, /no 'textsubs:' mapping/],
      'a file from another schema'               => [OpenStruct.new(stale), /schema 2, but this textsubs.lic reads schema 1/],
      'a section of an unknown kind'             => [OpenStruct.new(unknown_kind), /has unknown kind "ladder"/]
    }.each do |label, (answer, reason)|
      context "with #{label}" do
        # Starts textsubs with one shit-list name and one private sub.
        #
        # @return [Array<Array>] the catalog built
        def start_with_shit_list_and_private_sub
          Dir.mktmpdir('textsubs-bad-catalog') do |dir|
            File.write(File.join(dir, "#{checkname}_shit.list"), "zorvex,stole my kill\n")
            Dir.chdir(dir) do
              build_catalog('Bard', 'integrate_shit_list_with_textsubs' => true, 'textsubs_spell_links' => true,
                                    'private_textsubs' => { 'You feel fine' => 'You feel FINE' })
            end
          end
        end

        before { $test_data[:textsubs] = answer }

        it 'says once that it adds no built-in sub, naming the file, why and the schema it needs' do
          start_with_shit_list_and_private_sub
          expect($data_called_with).to eq(['textsubs'])
          said = displayed_messages.grep(/built-in subs/)
          expect(said.size).to eq(1)
          expect(said.first).to start_with('No built-in subs: /nonexistent-textsubs-spec/data/base-textsubs.yaml cannot be used (')
          expect(said.first).to match(reason)
          expect(said.first).to include("needs a 'textsubs:' mapping with schema: 1")
          expect(said.first).to end_with('Only private_textsubs and shit-list subs are active.')
        end

        it 'keeps the shit-list and private subs, adds nothing else, and still registers the hook' do
          expect(start_with_shit_list_and_private_sub).to eq([['\\bZorvex\\b', 0, 'Zorvex (SL)'], ['You feel fine', 0, 'You feel FINE']])
          expect(DownstreamHook.list).to include('textsub')
          expect(run_hooks("You feel fine, Zorvex.\r\n".b)).to eq("You feel FINE, Zorvex (SL).\r\n")
        end
      end
    end

    it 'says nothing about the catalog when the shipped file is good' do
      build_catalog('Commoner')
      expect(displayed_messages).to be_empty
    end

    describe 'a copy in data/custom' do
      around do |example|
        Dir.mktmpdir('textsubs-script-dir') do |dir|
          @custom = File.join(dir, 'data', 'custom', 'base-textsubs.yaml')
          FileUtils.mkdir_p(File.dirname(@custom))
          # A real copy of the shipped file. get_data is stubbed, so the
          # script only checks that this file exists; what it builds comes
          # from $test_data, which each example sets.
          FileUtils.cp(catalog_path, @custom)
          @script_dir = dir
          example.run
        end
      end

      before { stub_const('SCRIPT_DIR', @script_dir) }

      it 'says once that it reads the copy, and builds the catalog get_data gives' do
        from_copy = build_catalog('Commoner')
        expect(displayed_messages).to eq(
          ["Reading the built-in subs from #{@custom}, which replaces data/base-textsubs.yaml " \
           "(it must be a 'textsubs:' mapping with schema: 1)."]
        )

        stub_const('SCRIPT_DIR', '/nonexistent-textsubs-spec')
        expect(from_copy).to eq(build_catalog('Commoner'))
        expect(from_copy.size).to be > 700
      end

      it 'names the copy, not the shipped file, when the copy cannot be used' do
        $test_data[:textsubs] = OpenStruct.new(textsubs: nil)
        expect(build_catalog('Commoner')).to eq([])
        expect(displayed_messages.last).to start_with("No built-in subs: #{@custom} cannot be used (no 'textsubs:' mapping")
      end
    end
  end

  describe "the 'textsub' hook" do
    include_context 'with a front end attached'

    it "registers 'textsub', and the registered hook applies the catalog" do
      build_catalog('Commoner', 'private_textsubs' => { 'You feel fine' => 'You feel FINE' })
      expect(DownstreamHook.list).to include('textsub')
      expect(run_hooks("You feel fine today.\n".b)).to eq("You feel FINE today.\n")
    end

    it 'hands each line to TextSubs.apply and passes on what it returns' do
      build_catalog('Commoner')
      line = "You feel fine.\r\n".b
      allow(TextSubs).to receive(:apply).and_return("rewritten\r\n".b)

      expect(run_hooks(line)).to eq("rewritten\r\n")
      expect(TextSubs).to have_received(:apply).with(line).once
    end

    it "registers 'textsub' with persist: false, leaving its removal to Lich alone: its before_dying keeps every hook" do
      # Stubbed on main (where run_lic_entry evaluates the entry), not on
      # Script.at_exit: another spec replaces the top-level before_dying.
      dying = []
      allow(TOPLEVEL_BINDING.receiver).to(receive(:before_dying)) { |&block| dying << block }
      DownstreamHook.add('other-script', proc { |line| line })
      build_catalog('Commoner')
      dying.each(&:call)

      expect(dying.size).to eq(1)
      expect(DownstreamHook._hook_persist).to include('textsub' => false)
      expect(DownstreamHook.list).to include('textsub', 'other-script')
    ensure
      DownstreamHook.remove('other-script')
    end

    it 'stages a fresh Registry, installs it once the whole catalog is in it, and registers the hook once, last' do
      TextSubs.add('stale', 'left over from the run before')
      events = []
      allow(TextSubs).to(receive(:stage).and_wrap_original do |original, registry|
        events << [:stage, registry, registry.snapshot]
        original.call(registry)
      end)
      allow(TextSubs).to(receive(:install).and_wrap_original do |original, registry|
        events << [:install, registry, registry.snapshot]
        original.call(registry)
      end)
      allow(DownstreamHook).to(receive(:add).and_wrap_original do |original, name, action, **options|
        events << [:hook, name, options, TextSubs.subs]
        original.call(name, action, **options)
      end)

      catalog = build_catalog('Commoner', 'private_textsubs' => { 'You feel fine' => 'You feel FINE' })

      expect(events.map(&:first)).to eq(%i[stage install hook])
      (_, staged, staged_subs), (_, installed, installed_subs), (_, name, options, subs_at_hook) = events
      expect(staged_subs).to eq({})
      expect(installed).to equal(staged)
      expect(installed_subs.map { |pattern, replacement| [pattern.source, pattern.options, replacement] }).to eq(catalog)
      expect([name, options]).to eq(['textsub', { persist: false, priority: -100 }])
      expect(subs_at_hook).to equal(installed_subs)
      expect(catalog.map(&:first)).not_to include('stale')
    end

    it 'builds in a staged Registry, so a hook still registered applies the installed catalog whole until install' do
      build_catalog('Ranger', 'herb_textsubs' => true)
      old_catalog = TextSubs.subs
      lines = ["You pick some nilos.\r\n", "You feel fine.\r\n"]
      old_output = ["You pick some nilos (abdo-EW).\r\n", "You feel fine.\r\n"]
      partial = []
      seen = []
      writes = 0
      # The old run's 'textsub' hook stays registered until the new run
      # registers its own, as when Lich has not yet removed the hook of a run
      # that is being stopped. The class body is not evaluated again here, so
      # the installed catalog is still the old run's; that isolates what the
      # staging alone guarantees (the restart Lich runs, which re-runs the
      # class body, is covered under 'a start in Lich, which evaluates the
      # class body before the entry point'). After every write, subs has to be
      # the old catalog itself, and every 250th write sends the lines through it.
      observer = lambda do |key, _value, _gate, _registry|
        partial << key.source unless TextSubs.subs.equal?(old_catalog)
        seen << lines.map { |line| run_hooks(line.b) } if (writes += 1) % 250 == 1
      end

      on_registry_write(observer) do
        build_catalog('Ranger', 'herb_textsubs' => false, 'private_textsubs' => { 'You feel fine' => 'You feel FINE' })
      end

      expect(writes).to be > 500
      expect(partial).to be_empty, -> { "the old hook saw a catalog of the new run after writing #{partial.first.inspect}" }
      expect(seen.size).to be > 3
      expect(seen).to all(eq(old_output))
      expect(lines.map { |line| run_hooks(line.b) }).to eq(["You pick some nilos.\r\n", "You feel FINE.\r\n"])
    end

    it 'registers no hook until the catalog is installed, so a line passes through untouched while it is built' do
      # No 'textsub' hook is registered, but the installed catalog rewrites
      # the line, so a hook the new run registered before its build was done
      # would apply that catalog to it (and, filling the installed catalog,
      # its private key). Sends the line through the hooks right after the
      # private key is staged, and after every 250th write from then on.
      TextSubs.add('You feel fine', 'You feel OLD')
      expect(TextSubs.apply(+"You feel fine.\r\n")).to eq("You feel OLD.\r\n")
      seen = []
      writes = 0
      observer = lambda do |key, _value, _gate, _registry|
        writes += 1 unless seen.empty? && key.source != 'You feel fine'
        seen << run_hooks("You feel fine.\r\n".b) if writes % 250 == 1
      end

      on_registry_write(observer) { build_catalog('Commoner', 'private_textsubs' => { 'You feel fine' => 'You feel FINE' }) }

      expect(seen.size).to be > 3
      expect(seen).to all(eq("You feel fine.\r\n"))
      expect(run_hooks("You feel fine.\r\n".b)).to eq("You feel FINE.\r\n")
    end

    it 'leaves one hook that applies the new catalog after a restart with other settings' do
      build_catalog('Ranger', 'herb_textsubs' => true)
      expect(run_hooks("You pick some nilos.\r\n".b)).to eq("You pick some nilos (abdo-EW).\r\n")

      build_catalog('Ranger', 'herb_textsubs' => false)
      expect(DownstreamHook.list.count('textsub')).to eq(1)
      expect(run_hooks("You pick some nilos.\r\n".b)).to eq("You pick some nilos.\r\n")
    end

    # Other scripts register hooks that read or squelch lines, almost always
    # at the default priority of 0, and they must match the server's text, not
    # textsubs' rewrite of it, whichever script started first.
    describe 'beside the hooks of other scripts' do
      # Registers a hook named name that records each line it is handed and
      # passes it on unchanged.
      #
      # @param name [String] the hook name
      # @param options [Hash] persist:/priority: for DownstreamHook.add
      # @return [Array<String>] the lines the hook has seen, filled as they come
      def add_reader(name, **options)
        [].tap { |seen| DownstreamHook.add(name, proc { |line| seen << line.dup; line }, **options) }
      end

      # Starts textsubs with "Bob" on the shit list, as integrate_shit_list_with_textsubs reads it.
      #
      # @return [void]
      def start_textsubs_with_bob_on_the_shit_list
        Dir.mktmpdir('textsubs-hook-priority') do |dir|
          File.write(File.join(dir, "#{checkname}_shit.list"), "bob,stole my kill\n")
          Dir.chdir(dir) { build_catalog('Commoner', 'integrate_shit_list_with_textsubs' => true) }
        end
      end

      after do
        %w[reader-started-before reader-started-after reader-below].each { |name| DownstreamHook.remove(name) }
      end

      it 'runs after a default-priority hook registered after it, and before one below -100' do
        before_reader = add_reader('reader-started-before')
        start_textsubs_with_bob_on_the_shit_list
        after_reader = add_reader('reader-started-after')
        below_reader = add_reader('reader-below', priority: -101)

        expect(run_hooks("Bob just arrived.\r\n".b)).to eq("Bob (SL) just arrived.\r\n")
        expect(before_reader).to eq(["Bob just arrived.\r\n"])
        expect(after_reader).to eq(["Bob just arrived.\r\n"])
        expect(below_reader).to eq(["Bob (SL) just arrived.\r\n"])
      end

      # A re-registered name keeps its first position among equal priorities
      # (lich-5 HookRegistry), so a textsubs started while the old one's hook
      # is still there inherits that hook's place ahead of a reader added
      # since; one started after Lich removed it lands behind every hook.
      it 'still runs last after a restart, whether it replaced its old hook or Lich removed that first' do
        start_textsubs_with_bob_on_the_shit_list
        reader = add_reader('reader-started-after')

        start_textsubs_with_bob_on_the_shit_list
        expect(run_hooks("Bob just arrived.\r\n".b)).to eq("Bob (SL) just arrived.\r\n")
        expect(reader).to eq(["Bob just arrived.\r\n"])

        DownstreamHook.remove('textsub')
        start_textsubs_with_bob_on_the_shit_list
        expect(run_hooks("Bob waves.\r\n".b)).to eq("Bob (SL) waves.\r\n")
        expect(reader).to eq(["Bob just arrived.\r\n", "Bob waves.\r\n"])
      end

      it 'never hands a line a default-priority hook squelched to TextSubs.apply' do
        start_textsubs_with_bob_on_the_shit_list
        DownstreamHook.add('reader-started-after', proc { |line| line.start_with?('Bob') ? nil : line })
        allow(TextSubs).to receive(:apply).and_call_original

        expect(run_hooks("Bob just arrived.\r\n".b)).to be_nil
        expect(TextSubs).not_to have_received(:apply)
        expect(run_hooks("You feel fine.\r\n".b)).to eq("You feel fine.\r\n")
        expect(TextSubs).to have_received(:apply).once
      end
    end

    it "ends by watching 'textsub', once, after the hook is registered, as the run its start_run token stands for" do
      events = []
      tokens = []
      allow(DownstreamHook).to(receive(:add).and_wrap_original do |original, name, *args, **options|
        events << [:hook, name]
        original.call(name, *args, **options)
      end)
      staged = []
      allow(TextSubs).to(receive(:start_run).and_wrap_original { |original| original.call.tap { |token| tokens << token } })
      allow(TextSubs).to(receive(:stage).and_wrap_original { |original, registry| original.call(registry).tap { |built| staged << built } })
      allow(TextSubs).to receive(:watch) { |hook, **options| events << [:watch, hook, options] }

      build_catalog('Commoner')

      expect(tokens.size).to eq(1)
      # The token keeps no catalog alive: it is not the Registry the start built.
      expect(staged.size).to eq(1)
      expect(tokens.first).not_to equal(staged.first)
      expect(events).to eq([[:hook, 'textsub'], [:watch, 'textsub', { guild: 'Commoner', run: tokens.first }]])
    end

    it 'ends the script, saying so, once Lich removes the hook because it raised' do
      allow(TextSubs).to receive(:watch).and_call_original
      allow(TextSubs).to receive(:apply).and_raise(ArgumentError, 'invalid byte sequence')
      pauses = 0
      # Each poll sends a line through the hooks, as the game would between
      # two polls: the first one raises, and Lich removes the hook.
      allow(TextSubs).to receive(:pause) do
        pauses += 1
        raise 'TextSubs.watch kept waiting after the hook was gone' if pauses > 3

        run_hooks("You feel fine.\r\n".b)
      end

      build_catalog('Commoner')

      expect(pauses).to eq(1)
      expect(DownstreamHook.list).not_to include('textsub')
      expect(displayed_messages.grep(/--- Lich: DownstreamHook: invalid byte sequence/).size).to eq(1)
      expect(displayed_messages.last).to start_with("The 'textsub' hook is gone")
    end

    # DownstreamHook.run removes a hook that raises, for good, and every sub
    # goes with it. A sub that raises is the one thing dropped instead.
    describe 'a sub that raises' do
      # @param source [String] the key's regex source, as added
      # @return [Array<String>] the messages that report that key
      def reports_of(source)
        displayed_messages.select { |message| message.include?("the sub #{Regexp.new(source).source.inspect} raised") }
      end

      # @return [Array<String>] Lich's own reports of a hook it removed
      def lich_removals
        displayed_messages.grep(/--- Lich: DownstreamHook/)
      end

      it 'drops a nil-valued key, keeps the hook and the other subs on the line, and reports it once' do
        build_catalog('Commoner', 'private_textsubs' => { 'You feel fine' => 'You feel FINE' })
        TextSubs.add('foo', nil)

        expect(run_hooks("You feel fine, foo.\r\n".b)).to eq("You feel FINE, foo.\r\n")
        expect(DownstreamHook.list).to include('textsub')
        expect(reports_of('foo').size).to eq(1)
        expect(reports_of('foo').first).to include('TypeError')
        expect(lich_removals).to be_empty

        expect(run_hooks("foo. You feel fine.\r\n".b)).to eq("foo. You feel FINE.\r\n")
        expect(reports_of('foo').size).to eq(1)
        expect(TextSubs.subs.keys).not_to include(/foo/)
      end

      it 'drops a UTF-8 key on the first binary line with high bytes, keeping the hook and the other subs' do
        key = "Caf#{0xE9.chr(Encoding::UTF_8)}"
        build_catalog('Commoner', 'private_textsubs' => { key => 'Cafe', 'You feel fine' => 'You feel FINE' })

        # On a line of ASCII bytes alone the key is merely tried, and misses.
        expect(run_hooks("You feel fine.\r\n".b)).to eq("You feel FINE.\r\n")
        expect(reports_of(key)).to be_empty

        expect(run_hooks("na#{0xEF.chr}ve. You feel fine.\r\n".b)).to eq("na#{0xEF.chr}ve. You feel FINE.\r\n")
        expect(DownstreamHook.list).to include('textsub')
        expect(reports_of(key).size).to eq(1)
        expect(reports_of(key).first).to include('Encoding::CompatibilityError')
        expect(lich_removals).to be_empty

        expect(run_hooks("na#{0xEF.chr}ve again.\r\n".b)).to eq("na#{0xEF.chr}ve again.\r\n")
        expect(reports_of(key).size).to eq(1)
      end

      it 'takes the key back when it is added again with a good value' do
        build_catalog('Commoner')
        TextSubs.add('foo', nil)
        run_hooks("foo\r\n".b)

        TextSubs.add('foo', 'bar')
        expect(run_hooks("foo\r\n".b)).to eq("bar\r\n")
        expect(reports_of('foo').size).to eq(1)
      end
    end
  end

  # Lich evaluates the whole of textsubs.lic on every start, so the class body
  # runs again (reload_lic_class) before the entry point. That redefines every
  # TextSubs method, and reload_lic_class ends every stub on TextSubs first,
  # so these examples stub TextSubs only after it: watch again, as the
  # file-wide before hook did, so the next start returns.
  describe 'a start in Lich, which evaluates the class body before the entry point' do
    it 'leaves a hook of the run before passing every line through untouched until the new catalog is installed' do
      build_catalog('Ranger', 'herb_textsubs' => true)
      expect(TextSubs.apply(+"You pick some nilos.\r\n")).to eq("You pick some nilos (abdo-EW).\r\n")
      reload_lic_class('textsubs.lic', 'TextSubs')
      allow(TextSubs).to receive(:watch)
      allow(TextSubs).to receive(:client_attached?).and_return(true)
      lines = ["You pick some nilos.\r\n", "You feel fine.\r\n"]
      seen = []
      writes = 0
      # The old run's 'textsub' hook is still registered, as when Lich has not
      # yet removed the hook of a run that is being stopped. The first write
      # (the private key) and every 250th after it send the lines through it.
      observer = lambda do |_key, _value, _gate, _registry|
        seen << lines.map { |line| run_hooks(line.b) } if (writes += 1) % 250 == 1
      end
      expect(DownstreamHook.list).to include('textsub')
      expect(TextSubs.subs).to eq({})

      on_registry_write(observer) do
        build_catalog('Ranger', 'herb_textsubs' => false, 'private_textsubs' => { 'You feel fine' => 'You feel FINE' })
      end

      expect(writes).to be > 500
      expect(seen.size).to be > 3
      expect(seen).to all(eq(lines))
      expect(lines.map { |line| run_hooks(line.b) }).to eq(["You pick some nilos.\r\n", "You feel FINE.\r\n"])
    end

    it 'counts the empty catalog the class body installs, and the next start leaves a higher number again' do
      build_catalog('Ranger', 'herb_textsubs' => true)
      first = TextSubs.generation
      expect(TextSubs.subs).not_to be_empty

      reload_lic_class('textsubs.lic', 'TextSubs')
      allow(TextSubs).to receive(:watch)
      emptied = TextSubs.generation
      expect(TextSubs.subs).to eq({})
      expect(emptied).to eq(first + 1)

      build_catalog('Commoner', 'private_textsubs' => { 'You feel fine' => 'You feel FINE' })
      expect(TextSubs.generation).to be > emptied
    end

    it 'ends the staging of a build that raises when the script dies, installing none of it' do
      # 'before' is the run before's; the class body empties the catalog.
      TextSubs.add('before', 'BEFORE')
      reload_lic_class('textsubs.lic', 'TextSubs')
      # Stubbed on main (where run_lic_entry evaluates the entry), not on
      # Script.at_exit: another spec replaces the top-level before_dying.
      dying = []
      allow(TOPLEVEL_BINDING.receiver).to(receive(:before_dying)) { |&block| dying << block }
      # A private_textsubs key that is not regex source is skipped with a
      # warning now, so the build is made to die on its second write to the
      # staged Registry instead, as a build stopped (;kill) or broken partway
      # would. A TracePoint on Registry#add raises before that write lands,
      # and only while the build runs: a stub giving the staged Registry a
      # raising add would also reach the Registry the after hook stages for
      # the next example.
      build_died = Class.new(StandardError)
      writes = 0
      dies = TracePoint.new(:call) { raise build_died, 'the build died partway' if (writes += 1) == 2 }
      installed = TextSubs.subs
      expect(installed).to eq({})

      expect do
        dies.enable(target: TextSubs::Registry.instance_method(:add)) do
          build_catalog('Commoner', 'private_textsubs' => { 'You feel fine' => 'You feel FINE' })
        end
      end.to raise_error(build_died)
      expect(writes).to eq(2)
      expect(TextSubs.subs).to equal(installed)
      dying.each(&:call)

      # Another script's add reaches the installed catalog, which holds none
      # of the partial build ('You feel fine').
      TextSubs.add('bird', 'fish')
      expect(TextSubs.subs).to eq(/bird/ => 'fish')
      expect(TextSubs.apply(+'You feel fine, bird.')).to eq('You feel fine, fish.')
      TextSubs.clear
      TextSubs.add('cat', 'dog')
      expect(TextSubs.subs).to eq(/cat/ => 'dog')
    end

    it 'keeps two overlapping starts apart, so neither installs a part of its catalog nor takes keys of the other' do
      # Run A builds on a thread of its own, as a Lich script does. Run B is a
      # ';force textsubs' that Lich starts while A builds: it re-runs the class
      # body, then stages and builds on its own thread. A goes on adding after
      # B has staged, and finishes first.
      to_a = Queue.new
      to_b = Queue.new
      from_runs = Queue.new
      run_a = Thread.new do
        catalog = TextSubs.stage(TextSubs::Registry.new)
        TextSubs.add('a head', 'A')
        from_runs << :a_head_added
        to_a.pop(timeout: 5)
        TextSubs.add('a tail', 'A')
        [catalog, TextSubs.install(catalog)]
      end
      expect(from_runs.pop(timeout: 5)).to eq(:a_head_added)
      reload_lic_class('textsubs.lic', 'TextSubs')
      emptied = TextSubs.subs
      run_b = Thread.new do
        catalog = TextSubs.stage(TextSubs::Registry.new)
        TextSubs.add('b key', 'B')
        from_runs << :b_staged
        to_b.pop(timeout: 5)
        [catalog, TextSubs.install(catalog)]
      end
      expect(from_runs.pop(timeout: 5)).to eq(:b_staged)
      before_a_installs = TextSubs.generation

      to_a << :go
      catalog_a, installed_a = run_a.value
      expect(installed_a).to be_nil
      expect(TextSubs.subs).to equal(emptied)
      expect(emptied).to eq({})
      expect(TextSubs.generation).to eq(before_a_installs)
      expect(catalog_a.snapshot.keys.map(&:source)).to eq(['a head', 'a tail'])

      # Another script's add, made while B builds, goes into B's catalog.
      TextSubs.add('other script', 'X')
      to_b << :go
      catalog_b, installed_b = run_b.value
      expect(installed_b).to equal(catalog_b)
      expect(TextSubs.subs.keys.map(&:source)).to eq(['b key', 'other script'])
    end

    it 'ends a start that a newer one superseded while it built, before it registers a hook' do
      # The newer start ('b key') begins the moment this one has staged: Lich
      # re-runs the class body, then the newer start stages on its own thread.
      # Stubbed on main (where run_lic_entry evaluates the entry), not on
      # Script.at_exit: another spec replaces the top-level before_dying.
      reload_lic_class('textsubs.lic', 'TextSubs')
      dying = []
      newer = nil
      emptied = nil
      allow(TOPLEVEL_BINDING.receiver).to(receive(:before_dying)) do |&block|
        dying << block
        reload_lic_class('textsubs.lic', 'TextSubs')
        emptied = TextSubs.subs
        newer = Thread.new do
          catalog = TextSubs.stage(TextSubs::Registry.new)
          TextSubs.add('b key', 'B')
          catalog
        end.value
      end

      expect { build_catalog('Commoner', 'private_textsubs' => { 'You feel fine' => 'You feel FINE' }) }.to raise_error(SystemExit)
      expect(DownstreamHook.list).not_to include('textsub')
      expect(TextSubs.subs).to equal(emptied)
      expect(emptied).to eq({})
      expect(newer.snapshot.keys.map(&:source)).to eq(['b key'])
      expect(dying.map(&:call)).to eq([false])

      TextSubs.add('other script', 'X')
      expect(newer.snapshot.keys.map(&:source)).to eq(['b key', 'other script'])
    end
  end

  describe 'run_hooks' do
    # Registers, as 'textsub', a hook proc made the way run_lic_entry makes
    # textsubs.lic's: evaluated in a copy of TOPLEVEL_BINDING, so the `return`
    # in it is a top-level return.
    #
    # @return [void]
    def add_top_level_return_hook
      DownstreamHook.add('textsub', eval('proc { |_server_string| return }', TOPLEVEL_BINDING.dup, __FILE__, __LINE__))
    end

    # Registers, as 'textsub', a hook that raises a new exception class that is
    # not a StandardError, so DownstreamHook.run does not swallow it.
    #
    # @return [Class] the exception class the hook raises, with message
    #   'from the hook'
    def add_raising_hook
      hook_error = Class.new(Exception) # rubocop:disable Lint/InheritException
      DownstreamHook.add('textsub', proc { |_server_string| raise hook_error, 'from the hook' })
      hook_error
    end

    # Calls run_hooks and gives back what came out of it, value or exception.
    # A top-level return that gets past run_hooks would end rspec with status
    # 0, so this has its own guard: `finished` is set only once run_hooks has
    # returned or raised, and the ensure clause turns any other exit into a
    # failure of the example, whatever $! holds.
    #
    # @param line [String] a binary server line
    # @return [String, nil, Exception] the hooks' output, or the exception
    #   run_hooks raised
    # @raise [RuntimeError] when a top-level return got past run_hooks
    def run_hooks_outcome(line)
      finished = false
      outcome = begin
        run_hooks(line)
      rescue Exception => e # rubocop:disable Lint/RescueException
        e
      end
      finished = true
      outcome
    ensure
      raise 'a top-level return in the hook got past run_hooks' unless finished
    end

    it 'hands back an exception the hook raises as itself, whatever its class' do
      hook_error = add_raising_hook
      expect(run_hooks_outcome("You feel fine.\r\n".b)).to be_a(hook_error).and have_attributes(message: 'from the hook')
    end

    it 'turns a top-level return in the hook into an error' do
      add_top_level_return_hook
      expect(run_hooks_outcome("You feel fine.\r\n".b)).to be_a(RuntimeError).and have_attributes(message: /left without returning/)
    end

    it 'turns a top-level return in the hook into an error when run_hooks is called while an exception is rescued' do
      add_top_level_return_hook
      outcome = begin
        raise ArgumentError, 'an exception being rescued leaves $! set'
      rescue ArgumentError
        run_hooks_outcome("You feel fine.\r\n".b)
      end
      expect(outcome).to be_a(RuntimeError).and have_attributes(message: /left without returning/)
    end

    it 'lets an exception the hook raises through unchanged when run_hooks is called while an exception is rescued' do
      hook_error = add_raising_hook
      expect do
        raise ArgumentError, 'an exception being rescued leaves $! set'
      rescue ArgumentError
        run_hooks("You feel fine.\r\n".b)
      end.to raise_error(hook_error, 'from the hook')
    end
  end

  # The poll seam is stubbed: DownstreamHook.list where a sequence of lists
  # is wanted, and pause everywhere, counting calls so a watch that never
  # returns fails instead of hanging the run.
  describe 'TextSubs.watch' do
    let(:script) { OpenStruct.new(want_downstream: true) }
    let(:pauses) { [] }

    before do
      allow(TextSubs).to receive(:watch).and_call_original
      allow(TextSubs).to receive(:pause) do |seconds|
        pauses << seconds
        raise 'TextSubs.watch is still waiting after 10 polls' if pauses.size > 10
      end
    end

    it 'returns nil once the hook leaves DownstreamHook.list, pausing the interval between checks' do
      allow(DownstreamHook).to receive(:list).and_return(%w[other textsub], %w[textsub other], %w[other])

      expect(TextSubs.watch('textsub', script: script, interval: 7)).to be_nil
      expect(pauses).to eq([7, 7])
      expect(DownstreamHook).to have_received(:list).exactly(3).times
    end

    it 'pauses five seconds by default' do
      allow(DownstreamHook).to receive(:list).and_return(%w[textsub], [])
      TextSubs.watch('textsub', script: script)
      expect(pauses).to eq([5])
    end

    it 'stops Lich buffering game lines for the script before it waits' do
      allow(DownstreamHook).to(receive(:list).and_wrap_original do
        expect(script.want_downstream).to be(false)
        []
      end)
      TextSubs.watch('textsub', script: script)
      expect(script.want_downstream).to be(false)
    end

    it 'says the hook is gone, and how to start textsubs again, when it returns' do
      allow(DownstreamHook).to receive(:list).and_return([])
      TextSubs.watch('textsub', script: script)
      expect(displayed_messages.last).to start_with("The 'textsub' hook is gone")
      expect(displayed_messages.last).to end_with('Start it again with ;textsubs.')
    end

    it 'returns at once, without pausing, when the hook was never registered' do
      allow(DownstreamHook).to receive(:list).and_return(%w[textsubs textsub-old Textsub])
      expect(TextSubs.watch('textsub', script: script)).to be_nil
      expect(pauses).to be_empty
    end

    it 'keeps waiting while the real hook list holds the hook, and returns the poll after it is removed' do
      DownstreamHook.add('textsub', proc { |line| line }, persist: false)
      allow(TextSubs).to receive(:pause) do |seconds|
        pauses << seconds
        raise 'TextSubs.watch is still waiting after 10 polls' if pauses.size > 10

        DownstreamHook.remove('textsub') if pauses.size == 3
      end

      TextSubs.watch('textsub', script: script)
      expect(pauses.size).to eq(3)
    end

    it 'reads the running script from Script.current by default' do
      allow(Script).to receive(:current).and_return(script)
      allow(DownstreamHook).to receive(:list).and_return([])
      TextSubs.watch('textsub')
      expect(script.want_downstream).to be(false)
    end

    describe 'with a block, as the entry point passes one' do
      let(:yielded) { [] }

      # @param guild [String, nil] the guild the catalog was built for
      # @param polls [Integer] how many checks find the hook before it goes
      # @return [nil] what watch returns
      def watch_for(guild:, polls:)
        allow(DownstreamHook).to receive(:list).and_return(*([%w[textsub]] * polls), [])
        TextSubs.watch('textsub', script: script, interval: 1, guild: guild) { |new_guild| yielded << [new_guild, pauses.size] }
      end

      it 'yields nothing while DRStats reports the guild the catalog was built for' do
        DRStats.guild = 'Bard'
        watch_for(guild: 'Bard', polls: 3)
        expect(yielded).to be_empty
        expect(pauses.size).to eq(3)
      end

      it 'yields the new guild once, before that check pauses, and not again while it stays' do
        allow(TextSubs).to receive(:pause) do |seconds|
          pauses << seconds
          DRStats.guild = 'Bard' if pauses.size == 2
        end
        watch_for(guild: nil, polls: 5)
        expect(yielded).to eq([['Bard', 2]])
        expect(pauses.size).to eq(5)
      end

      it 'yields again on each later change, nil included, comparing with the guild it last yielded' do
        reported = [nil, 'Bard', 'Bard', 'Cleric', nil]
        allow(TextSubs).to receive(:pause) { |seconds| pauses << seconds }
        allow(DRStats).to receive(:guild) { reported[pauses.size] }
        watch_for(guild: nil, polls: 5)
        expect(yielded).to eq([['Bard', 1], ['Cleric', 3], [nil, 4]])
      end

      it 'yields at the first check when the guild changed after the catalog was built' do
        DRStats.guild = 'Ranger'
        watch_for(guild: nil, polls: 1)
        expect(yielded).to eq([['Ranger', 0]])
      end

      it 'yields nothing once the hook is gone, whatever the guild' do
        DRStats.guild = 'Ranger'
        watch_for(guild: nil, polls: 0)
        expect(yielded).to be_empty
      end

      it 'compares with the guild DRStats reports when it is called, if no guild is given' do
        DRStats.guild = 'Thief'
        allow(DownstreamHook).to receive(:list).and_return(%w[textsub], [])
        TextSubs.watch('textsub', script: script) { |new_guild| yielded << new_guild }
        expect(yielded).to be_empty
      end
    end

    describe 'given the token start_run gave a start, as the entry point passes it' do
      let(:superseded) { 'A newer textsubs has started, so this one stops here; if no textsubs is running now, start it again with ;textsubs.' }

      it 'keeps waiting while that run is the latest start, and returns when the hook goes' do
        run = TextSubs.start_run
        allow(DownstreamHook).to receive(:list).and_return(%w[textsub], %w[textsub], [])

        expect(TextSubs.watch('textsub', script: script, run: run)).to be_nil
        expect(pauses.size).to eq(2)
        expect(displayed_messages.last).to start_with("The 'textsub' hook is gone")
      end

      it 'returns at the check after a newer start takes its token, though the hook name is still registered' do
        run = TextSubs.start_run
        allow(DownstreamHook).to receive(:list).and_return(%w[textsub])
        # The newer start runs on a thread of its own, as a Lich script does.
        allow(TextSubs).to receive(:pause) do |seconds|
          pauses << seconds
          raise 'TextSubs.watch is still waiting after 10 polls' if pauses.size > 10

          Thread.new { TextSubs.start_run }.join if pauses.size == 2
        end

        expect(TextSubs.watch('textsub', script: script, run: run)).to be_nil
        expect(pauses.size).to eq(2)
        expect(displayed_messages.last).to eq(superseded)
      end

      it 'keeps waiting when another script stages a Registry of its own, as that starts no textsubs' do
        run = TextSubs.start_run
        allow(DownstreamHook).to receive(:list).and_return(%w[textsub], %w[textsub], %w[textsub], [])
        allow(TextSubs).to receive(:pause) do |seconds|
          pauses << seconds
          raise 'TextSubs.watch is still waiting after 10 polls' if pauses.size > 10

          Thread.new { TextSubs.stage(TextSubs::Registry.new) }.join if pauses.size == 1
        end

        expect(TextSubs.watch('textsub', script: script, run: run)).to be_nil
        expect(pauses.size).to eq(3)
        expect(displayed_messages.last).to start_with("The 'textsub' hook is gone")
      end

      it 'returns at its first check once a newer start has re-run the class body, before that start takes its token' do
        run = TextSubs.start_run
        # reload_lic_class resets every stub on TextSubs, so they go on after it.
        reload_lic_class('textsubs.lic', 'TextSubs')
        allow(TextSubs).to receive(:watch).and_call_original
        allow(TextSubs).to receive(:pause) do |seconds|
          pauses << seconds
          raise 'TextSubs.watch is still waiting after 10 polls' if pauses.size > 10
        end
        allow(DownstreamHook).to receive(:list).and_return(%w[textsub])

        expect(TextSubs.watch('textsub', script: script, run: run)).to be_nil
        expect(pauses).to be_empty
        expect(displayed_messages.last).to eq(superseded)
      end
    end

    it 'never reads the guild without a block' do
      allow(DRStats).to receive(:guild).and_raise('read the guild')
      allow(DownstreamHook).to receive(:list).and_return(%w[textsub], %w[textsub], [])
      expect { TextSubs.watch('textsub', script: script, guild: 'Bard') }.not_to raise_error
      expect(pauses.size).to eq(2)
    end
  end

  # pause is stubbed and counted, so a wait that never ends fails instead of
  # hanging the run; DRInfomon.startup_complete? is the harness double, true
  # unless an example says otherwise.
  describe 'TextSubs.await_guild' do
    let(:pauses) { [] }
    let(:warnings) { displayed_messages.grep(/does not know your guild yet/) }

    # @param on_pause [Proc, nil] called with the number of pauses so far
    #   after each one, to change the world as time goes by
    # @return [void]
    def count_pauses(&on_pause)
      allow(TextSubs).to receive(:pause) do |seconds|
        pauses << seconds
        raise 'TextSubs.await_guild is still waiting after 100 pauses' if pauses.size > 100

        on_pause&.call(pauses.size)
      end
    end

    before { count_pauses }

    it 'returns the guild DRStats knows at once, without pausing or warning' do
      DRStats.guild = 'Moon Mage'
      DRInfomon._set_startup_complete(false)
      expect(TextSubs.await_guild).to eq('Moon Mage')
      expect(pauses).to be_empty
      expect(warnings).to be_empty
    end

    it 'returns nil at once, warning once, when DRInfomon is done and still has no guild (a login while dead)' do
      expect(TextSubs.await_guild).to be_nil
      expect(pauses).to be_empty
      expect(warnings.size).to eq(1)
      expect(warnings.first).to include('(a login while dead skips INFO)')
      expect(warnings.first).to end_with('textsubs adds them by itself once your guild is known.')
    end

    it 'keeps waiting while DRInfomon is busy, and returns the guild once INFO sets it, without warning' do
      DRInfomon._set_startup_complete(false)
      count_pauses { |count| DRStats.guild = 'Empath' if count == 3 }
      expect(TextSubs.await_guild(interval: 0.25)).to eq('Empath')
      expect(pauses).to eq([0.25, 0.25, 0.25])
      expect(warnings).to be_empty
    end

    it 'stops at the check after DRInfomon finishes without a guild' do
      DRInfomon._set_startup_complete(false)
      count_pauses { |count| DRInfomon._set_startup_complete(true) if count == 2 }
      expect(TextSubs.await_guild).to be_nil
      expect(pauses.size).to eq(2)
      expect(warnings.size).to eq(1)
    end

    it 'gives up after timeout seconds and warns once, blaming the slow DRInfomon rather than a dead login' do
      DRInfomon._set_startup_complete(false)
      expect(TextSubs.await_guild(timeout: 2, interval: 0.5)).to be_nil
      expect(pauses).to eq([0.5] * 4)
      expect(warnings.size).to eq(1)
      expect(warnings.first).to include('(DRInfomon had not finished its login commands after 2 seconds)')
      expect(warnings.first).not_to include('dead')
    end

    # The reason is read once the wait is over, not when it began.
    it 'blames a dead login when DRInfomon finishes during the wait without a guild' do
      DRInfomon._set_startup_complete(false)
      count_pauses { |count| DRInfomon._set_startup_complete(true) if count == 1 }
      TextSubs.await_guild(timeout: 2)
      expect(warnings.first).to include('(a login while dead skips INFO)')
    end

    it 'waits ten seconds at most by default, checking every half second' do
      DRInfomon._set_startup_complete(false)
      TextSubs.await_guild
      expect(pauses).to eq([0.5] * 20)
    end

    it 'does not wait at all when the timeout is zero' do
      DRInfomon._set_startup_complete(false)
      expect(TextSubs.await_guild(timeout: 0)).to be_nil
      expect(pauses).to be_empty
    end

    # DRInfomon marks startup done right after INFO, so the guild may land
    # between the guild check and the startup check of the same poll.
    it 'reads the guild again after it stops, so a guild set at the moment DRInfomon finishes is not missed' do
      allow(DRStats).to receive(:guild).and_return(nil, 'Bard')
      expect(TextSubs.await_guild).to eq('Bard')
      expect(warnings).to be_empty
    end
  end

  describe 'a guild DRStats does not know yet' do
    let(:warnings) { displayed_messages.grep(/does not know your guild yet/) }
    let(:spell_links_on) { { 'textsubs_spell_links' => true, 'herb_textsubs' => false, 'textsubs_use_plat_grouping' => false } }
    let(:mana_tuner_sources) do
      shipped_catalog['textsubs']['sections'].find { |section| section['name'] == 'mana tuners' }['subs'].map(&:first)
    end

    before { allow(TextSubs).to receive(:pause) }

    it 'builds no guild section, no guild spell link and no mana tuner note, and warns once' do
      catalog = build_catalog(nil, spell_links_on)
      sources = catalog.map(&:first)
      commoner = golden_catalog(spell_links_on.merge('guild' => 'Commoner'))

      expect(catalog.map(&:last).grep(/Category:_spells/)).to be_empty
      expect(sources & mana_tuner_sources).to be_empty
      expect(sources).not_to include('You recall the spells you have learned from your training.')
      # A Commoner has no guild section, so it differs only by what needs a
      # known guild: the link and the mana tuners.
      expect(catalog).to eq(commoner.reject { |source, _, replacement| mana_tuner_sources.include?(source) || replacement.include?('Category:Commoner_spells') })
      expect(warnings.size).to eq(1)
    end

    it 'builds the Empath catalog when INFO sets the guild during the wait' do
      DRInfomon._set_startup_complete(false)
      pauses = 0
      allow(TextSubs).to receive(:pause) do
        pauses += 1
        DRStats.guild = 'Empath' if pauses == 2
      end

      catalog = build_catalog(nil, spell_links_on)

      expect(pauses).to eq(2)
      expect(catalog == golden_catalog(spell_links_on.merge('guild' => 'Empath'))).to be(true)
      expect(warnings).to be_empty
    end

    context 'when DRStats learns the guild after the hook is registered' do
      include_context 'with a front end attached'

      let(:song) { "You bring the song to a close, bowing your head.\r\n".b }
      let(:rebuilt) { displayed_messages.grep(/^Your guild is now|^textsubs has built its subs again|built again for .* are dropped/) }
      let(:bard_rebuild) { 'Your guild is now Bard, so textsubs builds its subs again for it.' }
      let(:bard_installed) { 'textsubs has built its subs again for Bard and uses them now.' }
      let(:bard_dropped) { 'A newer textsubs has started, so the subs this one built again for Bard are dropped.' }

      # Runs the real watch: the first pause is where INFO lands and sets the
      # guild, after the block (what happens before it, on the old catalog);
      # each pause after it gets a line through the hooks, and the last one
      # removes the hook so watch returns.
      #
      # @param polls [Integer] how many pauses watch makes before the hook goes
      # @param private_textsubs [Hash{String=>String}] the setting to start with
      # @param line [String] the binary line sent at each pause after the first
      # @yield at the first pause, before the guild is set
      # @return [Array<String>] what the hooks made of line at each pause
      #   after the first
      def start_then_learn_bard(polls: 2, private_textsubs: { 'You feel fine' => 'You feel FINE' }, line: song, &before_info)
        allow(TextSubs).to receive(:watch).and_call_original
        seen = []
        pauses = 0
        allow(TextSubs).to receive(:pause) do
          pauses += 1
          raise 'TextSubs.watch kept waiting' if pauses > polls

          if pauses == 1
            before_info&.call
            DRStats.guild = 'Bard'
          end
          seen << run_hooks(line) if pauses > 1
          DownstreamHook.remove('textsub') if pauses == polls
        end
        build_catalog(nil, spell_links_on.merge('private_textsubs' => private_textsubs))
        seen
      end

      # @return [Array<Array(String, Integer, String)>] TextSubs.subs as
      #   [source, options, replacement] entries, like build_catalog's
      def installed_entries
        TextSubs.subs.map { |pattern, replacement| [pattern.source, pattern.options, replacement] }
      end

      it 'keeps the subs other scripts added since the start, with their values, in the catalog built for the guild' do
        line = "Zorbix sings.\r\n".b
        seen = start_then_learn_bard(line: line, polls: 3) do
          TextSubs.add('Zorbix', 'ZORBIX')
          TextSubs.elanthipedia('sings', ' ', '\\.', 'Category:', '_songs')
          # Over a key the catalog builds too: the add wins, in that key's place.
          TextSubs.add('You feel fine', 'You feel GREAT')
          expect(run_hooks(line)).to eq(%(ZORBIX <a href="https://elanthipedia.play.net/Category:sings_songs">sings</a>.\r\n))
        end

        expect(seen).to eq([%(ZORBIX <a href="https://elanthipedia.play.net/Category:sings_songs">sings</a>.\r\n)] * 2)
        expect(installed_entries).to eq([['You feel fine', 0, 'You feel GREAT'],
                                         *golden_catalog(spell_links_on.merge('guild' => 'Bard')),
                                         ['Zorbix', 0, 'ZORBIX'],
                                         ['( )(sings)(\\.)', 0, '\\1<a href="https://elanthipedia.play.net/Category:sings_songs">sings</a>\\3']])
        expect(rebuilt).to eq([bard_rebuild, bard_installed])
      end

      it 'leaves out of the catalog built for the guild a sub apply dropped, and reports the drop only once' do
        # A UTF-8 key (an e-acute) meets a binary line with a high byte: the
        # regex raises Encoding::CompatibilityError on it.
        key = "Zorbix#{0xE9.chr(Encoding::UTF_8)}?"
        line = "caf#{0xE9.chr} Zorbix\r\n".b
        reports = -> { displayed_messages.grep(/the sub #{Regexp.escape(key.inspect)} raised Encoding::CompatibilityError/) }
        seen = start_then_learn_bard(line: line, polls: 3, private_textsubs: { key => 'X' }) do
          expect(TextSubs.subs.keys.map(&:source)).to include(key)
          expect(run_hooks(line)).to eq(line)
          expect(reports.call.size).to eq(1)
        end

        expect(seen).to eq([line, line])
        expect(rebuilt).to eq([bard_rebuild, bard_installed])
        expect(TextSubs.subs.keys.map(&:source)).not_to include(key)
        expect(installed_entries).to eq(golden_catalog(spell_links_on.merge('guild' => 'Bard')))
        expect(reports.call.size).to eq(1)
      end

      it 'says again only the private_textsubs warnings the new guild brings' do
        teaching = 'class on extremely advanced(.*)compared to'
        bard_song = 'You bring the song to a close, bowing your head\\.'
        seen = start_then_learn_bard(private_textsubs: { teaching => 'TAUGHT', bard_song => 'SUNG' })

        expect(seen).to eq(["SUNG\r\n"])
        teaching_warning = "private_textsubs \"#{teaching}\" is also a built-in sub; your replacement is used instead of the built-in one."
        song_warning = "private_textsubs \"#{bard_song}\" is also a built-in sub; your replacement is used instead of the built-in one."
        expect(displayed_messages.grep(/is also a built-in sub/)).to eq([teaching_warning, song_warning])
        # The song's warning comes with the rebuild, after the line that says
        # why the subs are built again and before the one that says they are in.
        expect(displayed_messages.grep(/is also a built-in sub|^Your guild is now|^textsubs has built its subs again/).last(3))
          .to eq([bard_rebuild, song_warning, bard_installed])
      end

      it 'builds the Bard catalog in one watch check and installs it, saying so once' do
        seen = start_then_learn_bard
        private_key = ['You feel fine', 0, 'You feel FINE']

        expect(seen).to eq(["You bring the song to a close, bowing your head (4/7).\r\n"])
        expect(TextSubs.subs.map { |pattern, replacement| [pattern.source, pattern.options, replacement] })
          .to eq([private_key, *golden_catalog(spell_links_on.merge('guild' => 'Bard'))])
        expect(rebuilt).to eq([bard_rebuild, bard_installed])
        expect(warnings.size).to eq(1)
      end

      it 'ends a run a newer start superseded, and never installs its rebuild over the newer catalog' do
        # Each start's watch is recorded instead of run, so both runs reach
        # it; reload_lic_class (the class body a ';force textsubs' re-runs)
        # resets every stub on TextSubs, so the stubs go on again after it.
        watches = []
        stub_start = lambda do
          allow(TextSubs).to receive(:client_attached?).and_return(true)
          allow(TextSubs).to(receive(:watch)) { |hook, **options, &rebuild| watches << [hook, options, rebuild] }
        end
        fine = "You feel fine.\r\n".b
        stub_start.call
        build_catalog(nil, spell_links_on.merge('private_textsubs' => { 'You feel fine' => 'OLD RUN' }))
        expect(run_hooks(fine)).to eq("OLD RUN.\r\n")
        reload_lic_class('textsubs.lic', 'TextSubs')
        stub_start.call
        build_catalog(nil, spell_links_on.merge('private_textsubs' => { 'You feel fine' => 'NEW RUN' }))
        expect(run_hooks(fine)).to eq("NEW RUN.\r\n")
        (old_hook, old_options, old_rebuild), (new_hook, new_options, new_rebuild) = watches

        # INFO lands: both runs now see a guild their catalog was not built for.
        DRStats.guild = 'Bard'
        allow(TextSubs).to receive(:watch).and_call_original
        pauses = 0
        allow(TextSubs).to receive(:pause) do
          raise 'TextSubs.watch kept waiting' if (pauses += 1) > 1

          DownstreamHook.remove('textsub')
        end

        # The old run's watch stops at its first check, though the hook name
        # (the new run's hook now) is still registered, and rebuilds nothing.
        expect(TextSubs.watch(old_hook, **old_options, &old_rebuild)).to be_nil
        expect(pauses).to eq(0)
        expect(displayed_messages.last).to eq('A newer textsubs has started, so this one stops here; if no textsubs is running now, start it again with ;textsubs.')
        expect(run_hooks(fine)).to eq("NEW RUN.\r\n")

        # Its rebuild, as if its last check had passed just before the newer
        # start, is refused when it comes to install, and says so at once.
        generation = TextSubs.generation
        old_rebuild.call('Bard')
        expect(TextSubs.generation).to eq(generation)
        expect(run_hooks(fine)).to eq("NEW RUN.\r\n")
        expect(displayed_messages.last(2)).to eq([bard_rebuild, bard_dropped])

        # The new run's watch rebuilds for the Bard, and returns once its hook goes.
        expect(TextSubs.watch(new_hook, **new_options, &new_rebuild)).to be_nil
        expect(pauses).to eq(1)
        expect(installed_entries).to eq([['You feel fine', 0, 'NEW RUN'], *golden_catalog(spell_links_on.merge('guild' => 'Bard'))])
        # The refused rebuild said why it started and that it was dropped,
        # never that it was done.
        expect(rebuilt).to eq([bard_rebuild, bard_dropped, bard_rebuild, bard_installed])
      end

      # The first write once the guild is Bard (the rebuild's) and every
      # 400th after it send two lines through the hooks: the Bard song, which
      # only the new catalog labels, and a private sub the old one has.
      it 'keeps applying the whole old catalog while the new one is built, then swaps it in with one generation' do
        probes = []
        writes = 0
        probe = lambda do |_key, _value, _gate, _registry|
          next unless DRStats.guild == 'Bard' && (writes += 1) % 400 == 1

          probes << [run_hooks(song), run_hooks("You feel fine.\r\n".b), TextSubs.generation]
        end

        seen = on_registry_write(probe) { start_then_learn_bard }

        expect(probes.size).to be > 2
        expect(probes.map { |old_song, fine, _| [old_song, fine] }.uniq).to eq([[song, "You feel FINE.\r\n"]])
        expect(probes.map(&:last).uniq.size).to eq(1)
        expect(TextSubs.generation).to eq(probes.first.last + 1)
        expect(seen).to eq(["You bring the song to a close, bowing your head (4/7).\r\n"])
      end
    end
  end

  describe 'TextSubs.build' do
    let(:context) { TextSubs::Context.new(guild: 'Bard', settings: OpenStruct.new) }
    let(:data) do
      { 'schema' => 1, 'sections' => [{ 'name' => 'one', 'subs' => [%w[fine FINE], %w[cat dog]] }] }
    end
    let(:private_subs) { TextSubs::Sources::PrivateSubs.entries('fine' => 'MINE', 'owl' => 'hoot').first }

    def build_into(registry, data: self.data)
      TextSubs.build(registry, shit_list: %w[Bob Quimble], private_subs: private_subs, data: data, context: context, file: 'f')
    end

    it 'fills a Registry that is not installed, in place order, leaving the installed catalog and the generation alone' do
      TextSubs.add('mine', 'MINE')
      generation = TextSubs.generation
      registry = TextSubs::Registry.new

      expect(build_into(registry)).to eq(['private_textsubs "fine" is also a built-in sub; your replacement is used instead of the built-in one.'])
      expect(registry.snapshot.to_a).to eq([[/\bBob\b/, 'Bob (SL)'], [/\bQuimble\b/, 'Quimble (SL)'], [private_subs[0][0], 'MINE'],
                                            [private_subs[1][0], 'hoot'], [/cat/, 'dog']])
      expect(TextSubs.subs).to eq(/mine/ => 'MINE')
      expect(TextSubs.generation).to eq(generation)

      TextSubs.install(registry)
      expect(TextSubs.generation).to eq(generation + 1)
      expect(TextSubs.apply(+'Bob: fine cat')).to eq('Bob (SL): MINE dog')
    end

    it 'counts a generation for each write to the installed Registry, as on a start' do
      registry = TextSubs.install(TextSubs::Registry.new)
      generation = TextSubs.generation
      build_into(registry)
      # Two names, two private keys, two built-in subs, one private value given back.
      expect(TextSubs.generation).to eq(generation + 7)
    end

    it "puts why no built-in sub was added first, and still adds the shit-list and private subs" do
      registry = TextSubs::Registry.new
      messages = build_into(registry, data: { 'schema' => 2 })
      expect(messages.size).to eq(1)
      expect(messages.first).to start_with('No built-in subs: f cannot be used (schema 2')
      expect(registry.snapshot.values).to eq(['Bob (SL)', 'Quimble (SL)', 'MINE', 'hoot'])
    end

    it 'gives each private key the gate of the built-in sub it replaced, in the Registry it fills' do
      gated = { 'schema' => 1, 'sections' => [{ 'name' => 'gated', 'requires_any' => ['Kronar'], 'subs' => [%w[fine FINE]] }] }
      registry = TextSubs::Registry.new
      build_into(registry, data: gated)
      expect(registry.gates).to eq(private_subs[0][0] => ['Kronar'])
    end
  end

  describe 'hook engine semantics' do
    include_context 'with a front end attached'

    # Runs the real entry point, so the real 'textsub' hook is registered, then
    # swaps the built catalog for exactly `pairs` through the public TextSubs
    # API, so the example controls every key the hook can see.
    #
    # @param pairs [Array<Array(String, String)>] [target, result] pairs, added in order
    # @return [void]
    def install_catalog(*pairs)
      build_catalog('Commoner')
      TextSubs.clear
      pairs.each { |target, result| TextSubs.add(target, result) }
    end

    # @param line [String] a server line; sent as the binary string Lich hands hooks
    # @return [String, nil] what the downstream hooks pass on to the client
    def through_hook(line)
      run_hooks(line.b)
    end

    it 'does not fire a key that matches only after an earlier key rewrote the line' do
      install_catalog(%w[cat dog], %w[dog bird])
      expect(through_hook("The cat sleeps.\r\n")).to eq("The dog sleeps.\r\n")
    end

    it 'does nothing for a key that matched the original line but no longer matches it' do
      # 'c' matches "The cat sleeps." but not "The dog sleeps.", which is what
      # it sees after 'cat' ran; it never gets to turn "cat" into "kat".
      install_catalog(%w[cat dog], %w[c k])
      expect(through_hook("The cat sleeps.\r\n")).to eq("The dog sleeps.\r\n")
    end

    it 'applies the selected keys in insertion order, each to the output of the one before' do
      # In reverse order the line would read "blue green"; applied each to the
      # original line, "red green".
      install_catalog(%w[red blue], %w[blue green])
      expect(through_hook("red blue\r\n")).to eq("green green\r\n")
    end

    it 'keeps the first slot for a key added twice, with the value of the last add' do
      # Moving 'cat' behind 'c' would give "The kat sleeps."; keeping the
      # first value, "The dog sleeps."
      install_catalog(%w[cat dog], %w[c k], %w[cat lion])
      expect(through_hook("The cat sleeps.\r\n")).to eq("The lion sleeps.\r\n")
    end

    it 'keeps the \r\n line ending and the binary encoding of a rewritten line' do
      install_catalog(['fine\.', 'FINE.'])
      output = through_hook("You feel fine.\r\n")
      expect(output).to eq("You feel FINE.\r\n")
      expect(output.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it 'returns a line that no key matches byte for byte' do
      install_catalog(%w[cat dog])
      expect(through_hook("A bird sings.\r\n")).to eq("A bird sings.\r\n")
    end
  end

  # TextSubs.apply is the engine the hook hands each line to once a front end
  # is attached. These examples call it straight, with no hook registered and
  # no built-in catalog: each starts from an empty catalog and adds only the
  # keys it needs.
  describe 'TextSubs.apply' do
    before { TextSubs.clear }

    # @param pairs [Array<Array(String, String)>] [target, result] pairs, added in order
    # @return [void]
    def catalog(*pairs)
      pairs.each { |target, result| TextSubs.add(target, result) }
    end

    it 'rewrites a line with the keys added through TextSubs.add, with no hook registered' do
      catalog(['fine\.', 'FINE.'])
      expect(DownstreamHook.list).not_to include('textsub')
      expect(TextSubs.apply("You feel fine.\r\n".b)).to eq("You feel FINE.\r\n")
    end

    it 'rewrites the line it is given in place and returns that same String' do
      catalog(%w[cat dog])
      line = "The cat sleeps.\r\n".b
      expect(TextSubs.apply(line)).to equal(line)
      expect(line).to eq("The dog sleeps.\r\n")
    end

    it 'does not fire a key that matches only after an earlier key rewrote the line' do
      catalog(%w[cat dog], %w[dog bird])
      expect(TextSubs.apply("The cat sleeps.\r\n".b)).to eq("The dog sleeps.\r\n")
    end

    it 'does nothing for a key that matched the original line but no longer matches it' do
      catalog(%w[cat dog], %w[c k])
      expect(TextSubs.apply("The cat sleeps.\r\n".b)).to eq("The dog sleeps.\r\n")
    end

    it 'applies the selected keys in insertion order, each to the output of the one before' do
      catalog(%w[red blue], %w[blue green])
      expect(TextSubs.apply("red blue\r\n".b)).to eq("green green\r\n")
    end

    it 'keeps the first slot for a key added twice, with the value of the last add' do
      catalog(%w[cat dog], %w[c k], %w[cat lion])
      expect(TextSubs.apply("The cat sleeps.\r\n".b)).to eq("The lion sleeps.\r\n")
    end

    it 'fills capture groups in a value and keeps the binary encoding' do
      catalog(['(\d+) coins', '\1 kronars'])
      output = TextSubs.apply("You have 42 coins.\r\n".b)
      expect(output).to eq("You have 42 kronars.\r\n")
      expect(output.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it 'returns a line with an empty catalog, or one no key matches, as it came, even when frozen' do
      line = "A bird sings.\r\n".b.freeze
      expect(TextSubs.apply(line)).to equal(line)
      catalog(%w[cat dog])
      expect(TextSubs.apply(line)).to equal(line)
    end

    it 'raises FrozenError when a key matches a frozen line' do
      catalog(%w[cat dog])
      expect { TextSubs.apply("The cat sleeps.\r\n".b.freeze) }.to raise_error(FrozenError)
    end

    it 'applies whatever TextSubs.subs holds when it is called, not a copy taken earlier' do
      catalog(%w[cat dog])
      expect(TextSubs.apply(+'The cat.')).to eq('The dog.')
      TextSubs.add('cat', 'lion')
      expect(TextSubs.apply(+'The cat.')).to eq('The lion.')
      TextSubs.clear
      expect(TextSubs.apply(+'The cat.')).to eq('The cat.')
    end

    it 'tries a key added after the first line on the very next line, though the index was already built' do
      catalog(%w[cat dog])
      expect(TextSubs.apply(+'The cat and the bird.')).to eq('The dog and the bird.')
      TextSubs.add('bird', 'fish')
      expect(TextSubs.apply(+'The cat and the bird.')).to eq('The dog and the fish.')
    end

    it 'drops a key that raises, counts one generation for it, and applies the keys on either side' do
      catalog(%w[red blue], ['cat', nil], %w[bird fish])
      start = TextSubs.generation

      expect(TextSubs.apply(+'red cat bird')).to eq('blue cat fish')
      expect(TextSubs.subs.keys).to eq([/red/, /bird/])
      expect(TextSubs.generation).to eq(start + 1)
      expect(displayed_messages.grep(/the sub "cat" raised TypeError/).size).to eq(1)
    end

    it 'lets a FrozenError out and drops nothing, since the frozen line is at fault, not the key' do
      catalog(%w[cat dog])
      expect { TextSubs.apply(String.new('The cat.').freeze) }.to raise_error(FrozenError)
      expect(TextSubs.subs).to eq(/cat/ => 'dog')
      expect(displayed_messages.grep(/the sub/)).to be_empty
    end

    it 'leaves alone a key given a good value after the line began, and reports nothing' do
      catalog(['cat', nil])
      # The add lands between the snapshot the line runs through and the
      # drop, as another script's add on its own thread can.
      allow(TextSubs::Engine).to(receive(:apply).and_wrap_original do |original, *args, **options|
        on_error = options[:on_error]
        original.call(*args, **options, on_error: lambda { |key, error|
          TextSubs.add('cat', 'dog')
          on_error.call(key, error)
        })
      end)

      expect(TextSubs.apply(+'The cat.')).to eq('The cat.')
      expect(TextSubs.subs).to eq(/cat/ => 'dog')
      expect(displayed_messages.grep(/the sub/)).to be_empty
    end

    describe 'TextSubs::Engine.apply' do
      it 'runs on a hand-made ordered Hash, leaving that Hash and the TextSubs catalog alone' do
        subs = { /cat/ => 'dog', /dog/ => 'bird', /CAT/i => 'never' }.freeze
        # /dog/ matched the original line, so it also rewrites the dog /cat/
        # just made; /CAT/i matched too, but finds no cat left to change.
        expect(TextSubs::Engine.apply(subs, +'The cat and the dog.')).to eq('The bird and the bird.')
        expect(subs.keys).to eq([/cat/, /dog/, /CAT/i])
        expect(TextSubs.subs).to be_empty
      end

      it 'uses each key with its own options' do
        expect(TextSubs::Engine.apply({ /CAT/i => 'dog' }, +'The Cat.')).to eq('The dog.')
        expect(TextSubs::Engine.apply({ /CAT/ => 'dog' }, +'The Cat.')).to eq('The Cat.')
      end

      describe 'with on_error' do
        let(:errors) { [] }
        let(:on_error) { ->(key, error) { errors << [key, error.class] } }
        let(:high) { 0xEF.chr }

        it 'lets an error out when there is no on_error, as before' do
          expect { TextSubs::Engine.apply({ /cat/ => nil }, +'The cat.') }.to raise_error(TypeError)
        end

        it 'hands on_error a key whose replacement raises, and applies the keys before and after it' do
          subs = { /The/ => 'A', /cat/ => nil, /sleeps/ => 'naps' }.freeze
          expect(TextSubs::Engine.apply(subs, +'The cat sleeps.', on_error: on_error)).to eq('A cat naps.')
          expect(errors).to eq([[/cat/, TypeError]])
        end

        it 'hands on_error a key whose match raises, and treats it as not matching' do
          utf8 = Regexp.new("caf#{0xE9.chr(Encoding::UTF_8)}")
          subs = { utf8 => 'cafe', /fine/ => 'FINE' }.freeze
          expect(TextSubs::Engine.apply(subs, "#{high} fine".b, on_error: on_error)).to eq("#{high} FINE".b)
          expect(errors).to eq([[utf8, Encoding::CompatibilityError]])
        end

        it 'hands on_error a regex timeout, and goes on' do
          # Three repeats in a row, not nested, so the work grows as roughly
          # n**4 or worse (nearer n**5 at these sizes) rather than
          # exponentially; the back-reference keeps Onigmo from memoizing it
          # away. Untimed, 250 a's run a few hundred times past the 10 ms
          # timeout, yet only for seconds: the timeout caps the run only
          # while the key keeps it, so a key that lost it fails here in
          # seconds rather than in minutes.
          slow = Regexp.new('(a*)a*a*\\1$', timeout: 0.01)
          subs = { slow => 'x', /fine/ => 'FINE' }.freeze
          run = 'a' * 250
          expect(TextSubs::Engine.apply(subs, +"#{run}! fine", on_error: on_error)).to eq("#{run}! FINE")
          expect(errors).to eq([[slow, Regexp::TimeoutError]])
        end

        it 'hands on_error every key that raises on the line, each once' do
          subs = { /cat/ => nil, /dog/ => 5, /bird/ => 'fish' }.freeze
          expect(TextSubs::Engine.apply(subs, +'cat dog bird', on_error: on_error)).to eq('cat dog fish')
          expect(errors).to eq([[/cat/, TypeError], [/dog/, TypeError]])
        end

        it 'lets a FrozenError out, as the frozen line is at fault and not the key' do
          expect { TextSubs::Engine.apply({ /cat/ => 'dog' }, String.new('cat').freeze, on_error: on_error) }.to raise_error(FrozenError)
          expect(errors).to be_empty
        end

        # Only StandardError is a key's fault; NoMemoryError, Interrupt or
        # SystemExit belong to the process and must not drop a sub.
        it 'lets out an error that is not a StandardError, without handing it to on_error' do
          replacement = Object.new
          def replacement.to_str = raise(NoMemoryError, 'from to_str')
          subs = { /cat/ => replacement, /dog/ => 'fox' }.freeze
          expect { TextSubs::Engine.apply(subs, +'cat dog', on_error: on_error) }.to raise_error(NoMemoryError, 'from to_str')
          expect(errors).to be_empty
        end

        it 'lets out the KeyError of an index that names a key subs does not hold' do
          index = TextSubs::TokenIndex.new([/cat/])
          expect { TextSubs::Engine.apply({}, +'cat', index: index, on_error: on_error) }.to raise_error(KeyError)
          expect(errors).to be_empty
        end

        it 'lets out an error on_error itself raises' do
          raising = ->(_key, _error) { raise ArgumentError, 'from on_error' }
          expect { TextSubs::Engine.apply({ /cat/ => nil }, +'cat', on_error: raising) }.to raise_error(ArgumentError, 'from on_error')
        end
      end

      # An index already holds its gates, so gates passed beside it would be
      # dropped without a word; even an empty Hash is refused, since it says
      # the caller meant to choose the gates.
      it 'refuses gates passed beside an index, and leaves the line alone' do
        subs = { /cat/ => 'dog' }.freeze
        index = TextSubs::TokenIndex.new(subs.keys)
        line = +'The cat.'
        expect { TextSubs::Engine.apply(subs, line, gates: { /cat/ => ['Kronar'] }, index: index) }
          .to raise_error(ArgumentError, /not both/)
        expect { TextSubs::Engine.apply(subs, line, gates: {}, index: index) }.to raise_error(ArgumentError)
        expect(line).to eq('The cat.')
        expect(TextSubs::Engine.apply(subs, line, index: index)).to eq('The dog.')
      end

      # The engine trusts a gate, so a key gated on a word its pattern does not
      # need shows which lines the gate lets through: it stays silent on a line
      # it matches when that line holds none of the words.
      describe 'with gates' do
        let(:subs) { { /cat/ => 'dog' }.freeze }
        let(:gates) { { /cat/ => %w[Kronar Dokora].freeze }.freeze }

        it 'leaves out a gated key on a line that holds none of its words' do
          expect(TextSubs::Engine.apply(subs, +'The cat.', gates: gates)).to eq('The cat.')
        end

        it 'runs a gated key on a line that holds any one of its words, wherever it is' do
          expect(TextSubs::Engine.apply(subs, +'The cat, 5 Kronars.', gates: gates)).to eq('The dog, 5 Kronars.')
          expect(TextSubs::Engine.apply(subs, +'2 Dokoras for the cat.', gates: gates)).to eq('2 Dokoras for the dog.')
        end

        it 'matches the words case for case, as the coin patterns do' do
          expect(TextSubs::Engine.apply(subs, +'The cat, 5 kronars.', gates: gates)).to eq('The cat, 5 kronars.')
        end

        it 'checks the gate against the original line, not the line an earlier key rewrote' do
          made = { /a/ => 'Kronar', /b/ => 'B' }.freeze
          expect(TextSubs::Engine.apply(made, +'ab', gates: { /b/ => ['Kronar'] })).to eq('Kronarb')

          removed = { /Kronar/ => 'coin', /\d/ => '#' }.freeze
          expect(TextSubs::Engine.apply(removed, +'5 Kronar', gates: { /\d/ => ['Kronar'] })).to eq('# coin')
        end

        it 'keeps the other keys in insertion order around a key it leaves out' do
          ordered = { /red/ => 'blue', /cat/ => 'dog', /blue/ => 'green' }.freeze
          expect(TextSubs::Engine.apply(ordered, +'red blue cat', gates: gates)).to eq('green green cat')
        end

        it 'ignores a gate for a key the catalog does not hold, and changes neither Hash' do
          expect(TextSubs::Engine.apply(subs, +'The cat.', gates: { /dog/ => ['Kronar'] }.freeze)).to eq('The dog.')
          expect(subs).to eq(/cat/ => 'dog')
          expect(gates).to eq(/cat/ => %w[Kronar Dokora])
        end

        it 'reads a binary line with high bytes, with or without the word, without raising' do
          high = 0xFE.chr
          expect(TextSubs::Engine.apply(subs, "#{high}cat#{high}\r\n", gates: gates)).to eq("#{high}cat#{high}\r\n")
          expect(TextSubs::Engine.apply(subs, "#{high}cat Kronar#{high}\r\n", gates: gates)).to eq("#{high}dog Kronar#{high}\r\n")
        end
      end
    end
  end

  describe 'TextSubs.generation' do
    it 'goes up by one for each add, including a second add of the same target' do
      start = TextSubs.generation
      TextSubs.add('cat', 'dog')
      expect(TextSubs.generation).to eq(start + 1)
      TextSubs.add('cat', 'lion')
      expect(TextSubs.generation).to eq(start + 2)
    end

    it 'goes up by exactly one for an elanthipedia link, which adds one key' do
      TextSubs.clear
      start = TextSubs.generation
      TextSubs.elanthipedia('Fae Arts', '^', ':', 'Category:', '_spellbook')
      expect(TextSubs.generation).to eq(start + 1)
      expect(TextSubs.subs.size).to eq(1)
    end

    it 'goes up by one for clear, even on an empty catalog' do
      TextSubs.clear
      start = TextSubs.generation
      TextSubs.clear
      expect(TextSubs.generation).to eq(start + 1)
    end

    it 'leaves the counter and the catalog alone when a target is not valid regex source' do
      TextSubs.clear
      TextSubs.add('cat', 'dog')
      start = TextSubs.generation
      expect { TextSubs.add('(cat', 'dog') }.to raise_error(RegexpError)
      expect(TextSubs.generation).to eq(start)
      expect(TextSubs.subs).to eq(/cat/ => 'dog')
    end

    it 'counts a new key only after the key is in the catalog, so a reader never sees the count run ahead' do
      registry = TextSubs::Registry.new
      TextSubs.install(registry)
      TextSubs.add('cat', 'dog')
      before_write = TextSubs.generation
      seen = []
      # A reader that runs the moment the key is written, as the hook thread
      # can. The singleton lives on this Registry only; the after hook's clear
      # installs another.
      registry.define_singleton_method(:add) do |key, value, **options|
        result = super(key, value, **options)
        seen << [TextSubs.generation, TextSubs.subs.keys.map(&:source)]
        result
      end
      expect(TextSubs.add('bird', 'fish')).to eq('fish')
      expect(seen).to eq([[before_write, %w[cat bird]]])
      expect(TextSubs.generation).to eq(before_write + 1)
      expect(TextSubs.subs.keys.map(&:source)).to eq(%w[cat bird])
    end

    it 'swaps in the empty catalog before it counts a clear, so a reader never sees the count run ahead' do
      TextSubs.add('cat', 'dog')
      old_catalog = TextSubs.subs
      before_clear = TextSubs.generation
      seen = []
      # A reader before every line of textsubs.lic that clear runs, install
      # included, and at each return, as the hook thread can run between any
      # two of them. It records each new state: the count, and whether subs
      # is still the catalog clear replaces. The probe sees only the gaps
      # between lines, so two writes on one line, or in one parallel
      # assignment, show up as the start state and the end state with no
      # step between.
      probe = TracePoint.new(:line, :return) do |event|
        next unless File.basename(event.path) == 'textsubs.lic'

        state = [TextSubs.generation, TextSubs.subs.equal?(old_catalog) ? :old : :new]
        seen << state unless seen.last == state
      end
      expect(probe.enable(target_thread: Thread.current) { TextSubs.clear }).to eq({})
      expect(seen.first).to eq([before_clear, :old])
      expect(seen).not_to include([before_clear + 1, :old])
      expect(seen.last).to eq([before_clear + 1, :new])
    end

    it 'swaps in the empty catalog before it works out the next count, even with both writes on one line' do
      TextSubs.add('cat', 'dog')
      old_catalog = TextSubs.subs
      before_clear = TextSubs.generation
      seen = []
      # A count that records, at the moment clear works out the next number
      # from it, whether subs is still the catalog clear replaces; clear makes
      # its swap through install. The line probe above cannot split two writes
      # on one line; this reader can. A class variable write cannot be hooked,
      # so it watches the step that feeds the write: + / - / succ / next on
      # the count, coerce when install puts the count on the right of the +,
      # and to_i / to_int when install turns the count into a plain Integer
      # first (.to_i + 1, Integer() + 1). That is a stronger rule than the
      # write order alone, and it is the rule here by design: install must
      # work out the next count after the swap, so a parallel assignment (its
      # right side runs before either write) or a count worked out ahead of
      # the swap is red even when the writes land in the right order. It
      # forwards everything else to the real count without recording, so an
      # install that reaches the next count by any step not listed here never
      # records and is red by design too.
      counter = SimpleDelegator.new(before_clear)
      note_catalog = -> { seen << (TextSubs.subs.equal?(old_catalog) ? :old : :new) }
      %i[+ succ next].each do |step|
        counter.define_singleton_method(step) do |by = 1|
          note_catalog.call
          before_clear + by
        end
      end
      counter.define_singleton_method(:-) do |by|
        note_catalog.call
        before_clear - by
      end
      %i[to_i to_int].each do |step|
        counter.define_singleton_method(step) do
          note_catalog.call
          before_clear
        end
      end
      counter.define_singleton_method(:coerce) do |other|
        note_catalog.call
        [other, before_clear]
      end
      TextSubs.class_variable_set(:@@generation, counter)
      begin
        expect(TextSubs.clear).to eq({})
      ensure
        # Still the stand-in means clear never wrote a count: put back the real
        # one, so the count check below sees what clear did, not a guess.
        TextSubs.class_variable_set(:@@generation, before_clear) if TextSubs.generation.equal?(counter)
      end
      expect(seen).to eq([:new])
      expect(TextSubs.generation).to eq(before_clear + 1)
      expect(TextSubs.subs).not_to equal(old_catalog)
    end

    it 'keeps the return values add, elanthipedia and clear had before the counter' do
      expect(TextSubs.add('cat', 'dog')).to eq('dog')
      expect(TextSubs.elanthipedia('Fae Arts')).to eq('\1<a href="https://elanthipedia.play.net/Fae_Arts">Fae Arts</a>\3')
      expect(TextSubs.clear).to eq({})
    end
  end

  describe 'TextSubs::Registry' do
    subject(:registry) { TextSubs::Registry.new }

    it 'keeps the first position of a key added twice and takes the value of the last add' do
      registry.add(/cat/, 'dog')
      registry.add(/c/, 'k')
      registry.add(/cat/, 'lion')
      expect(registry.snapshot.to_a).to eq([[/cat/, 'lion'], [/c/, 'k']])
    end

    it 'treats the same source with other options as another key' do
      registry.add(/cat/, 'dog')
      registry.add(/cat/i, 'lion')
      expect(registry.snapshot.to_a).to eq([[/cat/, 'dog'], [/cat/i, 'lion']])
    end

    it 'returns the value it was given, but keeps a frozen copy the caller cannot change' do
      value = +'dog'
      expect(registry.add(/cat/, value)).to equal(value)
      value << 'gone'
      expect(registry.snapshot[/cat/]).to eq('dog')
      expect(registry.snapshot[/cat/]).to be_frozen
    end

    it 'hands out a frozen snapshot, the same one until the next add' do
      registry.add(/cat/, 'dog')
      first = registry.snapshot
      expect(first).to be_frozen
      expect(registry.snapshot).to equal(first)
      expect { first[/bird/] = 'fish' }.to raise_error(FrozenError)

      registry.add(/bird/, 'fish')
      expect(registry.snapshot).not_to equal(first)
      expect(registry.snapshot.keys).to eq([/cat/, /bird/])
      expect(first.keys).to eq([/cat/])
    end

    it 'takes a new snapshot when an add only changes the value of a key it holds' do
      registry.add(/cat/, 'dog')
      first = registry.snapshot
      registry.add(/cat/, 'lion')
      expect(registry.snapshot).to eq(/cat/ => 'lion')
      expect(first).to eq(/cat/ => 'dog')
    end

    it 'starts empty and frozen' do
      expect(registry.snapshot).to eq({})
      expect(registry.snapshot).to be_frozen
    end

    it 'refuses a key that is not a Regexp and keeps what it holds' do
      registry.add(/cat/, 'dog')
      expect { registry.add('cat', 'lion') }.to raise_error(ArgumentError, /Regexps, not String/)
      expect { registry.add(nil, 'lion') }.to raise_error(ArgumentError, /not NilClass/)
      expect(registry.snapshot).to eq(/cat/ => 'dog')
    end

    it 'starts with no gate, and gates no key added without requires_any' do
      expect(registry.gates).to eq({})
      expect(registry.gates).to be_frozen
      registry.add(/cat/, 'dog')
      expect(registry.gates).to eq({})
    end

    it 'keeps a frozen copy of a gate the caller cannot change, with the same copy as the snapshot' do
      word = +'Kronar'
      words = [word]
      registry.add(/cat/, 'dog')
      registry.add(/\d+/, '#', requires_any: words)
      word << 's'
      words << 'Lirum'

      gates = registry.gates
      expect(gates).to eq(/\d+/ => ['Kronar'])
      expect(gates).to be_frozen
      expect(gates[/\d+/]).to be_frozen
      expect(gates[/\d+/]).to all(be_frozen)
      expect(registry.gates).to equal(gates)
      registry.add(/bird/, 'fish')
      expect(registry.gates).not_to equal(gates)
      expect(registry.gates).to eq(gates)
    end

    it 'takes the gate of the last add of a key, and drops it when that add has none' do
      registry.add(/\d+/, '#', requires_any: ['Kronar'])
      registry.add(/\d+/, '%', requires_any: ['Lirum'])
      expect(registry.gates).to eq(/\d+/ => ['Lirum'])

      registry.add(/\d+/, '&')
      expect(registry.gates).to eq({})
      expect(registry.snapshot).to eq(/\d+/ => '&')
    end

    [[], 'Kronar', [''], [1], [nil], ["Kr#{0xF6.chr(Encoding::UTF_8)}nar"], { 'Kronar' => true }].each do |bad|
      it "refuses requires_any #{bad.inspect} and keeps what it holds, the same snapshot included" do
        registry.add(/cat/, 'dog', requires_any: ['Kronar'])
        snapshot = registry.snapshot
        gates = registry.gates
        expect { registry.add(/cat/, 'lion', requires_any: bad) }
          .to raise_error(ArgumentError, /requires_any must be a non-empty list of non-empty ASCII words/)
        expect(registry.snapshot).to equal(snapshot)
        expect(registry.gates).to equal(gates)

        # A refused add leaves the version alone, so the snapshot above is the
        # cached copy. Another add forces a fresh copy of what is held.
        registry.add(/bird/, 'fish')
        expect(registry.snapshot).to eq(/cat/ => 'dog', /bird/ => 'fish')
        expect(registry.gates).to eq(/cat/ => ['Kronar'])
      end
    end

    it 'hands out the snapshot with an index over exactly its keys, the same pair until the next add' do
      registry.add(/cat/, 'dog')
      subs, index = registry.indexed_snapshot
      expect(subs).to equal(registry.snapshot)
      expect(registry.indexed_snapshot).to be_frozen
      expect(registry.indexed_snapshot.last).to equal(index)
      expect(index.candidates('The cat and the bird.')).to eq([/cat/])

      registry.add(/bird/, 'fish')
      newer_subs, newer_index = registry.indexed_snapshot
      expect(newer_subs).to equal(registry.snapshot)
      expect(newer_index.candidates('The cat and the bird.')).to eq([/cat/, /bird/])
      expect(index.candidates('The cat and the bird.')).to eq([/cat/])
    end

    describe '#drop' do
      it 'removes the key and its gate while it holds the value given, and takes a new snapshot' do
        registry.add(/cat/, 'dog')
        registry.add(/\d+/, '#', requires_any: ['Kronar'])
        before = registry.snapshot

        expect(registry.drop(/\d+/, before[/\d+/])).to be(true)
        expect(registry.snapshot).to eq(/cat/ => 'dog')
        expect(registry.gates).to eq({})
        expect(before.keys).to eq([/cat/, /\d+/])
        expect(registry.indexed_snapshot.last.candidates('7 Kronars')).to eq([])
      end

      it 'drops a nil value, which is held like any other' do
        registry.add(/cat/, nil)
        expect(registry.drop(/cat/, nil)).to be(true)
        expect(registry.snapshot).to eq({})
      end

      it 'leaves a key given another value since, even an equal one, and keeps the same snapshot' do
        registry.add(/cat/, 'dog')
        stale = registry.snapshot[/cat/]
        registry.add(/cat/, 'dog')
        current = registry.snapshot

        expect(registry.drop(/cat/, stale)).to be(false)
        expect(registry.snapshot).to equal(current)
        expect(registry.snapshot).to eq(/cat/ => 'dog')
      end

      it 'answers false for a key it does not hold, nil value included, and for a second drop' do
        expect(registry.drop(/cat/, nil)).to be(false)
        registry.add(/cat/, 'dog')
        value = registry.snapshot[/cat/]
        expect(registry.drop(/cat/, value)).to be(true)
        expect(registry.drop(/cat/, value)).to be(false)
      end

      it 'lets the key be added again, in last place' do
        registry.add(/cat/, 'dog')
        registry.add(/bird/, 'fish')
        registry.drop(/cat/, registry.snapshot[/cat/])
        registry.add(/cat/, 'lion')
        expect(registry.snapshot.to_a).to eq([[/bird/, 'fish'], [/cat/, 'lion']])
      end

      it 'records the drop as a change, and records nothing when it removes nothing' do
        registry.add(/cat/, 'dog')
        registry.add(/bird/, 'fish')
        registry.drop(/bird/, 'another fish')
        expect(registry.changes).to eq({})

        registry.drop(/cat/, registry.snapshot[/cat/])
        expect(registry.changes).to eq(/cat/ => [:drop])
      end
    end

    # A catalog built again for a new guild gets the changes made to the
    # installed one since it was built (TextSubs.reinstall).
    describe 'changes' do
      it 'records an add_change with a frozen copy of its value and its gate, but not a plain add' do
        value = +'dog'
        word = +'cat'
        gate = [word]
        registry.add(/built/, 'in')
        expect(registry.add_change(/cat/, value, requires_any: gate)).to equal(value)
        value << 'gone'
        word << 's'
        gate << ''

        expect(registry.snapshot).to eq(/built/ => 'in', /cat/ => 'dog')
        expect(registry.gates).to eq(/cat/ => ['cat'])
        expect(registry.changes).to eq(/cat/ => [:add, 'dog', ['cat']])
        expect(registry.changes[/cat/][1]).to be_frozen
        expect(registry.changes[/cat/][2]).to be_frozen
        expect(registry.changes[/cat/][2]).to all(be_frozen)
      end

      it 'replays a recorded gate even after the caller edits the list it passed' do
        gate = ['cat']
        registry.add_change(/cat/, 'dog', requires_any: gate)
        gate << ''

        rebuilt = TextSubs::Registry.new
        expect { rebuilt.replay(registry.changes) }.not_to raise_error
        expect(rebuilt.gates).to eq(/cat/ => ['cat'])
      end

      it 'hands out a frozen copy that later changes do not reach' do
        registry.add_change(/cat/, 'dog')
        changes = registry.changes
        registry.add_change(/bird/, 'fish')

        expect(changes).to be_frozen
        expect(changes.keys).to eq([/cat/])
        expect { changes[/owl/] = [:drop] }.to raise_error(FrozenError)
      end

      it 'records nothing for an add_change the registry refuses' do
        expect { registry.add_change('cat', 'dog') }.to raise_error(ArgumentError)
        expect { registry.add_change(/cat/, 'dog', requires_any: []) }.to raise_error(ArgumentError)
        expect(registry.changes).to eq({})
        expect(registry.snapshot).to eq({})
      end

      it 'keeps the last change of each key, in the order the keys took their places' do
        registry.add_change(/cat/, 'dog')
        registry.add_change(/bird/, 'fish')
        registry.add_change(/cat/, 'lion')
        expect(registry.changes.to_a).to eq([[/cat/, [:add, 'lion', nil]], [/bird/, [:add, 'fish', nil]]])
        expect(registry.snapshot.keys).to eq([/cat/, /bird/])

        registry.drop(/cat/, registry.snapshot[/cat/])
        registry.add_change(/cat/, 'tiger')
        expect(registry.changes.to_a).to eq([[/bird/, [:add, 'fish', nil]], [/cat/, [:add, 'tiger', nil]]])
        expect(registry.snapshot.keys).to eq([/bird/, /cat/])
      end

      describe '#replay' do
        subject(:rebuilt) { TextSubs::Registry.new }

        before do
          rebuilt.add(/fine/, 'FINE', requires_any: ['fine'])
          rebuilt.add(/raises/, 'built again')
          rebuilt.add(/owl/, 'hoot')
        end

        it 'adds each added key, over a value the catalog gave it, in its place, and appends the rest in order' do
          registry.add_change(/bird/, 'fish')
          registry.add_change(/owl/, 'HOOT')
          registry.add_change(/cat/, 'dog', requires_any: ['cat'])

          expect(rebuilt.replay(registry.changes)).to equal(rebuilt)
          expect(rebuilt.snapshot.to_a).to eq([[/fine/, 'FINE'], [/raises/, 'built again'], [/owl/, 'HOOT'],
                                               [/bird/, 'fish'], [/cat/, 'dog']])
          expect(rebuilt.gates).to eq(/fine/ => ['fine'], /cat/ => ['cat'])
        end

        it 'gives an added key with no gate none, as add would, even where the catalog gave it one' do
          registry.add_change(/fine/, 'MINE')
          rebuilt.replay(registry.changes)
          expect(rebuilt.snapshot[/fine/]).to eq('MINE')
          expect(rebuilt.gates).to eq({})
        end

        it 'removes each dropped key the catalog built again, and its gate' do
          registry.add(/raises/, nil)
          registry.add(/fine/, 'FINE', requires_any: ['fine'])
          registry.drop(/raises/, nil)
          registry.drop(/fine/, registry.snapshot[/fine/])

          rebuilt.replay(registry.changes)
          expect(rebuilt.snapshot.to_a).to eq([[/owl/, 'hoot']])
          expect(rebuilt.gates).to eq({})
          expect(rebuilt.indexed_snapshot.last.candidates('fine raises owl')).to eq([/owl/])
        end

        # Guild A builds the key and drops it, guild B does not build it,
        # guild C builds it again: it has to stay off all the way.
        it 'records a drop of a key the catalog did not build, so the catalog built after it leaves it out too' do
          registry.add(/gone/, nil)
          registry.drop(/gone/, nil)
          registry.add_change(/cat/, 'dog')

          rebuilt.replay(registry.changes)
          expect(rebuilt.snapshot.keys).to eq([/fine/, /raises/, /owl/, /cat/])
          expect(rebuilt.changes).to eq(/gone/ => [:drop], /cat/ => [:add, 'dog', nil])

          third = TextSubs::Registry.new
          third.add(/gone/, 'back')
          third.replay(rebuilt.changes)
          expect(third.snapshot).to eq(/cat/ => 'dog')
        end

        it 'replays an add after a drop as the add, and a drop after an add as the drop' do
          registry.add(/raises/, nil)
          registry.drop(/raises/, nil)
          registry.add_change(/raises/, 'fixed')
          registry.add_change(/owl/, 'HOOT')
          registry.drop(/owl/, registry.snapshot[/owl/])

          rebuilt.replay(registry.changes)
          expect(rebuilt.snapshot.to_a).to eq([[/fine/, 'FINE'], [/raises/, 'fixed']])
        end

        # Before the rebuild the re-added key runs last; after it, the key
        # runs where the catalog puts it (documented on record and replay).
        it 'puts a built-in key a script re-added after a drop back in its catalog place' do
          registry.add(/fine/, nil)
          registry.add(/owl/, 'hoot')
          registry.drop(/fine/, nil)
          registry.add_change(/fine/, 'MINE')
          expect(registry.snapshot.keys).to eq([/owl/, /fine/])

          rebuilt.replay(registry.changes)
          expect(rebuilt.snapshot.to_a).to eq([[/fine/, 'MINE'], [/raises/, 'built again'], [/owl/, 'hoot']])
        end

        it 'changes nothing for an empty change list' do
          before = rebuilt.snapshot
          rebuilt.replay(registry.changes)
          expect(rebuilt.snapshot).to equal(before)
          expect(rebuilt.changes).to eq({})
        end
      end
    end

    it 'gives the index the gates of the same copy, so a gated key stays out of a line without its word' do
      registry.add(/\d+/, '#', requires_any: ['Kronar'])
      _subs, index = registry.indexed_snapshot
      expect(index.candidates('7 coins')).to eq([])
      expect(index.candidates('7 Kronars')).to eq([/\d+/])

      registry.add(/\d+/, '#')
      expect(registry.indexed_snapshot.last.candidates('7 coins')).to eq([/\d+/])
    end
  end

  # The index picks the keys that may match a line, so a wrong tier would
  # silently drop a sub. These examples hold each tier, the tokenizer and
  # every construct the parser refuses to read to what the regex itself does
  # on a line.
  describe 'TextSubs::TokenIndex' do
    # @param source [String] regex source
    # @return [Array(Symbol, Object)] the tier of Regexp.new(source)
    def tier_of(source)
      TextSubs::TokenIndex.tier(Regexp.new(source))
    end

    {
      'You feel fine'                                           => [:words, ['feel']],
      # Of several whole words the longest is filed, the least common token.
      'You feel a bitter cold wind blow'                        => [:words, ['bitter']],
      '^Roundtime: \d+ sec'                                     => [:words, ['Roundtime']],
      'You feel (fine|good)\.'                                  => [:words, ['feel']],
      ' (fine|good|well) '                                      => [:words, %w[fine good well]],
      ' cat | dog '                                             => [:words, %w[cat dog]],
      '\d+ coins'                                               => [:prefix, 'coi'],
      ' glow\w*'                                                => [:prefix, 'glo'],
      'Kronars? '                                               => [:trigram, 'Kro'],
      '\w+ing '                                                 => [:suffix, 'ing'],
      '\wbcd\w'                                                 => [:trigram, 'bcd'],
      ':\s+\*\*--------'                                        => [:include, '**--------'],
      '[!-~]foo bar'                                            => [:suffix, 'foo'],
      'a.b'                                                     => [:always],
      '\d+'                                                     => [:always],
      '(?!.*>)\d{1,3}(?=(\d{3})+(?!\d).*(Kronar|Dokora|Lirum))' => [:always]
    }.each do |source, tier|
      it "files /#{source}/ under #{tier.inspect}" do
        expect(tier_of(source)).to eq(tier)
      end
    end

    it 'returns a frozen tier, frozen word lists included' do
      expect(tier_of('You feel fine')).to be_frozen
      expect(tier_of('You feel fine').last).to be_frozen
      expect(tier_of('a.b')).to be_frozen
    end

    it 'names a word-tier key only for a line that holds the word as a whole token' do
      index = TextSubs::TokenIndex.new([/You feel fine/])
      expect(index.candidates("You feel fine.\r\n")).to eq([/You feel fine/])
      expect(index.candidates("You feeling fine.\r\n")).to eq([])
      expect(index.candidates("You refeel fine.\r\n")).to eq([])
    end

    it 'names prefix, suffix and trigram keys for a token that starts with, ends with or holds the letters' do
      index = TextSubs::TokenIndex.new([/\d+ coins/, /\w+ing /, /\wbcd\w/])
      expect(index.candidates('7 coinage')).to eq([/\d+ coins/])
      expect(index.candidates('7 recoins')).to eq([])
      expect(index.candidates('a thing')).to eq([/\w+ing /])
      expect(index.candidates('a ingot')).to eq([])
      expect(index.candidates('xabcdx')).to eq([/\wbcd\w/])
      expect(index.candidates('abc dx')).to eq([])
    end

    it 'reads a class with a range as possibly a letter, however plain its ends are' do
      # '!' to '~' spans every letter, so the class can glue one to "foo".
      key = /[!-~]foo bar/
      expect(key).to match('Xfoo bar')
      expect(TextSubs::TokenIndex.new([key]).candidates('Xfoo bar')).to eq([key])
    end

    it 'names an include-tier key when the line holds its literal anywhere, between letters too' do
      index = TextSubs::TokenIndex.new([/:\s+\*\*--------/])
      expect(index.candidates('Quality:  **--------')).to eq([/:\s+\*\*--------/])
      expect(index.candidates('x**--------y')).to eq([/:\s+\*\*--------/])
      expect(index.candidates('Quality:  *---------')).to eq([])
    end

    it 'splits tokens at digits, underscores and high bytes, which the parser reads as non-letters' do
      # A tokenizer that kept digits or underscores in a token would see
      # "x_foo", "9foo" or "foo7" and miss the key all three lines match.
      key = /[_\d]foo[_\d]/
      expect(tier_of(key.source)).to eq([:words, ['foo']])
      index = TextSubs::TokenIndex.new([key])
      lines = ['x_foo_', '9foo7', "#{0xFE.chr}9foo7#{0xFE.chr}"]
      expect(lines).to all(match(key))
      expect(lines.map { |line| index.candidates(line) }).to eq([[key]] * 3)
    end

    it 'returns the candidates in insertion order, whichever tier and token found them' do
      keys = [/zeta/, /\d+ alpha/, /a.b/, /beta/, / mid/]
      index = TextSubs::TokenIndex.new(keys)
      expect(index.candidates('beta alpha zeta 7 alphas mid acb')).to eq(keys)
    end

    it 'leaves the line it reads alone, frozen or not, and is frozen itself' do
      index = TextSubs::TokenIndex.new([/cat/, /a.b/])
      line = 'The cat.'.b.freeze
      expect(index.candidates(line)).to eq([/cat/, /a.b/])
      expect(line).to eq('The cat.')
      expect(index).to be_frozen
    end

    it 'names nothing for an empty catalog' do
      expect(TextSubs::TokenIndex.new([]).candidates('The cat.')).to eq([])
    end

    # Each construct below makes the parser give up and check the key on
    # every line. Next to each is a line the key matches that does not hold,
    # as a whole token, the word a naive reading of the source would key it
    # on, so an index built on that reading would skip the line. The
    # numbered back-reference, (?i) and {n}? / {n}+ rows guard against a
    # plausible naive extractor only: a stricter one that refuses those
    # constructs outright would already check such keys on every line.
    {
      'a hex escape'                    => ['\x41bc def', 'Abc def', 'bc'],
      'an octal escape'                 => ['\101bc def', 'Abc def', 'bc'],
      'a \C- control escape'            => ['\C-abc def', "\x01bc def", 'abc'],
      'an escaped alphanumeric'         => ['\u0041bc def', 'Abc def', 'bc'],
      'a \c escape inside a class'      => ['[\c]a]bc def', 'abc def', 'bc'],
      'a \k<name> back-reference'       => ['(?<n>x)\k<n>bc def', 'xxbc def', 'bc'],
      'a \g<1> subexpression call'      => ['(x)\g<1>bc def', 'xxbc def', 'bc'],
      'a numbered back-reference'       => ['(\w+) \1zap ', 'ab abzap ', 'zap'],
      'an extended-mode flag'           => ['(?x) foo bar ', 'foobar', 'foo'],
      'a case-insensitive flag'         => ['(?i) Bar baz ', ' bar BAZ ', 'Bar'],
      'a scoped case-insensitive group' => [' (?i:Bar) baz ', ' bAR baz ', 'Bar'],
      'a nested class'                  => ['[a-z&&[^q]]foo bar', 'xfoo bar', 'foo'],
      'a POSIX class'                   => ['[[:alpha:]]foo bar', 'xfoo bar', 'foo'],
      'an optional fixed interval {n}?' => [',ab{1}?,', ',a,', 'ab'],
      'a repeated fixed interval {n}+'  => [',ab{1}+,', ',abbb,', 'ab']
    }.each do |construct, (source, line, naive)|
      it "checks a key with #{construct} on every line" do
        key = Regexp.new(source)
        expect(TextSubs::TokenIndex.tier(key)).to eq([:always])
        expect(key).to match(line)
        expect(line.scan(/[A-Za-z]+/)).not_to include(naive)
        expect(TextSubs::Engine.apply({ key => '<\0>' }, line.dup)).to eq(reference_apply({ key => '<\0>' }, line))
      end
    end

    it 'checks a key compiled with options on every line' do
      key = Regexp.new('Bar baz', Regexp::IGNORECASE)
      expect(TextSubs::TokenIndex.tier(key)).to eq([:always])
      expect(TextSubs::Engine.apply({ key => 'X' }, +'BAR BAZ')).to eq('X')
    end

    # A naive reading of 'cafe bar' with an accented e keys it on "bar", and skips it on a
    # binary line without that word. But a UTF-8 key raises on a binary line
    # with high bytes, as reference_apply does, so skipping it would change
    # what the engine does with the line.
    it 'checks a key with a non-ASCII source on every line, so it fails on a binary line as reference_apply does' do
      key = Regexp.new("caf#{0xE9.chr(Encoding::UTF_8)} bar")
      line = "#{0xFE.chr}lunch\r\n".b
      expect(TextSubs::TokenIndex.tier(key)).to eq([:always])
      expect { reference_apply({ key => 'X' }, line) }.to raise_error(Encoding::CompatibilityError)
      expect { TextSubs::Engine.apply({ key => 'X' }, line.dup) }.to raise_error(Encoding::CompatibilityError)
    end

    it 'checks only the three gated coin-comma rules of every catalog on every line' do
      always = every_key.select { |key| TextSubs::TokenIndex.tier(key) == [:always] }.map(&:source)
      expect(every_key.size).to be > 1_500
      expect(always).to contain_exactly(
        '(?!.*>)\d{1,3}(?=(\d{3})+(?!\d).*(Kronar|Dokora|Lirum))',
        '(?!.*>)\d{1,3}(?=((\d{3})*(\d{4}))(?!\d)(?! platinum).*(Kronar|Dokora|Lirum))',
        '(?!.*>)\d{1,3}(?=(\d{3})+(?!\d) platinum.*(Kronar|Dokora|Lirum))'
      )
    end

    # A small regex grammar. Each production gives [source, sample], where the
    # sample is a string the source matches unless a zero-width part fails
    # where it lands. It mixes the constructs the parser reads with the ones
    # it refuses, so every tier and the bail path all see thousands of lines.
    describe 'against a seeded fuzz of 2,000 generated regexes' do
      # @return [Array<String>] the plain words the grammar draws on, frozen
      def fuzz_words
        %w[ab abc abcd bca cab cabin xyz Roundtime You the fine Kronar].freeze
      end

      # @return [Hash{Symbol=>Array<Array(String, String)>}] leaf productions
      #   by kind, frozen
      def fuzz_leaves
        {
          separator: [[' ', ' '], [',', ','], [':', ':'], ['\.', '.'], ['\(', '('], ['-', '-'], ['_', '_'], ['7', '7'], ['>', '>'],
                      ['\s', ' '], ['\s+', '  '], ['\d', '4'], ['\d+', '12'], ['\W', '#'], ['\t', "\t"], ['_+', '__'],
                      ['[ ,.]', ','], ['[0-9]', '3'], ['[\d\s]', ' '], ['[-.]', '-'], ['[_7]', '_'],
                      ['--', '--'], ['\*\*', '**'], ['\.\.\.', '...'], [', ', ', ']],
          letters: %w[a b c].flat_map { |letter| [["#{letter}?", ''], ["#{letter}+", letter * 2], ["#{letter}*", ''], ["#{letter}{2,3}", letter * 3]] } +
            [['\w', 'k'], ['\w+', 'k9'], ['\h', 'f'], ['\D', 'z'], ['\S', 'q'], ['.', 'm'], ['.*', 'mn'], ['.+?', 'm'],
             ['[abc]', 'b'], ['[^a]', 'z'], ['[a-z]', 'm'], ['[!-/]', '#'], ['[!-~]', 'q'], ['[\w]', 'w']],
          zero_width: [['\b', ''], ['^', ''], ['$', ''], ['(?=a)', ''], ['(?!zz)', ''], ['(?<=\s)', ''], ['(?<!q)', ''], ['\A', ''], ['\z', '']],
          refused: [['\x41', 'A'], ['\101', 'A'], ['\u0042', 'B'], ['[[:alpha:]]', 'q'], ['\p{Alpha}', 'r'], ['(?i:ab)', 'AB'],
                    ['\C-a', "\x01"], ['[\c]a]', 'a'], ['b{1}+', 'bb'], ['b{1}?', ''], ['(?#note)', ''], ['(ab)\1', 'abab'],
                    ['(?<n>c)\k<n>', 'cc'], ['(x)\g<1>', 'xx'], ['(?x: a b )', 'ab']]
        }.freeze
      end

      # @param random [Random]
      # @return [Array(String, String)] one leaf: a plain word (most often),
      #   a separator, a letter-matching piece, a zero-width part, or (rarely)
      #   a construct the parser refuses
      def fuzz_leaf(random)
        roll = random.rand(100)
        return [fuzz_words.sample(random: random)] * 2 if roll < 40

        kind = if roll < 70 then :separator
               elsif roll < 85 then :letters
               elsif roll < 96 then :zero_width
               else :refused
               end
        fuzz_leaves[kind].sample(random: random)
      end

      # @param random [Random]
      # @param depth [Integer] group nesting so far
      # @return [Array(String, String)] [source, sample]
      def fuzz_node(random, depth)
        return fuzz_leaf(random) if depth >= 2 || random.rand(4).positive?

        parts = Array.new(random.rand(1..3)) { fuzz_node(random, depth + 1) }
        body = parts.map(&:first).join
        sample = parts.map(&:last).join
        # Only a group holding a plain word is quantified: a quantifier on a
        # group that is one repeat already makes Ruby warn.
        case random.rand(parts.any? { |source, _| fuzz_words.include?(source) } ? 8 : 4)
        when 0
          other_source, other_sample = fuzz_node(random, depth + 1)
          ["(?:#{body}|#{other_source})", random.rand(2).zero? ? sample : other_sample]
        when 1 then ["(#{body})", sample]
        when 2 then ["(?<g#{depth}>#{body})", sample]
        when 3 then ["(?>#{body})", sample]
        when 4 then ["(?:#{body})?", random.rand(2).zero? ? sample : '']
        when 5 then ["(?:#{body})+", sample * random.rand(1..2)]
        when 6 then ["(?:#{body}){1,2}", sample]
        else ["(?:#{body})*", '']
        end
      end

      # @param random [Random]
      # @return [Array(Regexp, String)] a compilable regex and its sample
      def fuzz_regex(random)
        loop do
          parts = Array.new(random.rand(2..6)) { fuzz_node(random, 0) }
          source = parts.map(&:first).join
          sample = parts.map(&:last).join
          if random.rand(6).zero?
            other = Array.new(random.rand(1..3)) { fuzz_node(random, 0) }
            source = "#{source}|#{other.map(&:first).join}"
          end
          return [Regexp.new(source), sample]
        rescue RegexpError
          next
        end
      end

      it 'gives reference_apply\'s output on every line, and names every key that matches a line' do
        random = Random.new(14_014)
        generated = Array.new(2_000) { fuzz_regex(random) }
        tiers = Hash.new(0)
        own_matches = 0
        pairs = 0
        skipped = 0
        missed = []
        mismatches = []
        generated.each_slice(50).with_index do |batch, batch_number|
          subs = batch.each_with_index.to_h { |(key, _), at| [key, "<#{batch_number}.#{at}>"] }
          index = TextSubs::TokenIndex.new(subs.keys)
          subs.each_key { |key| tiers[TextSubs::TokenIndex.tier(key).first] += 1 }
          own_matches += batch.count { |key, sample| key.match?(sample) }
          lines = batch.flat_map do |_, sample|
            [sample, "x#{sample}", "#{sample}x", "<b>#{sample}</b>", sample.swapcase, "zz #{sample} zz", "#{sample}\r\n"]
          end
          lines.each do |line|
            candidates = index.candidates(line)
            pairs += subs.size
            skipped += subs.size - candidates.size
            subs.each_key { |key| missed << [key.source, line] if key.match?(line) && !candidates.include?(key) }
            indexed = TextSubs::Engine.apply(subs, line.dup, index: index)
            expected = reference_apply(subs, line)
            mismatches << [line, indexed, expected] unless indexed == expected
          end
        end

        expect(missed).to eq([]), -> { "#{missed.size} key(s) left out of a line they match:\n#{missed.first(10).map(&:inspect).join("\n")}" }
        expect(mismatches).to eq([]), -> { "#{mismatches.size} line(s) differ:\n#{mismatches.first(10).map(&:inspect).join("\n")}" }
        # The fuzz is only worth something if the keys match their samples,
        # every tier is filled, and the index leaves many keys out (about
        # two in five keys are refused or have no letters, so it cannot
        # leave out most).
        expect(own_matches).to be > 1_200
        expect(tiers.keys).to contain_exactly(:words, :prefix, :suffix, :trigram, :include, :always)
        expect(tiers.values).to all(be >= 20), "tiers: #{tiers.inspect}"
        expect(skipped.fdiv(pairs)).to be > 0.4
      end
    end
  end

  describe 'TextSubs.install' do
    it 'makes the given Registry the catalog that subs, add and apply use' do
      registry = TextSubs::Registry.new
      registry.add(/cat/, 'dog')
      expect(TextSubs.install(registry)).to equal(registry)
      expect(TextSubs.subs).to eq(/cat/ => 'dog')

      TextSubs.add('bird', 'fish')
      expect(registry.snapshot.keys).to eq([/cat/, /bird/])
      expect(TextSubs.apply(+'The cat and the bird.')).to eq('The dog and the fish.')
    end

    it 'drops every key of the catalog it replaces' do
      TextSubs.add('cat', 'dog')
      TextSubs.install(TextSubs::Registry.new)
      expect(TextSubs.subs).to be_empty
      expect(TextSubs.apply(+'The cat.')).to eq('The cat.')
    end

    it 'goes up by exactly one generation, whatever the new Registry holds' do
      registry = TextSubs::Registry.new
      registry.add(/cat/, 'dog')
      registry.add(/bird/, 'fish')
      start = TextSubs.generation
      TextSubs.install(registry)
      expect(TextSubs.generation).to eq(start + 1)
    end

    it 'refuses anything but a Registry and leaves the catalog and the generation alone' do
      TextSubs.add('cat', 'dog')
      start = TextSubs.generation
      [nil, {}, { /cat/ => 'lion' }].each do |not_a_registry|
        expect { TextSubs.install(not_a_registry) }.to raise_error(ArgumentError, /TextSubs::Registry/)
      end
      expect(TextSubs.generation).to eq(start)
      expect(TextSubs.subs).to eq(/cat/ => 'dog')
    end
  end

  describe 'TextSubs.stage' do
    it 'sends add and elanthipedia to the staged Registry, leaving subs, apply and the generation alone' do
      TextSubs.add('cat', 'dog')
      installed = TextSubs.subs
      start = TextSubs.generation
      staged = TextSubs::Registry.new
      expect(TextSubs.stage(staged)).to equal(staged)

      TextSubs.add('bird', 'fish')
      TextSubs.elanthipedia('Fae Arts')
      expect(staged.snapshot.keys.map(&:source)).to eq(['bird', '()(Fae Arts)()'])
      expect(TextSubs.subs).to equal(installed)
      expect(TextSubs.apply(+'The cat and the bird.')).to eq('The dog and the bird.')
      expect(TextSubs.generation).to eq(start)
    end

    it 'ends with install of the staged Registry, which then takes add as the installed catalog' do
      staged = TextSubs.stage(TextSubs::Registry.new)
      TextSubs.add('cat', 'dog')
      start = TextSubs.generation
      TextSubs.install(staged)
      expect(TextSubs.subs).to eq(/cat/ => 'dog')
      expect(TextSubs.generation).to eq(start + 1)

      TextSubs.add('bird', 'fish')
      expect(TextSubs.generation).to eq(start + 2)
      TextSubs.clear
      TextSubs.add('cow', 'moo')
      expect(TextSubs.subs).to eq(/cow/ => 'moo')
      expect(staged.snapshot.keys).to eq([/cat/, /bird/])
    end

    it 'goes on staging when another Registry is installed meanwhile' do
      staged = TextSubs.stage(TextSubs::Registry.new)
      TextSubs.clear
      TextSubs.add('cat', 'dog')
      expect(TextSubs.subs).to eq({})
      expect(staged.snapshot).to eq(/cat/ => 'dog')
    end

    it 'refuses anything but a Registry and leaves the staging alone' do
      staged = TextSubs.stage(TextSubs::Registry.new)
      [nil, {}, { /cat/ => 'lion' }].each do |not_a_registry|
        expect { TextSubs.stage(not_a_registry) }.to raise_error(ArgumentError, /TextSubs.stage needs a TextSubs::Registry/)
      end
      TextSubs.add('cat', 'dog')
      expect(staged.snapshot).to eq(/cat/ => 'dog')
      expect(TextSubs.subs).to eq({})
    end
  end

  describe 'TextSubs.unstage' do
    it 'ends the staging without installing it, so add reaches the installed catalog again' do
      TextSubs.add('cat', 'dog')
      installed = TextSubs.subs
      start = TextSubs.generation
      staged = TextSubs.stage(TextSubs::Registry.new)
      TextSubs.add('bird', 'fish')

      expect(TextSubs.unstage(staged)).to be(true)
      expect(TextSubs.subs).to equal(installed)
      expect(TextSubs.generation).to eq(start)

      TextSubs.add('cow', 'moo')
      expect(TextSubs.subs).to eq(/cat/ => 'dog', /cow/ => 'moo')
      expect(staged.snapshot).to eq(/bird/ => 'fish')
    end

    it 'leaves a newer staging alone, and does nothing once the Registry is installed' do
      first = TextSubs.stage(TextSubs::Registry.new)
      second = TextSubs.stage(TextSubs::Registry.new)
      expect(TextSubs.unstage(first)).to be(false)
      TextSubs.add('cat', 'dog')
      expect(second.snapshot).to eq(/cat/ => 'dog')

      TextSubs.install(second)
      expect(TextSubs.unstage(second)).to be(false)
      TextSubs.add('bird', 'fish')
      expect(TextSubs.subs).to eq(/cat/ => 'dog', /bird/ => 'fish')
    end

    it 'refuses anything but a Registry and leaves the staging alone' do
      staged = TextSubs.stage(TextSubs::Registry.new)
      [nil, {}, { /cat/ => 'lion' }].each do |not_a_registry|
        expect { TextSubs.unstage(not_a_registry) }.to raise_error(ArgumentError, /TextSubs.unstage needs a TextSubs::Registry/)
      end
      TextSubs.add('cat', 'dog')
      expect(staged.snapshot).to eq(/cat/ => 'dog')
    end

    it 'records an add made while staged as a change, so a guild rebuild after the install keeps it' do
      staged = TextSubs.stage(TextSubs::Registry.new)
      staged.add(/fine/, 'FINE')
      TextSubs.add('cat', 'dog')
      TextSubs.install(staged)

      TextSubs.reinstall(TextSubs::Registry.new.tap { |registry| registry.add(/fine/, 'FINE') })
      expect(TextSubs.subs).to eq(/fine/ => 'FINE', /cat/ => 'dog')
    end
  end

  describe 'TextSubs.reinstall' do
    # @return [TextSubs::Registry] a catalog as if built again, not installed
    def built_again
      TextSubs::Registry.new.tap do |registry|
        registry.add(/fine/, 'FINE')
        registry.add(/raises/, 'again')
      end
    end

    before do
      registry = TextSubs.install(TextSubs::Registry.new)
      registry.add(/fine/, 'FINE')
      registry.add(/raises/, nil)
    end

    it 'installs the catalog with the subs added since the start and without the subs apply dropped, in one generation' do
      TextSubs.add('cat', 'dog')
      TextSubs.elanthipedia('Zephyr', '^')
      TextSubs.apply(+'raises')
      start = TextSubs.generation
      registry = built_again

      expect(TextSubs.reinstall(registry)).to equal(registry)
      expect(TextSubs.generation).to eq(start + 1)
      expect(TextSubs.subs.keys).to eq([/fine/, /cat/, /(^)(Zephyr)()/])
      expect(TextSubs.apply(+'fine cat raises')).to eq('FINE dog raises')
      expect(displayed_messages.grep(/the sub "raises" raised/).size).to eq(1)
    end

    it 'keeps them through every rebuild after it' do
      TextSubs.add('cat', 'dog')
      TextSubs.apply(+'raises')
      TextSubs.reinstall(built_again)
      TextSubs.reinstall(built_again)
      expect(TextSubs.subs).to eq(/fine/ => 'FINE', /cat/ => 'dog')
    end

    it 'keeps the changes the catalog it replaces got after the last rebuild, too' do
      TextSubs.reinstall(built_again)
      TextSubs.add('cat', 'dog')
      TextSubs.reinstall(built_again)
      expect(TextSubs.subs).to eq(/fine/ => 'FINE', /raises/ => 'again', /cat/ => 'dog')
    end

    it 'carries nothing over for a catalog nothing changed, and nothing from before an install or a clear' do
      TextSubs.reinstall(built_again)
      expect(TextSubs.subs).to eq(/fine/ => 'FINE', /raises/ => 'again')

      TextSubs.add('cat', 'dog')
      TextSubs.clear
      TextSubs.reinstall(built_again)
      expect(TextSubs.subs).to eq(/fine/ => 'FINE', /raises/ => 'again')

      TextSubs.add('cat', 'dog')
      TextSubs.install(TextSubs::Registry.new)
      TextSubs.reinstall(built_again)
      expect(TextSubs.subs).to eq(/fine/ => 'FINE', /raises/ => 'again')
    end

    it 'refuses anything but a Registry, replaying and installing nothing' do
      TextSubs.add('cat', 'dog')
      start = TextSubs.generation
      before = TextSubs.subs
      [nil, {}, { /cat/ => 'lion' }].each do |not_a_registry|
        expect { TextSubs.reinstall(not_a_registry) }.to raise_error(ArgumentError, /TextSubs.reinstall needs a TextSubs::Registry/)
      end
      expect(TextSubs.generation).to eq(start)
      expect(TextSubs.subs).to equal(before)
    end

    describe 'given the token start_run gave a start' do
      it 'installs the catalog while that run is the latest start, though another script staged a Registry since' do
        run = TextSubs.start_run
        TextSubs.install(TextSubs.stage(TextSubs::Registry.new))
        Thread.new { TextSubs.stage(TextSubs::Registry.new) }.join
        start = TextSubs.generation
        registry = built_again

        expect(TextSubs.reinstall(registry, run: run)).to equal(registry)
        expect(TextSubs.generation).to eq(start + 1)
        expect(TextSubs.subs).to eq(/fine/ => 'FINE', /raises/ => 'again')
      end

      it 'installs nothing, and returns nil, once a newer start has taken its token, even before that start installs' do
        run = TextSubs.start_run
        TextSubs.install(TextSubs.stage(TextSubs::Registry.new))
        TextSubs.add('cat', 'dog')
        Thread.new { TextSubs.start_run }.join
        start = TextSubs.generation
        before = TextSubs.subs

        expect(TextSubs.reinstall(built_again, run: run)).to be_nil
        expect(TextSubs.generation).to eq(start)
        expect(TextSubs.subs).to equal(before)
        expect(TextSubs.subs).to eq(/cat/ => 'dog')
      end
    end
  end

  # Each of these runs one step on this thread and, at the gap inside it
  # where another thread could get in between a check and the change it
  # leads to, starts another thread's step. Without the lock that step lands
  # in the gap; with it, it waits until this thread's step is done. The gaps
  # are reached through a stand-in, not a TracePoint: a probe of C calls
  # left the examples after it measurably slower.
  describe 'one step at a time across threads' do
    # Starts interloper on a thread of its own, once, and gives it 20 ms to
    # finish before this thread goes on.
    #
    # @param state [Hash] holds :other, the interloper's thread, once started
    # @param interloper [Proc] the other thread's step
    # @return [void]
    def start_interloper(state, interloper)
      return if state.key?(:other)

      state[:other] = nil
      state[:other] = Thread.new(&interloper)
      state[:other].join(0.02)
    end

    # Waits for the interloper, failing when the gap was never reached.
    #
    # @param state [Hash] as start_interloper filled it
    # @param gap [String] what the gap was, for the message
    # @return [void]
    # @raise [RuntimeError] when the interloper never started
    def finish_interloper(state, gap)
      raise "the step never reached #{gap}" unless state[:other]

      state[:other].join
    end

    # Runs block on this thread with registry's equal? starting interloper
    # right after it answers a call made from the line of textsubs.lic whose
    # stripped text is line: the gap between that check and what follows.
    #
    # @param registry [TextSubs::Registry] the Registry the step checks
    # @param line [String] the stripped text of the checking line
    # @param interloper [Proc] the other thread's step
    # @return [Object] what block returns
    def with_interloper_after_check(registry, line:, interloper:)
      source = File.readlines(lic_path('textsubs.lic'))
      state = {}
      start = method(:start_interloper)
      registry.define_singleton_method(:equal?) do |other|
        answer = super(other)
        site = caller_locations(1, 1).first
        start.call(state, interloper) if File.basename(site.path) == 'textsubs.lic' && source[site.lineno - 1].strip == line
        answer
      end
      result = yield
      finish_interloper(state, line.inspect)
      result
    end

    # Runs block on this thread with the generation count replaced by a
    # stand-in whose + starts interloper before it answers: the gap between
    # reading the count and writing the next one. The real count is put back
    # if block never wrote one.
    #
    # @param interloper [Proc] the other thread's step
    # @return [Object] what block returns
    def with_interloper_in_count(interloper:)
      real = TextSubs.generation
      state = {}
      start = method(:start_interloper)
      counter = SimpleDelegator.new(real)
      counter.define_singleton_method(:+) do |by|
        start.call(state, interloper)
        real + by
      end
      TextSubs.class_variable_set(:@@generation, counter)
      begin
        result = yield
      ensure
        TextSubs.class_variable_set(:@@generation, real) if TextSubs.generation.equal?(counter)
      end
      finish_interloper(state, 'the count')
      result
    end

    # Runs block on this thread with registry's replay starting interloper
    # before it replays a change: the gap between reinstall reading the
    # changes of the installed catalog and swapping registry in.
    #
    # @param registry [TextSubs::Registry] the catalog built again, which
    #   block hands to reinstall
    # @param interloper [Proc] the other thread's step
    # @return [Object] what block returns
    def with_interloper_in_replay(registry, interloper:)
      state = {}
      start = method(:start_interloper)
      registry.define_singleton_method(:replay) do |changes|
        start.call(state, interloper)
        super(changes)
      end
      result = yield
      finish_interloper(state, 'the replay')
      result
    end

    it 'lets no stage of another thread land between the check in unstage and the change' do
      first = TextSubs.stage(TextSubs::Registry.new)
      second = TextSubs::Registry.new

      ended = with_interloper_after_check(first, line: 'return false unless registry.equal?(@@staged)',
                                                 interloper: -> { TextSubs.stage(second) }) do
        TextSubs.unstage(first)
      end

      expect(ended).to be(true)
      TextSubs.add('cat', 'dog')
      expect(second.snapshot).to eq(/cat/ => 'dog')
      expect(TextSubs.subs).to eq({})
    end

    it 'lets no stage of another thread land between the check in install and the end of the staging' do
      first = TextSubs.stage(TextSubs::Registry.new)
      second = TextSubs::Registry.new

      with_interloper_after_check(first, line: '@@staged = nil if registry.equal?(@@staged)',
                                         interloper: -> { TextSubs.stage(second) }) do
        expect(TextSubs.install(first)).to equal(first)
      end

      TextSubs.add('cat', 'dog')
      expect(second.snapshot).to eq(/cat/ => 'dog')
      expect(TextSubs.subs).to eq({})
    end

    it 'counts an add and an install on another thread once each, never one number for both' do
      start = TextSubs.generation

      with_interloper_in_count(interloper: -> { TextSubs.install(TextSubs::Registry.new) }) do
        TextSubs.add('cat', 'dog')
      end

      expect(TextSubs.generation).to eq(start + 2)
    end

    it 'counts the empty catalog a start installs and an install on another thread once each' do
      start = TextSubs.generation
      other = TextSubs::Registry.new

      with_interloper_in_count(interloper: -> { TextSubs.install(other) }) do
        reload_lic_class('textsubs.lic', 'TextSubs')
      end

      expect(TextSubs.generation).to eq(start + 2)
      expect(TextSubs.subs).to equal(other.snapshot)
    end

    # The add starts while the catalog built again takes the changes over: it
    # must land before they are read, or after the swap in the new catalog,
    # never in the catalog being replaced.
    it 'keeps an add another thread makes while reinstall replays the changes onto the catalog built again' do
      TextSubs.add('cat', 'dog')
      built_again = TextSubs::Registry.new.tap { |registry| registry.add(/fine/, 'FINE') }

      with_interloper_in_replay(built_again, interloper: -> { TextSubs.add('late', 'LATE') }) do
        expect(TextSubs.reinstall(built_again)).to equal(built_again)
      end

      expect(TextSubs.subs).to eq(/fine/ => 'FINE', /cat/ => 'dog', /late/ => 'LATE')
    end

    # A drop is a change too: it must land before the changes are read, and
    # be replayed, or after the swap, on the new catalog, never in the one
    # being replaced, where the replay would bring the sub back.
    it 'keeps a sub apply drops on another thread while reinstall replays the changes off, reporting it once' do
      TextSubs.add('boom', nil)
      built_again = TextSubs::Registry.new.tap { |registry| registry.add(/fine/, 'FINE') }

      with_interloper_in_replay(built_again, interloper: -> { TextSubs.apply(+'boom') }) do
        expect(TextSubs.reinstall(built_again)).to equal(built_again)
      end

      expect(TextSubs.subs).to eq(/fine/ => 'FINE')
      expect(TextSubs.apply(+'boom fine')).to eq('boom FINE')
      expect(displayed_messages.grep(/the sub "boom" raised/).size).to eq(1)
    end

    it 'counts a drop on the hook thread and an add on another thread once each, never one number for both' do
      TextSubs.add('boom', nil)
      start = TextSubs.generation

      with_interloper_in_count(interloper: -> { TextSubs.add('cat', 'dog') }) do
        TextSubs.apply(+'boom')
      end

      expect(TextSubs.generation).to eq(start + 2)
      expect(TextSubs.subs).to eq(/cat/ => 'dog')
    end

    # The public writers that take a registry: called without one, each
    # writes the catalog being built as it stands once the lock is theirs,
    # not the one that stood when they were called.
    it 'keeps private subs another thread adds while reinstall replays the changes, in the catalog built again' do
      built_again = TextSubs::Registry.new.tap { |registry| registry.add(/fine/, 'FINE') }

      with_interloper_in_replay(built_again, interloper: -> { TextSubs.add_private([[/late/, 'LATE', '"late"']]) }) do
        expect(TextSubs.reinstall(built_again)).to equal(built_again)
      end

      expect(TextSubs.subs).to eq(/fine/ => 'FINE', /late/ => 'LATE')
    end

    it 'keeps built-in subs another thread adds while reinstall replays the changes, in the catalog built again' do
      built_again = TextSubs::Registry.new.tap { |registry| registry.add(/fine/, 'FINE') }
      data = { 'schema' => TextSubs::Catalog.schema, 'sections' => [{ 'name' => 'late', 'subs' => [%w[late LATE]] }] }
      context = TextSubs::Context.new(guild: 'Bard', settings: OpenStruct.new)
      add_catalog = -> { TextSubs.add_catalog(data, context, file: 'data/base-textsubs.yaml') }

      with_interloper_in_replay(built_again, interloper: add_catalog) do
        expect(TextSubs.reinstall(built_again)).to equal(built_again)
      end

      expect(TextSubs.subs).to eq(/fine/ => 'FINE', /late/ => 'LATE')
    end

    # The installed catalog lacks the key, so a check made before the lock
    # is taken (on that catalog) would give nothing back.
    it 'gives a private value back on the catalog built again when another thread prefers it during the replay' do
      built_again = TextSubs::Registry.new.tap { |registry| registry.add(/fine/, 'FINE') }
      warnings = nil
      prefer = -> { warnings = TextSubs.prefer_private([[/fine/, 'MINE', '"fine"']]) }

      with_interloper_in_replay(built_again, interloper: prefer) do
        expect(TextSubs.reinstall(built_again)).to equal(built_again)
      end

      expect(TextSubs.subs).to eq(/fine/ => 'MINE')
      expect(warnings).to eq(['private_textsubs "fine" is also a built-in sub; your replacement is used instead of the built-in one.'])
    end
  end

  describe 'TextSubs.subs' do
    it 'is a frozen snapshot, in the order the keys were first added, that cannot change the catalog' do
      TextSubs.add('cat', 'dog')
      TextSubs.add('bird', 'fish')
      TextSubs.add('cat', 'lion')
      subs = TextSubs.subs

      expect(subs.to_a).to eq([[/cat/, 'lion'], [/bird/, 'fish']])
      expect(subs).to be_frozen
      expect(subs.values).to all(be_frozen)
      expect { subs[/eel/] = 'ray' }.to raise_error(FrozenError)
      expect { subs.delete(/cat/) }.to raise_error(FrozenError)
      expect { subs[/cat/] << '!' }.to raise_error(FrozenError)
      expect(TextSubs.apply(+'The cat.')).to eq('The lion.')
    end

    it 'keeps an earlier snapshot as it was after later adds and a clear' do
      TextSubs.add('cat', 'dog')
      before = TextSubs.subs
      TextSubs.add('bird', 'fish')
      TextSubs.clear
      expect(before).to eq(/cat/ => 'dog')
      expect(TextSubs.subs).to eq({})
      expect(TextSubs.subs).to be_frozen
    end
  end

  describe 'TextSubs.elanthipedia' do
    before { TextSubs.clear }

    it 'wraps the text in (pretext)(text)(postext) and puts groups 1 and 3 back around the link by default' do
      TextSubs.elanthipedia('Fae Arts', '^', ':', 'Category:', '_spellbook')
      expect(TextSubs.subs.keys).to eq([/(^)(Fae Arts)(:)/])
      expect(TextSubs.apply(+"Fae Arts:\r\n"))
        .to eq(%(<a href="https://elanthipedia.play.net/Category:Fae_Arts_spellbook">Fae Arts</a>:\r\n))
    end

    it 'adds poslink after the underscored page name, and prelink before it' do
      TextSubs.elanthipedia('Holy Defense', '', '', 'Category:', '_spellbook')
      expect(TextSubs.subs.values).to eq(['\1<a href="https://elanthipedia.play.net/Category:Holy_Defense_spellbook">Holy Defense</a>\3'])
    end

    it 'replaces the context with preresult and posresult when they are given' do
      TextSubs.elanthipedia('Fae Arts', '(?:the )', '(?: book)', '', '', '[', ']')
      expect(TextSubs.apply(+'Read the Fae Arts book.'))
        .to eq('Read [<a href="https://elanthipedia.play.net/Fae_Arts">Fae Arts</a>].')
    end

    it 'builds the key from pretext, text and postext only, and reads a backslash in the link arguments as a backreference' do
      TextSubs.elanthipedia('Fae Arts', '^', ':', '\3', '_\3', '(', ')')
      expect(TextSubs.subs.keys).to eq([/(^)(Fae Arts)(:)/])
      expect(TextSubs.apply(+'Fae Arts:'))
        .to eq('(<a href="https://elanthipedia.play.net/:Fae_Arts_:">Fae Arts</a>)')
    end

    it 'matches a regex escape in text in the key, and shows it verbatim in the link and the page name' do
      TextSubs.elanthipedia('Fae\\sArts', '^', ':')
      expect(TextSubs.subs.keys).to eq([/(^)(Fae\sArts)(:)/])
      expect(TextSubs.apply(+'Fae Arts:'))
        .to eq('<a href="https://elanthipedia.play.net/Fae\\sArts">Fae\\sArts</a>:')
    end

    it 'reads a substitution in text as gsub replacement text, in the link and in the page name' do
      # \& in the key matches a literal '&'; in the replacement it is the whole
      # match, postext included, put between 'Salt' and 'Pepper' in both copies.
      TextSubs.elanthipedia('Salt\\&Pepper', '^', ':')
      expect(TextSubs.apply(+'Salt&Pepper:'))
        .to eq('<a href="https://elanthipedia.play.net/SaltSalt&Pepper:Pepper">SaltSalt&Pepper:Pepper</a>:')
    end
  end

  describe 'TextSubs.wiki_link' do
    it 'is the anchor elanthipedia puts between preresult and posresult' do
      TextSubs.clear
      TextSubs.elanthipedia('Fae Arts', '^', ':', 'Category:', '_spellbook', '[', ']')
      expect(TextSubs.subs.values)
        .to eq(["[#{TextSubs.wiki_link('Category:Fae_Arts_spellbook', 'Fae Arts')}]"])
      expect(TextSubs.wiki_link('Category:Fae_Arts_spellbook', 'Fae Arts'))
        .to eq('<a href="https://elanthipedia.play.net/Category:Fae_Arts_spellbook">Fae Arts</a>')
    end
  end

  describe 'TextSubs::Context' do
    let(:settings) { OpenStruct.new(herb_textsubs: true, textsubs_spell_links: false, textsubs_use_plat_grouping: nil) }

    def context_for(guild)
      TextSubs::Context.new(guild: guild, settings: settings)
    end

    it 'lets a section without a gate through for every guild, and for a guild not known yet' do
      expect([context_for('Bard'), context_for(nil)].map { |context| context.allows?(nil) }).to eq([true, true])
    end

    it 'lets a guilds gate through only for a guild it names' do
      gate = { 'guilds' => ['Moon Mage', 'Trader'] }
      expect(%w[Trader Bard].map { |guild| context_for(guild).allows?(gate) }).to eq([true, false])
      expect(context_for('Moon Mage').allows?(gate)).to be(true)
      expect(context_for(nil).allows?(gate)).to be(false)
    end

    it 'lets a not_guilds gate through for every guild it does not name, but not for a guild not known yet' do
      gate = { 'not_guilds' => %w[Barbarian Thief] }
      expect(%w[Thief Barbarian Cleric].map { |guild| context_for(guild).allows?(gate) }).to eq([false, false, true])
      expect(context_for(nil).allows?(gate)).to be(false)
    end

    # The unknown guild may turn out to be one the gate names, so a section
    # gated on guilds waits for it whichever way the gate is put.
    it 'lets no guild gate through for a guild not known yet, even beside a setting that holds' do
      unknown = context_for(nil)
      expect(unknown.allows?('not_guilds' => ['Commoner'], 'setting' => 'herb_textsubs')).to be(false)
      expect(unknown.allows?('guilds' => TextSubs::Context.guilds)).to be(false)
      expect(unknown.allows?('setting' => 'herb_textsubs')).to be(true)
      expect(unknown.guild).to be_nil
    end

    it 'reads setting as set and setting_off as nil or false, by name' do
      bard = context_for('Bard')
      expect(bard.allows?('setting' => 'herb_textsubs')).to be(true)
      expect(%w[textsubs_spell_links textsubs_use_plat_grouping not_a_key].map { |name| bard.allows?('setting' => name) })
        .to eq([false, false, false])
      expect(%w[textsubs_spell_links textsubs_use_plat_grouping not_a_key].map { |name| bard.allows?('setting_off' => name) })
        .to eq([true, true, true])
      expect(bard.allows?('setting_off' => 'herb_textsubs')).to be(false)
    end

    it 'counts any value but nil and false as set, 0 and an empty string included' do
      context = TextSubs::Context.new(guild: 'Bard', settings: OpenStruct.new(zero: 0, blank: ''))
      expect(%w[zero blank].map { |name| context.allows?('setting' => name) }).to eq([true, true])
    end

    it 'needs every key of a gate to hold, not just one' do
      gate = { 'guilds' => ['Bard'], 'setting' => 'textsubs_spell_links' }
      expect(context_for('Bard').allows?(gate)).to be(false)
      expect(context_for('Bard').allows?(gate.merge('setting' => 'herb_textsubs'))).to be(true)
      expect(context_for('Cleric').allows?(gate.merge('setting' => 'herb_textsubs'))).to be(false)
    end

    {
      'a misspelt key'               => [{ 'guild' => ['Bard'] }, /unknown 'when' key\(s\) "guild"/],
      'an empty mapping'             => [{}, /'when' is empty/],
      'a bare guild name'            => ['Bard', /'when' must be a mapping, not String/],
      'guilds as a string'           => [{ 'guilds' => 'Bard' }, /'when' guilds must be a non-empty list/],
      'an empty guild list'          => [{ 'not_guilds' => [] }, /'when' not_guilds must be a non-empty list/],
      'a misspelt guild'             => [{ 'guilds' => %w[Bard Moonmage] }, /unknown guild\(s\) "Moonmage"/],
      'a guild in lower case'        => [{ 'guilds' => ['bard'] }, /unknown guild\(s\) "bard"/],
      'a setting that is not a name' => [{ 'setting' => true }, /'when' setting must be a setting name/],
      'an empty setting_off'         => [{ 'setting_off' => '' }, /'when' setting_off must be a setting name/]
    }.each do |label, (gate, message)|
      it "refuses #{label}, in check_gate and in allows? alike" do
        expect { TextSubs::Context.check_gate(gate) }.to raise_error(ArgumentError, message)
        expect { context_for('Bard').allows?(gate) }.to raise_error(ArgumentError, message)
      end
    end

    it 'knows the twelve guilds the golden catalog is built for' do
      expect(TextSubs::Context.guilds).to eq(guilds)
      expect(TextSubs::Context.guilds).to be_frozen
    end
  end

  describe 'TextSubs::Catalog.entries' do
    let(:settings) { OpenStruct.new(herb_textsubs: true, textsubs_spell_links: false) }

    # Parses a small catalog, as data/base-textsubs.yaml would hold it, and
    # freezes it throughout, so an example also proves the catalog changes
    # nothing.
    #
    # @param yaml [String] the file text, top-level `textsubs:` key included
    # @return [Hash, nil] the `textsubs:` value
    def catalog_data(yaml)
      YAML.safe_load(yaml, freeze: true)['textsubs']
    end

    def entries_for(guild, data)
      TextSubs::Catalog.entries(data, TextSubs::Context.new(guild: guild, settings: settings))
    end

    let(:three_sections) do
      catalog_data(<<~YAML)
        textsubs:
          schema: 1
          sections:
            - name: 'everyone, first'
              subs:
                - ['b', 'B']
                - ['a', 'A']
            - name: 'Bards only'
              when:
                guilds: ['Bard']
              kind: 'pairs'
              subs:
                - ['song', 'SONG']
            - name: 'herb setting on'
              when:
                setting: 'herb_textsubs'
              subs:
                - ['c', 'C']
      YAML
    end

    it 'gives the subs of every selected section, sections in file order and subs in list order' do
      expect(entries_for('Bard', three_sections).map { |source, replacement, _meta| [source, replacement] })
        .to eq([%w[b B], %w[a A], %w[song SONG], %w[c C]])
    end

    it 'leaves out a section whose gate does not hold, and nothing else' do
      expect(entries_for('Cleric', three_sections).map(&:first)).to eq(%w[b a c])
    end

    it 'names the section each sub came from in a frozen meta' do
      metas = entries_for('Bard', three_sections).map(&:last)
      expect(metas).to eq([{ section: 'everyone, first' }, { section: 'everyone, first' },
                           { section: 'Bards only' }, { section: 'herb setting on' }])
      expect(metas).to all(be_frozen)
    end

    # add_catalog stores these keys, so each has to be the key TextSubs.add
    # would store for the source the YAML gives (eql? and the same hash, as a
    # Hash key needs, and frozen, as the /#{source}/ add compiles is). The
    # sources are written out here rather than read back from the keys, so a
    # key compiled from the wrong sub's pattern fails too.
    it 'gives the same subs through keyed_entries, each key the one add would store for its source' do
      data = catalog_data(<<~'YAML')
        textsubs:
          schema: 1
          sections:
            - name: 'keys'
              subs:
                - ['^(It is labeled) "Burden\."', 'x']
                - ['a/b', 'y']
                - ['(?<n>\d+) coins?', 'z']
      YAML
      context = TextSubs::Context.new(guild: 'Bard', settings: settings)
      sources = ['^(It is labeled) "Burden\\."', 'a/b', '(?<n>\\d+) coins?']
      keyed = TextSubs::Catalog.keyed_entries(data, context)

      expect(keyed.map { |_key, replacement, meta| [replacement, meta] })
        .to eq([['x', { section: 'keys' }], ['y', { section: 'keys' }], ['z', { section: 'keys' }]])
      keyed.map(&:first).zip(sources).each do |key, source|
        expect(key.source).to eq(source)
        expect(key).to eql(/#{source}/)
        expect(key.hash).to eq(/#{source}/.hash)
        expect(key).to be_frozen
      end
    end

    it 'adds the requires_any words of a gated section to the meta of each of its subs' do
      data = catalog_data(<<~YAML)
        textsubs:
          schema: 1
          sections:
            - name: 'coins'
              requires_any: ['Kronar', 'Lirum']
              subs:
                - ['\\d+(?=.*Kronar)', '#']
                - ['\\d+(?=.*Lirum)', '%']
            - name: 'plain'
              subs:
                - ['a', 'A']
      YAML
      metas = entries_for('Bard', data).map(&:last)
      expect(metas).to eq([{ section: 'coins', requires_any: %w[Kronar Lirum] }] * 2 + [{ section: 'plain' }])
      expect(metas).to all(be_frozen)
    end

    it 'reads backslashes, quotes and colons in single-quoted scalars as they are written' do
      data = catalog_data(<<~'YAML')
        textsubs:
          schema: 1
          sections:
            - name: 'escapes'
              subs:
                - ['^(It is labeled) "Burden\."', '\1 "Burden." (it''s: Analogous Patterns)']
      YAML
      expect(entries_for('Bard', data).map { |source, replacement, _meta| [source, replacement] })
        .to eq([['^(It is labeled) "Burden\\."', '\\1 "Burden." (it\'s: Analogous Patterns)']])
    end

    describe 'the guild spell list link' do
      let(:data) do
        catalog_data(<<~YAML)
          textsubs:
            schema: 1
            sections:
              - name: 'guild spells'
                kind: 'guild_spells_link'
                pattern: 'You recall the spells you have learned from your training.'
                preresult: 'You recall the spells you have learned from your '
                prelink: 'Category:'
                poslink: '_spells'
                posresult: ' training.'
        YAML
      end

      it "links the guild's category page, underscores in the page and spaces in the text" do
        expect(entries_for('Moon Mage', data).map { |source, replacement, _meta| [source, replacement] })
          .to eq([['You recall the spells you have learned from your training.',
                   'You recall the spells you have learned from your ' \
                   '<a href="https://elanthipedia.play.net/Category:Moon_Mage_spells">Moon Mage</a> training.']])
      end

      # A link to Category:_spells would show an empty link where the game
      # names the guild, losing the name; the line is better left as it is.
      it 'gives no sub at all for a guild not known yet, keeping the sections around it' do
        around = catalog_data(<<~YAML)['sections']
          textsubs:
            schema: 1
            sections:
              - name: 'before'
                subs: [['cat', 'dog']]
              - name: 'after'
                subs: [['bird', 'fish']]
        YAML
        data_with_neighbours = data.merge('sections' => [around.first, *data['sections'], around.last])

        expect(entries_for(nil, data)).to eq([])
        expect(entries_for(nil, data_with_neighbours).map(&:first)).to eq(%w[cat bird])
        expect(entries_for('Bard', data_with_neighbours).size).to eq(3)
      end

      it 'still checks the link fields while the guild is not known' do
        broken = data.merge('sections' => [data['sections'].first.merge('poslink' => 5)])
        expect { entries_for(nil, broken) }.to raise_error(ArgumentError, /'poslink' must be a quoted string, not 5/)
      end
    end

    # Each problem is a whole small file, so the example shows what a player
    # with a broken or stale data file would have on disk.
    [
      [
        'no textsubs mapping at all (a missing file or a parse error)',
        "other: 1\n", /no 'textsubs:' mapping/
      ],
      [
        'schema 2',
        "textsubs:\n  schema: 2\n  sections: []\n", /schema 2, but this textsubs.lic reads schema 1/
      ],
      [
        'a quoted schema',
        "textsubs:\n  schema: '1'\n  sections: []\n", /schema "1", but this textsubs.lic reads schema 1/
      ],
      [
        'no schema',
        "textsubs:\n  sections: []\n", /schema nil, but/
      ],
      [
        'an unknown top-level key',
        "textsubs:\n  schema: 1\n  spels: []\n  sections: []\n", /unknown top-level key\(s\) "spels"/
      ],
      [
        'an empty section list',
        "textsubs:\n  schema: 1\n  sections: []\n", /'sections' must be a non-empty list/
      ],
      [
        'a section that is not a mapping',
        "textsubs:\n  schema: 1\n  sections:\n    - 'loose'\n", /section 1 is not a mapping/
      ],
      [
        'a section with no name',
        "textsubs:\n  schema: 1\n  sections:\n    - subs:\n        - ['a', 'b']\n", /section 1 has no 'name'/
      ],
      [
        'two sections with one name',
        "textsubs:\n  schema: 1\n  sections:\n    - name: 'x'\n      subs: [['a', 'b']]\n    - name: 'x'\n      subs: [['c', 'd']]\n",
        /section name\(s\) used more than once: "x"/
      ],
      [
        'an unknown kind',
        "textsubs:\n  schema: 1\n  sections:\n    - name: 'x'\n      kind: 'ladder'\n      subs: [['a', 'b']]\n",
        /section 1 \(x\) has unknown kind "ladder"; kinds are pairs, guild_spells_link, wiki_links, spell_links, scroll_labels, spell_recognition\z/
      ],
      [
        'a misspelt section key',
        "textsubs:\n  schema: 1\n  sections:\n    - name: 'x'\n      sub: [['a', 'b']]\n", /section 1 \(x\) has unknown key\(s\) "sub"/
      ],
      [
        'a guild_spells_link field left out',
        "textsubs:\n  schema: 1\n  sections:\n    - name: 'x'\n      kind: 'guild_spells_link'\n      pattern: 'p'\n" \
        "      preresult: ''\n      prelink: ''\n      poslink: ''\n", /section 1 \(x\) has no posresult/
      ],
      [
        'a guild_spells_link field that is not a string',
        "textsubs:\n  schema: 1\n  sections:\n    - name: 'x'\n      kind: 'guild_spells_link'\n      pattern: 'p'\n" \
        "      preresult: ''\n      prelink: ''\n      poslink: ''\n      posresult: 7\n", /'posresult' must be a quoted string, not 7/
      ],
      [
        'an empty sub list',
        "textsubs:\n  schema: 1\n  sections:\n    - name: 'x'\n      subs: []\n", /section 1 \(x\) 'subs' must be a non-empty list/
      ],
      [
        'a sub with three strings',
        "textsubs:\n  schema: 1\n  sections:\n    - name: 'x'\n      subs: [['a', 'b', 'c']]\n", /sub 1 must be a \['pattern', 'replacement'\] pair/
      ],
      [
        'an unquoted yes, which YAML reads as true',
        "textsubs:\n  schema: 1\n  sections:\n    - name: 'x'\n      subs:\n        - ['a', 'b']\n        - ['ok', yes]\n",
        /section 1 \(x\) sub 2 must be .* not \["ok", true\]/
      ],
      [
        'an unquoted number',
        "textsubs:\n  schema: 1\n  sections:\n    - name: 'x'\n      subs: [[100, 'b']]\n", /not \[100, "b"\]/
      ],
      [
        'a pattern that does not compile',
        "textsubs:\n  schema: 1\n  sections:\n    - name: 'x'\n      subs: [['(open', 'b']]\n", /section 1 \(x\) pattern "\(open" does not compile/
      ],
      [
        'an empty requires_any',
        "textsubs:\n  schema: 1\n  sections:\n    - name: 'x'\n      requires_any: []\n      subs: [['a', 'b']]\n",
        /section 1 \(x\) requires_any must be a non-empty list of non-empty ASCII words, not \[\]/
      ],
      [
        'a requires_any that is one word, not a list',
        "textsubs:\n  schema: 1\n  sections:\n    - name: 'x'\n      requires_any: 'Kronar'\n      subs: [['a', 'b']]\n",
        /section 1 \(x\) requires_any must be .* not "Kronar"/
      ],
      [
        'a requires_any holding an empty word, which every line holds',
        "textsubs:\n  schema: 1\n  sections:\n    - name: 'x'\n      requires_any: ['Kronar', '']\n      subs: [['a', 'b']]\n",
        /section 1 \(x\) requires_any must be .* not \["Kronar", ""\]/
      ],
      [
        'a requires_any holding an unquoted number',
        "textsubs:\n  schema: 1\n  sections:\n    - name: 'x'\n      requires_any: [100]\n      subs: [['a', 'b']]\n",
        /section 1 \(x\) requires_any must be .* not \[100\]/
      ],
      [
        'a malformed gate',
        "textsubs:\n  schema: 1\n  sections:\n    - name: 'x'\n      when:\n        guilds: ['Moonmage']\n      subs: [['a', 'b']]\n",
        /section 1 \(x\) 'when' guilds names unknown guild\(s\) "Moonmage"/
      ]
    ].each do |label, yaml, message|
      it "refuses #{label}" do
        expect { entries_for('Bard', catalog_data(yaml)) }.to raise_error(ArgumentError, message)
      end
    end

    it 'refuses a nil textsubs value, which is what get_data gives for a missing file' do
      expect { entries_for('Bard', nil) }.to raise_error(ArgumentError, /no 'textsubs:' mapping/)
    end

    it 'refuses a problem in a section the guild does not get, so every guild sees it' do
      data = catalog_data(<<~YAML)
        textsubs:
          schema: 1
          sections:
            - name: 'everyone'
              subs: [['a', 'A']]
            - name: 'Clerics only'
              when:
                guilds: ['Cleric']
              subs: [['(broken', 'B']]
      YAML
      expect { entries_for('Bard', data) }.to raise_error(ArgumentError, /section 2 \(Clerics only\) pattern "\(broken"/)
    end

    # The spell kinds read one spells table, so a spell's name and labels are
    # written once. The table here is small and made up for the examples,
    # with each way a row can give its labels: a book alone, a guild and
    # book, a signature spell, a label of its own, and a guild with no
    # recognition data.
    describe 'the spell kinds' do
      let(:spell_rows) do
        [{ 'name' => 'Strange Arrow', 'book' => 'Analogous Patterns', 'tier' => 'introductory', 'type' => 'targeted' },
         { 'name' => 'Lay Ward', 'book' => 'Analogous Patterns', 'tier' => 'basic', 'type' => 'warding' },
         { 'name' => 'Manifest Force', 'book' => 'Analogous Patterns', 'tier' => 'basic', 'type' => 'warding' },
         { 'name' => 'Halo', 'guild' => 'Cleric', 'book' => 'Holy Defense', 'signature' => true, 'tier' => 'advanced',
           'type' => 'debilitation/warding' },
         { 'name' => "Sidhlot's Flaying", 'label' => 'Lay Necromancy' },
         { 'name' => 'Bless', 'guild' => 'Cleric' }]
      end
      let(:scrolls) do
        { 'name' => 'scrolls', 'kind' => 'scroll_labels', 'pattern' => '^(It is labeled) "{name}."',
          'replacement' => '\1 "{name}." ({label})', 'names' => ['Halo', 'Strange Arrow', "Sidhlot's Flaying", 'Bless'] }
      end
      let(:recognition) do
        { 'name' => 'recognition', 'kind' => 'spell_recognition',
          'pattern' => '^(You recognize|You decipher) the ({names}) spell.', 'replacement' => '\1 the \2 spell. [{label}]',
          'groups' => [['Halo'], ['Strange Arrow'], ['Lay Ward', 'Manifest Force']] }
      end

      # @param sections [Array<Hash>] the sections, in order
      # @param spells [Array<Hash>, nil] the spells table; nil leaves the key out
      # @return [Hash] the frozen `textsubs:` value, read back from YAML
      def spell_catalog(*sections, spells: spell_rows)
        catalog_data({ 'textsubs' => { 'schema' => 1, 'sections' => sections, 'spells' => spells }.compact }.to_yaml)
      end

      # @return [Array<Array(String, String)>] [source, replacement] of each sub
      def pairs_for(data)
        entries_for('Bard', data).map { |source, replacement, _meta| [source, replacement] }
      end

      # What TextSubs.elanthipedia adds for each call, as [source, replacement].
      #
      # @param calls [Array<Array<String>>] the arguments of each call
      # @return [Array<Array(String, String)>]
      def elanthipedia_pairs(calls)
        TextSubs.clear
        calls.each { |arguments| TextSubs.elanthipedia(*arguments) }
        TextSubs.subs.map { |key, value| [key.source, value] }
      ensure
        TextSubs.clear
      end

      it 'links every spell of the table once, in table order, just as elanthipedia would' do
        links = { 'name' => 'spell links', 'kind' => 'spell_links', 'pretext' => '\S|^', 'postext' => '..\(.*\)|\s*Slot' }
        expected = elanthipedia_pairs(spell_rows.map { |row| [row['name'], '\S|^', '..\(.*\)|\s*Slot'] })

        expect(pairs_for(spell_catalog(links))).to eq(expected)
        expect(expected.map(&:first).first(2)).to eq(['(\S|^)(Strange Arrow)(..\(.*\)|\s*Slot)', '(\S|^)(Lay Ward)(..\(.*\)|\s*Slot)'])
        expect(expected.last.last).to eq('\1<a href="https://elanthipedia.play.net/Bless">Bless</a>\3')
      end

      it 'links each text of a wiki_links section, in list order, with every link field elanthipedia takes' do
        books = { 'name' => 'books', 'kind' => 'wiki_links', 'texts' => ['Holy Defense', "Fae's Arts"],
                  'pretext' => '^', 'postext' => ':', 'prelink' => 'Category:', 'poslink' => '_spellbook',
                  'preresult' => '[', 'posresult' => ']' }
        expected = elanthipedia_pairs(books['texts'].map { |text| [text, '^', ':', 'Category:', '_spellbook', '[', ']'] })

        expect(pairs_for(spell_catalog(books))).to eq(expected)
        expect(expected.last).to eq(['(^)(Fae\'s Arts)(:)', '[<a href="https://elanthipedia.play.net/Category:Fae\'s_Arts_spellbook">Fae\'s Arts</a>]'])
      end

      it "takes elanthipedia's defaults for each link field a wiki_links section leaves out" do
        bare = { 'name' => 'bare', 'kind' => 'wiki_links', 'texts' => ['Holy Defense'] }
        expect(pairs_for(spell_catalog(bare))).to eq(elanthipedia_pairs([['Holy Defense']]))
        expect(pairs_for(spell_catalog(bare))).to eq([['()(Holy Defense)()', '\1<a href="https://elanthipedia.play.net/Holy_Defense">Holy Defense</a>\3']])
      end

      it "labels each scroll name, in list order, with the spell's label, else its guild, else its book" do
        expect(pairs_for(spell_catalog(scrolls))).to eq(
          [['^(It is labeled) "Halo."', '\1 "Halo." (Cleric)'],
           ['^(It is labeled) "Strange Arrow."', '\1 "Strange Arrow." (Analogous Patterns)'],
           ['^(It is labeled) "Sidhlot\'s Flaying."', '\1 "Sidhlot\'s Flaying." (Lay Necromancy)'],
           ['^(It is labeled) "Bless."', '\1 "Bless." (Cleric)']]
        )
      end

      it 'uses an override as it is written, for a name the table does not list and for one it does' do
        overridden = scrolls.merge('names' => [{ 'name' => "Damaris's Lullaby", 'label' => 'Bard' }, { 'label' => 'Paladin', 'name' => 'Halo' }])
        expect(pairs_for(spell_catalog(overridden))).to eq(
          [['^(It is labeled) "Damaris\'s Lullaby."', '\1 "Damaris\'s Lullaby." (Bard)'],
           ['^(It is labeled) "Halo."', '\1 "Halo." (Paladin)']]
        )
      end

      it 'puts names and labels in as they are written: a backslash stays, and a brace that names no placeholder stays' do
        literal = scrolls.merge('pattern' => '^\d{3} "{name}."', 'names' => [{ 'name' => 'Halo', 'label' => 'it\'s \0' }])
        expect(pairs_for(spell_catalog(literal))).to eq([['^\d{3} "Halo."', '\1 "Halo." (it\'s \0)']])
      end

      it 'gives one recognition sub per group, in list order, with the names joined and the label the table computes' do
        expect(pairs_for(spell_catalog(recognition))).to eq(
          [['^(You recognize|You decipher) the (Halo) spell.', '\1 the \2 spell. [signature Cleric (Holy Defense): advanced debilitation/warding]'],
           ['^(You recognize|You decipher) the (Strange Arrow) spell.', '\1 the \2 spell. [Analogous Patterns: introductory targeted]'],
           ['^(You recognize|You decipher) the (Lay Ward|Manifest Force) spell.', '\1 the \2 spell. [Analogous Patterns: basic warding]']]
        )
      end

      it 'rewrites a game line with a group sub, whichever name of the group the line holds' do
        TextSubs.clear
        expect(TextSubs.add_catalog(spell_catalog(recognition), TextSubs::Context.new(guild: 'Bard', settings: settings), file: 'f')).to be_nil
        expect(TextSubs.apply(+'You decipher the Manifest Force spell.'))
          .to eq('You decipher the Manifest Force spell. [Analogous Patterns: basic warding]')
        expect(TextSubs.apply(+'You recognize the Lay Ward spell.')).to eq('You recognize the Lay Ward spell. [Analogous Patterns: basic warding]')
      ensure
        TextSubs.clear
      end

      it 'refuses a group whose names the table labels differently, naming both labels' do
        mixed = recognition.merge('groups' => [['Lay Ward'], ['Strange Arrow', 'Manifest Force']])
        expect { pairs_for(spell_catalog(mixed)) }.to raise_error(
          ArgumentError,
          'section 1 (recognition) groups 2 mixes labels: "Strange Arrow" is "Analogous Patterns: introductory targeted" ' \
          'but "Manifest Force" is "Analogous Patterns: basic warding"'
        )
      end

      it 'refuses a group of two spells that differ only in being a signature spell' do
        twin = spell_rows + [spell_rows[3].merge('name' => 'Halo Twin').except('signature')]
        mixed = recognition.merge('groups' => [['Halo', 'Halo Twin']])
        expect { pairs_for(spell_catalog(mixed, spells: twin)) }.to raise_error(ArgumentError, /groups 1 mixes labels: "Halo" is "signature Cleric/)
      end

      it 'refuses a section that names a spell the table does not list, as a typo would' do
        expect { pairs_for(spell_catalog(scrolls.merge('names' => ['Strange Arow']))) }
          .to raise_error(ArgumentError, 'section 1 (scrolls) names "Strange Arow", which is not in spells')
        expect { pairs_for(spell_catalog(recognition.merge('groups' => [['Halo', 'Hallo']]))) }
          .to raise_error(ArgumentError, 'section 1 (recognition) names "Hallo", which is not in spells')
      end

      it 'refuses a spell section in a file with no spells table at all' do
        expect { pairs_for(spell_catalog(scrolls, spells: nil)) }.to raise_error(ArgumentError, /names "Halo", which is not in spells/)
        expect { pairs_for(spell_catalog({ 'name' => 'links', 'kind' => 'spell_links' }, spells: nil)) }
          .to raise_error(ArgumentError, 'section 1 (links) has no spells to link; list them under spells')
      end

      it 'loads a file of pairs alone with no spells table, as one from before the table would be' do
        expect(pairs_for(spell_catalog({ 'name' => 'plain', 'subs' => [%w[cat dog]] }, spells: nil))).to eq([%w[cat dog]])
      end

      it 'refuses a bad spells row even when no section reads the table' do
        bad = spell_rows + [{ 'name' => 'Halo' }]
        expect { pairs_for(spell_catalog({ 'name' => 'plain', 'subs' => [%w[cat dog]] }, spells: bad)) }
          .to raise_error(ArgumentError, 'spell 7 (Halo) is listed more than once')
      end

      {
        'a scroll name that is a number'                   => [:scrolls, { 'names' => [5] }, /names entry 1 must be a quoted spell name or an override \{name: '\.\.\.', label: '\.\.\.'\}, not 5/],
        'an override with no label'                        => [:scrolls, { 'names' => [{ 'name' => 'Halo' }] }, /names entry 1 must be/],
        'an override with a key besides name and label'    => [:scrolls, { 'names' => ['Bless', { 'name' => 'Halo', 'label' => 'X', 'note' => 'y' }] }, /names entry 2 must be/],
        'an override with an empty name'                   => [:scrolls, { 'names' => [{ 'name' => '', 'label' => 'X' }] }, /names entry 1 must be/],
        'a scroll name listed twice, once as an override'  => [:scrolls, { 'names' => ['Halo', { 'name' => 'Halo', 'label' => 'X' }] }, /section 1 \(scrolls\) lists "Halo" more than once/],
        'no scroll names'                                  => [:scrolls, { 'names' => [] }, /'names' must be a non-empty list/],
        'a scroll pattern without {name}'                  => [:scrolls, { 'pattern' => '^(It is labeled) "Halo."' }, /'pattern' must hold \{name\}, not/],
        'a scroll replacement that is not a string'        => [:scrolls, { 'replacement' => 5 }, /'replacement' must be a quoted string, not 5/],
        'a scroll pattern that does not compile'           => [:scrolls, { 'pattern' => '^(It is labeled "{name}."' }, /pattern "\^\(It is labeled \\"Halo\.\\"" does not compile/],
        'a recognition group that is one name, not a list' => [:recognition, { 'groups' => ['Halo'] }, /'groups 1' must be a non-empty list of quoted names, not "Halo"/],
        'an empty recognition group'                       => [:recognition, { 'groups' => [['Halo'], []] }, /'groups 2' must be a non-empty list/],
        'no recognition groups'                            => [:recognition, { 'groups' => [] }, /'groups' must be a non-empty list/],
        'a spell in two recognition groups'                => [:recognition, { 'groups' => [['Halo'], ['Lay Ward'], ['Halo']] }, /lists "Halo" more than once/],
        'a recognition pattern without {names}'            => [:recognition, { 'pattern' => '^the ({name}) spell.' }, /'pattern' must hold \{names\}/],
        'a recognition name with no recognition data'      => [:recognition, { 'groups' => [['Bless']] }, /needs the book, tier, type of spell "Bless"/]
      }.each do |label, (section, change, message)|
        it "refuses #{label}" do
          expect { pairs_for(spell_catalog(send(section).merge(change))) }.to raise_error(ArgumentError, message)
        end
      end

      it 'refuses a scroll name whose row has no label, guild or book' do
        bare = spell_rows + [{ 'name' => 'Bare' }]
        expect { pairs_for(spell_catalog(scrolls.merge('names' => ['Bare']), spells: bare)) }
          .to raise_error(ArgumentError, 'section 1 (scrolls) needs a label, guild or book for spell "Bare"')
      end

      it 'refuses a spell name that is not valid regex source wherever it would be linked' do
        broken = spell_rows + [{ 'name' => 'Open (Spell', 'guild' => 'Cleric' }]
        expect { pairs_for(spell_catalog({ 'name' => 'links', 'kind' => 'spell_links' }, spells: broken)) }
          .to raise_error(ArgumentError, /section 1 \(links\) pattern "\(\)\(Open \(Spell\)\(\)" does not compile/)
      end

      {
        'an empty texts list'         => [{ 'texts' => [] }, /'texts' must be a non-empty list of quoted names, not \[\]/],
        'a text listed twice'         => [{ 'texts' => %w[Healing Healing] }, /lists "Healing" more than once/],
        'a link field that is a list' => [{ 'prelink' => ['Category:'] }, /'prelink' must be a quoted string, not \["Category:"\]/],
        'an unknown link field'       => [{ 'postlink' => '_spellbook' }, /has unknown key\(s\) "postlink"/]
      }.each do |label, (change, message)|
        it "refuses a wiki_links section with #{label}" do
          section = { 'name' => 'books', 'kind' => 'wiki_links', 'texts' => ['Healing'] }.merge(change)
          expect { pairs_for(spell_catalog(section)) }.to raise_error(ArgumentError, message)
        end
      end
    end
  end

  describe 'TextSubs::SpellTable' do
    let(:rows) do
      [{ 'name' => 'Halo', 'guild' => 'Cleric', 'book' => 'Holy Defense', 'signature' => true, 'tier' => 'advanced',
         'type' => 'debilitation/warding' },
       { 'name' => 'Burden', 'book' => 'Analogous Patterns', 'tier' => 'introductory', 'type' => 'debilitation' },
       { 'name' => 'Bless', 'guild' => 'Cleric', 'book' => 'Holy Evocations', 'tier' => 'introductory', 'type' => 'utility',
         'label' => 'Clerical' },
       { 'name' => 'Abandoned Heart' }]
    end
    let(:table) { TextSubs::SpellTable.new(rows) }

    it 'lists the names in table order, frozen' do
      expect(table.names).to eq(['Halo', 'Burden', 'Bless', 'Abandoned Heart'])
      expect(table.names).to be_frozen
    end

    it 'labels a scroll with the label, else the guild, else the book' do
      expect(%w[Bless Halo Burden].map { |name| table.scroll_label(name) }).to eq(['Clerical', 'Cleric', 'Analogous Patterns'])
    end

    it "builds a recognition label from the signature flag, the guild and book (or the book alone), the tier and the type" do
      expect(table.recognition_label('Halo')).to eq('signature Cleric (Holy Defense): advanced debilitation/warding')
      expect(table.recognition_label('Burden')).to eq('Analogous Patterns: introductory debilitation')
      expect(table.recognition_label('Bless')).to eq('Cleric (Holy Evocations): introductory utility')
    end

    it 'refuses a name it does not list, and a label its row has no data for' do
      expect { table.scroll_label('Hallo') }.to raise_error(ArgumentError, 'names "Hallo", which is not in spells')
      expect { table.scroll_label('Abandoned Heart') }.to raise_error(ArgumentError, 'needs a label, guild or book for spell "Abandoned Heart"')
      expect { table.recognition_label('Abandoned Heart') }.to raise_error(ArgumentError, 'needs the book, tier, type of spell "Abandoned Heart"')
    end

    it 'changes no row it is given' do
      frozen = YAML.safe_load(rows.to_yaml, freeze: true)
      expect(TextSubs::SpellTable.new(frozen).recognition_label('Halo')).to start_with('signature')
    end

    {
      'spells: with nothing after it' => [nil, /'spells' must be a list, not nil/],
      'a mapping, not a list'         => [{ 'Halo' => {} }, /'spells' must be a list, not \{"Halo" => \{\}\}/],
      'a row that is a bare name'     => [['Halo'], /\Aspell 1 is not a mapping\z/],
      'a row with no name'            => [[{ 'guild' => 'Cleric' }], /\Aspell 1 has no 'name'\z/],
      'a row with an empty name'      => [[{ 'name' => '' }], /spell 1 has no 'name'/],
      'a misspelt key'                => [[{ 'name' => 'Halo', 'tierr' => 'basic' }], /\Aspell 1 \(Halo\) has unknown key\(s\) "tierr"\z/],
      'a name listed twice'           => [[{ 'name' => 'Halo' }, { 'name' => 'Burden' }, { 'name' => 'Halo' }], /\Aspell 3 \(Halo\) is listed more than once\z/],
      'a misspelt guild'              => [[{ 'name' => 'Halo', 'guild' => 'Moonmage' }], /spell 1 \(Halo\) names unknown guild "Moonmage"/],
      'signature: false'              => [[{ 'name' => 'Halo', 'signature' => false }], /signature must be true, or left out, not false/],
      "signature: 'true', a string"   => [[{ 'name' => 'Halo', 'signature' => 'true' }], /signature must be true, or left out, not "true"/],
      'an unquoted number for a tier' => [[{ 'name' => 'Halo', 'tier' => 5 }], /spell 1 \(Halo\) tier must be a non-empty quoted string, not 5/],
      'an empty label'                => [[{ 'name' => 'Halo', 'label' => '' }], /label must be a non-empty quoted string, not ""/]
    }.each do |label, (value, message)|
      it "refuses #{label}" do
        expect { TextSubs::SpellTable.new(value) }.to raise_error(ArgumentError, message)
      end
    end
  end

  describe 'TextSubs::LinkBuilder.pair' do
    it 'gives the key and replacement TextSubs.elanthipedia adds for the same arguments' do
      TextSubs.clear
      TextSubs.elanthipedia("Damaris' Lullaby", '\S|^', '\s*Slot', 'Spell:', '_page', '<', '>')
      expect([TextSubs::LinkBuilder.pair("Damaris' Lullaby", pretext: '\S|^', postext: '\s*Slot', prelink: 'Spell:', poslink: '_page',
                                                             preresult: '<', posresult: '>')])
        .to eq(TextSubs.subs.map { |key, value| [key.source, value] })
    ensure
      TextSubs.clear
    end

    it 'puts underscores only in the page, keeping the spaces of the text and the regex' do
      expect(TextSubs::LinkBuilder.pair('Aura of Tongues'))
        .to eq(['()(Aura of Tongues)()', '\1<a href="https://elanthipedia.play.net/Aura_of_Tongues">Aura of Tongues</a>\3'])
    end
  end

  describe 'TextSubs.add_catalog' do
    before { TextSubs.clear }

    let(:context) { TextSubs::Context.new(guild: 'Bard', settings: OpenStruct.new) }
    let(:good) do
      { 'schema' => 1, 'sections' => [{ 'name' => 'one', 'subs' => [%w[fine FINE], %w[cat dog]] }] }
    end

    it 'adds every sub after what is there, in order, under the key add would store, one generation each, and returns nil' do
      TextSubs.add('mine', 'MINE')
      generation = TextSubs.generation

      expect(TextSubs.add_catalog(good, context, file: 'data/base-textsubs.yaml')).to be_nil
      expect(TextSubs.subs.to_a).to eq([[/mine/, 'MINE'], [/fine/, 'FINE'], [/cat/, 'dog']])
      expect(TextSubs.generation).to eq(generation + 2)
    end

    # Checking the data compiles every pattern, a section the guild does not
    # get included; the selected subs are stored under those same Regexps
    # rather than compiled again (a start compiles ~1,600 patterns).
    #
    # This counts compiles through Regexp.new, the compiler check_pattern
    # uses, so it pins that choice too: a check that compiled with
    # Regexp.compile or /#{pattern}/ would count none here, and the failure
    # says so. The object_id comparison is what proves the stored keys are
    # the check's own Regexps, whatever compiled them.
    it 'compiles each pattern once, and stores the Regexp the check compiled' do
      data = good.merge('sections' => good['sections'] + [{ 'name' => 'Clerics', 'when' => { 'guilds' => ['Cleric'] },
                                                             'subs' => [%w[pray PRAY]] }])
      compiled = []
      allow(Regexp).to(receive(:new).and_wrap_original do |original, *args, **kwargs, &block|
        original.call(*args, **kwargs, &block).tap { |key| compiled << key }
      end)

      TextSubs.add_catalog(data, context, file: 'data/base-textsubs.yaml')

      expect(compiled.map(&:source)).to eq(%w[fine cat pray]), lambda {
        "Regexp.new compiled #{compiled.map(&:source).inspect}; this example counts only Regexp.new, so if the " \
          'catalog check now compiles some other way, count that instead'
      }
      expect(TextSubs.subs.keys.map(&:object_id)).to eq(compiled.first(2).map(&:object_id))
      expect(TextSubs.subs.keys).to all(be_frozen)
    end

    it 'adds nothing, not even the good sections before the bad one, and says why, naming the file and the schema' do
      bad = good.merge('sections' => good['sections'] + [{ 'name' => 'two', 'kind' => 'ladder' }])
      TextSubs.add('mine', 'MINE')
      generation = TextSubs.generation

      message = TextSubs.add_catalog(bad, context, file: '/lich/scripts/data/custom/base-textsubs.yaml')
      expect(message).to eq(
        'No built-in subs: /lich/scripts/data/custom/base-textsubs.yaml cannot be used (section 2 (two) has unknown kind ' \
        "\"ladder\"; kinds are pairs, guild_spells_link, wiki_links, spell_links, scroll_labels, spell_recognition). " \
        "This textsubs.lic needs a 'textsubs:' mapping with schema: 1; " \
        'update dr-scripts, or fix or remove a copy in data/custom. Only private_textsubs and shit-list subs are active.'
      )
      expect(TextSubs.subs).to eq(/mine/ => 'MINE')
      expect(TextSubs.generation).to eq(generation)
    end

    # 'fine' does not need 'Kronar', so the gate shows itself: the sub stays
    # silent on a line that holds the pattern but not the word.
    it "gives each sub its section's requires_any gate, which TextSubs.apply honours" do
      gated = { 'schema' => 1, 'sections' => [{ 'name' => 'gated', 'requires_any' => ['Kronar'], 'subs' => [%w[fine FINE]] },
                                              { 'name' => 'open', 'subs' => [%w[cat dog]] }] }
      expect(TextSubs.add_catalog(gated, context, file: 'f')).to be_nil

      expect(TextSubs.subs).to eq(/fine/ => 'FINE', /cat/ => 'dog')
      expect(TextSubs.apply(+'fine cat')).to eq('fine dog')
      expect(TextSubs.apply(+'fine cat, 3 Kronars')).to eq('FINE dog, 3 Kronars')
    end

    it 'lets a key added later with TextSubs.add drop the gate the catalog gave it' do
      gated = { 'schema' => 1, 'sections' => [{ 'name' => 'gated', 'requires_any' => ['Kronar'], 'subs' => [%w[fine FINE]] }] }
      TextSubs.add_catalog(gated, context, file: 'f')
      TextSubs.add('fine', 'MINE')
      expect(TextSubs.apply(+'fine')).to eq('MINE')
    end

    it 'lets an error that is not about the data through' do
      allow(TextSubs::Catalog).to receive(:keyed_entries).and_raise(NoMethodError, 'a bug, not bad data')
      expect { TextSubs.add_catalog(good, context, file: 'f') }.to raise_error(NoMethodError, 'a bug, not bad data')
    end
  end

  describe 'TextSubs::Sources::ShitList' do
    # @param content [String] a shit-list file body
    # @return [Array<String>] the names read from it
    def shit_list_names(content)
      TextSubs::Sources::ShitList.names(StringIO.new(content))
    end

    it 'gives each name stripped and capitalized, cut at the first comma only' do
      expect(shit_list_names("  zorvex  , stole my kill, twice\r\nqUIMBLE,\nbob")).to eq(%w[Zorvex Quimble Bob])
    end

    it 'gives no name for an empty file, a blank line, a line of spaces, or a lone comma' do
      expect(shit_list_names('')).to eq([])
      expect(shit_list_names("\n\r\n \t \n,\n , note\n,bob\n")).to eq([])
    end

    it 'freezes the list and every name in it' do
      names = shit_list_names("zorvex\n")
      expect(names).to be_frozen
      expect(names).to all(be_frozen)
    end

    it 'makes a sub that matches the name literally, as a whole word, and tags it' do
      sub = TextSubs::Sources::ShitList.sub('O.k')
      expect(sub).to eq(['\\bO\\.k\\b', 'O.k (SL)'])
      expect(sub).to be_frozen
    end
  end

  describe 'TextSubs::Sources::PrivateSubs.entries' do
    # @param value [Object] a private_textsubs value
    # @return [Array(Array, Array)] [entries, warnings]
    def private_entries(value)
      TextSubs::Sources::PrivateSubs.entries(value)
    end

    it 'compiles each usable key with the timeout, in order, around the skipped ones' do
      entries, warnings = private_entries('a(\d)' => 'A\1', 'Bob' => nil, '[' => 'x', 'c' => '')
      expect(entries).to eq([[/a(\d)/, 'A\1', '"a(\d)"'], [/c/, '', '"c"']])
      expect(entries.map { |key, _| key.timeout }).to eq([1.0, 1.0])
      expect(warnings.size).to eq(2)
      expect(warnings.first).to start_with('private_textsubs "Bob" is skipped:')
      expect(warnings.last).to start_with('private_textsubs "[" is skipped: it is not a valid regex (')
    end

    # The name is the key as the player wrote it in their YAML, not Ruby's
    # String#inspect, which would double each backslash and escape each quote.
    it 'names a String key as written, backslashes and quotes unescaped, in its entry and in its warning' do
      entries, warnings = private_entries('say "(\w+)"' => 'A', '[\d' => 'x', 'say "(\w+)" again' => nil)
      expect(entries.map(&:last)).to eq(['"say "(\w+)""'])
      expect(warnings.size).to eq(2)
      expect(warnings.first).to start_with('private_textsubs "[\d" is skipped: it is not a valid regex (')
      expect(warnings.last).to start_with('private_textsubs "say "(\w+)" again" is skipped: its replacement is empty (nil)')
    end

    it 'names a !ruby/regexp key as /text/flags, its source unescaped' do
      entries, warnings = private_entries(/say "(\w+)"/i => 'A', /say "(\w+)" again/ => nil)
      expect(entries.map(&:last)).to eq(['/say "(\w+)"/i'])
      expect(warnings).to eq(['private_textsubs /say "(\w+)" again/ is skipped: its replacement is empty (nil); ' \
                              "write '' to delete the text it matches."])
    end

    it 'answers nil with nothing to add and nothing to say' do
      expect(private_entries(nil)).to eq([[], []])
    end

    it 'answers an empty mapping with nothing to add and nothing to say' do
      expect(private_entries({})).to eq([[], []])
    end

    it 'names the class of a value that is not a String, with the right article' do
      _, warnings = private_entries('one' => 1.5, 'two' => :sym, 'three' => ['x'], 'four' => { 'x' => 'y' })
      expect(warnings).to eq([
                               'private_textsubs "one" is skipped: its replacement 1.5 is a Float, not a quoted string; quote the replacement in your YAML.',
                               'private_textsubs "two" is skipped: its replacement :sym is a Symbol, not a quoted string; quote the replacement in your YAML.',
                               'private_textsubs "three" is skipped: its replacement ["x"] is an Array, not a quoted string; quote the replacement in your YAML.',
                               "private_textsubs \"four\" is skipped: its replacement #{{ 'x' => 'y' }.inspect} is a Hash, not a quoted string; " \
                               'quote the replacement in your YAML.'
                             ])
    end

    it 'compiles a Regexp key (!ruby/regexp) from its source and flags, with the timeout' do
      entries, warnings = private_entries(/a(\d)/i => 'A\1', /x y/mx => 'z', /plain/ => 'p')
      expect(warnings).to eq([])
      expect(entries).to eq([[/a(\d)/i, 'A\1', '/a(\d)/i'], [/x y/mx, 'z', '/x y/mx'], [/plain/, 'p', '/plain/']])
      expect(entries.map { |key, _| key.options }).to eq([Regexp::IGNORECASE, Regexp::MULTILINE | Regexp::EXTENDED, 0])
      expect(entries.map { |key, _| key.timeout }).to eq([1.0, 1.0, 1.0])
    end

    it 'skips an empty Regexp key or one with a bad value, saying why and never to quote the key' do
      _, warnings = private_entries(//i => 'x', /Bob/ => nil, /Ann/i => 7)
      expect(warnings).to eq([
                               'private_textsubs //i is skipped: an empty pattern matches between every two characters of every line.',
                               "private_textsubs /Bob/ is skipped: its replacement is empty (nil); write '' to delete the text it matches.",
                               'private_textsubs /Ann/i is skipped: its replacement 7 is an Integer, not a quoted string; quote the replacement in your YAML.'
                             ])
    end

    it 'skips a later key that is the same pattern as an earlier one, but not one that differs only by a flag' do
      entries, warnings = private_entries('fine' => 'A', /fine/i => 'B', /fine/ => 'C')
      expect(entries).to eq([[/fine/, 'A', '"fine"'], [/fine/i, 'B', '/fine/i']])
      expect(warnings).to eq(['private_textsubs /fine/ is skipped: it is the same pattern as "fine", which is used instead.'])
    end

    it 'reports a key that is not a String before looking at its value' do
      expect(private_entries(nil => nil).last).to eq(['private_textsubs nil is skipped: it is a NilClass, not a quoted string; quote it in your YAML.'])
    end

    it 'returns frozen lists of frozen entries and reads a frozen mapping without changing it' do
      value = { 'fine' => 'FINE' }.freeze
      result = private_entries(value)
      expect(result).to be_frozen
      expect(result).to all(be_frozen)
      expect(result.first).to all(be_frozen)
      expect(value).to eq('fine' => 'FINE')
    end
  end

  describe 'TextSubs.prefer_private' do
    before { TextSubs.clear }

    let(:context) { TextSubs::Context.new(guild: 'Bard', settings: OpenStruct.new) }

    it 'gives a replaced private key its value back in its own place, once, counting one generation' do
      entries, = TextSubs::Sources::PrivateSubs.entries('fine' => 'MINE', 'cat' => 'kitten')
      TextSubs.add_private(entries)
      TextSubs.add('dog', 'hound')
      TextSubs.add('fine', 'FINE')
      generation = TextSubs.generation

      expect(TextSubs.prefer_private(entries)).to eq(['private_textsubs "fine" is also a built-in sub; your replacement is used instead of the built-in one.'])
      expect(TextSubs.subs.to_a).to eq([[/fine/, 'MINE'], [/cat/, 'kitten'], [/dog/, 'hound']])
      expect(TextSubs.subs.keys.first.timeout).to eq(1.0)
      expect(TextSubs.generation).to eq(generation + 1)

      expect(TextSubs.prefer_private(entries)).to eq([])
      expect(TextSubs.generation).to eq(generation + 1)
    end

    it 'keeps the gate the built-in section gave the key, so the private value still skips lines without a coin' do
      coin_commas = '(?!.*>)\\d{1,3}(?=(\\d{3})+(?!\\d).*(Kronar|Dokora|Lirum))'
      entries, = TextSubs::Sources::PrivateSubs.entries(coin_commas => '\\&.')
      key = entries.first.first
      TextSubs.add_private(entries)
      gated = { 'schema' => 1, 'sections' => [{ 'name' => 'coin commas', 'requires_any' => %w[Kronar Dokora Lirum], 'subs' => [[coin_commas, '\\&,']] }] }
      TextSubs.add_catalog(gated, context, file: 'f')
      allow(key).to receive(:match?).and_call_original

      TextSubs.prefer_private(entries)
      expect(TextSubs.apply(+'You count 1234567 coins.')).to eq('You count 1234567 coins.')
      expect(key).not_to have_received(:match?)
      expect(TextSubs.apply(+'You have 1234567 Kronars.')).to eq('You have 1.234.567 Kronars.')
      expect(key).to have_received(:match?).once
    end

    it 'reads and writes the staged Registry while one is staged, gate included, as on a start' do
      coin_commas = '(?!.*>)\\d{1,3}(?=(\\d{3})+(?!\\d).*(Kronar|Dokora|Lirum))'
      entries, = TextSubs::Sources::PrivateSubs.entries(coin_commas => '\\&.')
      key = entries.first.first
      staged = TextSubs.stage(TextSubs::Registry.new)
      TextSubs.add_private(entries)
      gated = { 'schema' => 1, 'sections' => [{ 'name' => 'coin commas', 'requires_any' => %w[Kronar Dokora Lirum], 'subs' => [[coin_commas, '\\&,']] }] }
      TextSubs.add_catalog(gated, context, file: 'f')

      expect(TextSubs.prefer_private(entries).size).to eq(1)
      expect(staged.snapshot).to eq(key => '\\&.')
      expect(staged.gates[key]).to eq(%w[Kronar Dokora Lirum])
      expect(TextSubs.subs).to eq({})
    ensure
      TextSubs.install(staged)
    end

    it 'leaves a key alone that is no longer in the catalog' do
      entries, = TextSubs::Sources::PrivateSubs.entries('fine' => 'MINE')
      TextSubs.add('cat', 'dog')
      expect(TextSubs.prefer_private(entries)).to eq([])
      expect(TextSubs.subs).to eq(/cat/ => 'dog')
    end
  end

  describe 'TextSubs.catalog_override' do
    it 'names data/custom/base-textsubs.yaml only when that file exists' do
      Dir.mktmpdir('textsubs-override') do |dir|
        expect(TextSubs.catalog_override(dir)).to be_nil
        FileUtils.mkdir_p(File.join(dir, 'data', 'custom'))
        File.write(File.join(dir, 'data', 'base-textsubs.yaml'), "textsubs: {}\n")
        expect(TextSubs.catalog_override(dir)).to be_nil

        File.write(File.join(dir, 'data', 'custom', 'base-textsubs.yaml'), "textsubs: {}\n")
        expect(TextSubs.catalog_override(dir)).to eq(File.join(dir, 'data', 'custom', 'base-textsubs.yaml'))
      end
    end

    it 'ignores a directory of that name' do
      Dir.mktmpdir('textsubs-override') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'data', 'custom', 'base-textsubs.yaml'))
        expect(TextSubs.catalog_override(dir)).to be_nil
      end
    end
  end

  describe 'front end guard' do
    let(:line) { "You feel fine.\r\n".b }
    let(:no_clients) { double('DetachableClientRegistry', empty?: true) }
    let(:some_clients) { double('DetachableClientRegistry', empty?: false) }
    let(:front_end) { double('front end client') }

    # Where each kind of front end shows up for TextSubs.client_attached?,
    # with the other two sources empty.
    attached_sources = {
      'the detachable client registry' => -> { { registry: some_clients, detachable: nil, client: nil } },
      'the legacy detachable client'   => -> { { registry: no_clients, detachable: front_end, client: nil } },
      'the primary client ($_CLIENT_)' => -> { { registry: no_clients, detachable: nil, client: front_end } }
    }

    # Runs the real entry point with one private key the probe line matches,
    # so a hook that skipped the catalog shows in its output.
    #
    # @return [void]
    def install_probe_catalog
      build_catalog('Commoner', 'private_textsubs' => { 'fine' => 'FINE' })
    end

    # Makes the hook's TextSubs.client_attached? call run the real predicate
    # with `sources` in place of the Lich globals, which a spec must not set.
    #
    # @param sources [Hash{Symbol=>Object}] registry:, detachable:, client:
    # @return [void]
    def front_ends(**sources)
      allow(TextSubs).to(receive(:client_attached?).and_wrap_original { |original| original.call(**sources) })
    end

    describe 'TextSubs.client_attached?' do
      it 'is false with an empty registry, no detachable client and no primary client' do
        expect(TextSubs.client_attached?(registry: no_clients, detachable: nil, client: nil)).to be(false)
      end

      it 'is false, and does not touch the registry, when there is no registry at all' do
        # Under Lich's nilclass patch nil.empty? is nil, so an unguarded
        # !registry.empty? would call a headless character attached.
        expect(TextSubs.client_attached?(registry: nil, detachable: nil, client: nil)).to be(false)
      end

      attached_sources.each do |source, sources|
        it "is true with a front end in #{source} alone" do
          expect(TextSubs.client_attached?(**instance_exec(&sources))).to be(true)
        end
      end

      # The hook calls the predicate bare, so these defaults are its only wiring
      # to Lich. A spec must not set the globals, and with all three nil a
      # misspelt, swapped or nil default would still answer false, so the
      # defaults are read from the parsed source instead.
      it 'defaults each source to the Lich global that holds it' do
        tree = Prism.parse_file(lic_path('textsubs.lic')).value
        definition = tree.breadth_first_search do |node|
          node.is_a?(Prism::DefNode) && node.receiver.is_a?(Prism::SelfNode) && node.name == :client_attached?
        end
        defaults = definition.parameters.keywords.to_h { |keyword| [keyword.name, keyword.value.slice] }

        expect(defaults).to eq(registry: '$_DETACHABLE_CLIENT_REGISTRY_', detachable: '$_DETACHABLE_CLIENT_',
                               client: '$_CLIENT_')
        expect(definition.parameters.keywords.map(&:value)).to all(be_a(Prism::GlobalVariableReadNode))
      end

      it 'is false through those defaults in the harness, which sets none of the globals' do
        expect([$_DETACHABLE_CLIENT_REGISTRY_, $_DETACHABLE_CLIENT_, $_CLIENT_]).to all(be_nil)
        expect(TextSubs.client_attached?).to be(false)
      end
    end

    it 'passes the line on untouched, without reading the catalog, when no front end is attached' do
      install_probe_catalog
      front_ends(registry: no_clients, detachable: nil, client: nil)
      allow(TextSubs).to receive(:subs).and_call_original

      expect(run_hooks(line)).to eq(line)
      expect(TextSubs).not_to have_received(:subs)
      # DownstreamHook.run drops a hook that raises and passes the line on
      # unchanged, which would look like a skip.
      expect(DownstreamHook.list).to include('textsub')
    end

    it 'does not call TextSubs.apply when no front end is attached' do
      install_probe_catalog
      front_ends(registry: no_clients, detachable: nil, client: nil)
      allow(TextSubs).to receive(:apply).and_call_original

      expect(run_hooks(line)).to eq(line)
      expect(TextSubs).not_to have_received(:apply)
    end

    it 'skips the catalog in the harness, which has no front end, when nothing is stubbed' do
      install_probe_catalog
      expect(run_hooks(line)).to eq(line)
      expect(DownstreamHook.list).to include('textsub')
    end

    attached_sources.each do |source, sources|
      it "rewrites the line exactly as reference_apply does with a front end in #{source}" do
        install_probe_catalog
        front_ends(**instance_exec(&sources))
        expected = reference_apply(TextSubs.subs, line)

        expect(expected).not_to eq(line)
        expect(run_hooks(line)).to eq(expected)
        # The rewrite came through the attached branch, not around the guard,
        # and the hook asked bare: front_ends discards the hook's arguments, so
        # an explicit client: nil would otherwise pass while disabling textsubs.
        expect(TextSubs).to have_received(:client_attached?).with(no_args).once
      end
    end

    it 'asks again on every line, so a front end that attaches or leaves later is honoured' do
      install_probe_catalog
      attached = nil
      # Parenthesized so the block goes to and_wrap_original, not to `to`.
      allow(TextSubs).to(receive(:client_attached?).and_wrap_original do |original|
        original.call(registry: no_clients, detachable: attached, client: nil)
      end)

      expect(run_hooks(line)).to eq(line)
      attached = front_end
      expect(run_hooks(line)).to eq("You feel FINE.\r\n")
      attached = nil
      expect(run_hooks(line)).to eq(line)
    end

    it 'still builds the catalog and registers the hook when it starts with no front end' do
      expect { install_probe_catalog }.not_to raise_error
      expect(DownstreamHook.list).to include('textsub')
      expect(TextSubs.subs.size).to be > 100
    end
  end

  # What single built-in subs do to the game lines they were written for. The
  # golden catalog pins each entry as it stands, mistakes included; these pin
  # the output a player should see.
  describe 'built-in subs' do
    include_context 'with a front end attached'

    # Builds `guild`'s catalog with the real entry point and sends one server
    # line through the registered hooks.
    #
    # @param line [String] a server line without its line ending
    # @param guild [String] whose catalog to build
    # @param line_ending [String] appended to `line`; raw server lines end in "\r\n"
    # @return [String, nil] what the hooks pass on for "#{line}#{line_ending}"
    # @example
    #   hooked('The back of your neck prickles.', guild: 'Necromancer')
    #   # => "The back of your neck prickles. (DO gained from being in a Holy area. Move away to avoid this hit.)\r\n"
    def hooked(line, guild: 'Commoner', line_ending: "\r\n")
      build_catalog(guild)
      run_hooks("#{line}#{line_ending}".b)
    end

    # A double-quoted literal turns "\1" into byte 0x01 and "\b" into a
    # backspace; a single-quoted one keeps the backslash for the regex engine.
    #
    # The 96 catalogs hold ~100,000 entries but only ~1,600 distinct ones, so
    # each distinct entry's bytes are read once and every combination that
    # holds it is still named.
    it 'holds no control byte (0x00-0x1f) in any key or value of any catalog' do
      control_byte = Hash.new do |seen, entry|
        source, _options, replacement = entry
        seen[entry] = [source, replacement].any? { |text| text.bytes.any? { |byte| byte < 0x20 } }
      end
      offenders = combinations.flat_map do |combination|
        catalog_of(combination).filter_map do |entry|
          source, _options, replacement = entry
          [combination, source, replacement] if control_byte[entry]
        end
      end
      expect(offenders).to be_empty, lambda {
        "#{offenders.size} entr(y/ies) hold a control byte (a double-quoted \"\\1\" or \"\\b\"?):\n" \
          "#{offenders.uniq { |entry| entry.drop(1) }.first(5).map { |entry| "  #{entry.inspect}" }.join("\n")}"
      }
    end

    # Whether a catalog key starts with a wildcard. Keys are unanchored and
    # gsub! replaces only what they match, so a leading wildcard swallows
    # whatever came before the message on the line (XML tags, other text):
    # a value that drops it deletes that text, and one that puts it back
    # gains nothing a key without it could not do. Either way no key needs one.
    #
    # The wildcard is any character ('.', '\X', '\N') or any character but
    # a few: a negated class ('[^\n]'), shorthand ('\S', '\W', '\D', '\H')
    # or property ('\P{...}'), under '*', '+' or a '{m,n}' range, lazy or
    # not. A positive class ('[a-z]*', '\s*') is not a wildcard.
    # It may follow an optional '^' or '\A', inline flags ('(?i)') and any
    # number of opening groups: plain, non-capturing, named or flag-scoped
    # ('(', '(?:', '(?<name>', '(?i:'). Lookarounds ('(?!.*>)') consume
    # nothing and do not count.
    #
    # @param source [String] a catalog key's regex source
    # @return [Boolean] true when the key opens with a wildcard
    # @example
    #   leading_wildcard?('(?<before>.*)You feel')   # => true
    #   leading_wildcard?('(?!.*>)\d{1,3}')           # => false
    def leading_wildcard?(source)
      source.match?(
        /\A(?:\^|\\A)?(?:\(\?[imx-]+\))*(?:\((?:\?(?::|<[A-Za-z_]\w*>|'[A-Za-z_]\w*'|[imx-]+:))?)*
         (?:\.|\[\^(?:\\.|[^\]\\])*\]|\\[SWDHNX]|\\P\{[^}]*\})(?:[*+]|\{\d*,\d*\})/x
      )
    end

    it 'counts each form of leading wildcard as one, and a literal or a later wildcard as none' do
      wildcards = ['.*You feel', '.+You feel', '.*?You feel', '^.*You feel', '\A.+?You feel', '(?:.*)You feel',
                   '(.*)You feel', '(.+?)You feel', '(?<before>.*)You feel', "(?'before'.*)You feel", '((?:.*))You feel',
                   '.{0,}You feel', '.{1,40}You feel', '[^\n]*You feel', '[^\]]+You feel', '\S*You feel',
                   '\P{Space}*You feel', '\X*You feel', '(?m).*You feel', '(?i).*You feel', '(?i:.*)You feel']
      literals = ['You feel (.*) fine', '^You feel', '^(You feel)', '(^)(Fae Arts)(:)', '\.\.\. You feel', '\.*You feel',
                  '(?!.*>)\d{1,3}', '(?<!receiving )(a|an) (glancing)', '(?=.*You)You feel', '(?i)You feel', '.You feel',
                  '.{3}You feel', '[a-z]*You feel', '\s*You feel', '\p{Alpha}*You feel']

      expect(wildcards.reject { |source| leading_wildcard?(source) }).to be_empty
      expect(literals.select { |source| leading_wildcard?(source) }).to be_empty
    end

    it 'holds no key in any catalog that starts with a wildcard' do
      offenders = combinations.flat_map do |combination|
        catalog_of(combination).filter_map { |source, _options, _replacement| [combination['guild'], source] if leading_wildcard?(source) }
      end
      expect(offenders.uniq).to be_empty, -> { "keys that swallow the start of the line:\n#{offenders.uniq.map { |entry| "  #{entry.inspect}" }.join("\n")}" }
    end

    # The hook rewrites the raw XML stream, so a bare '<' in a value opens a
    # tag the front end never sees closed: when markup follows on the row,
    # ProfanityFE drops the annotation and swallows that markup, and Genie
    # (read from source) buffers it into the next row's XML. The
    # Elanthipedia links are the only markup a built-in value may add.
    # Private subs are not built in (and may add markup on purpose), so the
    # engine does not escape values.
    it "adds no '<' outside an <a href=\"...\">...</a> link in any value of any catalog" do
      link = %r{<a href="[^"<>]*">[^<>]*</a>}
      offenders = combinations.flat_map do |combination|
        catalog_of(combination).filter_map do |source, _options, replacement|
          [combination['guild'], source, replacement] if replacement.gsub(link, '').include?('<')
        end
      end
      expect(offenders.uniq).to be_empty, lambda {
        "values that add a bare '<' ([guild, key, value]):\n#{offenders.uniq.map { |entry| "  #{entry.inspect}" }.join("\n")}"
      }
    end

    # The Registry keys on /#{target}/, so a second write of the same source
    # keeps the first slot with the last value and the first value is lost
    # without a word ('jadice' was added as limb-ES and then as limb-EW).
    # Every write has to leave one more key behind.
    #
    # catalog_build_of records the writes in the one build the catalog
    # examples share, so this example does not build the 96 catalogs a
    # second time.
    it 'adds every key source once in every combination' do
      offenders = combinations.filter_map do |combination|
        build = catalog_build_of(combination)
        sources = build[:write_sources]
        size = build[:catalog].size
        repeated = sources.tally.select { |_, count| count > 1 }.keys
        [combination, repeated, sources.size, size] unless repeated.empty? && sources.size == size
      end
      expect(offenders).to be_empty, lambda {
        "#{offenders.size} combination(s) add a key twice ([combination, repeated sources, writes, keys]):\n" \
          "#{offenders.first(5).map { |entry| "  #{entry.inspect}" }.join("\n")}"
      }
    end

    # data/base-herbs.yaml lists jadice flower as the external remedy for
    # limb wounds and jadice pollen as the one for limb scars.
    describe 'the jadice herb notes' do
      [['jadice flower', 'limb-EW'], ['jadice pollen', 'limb-ES']].each do |herb, tag|
        it "tags a #{herb} (#{tag}) with herb_textsubs on" do
          build_catalog('Commoner', 'herb_textsubs' => true)
          expect(run_hooks("You get some #{herb} from your pouch.\r\n".b)).to eq("You get some #{herb} (#{tag}) from your pouch.\r\n")
        end
      end

      # The game writes the plural too ("some jadice flowers"); the tag goes
      # after the whole noun, not between "flower" and its "s".
      it 'tags the plural jadice flowers after the plural noun' do
        build_catalog('Commoner', 'herb_textsubs' => true)
        expect(run_hooks("You get some jadice flowers from your pouch.\r\n".b))
          .to eq("You get some jadice flowers (limb-EW) from your pouch.\r\n")
      end

      it 'leaves a bare jadice, which could be either herb, untagged' do
        build_catalog('Commoner', 'herb_textsubs' => true)
        expect(run_hooks("You see some jadice here.\r\n".b)).to eq("You see some jadice here.\r\n")
      end

      it 'tags neither herb with herb_textsubs off' do
        expect(hooked('You get some jadice flower and some jadice pollen.'))
          .to eq("You get some jadice flower and some jadice pollen.\r\n")
      end
    end

    describe 'the RoC/RoG aura notes' do
      [['Joyous corruption seeps into your mind from your own spell, muting your unconscious sense of shame.',
        ' (Your RoC/RoG spell is strong enough to mask your aura from Clerics and Moon Mages.)'],
       ['You feel a wave of filth wash over you, heralding the renewed health of your internal gauges.',
        ' (You gained some Divine Outrage and your RoC/RoG spell is no longer strong enough to mask your aura from ' \
        'Clerics/Moon Mages. Recast with more mana.)']].each do |message, note|
        it "keeps the tags before \"#{message[0, 30]}...\" and adds the note after it" do
          prefix = '<roundTime value="1"/><pushStream id="combat"/>'
          expect(hooked("#{prefix}#{message}<popStream/>")).to eq("#{prefix}#{message}#{note}<popStream/>\r\n")
        end

        it "keeps the text before \"#{message[0, 30]}...\" on the same line" do
          expect(hooked("You feel fine.  #{message}")).to eq("You feel fine.  #{message}#{note}\r\n")
        end
      end
    end

    describe 'the Holy-area Divine Outrage warning' do
      note = ' (DO gained from being in a Holy area. Move away to avoid this hit.)'
      ['The back of your neck prickles.', 'You feel judged and hated.', 'Muddled thoughts of paranoia nag at you.',
       'You are exposed and vulnerable in this place.', "You have a feeling that you aren't welcome here.",
       'You worry for your safety and well-being.'].each do |sentence|
        it "keeps \"#{sentence}\" and adds the DO note after it" do
          expect(hooked(sentence, guild: 'Necromancer')).to eq("#{sentence}#{note}\r\n")
        end
      end

      it 'needs the closing full stop, not just any character after the sentence' do
        expect(hooked('You feel judged and hatedX', guild: 'Necromancer')).to eq("You feel judged and hatedX\r\n")
      end
    end

    # The game tells tier 18 from tier 17 only by the "(That'll leave a mark!)"
    # after the hit, so the two keys must see real parentheses there.
    describe 'the devastating-hit tiers' do
      # A plain tier-17 line was already labelled right before the quoting
      # fix; this pins it so a later edit to the lookahead cannot stop key 17
      # from matching. The tier-18 example is the one that fails on the bug.
      it 'labels a devastating hit (17/23) and nothing else' do
        expect(hooked("The punch lands a devastating hit to the goblin's chest."))
          .to eq("The punch lands a devastating hit (17/23) to the goblin's chest.\r\n")
      end

      it "labels a devastating hit (That'll leave a mark!) (18/23) and nothing else" do
        expect(hooked("The punch lands a devastating hit (That'll leave a mark!) to the goblin's chest."))
          .to eq("The punch lands a devastating hit (That'll leave a mark!) (18/23) to the goblin's chest.\r\n")
      end
    end

    # Raw server lines end in \r\n and Ruby's '$' matches only before \n, so
    # these two end-anchored keys have to allow the \r in front of it.
    describe 'the end-anchored Ranger howl tiers' do
      [["You open your mouth and roar with everything you've got!  A few soft sounds reminiscent of a baby robin's " \
        'first song twitter sweetly from within you.', '4/15'],
       ["You howl quietly to yourself, echoing a soft, desolate sound that doesn't sound quite right.", '7/15']].each do |howl, tier|
        it "labels the (#{tier}) howl on a line that ends in \\r\\n" do
          expect(hooked(howl, guild: 'Ranger')).to eq("#{howl} (#{tier})\r\n")
        end

        it "labels the (#{tier}) howl on a line that ends in a bare \\n" do
          expect(hooked(howl, guild: 'Ranger', line_ending: "\n")).to eq("#{howl} (#{tier})\n")
        end

        it "leaves the (#{tier}) howl alone when more text follows it on the line" do
          line = "#{howl}  You cough."
          expect(hooked(line, guild: 'Ranger')).to eq("#{line}\r\n")
        end
      end
    end

    # The game wraps the gavel's sound in literal asterisks, so the key has to
    # escape them: unescaped, ' *' and 'D*' are quantifiers.
    describe 'the Thief (13/13) gavel warning' do
      gavel = "the heavy *THUD* of a judge's gavel echoes through your mind"

      it 'labels the line with the literal *THUD* (13/13)' do
        expect(hooked("Glancing about, #{gavel}.", guild: 'Thief')).to eq("Glancing about, #{gavel} (13/13).\r\n")
      end

      it 'leaves the line alone when the asterisks are missing' do
        line = "Glancing about, the heavy THUD of a judge's gavel echoes through your mind."
        expect(hooked(line, guild: 'Thief')).to eq("#{line}\r\n")
      end
    end

    # Two Bard blocks used to hold a song ladder each: one keyed on the end of
    # every message, one on the whole message, so a Bard got each counter
    # twice ("bowing your head (4/7). (4/7)"). Every message gets its counter
    # once, before the full stop.
    describe 'the Bard song assessment' do
      [['You stop only after those first few lines, however, unable to remember any more', 1],
       ['Your voice cracks on the second line, however, and you stop, unable to remember any more of the song anyway', 1],
       ['At one point you hesitate as you mentally grasp for the next line of the song, and stop in confusion, ' \
        'but pick it up a moment later and bring it to a strong conclusion', 2],
       ['You feel a bit tired as you finish, but grin despite that for the ease at which you sang', 3],
       ['You bring the song to a close, bowing your head', 4],
       ['Your voice carries strongly on the air as you effortlessly recite the Common words so that all may hear, ' \
        'bowing your head as they come to a close', 5],
       ['Tears fill your eyes as the emotion of your ancient aire grips you, and you raise your chin with pride ' \
        'as it comes to a close', 6],
       ['When the song finally comes to a close, you bow your head, your ears ringing in the silence', 7]].each do |message, tier|
        it "labels \"#{message[0, 40]}...\" (#{tier}/7) once" do
          expect(hooked("#{message}.", guild: 'Bard')).to eq("#{message} (#{tier}/7).\r\n")
        end
      end

      # The (5/7) message names the language the song is sung in. The key
      # takes any language name spelled with letters (A-Z, a-z), apostrophes,
      # hyphens and spaces, as in race names such as S'Kra Mur and Gor'Tog,
      # not just the Common the ladder above pins. 'Old-Common' is synthetic:
      # it pins the hyphen.
      ['Elothean', "S'Kra Mur", "Gor'Tog", 'Old-Common'].each do |language|
        it "labels the (5/7) message once when the words are #{language}" do
          message = "Your voice carries strongly on the air as you effortlessly recite the #{language} words so that " \
                    'all may hear, bowing your head as they come to a close'
          expect(hooked("#{message}.", guild: 'Bard')).to eq("#{message} (5/7).\r\n")
        end
      end

      # The slot takes nothing else, and is never empty, so each of these
      # synthetic lines gets no (5/7) counter: markup sent in the server line
      # (which a class loosened to .+ would take), a digit, an underscore
      # (each of which \w would take) and an empty slot (which * in place of
      # + would take).
      ['<b>Common</b>', 'C0mmon', 'Old_Common', ''].each do |slot|
        it "leaves the (5/7) message alone when the language slot holds #{slot.inspect}" do
          line = "Your voice carries strongly on the air as you effortlessly recite the #{slot} words so that " \
                 'all may hear, bowing your head as they come to a close.'
          expect(hooked(line, guild: 'Bard')).to eq("#{line}\r\n")
        end
      end

      it 'leaves the song messages alone for a guild other than Bard' do
        line = 'You bring the song to a close, bowing your head.'
        expect(hooked(line, guild: 'Empath')).to eq("#{line}\r\n")
      end
    end

    # The vitality bands used to read '(vitality <50%)', a bare '<' in the
    # XML stream; they are plain words now, since no front end is known to
    # decode an '&lt;' entity in game text.
    describe 'the Empath vitality notes' do
      [['The presence of Bob, whose life essence is wavering.', ' (vitality under 50%)'],
       ['The presence of Bob, whose life essence is almost extinguished.', ' (vitality under 20%)'],
       ['The presence of Bob, a fellow Empath, whose life essence is wavering.', ' (vitality under 50%)'],
       ['The presence of Bob, a fellow Empath, whose life essence is almost extinguished.', ' (vitality under 20%)'],
       ['A wavering life essence nearby.', ' (critter with vitality under 50%)']].each do |message, note|
        it "notes \"#{message}\" as#{note}" do
          expect(hooked(message, guild: 'Empath')).to eq("#{message}#{note}\r\n")
        end

        # A prompt after the message on the same row is where a bare '<'
        # did its damage: the front end read '<50%) <prompt ...>' as one tag.
        it "leaves the markup after \"#{message}\" with exactly the tags it came with" do
          prompt = '<prompt time="1700000000">&gt;</prompt>'
          output = hooked("#{message}#{prompt}", guild: 'Empath')
          expect(output).to eq("#{message}#{note}#{prompt}\r\n")
        end
      end

      it 'leaves the presence lines alone for a guild other than Empath' do
        line = 'The presence of Bob, whose life essence is wavering.'
        expect(hooked(line, guild: 'Cleric')).to eq("#{line}\r\n")
      end
    end

    # The first two rungs of the durability ladder spelled the game's word
    # 'durabiltiy'. Every rung shortens 'you determine it is' to 'it is';
    # these two now read like the other sixteen.
    describe 'the durability (1/18) and (2/18) notes' do
      [['it is extremely weak and easily damaged', 1],
       ['they are very delicate and easily damaged', 2]].each do |condition, tier|
        it "spells durability right in the (#{tier}/18) note" do
          expect(hooked("Assessing the steel sword durability, you determine #{condition}."))
            .to eq("Assessing the steel sword durability, #{condition} (#{tier}/18).\r\n")
        end
      end
    end

    # Every scroll label keeps the full stop the game puts inside the quoted
    # title; the Demrris' Resolve one used to drop it.
    describe "the Demrris' Resolve scroll label" do
      it 'keeps the full stop inside the quoted title and adds (Bard)' do
        expect(hooked(%(It is labeled "Demrris' Resolve.")))
          .to eq(%(It is labeled "Demrris' Resolve." (Bard)\r\n))
      end
    end

    # With textsubs_spell_links on, the magic feats list gets a wiki link.
    # The link used to replace the game's 'magic feats of' with
    # 'magical feats:', so the list read 'magical feats: Sorcerous
    # Patterns, ...'. It wraps the game's own words now.
    describe 'the magic feats link' do
      feats = 'Sorcerous Patterns, Alternate Preparation and Augmentation Mastery.'
      link = '<a href="https://elanthipedia.play.net/Magical_feats">magic feats</a>'

      it "links the game's 'magic feats' and keeps the 'of' before the list" do
        build_catalog('Commoner', 'textsubs_spell_links' => true)
        expect(run_hooks("You recall proficiency with the magic feats of #{feats}\r\n".b))
          .to eq("You recall proficiency with the #{link} of #{feats}\r\n")
      end

      it 'adds no second colon when the game ends the line with one' do
        build_catalog('Commoner', 'textsubs_spell_links' => true)
        expect(run_hooks("You recall proficiency with the magic feats of:\r\n".b))
          .to eq("You recall proficiency with the #{link} of:\r\n")
      end
    end

    # The Trader starlight ladder puts each counter before the full stop;
    # the (1/9) rung used to put the stop inside the parentheses.
    describe 'the Trader starlight (1/9) note' do
      it 'puts the full stop after the counter' do
        expect(hooked('A bare flicker of starlight plays within your aura.', guild: 'Trader'))
          .to eq("A bare flicker of starlight plays within your aura (1/9).\r\n")
      end
    end

    # Three rungs of the crafted-quality ladder wrote a fixed 'is' in place
    # of the verb and 'of' they matched, so plural items read 'They is
    # finely-crafted (8/12) quality.' Like the other rungs, they write back
    # what they matched and add the counter.
    describe 'the crafted-quality notes' do
      [['finely-crafted', 8], ['well-crafted', 7], ['poorly-crafted', 2]].each do |quality, tier|
        it "keeps 'are of' on a plural #{quality} item and adds (#{tier}/12)" do
          expect(hooked("They are of #{quality} quality."))
            .to eq("They are of #{quality} (#{tier}/12) quality.\r\n")
        end

        it "keeps 'is of' on a single #{quality} item and adds (#{tier}/12)" do
          expect(hooked("It is of #{quality} quality."))
            .to eq("It is of #{quality} (#{tier}/12) quality.\r\n")
        end

        # Without 'of' and 'quality' the empty alternatives match, so this
        # pins that both are written back from the match, never hardcoded.
        it "adds (#{tier}/12) to a bare 'are #{quality}' with no 'of' or 'quality'" do
          expect(hooked("They are #{quality}."))
            .to eq("They are #{quality} (#{tier}/12).\r\n")
        end
      end
    end
  end

  describe 'reference-engine oracle' do
    include_context 'with a front end attached'

    samples = TextsubsCorpus.parse_samples(File.read(samples_path)).map(&:b)
    stream = File.binread(stream_path).lines
    big_line = stream.max_by(&:bytesize)
    # reference_apply spends ~0.5 s in the coin regex on the 49 KB line per
    # pass (the hook skips that regex, as the line holds no currency word), so
    # the per-guild sweeps leave the line to the one whole-stream example below.
    stream_without_big_line = stream - [big_line]
    every_flag_on = { 'textsubs_spell_links' => true, 'herb_textsubs' => true }.freeze

    # The lines the catalog sweeps run: every sample, then every stream line
    # but the 49 KB one. A sample's index here is its index in `samples`.
    corpus = samples + stream_without_big_line
    # reference_apply's select step, run once per distinct key: the indexes of
    # the corpus lines each key matches (key.match?(line) is true exactly when
    # key =~ line is), worked out the first time an example asks for the key.
    # The guild catalogs share most of their keys, so the sweeps run each key
    # over the corpus once instead of once per catalog. A key built again by a
    # later example finds its entry: Regexp#eql? compares source and options.
    corpus_matches = Hash.new { |cache, key| cache[key] = corpus.each_index.select { |at| key.match?(corpus[at]) } }
    # The gates production installs, read from the built Registries rather
    # than from the YAML, so the gate-soundness example and the one-index
    # examples check the same gates, and a gate that add_catalog or
    # Catalog.expand adds, drops or changes is what they check. Reading them
    # costs the 96 shared builds (catalog_build_of): run on their own, those
    # examples take about a second longer than a YAML read would, and the
    # full file nothing, as the golden examples make the same builds. Going
    # back to the YAML copy would lose exactly that check.
    #
    # @return [Hash{Regexp=>Array<String>}] each key any of the 96 built
    #   Registries gates, and its requires_any words (see catalog_build_of)
    define_method(:every_key_gates) do
      combinations.map { |combination| catalog_build_of(combination)[:gates] }.reduce(:merge)
                  .transform_keys { |source, options| Regexp.new(source, options) }
    end
    entries = read_entries.call
    # What the generator makes of today's catalog, each part worked out the
    # first time an example asks for it:
    # - :expanded, the samples expanded from the catalog's regex sources;
    # - :composites, the composite lines joined from them;
    # - :generated, both in order ('corpus fixtures' checks that samples.jsonl
    #   is these lines, then the hand-added ones);
    # - :composite_indexes, the indexes in `samples` of the composite lines.
    # Not worked out while the file loads: a generator error (a catalog change
    # leaving a COMPOSITE_FAMILIES pattern with no sample to match) then fails
    # the examples that need the generator, not the loading of every spec file
    # in the run.
    corpus_generator = Hash.new do |generator, part|
      generator[part] =
        case part
        when :expanded then TextsubsCorpus.expanded_samples(entries)
        when :composites then TextsubsCorpus.composite_samples(generator[:expanded])
        when :generated then generator[:expanded] + generator[:composites]
        when :composite_indexes
          composite_lines = generator[:composites].map(&:b).to_set
          samples.each_index.select { |at| composite_lines.include?(samples[at]) }
        else raise KeyError, "the generator makes no #{part.inspect}"
        end
    end
    hand_added = TextsubsCorpus.parse_samples(File.read(hand_added_path))

    # For each corpus line, the keys of `subs` that match it, in catalog order:
    # what reference_apply's select step gives for the line.
    #
    # @param subs [Hash{Regexp=>String}] ordered catalog (TextSubs.subs)
    # @param corpus_matches [Hash{Regexp=>Array<Integer>}] corpus line indexes per key
    # @param size [Integer] number of corpus lines
    # @return [Array<Array<Regexp>>] one ordered key list per corpus line
    def selected_keys(subs, corpus_matches, size)
      selected = Array.new(size) { [] }
      subs.each_key { |key| corpus_matches[key].each { |at| selected[at] << key } }
      selected
    end

    # reference_apply's apply step: gsub! each selected key, in the order
    # given, on the line as it changes.
    #
    # @param subs [Hash{Regexp=>String}] the catalog the keys come from
    # @param keys [Array<Regexp>] the selected keys, in the order they run
    # @param line [String] a server line; not modified
    # @return [String] the line after substitution
    def apply_selected(subs, keys, line)
      keys.each_with_object(line.dup) { |key, output| output.gsub!(key, subs[key]) }
    end

    # Each catalog's reference run (see reference_run), keyed by the catalog's
    # [key, value] pairs, worked out the first time an example installs that
    # catalog. Several examples install the same catalog (each guild's with
    # every flag on is installed by its sweep, its key order example and the
    # two-counter example), so each catalog's lines are worked out once per
    # run instead of once per example.
    reference_runs = {}

    # reference_apply's select step and output for every corpus line, with the
    # select step looked up in corpus_matches, shared by every example that
    # installs the same catalog. Two catalogs share a run only when they hold
    # the same keys with the same values in the same order, which is
    # everything reference_apply reads.
    #
    # @param subs [Hash{Regexp=>String}] ordered catalog (TextSubs.subs)
    # @return [Hash{Symbol=>Array}] deep-frozen, because every caller shares it:
    #   :selected [Array<Array<Regexp>>], selected_keys for every corpus line;
    #   :output [Array<String>], the reference output for every corpus line
    define_method(:reference_run) do |subs|
      reference_runs[subs.to_a.freeze] ||= begin
        selected = selected_keys(subs, corpus_matches, corpus.size).each(&:freeze).freeze
        output = selected.each_with_index.map { |keys, at| apply_selected(subs, keys, corpus[at]).freeze }.freeze
        { selected: selected, output: output }.freeze
      end
    end

    # Sends each line through the registered hooks and compares the output
    # with the reference output for that line.
    #
    # @param lines [Array<String>] binary server lines
    # @param expected [Array<String>] the reference output for each line;
    #   reference_apply with the current TextSubs.subs unless given
    # @return [Array<Array(String, String, String)>] [line, hook output,
    #   reference output] for each line where the two differ
    def oracle_mismatches(lines, expected = lines.map { |line| reference_apply(TextSubs.subs, line) })
      lines.each_with_index.filter_map do |line, at|
        hooked = run_hooks(line)
        [line, hooked, expected[at]] unless hooked == expected[at]
      end
    end

    # @param catalog [String] which catalog was in force
    # @param mismatches [Array<Array(String, String, String)>] from oracle_mismatches
    # @return [String] the count and the first five differences, each value cut
    #   to 300 characters so the 49 KB line stays readable
    def mismatch_report(catalog, mismatches)
      shown = mismatches.first(5).map do |line, hooked, expected|
        "  line:      #{line.inspect[0, 300]}\n  hook:      #{hooked.inspect[0, 300]}\n  " \
          "reference: #{expected.inspect[0, 300]}"
      end
      "#{mismatches.size} line(s) differ from reference_apply with the #{catalog} catalog:\n#{shown.join("\n")}"
    end

    describe 'corpus fixtures' do
      if ENV['TEXTSUBS_CORPUS_WRITE'] == '1'
        it 'writes samples.jsonl and synthetic_stream.xml from the catalog and samples_hand_added.jsonl' do
          # Both writers run in one rspec run in random order, so the samples
          # could come from the catalog_entries.jsonl the golden writer replaces.
          expect(ENV.fetch('TEXTSUBS_GOLDEN_WRITE', nil)).not_to eq('1'),
                                                                 'run TEXTSUBS_GOLDEN_WRITE=1 first, then TEXTSUBS_CORPUS_WRITE=1 on its own'
          generated = corpus_generator[:generated]
          composites = corpus_generator[:composites]
          redundant = TextsubsCorpus.redundant_hand_added(generated, hand_added)
          expect(redundant).to eq([]), "delete these from samples_hand_added.jsonl (repeated, or generated): #{redundant.inspect}"
          # The every-run examples check this for the flags-on catalogs with plat
          # grouping off, and for Trader with it on; here every catalog with
          # spell links and herbs on, before the new composites are written.
          composite_matches = Hash.new { |cache, key| cache[key] = composites.each_index.select { |at| key.match?(composites[at]) } }
          thin = combinations.select { |combination| combination['textsubs_spell_links'] && combination['herb_textsubs'] }.flat_map do |combination|
            build_combination(combination)
            selected = selected_keys(TextSubs.subs, composite_matches, composites.size)
            composites.each_index.reject { |at| selected[at].size >= 2 }.map { |at| [combination['guild'], composites[at]] }
          end
          expect(thin).to eq([]), 'each composite sample must be matched by two or more keys of every catalog with spell links and ' \
                                  "herbs on; [guild, composite] pairs where it is not: #{thin.inspect}"

          lines = TextsubsCorpus.samples_lines(generated, hand_added)
          # Names every line the rewrite drops, so a line added straight to
          # samples.jsonl is not lost without a word.
          dropped = TextsubsCorpus.drop_warning(File.read(samples_path), lines)
          warn dropped if dropped
          File.write(samples_path, TextsubsCorpus.samples_jsonl(lines))
          File.binwrite(stream_path, TextsubsCorpus.stream)
        end
      else
        it 'holds the generated samples, then the lines of samples_hand_added.jsonl, each line once' do
          fault = TextsubsCorpus.samples_fault(File.read(samples_path), corpus_generator[:generated], hand_added)
          expect(fault).to be_nil, fault
        end

        it 'holds the generated stream' do
          committed = File.binread(stream_path)
          generated_stream = TextsubsCorpus.stream
          at = TextsubsCorpus.first_difference(committed.bytes, generated_stream.bytes) unless committed == generated_stream
          expect(at).to be_nil, lambda {
            "synthetic_stream.xml differs from TextsubsCorpus.stream at byte #{at}: " \
              "#{committed[at, 60].inspect} vs #{generated_stream[at, 60].inspect}; regenerate it with " \
              'TEXTSUBS_CORPUS_WRITE=1 bundle exec rspec spec/textsubs_spec.rb'
          }
        end
      end

      it 'takes each composite part as the first expanded sample its pattern matches' do
        expect(TextsubsCorpus.composite_part(['a hit', 'a light hit', 'a light hit (grazing)'], /\Aa light hit\b/, 'COMPOSITE_FAMILIES'))
          .to eq('a light hit')
      end

      it 'names the constant and the pattern when no expanded sample is left for a composite part' do
        expect { TextsubsCorpus.composite_samples(corpus_generator[:expanded].grep_v(/\AEncumbrance : /)) }
          .to raise_error(ArgumentError, %r{\ACOMPOSITE_FAMILIES pattern /\\AEncumbrance : Burdened\\b/ matches no expanded sample})
      end

      it 'keeps every hand-added sample, after the generated ones and in its file order' do
        # A regeneration after a catalog change: 'gen two' is no longer made.
        expect(TextsubsCorpus.samples_lines(['gen one', 'gen three'], ['hand first', 'hand second']))
          .to eq(['gen one', 'gen three', 'hand first', 'hand second'])
      end

      it 'fails a samples.jsonl that moved a hand-added line into the generated ones, or dropped it' do
        generated = corpus_generator[:generated]
        hand = ['HAND line pinning a pattern', 'HAND line at the end']
        in_order = TextsubsCorpus.samples_jsonl(generated + hand)
        moved = TextsubsCorpus.samples_jsonl(generated.dup.insert(100, hand.first) + hand.drop(1))
        dropped = TextsubsCorpus.samples_jsonl(generated + hand.drop(1))
        expect(TextsubsCorpus.samples_fault(in_order, generated, hand)).to be_nil
        expect(TextsubsCorpus.samples_fault(moved, generated, hand)).to start_with('samples.jsonl line 101 is "\"HAND line pinning a pattern\"')
        expect(TextsubsCorpus.samples_fault(dropped, generated, hand)).to start_with("samples.jsonl line #{generated.size + 1} ")
      end

      it 'names first the lines regenerating drops, then where samples.jsonl ends early or runs on' do
        generated = corpus_generator[:generated]
        hand = ['HAND line']
        stray = 'STRAY line added straight to samples.jsonl'
        runs_on = TextsubsCorpus.samples_fault(TextsubsCorpus.samples_jsonl(generated + hand + [stray]), generated, hand)
        ends_early = TextsubsCorpus.samples_fault(TextsubsCorpus.samples_jsonl(generated), generated, hand)
        stray_line = "#{stray.to_json}\n".inspect
        hand_line = "#{hand.first.to_json}\n".inspect
        expect(runs_on).to start_with('regenerating samples.jsonl drops 1 line(s) that neither the generator nor ' \
                                      'samples_hand_added.jsonl makes; move any added by hand to samples_hand_added.jsonl')
          .and include(": #{[stray].inspect}; samples.jsonl line #{generated.size + 2} is #{stray_line}, " \
                       'the generator puts nothing (end of file) there; regenerate it')
        expect(ends_early).to start_with("samples.jsonl has no line #{generated.size + 1} (end of file), " \
                                         "the generator puts #{hand_line} there; regenerate it")
      end

      it 'names every line of samples.jsonl a regeneration drops, and nothing when it drops none' do
        content = TextsubsCorpus.samples_jsonl(['kept', 'no longer generated', 'added by hand'])
        expect(TextsubsCorpus.drop_warning(content, ['kept', 'new'])).to end_with(['no longer generated', 'added by hand'].inspect)
        expect(TextsubsCorpus.drop_warning(content, ['added by hand', 'new', 'no longer generated', 'kept'])).to be_nil
      end

      it 'fails a hand-added line that is there twice or that the generator makes too' do
        generated = corpus_generator[:generated]
        hand = ['HAND line', generated.first, 'HAND line']
        fault = TextsubsCorpus.samples_fault(TextsubsCorpus.samples_jsonl(generated + hand), generated, hand)
        expect(fault).to start_with('samples_hand_added.jsonl holds these lines more than once')
          .and include(['HAND line', generated.first].inspect)
      end
    end

    it 'reads a synthetic stream of \r\n lines holding one 49 KB digit-heavy line with no currency word' do
      expect(stream).to all(end_with("\r\n"))
      expect(stream.join).to be_ascii_only
      expect(big_line.bytesize).to be >= 49_000
      expect(big_line.count('0-9')).to be > 10_000
      expect(big_line).not_to match(/Kronar|Dokora|Lirum/)
    end

    it 'reads one-line ASCII samples' do
      expect(samples.size).to be > 2_000
      expect(samples).to all(be_ascii_only)
      expect(samples.grep(/[\r\n]/)).to eq([])
    end

    guilds.each do |guild|
      it "gives reference_apply's output for every sample and stream line with the #{guild} catalog" do
        build_catalog(guild, every_flag_on)
        mismatches = oracle_mismatches(corpus, reference_run(TextSubs.subs)[:output])
        expect(mismatches).to be_empty, -> { mismatch_report(guild, mismatches) }
      end

      it "matches every key of the #{guild} catalog with at least one sample" do
        build_catalog(guild, every_flag_on)
        unmatched = TextSubs.subs.keys.reject { |key| corpus_matches[key].any? { |at| at < samples.size } }
        expect(unmatched.map(&:source)).to eq([]), lambda {
          "#{unmatched.size} #{guild} key(s) match no line of samples.jsonl; add a sample for each:\n" \
            "#{unmatched.map { |key| "  #{key.source}" }.join("\n")}"
        }
      end

      # Without lines that several keys match, and some where their order
      # matters, the sweep above holds each real key to the reference on its
      # own and a reordered engine would still pass it. Running reference_apply
      # over the catalog reversed is exactly such an engine.
      it "holds lines that two or more #{guild} keys match, in some of which the key order changes the output" do
        # reference_apply over the reversed catalog selects the same keys and
        # runs them in reverse order.
        build_catalog(guild, every_flag_on)
        subs = TextSubs.subs
        selected = reference_run(subs)[:selected].first(samples.size)
        shared = samples.each_index.select { |at| selected[at].size >= 2 }
        order_sensitive = shared.reject do |at|
          apply_selected(subs, selected[at].reverse, samples[at]) == apply_selected(subs, selected[at], samples[at])
        end
        thin = corpus_generator[:composite_indexes].reject { |at| selected[at].size >= 2 }.map { |at| samples[at] }
        expect(thin).to eq([]), "every composite sample must be matched by two or more #{guild} keys; these are not: #{thin.inspect}"
        expect(shared.size).to be >= 50, "only #{shared.size} sample(s) are matched by two or more #{guild} keys"
        expect(order_sensitive.size).to be >= 4,
                                        "only #{order_sensitive.size} sample(s) give another output with the #{guild} keys reversed"
      end
    end

    # A progress counter: "(4/7)", "(10/10)". Ingot sizes "(1)" and percent
    # bands "(40-50%)" are not counters.
    counter = %r{\(\d+/\d+\)}

    # Two keys that label the same message stack their counters. No single
    # sample is one message with two counters, so a sample whose output under
    # a catalog gets a second new counter is two keys labelling it. The
    # composite lines at the end of samples.jsonl join two samples, each of
    # which may have its own counter, so they are judged by their parts.
    #
    # The output for a sample is reference_apply's, from the same reference run
    # the per-guild sweeps above read; those sweeps hold the hook to it on
    # every sample with these same catalogs, and sending the ~28,000 lines
    # through the hook again here took ~3.8 s.
    it 'gives no sample of any guild catalog two new (n/m) counters' do
      known = samples.to_set
      composite = lambda do |sample|
        (0...sample.size).any? { |i| sample[i] == ' ' && known.include?(sample[0...i]) && known.include?(sample[(i + 1)..]) }
      end
      single_indexes = samples.each_index.reject { |at| composite.call(samples[at]) }
      expect(samples.size - single_indexes.size).to be >= 10
      offenders = guilds.flat_map do |guild|
        build_catalog(guild, every_flag_on)
        output = reference_run(TextSubs.subs)[:output]
        single_indexes.filter_map do |at|
          sample = samples[at]
          [guild, sample, output[at]] if output[at].scan(counter).size - sample.scan(counter).size > 1
        end
      end
      expect(offenders).to be_empty, lambda {
        "#{offenders.size} sample(s) get two counters:\n#{offenders.first(10).map { |entry| "  #{entry.inspect}" }.join("\n")}"
      }
    end

    it "gives reference_apply's output for the whole stream, 49 KB line included, with the default coin rule" do
      build_catalog('Trader', every_flag_on.merge('textsubs_use_plat_grouping' => false))
      mismatches = oracle_mismatches(stream)
      expect(mismatches).to be_empty, -> { mismatch_report('Trader (plat grouping off)', mismatches) }
    end

    it "gives reference_apply's output for every sample and stream line with textsubs_use_plat_grouping on" do
      # The 49 KB line is left out: reference_apply runs the two platinum-aware
      # coin rules on it for ~3.5 s, and 'the coin-comma gate' below shows the
      # hook runs neither.
      build_catalog('Trader', every_flag_on.merge('textsubs_use_plat_grouping' => true))
      run = reference_run(TextSubs.subs)
      mismatches = oracle_mismatches(corpus, run[:output])
      expect(mismatches).to be_empty, -> { mismatch_report('Trader (plat grouping on)', mismatches) }
      # The per-guild key order examples check the composites with plat
      # grouping off; its two coin rules have to match them too.
      selected = run[:selected]
      expect(corpus_generator[:composite_indexes].reject { |at| selected[at].size >= 2 }.map { |at| samples[at] }).to eq([])
    end

    # The sweeps above take reference_apply's select step from corpus_matches.
    # Here it is held to reference_apply's own select (key =~ line). Every line
    # the lookup lists for a key of any catalog has to match the key: gsub!
    # with a key that does not match changes nothing, so an extra line would
    # pass every output comparison and pad the key coverage and key order
    # examples. reference_apply runs on every corpus line with the Trader
    # catalog; the keys its select step picks (recorded from a copy of the
    # catalog, so the regexes run once) have to be the looked-up ones, in
    # catalog order, and its output the looked-up output, both as the shared
    # reference run (reference_run) the sweeps read holds them.
    it 'looks up the same select step reference_apply runs, on every corpus line' do
      extra = every_key.select { |key| corpus_matches[key].any? { |at| (key =~ corpus[at]).nil? } }
      build_catalog('Trader', every_flag_on.merge('textsubs_use_plat_grouping' => true))
      subs = TextSubs.subs
      selections = []
      recording = subs.dup
      recording.define_singleton_method(:select) { |&block| super(&block).tap { |matches| selections << matches.keys } }
      run = reference_run(subs)
      looked_up = run[:output]
      differ = corpus.each_index.reject { |at| looked_up[at] == reference_apply(recording, corpus[at]) }
      selected = run[:selected]
      expect(extra.map(&:source)).to eq([])
      expect(selections.size).to eq(corpus.size)
      expect(corpus.each_index.reject { |at| selected[at] == selections[at] }.map { |at| corpus[at] }).to eq([])
      expect(looked_up.each_index.count { |at| looked_up[at] != corpus[at] }).to be > 1_000
      expect(differ.map { |at| corpus[at] }).to eq([])
    end

    it 'matches every hand-added sample with a key of some catalog' do
      unmatched = hand_added.reject { |line| every_key.any? { |key| key.match?(line.b) } }
      expect(unmatched).to eq([]), "samples_hand_added.jsonl lines no key matches; delete them or fix the key: #{unmatched.inspect}"
    end

    describe 'the coin-comma gate' do
      # Every call made on a coin-comma key that runs it on a line in the code
      # under the block, by any name a Regexp can be run with, so an engine
      # that ran the key with key =~ line is caught too. Calls that run no
      # match (hash, source) are not counted. Only calls whose receiver is the
      # Regexp are seen: line.match?(key) and line =~ key run on the String, so
      # an engine written that way would slip past the empty-list examples and
      # is caught instead by the currency-word controls below and the Engine
      # 'with gates' examples.
      #
      # @return [Array<Array(Symbol, String)>] [method, key source] per call
      def coin_key_calls
        coin_keys = TextSubs.subs.keys.select { |key| key.source.include?('(Kronar|Dokora|Lirum)') }
        expect(coin_keys).not_to be_empty
        runs = %i[=~ !~ === match match?]
        calls = []
        trace = TracePoint.new(:c_call) do |point|
          next unless runs.include?(point.method_id) && coin_keys.any? { |key| key.equal?(point.self) }

          calls << [point.method_id, point.self.source]
        end
        trace.enable { yield }
        calls
      end

      [false, true].each do |plat|
        context "with textsubs_use_plat_grouping #{plat}" do
          before { build_catalog('Trader', every_flag_on.merge('textsubs_use_plat_grouping' => plat)) }

          it 'runs no coin-comma regex on the 49 KB digit-heavy line, which holds no currency word' do
            output = nil
            expect(coin_key_calls { output = run_hooks(big_line.dup) }).to eq([])
            expect(output).to eq(big_line)
          end

          it 'runs the coin-comma regexes on a line that holds a currency word' do
            expect(coin_key_calls { run_hooks("You have 1234567 Kronars.\r\n".b) }).not_to be_empty
          end
        end
      end

      {
        false => { "You have 1234567 Kronars.\r\n"                     => "You have 1,234,567 Kronars.\r\n",
                   "It costs 15625 Lirums and 9876543210 Dokoras.\r\n" => "It costs 15,625 Lirums and 9,876,543,210 Dokoras.\r\n" },
        true  => { "You have 1234567 Kronars.\r\n"              => "You have 123,4567 Kronars.\r\n",
                   "You have 12345678 platinum, 9 Kronars.\r\n" => "You have 12,345,678 platinum, 9 Kronars.\r\n" }
      }.each do |plat, lines|
        lines.each do |line, grouped|
          it "groups #{line.strip.inspect} as reference_apply does with textsubs_use_plat_grouping #{plat}" do
            build_catalog('Commoner', 'textsubs_use_plat_grouping' => plat)
            expect(run_hooks(line.b)).to eq(grouped)
            expect(reference_apply(TextSubs.subs, line.b)).to eq(grouped)
          end
        end
      end

      # A gate is only sound if each key it gates needs one of its words: every
      # corpus line a gated key matches has to stop matching once each of
      # those words in it is misspelt. The gates are the ones the 96 built
      # Registries hold (every_key_gates), so a gate the catalog build puts on
      # the wrong section is caught here, not only by the sweeps.
      it 'gates only patterns that stop matching a corpus line once its requires_any words are misspelt' do
        gated = every_key_gates
        lines = corpus + ["You have 1234567 Kronars.\r\n".b, "9 Lirums, 1000 Dokoras\r\n".b]
        matched = gated.flat_map { |key, words| lines.select { |line| key.match?(line) }.map { |line| [key, words, line] } }
        unsound = matched.select { |key, words, line| key.match?(line.gsub(Regexp.union(words)) { |word| "X#{word[1..]}" }) }
        expect(unsound.map { |key, _words, line| [key.source, line] }).to eq([])
        expect(gated.size).to eq(3)
        expect(matched.map(&:first).uniq.size).to eq(gated.size)
      end
    end

    # The sweeps above run each guild's catalog through the hook, its own
    # Registry and index included. The engine runs exactly the candidates that
    # match the line, in catalog order, so any catalog gives reference_apply's
    # output on a line as long as every key of it that matches the line is a
    # candidate. A key's tier depends on the key alone, and its gate is the
    # same in every catalog that holds it (the first example below checks
    # that), so one index over every key of every catalog (every_key, which
    # the golden examples hold to what the 96 builds write), gated as the
    # built Registries gate them, checks that for all 96 catalogs at once: one
    # candidates call per line instead of 96 index builds and hook sweeps.
    # Reading the built gates makes these examples depend on the 96 shared
    # builds (see every_key_gates), on purpose.
    describe 'every catalog, through one index over all their keys' do
      # @return [TextSubs::TokenIndex] over every_key, gated by every_key_gates
      define_method(:every_key_index) do
        TextSubs::TokenIndex.new(every_key, every_key_gates)
      end

      it 'finds each key gated alike in every catalog that holds it, and gates only keys of every_key' do
        gates_seen = Hash.new { |seen, entry| seen[entry] = Set.new }
        combinations.each do |combination|
          build = catalog_build_of(combination)
          build[:catalog].each { |source, options, _replacement| gates_seen[[source, options]] << build[:gates][[source, options]] }
        end
        gates = every_key_gates
        # The lookup has to find the gates, or every entry would see only nil
        # and the consistency check below would hold whatever was built.
        expect(gates_seen.count { |_entry, seen| seen.any? }).to eq(3)
        expect(gates_seen.reject { |_entry, seen| seen.size == 1 }).to eq({})
        expect(gates.keys - every_key).to eq([])
        expect(gates.size).to eq(3)
        expect(gates.values.uniq).to eq([%w[Kronar Dokora Lirum]])
      end

      # @param lines [Array<String>]
      # @param matching [Proc] takes a line index and gives the keys of
      #   every_key that match that line
      # @return [Array(Array<Array(String, String)>, Integer)] [key source,
      #   line] for each key every_key_index leaves out of a line it matches,
      #   and the number of key and line pairs that match
      def missed_keys(lines, matching)
        index = every_key_index
        matched = 0
        missed = lines.each_with_index.flat_map do |line, at|
          candidates = index.candidates(line).to_set
          keys = matching.call(at)
          matched += keys.size
          keys.reject { |key| candidates.include?(key) }.map { |key| [key.source, line] }
        end
        [missed, matched]
      end

      it 'names every key of every catalog that matches a sample or stream line, the gated coin-comma keys included' do
        matching = Array.new(corpus.size) { [] }
        every_key.each { |key| corpus_matches[key].each { |at| matching[at] << key } }
        missed, matched = missed_keys(corpus, matching.method(:[]))
        coin_lines = matching.count { |keys| keys.any? { |key| key.source.end_with?('.*(Kronar|Dokora|Lirum))') } }
        expect(every_key.size).to be > 1_500
        expect(matched).to be > 2_000
        expect(coin_lines).to be > 10
        expect(missed).to be_empty, lambda {
          "#{missed.size} key(s) left out of a corpus line they match:\n#{missed.first(10).map { |entry| "  #{entry.inspect}" }.join("\n")}"
        }
      end

      # Each mutation moves token edges or line ends the index reads: a letter
      # glued to the first or last token, markup around the sample, every
      # letter's case flipped, and a \r\n line end.
      it 'names every key of every catalog that matches a mutated sample' do
        mutated = samples.flat_map do |sample|
          ["x#{sample}", "#{sample}x", "<pushBold/>#{sample}<popBold/>", sample.swapcase, "#{sample}\r\n"].map(&:b)
        end.uniq
        missed, matched = missed_keys(mutated, ->(at) { every_key.select { |key| key.match?(mutated[at]) } })
        expect(matched).to be > 5_000
        expect(missed).to be_empty, lambda {
          "#{missed.size} key(s) left out of a mutated sample they match:\n#{missed.first(10).map { |entry| "  #{entry.inspect}" }.join("\n")}"
        }
      end
    end

    it 'keeps the \r\n ending on every stream line the Empath catalog rewrites' do
      build_catalog('Empath', every_flag_on)
      rewritten = stream_without_big_line.filter_map do |line|
        output = run_hooks(line)
        output unless output == line
      end
      expect(rewritten).not_to be_empty
      expect(rewritten).to all(end_with("\r\n"))
    end
  end
end
