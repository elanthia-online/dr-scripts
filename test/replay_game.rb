# frozen_string_literal: true

require 'json'

# Raised when a replay sends more commands than its send budget, so a spec can
# assert that a script loops forever (`raise_error(ReplayLoopGuard)`).
#
# It inherits from Exception, not StandardError, on purpose: a `rescue => e`
# in the code under test must not swallow it and carry on looping.
class ReplayLoopGuard < Exception # rubocop:disable Lint/InheritException
end

# A game for specs, played from real log lines. It answers the commands a
# script sends through DRC.bput and fput, and feeds every line it sends back
# to the Flags matchers, so a whole script run can be replayed from its entry
# point.
#
# It models lich-5's behaviour; no lich-5 code is copied. Each modelled rule
# cites the lich-5 line it imitates, at lich-5 commit 480bdee3:
# - DRC.bput: lib/dragonrealms/commons/common.rb:179-288 ("DRC:N" below);
# - Flags matching: lib/dragonrealms/drinfomon/drparser.rb:124-139 (match_line),
#   :145-155 (check_events) and :582-584 (parse feeds one to the other);
# - fput: lib/global_defs.rb:1483-1641;
# - the "...wait N seconds." pattern: lib/common/wait_response.rb:9.
#
# == Replies
# Every command the script sends is answered by the first rule that matches
# it, in this order:
# 1. overrides ({#override}): scenario replies that win over everything else,
#    e.g. a refusal injected at one step;
# 2. scripted replies ({#script}): one reply per call, used once, in the order
#    they were scripted. A rule matches the exact command, or a Regexp "verb
#    signature" such as /\Acrush my \S+ with my /, and a command can also
#    reach a rule through an alias ({#alias_command}) when the script words a
#    command differently from the log;
# 3. fallbacks ({#fallback}): replies for commands nothing else answers.
# A command no rule answers gets silence, exactly as in game when the game
# says nothing the script waits for.
#
# == Lines
# Every line is a {Line}: either a real log line, {ReplayGame.log}('26:6742'),
# whose text comes from a spec/fixtures/*/log_lines.json fixture, or a line
# built from code, {ReplayGame.code}(text, from: 'R:290'), which shows as
# CODE-DERIVED in every trace. Bare strings are refused.
#
# == Time
# {#clock} is a fake clock in seconds. Only the model advances it: a bput
# timeout (15 s), an fput timeout (60 s), a "...wait N" refusal (N s) and
# the harness `pause`. Roundtime is not simulated (the harness `waitrt?` is a
# no-op).
#
# @example Replay one command
#   game = ReplayGame.new.install(self)
#   game.script('mix my heavy cauldron with my mixing stick',
#               ReplayGame.log('26:6738'), ReplayGame.log('26:6740'), ReplayGame.log('26:6742'))
#   DRC.bput('mix my heavy cauldron with my mixing stick', '^Applying the final touches', 'Roundtime:')
#   # => "Roundtime:"
class ReplayGame
  # One game line fed to a replay.
  #
  # @!attribute [r] text
  #   @return [String] the line as the game sends it (it may carry XML tags)
  # @!attribute [r] cite
  #   @return [String] "<log>:<line>" for a log line, or the code line a
  #     code-derived line was built from (e.g. "R:290")
  # @!attribute [r] origin
  #   @return [Symbol] :log or :code
  Line = Struct.new(:text, :cite, :origin) do
    # @return [Boolean] true when the line is not in any log
    def code?
      origin == :code
    end

    # @return [String] the cite, or "CODE-DERIVED(<source>)" for a line built
    #   from code
    def label
      code? ? "CODE-DERIVED(#{cite})" : cite
    end
  end

  # One reply rule: which commands it answers, the lines it sends back, and
  # how often it may answer.
  #
  # @!attribute [r] matcher
  #   @return [String, Regexp] the exact command, or a verb signature
  # @!attribute [r] lines
  #   @return [Array<Line>] the reply, in arrival order
  # @!attribute [r] times
  #   @return [Integer, nil] how many sends it answers; nil for no limit
  # @!attribute [rw] used
  #   @return [Integer] how many sends it has answered
  # @!attribute [r] after
  #   @return [Proc, nil] called with the game once the reply has arrived,
  #     e.g. to change the hands the way the game would
  Rule = Struct.new(:matcher, :lines, :times, :used, :after) do
    # @param command [String] a command as sent
    # @return [Boolean] true when this rule answers the command
    def matches?(command)
      matcher.is_a?(Regexp) ? matcher.match?(command) : matcher == command
    end

    # @return [Boolean] true while the rule may answer another send
    def available?
      times.nil? || used < times
    end
  end

  # One entry of the replay trace.
  #
  # @!attribute [r] kind
  #   @return [Symbol] :send (a command went out), :line (a game line
  #     arrived), :flag (a Flag was set), :stall (the clock moved) or :call (a
  #     modelled commons call, from ReplayCommons)
  # @!attribute [r] text
  #   @return [String] the command, line, flag key, stall reason or call
  # @!attribute [r] label
  #   @return [String, nil] where it came from: the rule source for a send,
  #     the cite for a line or flag, the seconds for a stall
  Event = Struct.new(:kind, :text, :label)

  # The fixtures {ReplayGame.log} reads: every spec/fixtures/*/log_lines.json.
  FIXTURE_GLOB = File.expand_path('../spec/fixtures/*/log_lines.json', __dir__)

  # A fixture key naming a log line, "<log>:<line>". Keys starting with "_"
  # are metadata (e.g. "_source") and are skipped.
  CITE_FORMAT = /\A\d+:\d+\z/

  # Sends a replay allows before it raises {ReplayLoopGuard}.
  DEFAULT_SEND_BUDGET = 80

  # Seconds DRC.bput waits for a matching line (BPUT_DEFAULT_TIMEOUT, DRC:72).
  BPUT_TIMEOUT = 15

  # Seconds fput waits for any line before it gives up (global_defs.rb:1505).
  FPUT_TIMEOUT = 60

  # The game's roundtime refusal, "...wait 1 seconds." (25:11582). Same
  # pattern as lich-5's WAIT_RESPONSE_PATTERN (wait_response.rb:9).
  WAIT_RESPONSE_PATTERN = /(?:\.\.\. ?wait|\AWait) (?<seconds>[0-9]+) sec(?:onds?)?\.(?:<[^>]+>)*\s*\z/

  # Replies fput gives up on without resending (global_defs.rb:1582-1608), when
  # the character is neither dead, stunned nor webbed.
  FPUT_REFUSAL_PATTERN = /stunned|can't do that while|cannot seem|^(?!You rummage).*can't seem|don't seem/

  # The type-ahead refusal fput waits 1 s on and resends (global_defs.rb:1600).
  FPUT_TYPE_AHEAD_PATTERN = /Sorry, you may only type ahead/

  # An object link tag, opening or closing, as lich-5's DRParser::LINK_TAG
  # (drparser.rb:124): match_line removes it and keeps the link's text.
  LINK_TAG = %r{</?a\b[^>]*>}

  # Two or more bold openings in a row, which match_line collapses to one
  # (DRParser::PUSH_BOLD_RUN, drparser.rb:125).
  PUSH_BOLD_RUN = %r{(?:<pushBold/>){2,}}

  # Two or more bold closings in a row, which match_line collapses to one
  # (DRParser::POP_BOLD_RUN, drparser.rb:126).
  POP_BOLD_RUN = %r{(?:<popBold/>){2,}}

  # XML entities the tag stripper decodes.
  XML_ENTITIES = { '&gt;' => '>', '&lt;' => '<', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' }.freeze

  class << self
    # A real game line, by cite.
    #
    # @param cite [String] "<log>:<line>", e.g. "26:6742"
    # @return [Line] the line, its text read from the fixtures
    # @raise [ArgumentError] when no fixture holds the cite
    def log(cite)
      text = log_lines.fetch(cite) do
        raise ArgumentError, "#{cite.inspect} is in no fixture matching #{FIXTURE_GLOB}"
      end
      Line.new(text, cite, :log)
    end

    # A game line that is in no log, built from code. Traces mark it
    # CODE-DERIVED.
    #
    # @param text [String] the line
    # @param from [String] the code line it comes from, e.g. "R:290"
    # @return [Line]
    # @raise [ArgumentError] when from is blank
    def code(text, from:)
      raise ArgumentError, 'a code-derived line needs from: naming the code line it comes from' if from.to_s.strip.empty?

      Line.new(text, from, :code)
    end

    # Every cited line of every fixture, loaded once.
    #
    # @return [Hash{String => String}] cite => text
    # @raise [ArgumentError] when the fixtures are malformed (see {.load_log_lines})
    def log_lines
      @log_lines ||= load_log_lines(Dir[FIXTURE_GLOB].sort).freeze
    end

    # Reads and merges log line fixtures.
    #
    # @param paths [Array<String>] JSON files, each a Hash of cite => text
    # @return [Hash{String => String}] cite => text
    # @raise [ArgumentError] when a key is not a cite, or two fixtures give
    #   one cite different texts
    def load_log_lines(paths)
      paths.each_with_object({}) do |path, lines|
        JSON.parse(File.read(path)).each do |cite, text|
          next if cite.start_with?('_')
          raise ArgumentError, "#{path}: #{cite.inspect} is not a <log>:<line> cite" unless CITE_FORMAT.match?(cite)
          raise ArgumentError, "#{path}: #{cite} has another text in an earlier fixture" if lines.key?(cite) && lines[cite] != text

          lines[cite] = text
        end
      end
    end
  end

  # @return [Array<String>] every command sent, resends included, in order
  attr_reader :sent

  # @return [Array<Event>] everything that happened, in order
  attr_reader :trace

  # @return [Float] fake seconds elapsed
  attr_reader :clock

  # @return [Array<String>] the bput and fput timeout messages lich-5 would
  #   print (DRC:281, global_defs.rb:1551), one per timeout
  attr_reader :diagnostics

  # @param send_budget [Integer] sends allowed before {ReplayLoopGuard}
  def initialize(send_budget: DEFAULT_SEND_BUDGET)
    @send_budget = send_budget
    @overrides = []
    @scripts = []
    @fallbacks = []
    @aliases = {}
    @queue = []
    @sent = []
    @trace = []
    @diagnostics = []
    @clock = 0.0
  end

  # Routes the example's game I/O here: DRC.bput through an `allow`, and the
  # harness fput and pause through $replay_game (reset_data clears it).
  #
  # @param example [RSpec::Core::ExampleGroup] the running example (`self`)
  # @return [ReplayGame] self
  def install(example)
    game = self
    $replay_game = game
    example.instance_exec { allow(DRC).to receive(:bput) { |*args| game.bput(*args) } }
    self
  end

  # Scripts one reply, used by one send of a matching command. Several
  # replies for one command are used in the order they were scripted.
  #
  # @param command [String, Regexp] the exact command, or a verb signature
  # @param lines [Array<Line>] the reply, in arrival order (none for silence)
  # @param after [Proc, nil] called with the game once the reply has arrived
  # @return [ReplayGame] self
  # @raise [ArgumentError] when a line is not a {Line}
  def script(command, *lines, after: nil)
    @scripts << rule(command, lines, 1, after)
    self
  end

  # Adds a reply that wins over scripted replies and fallbacks.
  #
  # @param command [String, Regexp] the exact command, or a verb signature
  # @param lines [Array<Line>] the reply (none for silence)
  # @param times [Integer, nil] sends it answers; nil for every send
  # @param after [Proc, nil] called with the game once the reply has arrived
  # @return [ReplayGame] self
  # @raise [ArgumentError] when a line is not a {Line}
  def override(command, *lines, times: 1, after: nil)
    @overrides << rule(command, lines, times, after)
    self
  end

  # Adds a reply for commands no override or scripted reply answers.
  #
  # @param command [String, Regexp] the exact command, or a verb signature
  # @param lines [Array<Line>] the reply (none for silence)
  # @param times [Integer, nil] sends it answers; nil for every send
  # @param after [Proc, nil] called with the game once the reply has arrived
  # @return [ReplayGame] self
  # @raise [ArgumentError] when a line is not a {Line}
  def fallback(command, *lines, times: nil, after: nil)
    @fallbacks << rule(command, lines, times, after)
    self
  end

  # Lines the game sends with no command before them, e.g. "You struggle to
  # recall the crafting instructions ..." three minutes after a study
  # (25:37919). Flags see each line as it arrives; like any reply line, it
  # waits to be read until the next command's `clear` (DRC:198) drops it.
  # Nothing is sent and the clock does not move.
  #
  # @param lines [Array<Line>] the lines, in arrival order
  # @return [ReplayGame] self
  # @raise [ArgumentError] when a line is not a {Line}
  def unprompted(*lines)
    check_lines(lines)
    lines.each { |line| arrive(line) }
    self
  end

  # Lets a command the script words differently use the replies scripted for
  # the logged wording (e.g. remedy's `put alcohol in my heavy cauldron` for
  # the log's `pour part alcohol in my heavy cauldron`).
  #
  # @param command [String] the command as the script sends it
  # @param as [String] the command as the log has it
  # @return [ReplayGame] self
  def alias_command(command, as:)
    @aliases[command] = as
    self
  end

  # Model of DRC.bput (DRC:179-288): send a command and wait for a line that
  # matches one of the patterns.
  #
  # - An options Hash may come first; 'timeout' and 'suppress_no_match' are
  #   honoured (DRC:180-185).
  # - String patterns become case-insensitive Regexps (DRC:196-197).
  # - Lines left over from earlier commands are dropped before the send
  #   (`clear`, DRC:198).
  # - Lines are read in arrival order and, for each line, the patterns are
  #   tried in order; the first match returns its matched text, not the whole
  #   line (`match.to_a.first`, DRC:273-276). So the first matching LINE wins,
  #   even over a pattern listed earlier that a later line would match.
  # - A "...wait N seconds." line advances the clock N s and resends the
  #   command. The lines that arrived with it are read again first, wait lines
  #   skipped (DRC:211, 221-224, 301-311).
  # - With no matching line the clock advances by the timeout, a no-match
  #   message is recorded in {#diagnostics} (DRC:280-285) and '' is returned.
  #
  # bput reads each line with its XML tags stripped (lich-5 games.rb:1139
  # strips the line before scripts read it); Flags saw the line, tags kept
  # but links removed ({#match_line}), when it arrived.
  #
  # @note Not modelled: the other resend cases (frozen world, type-ahead,
  #   asleep, performing, hidden, stunned, webbed, not standing; DRC:213-271).
  # @param message [String] the command
  # @param matches [Array<String, Regexp, Hash>] an optional options Hash,
  #   then the patterns
  # @return [String] the matched text, or '' on a timeout
  # @raise [ReplayLoopGuard] when the send budget runs out
  def bput(message, *matches)
    options = (matches.shift if matches.first.is_a?(Hash)) || {}
    timeout = options['timeout'] || BPUT_TIMEOUT
    patterns = matches.flatten.map { |item| item.is_a?(Regexp) ? item : /#{item}/i }
    @queue.clear
    send_command(message)
    seen = 0
    while (line = @queue.shift)
      seen += 1
      text = strip_xml(line.text)
      if (wait = WAIT_RESPONSE_PATTERN.match(text))
        resend_after_wait(message, wait[:seconds].to_i)
        next
      end
      patterns.each do |pattern|
        match = text.match(pattern)
        return match.to_a.first if match
      end
    end
    advance(timeout, "bput timeout: #{message}")
    @diagnostics << "DRC: No match was found after #{timeout} seconds for command '#{message}' (#{seen} lines seen)" unless options['suppress_no_match']
    ''
  end

  # Model of the pattern-less fput (global_defs.rb:1483-1641): send a
  # command and return the first line of the reply.
  #
  # - Lines left over from earlier commands are dropped first (`clear`).
  # - A "...wait N" line advances the clock N s and resends (:1560-1568).
  # - A type-ahead refusal advances it 1 s and resends (:1600).
  # - A refusal such as "can't seem" returns false (:1582-1608).
  # - Silence advances the clock 60 s, records the timeout message and
  #   returns false (:1549-1552).
  # The returned line stays readable, as fput puts it back (:1627).
  #
  # @note lich-5 releases before the fput `timeout:` option wait for a reply
  #   forever; this model always gives up after 60 s.
  # @param message [String] the command
  # @param waitingfor [Array] patterns; only the pattern-less form is modelled
  # @return [String, false] the first reply line (tags stripped), or false
  # @raise [NotImplementedError] when patterns are given
  # @raise [ReplayLoopGuard] when the send budget runs out
  def fput(message, *waitingfor)
    raise NotImplementedError, 'ReplayGame#fput models only fput without patterns' unless waitingfor.empty?

    @queue.clear
    send_command(message)
    while (line = @queue.shift)
      text = strip_xml(line.text)
      if (wait = WAIT_RESPONSE_PATTERN.match(text))
        advance(wait[:seconds].to_i, "fput wait: #{message}")
        @queue.clear
        send_command(message)
        next
      end
      if FPUT_TYPE_AHEAD_PATTERN.match?(text)
        advance(1, "fput type-ahead: #{message}")
        @queue.clear
        send_command(message)
        next
      end
      @queue.unshift(line)
      return false if FPUT_REFUSAL_PATTERN.match?(text)

      return text
    end
    advance(FPUT_TIMEOUT, "fput timeout: #{message}")
    @diagnostics << "fput: No game response for #{FPUT_TIMEOUT}s to '#{message}'"
    false
  end

  # Moves the fake clock forward.
  #
  # @param seconds [Numeric] how far
  # @param reason [String, nil] traced as a :stall when given
  # @return [Float] the new clock
  def advance(seconds, reason = nil)
    @clock += seconds.to_f
    @trace << Event.new(:stall, reason, seconds) if reason
    @clock
  end

  # Records a modelled commons call in the trace (ReplayCommons calls this).
  #
  # @param text [String] the call, e.g. 'DRCC.stow_crafting_item("stamp", ...)'
  # @return [void]
  def record_call(text)
    @trace << Event.new(:call, text, nil)
  end

  # The sends and modelled calls in order, one string each: ">> <command>"
  # for a send and "** <call>" for a commons call. Pin it to fix a whole
  # command sequence.
  #
  # @param calls [Boolean] include the commons calls
  # @return [Array<String>]
  def timeline(calls: true)
    @trace.filter_map do |event|
      case event.kind
      when :send then ">> #{event.text}"
      when :call then "** #{event.text}" if calls
      end
    end
  end

  # The Flags the replay set, in order.
  #
  # @return [Array<Array(String, String)>] [flag key, label of the line]
  def flag_sets
    @trace.select { |event| event.kind == :flag }.map { |event| [event.text, event.label] }
  end

  # The whole trace as text, for a failing spec's message or a debugging
  # `puts game.report`.
  #
  # @return [String]
  def report
    @trace.map do |event|
      case event.kind
      when :send then ">> #{event.text}  [#{event.label}]"
      when :line then "   #{event.label}: #{event.text}"
      when :flag then "   FLAG #{event.text} <- #{event.label}"
      when :stall then "   (#{event.label} s: #{event.text})"
      when :call then "** #{event.text}"
      end
    end.join("\n")
  end

  private

  # Builds a reply rule, refusing uncited lines.
  #
  # @param matcher [String, Regexp]
  # @param lines [Array<Line>]
  # @param times [Integer, nil]
  # @param after [Proc, nil]
  # @return [Rule]
  # @raise [ArgumentError] when the matcher or a line has the wrong type
  def rule(matcher, lines, times, after)
    raise ArgumentError, "a reply matcher is a String or Regexp, not #{matcher.inspect}" unless matcher.is_a?(String) || matcher.is_a?(Regexp)

    check_lines(lines)
    Rule.new(matcher, lines.dup.freeze, times, 0, after)
  end

  # Refuses game lines that are not cited.
  #
  # @param lines [Array<Object>]
  # @return [void]
  # @raise [ArgumentError] when a line is not a {Line}
  def check_lines(lines)
    bare = lines.reject { |line| line.is_a?(Line) }
    raise ArgumentError, "reply lines must be ReplayGame.log or ReplayGame.code, not #{bare.inspect}" unless bare.empty?
  end

  # Sends one command: counts it against the budget, finds its reply and
  # delivers each line.
  #
  # @param command [String]
  # @return [void]
  # @raise [ReplayLoopGuard] when the send budget runs out
  def send_command(command)
    @sent << command
    raise ReplayLoopGuard, "more than #{@send_budget} commands sent; the last was #{command.inspect}" if @sent.size > @send_budget

    rule, source = resolve(command)
    @trace << Event.new(:send, command, source.to_s)
    return unless rule

    rule.lines.each { |line| arrive(line) }
    rule.after&.call(self)
  end

  # Waits out a "...wait N" refusal and resends, keeping the lines that came
  # with the refusal (minus wait lines) to be read first (DRC:211, 221-224).
  #
  # @param message [String] the command to resend
  # @param seconds [Integer] the wait
  # @return [void]
  def resend_after_wait(message, seconds)
    advance(seconds, "bput wait: #{message}")
    held = @queue.reject { |line| WAIT_RESPONSE_PATTERN.match?(strip_xml(line.text)) }
    @queue.clear
    send_command(message)
    @queue.unshift(*held)
  end

  # The rule answering a command: an override, else a scripted reply, else a
  # fallback, each also tried through the command's alias.
  #
  # @param command [String]
  # @return [Array(Rule, Symbol)] the rule (nil for silence) and its source
  def resolve(command)
    keys = [command, @aliases[command]].compact
    [[@overrides, :override], [@scripts, :script], [@fallbacks, :fallback]].each do |rules, source|
      rule = rules.find { |candidate| candidate.available? && keys.any? { |key| candidate.matches?(key) } }
      next unless rule

      rule.used += 1
      return [rule, source]
    end
    [nil, :silence]
  end

  # A line arrives: Flags see it first (in {#match_line} shape, tags kept),
  # then it waits to be read.
  #
  # @param line [Line]
  # @return [void]
  def arrive(line)
    @trace << Event.new(:line, line.text, line.label)
    deliver_to_flags(line)
    @queue << line
  end

  # Model of DRParser.check_events (drparser.rb:145-155) as DRParser.parse
  # calls it (:582-584): for each Flag, the first of its patterns that
  # matches the line in {#match_line} shape sets the Flag to the MatchData;
  # later patterns of that Flag are not tried.
  #
  # @param line [Line]
  # @return [void]
  def deliver_to_flags(line)
    text = match_line(line.text)
    Flags.matchers.each do |key, regexes|
      regexes.each do |regex|
        match = text.match(regex)
        next unless match

        Flags[key] = match
        @trace << Event.new(:flag, key, line.label)
        break
      end
    end
  end

  # Model of DRParser.match_line (drparser.rb:135-139): the line Flags are
  # matched against, with object links removed (their text kept) and doubled
  # bold collapsed. Every other tag stays, so a Flag can still match a
  # single <pushBold/>.
  #
  # @param text [String] the line as the game sends it
  # @return [String] the line in the shape Flags see
  def match_line(text)
    return text unless text.include?('</a>') || text.include?('<pushBold/><pushBold/>')

    text.gsub(LINK_TAG, '').gsub(PUSH_BOLD_RUN, '<pushBold/>').gsub(POP_BOLD_RUN, '<popBold/>')
  end

  # The line as a script reads it: tags removed, the common XML entities
  # decoded.
  #
  # @note A simplification of lich-5 strip_xml (markup.rb:117): stream
  #   buffering across lines is not modelled.
  # @param text [String]
  # @return [String]
  def strip_xml(text)
    text.gsub(/<[^>]*>/, '').gsub(/&(?:gt|lt|quot|apos|amp);/, XML_ENTITIES)
  end
end
