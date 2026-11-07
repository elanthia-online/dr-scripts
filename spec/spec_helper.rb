# Testing Conventions
#
# File organization:
#   - One spec file per script, named to match: <script-name>_spec.rb
#     (e.g. dependency_spec.rb for dependency.lic, pick_spec.rb for pick.lic)
#
# Principles:
#   - DAMP (Descriptive And Meaningful Phrases): favor readable, self-documenting
#     test names and setup over extreme DRYness. Each test should be understandable
#     in isolation without chasing helper definitions.
#   - SOLID: extract shared behavior into shared_examples when the same assertions
#     apply across multiple contexts. Use let/before for setup, not deep inheritance.
#     Keep each test focused on a single responsibility.
#
# Lich runtime isolation:
#   - Scripts (.lic files) cannot be required directly -- they depend on the full
#     Lich runtime. Extract just the unit under test via eval of specific line
#     ranges with one of the load_lic_* helpers defined below: load_lic_class /
#     load_lic_module for a class or module body, load_lic_constant for a
#     single-line constant, or load_lic_methods for the top-level defs of a
#     class-less script (returned wrapped in a module).
#   - To drive a whole script the way a user runs it, load its class, then
#     run_lic_entry evals the code after the class (its entry point). Pair it
#     with the replay support in test/ (ReplayGame answers DRC.bput and fput
#     from real log lines, ReplayCommons models the commons helpers,
#     $parse_args_model = true parses $script_vars like lich-5's ArgParser).
#     To drive a restart, reload_lic_class evaluates the class body again
#     before the next run_lic_entry, as Lich does on every start.
#
# Shared game doubles -- READ THIS before adding or copying a spec:
#   The game/commons layer is stubbed ONCE, centrally, so the whole suite can run
#   in a single process without specs clobbering each other's doubles. Follow
#   these rules or you WILL reintroduce order-dependent failures (a duplicate
#   top-level definition wins for the entire process by load order, so a stub
#   added in one spec silently changes another spec that ran first or last):
#
#   - Game objects (DRStats, DRSkill, DRSpells, DRRoom, GameObj, Flags, Room,
#     Map, Script, XMLData, EquipmentManager), the commons command modules (DRC,
#     DRCI, DRCC, DRCM, DRCT, DRCH, DRCA, DRCS, DRCMM, DRCTH) and Lich all live
#     in test/test_harness.rb. Do NOT redefine or reopen them in a spec file
#     (no `module DRC ... end`).
#   - To change what a stub returns for one example, override it there with
#     `allow(DRC).to receive(:bput).and_return(...)` -- never by reopening the
#     module. `allow` adds the method even if the harness lacks it.
#   - Harness default returns follow these conventions -- they are heuristics,
#     not guarantees, so check test/test_harness.rb for the exact value:
#       * presence / "did it happen" predicates (in_hands?, exists?) -> false
#       * "did the action succeed" checks (get_item?, cast_spell?, walk_to) -> true
#       * collection / count accessors -> [] / 0 / {}
#         (e.g. get_item_list -> [], count_* -> 0, get_total_wealth -> {})
#       * most other methods -> nil (an inert seam)
#     Some methods return domain values instead of nil -- notably
#     DRC.bput -> 'Roundtime' and DRCH.check_health -> a health Hash -- so do not
#     assume nil for a method you have not checked.
#   - Need a commons method the harness does not have yet? Add it to
#     test/test_harness.rb following the conventions above -- do not stub it
#     locally in one spec.
#   - UserVars is a generic dynamic store in the harness: any getter reads back
#     nil until set, any setter stores, and it is cleared before each example.
#     Override a key with allow(UserVars).to receive(:key)... or set it directly
#     with UserVars.key = value -- do NOT redefine the class in a spec. A script
#     that needs a domain default (e.g. combat-trainer's moons) reopens
#     Harness::UserVars to add just that default (see combat_trainer_spec).
#   - If a .lic method calls exit on a guard, drive it with
#     `expect { ... }.to raise_error(SystemExit)` (or stub exit on the instance).
#     RSpec itself does not rescue SystemExit: an unwrapped exit would end the
#     whole run there, counting only the examples run so far and leaving with
#     the exit's own status (0 for a bare exit, even after failures). The
#     global around hook at the bottom of this file turns such an exit into a
#     failure of that example instead, so the rest of the suite still runs.
#
# Shared setup / why reset_data lives here (do not move it):
#   - This file is loaded before every spec via .rspec (--require spec_helper). It
#     loads the test harness, includes Harness at the top level, provides the
#     load_lic_class / load_lic_module / load_lic_constant / load_lic_methods
#     extraction helpers, and registers the single global before(:each)
#     { reset_data } hook and the global around(:each) exit guard.
#   - Do NOT register a global RSpec.configure { config.before } in a spec.
#     Same-scope before(:each) hooks run in the order they are registered, so a
#     config.before(:each) runs before a group's own before hooks only when it
#     was registered before that group was defined. spec_helper is required
#     first (via .rspec), so its single reset_data hook is registered before
#     every group and always runs first -- which is exactly why reset_data
#     belongs here, not in a spec. A config.before added inside a spec file is
#     registered AFTER the groups of already-loaded specs, so it runs AFTER
#     their before hooks and clobbers the per-example world (guild, settings,
#     hands, room) they set up (and it also runs for every example in every
#     other file). Put spec-specific world setup in a describe-scoped before
#     instead.

