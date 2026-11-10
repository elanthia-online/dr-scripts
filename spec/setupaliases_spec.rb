# frozen_string_literal: true

require 'prism'

require_relative 'spec_helper'

# setupaliases.lic is class-less: the whole script is top-level code that sends
# one ";alias add --global <trigger> = <target>" per alias through
# UpstreamHook.run. These specs run the real file in a fresh object and read
# back what it sent, so they check the aliases a player actually gets.
#
# What they cannot check offline: that a ;e target's methods exist in the live
# Lich runtime, or that ;lich5-update accepts the options given. Those were
# verified against lich-5 and the scripts repo when the targets were written.
RSpec.describe 'setupaliases.lic' do
  let(:sent) { [] }
  let(:existing_scripts) { [] }

  # dependency.lic helpers the old das/ds/dad/mme aliases called. #7407 deleted
  # them when their logic moved into core Lich, so an alias calling one only
  # prints a NameError.
  let(:removed_dependency_helpers) { %w[force_refresh_scripts get_script setup_data make_map_edits] }

  around do |example|
    saved_char = $clean_lich_char
    $clean_lich_char = ';'
    example.run
  ensure
    $clean_lich_char = saved_char
  end

  before do
    allow(UpstreamHook).to receive(:run) { |command| sent << command }
    allow(Script).to receive(:exists?) { |name| existing_scripts.include?(name) }
  end

  def run_script
    path = lic_path('setupaliases.lic')
    Object.new.instance_eval(File.read(path), path, 1)
  end

  # trigger => target, parsed from what the script sent. Fails the example if
  # any command is not a global alias add.
  def aliases
    sent.to_h do |command|
      match = command.match(/\A<c>;alias add --global (\S+) = (.+)\z/m)
      raise "not a global alias add: #{command.inspect}" unless match

      [match[1], match[2]]
    end
  end

  # The Ruby source a ;e or ;eq target runs, with the alias argument placeholder
  # filled in the way alias.lic does when the player types an argument.
  def ruby_source(target, argument: '1')
    target.sub(/\A;eq? /, '').gsub('\\?', argument)
  end

  describe 'every alias' do
    before { run_script }

    it 'is sent once, as a global alias add' do
      expect(sent.length).to eq(aliases.length)
    end

    it 'never calls a dependency.lic helper that #7407 removed' do
      offenders = aliases.select do |_trigger, target|
        removed_dependency_helpers.any? { |helper| target.match?(/\b#{helper}\b/) }
      end

      expect(offenders).to be_empty
    end

    it 'runs Ruby that parses when its target is ;e or ;eq' do
      unparsable = aliases.select { |_trigger, target| target.match?(/\A;eq? /) }
                          .reject { |_trigger, target| Prism.parse(ruby_source(target)).success? }

      expect(unparsable).to be_empty
    end
  end

  describe 'the script update aliases' do
    before { run_script }

    it 'das syncs the dr-scripts repo through core lich5-update' do
      expect(aliases['das']).to eq(';lich5-update --sync=dr-scripts')
    end

    it 'dad runs the same dr-scripts sync, because core has no data-only sync' do
      expect(aliases['dad']).to eq(aliases['das'])
    end

    # Without the repo prefix, --script= fetches from the core scripts repo,
    # and it rejects names without .lic, so both are added here.
    it 'ds updates one named dr-scripts script, adding the .lic suffix' do
      expect(aliases['ds']).to eq(';lich5-update --script=dr-scripts:\\?.lic')
    end
  end

  describe 'the map override alias' do
    before { run_script }

    it 'mme reapplies personal map overrides through core Map.apply_wayto_overrides' do
      expect(aliases['mme']).to eq(';eq Map.apply_wayto_overrides')
    end
  end

  describe 'the map alias' do
    it 'starts ;map when the map script exists' do
      existing_scripts.push('map', 'xnarost')
      run_script

      expect(aliases['map']).to eq(';map')
    end

    it 'falls back to ;xnarost when only xnarost exists' do
      existing_scripts.push('xnarost')
      run_script

      expect(aliases['map']).to eq(';xnarost')
    end

    it 'is not added when neither map script exists' do
      run_script

      expect(aliases).not_to have_key('map')
    end
  end
end
