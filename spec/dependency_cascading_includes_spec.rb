# frozen_string_literal: true

require 'ostruct'
require 'yaml'
require 'monitor'
require 'fileutils'
require 'tmpdir'

# Test suite for dependency.lic cascading includes feature (v2.1.0)
#
# This tests the resolve_includes_recursively method's logic for resolving
# nested include files with depth-first resolution and circular dependency protection.
#
# Rather than trying to eval the complex SetupFiles class with all its dependencies,
# we test the core algorithm in isolation with a minimal mock.

# Minimal mock that replicates the resolve_includes_recursively behavior
# This allows us to test the algorithm without SetupFiles's complex dependencies
class IncludeResolver
  attr_reader :files, :loaded_files, :debug

  def initialize(files = {}, debug: false)
    @files = files # Map of filename => { include: [...], ...settings }
    @loaded_files = []
    @debug = debug
  end

  # Simulates reload_profiles - just tracks that a file was "loaded"
  def reload_profiles(filenames)
    filenames.each { |f| @loaded_files << f unless @loaded_files.include?(f) }
  end

  # Simulates cache_get_by_filename - returns FileInfo-like object
  def cache_get_by_filename(filename)
    return nil unless @files.key?(filename)

    data = @files[filename]
    OpenStruct.new(
      name: filename,
      data: data,
      peek: ->(prop) { data[prop.to_sym] || data[prop.to_s] }
    )
  end

  def to_include_filename(suffix)
    "include-#{suffix}.yaml"
  end

  def echo(msg)
    puts msg if @debug
  end

  # The actual algorithm under test - copied from dependency.lic
  def resolve_includes_recursively(filenames, visited = Set.new, include_order = [])
    filenames.each do |filename|
      # Circular dependency protection - skip already visited files
      next if visited.include?(filename)

      visited << filename
      # Load this include file into cache
      reload_profiles([filename])
      file_info = cache_get_by_filename(filename)
      next unless file_info

      # Get nested includes from this file
      nested_suffixes = file_info.peek.call('include') || []
      echo "#{filename} has nested includes: #{nested_suffixes}" if @debug && !nested_suffixes.empty?
      nested_filenames = nested_suffixes.map { |suffix| to_include_filename(suffix) }

      # Depth-first: resolve nested includes BEFORE adding this file
      # This ensures dependencies are merged before dependents
      resolve_includes_recursively(nested_filenames, visited, include_order)

      include_order << filename
    end
    include_order
  end
end