# Line ranges (0-based, inclusive) each extractor actually eval'd out of a .lic,
# keyed by absolute path. Lets the coverage backfill below distinguish "no spec
# ever eval'd this line" from "eval'd, but Ruby attributed the statement to a
# neighbouring line". Harmless and cheap when coverage is off.
LIC_EVAL_RANGES = Hash.new { |h, k| h[k] = [] }

# Coverage (opt-in): COVERAGE=1 bundle exec rspec, report in coverage/index.html.
#
# This has to run before anything else here, and it needs `enable_coverage :eval`
# -- the .lic files are never required, they are eval'd by load_lic_class below,
# and Ruby only measures eval'd source when Coverage is set up with eval: true.
# Starting here is early enough: RSpec requires spec_helper (via .rspec) before
# it loads any *_spec.rb, so every load_lic_class call still lies ahead of us.
if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.enable_coverage :eval

  # Only the class/module bodies a spec extracts are ever eval'd, so a script's
  # remaining code -- the before_dying block, the `Klass.new` entry point, a
  # top-level def -- is invisible to Coverage rather than counted as missed,
  # which quietly flatters the percentage. Backfill those lines from SimpleCov's
  # own static line classifier (the same one it uses for files that were never
  # loaded at all) so they land in the denominator as uncovered.
  #
  # Restricted to lines OUTSIDE every range an extractor eval'd. Inside an eval'd
  # range Ruby is authoritative and the static classifier is not: it calls each
  # element line of a multi-line literal relevant, while Ruby attributes the
  # whole literal to one line. Backfilling there invents missed lines for code
  # that demonstrably ran (astrology.lic's OBSERVE_SUCCESS_PATTERNS is the
  # example -- line 73 opens the array, but Ruby records the hit on line 74).
  SimpleCov.at_exit do
    raw = SimpleCov.result.original_result

    raw.each do |filename, data|
      next unless filename.end_with?('.lic')

      static = SimpleCov::SimulateCoverage.call(filename)
      static = static['lines'] || static[:lines] if static.is_a?(Hash)
      next unless static

      evaled = LIC_EVAL_RANGES[filename]
      measured = data['lines'] || data[:lines]
      static.each_index do |i|
        next unless measured[i].nil? && !static[i].nil?
        next if evaled.any? { |range| range.cover?(i) }

        measured[i] = 0
      end
    end

    SimpleCov::Result.new(raw, command_name: SimpleCov.command_name).format!
  end

  SimpleCov.start
end

require 'ostruct'

# Load the test harness, which provides the mock game objects and commons
# command modules listed in the "Shared game doubles" section above.
load File.join(File.dirname(__FILE__), '..', 'test', 'test_harness.rb')

