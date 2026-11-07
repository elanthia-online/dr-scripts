require 'fileutils'
require 'json'
require 'tmpdir'

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
#     every guild catalog is matched by at least one sample. It ends with
#     composite lines, each two of those samples joined by a space, that two or
#     more keys of every guild catalog match; in a few of them the order the
#     keys run in changes the output (a coin amount before a spell link, whose
#     '>' turns the coin rule off; the two "a devastating hit" keys), so the
#     per-guild sweeps also pin the order of real keys, not just each key;
#   - synthetic_stream.xml is a hand-written XML stream (inv pushStream dump,
#     room objs with exist ids, prompts, roundTime, coin and wealth lines and a
#     49 KB digit-heavy inventoryManager line), every line ending in \r\n.
# The samples are inputs, not output: they are not regenerated when the catalog
# changes. A new or rewritten pattern adds a line to samples.jsonl.
#
# What the real catalogs cannot pin: on no corpus line does a key create a
# match for a key that runs after it (the only two such pairs a search of every
# key's output on its own samples found run the other way round), so an engine
# that checks each key against the changing line instead of the original gives
# the same output on every corpus line. The hand-made catalogs in 'hook engine
# semantics' pin that rule.
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
  # @param line [String] a binary server line
  # @return [String, nil] what the hooks pass on to the client
  # @raise [RuntimeError] when the hooks neither returned nor raised
  # @example
  #   run_hooks("You feel fine.\r\n".b) # => "You feel FINE.\r\n"
  def run_hooks(line)
    returned = false
    output = DownstreamHook.run(line)
    returned = true
    output
  ensure
    # $! is the exception in flight when the hook raised: let that one through.
    unless returned || $!
      raise "a DownstreamHook left without returning (a `return` in the hook proc where `next` belongs?); " \
            'unchecked, that would end the whole rspec run with status 0'
    end
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
        @golden_entries = File.readlines(entries_path).map { |line| JSON.parse(line) }
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
          actual = build_combination(combination)
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

    it 'herb_textsubs inserts one block of "<herb> (<area>)" annotations and removes nothing' do
      run = toggle('Trader', 'herb_textsubs', others: false)
      expect(run[:removed]).to eq([])
      expect(run[:added]).not_to be_empty
      expect(run[:added]).to all(satisfy { |source, _options, replacement| replacement.start_with?("#{source} (") })
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

  describe 'hook engine semantics' do
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

  describe 'reference-engine oracle' do
    samples = File.readlines(samples_path, chomp: true).map { |line| JSON.parse(line).b }
    stream = File.binread(stream_path).lines
    big_line = stream.max_by(&:bytesize)
    # The 49 KB line spends ~0.5 s in the coin regex per pass, so the per-guild
    # sweeps leave it to the one whole-stream example below.
    stream_without_big_line = stream - [big_line]
    every_flag_on = { 'textsubs_spell_links' => true, 'herb_textsubs' => true }.freeze

    # Sends each line through the registered hooks and through reference_apply
    # with the current TextSubs.subs.
    #
    # @param lines [Array<String>] binary server lines
    # @return [Array<Array(String, String, String)>] [line, hook output,
    #   reference output] for each line where the two differ
    def oracle_mismatches(lines)
      subs = TextSubs.subs
      lines.filter_map do |line|
        hooked = run_hooks(line)
        expected = reference_apply(subs, line)
        [line, hooked, expected] unless hooked == expected
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
        mismatches = oracle_mismatches(samples + stream_without_big_line)
        expect(mismatches).to be_empty, -> { mismatch_report(guild, mismatches) }
      end

      it "matches every key of the #{guild} catalog with at least one sample" do
        build_catalog(guild, every_flag_on)
        unmatched = TextSubs.subs.keys.reject { |key| samples.any? { |sample| key.match?(sample) } }
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
        build_catalog(guild, every_flag_on)
        subs = TextSubs.subs
        reversed = subs.to_a.reverse.to_h
        shared = samples.select { |sample| subs.keys.count { |key| key.match?(sample) } >= 2 }
        order_sensitive = shared.reject { |line| reference_apply(reversed, line) == reference_apply(subs, line) }
        expect(shared.size).to be >= 50, "only #{shared.size} sample(s) are matched by two or more #{guild} keys"
        expect(order_sensitive.size).to be >= 4,
                                        "only #{order_sensitive.size} sample(s) give another output with the #{guild} keys reversed"
      end
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
      mismatches = oracle_mismatches(samples + stream_without_big_line)
      expect(mismatches).to be_empty, -> { mismatch_report('Trader (plat grouping on)', mismatches) }
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