RSpec.describe 'Cascading Includes Algorithm' do
  describe '#resolve_includes_recursively' do
    context 'with no includes' do
      it 'returns empty array when no include files specified' do
        resolver = IncludeResolver.new({})
        result = resolver.resolve_includes_recursively([])
        expect(result).to eq([])
      end
    end

    context 'with single-level includes (backwards compatibility)' do
      let(:files) do
        {
          'include-hunting.yaml' => { hunting_zones: ['zone1', 'zone2'] }
        }
      end

      it 'resolves single-level includes correctly' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-hunting.yaml'])
        expect(result).to eq(['include-hunting.yaml'])
      end
    end

    context 'with two-level cascading includes' do
      let(:files) do
        {
          'include-hunting.yaml' => { include: ['combat'], hunting_zones: ['zone1'] },
          'include-combat.yaml'  => { combat_style: 'aggressive' }
        }
      end

      it 'resolves nested includes depth-first' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-hunting.yaml'])
        # combat should come before hunting (depth-first)
        expect(result).to eq(['include-combat.yaml', 'include-hunting.yaml'])
      end
    end

    context 'with three-level cascading includes' do
      let(:files) do
        {
          'include-hunting.yaml' => { include: ['combat'], hunting_zones: ['zone1'] },
          'include-combat.yaml'  => { include: ['weapons'], combat_style: 'aggressive' },
          'include-weapons.yaml' => { primary_weapon: 'sword' }
        }
      end

      it 'resolves three levels depth-first' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-hunting.yaml'])
        # weapons -> combat -> hunting (deepest first)
        expect(result).to eq(['include-weapons.yaml', 'include-combat.yaml', 'include-hunting.yaml'])
      end
    end

    context 'with sibling includes at same level' do
      let(:files) do
        {
          'include-hunting.yaml'  => { include: ['combat', 'survival'], hunting_zones: ['zone1'] },
          'include-combat.yaml'   => { combat_style: 'aggressive' },
          'include-survival.yaml' => { survival_skill: 'evasion' }
        }
      end

      it 'resolves siblings in order, depth-first' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-hunting.yaml'])
        # combat then survival (sibling order), then hunting
        expect(result).to eq(['include-combat.yaml', 'include-survival.yaml', 'include-hunting.yaml'])
      end
    end

    context 'with diamond dependency pattern' do
      let(:files) do
        {
          #        character (not in this test)
          #        /      \
          #    hunting  crafting
          #        \      /
          #         common
          'include-hunting.yaml'  => { include: ['common'], hunting_zones: ['zone1'] },
          'include-crafting.yaml' => { include: ['common'], crafting_type: 'forging' },
          'include-common.yaml'   => { safe_room: 1234 }
        }
      end

      it 'resolves diamond pattern without duplicates' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-hunting.yaml', 'include-crafting.yaml'])
        # common should appear only once (first encounter via hunting)
        expect(result).to eq(['include-common.yaml', 'include-hunting.yaml', 'include-crafting.yaml'])
        expect(result.count('include-common.yaml')).to eq(1)
      end
    end

    context 'with circular dependency' do
      let(:files) do
        {
          'include-circular-a.yaml' => { include: ['circular-b'], setting_a: 'value_a' },
          'include-circular-b.yaml' => { include: ['circular-a'], setting_b: 'value_b' }
        }
      end

      it 'handles circular dependency without infinite loop' do
        resolver = IncludeResolver.new(files)
        # Should complete without hanging
        result = resolver.resolve_includes_recursively(['include-circular-a.yaml'])
        # b is resolved before a (depth-first), circular reference to a is skipped
        expect(result).to eq(['include-circular-b.yaml', 'include-circular-a.yaml'])
      end
    end

    context 'with self-referencing include' do
      let(:files) do
        {
          'include-self-ref.yaml' => { include: ['self-ref'], setting_self: 'value_self' }
        }
      end

      it 'handles self-reference without infinite loop' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-self-ref.yaml'])
        # Should only appear once
        expect(result).to eq(['include-self-ref.yaml'])
      end
    end

    context 'with missing include file' do
      let(:files) do
        {
          'include-exists.yaml' => { existing_setting: 'value' }
          # include-missing.yaml does NOT exist
        }
      end

      it 'skips missing files gracefully' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-exists.yaml', 'include-missing.yaml'])
        # Only the existing file should be in the result
        expect(result).to eq(['include-exists.yaml'])
      end
    end

    context 'with include file having empty include array' do
      let(:files) do
        {
          'include-empty-includes.yaml' => { include: [], some_setting: 'value' }
        }
      end

      it 'handles empty include arrays' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-empty-includes.yaml'])
        expect(result).to eq(['include-empty-includes.yaml'])
      end
    end

    context 'with include file having nil/missing include key' do
      let(:files) do
        {
          'include-nil-includes.yaml' => { some_setting: 'value' } # No 'include' key
        }
      end

      it 'handles missing include key (nil)' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-nil-includes.yaml'])
        expect(result).to eq(['include-nil-includes.yaml'])
      end
    end

    context 'with deeply nested includes (stress test)' do
      let(:files) do
        # Create a chain of 10 nested includes
        (1..10).each_with_object({}) do |level, hash|
          next_include = level < 10 ? ["level-#{level + 1}"] : []
          hash["include-level-#{level}.yaml"] = {
            include: next_include,
            "setting_#{level}": "value_#{level}"
          }
        end
      end

      it 'handles deeply nested includes' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-level-1.yaml'])

        # All 10 levels should be loaded
        expect(result.length).to eq(10)
      end

      it 'resolves in correct depth-first order' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-level-1.yaml'])

        # Deepest first: level-10, level-9, ..., level-1
        expected = (1..10).to_a.reverse.map { |n| "include-level-#{n}.yaml" }
        expect(result).to eq(expected)
      end
    end

    context 'complex real-world scenario' do
      let(:files) do
        {
          # Character -> [guild, hometown] -> [common]
          # where guild also includes class-specific settings
          'include-moon-mage.yaml'  => {
            include: ['magic-user', 'common'],
            guild: 'Moon Mage',
            cambrinth: 'moon-staff'
          },
          'include-crossing.yaml'   => {
            include: ['common'],
            hometown: 'Crossing',
            safe_room: 1234
          },
          'include-magic-user.yaml' => {
            include: ['common'],
            train_magic: true
          },
          'include-common.yaml'     => {
            loot_coins: true,
            safe_room: 9999 # This should be overridden by crossing
          }
        }
      end

      it 'resolves complex hierarchy correctly' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-moon-mage.yaml', 'include-crossing.yaml'])

        # Expected order (depth-first):
        # 1. common (via magic-user via moon-mage)
        # 2. magic-user (via moon-mage)
        # 3. moon-mage
        # 4. crossing (common already visited, skipped)
        expect(result).to eq([
                               'include-common.yaml',
                               'include-magic-user.yaml',
                               'include-moon-mage.yaml',
                               'include-crossing.yaml'
                             ])
      end

      it 'common is only loaded once despite multiple references' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-moon-mage.yaml', 'include-crossing.yaml'])

        # common should appear only once
        expect(result.count('include-common.yaml')).to eq(1)

        # Total unique files
        expect(result.uniq.length).to eq(result.length)
      end
    end

    context 'multiple initial includes with shared dependencies' do
      let(:files) do
        {
          'include-hunting.yaml'   => { include: ['weapons', 'armor'] },
          'include-crafting.yaml'  => { include: ['tools', 'armor'] },
          'include-weapons.yaml'   => { include: ['materials'] },
          'include-tools.yaml'     => { include: ['materials'] },
          'include-armor.yaml'     => {},
          'include-materials.yaml' => {}
        }
      end

      it 'resolves shared dependencies correctly' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-hunting.yaml', 'include-crafting.yaml'])

        # Each file should appear exactly once
        expect(result.uniq.length).to eq(result.length)

        # All files should be present
        expect(result).to include('include-hunting.yaml')
        expect(result).to include('include-crafting.yaml')
        expect(result).to include('include-weapons.yaml')
        expect(result).to include('include-tools.yaml')
        expect(result).to include('include-armor.yaml')
        expect(result).to include('include-materials.yaml')
      end

      it 'maintains depth-first order' do
        resolver = IncludeResolver.new(files)
        result = resolver.resolve_includes_recursively(['include-hunting.yaml', 'include-crafting.yaml'])

        # materials should come before weapons (depth-first via hunting)
        expect(result.index('include-materials.yaml')).to be < result.index('include-weapons.yaml')

        # weapons should come before hunting
        expect(result.index('include-weapons.yaml')).to be < result.index('include-hunting.yaml')

        # hunting should come before crafting (processing order)
        expect(result.index('include-hunting.yaml')).to be < result.index('include-crafting.yaml')
      end
    end
  end

  describe 'merge order verification' do
    # These tests verify that the include order produces correct merge results
    # when used with Ruby's Hash#merge

    context 'setting override precedence' do
      let(:files) do
        {
          'include-level2.yaml' => { shared: 'from_level2', level2_only: 'l2' },
          'include-level1.yaml' => { include: ['level2'], shared: 'from_level1', level1_only: 'l1' }
        }
      end

      it 'shallower include overrides deeper include' do
        resolver = IncludeResolver.new(files)
        order = resolver.resolve_includes_recursively(['include-level1.yaml'])

        # Simulate the merge
        merged = order.reduce({}) do |result, filename|
          data = files[filename] || {}
          result.merge(data.reject { |k, _| k == :include })
        end

        # level1 merges after level2, so level1 wins
        expect(merged[:shared]).to eq('from_level1')
        expect(merged[:level1_only]).to eq('l1')
        expect(merged[:level2_only]).to eq('l2')
      end
    end
  end
end
