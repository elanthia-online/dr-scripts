# frozen_string_literal: true

require 'ostruct'

# Model of lich-5's ArgParser#parse_args (lib/common/arg_parser.rb:25-45 and
# :85-138 at lich-5 480bdee3, "AP:N" below), so a spec can check which of a
# script's argument forms a command line matches, the way lich-5 decides it.
# No lich-5 code is copied.
#
# The rules it models:
# - each definition set (form) is tried against the arguments;
# - required definitions match positionally, in order (AP:96-101);
# - optional definitions then match any remaining argument (AP:103-108);
# - for each argument, a definition's :regex is tried before its :options,
#   and an option matches as a prefix unless :option_exact (AP:85-91);
# - every matched value is downcased (AP:99, AP:105);
# - without flex, an argument left over fails the form (AP:123-125); with
#   flex the leftovers go to `flex` (AP:110-111);
# - exactly one matching form is returned; none or several print a message
#   and the help, then exit (AP:30-44);
# - a lone "help", "?" or "h" prints the help and exits (AP:29).
#
# The harness `parse_args` uses it when a spec sets `$parse_args_model = true`
# (and the arguments in `$script_vars`, as Lich's `variable`).
#
# @note Not modelled: the `parse_args_debug` echo (AP:86), the flex profile
#   name warning (AP:113-122) and the YAML settings part of the help
#   (AP:66-81).
module ArgParserModel
  # Arguments that ask for the help instead of a run (AP:29).
  HELP_ARGUMENT = /^help$|^\?$|^h$/

  # Message when no form matches (AP:35).
  NO_MATCH_MESSAGE = "***INVALID ARGUMENTS DON'T MATCH ANY PATTERN***"

  # Message when several forms match (AP:38).
  MULTIPLE_MATCH_MESSAGE = '***INVALID ARGUMENTS MATCH MULTIPLE PATTERNS***'

  # One argument of a script's argument string, as Lich's Script#initialize
  # splits it (lib/common/script.rb:1842 at 480bdee3): a run of characters
  # that may hold a double-quoted part with spaces, or a run without spaces.
  SCRIPT_ARGUMENT = /[^\s"]*(?<!\\)"(?:\\"|[^"])+(?<!\\)"[^\s]*|(?:\\"|[^"\s])+/

  module_function

  # The `variable` a script sees when started with an argument string, as
  # typed (`;remedy remedies 2 "blister cream" ...`) or as start_script joins
  # an argument list (lib/global_defs.rb:22-26): [0] the whole string, [1..]
  # each argument with its double quotes removed (lib/common/script.rb:1837-1843).
  #
  # @param line [String] the argument string
  # @return [Array<String>] empty for an empty string
  def script_vars(line)
    return [] if line.empty?

    [line, *line.scan(SCRIPT_ARGUMENT).map { |arg| arg.gsub(/(?<!\\)"/, '').gsub('\\"', '"') }]
  end

  # The `variable` a script sees when another script runs it with
  # DRC.wait_for_script_to_complete(name, args): each argument holding
  # whitespace is wrapped in double quotes (lib/dragonrealms/commons/common.rb:339),
  # the list is joined with spaces (start_script), and the string is split
  # again ({.script_vars}). A nil or blank argument therefore disappears.
  #
  # @param args [Array<Object>] the caller's argument list (Integers, nil ...)
  # @return [Array<String>]
  def caller_vars(args)
    script_vars(args.map { |arg| arg.to_s =~ /\s/ ? "\"#{arg}\"" : arg }.join(' '))
  end

  # Matches arguments against a script's argument forms.
  #
  # @param definitions [Array<Array<Hash>>] the forms, as passed to parse_args
  # @param argv [Array<String>] the arguments, as typed (Lich's
  #   `variable.drop(1)`)
  # @param raw [String] the whole argument string (Lich's `variable.first`),
  #   shown when no form or several forms match
  # @param flex [Boolean] keep leftover arguments in `flex` instead of failing
  # @return [OpenStruct] the values of the one matching form, downcased
  # @raise [SystemExit] when no form or several forms match, or help is asked
  def parse(definitions, argv, raw: argv.join(' '), flex: false)
    unless argv.size == 1 && argv.grep(HELP_ARGUMENT).any?
      result = definitions.map { |definition| check_match(definition, argv.dup, flex) }.compact
      return result.first if result.size == 1

      echo(result.empty? ? NO_MATCH_MESSAGE : MULTIPLE_MATCH_MESSAGE)
      respond("Provided Arguments: '#{raw}'")
    end
    display_args(definitions)
    exit
  end

  # Prints each form's call format and argument descriptions (AP:50-65).
  #
  # @param definitions [Array<Array<Hash>>]
  # @return [void]
  def display_args(definitions)
    definitions.each do |form|
      shown = form.reject { |definition| definition[:name].to_s == 'script_summary' }
      respond('')
      respond(' SCRIPT CALL FORMAT AND ARG DESCRIPTIONS (arguments in brackets are optional):')
      respond("  ;#{Script.current.name} " + shown.map { |definition| format_item(definition) }.join(' '))
      shown.each do |definition|
        options = definition[:options] ? "[#{definition[:options].join(', ')}]" : ''
        respond("   #{(definition[:display] || definition[:name]).to_s.ljust(12)} #{definition[:description]} #{options}")
      end
    end
  end

  # Whether one argument satisfies one definition: :regex first, then
  # :options as a case-insensitive prefix (AP:85-91).
  #
  # @param definition [Hash]
  # @param item [String, nil] the argument; nil when none is left
  # @return [Boolean]
  def matches_def(definition, item)
    return true if definition[:regex] && definition[:regex] =~ item
    return true if definition[:options]&.find { |option| item =~ /^#{option}#{'$' if definition[:option_exact]}/i }

    false
  end

  # Matches one form (AP:93-128).
  #
  # @param definitions [Array<Hash>] the form
  # @param vars [Array<String>] the arguments; consumed
  # @param flex [Boolean]
  # @return [OpenStruct, nil] the values, or nil when the form does not match
  def check_match(definitions, vars, flex)
    args = OpenStruct.new
    definitions.reject { |definition| definition[:optional] }.each do |definition|
      return nil unless matches_def(definition, vars.first)

      args[definition[:name]] = vars.shift.downcase
    end
    definitions.select { |definition| definition[:optional] }.each do |definition|
      match = vars.find { |item| matches_def(definition, item) }
      next unless match

      args[definition[:name]] = match.downcase
      vars.delete(match)
    end
    if flex
      args.flex = vars
    elsif !vars.empty?
      return nil
    end
    args
  end

  # One argument as shown in the call format (AP:130-138).
  #
  # @param definition [Hash]
  # @return [String]
  def format_item(definition)
    item = (definition[:display] || definition[:name]).to_s
    if definition[:optional]
      "[#{item}]"
    elsif definition[:variable] || definition[:options]
      "<#{item}>"
    else
      item
    end
  end
end