include Harness

# Absolute, symlink-free path to a .lic in the repo root. Expanded rather than
# left as "<root>/spec/../foo.lic" so eval attributes the source to the file's
# real path -- backtraces point at it, and coverage tooling does not mistake it
# for something under spec/.
def lic_path(filename)
  File.expand_path(File.join(__dir__, '..', filename))
end

# Ruby allocates a file's eval-coverage line array on the FIRST eval attributed
# to that filename and never grows it. A .lic holding several classes is eval'd
# once per class, so any class starting past the end of the first-eval'd one
# would be silently dropped from coverage -- not counted as missed, just absent
# (combat-trainer.lic reported 2 of its 11 classes). Priming with a blank eval
# spanning the whole file sizes the array once so every later eval lands inside.
# No-op when coverage is not running.
def prime_lic_coverage(filepath, line_count)
  return unless defined?(Coverage) && Coverage.running?

  @primed_lic_files ||= {}
  return if @primed_lic_files[filepath]

  @primed_lic_files[filepath] = true
  eval(("\n" * (line_count - 1)) + 'nil', TOPLEVEL_BINDING, filepath, 1)
end

# Extract and eval a class from a .lic file without executing the top-level code
# (before_dying blocks, Klass.new, etc.) that sits outside the class body.
#
# Strategy: read the file, extract lines from the `class <ClassName>` opening
# through the matching `end` at column 0, then eval only that slice. The
# const_defined? guard makes repeated calls (across co-running specs) idempotent.
def load_lic_class(filename, class_name)
  return if Object.const_defined?(class_name)

  eval_lic_definition(filename, 'class', class_name)
end

# Module counterpart to load_lic_class, with the same strategy and guard.
# Lived as a duplicated top-level def in automap_spec and moonwatch_spec, which
# is the exact "a duplicate top-level definition wins for the entire process by
# load order" hazard described above -- it belongs here, defined once.
def load_lic_module(filename, module_name)
  return if Object.const_defined?(module_name)

  eval_lic_definition(filename, 'module', module_name)
end

# Evaluates a loaded class's body again, as Lich does every time the script
# starts: Lich evaluates the whole .lic on each start, so the class body runs
# again before the entry point while the class itself (and anything that
# still refers to it, such as a hook of the run before) persists. Pair it
# with run_lic_entry to drive a restart the way Lich runs one.
#
# Methods the body defines replace the ones it defined before, and with them
# any RSpec stub of those methods, which RSpec could then not stub again in
# the same example. So it first ends every RSpec stub on the class, a stub
# made by a before hook included, and an example stubs again, after it, what
# the rest of the example needs stubbed.
#
# @param filename [String] the .lic, relative to the repo root
# @param class_name [String] the class whose body runs again
# @return [Object] what the class body returns
# @raise [RuntimeError] when the class is not loaded yet (use load_lic_class
#   for the first load), or its definition is not found
def reload_lic_class(filename, class_name)
  raise "reload_lic_class: load #{class_name} with load_lic_class before reloading it" unless Object.const_defined?(class_name)

  klass = Object.const_get(class_name)
  RSpec::Mocks.space.proxy_for(klass).reset if RSpec::Mocks.space.registered?(klass)
  eval_lic_definition(filename, 'class', class_name)
end

# Evaluates one column-0 class or module definition of a .lic at its real
# line numbers, recording the range for coverage. Shared by load_lic_class,
# load_lic_module and reload_lic_class.
#
# @param filename [String] the .lic, relative to the repo root
# @param keyword [String] 'class' or 'module'
# @param name [String] the class or module name
# @return [Object] what the definition returns
# @raise [RuntimeError] when the definition or its `end` is not found
def eval_lic_definition(filename, keyword, name)
  filepath = lic_path(filename)
  lines = File.readlines(filepath)
  prime_lic_coverage(filepath, lines.size)

  range = lic_definition_range(lines, keyword, name, filename)
  LIC_EVAL_RANGES[filepath] << range
  eval(lines[range].join, TOPLEVEL_BINDING, filepath, range.begin + 1)
end

