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

  # The nodes that open a scope of local variables. A local variable node's
  # depth counts the blocks and lambdas between it and the scope that holds
  # the variable; a def, class or module body sees no local from outside.
  SCOPES = [Prism::ProgramNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode, Prism::DefNode,
            Prism::BlockNode, Prism::LambdaNode].freeze

  # The nodes that set a local variable: 'x = ...', 'x += ...', 'x ||= ...',
  # 'x &&= ...', and a target ('x, y = ...', 'rescue => x', 'for x in ...', a
  # named capture or a pattern).
  LOCAL_WRITES = [Prism::LocalVariableWriteNode, Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode,
                  Prism::LocalVariableAndWriteNode, Prism::LocalVariableTargetNode].freeze

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
  # @raise [ArgumentError] when Ruby read a literal anywhere in `source`
  #   differently and it is neither a catalog call's argument (or a literal
  #   part of one) nor a string local (see string_local) that only catalog
  #   calls interpolate, as its text could then reach a catalog call some way
  #   this reader does not follow ('x += "a\."', 'y = x', a constant);
  #   when a catalog call with such an argument interpolates anything but a
  #   string local; when `source` has an interpolating <<~ heredoc, as Ruby
  #   takes its indentation out too, which this reader does not rebuild; or
  #   when double_quoted cannot rebuild a dropped argument's Ruby reading
  #   from its intent ("a\\b\." reads as 'a\b\.', and double_quoted of
  #   that gives a backspace)
  def self.rows(source)
    program = Prism.parse(source).value
    writes = local_writes(program)
    check_drops_followed(program, writes)
    rows = []
    walk(program) do |node, scopes|
      next unless catalog_call?(node)

      arguments = node.arguments&.arguments || []
      locals = string_locals(arguments, scopes, writes)
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

  # Yields every node under `node`, parents before children, in source
  # order, with the scopes it is in.
  #
  # @param node [Prism::Node]
  # @param scopes [Array<Prism::Node>] the SCOPES around `node`, outermost first
  # @yieldparam node [Prism::Node]
  # @yieldparam scopes [Array<Prism::Node>] the SCOPES around it, and itself
  #   when it is one, outermost first
  # @return [void]
  def self.walk(node, scopes = [], &block)
    scopes += [node] if SCOPES.any? { |kind| node.is_a?(kind) }
    yield node, scopes
    node.compact_child_nodes.each { |child| walk(child, scopes, &block) }
  end
  private_class_method :walk

  # @param node [Prism::Node] a local variable read or one of LOCAL_WRITES
  # @param scopes [Array<Prism::Node>] the SCOPES around it, outermost first
  # @return [Array(Integer, Symbol), nil] the variable it names, told apart
  #   from one of the same name in any other scope; nil when its depth leads
  #   to no scope that holds the name
  def self.local_key(node, scopes)
    scope = scopes[-1 - node.depth]
    [scope.object_id, node.name] if scope&.locals&.include?(node.name)
  end
  private_class_method :local_key

  # Every write to a local variable in `program`.
  #
  # @param program [Prism::ProgramNode]
  # @return [Hash{Array => Array<Array(Prism::Node, Prism::StatementsNode)>}]
  #   for each local_key, its writes in source order, each with the body it
  #   is a statement of: nil when it is only part of a statement, as in
  #   'f(x = 1)', 'x = 1 if y' or 'x, y = 1, 2'
  def self.local_writes(program)
    bodies = {}.compare_by_identity
    writes = Hash.new { |hash, key| hash[key] = [] }
    walk(program) do |node, scopes|
      node.body.each { |statement| bodies[statement] = node } if node.is_a?(Prism::StatementsNode)
      writes[local_key(node, scopes)] << [node, bodies[node]] if LOCAL_WRITES.any? { |kind| node.is_a?(kind) }
    end
    writes
  end
  private_class_method :local_writes

  # The string literal a local variable read is sure to give, when it reads
  # a string local: a local variable set once in its scope (counting every
  # kind of LOCAL_WRITES), by a plain 'x = ...' of a string literal that is
  # a statement of a body the read comes later in. Ruby then runs that
  # statement before the read, and nothing sets the variable again, whatever
  # branches, loops or blocks are around them. A def's parameter, or a
  # block's, is set by no write, so is no string local.
  #
  # @param read [Prism::LocalVariableReadNode]
  # @param scopes [Array<Prism::Node>] the SCOPES around it, outermost first
  # @param writes [Hash] local_writes of the program
  # @return [Prism::StringNode, nil] nil when the read is not of a string local
  def self.string_local(read, scopes, writes)
    key = local_key(read, scopes)
    sets = key ? writes.fetch(key, []) : []
    return unless sets.size == 1

    write, body = sets.first
    return unless write.is_a?(Prism::LocalVariableWriteNode) && write.value.is_a?(Prism::StringNode) && body
    return unless read.location.start_offset >= write.location.end_offset && read.location.end_offset <= body.location.end_offset

    write.value
  end
  private_class_method :string_local

  # @param arguments [Array<Prism::Node>] a call's arguments
  # @param scopes [Array<Prism::Node>] the SCOPES around the call, outermost first
  # @param writes [Hash] local_writes of the program
  # @return [Hash{Symbol => Hash}] the string locals (see string_local) the
  #   arguments interpolate, each { intent:, ruby:, dropped: }: its literal
  #   as its author meant it, as Ruby read it, and whether those differ
  def self.string_locals(arguments, scopes, writes)
    interpolated_reads(arguments).each_with_object({}) do |read, locals|
      literal = string_local(read, scopes, writes)
      next unless literal

      locals[read.name] = { intent: reading(literal, {}, :intent), ruby: literal.unescaped, dropped: dropped?(literal, {}) }
    end
  end
  private_class_method :string_locals

  # @param arguments [Array<Prism::Node>] a call's arguments
  # @return [Array<Prism::LocalVariableReadNode>] the local variables they
  #   interpolate, each the whole of its interpolation
  def self.interpolated_reads(arguments)
    arguments.grep(Prism::InterpolatedStringNode).flat_map(&:parts).filter_map { |part| interpolated_read(part) }
  end
  private_class_method :interpolated_reads

  # Holds `program` to what rows needs to list every call it should: every
  # literal Ruby read differently is one rows follows into the catalog
  # calls (see followed_literals). Any text that reaches a catalog call
  # comes from a literal in the source or from the game, so no call can
  # then hold a dropped escape rows does not list.
  #
  # @param program [Prism::ProgramNode]
  # @param writes [Hash] local_writes of the program
  # @return [void]
  # @raise [ArgumentError] at the first literal Ruby read differently that
  #   rows does not follow, or the first interpolating <<~ heredoc
  def self.check_drops_followed(program, writes)
    followed = followed_literals(program, writes)
    containers = {}.compare_by_identity
    walk(program) do |node, _scopes|
      node.parts.each { |part| containers[part] = node } if node.respond_to?(:parts)
      node.elements.each { |element| containers[element] = node } if node.is_a?(Prism::ArrayNode)
      next unless node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode)

      container = containers.fetch(node, node)
      next if container.is_a?(Prism::InterpolatedRegularExpressionNode) || container.is_a?(Prism::InterpolatedXStringNode)
      next if !literal_dropped?(node, container) || followed.key?(node)

      raise ArgumentError, "cannot follow #{node.slice} at line #{node.location.start_line}, whose escape Ruby dropped, " \
                           'into the catalog calls: only their own arguments and string locals they alone read are followed'
    end
  end
  private_class_method :check_drops_followed

  # @param program [Prism::ProgramNode]
  # @param writes [Hash] local_writes of the program
  # @return [Hash{Prism::StringNode => true}] the literals rows follows into
  #   the catalog calls: the literal parts of their arguments, and the
  #   literal of every local variable set once, by a statement whose value
  #   Ruby throws away, and read only as a string local (see string_local)
  #   a catalog call's argument interpolates, so never copied on
  def self.followed_literals(program, writes)
    followed = {}.compare_by_identity
    catalog_reads = {}.compare_by_identity
    reads = Hash.new { |hash, key| hash[key] = [] }
    walk(program) do |node, scopes|
      reads[local_key(node, scopes)] << [node, scopes] if node.is_a?(Prism::LocalVariableReadNode)
      next unless catalog_call?(node)

      arguments = node.arguments&.arguments || []
      arguments.flat_map { |argument| literal_parts(argument) }.each { |part| followed[part] = true }
      interpolated_reads(arguments).each { |read| catalog_reads[read] = true }
    end
    writes.each do |key, sets|
      write, body = sets.first
      next unless sets.size == 1 && write.is_a?(Prism::LocalVariableWriteNode) && value_thrown_away?(write, body, program)
      next unless reads.fetch(key, []).all? { |read, scopes| catalog_reads.key?(read) && string_local(read, scopes, writes) }

      followed[write.value] = true
    end
    followed
  end
  private_class_method :followed_literals

  # @param statement [Prism::Node]
  # @param body [Prism::StatementsNode, nil] the body it is a statement of
  #   (nil when it is only part of one)
  # @param program [Prism::ProgramNode] the program it is in
  # @return [Boolean] true when Ruby throws its value away: a statement of
  #   the program, or of a body it does not end (the last statement of a
  #   method, block, branch or '(...)' gives that its value)
  def self.value_thrown_away?(statement, body, program)
    return false unless body

    !body.body.last.equal?(statement) || body.equal?(program.statements)
  end
  private_class_method :value_thrown_away?

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
  # @return [Prism::LocalVariableReadNode, nil] the local variable `part`
  #   interpolates, when it interpolates exactly one local variable and
  #   nothing else
  def self.interpolated_read(part)
    statements = part.statements&.body if part.is_a?(Prism::EmbeddedStatementsNode)
    statements.first if statements&.size == 1 && statements.first.is_a?(Prism::LocalVariableReadNode)
  end
  private_class_method :interpolated_read

  # @param argument [Prism::Node]
  # @param locals [Hash{Symbol => Hash}] string_locals of its call
  # @return [Boolean] true when Ruby read some literal part of the argument,
  #   or a string local it interpolates, differently from its single-quoted
  #   reading
  # @raise [ArgumentError] for an interpolating <<~ heredoc (see literal_dropped?)
  def self.dropped?(argument, locals)
    literal_parts(argument).any? { |part| literal_dropped?(part, argument) } ||
      (argument.is_a?(Prism::InterpolatedStringNode) &&
       argument.parts.any? { |part| locals.dig(interpolated_read(part)&.name, :dropped) })
  end
  private_class_method :dropped?

  # @param literal [Prism::StringNode, Prism::SymbolNode] a literal, or a
  #   literal part of one
  # @param container [Prism::Node] the literal it is part of (itself when it
  #   is no part)
  # @return [Boolean] true when it is written in an interpolating form
  #   (double quotes, say) and Ruby read it differently from its
  #   single-quoted reading
  # @raise [ArgumentError] for an interpolating <<~ heredoc: Ruby takes its
  #   indentation out as well as its escapes, so the two readings differ
  #   even where it has no escape
  def self.literal_dropped?(literal, container)
    opening = opening(literal, container)
    return false unless interpolating?(opening)
    if opening.start_with?('<<~')
      raise ArgumentError, "cannot read #{opening} at line #{container.location.start_line}: an interpolating <<~ heredoc " \
                           'has its indentation taken out, which this reader does not rebuild'
    end

    written = literal.respond_to?(:content) ? literal.content : literal.value
    literal.unescaped != single_quoted_reading(written)
  end
  private_class_method :literal_dropped?

  # @param literal [Prism::Node] a literal, or a literal part of one
  # @param container [Prism::Node] the literal it is part of (itself when it
  #   is no part)
  # @return [String] how it opens ('"', "%q(", '<<~END', '%W[', ...): its
  #   own opening, else its container's ("a" 'b' has a part of each form;
  #   a heredoc's lines have none of their own); '' for neither
  def self.opening(literal, container)
    own = literal.opening if literal.respond_to?(:opening)
    own || (container.opening if container.respond_to?(:opening)).to_s
  end
  private_class_method :opening

  # @param opening [String] how a literal opens (see opening)
  # @return [Boolean] false for '...', %q(...), %w[...], %i[...], %s(...),
  #   :'...' and <<~'END' heredocs, which keep backslashes
  def self.interpolating?(opening)
    !opening.match?(/\A(?:'|%[qwis]|:'|<<[-~]?')/)
  end
  private_class_method :interpolating?

  # @param argument [Prism::Node] a string literal or an interpolated string
  # @param locals [Hash{Symbol => Hash}] string_locals of its call
  # @param side [Symbol] :intent for the text as its author meant it (its
  #   single-quoted reading where it interpolates), :ruby for the text as
  #   Ruby read it
  # @return [String]
  # @raise [ArgumentError] for any other argument, or an interpolation of
  #   anything but one of `locals`
  def self.reading(argument, locals, side)
    literal = ->(part) { side == :intent && interpolating?(opening(part, argument)) ? single_quoted_reading(part.content) : part.unescaped }
    case argument
    when Prism::StringNode then literal.call(argument)
    when Prism::InterpolatedStringNode
      argument.parts.map do |part|
        next literal.call(part) if part.is_a?(Prism::StringNode)

        name = interpolated_read(part)&.name
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
