# frozen_string_literal: true

require 'ostruct'

load File.join(File.dirname(__FILE__), '..', 'test', 'test_harness.rb')
include Harness

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

def load_lic_constant(filename, const_name)
  return if Object.const_defined?(const_name)

  filepath = File.join(File.dirname(__FILE__), '..', filename)
  lines = File.readlines(filepath)

  line = lines.find { |l| l =~ /^#{const_name}\s*=/ }
  raise "Could not find '#{const_name}' in #{filename}" unless line

  eval(line, TOPLEVEL_BINDING, filepath)
end

module DRC
  class << self
    def bput(*_args); end
    def message(_msg); end
  end
end unless defined?(DRC)

module Lich
  module Common
    class ArgParser
      def parse_args(*_args)
        OpenStruct.new
      end
    end
  end
end unless defined?(Lich::Common::ArgParser)

def get_settings(*)
  {}
end unless defined?(get_settings)

module DRCA
  class << self
    def cast_spell(*_args); end
  end
end unless defined?(DRCA)

class UserVars
  @@_data = {}

  def self._reset
    @@_data = {}
  end

  def self.researcher
    @@_data['researcher']
  end

  def self.researcher=(val)
    @@_data['researcher'] = val
  end
end unless defined?(UserVars)

load_lic_constant('researcher.lic', 'VALID_RESEARCH_TOPICS')
load_lic_class('researcher.lic', 'Researcher')

RSpec.describe Researcher do
  before(:each) do
    reset_data
    UserVars._reset
    UserVars.researcher = {}
  end
  let(:researcher) { Researcher.allocate }
  let(:settings) { {} }

  before(:each) do
    researcher.instance_variable_set(:@settings, settings)
    researcher.instance_variable_set(:@debug, false)
    researcher.instance_variable_set(:@current_topic, nil)
    allow(researcher).to receive(:exit)
    allow(researcher).to receive(:echo)
    allow(researcher).to receive(:fput)
    allow(researcher).to receive(:pause)
  end

  # ---------------------------------------------------------------------------
  # validate_research_topic
  # ---------------------------------------------------------------------------
  describe '#validate_research_topic' do
    VALID_RESEARCH_TOPICS.each do |topic|
      it "accepts valid topic '#{topic}'" do
        researcher.instance_variable_set(:@current_topic, topic)
        researcher.send(:validate_research_topic)
        expect(researcher).not_to have_received(:exit)
      end
    end

    it 'normalizes uppercase topic to lowercase' do
      researcher.instance_variable_set(:@current_topic, 'AUGMENTATION')
      researcher.send(:validate_research_topic)
      expect(researcher.instance_variable_get(:@current_topic)).to eq('augmentation')
      expect(researcher).not_to have_received(:exit)
    end

    it 'normalizes mixed-case topic' do
      researcher.instance_variable_set(:@current_topic, 'FuNdAmEnTaL')
      researcher.send(:validate_research_topic)
      expect(researcher.instance_variable_get(:@current_topic)).to eq('fundamental')
      expect(researcher).not_to have_received(:exit)
    end

    it "normalizes 'attunement' to 'stream'" do
      researcher.instance_variable_set(:@current_topic, 'attunement')
      researcher.send(:validate_research_topic)
      expect(researcher.instance_variable_get(:@current_topic)).to eq('stream')
      expect(researcher).not_to have_received(:exit)
    end

    it "normalizes 'Attunement' (capitalized) to 'stream'" do
      researcher.instance_variable_set(:@current_topic, 'Attunement')
      researcher.send(:validate_research_topic)
      expect(researcher.instance_variable_get(:@current_topic)).to eq('stream')
      expect(researcher).not_to have_received(:exit)
    end

    it "normalizes 'ATTUNEMENT' (uppercase) to 'stream'" do
      researcher.instance_variable_set(:@current_topic, 'ATTUNEMENT')
      researcher.send(:validate_research_topic)
      expect(researcher.instance_variable_get(:@current_topic)).to eq('stream')
    end

    it 'skips validation for symbiosis topics' do
      researcher.instance_variable_set(:@current_topic, 'symbiosis activate')
      researcher.send(:validate_research_topic)
      expect(researcher.instance_variable_get(:@current_topic)).to eq('symbiosis activate')
      expect(researcher).not_to have_received(:exit)
    end

    it 'skips validation for symbiosis with any type' do
      researcher.instance_variable_set(:@current_topic, 'symbiosis xyzgarbage')
      researcher.send(:validate_research_topic)
      expect(researcher).not_to have_received(:exit)
    end

    it 'exits on invalid topic' do
      allow(DRC).to receive(:message)
      researcher.instance_variable_set(:@current_topic, 'alchemy')
      researcher.send(:validate_research_topic)
      expect(researcher).to have_received(:exit)
    end

    it 'displays error messages for invalid topic' do
      allow(DRC).to receive(:message)
      researcher.instance_variable_set(:@current_topic, 'alchemy')
      researcher.send(:validate_research_topic)
      expect(DRC).to have_received(:message).with(/Invalid research topic: alchemy/)
      expect(DRC).to have_received(:message).with(/Valid topics are:/)
    end

    it 'exits on empty string topic' do
      allow(DRC).to receive(:message)
      researcher.instance_variable_set(:@current_topic, '')
      researcher.send(:validate_research_topic)
      expect(researcher).to have_received(:exit)
    end

    it 'exits on nil topic' do
      allow(DRC).to receive(:message)
      researcher.instance_variable_set(:@current_topic, nil)
      researcher.send(:validate_research_topic)
      expect(researcher).to have_received(:exit)
    end

    it 'rejects topic with leading whitespace' do
      allow(DRC).to receive(:message)
      researcher.instance_variable_set(:@current_topic, ' augmentation')
      researcher.send(:validate_research_topic)
      expect(researcher).to have_received(:exit)
    end

    it 'rejects topic with trailing whitespace' do
      allow(DRC).to receive(:message)
      researcher.instance_variable_set(:@current_topic, 'augmentation ')
      researcher.send(:validate_research_topic)
      expect(researcher).to have_received(:exit)
    end

    it "rejects bare 'Symbiosis' with no type" do
      allow(DRC).to receive(:message)
      researcher.instance_variable_set(:@current_topic, 'Symbiosis')
      researcher.send(:validate_research_topic)
      expect(researcher).to have_received(:exit)
    end

    it "accepts 'Symbiosis activate' (capitalized) after downcasing" do
      researcher.instance_variable_set(:@current_topic, 'Symbiosis activate')
      researcher.send(:validate_research_topic)
      expect(researcher.instance_variable_get(:@current_topic)).to eq('symbiosis activate')
      expect(researcher).not_to have_received(:exit)
    end
  end

  # ---------------------------------------------------------------------------
  # check_status
  # ---------------------------------------------------------------------------
  describe '#check_status' do
    it 'sets researching true when research is in progress' do
      allow(DRC).to receive(:bput).and_return('You estimate that you will complete it a few minutes from now')
      researcher.send(:check_status)
      expect(UserVars.researcher['researching']).to be true
    end

    it 'sets researching false when not researching anything' do
      allow(DRC).to receive(:bput).and_return("You're not researching anything")
      researcher.send(:check_status)
      expect(UserVars.researcher['researching']).to be false
    end

    it 'sets researching false when partially complete' do
      allow(DRC).to receive(:bput).and_return("You have completed \d+% of a project about")
      researcher.send(:check_status)
      expect(UserVars.researcher['researching']).to be false
    end

    it 'records a timestamp when setting status' do
      allow(DRC).to receive(:bput).and_return('You estimate that you will complete it a few minutes from now')
      researcher.send(:check_status)
      expect(UserVars.researcher['timestamp']).to be_a(Time)
    end

    it 'sends the research status command' do
      allow(DRC).to receive(:bput).and_return("You're not researching anything")
      researcher.send(:check_status)
      expect(DRC).to have_received(:bput).with('research status', anything, anything, anything)
    end
  end

  # ---------------------------------------------------------------------------
  # researching
  # ---------------------------------------------------------------------------
  describe '#researching' do
    before do
      DRSpells._set_active_spells({ 'Gauge Flow' => true })
      UserVars.researcher['researching'] = true
    end

    it 'returns true when actively researching with Gauge Flow up' do
      expect(researcher.send(:researching)).to be true
    end

    it 'returns false when research-partial flag is set' do
      Flags['research-partial'] = true
      expect(researcher.send(:researching)).to be false
    end

    it 'returns false when research-complete flag is set' do
      Flags['research-complete'] = true
      expect(researcher.send(:researching)).to be false
    end

    it 'returns false when Gauge Flow is not active' do
      DRSpells._set_active_spells({})
      expect(researcher.send(:researching)).to be false
    end

    it 'returns false when UserVars.researcher researching is false' do
      UserVars.researcher['researching'] = false
      expect(researcher.send(:researching)).to be false
    end

    it 'returns false when UserVars.researcher researching is nil' do
      UserVars.researcher['researching'] = nil
      expect(researcher.send(:researching)).to be_falsey
    end

    it 'returns false when both flags are set simultaneously' do
      Flags['research-partial'] = true
      Flags['research-complete'] = true
      expect(researcher.send(:researching)).to be false
    end

    it 'prioritizes research-partial flag over other state' do
      Flags['research-partial'] = true
      expect(researcher.send(:researching)).to be false
    end

    it 'returns false when Gauge Flow drops even if UserVars says true' do
      DRSpells._set_active_spells({ 'Some Other Spell' => true })
      expect(researcher.send(:researching)).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # set_researching
  # ---------------------------------------------------------------------------
  describe '#set_researching' do
    it 'stores true status in UserVars' do
      researcher.send(:set_researching, true)
      expect(UserVars.researcher['researching']).to be true
    end

    it 'stores false status in UserVars' do
      researcher.send(:set_researching, false)
      expect(UserVars.researcher['researching']).to be false
    end

    it 'records a timestamp' do
      before = Time.now
      researcher.send(:set_researching, true)
      after = Time.now
      expect(UserVars.researcher['timestamp']).to be_between(before, after)
    end

    it 'echoes status when debug is enabled' do
      researcher.instance_variable_set(:@debug, true)
      researcher.send(:set_researching, true)
      expect(researcher).to have_received(:echo).with('researching=true')
    end

    it 'does not echo when debug is disabled' do
      researcher.instance_variable_set(:@debug, false)
      researcher.send(:set_researching, true)
      expect(researcher).not_to have_received(:echo).with(/researching=/)
    end
  end

  # ---------------------------------------------------------------------------
  # add_flags
  # ---------------------------------------------------------------------------
  describe '#add_flags' do
    it 'registers research-partial flag' do
      researcher.send(:add_flags)
      expect(Flags['research-partial']).to eq(false)
    end

    it 'registers research-complete flag' do
      researcher.send(:add_flags)
      expect(Flags['research-complete']).to eq(false)
    end

    it 'does not overwrite existing research-partial flag' do
      Flags['research-partial'] = 'some matched text'
      researcher.send(:add_flags)
      expect(Flags['research-partial']).to eq('some matched text')
    end

    it 'does not overwrite existing research-complete flag' do
      Flags['research-complete'] = 'Breakthrough!'
      researcher.send(:add_flags)
      expect(Flags['research-complete']).to eq('Breakthrough!')
    end
  end

  # ---------------------------------------------------------------------------
  # check_research
  # ---------------------------------------------------------------------------
  describe '#check_research' do
    before do
      allow(researcher).to receive(:start_research)
      researcher.send(:add_flags)
    end

    context 'when research-partial flag is set' do
      before { Flags['research-partial'] = true }

      it 'resets the flag' do
        researcher.send(:check_research)
        expect(Flags['research-partial']).to eq(false)
      end

      it 'sets researching to false' do
        researcher.send(:check_research)
        expect(UserVars.researcher['researching']).to be false
      end

      it 'calls start_research to resume' do
        researcher.send(:check_research)
        expect(researcher).to have_received(:start_research)
      end
    end

    context 'when research-complete flag is set' do
      before { Flags['research-complete'] = true }

      it 'resets the flag' do
        researcher.send(:check_research)
        expect(Flags['research-complete']).to eq(false)
      end

      it 'sets researching to false' do
        researcher.send(:check_research)
        expect(UserVars.researcher['researching']).to be false
      end

      it 'clears current topic' do
        researcher.instance_variable_set(:@current_topic, 'augmentation')
        researcher.send(:check_research)
        expect(researcher.instance_variable_get(:@current_topic)).to be_nil
      end

      it 'does not call start_research' do
        researcher.send(:check_research)
        expect(researcher).not_to have_received(:start_research)
      end
    end

    context 'when no flags are set' do
      it 'calls start_research' do
        researcher.send(:check_research)
        expect(researcher).to have_received(:start_research)
      end
    end

    context 'when both flags are set simultaneously' do
      before do
        Flags['research-partial'] = true
        Flags['research-complete'] = true
      end

      it 'handles research-partial first (if branch priority)' do
        researcher.send(:check_research)
        expect(Flags['research-partial']).to eq(false)
        expect(researcher).to have_received(:start_research)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # start_research
  # ---------------------------------------------------------------------------
  describe '#start_research' do
    before do
      allow(researcher).to receive(:check_gaf)
      researcher.instance_variable_set(:@current_topic, 'augmentation')
    end

    context 'when already researching' do
      before do
        DRSpells._set_active_spells({ 'Gauge Flow' => true })
        UserVars.researcher['researching'] = true
      end

      it 'returns immediately without sending commands' do
        expect(DRC).not_to receive(:bput)
        researcher.send(:start_research)
      end

      it 'does not call check_gaf' do
        researcher.send(:start_research)
        expect(researcher).not_to have_received(:check_gaf)
      end
    end

    context 'when not researching' do
      before do
        DRSpells._set_active_spells({})
        UserVars.researcher['researching'] = false
      end

      it 'calls check_gaf before researching' do
        allow(DRC).to receive(:bput).and_return('You focus')
        researcher.send(:start_research)
        expect(researcher).to have_received(:check_gaf).ordered
      end

      it 'sends research command with topic and 300 duration' do
        allow(DRC).to receive(:bput).and_return('You focus')
        researcher.send(:start_research)
        expect(DRC).to have_received(:bput).with(
          'research augmentation 300',
          'You expertly coach', 'You focus', 'You tentatively', 'You confidently',
          'Abandoning the normal', 'You cannot begin', 'You are already busy',
          'Usage:', 'You do not know how to research', 'You start to research',
          'You begin to bend', 'With a mixture of rational concern'
        )
      end

      ['You focus', 'You tentatively', 'You confidently', 'Abandoning the normal', 'You are already busy', 'You start to research', 'You expertly coach', 'You begin to bend', 'With a mixture of rational concern'].each do |response|
        it "sets researching true on '#{response}'" do
          allow(DRC).to receive(:bput).and_return(response)
          researcher.send(:start_research)
          expect(UserVars.researcher['researching']).to be true
        end
      end

      it 'cancels and retries on "You cannot begin"' do
        call_count = 0
        allow(DRC).to receive(:bput) do
          call_count += 1
          call_count == 1 ? 'You cannot begin' : 'You focus'
        end
        researcher.send(:start_research)
        expect(researcher).to have_received(:fput).with('research cancel').twice
      end

      it 'exits on "Usage:"' do
        allow(DRC).to receive(:bput).and_return('Usage:')
        researcher.send(:start_research)
        expect(UserVars.researcher['researching']).to be false
        expect(researcher).to have_received(:exit)
      end

      it 'exits on "You do not know how to research"' do
        allow(DRC).to receive(:bput).and_return('You do not know how to research')
        researcher.send(:start_research)
        expect(UserVars.researcher['researching']).to be false
        expect(researcher).to have_received(:exit)
      end

      it 'includes topic in the research command for symbiosis' do
        researcher.instance_variable_set(:@current_topic, 'symbiosis activate')
        allow(DRC).to receive(:bput).and_return('You focus')
        researcher.send(:start_research)
        expect(DRC).to have_received(:bput).with(/^research symbiosis activate 300$/, any_args)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # check_gaf
  # ---------------------------------------------------------------------------
  describe '#check_gaf' do
    context 'when Gauge Flow is already active' do
      before { DRSpells._set_active_spells({ 'Gauge Flow' => true }) }

      it 'does not cast anything' do
        expect(DRCA).not_to receive(:cast_spell)
        researcher.send(:check_gaf)
      end
    end

    context 'when Gauge Flow is not active' do
      before { DRSpells._set_active_spells({}) }

      context 'with waggle_sets gaf configured' do
        let(:gaf_data) { { 'abbrev' => 'gaf', 'mana' => 15, 'prep_time' => 5 } }
        let(:settings) do
          { 'waggle_sets' => { 'gaf' => { 'Gauge Flow' => gaf_data } } }
        end

        it 'casts using the waggle set configuration' do
          allow(DRCA).to receive(:cast_spell)
          researcher.send(:check_gaf)
          expect(DRCA).to have_received(:cast_spell).with(gaf_data, settings)
        end
      end

      context 'without waggle_sets configuration' do
        let(:settings) { {} }

        it 'casts with minimum prep defaults' do
          allow(DRCA).to receive(:cast_spell)
          researcher.send(:check_gaf)
          expect(DRCA).to have_received(:cast_spell).with(
            { 'abbrev' => 'gaf', 'mana' => 5 },
            settings
          )
        end
      end

      context 'with waggle_sets but no gaf key' do
        let(:settings) { { 'waggle_sets' => { 'buffset' => {} } } }

        it 'falls back to minimum prep' do
          allow(DRCA).to receive(:cast_spell)
          researcher.send(:check_gaf)
          expect(DRCA).to have_received(:cast_spell).with(
            { 'abbrev' => 'gaf', 'mana' => 5 },
            settings
          )
        end
      end

      context 'with waggle_sets.gaf but no Gauge Flow key' do
        let(:settings) { { 'waggle_sets' => { 'gaf' => { 'Other Spell' => {} } } } }

        it 'falls back to minimum prep' do
          allow(DRCA).to receive(:cast_spell)
          researcher.send(:check_gaf)
          expect(DRCA).to have_received(:cast_spell).with(
            { 'abbrev' => 'gaf', 'mana' => 5 },
            settings
          )
        end
      end

      context 'with nil waggle_sets' do
        let(:settings) { { 'waggle_sets' => nil } }

        it 'falls back to minimum prep without raising' do
          allow(DRCA).to receive(:cast_spell)
          researcher.send(:check_gaf)
          expect(DRCA).to have_received(:cast_spell).with(
            { 'abbrev' => 'gaf', 'mana' => 5 },
            settings
          )
        end
      end

      it 'echoes debug info when debug is enabled' do
        researcher.instance_variable_set(:@debug, true)
        allow(DRCA).to receive(:cast_spell)
        researcher.send(:check_gaf)
        expect(researcher).to have_received(:echo).with(/min prep/)
      end

      it 'does not echo when debug is disabled' do
        allow(DRCA).to receive(:cast_spell)
        researcher.send(:check_gaf)
        expect(researcher).not_to have_received(:echo)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # display_help_and_exit
  # ---------------------------------------------------------------------------
  describe '#display_help_and_exit' do
    before { allow(DRC).to receive(:message) }

    it 'exits after displaying help' do
      researcher.send(:display_help_and_exit)
      expect(researcher).to have_received(:exit)
    end

    it 'mentions all valid research topics' do
      researcher.send(:display_help_and_exit)
      VALID_RESEARCH_TOPICS.each do |topic|
        expect(DRC).to have_received(:message).with(/#{topic}/).at_least(:once)
      end
    end

    it 'mentions symbiosis types' do
      researcher.send(:display_help_and_exit)
      expect(DRC).to have_received(:message).with(/activate/).at_least(:once)
      expect(DRC).to have_received(:message).with(/spell/).at_least(:once)
    end

    it 'mentions YAML configuration' do
      researcher.send(:display_help_and_exit)
      expect(DRC).to have_received(:message).with(/YAML/).at_least(:once)
    end
  end

  # ---------------------------------------------------------------------------
  # Integration-style: check_status -> researching interaction
  # ---------------------------------------------------------------------------
  describe 'check_status and researching interaction' do
    before do
      researcher.send(:add_flags)
    end

    it 'researching returns true after check_status detects active research' do
      DRSpells._set_active_spells({ 'Gauge Flow' => true })
      allow(DRC).to receive(:bput).and_return('You estimate that you will complete it a few minutes from now')
      researcher.send(:check_status)
      expect(researcher.send(:researching)).to be true
    end

    it 'researching returns false after check_status detects no research' do
      DRSpells._set_active_spells({ 'Gauge Flow' => true })
      allow(DRC).to receive(:bput).and_return("You're not researching anything")
      researcher.send(:check_status)
      expect(researcher.send(:researching)).to be false
    end

    it 'researching returns false even with status true when Gauge Flow drops' do
      DRSpells._set_active_spells({})
      allow(DRC).to receive(:bput).and_return('You estimate that you will complete it a few minutes from now')
      researcher.send(:check_status)
      expect(researcher.send(:researching)).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: start_research recursive cancel
  # ---------------------------------------------------------------------------
  describe 'start_research cancel retry' do
    before do
      DRSpells._set_active_spells({})
      UserVars.researcher['researching'] = false
      researcher.instance_variable_set(:@current_topic, 'warding')
      allow(researcher).to receive(:check_gaf)
    end

    it 'sends two cancel commands before retrying' do
      call_count = 0
      allow(DRC).to receive(:bput) do
        call_count += 1
        call_count == 1 ? 'You cannot begin' : 'You focus'
      end
      researcher.send(:start_research)
      expect(researcher).to have_received(:fput).with('research cancel').exactly(2).times
    end

    it 'eventually succeeds after cancel' do
      call_count = 0
      allow(DRC).to receive(:bput) do
        call_count += 1
        call_count == 1 ? 'You cannot begin' : 'You confidently'
      end
      researcher.send(:start_research)
      expect(UserVars.researcher['researching']).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: check_research full cycle
  # ---------------------------------------------------------------------------
  describe 'check_research complete cycle' do
    before do
      researcher.send(:add_flags)
      researcher.instance_variable_set(:@current_topic, 'utility')
      allow(researcher).to receive(:start_research)
    end

    it 'clears topic on completion so subsequent start_research gets nil topic' do
      Flags['research-complete'] = true
      researcher.send(:check_research)
      expect(researcher.instance_variable_get(:@current_topic)).to be_nil
    end

    it 'partial flag resets then restarts without clearing topic' do
      Flags['research-partial'] = true
      researcher.send(:check_research)
      expect(researcher.instance_variable_get(:@current_topic)).to eq('utility')
      expect(researcher).to have_received(:start_research)
    end
  end

  # ---------------------------------------------------------------------------
  # VALID_RESEARCH_TOPICS constant
  # ---------------------------------------------------------------------------
  describe 'VALID_RESEARCH_TOPICS' do
    it 'is frozen' do
      expect(VALID_RESEARCH_TOPICS).to be_frozen
    end

    it 'contains all valid research topics' do
      expect(VALID_RESEARCH_TOPICS).to contain_exactly(
        'fundamental', 'stream', 'augmentation', 'utility', 'warding',
        'sorcery', 'energy', 'field', 'spell', 'plane', 'planes', 'road', 'wild'
      )
    end

    it 'does not include attunement (handled by normalization)' do
      expect(VALID_RESEARCH_TOPICS).not_to include('attunement')
    end

    it 'does not include symbiosis (handled separately)' do
      expect(VALID_RESEARCH_TOPICS).not_to include('symbiosis')
    end
  end
end
