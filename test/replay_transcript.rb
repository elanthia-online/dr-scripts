# frozen_string_literal: true

require 'json'

# One window of a real crafting run, read from a transcript fixture, that
# scripts a ReplayGame with the replies the game gave to each logged command.
#
# A transcript fixture (e.g. spec/fixtures/remedy/transcripts/*.json) holds:
# - "run", "log" (the log key of every cite, e.g. "26"), "from", "to";
# - "source": the log file and line window it was cut from, and how replies
#   were attributed to commands;
# - "steps": each logged command, in log order, as
#   {"cmd", "line", "user", "responses" => [{"text", "line"}]}. Every reply
#   line is the timestamped copy of that log line, with the timestamp removed.
#
# The logs come from another client script, so the log
# holds commands a Lich script does not send (analyze, extra resends) and
# words some commands differently. {#script} therefore takes only the steps
# whose command the script sends itself, minus any the spec names in skip:,
# and the spec maps remedy's wording onto the log's with
# ReplayGame#alias_command.
#
# @example Replay a cauldron run's crafting commands
#   transcript = ReplayTranscript.load('spec/fixtures/remedy/transcripts/2026-10-26_5598.json')
#   transcript.script(game, commands: /\A(?:mix|turn|pour|put|push|get|mark) /, skip: [5948])
class ReplayTranscript
  # One logged command and the game lines that answered it.
  #
  # @!attribute [r] command
  #   @return [String] the command as the log has it
  # @!attribute [r] line
  #   @return [Integer] the log line of the command
  # @!attribute [r] user
  #   @return [Boolean] true when the player typed it, not the client script
  # @!attribute [r] lines
  #   @return [Array<ReplayGame::Line>] the reply, in arrival order, cited
  Step = Struct.new(:command, :line, :user, :lines)

  # @return [String] the run id, e.g. "2026-10-26_5598"
  attr_reader :run

  # @return [String] where the window was cut from
  attr_reader :source

  # @return [Array<Step>] the logged commands, in log order
  attr_reader :steps

  # Reads a transcript fixture.
  #
  # @param path [String] the JSON file
  # @return [ReplayTranscript]
  # @raise [ArgumentError] when a reply line's text differs from the same
  #   cite in a log_lines.json fixture
  def self.load(path)
    new(JSON.parse(File.read(path)), path)
  end

  # @param data [Hash] the parsed fixture
  # @param path [String] the fixture, for error messages
  # @raise [ArgumentError] when a reply line's text differs from the same
  #   cite in a log_lines.json fixture
  def initialize(data, path)
    @run = data.fetch('run')
    @source = data.fetch('source')
    log = data.fetch('log')
    @steps = data.fetch('steps').map do |step|
      lines = step.fetch('responses').map { |reply| cited_line("#{log}:#{reply.fetch('line')}", reply.fetch('text'), path) }
      Step.new(step.fetch('cmd'), step.fetch('line'), step.fetch('user'), lines.freeze)
    end.freeze
  end

  # The step logged at a line.
  #
  # @param line [Integer] the log line of the command
  # @return [Step]
  # @raise [ArgumentError] when no step was logged at that line
  def step(line)
    @steps.find { |candidate| candidate.line == line } || raise(ArgumentError, "#{@run} has no command at line #{line}")
  end

  # Scripts one reply per selected step, in log order, so each send of a
  # command takes the next logged reply to it.
  #
  # Two edits let a spec vary one step of a real run (an event-order sweep):
  # - inject: an extra reply for a step's command, scripted just before the
  #   step's own, so that send gets it and the resend gets the logged reply
  #   (e.g. a real "...wait 1 seconds." line, 25:11582). An Array of such
  #   replies scripts each in turn (e.g. `[[], [], []]`: three sends go
  #   unanswered before the logged reply);
  # - replace: other lines for a step's reply (e.g. the same lines in another
  #   order).
  # A third, after:, changes no line: it runs a hook once a step's logged
  # reply has arrived (ReplayGame#script's after:), e.g. to move what the
  # hands hold the way the game did.
  #
  # @param game [ReplayGame] the replay to script
  # @param commands [Regexp] the logged commands to take (the ones the script
  #   under test sends itself)
  # @param skip [Array<Integer>] log lines of steps to leave out: commands the
  #   log sent that the script does not
  # @param from [Integer, nil] the first log line to take (a replay that
  #   starts part way through the window, e.g. `;remedy continue`)
  # @param inject [Hash{Integer => Array<ReplayGame::Line>, Array<Array<ReplayGame::Line>>}]
  #   step line => an extra reply, or a list of extra replies, scripted
  #   before the step's own
  # @param replace [Hash{Integer => Array<ReplayGame::Line>}] step line => the
  #   lines to reply with instead of the logged ones
  # @param after [Hash{Integer => Proc}] step line => a hook called with the
  #   game once that step's reply has arrived
  # @return [Array<Step>] the steps scripted
  # @raise [ArgumentError] when a skip, inject, replace or after line names
  #   no step, or names a step that is not scripted
  def script(game, commands:, skip: [], from: nil, inject: {}, replace: {}, after: {})
    skip.each { |line| step(line) }
    chosen = @steps.select do |step|
      commands.match?(step.command) && !skip.include?(step.line) && (from.nil? || step.line >= from)
    end
    (inject.keys + replace.keys + after.keys).each do |line|
      raise ArgumentError, "#{@run}: line #{line} is not a scripted step" unless chosen.include?(step(line))
    end
    chosen.each do |step|
      extra_replies(inject[step.line]).each { |reply| game.script(step.command, *reply) } if inject.key?(step.line)
      game.script(step.command, *replace.fetch(step.line, step.lines), after: after[step.line])
    end
  end

  private

  # The replies an inject value stands for: one reply (an Array of lines, or
  # none for silence), or a non-empty Array of replies.
  #
  # @param value [Array<ReplayGame::Line>, Array<Array<ReplayGame::Line>>]
  # @return [Array<Array<ReplayGame::Line>>]
  def extra_replies(value)
    !value.empty? && value.all?(Array) ? value : [value]
  end

  # A reply line as a cited log line, checked against the log_lines.json
  # fixtures when they hold the same cite.
  #
  # @param cite [String] "<log>:<line>"
  # @param text [String]
  # @param path [String] the fixture, for the error message
  # @return [ReplayGame::Line]
  # @raise [ArgumentError] when a log_lines.json fixture has another text
  def cited_line(cite, text, path)
    known = ReplayGame.log_lines[cite]
    raise ArgumentError, "#{path}: #{cite} reads #{text.inspect}, but a log_lines.json fixture has #{known.inspect}" if known && known != text

    ReplayGame::Line.new(text, cite, :log)
  end
end
