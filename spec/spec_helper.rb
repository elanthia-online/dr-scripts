require 'ostruct'

# Load the test harness which provides mock game objects:
# Flags, DRStats, DRSkill, DRRoom, Room, Map, GameObj, etc.
load File.join(File.dirname(__FILE__), '..', 'test', 'test_harness.rb')

include Harness

# Load SigilHarvest class definition without executing the top-level code
# (before_dying block and SigilHarvest.new) at the bottom of the .lic file.
#
# Strategy: read the file, extract lines from the `class SigilHarvest` opening
# through the matching `end` at column 0, then eval only that slice.
def load_lic_class(filename, class_name)
  return if Object.const_defined?(class_name)

  filepath = File.join(File.dirname(__FILE__), '..', filename)
  lines = File.readlines(filepath)

  start_idx = lines.index { |l| l =~ /^class\s+#{class_name}\b/ }
  raise "Could not find 'class #{class_name}' in #{filename}" unless start_idx

  # Find the matching end: first line after start that is exactly "end" at column 0
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

load_lic_class('sigilharvest.lic', 'SigilHarvest')

RSpec.configure do |config|
  config.before(:each) do
    reset_data
  end
end
