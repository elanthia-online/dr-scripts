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
#   - UserVars is the deliberate exception: it is per-script configuration (each
#     script reads different keys with script-specific meanings), so stub it
#     per-spec, not in the harness.
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

require 'ostruct'

# Load the test harness, which provides the mock game objects and commons
# command modules listed in the "Shared game doubles" section above.
load File.join(File.dirname(__FILE__), '..', 'test', 'test_harness.rb')

include Harness

# Extract and eval a class from a .lic file without executing the top-level code
# (before_dying blocks, Klass.new, etc.) that sits outside the class body.
#
# Strategy: read the file, extract lines from the `class <ClassName>` opening
# through the matching `end` at column 0, then eval only that slice. The
# const_defined? guard makes repeated calls (across co-running specs) idempotent.
def load_lic_class(filename, class_name)
  return if Object.const_defined?(class_name)

  filepath = File.join(File.dirname(__FILE__), '..', filename)
  lines = File.readlines(filepath)

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
  eval(class_source, TOPLEVEL_BINDING, filepath, start_idx + 1)
end

# Extract and eval a single top-level constant assignment (CONST = ...) from a
# .lic file without executing the rest of the file. The const_defined? guard
# makes repeated calls (across co-running specs) idempotent.
def load_lic_constant(filename, const_name)
  return if Object.const_defined?(const_name)

  filepath = File.join(File.dirname(__FILE__), '..', filename)
  lines = File.readlines(filepath)

  line = lines.find { |l| l =~ /^#{const_name}\s*=/ }
  raise "Could not find '#{const_name}' in #{filename}" unless line

  eval(line, TOPLEVEL_BINDING, filepath)
end

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end
end
