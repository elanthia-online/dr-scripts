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
#     Lich runtime. Extract constants and methods via eval of specific line ranges
#     (see load_lic_class below and dependency_spec.rb for the method-level pattern).
#   - Mock only what you need: UserVars, Settings, Script.current, _respond, etc.
#   - Use the test harness (test/test_harness.rb) for specs that need game objects.
#
# Shared setup:
#   - This file is loaded before every spec via .rspec (--require spec_helper). It
#     loads the test harness, includes Harness at the top level, provides the
#     load_lic_class extraction helper, and registers the single global
#     before(:each) { reset_data } hook.
#   - Registering reset_data here (rather than in individual specs via
#     RSpec.configure) is deliberate: config-level before hooks registered while a
#     spec file loads run AFTER that spec's own group-level before hooks. A
#     per-spec global reset_data would therefore run last and clobber the
#     per-example world (guild, settings, hands, room) that other specs set up in
#     their own before blocks. Because spec_helper is required first, its hook
#     registers first and always runs before every group hook.

require 'ostruct'

# Load the test harness which provides mock game objects:
# Flags, DRStats, DRSkill, DRRoom, Room, Map, GameObj, Script, XMLData, etc.
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

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end
end
