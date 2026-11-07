require 'fileutils'
require 'json'
require 'tmpdir'
require_relative '../test/textsubs_corpus'

# textsubs.lic builds its whole substitution catalog at top level: the entry
# point registers the 'textsub' DownstreamHook, adds the shit-list and
# private_textsubs entries, then runs ~1,600 TextSubs.add / TextSubs.elanthipedia
# calls gated by the guild and three settings. These specs pin that catalog so a
# refactor of the script has to reproduce every entry, in order, for every
# combination a player can run.
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
# the golden set; it is covered on its own when the guild handling is fixed.
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
#     '>' turns the coin rule off; a scroll label before a link to the same
#     spell, which the link rule then finds inside the label), so the
#     per-guild sweeps also pin the order of real keys, not just each key. The
#     lines of samples_hand_added.jsonl come last;
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

  # Runs the real textsubs.lic entry point for one combination and returns the
  # catalog it built.
  #
  # TextSubs.clear stands in for Lich re-evaluating the class body (and with it
  # `@@subs = {}`) on every start: load_lic_class evaluates the class only once
  # per process, so without it each run would add onto the previous catalog.
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
    TextSubs.clear
    run_lic_entry('textsubs.lic', 'TextSubs')
    TextSubs.subs.map { |pattern, replacement| [pattern.source, pattern.options, replacement] }
  end

  # The textsubs settings as profiles/base.yaml ships them, except
  # private_textsubs: {} instead of nil because the harness has no nilclass
  # patch. textsubs_spell_links stays nil, as base.yaml leaves it unset.
  #
  # @return [Hash{String=>Object}] frozen default for every key textsubs.lic reads
  def textsubs_defaults
    { 'private_textsubs' => {}, 'integrate_shit_list_with_textsubs' => false, 'textsubs_spell_links' => nil,
      'herb_textsubs' => false, 'textsubs_use_plat_grouping' => false }.freeze
  end

  # @param combination [Hash{String=>Object}] one element of `combinations`
  # @return [Array<Array(String, Integer, String)>] that combination's catalog
  def build_combination(combination)
    build_catalog(combination['guild'], combination.except('guild'))
  end

  # Each combination's traced build (see traced_build), made once per run by
  # whichever example asks first. The examples that only read a catalog, or
  # the calls that made it, share these builds, so the 96 catalogs are not
  # rebuilt once per such example. The examples that need TextSubs.subs to
  # hold the catalog call build_combination instead.
  built_catalogs = {}

  # The stubs active in this example that could change what build_catalog
  # builds: any stub on DRStats (the guild predicates), File (run_lic_entry
  # reads the script through it, and the shit-list branch reads a file), or the
  # top-level object (get_settings), and any stub on TextSubs except
  # client_attached?, which the script reads only inside the hook.
  #
  # @return [Array<String>] one label per stubbed object or TextSubs method;
  #   empty when nothing that catalog building reads is stubbed
  def stubs_on_catalog_reads
    space = RSpec::Mocks.space
    stubbed = { 'DRStats' => DRStats, 'File' => File, 'the top-level object' => TOPLEVEL_BINDING.receiver }
              .select { |_label, input| space.registered?(input) }.keys
    return stubbed unless space.registered?(TextSubs)

    proxy = space.proxy_for(TextSubs)
    stubbed + (TextSubs.singleton_methods - [:client_attached?])
              .select { |name| proxy.method_double_if_exists_for_message(name) }
              .map { |name| "TextSubs.#{name}" }
  end

  # build_combination, recording the calls that wrote the catalog: the source
  # passed to each TextSubs.add, and how many times TextSubs.elanthipedia ran
  # (it writes its key itself). TracePoints record them, which leaves both
  # methods as they are; rspec-mocks wrappers on the ~100,000 calls of the 96
  # builds doubled the time of the builds. The add source is read by its
  # position, so renaming TextSubs.add's parameter does not break the trace;
  # its name is looked up once per build, not once per call.
  #
  # @param combination [Hash{String=>Object}] one element of `combinations`
  # @return [Hash{Symbol=>Object}] deep-frozen, because every caller shares it.
  #   Every string in it is a frozen copy (see frozen_copy), so the record
  #   never shares a mutable string with TextSubs.subs or with the caller of
  #   TextSubs.add. :catalog, as build_combination returns it;
  #   :add_sources [Array<String>], the first argument of each TextSubs.add
  #   call, in call order; :link_calls [Integer], the number of
  #   TextSubs.elanthipedia calls
  def traced_build(combination)
    sources = []
    links = 0
    source_param = TextSubs.method(:add).parameters.first.last
    adds = TracePoint.new(:call) { |trace| sources << frozen_copy(trace.binding.local_variable_get(source_param).to_s) }
    link_calls = TracePoint.new(:call) { links += 1 }
    catalog = adds.enable(target: TextSubs.method(:add)) do
      link_calls.enable(target: TextSubs.method(:elanthipedia)) { build_combination(combination) }
    end
    { catalog: catalog.map { |entry| entry.map { |value| frozen_copy(value) }.freeze }.freeze,
      add_sources: sources.freeze, link_calls: links }.freeze
  end

  # A frozen value that shares no mutable object with the one given: a frozen
  # value as it is, anything else a frozen copy. Freezing the given object
  # itself would freeze a string the script still holds (String#to_s returns
  # the receiver), and a later `<<` on it would raise FrozenError in whichever
  # example built that combination first.
  #
  # @param value [Object] a catalog value (String or Integer) or an add source
  # @return [Object] `value` when frozen, else a frozen dup of it
  def frozen_copy(value)
    value.frozen? ? value : value.dup.freeze
  end

  # Memoized traced_build, for examples that only read the returned catalog or
  # calls. Whether TextSubs.subs holds that catalog afterwards depends on
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

  after do
    DownstreamHook.remove('textsub')
    TextSubs.clear
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

    it 'treats an unset flag (nil, as base.yaml leaves textsubs_spell_links) like false' do
      expect(build_catalog('Cleric', 'herb_textsubs' => false, 'textsubs_use_plat_grouping' => false))
        .to eq(build_catalog('Cleric', 'textsubs_spell_links' => false, 'herb_textsubs' => false,
                                       'textsubs_use_plat_grouping' => false))
    end

    it 'links the guild spell list to the guild category only with textsubs_spell_links on' do
      sources = build_catalog('Moon Mage', 'textsubs_spell_links' => true).map(&:last)
      expect(sources).to include(a_string_including('Category:Moon_Mage_spells">Moon Mage</a> training.'))
      expect(build_catalog('Moon Mage', 'textsubs_spell_links' => false).map(&:last))
        .not_to include(a_string_including('Category:Moon_Mage_spells'))
    end
  end

  describe 'shit list' do
    # Runs the entry inside a temporary directory holding
    # "<checkname>_shit.list" with the given content (or no file when nil).
    #
    # @param content [String, nil] the shit-list file body
    # @param integrate [Boolean] integrate_shit_list_with_textsubs
    # @return [Array<Array>] the catalog built
    def catalog_with_shit_list(content, integrate:)
      Dir.mktmpdir('textsubs-shit-list') do |dir|
        File.write(File.join(dir, "#{checkname}_shit.list"), content) if content
        Dir.chdir(dir) { build_catalog('Commoner', 'integrate_shit_list_with_textsubs' => integrate) }
      end
    end

    let(:plain_catalog) { build_catalog('Commoner') }

    it 'adds a capitalized "(SL)" entry per name, ahead of the built-in catalog' do
      catalog = catalog_with_shit_list("zorvex,stole my kill\nqUIMBLE,spammer\n", integrate: true)
      expect(catalog.first(2)).to eq([['Zorvex', 0, 'Zorvex (SL)'], ['Quimble', 0, 'Quimble (SL)']])
      expect(catalog.drop(2)).to eq(plain_catalog)
    end

    it 'adds nothing when integrate_shit_list_with_textsubs is off, even with a file present' do
      expect(catalog_with_shit_list("zorvex,stole my kill\n", integrate: false)).to eq(plain_catalog)
    end

    it 'adds nothing, and does not fail, when the flag is on but the file is missing' do
      expect(catalog_with_shit_list(nil, integrate: true)).to eq(plain_catalog)
    end
  end

  describe 'private_textsubs' do
    it 'adds each private pair, in order, ahead of the built-in catalog' do
      private_subs = { 'You feel fine' => 'You feel FINE', 'a (\w+) widget' => 'a \1 gadget' }
      catalog = build_catalog('Commoner', 'private_textsubs' => private_subs)
      expect(catalog.first(2)).to eq([['You feel fine', 0, 'You feel FINE'], ['a (\w+) widget', 0, 'a \1 gadget']])
      expect(catalog.drop(2)).to eq(build_catalog('Commoner'))
    end

    it 'puts shit-list entries before private ones' do
      Dir.mktmpdir('textsubs-shit-list') do |dir|
        File.write(File.join(dir, "#{checkname}_shit.list"), "zorvex,reason\n")
        settings = { 'integrate_shit_list_with_textsubs' => true, 'private_textsubs' => { 'You feel fine' => 'You feel FINE' } }
        catalog = Dir.chdir(dir) { build_catalog('Commoner', settings) }
        expect(catalog.first(2)).to eq([['Zorvex', 0, 'Zorvex (SL)'], ['You feel fine', 0, 'You feel FINE']])
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

    it "removes 'textsub', and only 'textsub', in before_dying" do
      teardown = nil
      # Stubbed on main (where run_lic_entry evaluates the entry), not on
      # Script.at_exit: another spec replaces the top-level before_dying.
      allow(TOPLEVEL_BINDING.receiver).to receive(:before_dying) { |&block| teardown = block }
      DownstreamHook.add('other-script', proc { |line| line })
      build_catalog('Commoner')
      expect(teardown).to be_a(Proc)

      teardown.call
      expect(DownstreamHook.list).not_to include('textsub')
      expect(DownstreamHook.list).to include('other-script')
    ensure
      DownstreamHook.remove('other-script')
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
        require 'prism'
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
        build_combination(combination).filter_map do |source, _options, replacement|
          [combination['guild'], source, replacement] if replacement.gsub(link, '').include?('<')
        end
      end
      expect(offenders.uniq).to be_empty, lambda {
        "values that add a bare '<' ([guild, key, value]):\n#{offenders.uniq.map { |entry| "  #{entry.inspect}" }.join("\n")}"
      }
    end

    # TextSubs.add stores /#{target}/ as the Hash key, so a second add of the
    # same source keeps the first slot with the last value and the first
    # value is lost without a word ('jadice' was added as limb-ES and then
    # as limb-EW). TextSubs.elanthipedia writes its own keys, so every call
    # to either method has to leave one more key behind.
    #
    # catalog_build_of records both methods' calls in the one build the
    # catalog examples share, so this example does not build the 96 catalogs
    # a second time.
    it 'adds every key source once in every combination' do
      offenders = combinations.filter_map do |combination|
        build = catalog_build_of(combination)
        sources = build[:add_sources]
        calls = sources.size + build[:link_calls]
        size = build[:catalog].size
        repeated = sources.tally.select { |_, count| count > 1 }.keys
        [combination, repeated, calls, size] unless repeated.empty? && calls == size
      end
      expect(offenders).to be_empty, lambda {
        "#{offenders.size} combination(s) add a key twice ([combination, repeated sources, calls, keys]):\n" \
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
  end

  describe 'reference-engine oracle' do
    include_context 'with a front end attached'

    samples = TextsubsCorpus.parse_samples(File.read(samples_path)).map(&:b)
    stream = File.binread(stream_path).lines
    big_line = stream.max_by(&:bytesize)
    # The 49 KB line spends ~0.5 s in the coin regex per pass, so the per-guild
    # sweeps leave it to the one whole-stream example below.
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
    entries = read_entries.call
    # Every key of every catalog a player can run: the golden fixture's
    # entries, which the golden examples hold to what the script builds.
    every_key = entries.map { |source, options, _replacement| Regexp.new(source, options) }.uniq
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
      # The 49 KB line is left out: through the two platinum-aware coin rules it
      # costs ~3.5 s, and the coin rules see it in the default-rule example above.
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
