# frozen_string_literal: true

require 'json'
require 'open3'
require 'prism'

# Reads the textsubs.lic that the catalog in data/base-textsubs.yaml was moved
# out of (main at PARENT_COMMIT), and lists every TextSubs.add or
# TextSubs.elanthipedia call that has an argument written in double quotes
# whose backslash escapes Ruby took out or changed: "spell\." gave
# 'spell.', so the full stop matched any character, and "\1" gave byte 0x01
# instead of a backreference. For each such call it records what the
# author wrote, read as single-quoted text, which is what the catalog has to
# hold. spec/textsubs_spec.rb holds data/base-textsubs.yaml to that list.
#
# The list is spec/fixtures/textsubs/parent_double_quoted.jsonl, and the spec
# holds it to what rows reads from PARENT_COMMIT (in a clone that has it).
# Nothing changes it unless this reader changes; rewrite it from such a
# clone with
#   bundle exec ruby -r ./test/textsubs_parent_quotes -e TextsubsParentQuotes.write
module TextsubsParentQuotes
  # main just before the catalog left textsubs.lic.
  PARENT_COMMIT = '6fe70b3f46fdf46cacac9b91792176f2be040d62'

  # The calls whose arguments are catalog text.
  CATALOG_CALLS = %i[add elanthipedia].freeze

  # Reads one call's argument the way the author meant it: as single-quoted
  # text, in which every backslash stays where it is written but '\\'
  # (one backslash) and "\'" (a quote). "\"" counts as a quote too, as the
  # author wrote the backslash only to keep it inside the double quotes.
  #
  # @param written [String] the text between the quotes, as written
  # @return [String]
  # @example
  #   TextsubsParentQuotes.single_quoted_reading('spell\. it\'s \"so\"') # => "spell\\. it's \"so\""
  def self.single_quoted_reading(written)
    written.gsub(/\\(.)/m) { %w[\\ ' "].include?(Regexp.last_match(1)) ? Regexp.last_match(1) : Regexp.last_match(0) }
  end

  # What Ruby makes of text written between double quotes.
  #
  # @param text [String] the body of a double-quoted literal
  # @return [String]
  # @raise [ArgumentError] when Ruby cannot read `text` as the body of one
  #   double-quoted literal, such as text that ends in a lone backslash
  # @example
  #   TextsubsParentQuotes.double_quoted('spell\.') # => "spell."
  #   TextsubsParentQuotes.double_quoted('\1')      # => "\u0001"
  def self.double_quoted(text)
    # A '"' or '#' after an even run of backslashes (none included) would end
    # the literal or start an interpolation, so it gets a backslash of its own.
    body = text.gsub(/(?<!\\)((?:\\\\)*)(["#])/) { "#{Regexp.last_match(1)}\\#{Regexp.last_match(2)}" }
    # So only the closing quote can end it, and it parses as one string
    # literal unless Ruby cannot read it (a lone backslash at the end, say).
    result = Prism.parse(%("#{body}"))
    raise ArgumentError, "#{text.inspect} is not the body of one double-quoted literal" unless result.success?

    result.value.statements.body.first.unescaped
  end

  # @param source [String] a textsubs.lic
  # @return [Array<Hash>] one row per catalog call that has an argument
  #   Ruby read differently from its single-quoted reading (in its own text
  #   or in a local variable it interpolates), in source order: 'line',
  #   'method', 'intent' (every argument as its author meant it: a
  #   double-quoted one read as single-quoted text, its interpolated local
  #   variables filled in the same way) and 'dropped' (the indexes of the
  #   arguments Ruby read differently; double_quoted of their intent gives
  #   Ruby's reading)
  # @raise [ArgumentError] when such a call interpolates anything but a
  #   local variable set to a string literal, or has a dropped argument whose
  #   Ruby reading double_quoted cannot rebuild from its intent ("a\\b\."
  #   reads as 'a\b\.', and double_quoted of that gives a backspace)
  def self.rows(source)
    locals = {}
    rows = []
    walk(Prism.parse(source).value) do |node|
      note_local(node, locals) if node.is_a?(Prism::LocalVariableWriteNode)
      next unless catalog_call?(node)

      arguments = node.arguments&.arguments || []
      dropped = arguments.each_index.select { |index| dropped?(arguments[index], locals) }
      next if dropped.empty?

      intent = arguments.map { |argument| reading(argument, locals, :intent) }
      dropped.each { |index| check_rebuilds(arguments[index], intent[index], locals) }
      rows << { 'line' => node.location.start_line, 'method' => node.name.to_s, 'intent' => intent, 'dropped' => dropped }
    end
    rows
  end

  # PARENT_COMMIT's textsubs.lic, which a shallow clone may not have.
  #
  # @return [String]
  # @raise [RuntimeError] when git cannot show it
  def self.parent_source
    source, error, status = Open3.capture3('git', 'show', "#{PARENT_COMMIT}:textsubs.lic", chdir: __dir__)
    raise "git show #{PARENT_COMMIT}:textsubs.lic failed: #{error.strip}" unless status.success?

    source
  end

  # @return [Boolean] true when the clone this file is in is shallow, so
  #   may lack PARENT_COMMIT
  def self.shallow_clone?
    output, _error, status = Open3.capture3('git', 'rev-parse', '--is-shallow-repository', chdir: __dir__)
    status.success? && output.strip == 'true'
  end

  # Writes the rows of PARENT_COMMIT's textsubs.lic to `path`, one JSON
  # object per line.
  #
  # @param path [String]
  # @return [void]
  # @raise [RuntimeError] when git cannot show the parent's textsubs.lic
  def self.write(path = File.expand_path('../spec/fixtures/textsubs/parent_double_quoted.jsonl', __dir__))
    File.write(path, rows(parent_source).map { |row| "#{JSON.generate(row)}\n" }.join)
  end

  # Yields every node under `node`, parents before children, in source order.
  #
  # @param node [Prism::Node]
  # @yieldparam node [Prism::Node]
  # @return [void]
  def self.walk(node, &block)
    yield node
    node.compact_child_nodes.each { |child| walk(child, &block) }
  end
  private_class_method :walk

  # Notes a local variable set to a string literal, both as its author meant
  # it and as Ruby read it, and forgets one set to anything else.
  #
  # @param node [Prism::LocalVariableWriteNode]
  # @param locals [Hash{Symbol => Hash}] the string locals set so far, each
  #   { intent:, ruby:, dropped: }; changed in place
  # @return [void]
  def self.note_local(node, locals)
    literal = node.value
    if literal.is_a?(Prism::StringNode)
      locals[node.name] = { intent: reading(literal, {}, :intent), ruby: literal.unescaped, dropped: dropped?(literal, {}) }
    else
      locals.delete(node.name)
    end
  end
  private_class_method :note_local

  # @param node [Prism::Node]
  # @return [Boolean] true for TextSubs.add(...) or TextSubs.elanthipedia(...)
  def self.catalog_call?(node)
    node.is_a?(Prism::CallNode) && node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :TextSubs &&
      CATALOG_CALLS.include?(node.name)
  end
  private_class_method :catalog_call?

  # @param argument [Prism::Node]
  # @return [Array<Prism::StringNode>] its literal text: the argument itself,
  #   or the literal parts of an interpolated string
  def self.literal_parts(argument)
    case argument
    when Prism::StringNode then [argument]
    when Prism::InterpolatedStringNode then argument.parts.grep(Prism::StringNode)
    else []
    end
  end
  private_class_method :literal_parts

  # @param part [Prism::Node] a part of an interpolated string
  # @return [Symbol, nil] the local variable `part` interpolates, when it
  #   interpolates exactly one local variable and nothing else
  def self.interpolated_name(part)
    statements = part.statements&.body if part.is_a?(Prism::EmbeddedStatementsNode)
    statements.first.name if statements&.size == 1 && statements.first.is_a?(Prism::LocalVariableReadNode)
  end
  private_class_method :interpolated_name

  # @param argument [Prism::Node]
  # @param locals [Hash{Symbol => Hash}] the string locals set so far
  # @return [Boolean] true when the argument is written in double quotes (or
  #   another interpolating form) and Ruby read some part of it, or a local
  #   it interpolates, differently from its single-quoted reading
  def self.dropped?(argument, locals)
    return false unless interpolating?(argument)

    literal_parts(argument).any? { |part| part.unescaped != single_quoted_reading(part.content) } ||
      (argument.is_a?(Prism::InterpolatedStringNode) &&
       argument.parts.any? { |part| locals.dig(interpolated_name(part), :dropped) })
  end
  private_class_method :dropped?

  # @param argument [Prism::Node]
  # @return [Boolean] false for '...', %q(...) and <<~'END' heredocs, which
  #   keep backslashes
  def self.interpolating?(argument)
    opening = argument.respond_to?(:opening) ? argument.opening.to_s : ''
    !opening.match?(/\A(?:'|%q|<<[-~]?')/)
  end
  private_class_method :interpolating?

  # @param argument [Prism::Node] a string literal or an interpolated string
  # @param locals [Hash{Symbol => Hash}] the string locals set so far
  # @param side [Symbol] :intent for the text as its author meant it (its
  #   single-quoted reading when it interpolates), :ruby for the text as
  #   Ruby read it
  # @return [String]
  # @raise [ArgumentError] for any other argument, or an interpolation of
  #   anything but one of `locals`
  def self.reading(argument, locals, side)
    literal = ->(part) { side == :intent && interpolating?(argument) ? single_quoted_reading(part.content) : part.unescaped }
    case argument
    when Prism::StringNode then literal.call(argument)
    when Prism::InterpolatedStringNode
      argument.parts.map do |part|
        next literal.call(part) if part.is_a?(Prism::StringNode)

        name = interpolated_name(part)
        raise ArgumentError, "cannot read #{part.slice} at line #{part.location.start_line}" unless locals.key?(name)

        locals[name][side]
      end.join
    else raise ArgumentError, "cannot read #{argument.slice} at line #{argument.location.start_line}"
    end
  end
  private_class_method :reading

  # Holds a dropped argument to the promise rows makes for it: double_quoted
  # of its intent is what Ruby read.
  #
  # @param argument [Prism::Node] a dropped argument
  # @param intent [String] its intent
  # @param locals [Hash{Symbol => Hash}] the string locals set so far
  # @return [void]
  # @raise [ArgumentError] when double_quoted of `intent` is not what Ruby read
  def self.check_rebuilds(argument, intent, locals)
    rebuilt = begin
      double_quoted(intent)
    rescue ArgumentError
      nil
    end
    return if rebuilt == reading(argument, locals, :ruby)

    raise ArgumentError, "cannot rebuild Ruby's reading of #{argument.slice} at line #{argument.location.start_line} from #{intent.inspect}"
  end
  private_class_method :check_rebuilds
end
