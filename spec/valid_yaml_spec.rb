# frozen_string_literal: true

require 'yaml'

require_relative 'spec_helper'

# Validates the repo's own profile YAML. Ported from the retired minitest suite
# (test/test_valid_yaml.rb); this was the one test in that suite still worth
# keeping, and it now rides the maintained rspec suite so it actually runs in CI
# (see #7503). It is what would have caught the invalid profile in #7502.
#
# YAML is loaded the way Lich loads it -- permissively. The profiles use
# !ruby/regexp tags and aliases, both of which Psych 4+ rejects under a safe
# load (YAML.load_file), so we use YAML.unsafe_load_file to match runtime.
#
# Note: the retired suite also had a "every non-base setting is declared in
# base.yaml" check, but it globbed the non-recursive profiles/*.yaml and so went
# vacuous once the character profiles moved under profiles/Samples/. It is left
# out here rather than half-revived; it can be rebuilt against profiles/Samples/
# as a follow-up if that lint is still wanted.
RSpec.describe 'profile YAML' do
  it 'loads and parses every YAML file under profiles/' do
    files = Dir.glob('profiles/**/*.yaml')
    expect(files).not_to be_empty, 'Expected to find at least one profile YAML file'

    failures = files.reject do |file|
      YAML.unsafe_load_file(file)
      true
    rescue StandardError => e
      warn "Failed to parse #{file}: #{e.class}: #{e.message}"
      false
    end

    expect(failures).to eq([]), "Expected all profile YAML to parse, but these failed: #{failures.inspect}"
  end
end
