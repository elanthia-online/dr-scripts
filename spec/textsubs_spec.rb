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
  # @param guild [String] what DRStats.guild reports
  # @param settings [Hash{String=>Object}] settings keys for get_settings;
  #   private_textsubs defaults to {} because the harness has no nilclass patch
  # @return [Array<Array(String, Integer, String)>] [source, options, replacement]
  #   for each entry of TextSubs.subs, in insertion order
  def build_catalog(guild, settings = {})
    DRStats.guild = guild
    { 'private_textsubs' => {} }.merge(settings).each { |key, value| $test_settings[key] = value }
    TextSubs.clear
    run_lic_entry('textsubs.lic', 'TextSubs')
    TextSubs.subs.map { |pattern, replacement| [pattern.source, pattern.options, replacement] }
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
end
