# frozen_string_literal: true

require_relative 'spec_helper'

load_lic_class('invoke-rune.lic', 'Runestone')

# Runestone#runestone_cast sends `invoke my <rune>` and compares the text
# DRC.bput returns against the `when` literals. lich-5's DRC.bput compiles
# each String pattern to /pattern/i and returns the matched text, so an
# unescaped '?' makes the character before it optional and drops the '?'
# from the returned text: 'Invoke what?' returns "Invoke what", which never
# equals the `when 'Invoke what?'` literal.
#
# DRC.bput is replaced by a model of that matching, not a canned return, so
# the patterns runestone_cast passes are what decide the branch.
RSpec.describe Runestone do
  let(:rune_name) { 'elbaite runestone' }
  let(:runestone) { Runestone.allocate }
  let(:bput_commands) { [] }
  let(:bput_results) { [] }
  let(:invoke_reply) { 'Invoke what?' }

  before do
    runestone.instance_variable_set(:@rune, rune_name)
    runestone.instance_variable_set(:@harness, 10)
    runestone.instance_variable_set(:@runestone_storage, 'pouch')
    runestone.instance_variable_set(:@buff_spell_mana_threshold, 0)
    allow(runestone).to receive(:mana).and_return(100)
    allow(DRCI).to receive(:dispose_trash)
    allow(DRCI).to receive(:put_away_item?).and_return(true)
    allow(DRC).to receive(:message)
    allow(DRC).to receive(:bput) do |command, *patterns|
      bput_commands << command
      result = command.start_with?('invoke') ? model_bput(invoke_reply, patterns) : ''
      bput_results << result
      result
    end
  end

  # lich-5 DRC.bput: `matches.map! { |item| item.is_a?(Regexp) ? item : /#{item}/i }`
  # then `return result.to_a.first` for the first pattern the line matches.
  def model_bput(line, patterns)
    patterns.flatten.each do |pattern|
      regex = pattern.is_a?(Regexp) ? pattern : /#{pattern}/i
      match = line.match(regex)
      return match.to_a.first if match
    end
    ''
  end

  context 'when the rune is not in hand' do
    it 'gets the whole reply, question mark included, back from bput' do
      runestone.runestone_cast
      expect(bput_results.first).to eq('Invoke what?')
    end

    it 'gives up on this cast instead of harnessing and casting' do
      runestone.runestone_cast
      expect(bput_commands).to eq(["invoke my #{rune_name}"])
    end

    it 'does not try to put away a rune it is not holding' do
      runestone.runestone_cast
      expect(DRCI).not_to have_received(:put_away_item?)
    end
  end

  context 'when the invoke succeeds' do
    let(:invoke_reply) { 'Closing your eyes, you trace the pattern of the elbaite runestone.' }

    it 'still harnesses, casts and puts the rune away' do
      runestone.runestone_cast
      expect(bput_commands).to eq(["invoke my #{rune_name}", 'harn 10', 'cast'])
      expect(DRCI).to have_received(:put_away_item?).with(rune_name, 'pouch')
    end
  end
end
