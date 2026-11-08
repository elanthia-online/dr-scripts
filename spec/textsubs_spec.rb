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
      expect(DownstreamHook.run("You feel fine today.\n")).to eq("You feel FINE today.\n")
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
end
