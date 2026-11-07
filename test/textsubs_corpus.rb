# frozen_string_literal: true

require 'json'
require 'regexp_parser'

# Builds the two synthetic inputs spec/textsubs_spec.rb holds the textsubs hook
# to, so both fixtures can be regenerated and audited:
# - spec/fixtures/textsubs/samples.jsonl: lines expanded from the catalog's own
#   regex sources, then composite lines that join two of them, then the
#   hand-added lines (see {.samples_lines});
# - spec/fixtures/textsubs/synthetic_stream.xml: a hand-written XML stream plus
#   one generated 49 KB digit-heavy inventoryManager line (see {.stream}).
#
# Everything here is invented or taken from catalog regex sources already in
# the repo: no player names, ids or rooms from real logs.
#
# Regenerate both with
#   TEXTSUBS_CORPUS_WRITE=1 bundle exec rspec spec/textsubs_spec.rb
module TextsubsCorpus
  # Turns a regex source into one concrete string the regex is meant to match.
  # Each choice the source leaves open is fixed by the strategy given to new:
  # which alternative of an alternation, how many repetitions of a quantified
  # node, and whether a positive lookahead's content is written out.
  class Expander
    # One character per character type (\d, \w, \s, ...).
    TYPE_CHARACTERS = { digit: '5', nondigit: 'x', word: 'w', nonword: ' ', space: ' ', nonspace: 'x', hex: 'a',
                        nonhex: 'z' }.freeze
    # Characters tried, in order, for a bracket expression ([...]).
    SET_CANDIDATES = ['x', 'a', '5', 'w', 'e', 's', ' ', ',', '.', 'A', 'Z'].freeze

    # @param alternative [Integer] index of the alternative taken in every
    #   alternation (modulo its size)
    # @param repetition [Symbol] :min for each quantifier's minimum, :one for at
    #   least one repetition
    # @param lookahead [Symbol] :drop writes nothing for a positive lookahead,
    #   :inline writes out its content
    def initialize(alternative:, repetition:, lookahead:)
      @alternative = alternative
      @repetition = repetition
      @lookahead = lookahead
      @groups = {}
    end

    # @param tree [Regexp::Expression::Root] a regex source parsed by
    #   Regexp::Parser.parse
    # @return [String] the expansion of the regex under this strategy
    # @raise [RuntimeError] for a construct the expander cannot write out (a
    #   backreference to a group it has not written, an unknown node type)
    def expand(tree)
      @groups = {}
      repeated(tree)
    end

    private

    # @param node [Regexp::Expression::Base]
    # @return [String] the node written out as often as its quantifier asks
    def repeated(node)
      once = +''
      repetitions(node).times { once << expand_once(node) }
      once
    end

    # @param node [Regexp::Expression::Base]
    # @return [Integer]
    def repetitions(node)
      quantifier = node.quantifier
      return 1 unless quantifier

      @repetition == :one ? [quantifier.min, 1].max : quantifier.min
    end

    # @param node [Regexp::Expression::Base]
    # @return [String] one repetition of the node
    def expand_once(node)
      case node.type
      when :expression then children(node)
      when :group then group(node)
      when :meta then meta(node)
      when :literal then node.text
      when :type then TYPE_CHARACTERS.fetch(node.token) { raise "type #{node.token}" }
      when :escape then node.respond_to?(:char) ? node.char : node.text[1..]
      when :anchor, :free_space then ''
      when :assertion then @lookahead == :inline && node.token == :lookahead ? children(node) : ''
      when :set then set_character(node)
      when :backref then @groups.fetch(node.number) { raise 'backref' }
      else raise "type #{node.type}/#{node.token}"
      end
    end

    # @param node [Regexp::Expression::Subexpression]
    # @return [String] its children written out in order
    def children(node)
      node.expressions.map { |child| repeated(child) }.join
    end

    # Writes a group out and remembers the text of a numbered (capturing)
    # group for the backreferences after it.
    #
    # @param node [Regexp::Expression::Group::Base]
    # @return [String]
    def group(node)
      text = children(node)
      @groups[node.number] = text if node.respond_to?(:number) && node.number
      text
    end

    # @param node [Regexp::Expression::Base] an alternation or a dot
    # @return [String]
    def meta(node)
      case node.token
      when :alternation
        alternatives = node.alternatives
        repeated(alternatives[@alternative % alternatives.size])
      when :dot then '.'
      else raise "meta #{node.token}"
      end
    end

    # @param node [Regexp::Expression::CharacterSet]
    # @return [String] the first candidate character the set matches
    def set_character(node)
      set = Regexp.new(node.to_s)
      SET_CANDIDATES.find { |character| set.match?(character) } or raise 'set'
    end
  end

  # [repetition, lookahead] strategies, tried in order for each alternative.
  SHAPES = [%i[min drop], %i[min inline], %i[one drop], %i[one inline]].freeze

  # Samples kept per catalog entry.
  SAMPLES_PER_ENTRY = 2

  # Each composite part below is a pattern, and the part is the first expanded
  # sample the pattern matches, so a catalog change that rewords the sample
  # (the tier-18 hit gaining its parentheses, jadice splitting into flower and
  # pollen) changes the composite line instead of breaking the generator.

  # Composite lines put a line-start family first: scroll labels
  # ('^(It is labeled)') and spell recognition ('^(You recognize|You decipher)')
  # only match at the start of a line.
  COMPOSITE_LEADS = [
    [/\AIt is labeled "Absolution\b/, /\AIt is labeled "Aether Cloak\b/],
    [/\AYou decipher .*\bIgnite spell\b/, /\AYou recognize .*\bIgnite spell\b/]
  ].freeze

  # Key families joined pairwise, in the order they sit on a composite line;
  # coin amounts go last. Five digits because plat grouping adds no comma to a
  # four-digit amount.
  COMPOSITE_FAMILIES = [
    [/\AEncumbrance : Burdened\b/],
    [/\Aa light hit\z/, /\Aa devastating hit\z/],
    [/\Ajadice\b/, /\Ayelith\b/],
    [/\A\.+ +Damaris' Lullaby\.\.\(\)\z/, /\A\.+ +Awaken\.\.\(\)\z/],
    [/\Aclass on basic/],
    [/\A5{5}Kronar\z/, /\A5{5}Dokora\z/, /\A5+ platinumKronar\z/]
  ].freeze

  # Joins whose output depends on the key order: a spell link after a coin
  # amount (the link's '>' turns the coin rule's (?!.*>) off when the link
  # runs first), and the two "a devastating hit" keys (tier 18, then tier 17).
  ORDER_SENSITIVE_JOINS = [
    [/\A5{5}Kronar\z/, /\A\.+ +Awaken\.\.\(\)\z/],
    [/\A5{5}Dokora\z/, /\A\.+ +Damaris' Lullaby\.\.\(\)\z/],
    [/\A5+ platinumKronar\z/, /\A\.+ +Awaken\.\.\(\)\z/],
    [/\Aa devastating hit\b.*\bmark\b/, /\Aa devastating hit\z/]
  ].freeze

  # For every distinct catalog entry, up to SAMPLES_PER_ENTRY expansions its
  # own regex matches, one per alternative (0 to 3) for which some shape
  # works, the first shape that works winning. Duplicates across entries are
  # kept once, at their first appearance.
  #
  # @param entries [Array<Array(String, Integer, String)>] catalog_entries.jsonl
  #   rows: [source, options, replacement]
  # @return [Array<String>] single-line samples, in entry order
  def self.expanded_samples(entries)
    entries.flat_map { |source, options, _replacement| entry_samples(source, options) }.uniq
  end

  # @param source [String] a catalog regex source
  # @param options [Integer] its Regexp options
  # @return [Array<String>] up to SAMPLES_PER_ENTRY distinct one-line strings
  #   the entry's regex matches; none when regexp_parser cannot read the source
  #   (the key coverage examples then name the key, for a hand-added line)
  def self.entry_samples(source, options)
    regex = Regexp.new(source, options)
    tree = begin
      Regexp::Parser.parse(source)
    rescue StandardError
      return []
    end
    found = []
    (0..3).each do |alternative|
      sample = SHAPES.lazy.filter_map do |repetition, lookahead|
        expanded = expansion(tree, alternative, repetition, lookahead)
        expanded if expanded && !expanded.include?("\n") && regex.match?(expanded)
      end.first
      found << sample if sample && !found.include?(sample)
      break if found.size >= SAMPLES_PER_ENTRY
    end
    found
  end

  # @param tree [Regexp::Expression::Root] the parsed regex source
  # @param alternative [Integer] see Expander#initialize
  # @param repetition [Symbol] see Expander#initialize
  # @param lookahead [Symbol] see Expander#initialize
  # @return [String, nil] the expansion, or nil when the expander cannot
  #   write the source out under this strategy
  def self.expansion(tree, alternative, repetition, lookahead)
    Expander.new(alternative: alternative, repetition: repetition, lookahead: lookahead).expand(tree)
  rescue StandardError
    nil
  end

  # Lines that two or more keys match: each lead with each family, each
  # family with every later family (alternatives zipped, the shorter list
  # cycled), then ORDER_SENSITIVE_JOINS. Every part is the first expanded
  # sample its pattern matches.
  #
  # @param samples [Array<String>] the expanded samples
  # @return [Array<String>] distinct composite lines, none of them in `samples`
  # @raise [ArgumentError] naming the constant and the pattern, when a pattern
  #   matches no sample (a catalog change removed what it picked: widen the
  #   pattern to match a sample of the new wording)
  def self.composite_samples(samples)
    leads = COMPOSITE_LEADS.map { |family| family.map { |pattern| composite_part(samples, pattern, 'COMPOSITE_LEADS') } }
    families = COMPOSITE_FAMILIES.map { |family| family.map { |pattern| composite_part(samples, pattern, 'COMPOSITE_FAMILIES') } }
    pairs = leads.product(families) + families.combination(2).to_a
    joined = pairs.flat_map { |first, second| first.zip(second.cycle).map { |a, b| "#{a} #{b}" } }
    order_sensitive = ORDER_SENSITIVE_JOINS.map do |join|
      join.map { |pattern| composite_part(samples, pattern, 'ORDER_SENSITIVE_JOINS') }.join(' ')
    end
    (joined + order_sensitive).uniq - samples
  end

  # @param samples [Array<String>] the expanded samples
  # @param pattern [Regexp] a pattern from `constant`
  # @param constant [String] the constant `pattern` sits in, for the error
  # @return [String] the first of `samples` that `pattern` matches
  # @raise [ArgumentError] when `pattern` matches none of them
  def self.composite_part(samples, pattern, constant)
    samples.find { |sample| pattern.match?(sample) } or
      raise ArgumentError, "#{constant} pattern #{pattern.inspect} matches no expanded sample; " \
                           'widen it in test/textsubs_corpus.rb to match a sample of the new wording'
  end

  # @param entries [Array<Array(String, Integer, String)>] catalog_entries.jsonl rows
  # @return [Array<String>] the expanded samples, then the composite lines
  def self.generated_samples(entries)
    expanded = expanded_samples(entries)
    (expanded + composite_samples(expanded)).uniq
  end

  # The lines of samples.jsonl: the generated samples, then every line of the
  # current file the generator does not make, in file order. Lines are added
  # by hand at the end of the file; regenerating never drops them, and a
  # generated line a catalog change no longer makes is kept there too, for a
  # person to delete or keep.
  #
  # @param generated [Array<String>] from generated_samples
  # @param current [Array<String>] the samples in the file now
  # @return [Array<String>]
  def self.samples_lines(generated, current)
    generated + hand_added(generated, current)
  end

  # @param generated [Array<String>] from generated_samples
  # @param current [Array<String>] the samples in the file now
  # @return [Array<String>] the lines of `current` the generator does not make
  def self.hand_added(generated, current)
    current - generated
  end

  # @param lines [Array<String>]
  # @return [String] samples.jsonl content: one JSON string per line
  def self.samples_jsonl(lines)
    lines.map { |line| "#{JSON.generate(line)}\n" }.join
  end

  # @param jsonl [String] samples.jsonl content
  # @return [Array<String>] the samples it holds
  def self.parse_samples(jsonl)
    jsonl.lines.map { |line| JSON.parse(line) }
  end

  # The hand-written part of the stream: an inv pushStream dump, room objs
  # with exist ids, prompts, roundTime, coin and wealth lines.
  STREAM_LINES = <<~'XML'.lines.map(&:chomp).freeze
    <mode id="GAME"/><settingsInfo  client="1.0.1.28" major="2304" crc='0' instance='DR'/>
    <streamWindow id='main' title='Story' subtitle=" - [Synthetic Outpost, Supply Room] (90001)" location='center' target='drop'/>
    <nav rm='90001'/>
    <streamWindow id='room' title='Room' subtitle=" - [Synthetic Outpost, Supply Room] (90001)" location='center' target='drop' ifClosed='' resident='true'/>
    <component id='room desc'>Shelves of plain crates line the walls, each stamped with a number from 1 to 1000000.</component>
    <component id='room objs'>You also see a <a exist="-12345" noun="crate">plain crate</a>, <pushBold/>a <a exist="41000017" noun="rat">giant rat</a><popBold/>, <pushBold/>a <a exist="41000024" noun="rat">giant rat</a><popBold/> and a <a exist="98765" noun="sign">large sign</a>.</component>
    <component id='room players'>Also here: Quimbly Synthwright.</component>
    <component id='room exits'>Obvious exits: <d>north</d>, <d>south</d>.<compass></compass></component>
    <compass><dir value="n"/><dir value="s"/></compass>
    <prompt time="1800000001">&gt;</prompt>
    <right>Empty</right><left exist="41100001" noun="pelt">a rat pelt</left><clearStream id='inv' ifClosed=''/><pushStream id='inv'/>Your worn items are:
      a leather backpack
      a coin purse holding 1234567 Kronars
      some 1000000-thread silk gloves
    <popStream/><prompt time="1800000002">&gt;</prompt>
    <dialogData id='minivitals'><progressBar id='concentration' value='100' text='concentration 100%' left='75%' customText='t' top='0%' width='25%' height='100%'/></dialogData>
    <roundTime value='1800000005'/><component id='exp Scholarship'><preset id='whisper'>     Scholarship: 1234 42% learning      0.51     </preset></component>
    Roundtime: 3 sec.
    <prompt time="1800000003">R&gt;</prompt>
    You pick up 2 copper Lirums.
    You pick up 5 bronze Dokoras.
    You pick up 1234 copper Kronars.
    Wealth:
      6768 platinum, 9 gold, 7 silver, and 3 copper Kronars (67689703 copper Kronars).
      12 platinum, 0 gold, 0 silver, and 5 copper Lirums (1200005 copper Lirums).
      No Dokoras.
    The attendant says, "You can purchase 100 yards of wool yarn for 625 Kronars.  Just order it again!"
    The clerk says, "That will be 1234567 Kronars, or 12345 platinum Kronars if you prefer."
    <pushBold/>The ledger reads 9876543210 entries, not counting the 1000000 crates.<popBold/>
    Assessing the sword durability, you determine it is extremely weak and easily damaged.
    Assessing the leather gloves durability, you determine they are of average construction.
    You feel like you have made some progress toward your goal.
    You feel as if many eyes are judging you and still find you... lacking.
    You feel worn but still ready to meet a challenge.
    You bring the song to a close, bowing your head.
    <output class="mono"/>
    You recall the spells you have learned from your training.
    <output class=""/>
    <prompt time="1800000004">&gt;</prompt>
  XML

  # An inventoryManager line of at least 49,000 bytes, heavy in digits and
  # holding no currency word, so the coin regexes scan all of it and match
  # nothing.
  #
  # @return [String]
  # @raise [RuntimeError] if it holds Kronar, Dokora or Lirum
  def self.big_line
    line = +%(<inventoryManager id='imsynthetic0001' room='90001'>)
    (1..).each do |n|
      break if line.bytesize >= 49_000

      line << %(<i id='#{42_000_000 + (n * 37)}' loc='in,#{42_000_000 + ((n / 20) * 37)}' name="a #{n}-count,crate" weight='#{n % 50}' in_max='#{1000 + n}'/>)
    end
    line << '</inventoryManager>'
    raise 'currency word in the big line' if line.match?(/Kronar|Dokora|Lirum/)

    line
  end

  # @return [String] synthetic_stream.xml content (binary): STREAM_LINES with
  #   big_line just before the roundTime line, every line ending in \r\n
  def self.stream
    lines = STREAM_LINES.dup
    lines.insert(lines.index { |line| line.start_with?('<roundTime') }, big_line)
    lines.map { |line| "#{line}\r\n" }.join.b
  end
end
