# frozen_string_literal: true

require 'yaml'

require_relative 'spec_helper'

# Structural-integrity specs for data/base-hunting.yaml, guarding the cleanup in
# this PR and the two bug classes it fixes.
#
# 1. Dangling town references. `hunting_areas_by_town` is a per-town menu of zone
#    NAMES; every name must resolve to a zone defined in `hunting_zones`
#    (name -> [room_ids]) or `escort_zones` (name -> {base,area,enter}), or it
#    silently resolves to nothing at runtime (hunting-buddy#find_hunting_room?).
#    Four names had drifted: velaka_slaver/zombie_nomad/razortuzk_boars were
#    singular/misspelled variants of real zones, and
#    hulking_black_barghest_riverhaven was never defined (dead menu entry removed;
#    tracked as a follow-up to map Ceceline's Meadow and re-add it).
#
# 2. A YAML indentation slip folded a whole zone into another zone's room list.
#    `snarlvine_fox` was written as `- snarlvine_fox:` (a list ITEM whose value is
#    a mapping) inside the `sky_giants` list instead of as its own sibling key, so
#    Psych parsed sky_giants as [..ints.., {"snarlvine_fox"=>nil}, 51876..51879]:
#    snarlvine_fox was undiscoverable and its four rooms were misattributed to
#    sky_giants, and sky_giants held a Hash where room-id code expects Integers.
#
# These specs assert the file-wide invariants (all now hold) plus the specific
# snarlvine_fox/sky_giants regression, so a future edit that reintroduces either
# bug class fails loudly.
#
# YAML is loaded permissively (YAML.unsafe_load_file) to match how Lich loads it
# at runtime -- base-hunting.yaml uses YAML aliases, which Psych 4+ rejects under
# a safe load. Specs run from the repo root, so the relative path resolves.
RSpec.describe 'data/base-hunting.yaml integrity' do
  let(:data)          { YAML.unsafe_load_file('data/base-hunting.yaml') }
  let(:escort_zones)  { data.fetch('escort_zones') }
  let(:hunting_zones) { data.fetch('hunting_zones') }
  let(:towns)         { data.fetch('hunting_areas_by_town') }
  # Every zone the game can actually route to: escort (via bescort) or go2 rooms.
  let(:defined_zones) { escort_zones.keys + hunting_zones.keys }

  it 'parses as valid YAML' do
    expect(data).to be_a(Hash)
  end

  describe 'town menus (hunting_areas_by_town)' do
    it 'reference only zones defined in hunting_zones or escort_zones' do
      referenced = towns.values.flatten.compact.uniq
      unresolved = referenced.reject { |zone| defined_zones.include?(zone) }

      expect(unresolved).to eq([]), "dangling town references (defined nowhere): #{unresolved.inspect}"
    end
  end

  describe 'hunting_zones' do
    it 'maps every zone to a non-empty list of positive integer room ids' do
      malformed = hunting_zones.reject do |_name, rooms|
        rooms.is_a?(Array) && !rooms.empty? && rooms.all? { |room| room.is_a?(Integer) && room.positive? }
      end

      expect(malformed.keys).to eq([]), "malformed hunting_zones room lists: #{malformed.keys.inspect}"
    end

    it 'never shares a name with escort_zones (escort takes precedence at runtime)' do
      expect(escort_zones.keys & hunting_zones.keys).to eq([])
    end
  end

  # Regression for the "- snarlvine_fox:" indentation fold into sky_giants.
  describe 'snarlvine_fox' do
    it 'is its own zone with exactly its four rooms' do
      expect(hunting_zones['snarlvine_fox']).to eq([51876, 51877, 51878, 51879])
    end

    it 'is not swallowed into sky_giants, which stays pure room-id integers' do
      expect(hunting_zones['sky_giants']).to all(be_a(Integer))
      expect(hunting_zones['sky_giants']).not_to include(51876, 51877, 51878, 51879)
    end
  end
end
