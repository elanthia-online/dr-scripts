require 'spec_helper'

# healme.lic heals the character's own wounds. While it waits on a cast it
# listens to the raw game stream (a DownstreamHook plus two Flags) for the
# game's "wounds/scars ... fully healed", "bandages ... fall apart", "cured of
# all disease" and "spell flushes all poison" lines. These specs check that
# only the game's own lines change what healme does next, and that the same
# words inside other players' speech, whispers or ESP do not.
describe 'healme.lic' do
  before(:all) do
    load_lic_class('healme.lic', 'HealMe')
  end

  let(:healme) { HealMe.allocate }
  let(:chest_internal_wound) do
    OpenStruct.new(body_part: 'chest', location: 'internal', type: 'wound', severity: 4, scar?: false)
  end
  let(:chest_lodged) do
    OpenStruct.new(body_part: 'chest', location: 'external', type: 'wound', severity: 3, scar?: false)
  end

  before do
    $debug_mode_healme = false
    allow(DownstreamHook).to receive(:add) { |_name, action| @wounds_healed_hook = action }
    allow(DownstreamHook).to receive(:remove)
    allow(healme).to receive(:attend_vitals)
    healme.reset_health_flags
    healme.register_wounds_healed_hook
  end

  # Feed one raw server line the way Lich does: DRParser.check_events tests it
  # against every registered Flags matcher, and the DownstreamHook sees it too.
  def deliver(line)
    Flags.matchers.each do |key, regexes|
      regexes.each do |regex|
        if (match = line.match(regex))
          Flags[key] = match
          break
        end
      end
    end
    @wounds_healed_hook.call(line)
  end

  # The same text spoken by another player, in the raw XML shapes the hook and
  # Flags see and in their stripped forms.
  def player_shapes(text)
    [
      %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
      %([General][Mallory] "#{text}"),
      %(<preset id='speech'>Mallory says</preset>, "#{text}"),
      %(Mallory says, "#{text}"),
      %(<pushStream id="whispers"/><preset id="whisper">Mallory whispers,</preset> "#{text}"),
      %(Mallory whispers, "#{text}")
    ]
  end

  def heals_chest_wound?
    healed = []
    allow(healme).to receive(:heal_wound) { |wound| healed << wound }
    healme.heal_wounds({ 4 => [chest_internal_wound] })
    healed.include?(chest_internal_wound)
  end

  describe 'fully healed wounds' do
    let(:healed_line) { 'The internal wounds to your chest are fully healed.' }

    it 'heals a wound when nothing said it was healed' do
      deliver('You feel a little better.')

      expect(heals_chest_wound?).to be(true)
    end

    it 'skips a wound the game says is fully healed' do
      deliver(healed_line)

      expect(heals_chest_wound?).to be(false)
    end

    it 'skips a wound the game says is fully healed behind a leading tag' do
      deliver("<pushBold/>#{healed_line}")

      expect(heals_chest_wound?).to be(false)
    end

    it 'reads each body part from a list in the "appear completely healed" wording' do
      deliver('The internal wounds on your neck, chest and left arm appear completely healed.')

      expect(heals_chest_wound?).to be(false)
      expect(healme.instance_variable_get(:@healed_wounds).keys)
        .to contain_exactly('neck|internal|wound', 'chest|internal|wound', 'left arm|internal|wound')
    end

    it 'still heals the wound when another player says or thinks the healed line' do
      player_shapes(healed_line).each { |line| deliver(line) }

      expect(healme.instance_variable_get(:@healed_wounds)).to be_empty
      expect(heals_chest_wound?).to be(true)
    end
  end

  describe 'bandages falling apart' do
    let(:fall_apart_line) { 'The bandages binding your chest become useless and fall apart.' }

    def tends_chest?
      tended = []
      allow(healme).to receive(:tend_wound) { |wound| tended << wound }
      healme.tend_wounds({ 3 => [chest_lodged] })
      tended.include?(chest_lodged)
    end

    before { healme.instance_variable_get(:@tended_wounds)['chest'] = true }

    it 'tends the wound again after the game says its bandages fell apart' do
      deliver("<pushBold/>#{fall_apart_line}")

      expect(tends_chest?).to be(true)
    end

    it 'keeps the wound tended when another player says the bandage line' do
      player_shapes(fall_apart_line).each { |line| deliver(line) }

      expect(tends_chest?).to be(false)
    end
  end

  describe 'disease cured' do
    let(:cured_line) { 'You feel completely cured of all disease.' }

    before { healme.instance_variable_set(:@diseased, true) }

    it 'stops treating the character as diseased after the game line' do
      deliver(cured_line)

      expect(healme.diseased?).to be(false)
    end

    it 'stops treating the character as diseased after the game line behind a leading tag' do
      deliver("<pushBold/>#{cured_line}")

      expect(healme.diseased?).to be(false)
    end

    it 'stays diseased when another player says the cured line' do
      player_shapes(cured_line).each { |line| deliver(line) }

      expect(Flags['healme-cured-disease']).to be(false)
      expect(healme.diseased?).to be(true)
    end
  end

  # The exact game line is not in the log corpus, so the pattern keeps
  # accepting any unquoted text before the phrase, as the old one did.
  describe 'poison flushed flag' do
    it 'fires on the game line, with or without unquoted text or tags before it' do
      ['Your spell flushes all poison from your body.',
       '<pushBold/>Your spell flushes all poison from your body.',
       'Some unquoted lead-in, and your spell flushes all poison from your body.'].each do |line|
        Flags.reset('healme-flushed-poison')
        deliver(line)

        expect(Flags['healme-flushed-poison']).to be_truthy, line
      end
    end

    it 'does not fire when another player says the line' do
      player_shapes('Your spell flushes all poison from your body.').each { |line| deliver(line) }

      expect(Flags['healme-flushed-poison']).to be(false)
    end
  end

  # The hook clears @poisoned when the flushed flag is set, so the next
  # attend_vitals does not cast Flush Poisons again before a perceive.
  describe 'poison flushed' do
    let(:casts) { [] }

    before do
      DRStats.health = 100
      healme.instance_variable_set(:@settings, OpenStruct.new(health_threshold: 50))
      allow(healme).to receive(:attend_vitals).and_call_original
      allow(healme).to receive(:use_heal_over_time_spells?).and_return(false)
      allow(healme).to receive(:cast_spell_or_warn) { |spell_name, _message| casts << spell_name }
      healme.instance_variable_set(:@poisoned, true)
    end

    it 'keeps flushing poison while nothing says it is gone' do
      deliver('You feel a little better.')
      healme.attend_vitals

      expect(healme.poisoned?).to be(true)
      expect(casts).to eq(['Flush Poisons'])
    end

    it 'stops flushing poison once the spell has flushed it' do
      deliver('Your spell flushes all poison from your body.')
      healme.attend_vitals

      expect(healme.poisoned?).to be(false)
      expect(casts).to be_empty
    end
  end
end
