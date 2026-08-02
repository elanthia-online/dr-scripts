# frozen_string_literal: true

require_relative 'spec_helper'

# Taisidon#initialize depends on the full Lich runtime (parse_args, EquipmentManager, and
# live cruise I/O), so -- following the fenvol-puzzle/smoke pattern -- we extract the class
# with load_lic_class and exercise its seams on bare-allocated instances (Taisidon.allocate).
# Every example is self-contained (DAMP): the fixture lines below are real transcript text
# from the event, and each test states the exact behavior it verifies without chasing shared
# helpers.
#
# Two kinds of tests appear:
#   1. Pure seams (weapon_for, scene_for, guilty?, solved?, accuse_command) called directly.
#   2. I/O methods (study_corpse, question_suspect, investigate, accuse, redeem_and_board)
#      driven by stubbing DRC.bput / DRRoom / DRCT, asserting the ivars and commands.
#
# For the detection logic we ALSO verify the real DRC.bput contract with simulate_bput (a
# file-local helper), which mirrors commons' matching: string patterns become case-insensitive
# regexps, the first pattern in argument order wins, and the whole matched substring is
# returned. This proves the wound and alibi patterns are collision-free AND correctly ordered
# against real transcript lines -- not merely that the constants look right.
load_lic_class('taisidon.lic', 'Taisidon')

# --- Real transcript fixtures (verbatim from event logs) ---------------------
# Defined as file-local variables (captured by the describe/it closures) rather than
# constants, so nothing leaks into the shared single-process suite namespace.

# Full STUDY CORPSE wound sentences, keyed by the weapon they imply.
wound_lines = {
  'zills'      => 'The dead body is covered with slashes displaying clean edges.',
  'cleaver'    => 'The neck of the dead body is nearly completely severed with chop marks that reveal flesh and bone.',
  'baton'      => 'The dead body has been beaten and battered, displaying a disturbing amount of soft tissue damage and internal bleeding.',
  'bottle'     => 'The dead body is covered with severe lacerations.',
  'corkscrew'  => 'The dead body is covered with oddly curved puncture wounds.',
  'knife'      => 'The dead body is covered with lethal cuts outlined by ragged edges.',
  'comb'       => 'The dead body is criss-crossed with slashes marked by odd perforations of the skin.',
  'logbook'    => 'The dead body is covered in gashes and severe blunt trauma, displaying a large amount of damage.',
  'paintbrush' => 'The dead body is pierced with deep and lethal puncture wounds.'
}.freeze

# Full guilty ASK ABOUT ALIBI responses, one per nervous tell.
guilty_lines = [
  'A Dwarven chef says with a nervous tic, "I was taking inventory of the pantry."',
  'A Dwarven beautician says coughing awkwardly, "I was organizing hair dyes by hue."',
  'A Dwarven boatswain says with shifty eyes, "I was teaching the new guy."',
  'A Gnomish entertainer says with a flushed face, "I was practicing the bongos."',
  'A Halfling director says with trembling hands, "I was putting together the entertainment schedule."',
  'A Dwarven bartender says while pacing back and forth, "I was polishing glassware."',
  'A Gnomish artist says while blinking excessively, "I was painting an abstract landscape of the ocean vista."',
  "A Gor'Tog deckhand says while tugging at their uniform, \"I was swabbing the deck.\"",
  "A Gor'Tog steward says, fingers tapping, \"I was tidying up the passenger cabins.\""
].freeze

# Full innocent ASK ABOUT ALIBI responses (a straight verbal answer, no tell).
innocent_lines = [
  'A Dwarven artist says, "I was painting an abstract landscape of the ocean vista."',
  'A Dwarven chef says, "I was taking inventory of the pantry."',
  'A Dwarven steward says, "I was tidying up the passenger cabins."',
  'A Dwarven bartender says, "I was polishing glassware."'
].freeze