# The 0-based, inclusive line range of a column-0 `class Name` / `module Name`
# body: from its opening line through the first column-0 `end` after it.
# Shared by eval_lic_definition and run_lic_entry.
#
# @param lines [Array<String>] the .lic's lines
# @param keyword [String] 'class' or 'module'
# @param name [String] the class or module name
# @param filename [String] the .lic, for the error message
# @return [Range<Integer>] 0-based, inclusive
# @raise [RuntimeError] when the definition or its `end` is not found
def lic_definition_range(lines, keyword, name, filename)
  start_idx = lines.index { |l| l =~ /^#{keyword}\s+#{name}\b/ }
  raise "Could not find '#{keyword} #{name}' in #{filename}" unless start_idx

  end_idx = (start_idx + 1...lines.size).find { |i| lines[i] =~ /^end\s*$/ }
  raise "Could not find matching end for '#{keyword} #{name}' in #{filename}" unless end_idx

  start_idx..end_idx
end

# Run a script's entry point: eval every line after the closing `end` of
# `class <class_name>` (the before_dying block, `Klass.new`, argument parsing
# ...) as the script would run it, so a spec can drive the whole script the
# way a user's `;script args` does, without reaching into its internals.
#
#   load_lic_class('remedy.lic', 'Remedy')
#   expect { run_lic_entry('remedy.lic', 'Remedy') }.to raise_error(SystemExit)
#
# Unlike the loaders it is not idempotent: every call runs the entry again.
# The class must be loaded first (with load_lic_class), so the entry never
# re-evals the class body. The code is eval'd at its real line numbers, so
# backtraces and coverage point at the .lic, in a fresh copy of
# TOPLEVEL_BINDING: `self` is still `main`, but a local the entry assigns (an
# `args = parse_args(...)`) stays inside that run instead of leaking into the
# next one. Same `^end` limitation as the loaders.
#
# @param filename [String] the .lic, relative to the repo root
# @param class_name [String] the class the entry code follows
# @return [Object] what the entry code returns (a script usually exits first)
# @raise [RuntimeError] when the class is not loaded, or no code follows it
# @raise [SystemExit] when the script exits, as most do when they finish
def run_lic_entry(filename, class_name)
  raise "run_lic_entry: load #{class_name} with load_lic_class before running its entry" unless Object.const_defined?(class_name)

  filepath = lic_path(filename)
  lines = File.readlines(filepath)
  prime_lic_coverage(filepath, lines.size)

  first = lic_definition_range(lines, 'class', class_name, filename).end + 1
  raise "run_lic_entry: #{filename} has no code after 'class #{class_name}'" if lines[first..].to_a.all? { |l| l.strip.empty? }

  LIC_EVAL_RANGES[filepath] << (first..lines.size - 1)
  eval(lines[first..].join, TOPLEVEL_BINDING.dup, filepath, first + 1)
end

# Extract and eval a single top-level constant assignment (CONST = ...) from a
# .lic file without executing the rest of the file. The const_defined? guard
# makes repeated calls (across co-running specs) idempotent.
def load_lic_constant(filename, const_name)
  return if Object.const_defined?(const_name)

  filepath = lic_path(filename)
  lines = File.readlines(filepath)
  prime_lic_coverage(filepath, lines.size)

  idx = lines.index { |l| l =~ /^#{const_name}\s*=/ }
  raise "Could not find '#{const_name}' in #{filename}" unless idx

  # Pass the real line number so the eval'd assignment is attributed to where it
  # actually lives, rather than to line 1 of the file.
  LIC_EVAL_RANGES[filepath] << (idx..idx)
  eval(lines[idx], TOPLEVEL_BINDING, filepath, idx + 1)
end

# Extract one or more TOP-LEVEL `def`s from a .lic file without executing the
# rest of the file, and return them wrapped in a fresh anonymous module.
# Counterpart to load_lic_class/module/constant, for the scripts that keep
# behavior in bare top-level defs (some class-less entirely).
#
#   CircleCheck = load_lic_methods('circlecheck.lic', 'clamp_progress', 'progress_bar')
#   CircleCheck.progress_bar(25)   # => "[###-------]"
#
# Each def is eval'd into the module at its real start line (so backtraces and
# coverage attribute correctly). The module `extend self`s, so the script's own
# helpers still resolve each other's bare calls, host/harness methods still fall
# through to Object, and the extracted names never touch the shared Object
# namespace -- so two scripts that each define a generically-named helper (e.g.
# `main`) simply get their own module instead of silently colliding by load
# order. `allow(mod).to receive(:foo)` stubs cleanly, including for sibling calls.
#
# Only column-0 `def`s are matched, so an instance method that happens to share
# a name inside a class earlier in the file is never lifted out by mistake.
#
# Instance-variable state: the returned module is a single object that lives for
# the whole process, so `Mod.foo` runs with `self == Mod` and any @ivar a def
# assigns persists from one example into the next (the global reset_data hook does
# NOT clear it). Harmless for pure / $global-only helpers -- call `Mod.foo` as
# shown above. For a script whose defs read or write @ivars (e.g. heal-remedy.lic,
# jail-buddy.lic, trigger-watcher.lic), `include` the module in the describe block
# instead: the defs are plain instance methods, so they then run on the
# per-example RSpec instance -- `before { @ivar = ... }` reaches them and each
# example stays isolated for free.
#
# Limitations shared with the class/module extractors: the `^end` scan is
# defeated by a heredoc or string literal containing `end` at column 0, and a
# one-line or endless def (`def x; 1; end` / `def x = 1`) has no `^end` of its
# own -- both are caught by the single-def slice guard below, which raises rather
# than silently swallowing a neighbouring def.
def load_lic_methods(filename, *method_names)
  filepath = lic_path(filename)
  lines = File.readlines(filepath)
  prime_lic_coverage(filepath, lines.size)

  mod = Module.new
  mod.extend(mod) # ancestor-based, so it covers defs added afterwards too

  method_names.each do |method_name|
    # Column-0 anchor: these are top-level defs. Anchor the end of the name so
    # `foo` matches neither `foobar` nor `foo?` -- it must be followed by
    # whitespace, `(`, `;`, or end-of-line.
    start_idx = lines.index { |l| l =~ /^def\s+#{Regexp.escape(method_name)}(?=[\s(;]|$)/ }
    raise "Could not find top-level 'def #{method_name}' in #{filename}" unless start_idx

    rel_end = lines[(start_idx + 1)..].index { |l| l =~ /^end\s*$/ }
    raise "Could not find matching 'end' for 'def #{method_name}' in #{filename}" unless rel_end

    end_idx = start_idx + 1 + rel_end
    slice = lines[start_idx..end_idx]

    # A one-line/endless def has no `^end` of its own, so the scan above runs on
    # to a later def's `end` and would silently pull that sibling in too. Refuse.
    defs = slice.count { |l| l =~ /^def\s/ }
    raise "Extraction of 'def #{method_name}' from #{filename} spans #{defs} " \
          'top-level defs; rewrite it as a multi-line def' unless defs == 1

    LIC_EVAL_RANGES[filepath] << (start_idx..end_idx)
    mod.module_eval(slice.join, filepath, start_idx + 1)
  end

  mod
end

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end

  # RSpec rescues everything an example raises except SystemExit (and signals
  # and NoMemoryError: rspec-support AVOID_RESCUING),
  # so code under test that calls exit (or abort) would end the whole process
  # here: the examples after it never run, and the process leaves with the
  # exit's status (0 for a bare exit, even when earlier examples failed), so a
  # truncated run reads as green. Re-raise it as an ordinary error,
  # which RSpec records as this example's failure; the SystemExit stays
  # attached as the cause, so the report shows where exit was called. An
  # example that asserts its exit with raise_error(SystemExit) catches it
  # itself and never gets here.
  config.around(:each) do |example|
    example.run
  rescue SystemExit => e
    raise "the code under test called exit (status #{e.status}), which would end the whole " \
          'rspec run here; assert it with expect { ... }.to raise_error(SystemExit), or stub exit'
  end
end
