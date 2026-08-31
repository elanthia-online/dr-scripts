require 'spec_helper'

# Regression coverage for issue #7529: an offhand thrown weapon whose strike
# shatters a limb resolves without the game ever printing a 'roundtime' line, so
# the old AttackProcess#attack_thrown bput (which matched only 'roundtime' and
# 'What are you trying to') stalled for its full timeout before giving up.
# attack_thrown now also matches the throw's own success text ("you lob/throw/
# hurl ...") so it returns as soon as the attack resolves and lets waitrt? handle
# the actual roundtime from XML.
describe 'AttackProcess#attack_thrown' do
  before(:all) { load_lic_class('combat-trainer.lic', 'AttackProcess') }

  # The exact strike line from issue #7529 - a limb-shatter lob with no roundtime
  # text anywhere in the game output. Note the combat-maneuver prefix means the
  # verb phrase is mid-line, not anchored at the start.
  let(:throw_line_7529) do
    '< Driving in with exacting precision, you lob a small cast-iron ' \
      'frying pan with a whitleather-wrapped handle at a grey clay mage.'
  end

  let(:attack_process) { AttackProcess.allocate }

  # game_state is a GameState instance at runtime, but load_lic_class only loads
  # AttackProcess, so the constant is unavailable for a verifying double here.
  def build_game_state(verb:, offhand:)
    double('game_state',
           thrown_attack_verb: verb,
           offhand?: offhand,
           weapon_name: 'frying pan',
           thrown_retrieve_verb: 'get my frying pan',
           action_taken: :action_taken)
  end

  before do
    # The retrieve step's bput returns a benign "picked it up" outcome.
    allow(DRC).to receive(:bput).and_return('You pick up')
  end

  # Capture the matcher list attack_thrown hands to bput for the *attack* command.
  def attack_matchers_for(command)
    captured = nil
    allow(DRC).to receive(:bput) do |cmd, *matchers|
      captured = matchers if cmd == command
      'You pick up'
    end
    yield
    captured
  end

  it 'matches the throw success line from #7529 even when no roundtime is printed' do
    matchers = attack_matchers_for('lob left') do
      attack_process.send(:attack_thrown, build_game_state(verb: 'lob', offhand: true))
    end

    expect(matchers).not_to be_nil
    expect(matchers).to include('roundtime') # existing behavior preserved
    matched_success = matchers.any? { |m| m.is_a?(Regexp) && throw_line_7529 =~ m }
    expect(matched_success).to be(true)
  end

  # thrown_attack_verb can emit lob (weak/lodging), throw (normal), hurl (bonded),
  # or a custom attack_override; each echoes "you <verb> ...", so the success match
  # is derived from the verb rather than hard-coded.
  { 'lob' => 'you lob a pan at a mage', 'throw' => 'you throw a pan at a mage',
    'hurl' => 'you hurl a pan at a mage' }.each do |verb, success_line|
    it "matches the '#{verb}' success text for a mainhand throw" do
      matchers = attack_matchers_for(verb) do
        attack_process.send(:attack_thrown, build_game_state(verb: verb, offhand: false))
      end

      matched_success = matchers.any? { |m| m.is_a?(Regexp) && success_line =~ m }
      expect(matched_success).to be(true)
    end
  end

  it 'returns action_taken for the attack' do
    result = attack_process.send(:attack_thrown, build_game_state(verb: 'lob', offhand: true))
    expect(result).to eq(:action_taken)
  end
end