RSpec.describe Taisidon do
  subject(:taisidon) { described_class.allocate }

  # Mirrors DRC.bput's matching so detection can be verified end-to-end against real lines:
  # string patterns become case-insensitive regexps, the first pattern (in the order passed)
  # that matches wins, and bput returns that match's whole matched substring. Returns '' when
  # nothing matches (bput's timeout return).
  def simulate_bput(line, patterns)
    patterns.each do |pattern|
      regexp = pattern.is_a?(Regexp) ? pattern : /#{pattern}/i
      match = line.match(regexp)
      return match.to_a.first if match
    end
    ''
  end

  # The exact pattern list question_suspect hands to bput, in order.
  def alibi_patterns
    [*Taisidon::GUILTY_TELLS, Taisidon::ALIBI_USAGE, Taisidon::INNOCENT_TELL]
  end

  # ===========================================================================
  # Constants
  # ===========================================================================
  describe 'WEAPON_BY_WOUND' do
    it 'is frozen' do
      expect(described_class::WEAPON_BY_WOUND).to be_frozen
    end

    it 'covers all nine murder weapons' do
      expect(described_class::WEAPON_BY_WOUND.values.sort)
        .to eq(%w[baton bottle cleaver comb corkscrew knife logbook paintbrush zills])
    end

    it 'maps to distinct weapons (no weapon appears twice)' do
      weapons = described_class::WEAPON_BY_WOUND.values
      expect(weapons).to eq(weapons.uniq)
    end

    it 'keys are all regexps' do
      expect(described_class::WEAPON_BY_WOUND.keys).to all(be_a(Regexp))
    end
  end

  describe 'SCENE_BY_ROOM' do
    it 'is frozen' do
      expect(described_class::SCENE_BY_ROOM).to be_frozen
    end

    it 'maps the six cruise rooms to their scene names' do
      expect(described_class::SCENE_BY_ROOM).to eq(
        '16025' => 'lounge',
        '16026' => 'bar',
        '16027' => 'promenade',
        '16028' => 'buffet',
        '16029' => 'quarterdeck',
        '16030' => 'foredeck'
      )
    end

    it 'names the six documented crime-scene rooms' do
      expect(described_class::SCENE_BY_ROOM.values.sort)
        .to eq(%w[bar buffet foredeck lounge promenade quarterdeck])
    end
  end

  describe 'PATROL_ROOMS' do
    it 'is frozen' do
      expect(described_class::PATROL_ROOMS).to be_frozen
    end

    it 'preserves the original patrol order' do
      expect(described_class::PATROL_ROOMS).to eq(%w[16030 16027 16028 16029 16025 16026])
    end

    it 'visits exactly the six crime-scene rooms (and not the morgue)' do
      expect(described_class::PATROL_ROOMS.sort).to eq(described_class::SCENE_BY_ROOM.keys.sort)
      expect(described_class::PATROL_ROOMS).not_to include(described_class::MORGUE_ROOM)
    end
  end

  describe 'GUILTY_TELLS' do
    it 'is frozen and lists nine tells' do
      expect(described_class::GUILTY_TELLS).to be_frozen
      expect(described_class::GUILTY_TELLS.size).to eq(9)
    end

    it 'are all regexps' do
      expect(described_class::GUILTY_TELLS).to all(be_a(Regexp))
    end

    it 'orders the comma-bearing "fingers tapping" tell before the generic innocent marker' do
      # In question_suspect, GUILTY_TELLS precede INNOCENT_TELL. Because bput returns the
      # first matching pattern, the fingers-tapping tell (which also matches /says,/) must be
      # offered first or the guilty steward would be misread as innocent.
      patterns = alibi_patterns
      fingers_index = patterns.index(/says, fingers tapping/)
      innocent_index = patterns.index(described_class::INNOCENT_TELL)
      expect(fingers_index).not_to be_nil
      expect(fingers_index).to be < innocent_index
    end
  end

  describe 'MORGUE_ROOM and REPRESENTATIVE_ROOM' do
    it 'are the expected room ids' do
      expect(described_class::MORGUE_ROOM).to eq('16031')
      expect(described_class::REPRESENTATIVE_ROOM).to eq('15979')
    end
  end

  # ===========================================================================
  # weapon_for -- wound description => weapon
  # ===========================================================================
  describe '#weapon_for' do
    wound_lines.each do |weapon, line|
      it "identifies #{weapon} from its real wound line" do
        expect(taisidon.weapon_for(line)).to eq(weapon)
      end
    end

    it 'matches on the short fragment alone as well as the full sentence' do
      expect(taisidon.weapon_for('displaying clean edges')).to eq('zills')
      expect(taisidon.weapon_for('gashes and severe blunt')).to eq('logbook')
    end

    it 'is collision-free: every real wound line maps through the exact bput contract' do
      wound_lines.each do |weapon, line|
        returned = simulate_bput(line, described_class::WEAPON_BY_WOUND.keys)
        expect(taisidon.weapon_for(returned)).to eq(weapon),
                                                 "expected #{line.inspect} -> #{weapon} but bput returned #{returned.inspect}"
      end
    end

    it 'returns nil for an unrecognized wound' do
      expect(taisidon.weapon_for('The dead body is untouched.')).to be_nil
    end

    it 'returns nil for the empty string bput yields on timeout' do
      expect(taisidon.weapon_for('')).to be_nil
    end

    it 'returns nil for nil' do
      expect(taisidon.weapon_for(nil)).to be_nil
    end
  end

  # ===========================================================================
  # scene_for -- room id => crime-scene name
  # ===========================================================================
  describe '#scene_for' do
    {
      '16025' => 'lounge',
      '16026' => 'bar',
      '16027' => 'promenade',
      '16028' => 'buffet',
      '16029' => 'quarterdeck',
      '16030' => 'foredeck'
    }.each do |room, scene|
      it "maps room #{room} to #{scene}" do
        expect(taisidon.scene_for(room)).to eq(scene)
      end
    end

    it 'accepts an integer room id' do
      expect(taisidon.scene_for(16_026)).to eq('bar')
    end

    it 'returns nil for the morgue (not a crime scene)' do
      expect(taisidon.scene_for('16031')).to be_nil
    end

    it 'returns nil for an unknown room id' do
      expect(taisidon.scene_for('99999')).to be_nil
    end
  end

  # ===========================================================================
  # guilty? -- alibi response => guilt
  # ===========================================================================
  describe '#guilty?' do
    guilty_lines.each do |line|
      it "flags a nervous tell as guilty: #{line[0, 60]}..." do
        expect(taisidon.guilty?(line)).to be(true)
      end
    end

    innocent_lines.each do |line|
      it "clears a straight answer as innocent: #{line[0, 60]}..." do
        expect(taisidon.guilty?(line)).to be(false)
      end
    end

    it 'is false for nil and for the empty string bput yields on timeout' do
      expect(taisidon.guilty?(nil)).to be(false)
      expect(taisidon.guilty?('')).to be(false)
    end

    it 'classifies every real alibi line correctly through the exact bput contract' do
      # The strongest guard: feeds each real line through simulate_bput using the exact
      # ordered pattern list question_suspect passes, then classifies the fragment bput
      # actually returns. Proves both no-collision and correct ordering (esp. the guilty
      # steward whose tell contains "says,").
      guilty_lines.each do |line|
        fragment = simulate_bput(line, alibi_patterns)
        expect(taisidon.guilty?(fragment)).to be(true), "guilty line misread: #{line.inspect} -> #{fragment.inspect}"
      end

      innocent_lines.each do |line|
        fragment = simulate_bput(line, alibi_patterns)
        expect(taisidon.guilty?(fragment)).to be(false), "innocent line misread: #{line.inspect} -> #{fragment.inspect}"
      end
    end

    it 'does not misclassify the comma-bearing guilty steward as innocent' do
      line = "A Gor'Tog steward says, fingers tapping, \"I was tidying up the passenger cabins.\""
      fragment = simulate_bput(line, alibi_patterns)
      expect(fragment).to eq('says, fingers tapping')
      expect(taisidon.guilty?(fragment)).to be(true)
    end
  end

  # ===========================================================================
  # Clue-state predicates and accuse_command
  # ===========================================================================
  describe 'clue-state predicates' do
    before do
      taisidon.instance_variable_set(:@murderer, '')
      taisidon.instance_variable_set(:@weapon, '')
      taisidon.instance_variable_set(:@crimescene, '')
    end

    it 'reports each clue as not found while blank and found once set' do
      expect(taisidon.murderer_found?).to be(false)
      expect(taisidon.weapon_found?).to be(false)
      expect(taisidon.scene_found?).to be(false)

      taisidon.instance_variable_set(:@murderer, 'chef')
      taisidon.instance_variable_set(:@weapon, 'knife')
      taisidon.instance_variable_set(:@crimescene, 'bar')

      expect(taisidon.murderer_found?).to be(true)
      expect(taisidon.weapon_found?).to be(true)
      expect(taisidon.scene_found?).to be(true)
    end

    describe '#solved?' do
      it 'is true only when all three clues are present' do
        taisidon.instance_variable_set(:@murderer, 'chef')
        taisidon.instance_variable_set(:@weapon, 'knife')
        taisidon.instance_variable_set(:@crimescene, 'bar')
        expect(taisidon.solved?).to be(true)
      end

      it 'is false when the murderer is missing' do
        taisidon.instance_variable_set(:@weapon, 'knife')
        taisidon.instance_variable_set(:@crimescene, 'bar')
        expect(taisidon.solved?).to be(false)
      end

      it 'is false when the weapon is missing' do
        taisidon.instance_variable_set(:@murderer, 'chef')
        taisidon.instance_variable_set(:@crimescene, 'bar')
        expect(taisidon.solved?).to be(false)
      end

      it 'is false when the crime scene is missing' do
        taisidon.instance_variable_set(:@murderer, 'chef')
        taisidon.instance_variable_set(:@weapon, 'knife')
        expect(taisidon.solved?).to be(false)
      end
    end

    describe '#accuse_command' do
      it 'builds the exact ACCUSE person WITH weapon IN room string' do
        taisidon.instance_variable_set(:@murderer, 'chef')
        taisidon.instance_variable_set(:@weapon, 'knife')
        taisidon.instance_variable_set(:@crimescene, 'bar')
        expect(taisidon.accuse_command).to eq('accuse chef with the knife in bar')
      end
    end
  end

  # ===========================================================================
  # study_corpse (I/O)
  # ===========================================================================
  describe '#study_corpse' do
    before { taisidon.instance_variable_set(:@weapon, '') }

    it 'records the weapon implied by the wound and announces it' do
      allow(DRC).to receive(:bput).and_return(wound_lines.fetch('knife'))
      expect(DRC).to receive(:message).with(/Weapon: knife/)

      taisidon.send(:study_corpse)

      expect(taisidon.instance_variable_get(:@weapon)).to eq('knife')
    end

    it 'passes exactly the wound patterns to bput' do
      captured = nil
      allow(DRC).to receive(:bput) do |_cmd, *patterns|
        captured = patterns
        wound_lines.fetch('zills')
      end

      taisidon.send(:study_corpse)

      expect(captured).to eq(described_class::WEAPON_BY_WOUND.keys)
    end

    it 'aborts (exit) when the wound is unrecognized rather than proceeding weaponless' do
      allow(DRC).to receive(:bput).and_return('The dead body is untouched.')
      allow(DRC).to receive(:message)

      expect { taisidon.send(:study_corpse) }.to raise_error(SystemExit)
      expect(taisidon.instance_variable_get(:@weapon)).to eq('')
    end

    it 'aborts (exit) when bput times out and returns an empty string' do
      allow(DRC).to receive(:bput).and_return('')
      allow(DRC).to receive(:message)

      expect { taisidon.send(:study_corpse) }.to raise_error(SystemExit)
    end
  end

  # ===========================================================================
  # question_suspect (I/O)
  # ===========================================================================
  describe '#question_suspect' do
    before do
      taisidon.instance_variable_set(:@murderer, '')
      DRRoom.npcs = ['chef']
    end

    it 'records the suspect as the murderer when the alibi shows a tell' do
      allow(DRC).to receive(:bput).and_return('says with a nervous tic')
      allow(DRC).to receive(:message)

      taisidon.send(:question_suspect)

      expect(taisidon.instance_variable_get(:@murderer)).to eq('chef')
    end

    it 'leaves the murderer unset when the alibi is a straight answer' do
      allow(DRC).to receive(:bput).and_return('says,')
      allow(DRC).to receive(:message)

      taisidon.send(:question_suspect)

      expect(taisidon.instance_variable_get(:@murderer)).to eq('')
    end

    it 'asks the first suspect present, with the tells offered before the innocent marker' do
      captured_cmd = nil
      captured_patterns = nil
      allow(DRC).to receive(:bput) do |cmd, *patterns|
        captured_cmd = cmd
        captured_patterns = patterns
        'says,'
      end
      allow(DRC).to receive(:message)

      taisidon.send(:question_suspect)

      expect(captured_cmd).to eq('ask chef about alibi')
      expect(captured_patterns.index(/says, fingers tapping/))
        .to be < captured_patterns.index(described_class::INNOCENT_TELL)
    end

    it 'does nothing (no bput) when the murderer is already known' do
      taisidon.instance_variable_set(:@murderer, 'artist')
      expect(DRC).not_to receive(:bput)

      taisidon.send(:question_suspect)

      expect(taisidon.instance_variable_get(:@murderer)).to eq('artist')
    end

    it 'skips the room (no bput) when no suspect is present' do
      DRRoom.npcs = []
      expect(DRC).not_to receive(:bput)

      taisidon.send(:question_suspect)

      expect(taisidon.instance_variable_get(:@murderer)).to eq('')
    end

    it 'aborts (exit) on a Usage error from ASK ABOUT ALIBI' do
      allow(DRC).to receive(:bput).and_return('Usage')
      allow(DRC).to receive(:message)

      expect { taisidon.send(:question_suspect) }.to raise_error(SystemExit)
    end
  end

  # ===========================================================================
  # investigate (I/O)
  # ===========================================================================
  describe '#investigate' do
    before { taisidon.instance_variable_set(:@crimescene, '') }

    it 'records the crime scene when the search uncovers blood' do
      allow(DRC).to receive(:bput).and_return('uncovers an area of')
      allow(DRC).to receive(:message)

      taisidon.send(:investigate, '16026')

      expect(taisidon.instance_variable_get(:@crimescene)).to eq('bar')
    end

    it 'leaves the scene unset when the search finds no clues' do
      allow(DRC).to receive(:bput).and_return('fails to turn up any clues')
      allow(DRC).to receive(:message)

      taisidon.send(:investigate, '16026')

      expect(taisidon.instance_variable_get(:@crimescene)).to eq('')
    end

    it 'does nothing (no bput) once the scene is already known' do
      taisidon.instance_variable_set(:@crimescene, 'bar')
      expect(DRC).not_to receive(:bput)

      taisidon.send(:investigate, '16026')
    end

    it 'aborts (exit) when SEARCH itself fails' do
      allow(DRC).to receive(:bput).and_return('I could not find')
      allow(DRC).to receive(:message)

      expect { taisidon.send(:investigate, '16026') }.to raise_error(SystemExit)
    end

    it 'aborts (exit) when blood is found in an unmapped room' do
      allow(DRC).to receive(:bput).and_return('uncovers an area of')
      allow(DRC).to receive(:message)

      expect { taisidon.send(:investigate, '99999') }.to raise_error(SystemExit)
    end
  end

  # ===========================================================================
  # accuse (I/O)
  # ===========================================================================
  describe '#accuse' do
    it 'accuses with the exact command when solved, then empties hands' do
      taisidon.instance_variable_set(:@murderer, 'chef')
      taisidon.instance_variable_set(:@weapon, 'knife')
      taisidon.instance_variable_set(:@crimescene, 'bar')
      allow(DRC).to receive(:message)
      allow(taisidon).to receive(:empty_hands)
      expect(DRC).to receive(:bput).with('accuse chef with the knife in bar', described_class::ACCUSE_SUCCESS)

      taisidon.send(:accuse)

      expect(taisidon).to have_received(:empty_hands)
    end

    it 'does not accuse (no bput) when a clue is missing' do
      taisidon.instance_variable_set(:@murderer, 'chef')
      taisidon.instance_variable_set(:@weapon, '')
      taisidon.instance_variable_set(:@crimescene, 'bar')
      allow(DRC).to receive(:message)
      expect(DRC).not_to receive(:bput)

      taisidon.send(:accuse)
    end
  end

  # ===========================================================================
  # patrol (control flow)
  # ===========================================================================
  describe '#patrol' do
    before do
      taisidon.instance_variable_set(:@murderer, '')
      taisidon.instance_variable_set(:@weapon, 'knife')
      taisidon.instance_variable_set(:@crimescene, '')
      allow(DRCT).to receive(:walk_to)
      allow(taisidon).to receive(:question_suspect)
      allow(taisidon).to receive(:investigate)
      allow(taisidon).to receive(:accuse)
    end

    it 'walks every room when the clues are never found, then accuses' do
      taisidon.send(:patrol)

      expect(DRCT).to have_received(:walk_to).exactly(described_class::PATROL_ROOMS.size).times
      expect(taisidon).to have_received(:accuse).once
    end

    it 'stops walking early once both the murderer and the scene are found' do
      # Simulate the second room revealing both remaining clues.
      call_count = 0
      allow(taisidon).to receive(:investigate) do
        call_count += 1
        if call_count == 2
          taisidon.instance_variable_set(:@murderer, 'chef')
          taisidon.instance_variable_set(:@crimescene, 'bar')
        end
      end

      taisidon.send(:patrol)

      expect(DRCT).to have_received(:walk_to).twice
      expect(taisidon).to have_received(:accuse).once
    end
  end

  # ===========================================================================
  # redeem_and_board (boarding flow, bounded loop)
  # ===========================================================================
  describe '#redeem_and_board' do
    it 'boards after the coordinator takes the pass' do
      allow(DRC).to receive(:bput).and_return('The cruise coordinator takes')
      allow(taisidon).to receive(:board_ship)

      taisidon.send(:redeem_and_board)

      expect(taisidon).to have_received(:board_ship).once
    end

    it 'repeats the redeem, then boards, honoring the "repeat within 10 seconds" prompt' do
      allow(DRC).to receive(:bput).and_return('Once you redeem this', 'The cruise coordinator takes')
      allow(taisidon).to receive(:board_ship)

      taisidon.send(:redeem_and_board)

      expect(DRC).to have_received(:bput).twice
      expect(taisidon).to have_received(:board_ship).once
    end

    it 'skips straight to the morgue when already aboard (task already assigned)' do
      allow(DRC).to receive(:bput).and_return('Your task is to identify')
      allow(taisidon).to receive(:morgue)

      taisidon.send(:redeem_and_board)

      expect(taisidon).to have_received(:morgue).once
    end

    it 'aborts (exit) when there are no boarding passes' do
      allow(DRC).to receive(:bput).and_return('The REDEEM verb is used')
      allow(DRC).to receive(:message)

      expect { taisidon.send(:redeem_and_board) }.to raise_error(SystemExit)
    end

    it 'aborts (exit) when standing in the wrong room' do
      allow(DRC).to receive(:bput).and_return('The representative for a short cruise')
      allow(DRC).to receive(:message)

      expect { taisidon.send(:redeem_and_board) }.to raise_error(SystemExit)
    end

    it 'aborts (exit) on the first unrecognized/timeout response (empty string)' do
      # bput returns '' after its 15s timeout; no case matches, so the else branch aborts
      # immediately -- exactly one attempt, not the full retry loop.
      allow(DRC).to receive(:bput).and_return('')
      allow(DRC).to receive(:message)

      expect { taisidon.send(:redeem_and_board) }.to raise_error(SystemExit)
      expect(DRC).to have_received(:bput).once
    end

    it 'is bounded: gives up (exit) after MAX_REDEEM_ATTEMPTS repeat prompts' do
      allow(DRC).to receive(:bput).and_return('Once you redeem this')
      allow(DRC).to receive(:message)

      expect { taisidon.send(:redeem_and_board) }.to raise_error(SystemExit)
      expect(DRC).to have_received(:bput).exactly(described_class::MAX_REDEEM_ATTEMPTS).times
    end
  end
end
