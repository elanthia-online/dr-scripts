# frozen_string_literal: true

# Test suite for circlecheck.lic
#
# circlecheck.lic is class-less: it holds its behavior in top-level defs and has
# no class or module for load_lic_class to grab. The pure helpers below are
# extracted with load_lic_method (spec_helper.rb) without running the script's
# top-level `main`, which needs the full Lich runtime (parse_args, get_settings,
# DRStats).

load_lic_method('circlecheck.lic', 'clamp_progress')
load_lic_method('circlecheck.lic', 'progress_bar')

RSpec.describe 'circlecheck.lic helpers' do
  describe '#clamp_progress' do
    it 'returns gained ranks past the current baseline and the gap to target' do
      # baseline 100, target 150 => gap 50; player at 120 => gained 20
      expect(clamp_progress(120, 100, 150)).to eq([20, 50])
    end

    it 'floors gained at 0 when the player is below the current baseline' do
      expect(clamp_progress(80, 100, 150)).to eq([0, 50])
    end

    it 'caps gained at the gap when the player is past the target' do
      expect(clamp_progress(200, 100, 150)).to eq([50, 50])
    end

    it 'floors the gap at 0 when the target is below the current baseline' do
      expect(clamp_progress(120, 100, 90)).to eq([0, 0])
    end

    it 'returns zeros when already exactly at the baseline and target' do
      expect(clamp_progress(100, 100, 100)).to eq([0, 0])
    end
  end

  describe '#progress_bar' do
    it 'renders an empty bar at 0 percent' do
      expect(progress_bar(0)).to eq("[#{'-' * 10}]")
    end

    it 'renders a full bar at 100 percent' do
      expect(progress_bar(100)).to eq("[#{'#' * 10}]")
    end

    it 'rounds partial progress to the nearest cell' do
      # 25% of 10 cells => 2.5 => rounds to 3 (Float#round is round-half-up)
      expect(progress_bar(25)).to eq("[####{'-' * 7}]")
    end

    it 'clamps percentages below 0 to an empty bar' do
      expect(progress_bar(-20)).to eq("[#{'-' * 10}]")
    end

    it 'clamps percentages above 100 to a full bar' do
      expect(progress_bar(150)).to eq("[#{'#' * 10}]")
    end

    it 'honors a custom width' do
      expect(progress_bar(50, 4)).to eq('[##--]')
    end
  end
end
