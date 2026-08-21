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
#     Lich runtime. Extract the class or a single constant via eval of specific
#     line ranges with load_lic_class / load_lic_constant (defined below; see
#     dependency_spec.rb for the method-level extraction pattern).
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
#     A stray unwrapped exit terminates the whole run, not just the example.
#
# Shared setup / why reset_data lives here (do not move it):
#   - This file is loaded before every spec via .rspec (--require spec_helper). It
#     loads the test harness, includes Harness at the top level, provides the
#     load_lic_class / load_lic_constant extraction helpers, and registers the
#     single global before(:each) { reset_data } hook.
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
  SimpleCov.enable_coverage :branch

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

  filepath = lic_path(filename)
  lines = File.readlines(filepath)
  prime_lic_coverage(filepath, lines.size)

  start_idx = lines.index { |l| l =~ /^class\s+#{class_name}\b/ }
  raise "Could not find 'class #{class_name}' in #{filename}" unless start_idx

  end_idx = nil
  (start_idx + 1...lines.size).each do |i|
    if lines[i] =~ /^end\s*$/
      end_idx = i
      break
    end
  end
  raise "Could not find matching end for 'class #{class_name}' in #{filename}" unless end_idx

  class_source = lines[start_idx..end_idx].join
  LIC_EVAL_RANGES[filepath] << (start_idx..end_idx)
  eval(class_source, TOPLEVEL_BINDING, filepath, start_idx + 1)
end

# Module counterpart to load_lic_class, with the same strategy and guard.
# Lived as a duplicated top-level def in automap_spec and moonwatch_spec, which
# is the exact "a duplicate top-level definition wins for the entire process by
# load order" hazard described above -- it belongs here, defined once.
def load_lic_module(filename, module_name)
  return if Object.const_defined?(module_name)

  filepath = lic_path(filename)
  lines = File.readlines(filepath)
  prime_lic_coverage(filepath, lines.size)

  start_idx = lines.index { |l| l =~ /^module\s+#{module_name}\b/ }
  raise "Could not find 'module #{module_name}' in #{filename}" unless start_idx

  end_idx = (start_idx + 1...lines.size).find { |i| lines[i] =~ /^end\s*$/ }
  raise "Could not find matching end for 'module #{module_name}' in #{filename}" unless end_idx

  LIC_EVAL_RANGES[filepath] << (start_idx..end_idx)
  eval(lines[start_idx..end_idx].join, TOPLEVEL_BINDING, filepath, start_idx + 1)
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

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end
end
