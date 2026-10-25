# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

# Minimal stub modules for game interaction
class EquipmentManager
  def empty_hands; end
end

load_lic_class('enchant.lic', 'Enchant')

# The game's own lines (from real logs where we have them) set each flag;
# the same words in another player's ESP, speech or whisper do not.
ENCHANT_SPEC_FLAG_LINES = {
  'enchant-focus'    => ["The totem's material struggles to accept the sigil scribing."],
  'enchant-meditate' => ['The traced sigil pattern blurs before your eyes, making it difficult to follow.'],
  'enchant-imbue'    => ['Once finished you sense an imbue spell will be required to continue enchanting.'],
  'enchant-push'     => ["You notice many of the scribed sigils are slowly merging back into the totem's surface."],
  'enchant-sigil'    => ['You need another paradox secondary sigil to continue the enchanting process.  You believe you can STUDY the sigil and then TRACE it on the unfinished item to prepare it for continued scribing.'],
  'enchant-complete' => ["The spell's energies settle upon the totem and seal off the streams of mana.  With the enchanting process completed, you believe it is safe to collect your things once more.",
                         'With the enchantment complete, you collect your things.',
                         'With enchanting complete, you collect your things.'],
  'imbue-failed'     => ['The streams collide, rending the space before you and disrupting the enchantment.'],
  'imbue-backlash'   => ['Suddenly the streams slip through your grasp and cascade violently against each other!']
}.freeze

RSpec.describe Enchant do
  before(:each) do
    reset_data
    $mock_bput_result = nil
    $mock_drci_exists = nil
    $mock_drci_get_item = nil
    $mock_drca_cast_spell = nil
    $left_hand = nil
    $right_hand = nil
  end

  # Helper: create a bare Enchant instance without running initialize
  def build_instance(**overrides)
    instance = Enchant.allocate
    # Set default ivars
    instance.instance_variable_set(:@settings, OpenStruct.new(
                                                 crafting_container: 'backpack',
                                                 crafting_items_in_container: ['burin'],
                                                 enchanting_belt: 'toolbelt',
                                                 mark_crafted_goods: false,
                                                 worn_trashcan: 'bucket',
                                                 worn_trashcan_verb: 'put',
                                                 enchanting_tools: ['brazier', 'fount', 'aug loop', 'rod', 'burin'],
                                                 master_crafting_book: nil,
                                                 cube_armor_piece: nil
                                               ))
    instance.instance_variable_set(:@bag, 'backpack')
    instance.instance_variable_set(:@bag_items, ['burin'])
    instance.instance_variable_set(:@belt, 'toolbelt')
    instance.instance_variable_set(:@brazier, 'brazier')
    # @brazier_ref is derived in initialize (which these specs bypass); the
    # command-building methods interpolate it directly.
    instance.instance_variable_set(:@brazier_ref, 'brazier')
    instance.instance_variable_set(:@fount, 'fount')
    instance.instance_variable_set(:@loop, 'aug loop')
    instance.instance_variable_set(:@imbue_wand, 'rod')
    instance.instance_variable_set(:@burin, 'burin')
    instance.instance_variable_set(:@item, 'totem')
    instance.instance_variable_set(:@baseitem, 'totem')
    instance.instance_variable_set(:@use_own_brazier, true)
    instance.instance_variable_set(:@worn_trashcan, 'bucket')
    instance.instance_variable_set(:@worn_trashcan_verb, 'put')
    instance.instance_variable_set(:@stamp, false)
    instance.instance_variable_set(:@equipment_manager, EquipmentManager.new)
    overrides.each { |k, v| instance.instance_variable_set(:"@#{k}", v) }
    instance
  end

  # The shapes other players' text arrives in. bput reads stripped text
  # (ESP, say, whisper); Flags see the raw XML server line as well.
  def player_lines(text)
    [%([General][Mallory] "#{text}"), %(Mallory says, "#{text}"), %(Mallory whispers, "#{text}")]
  end

  def raw_player_lines(text)
    player_lines(text) + [
      %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>),
      %(<preset id='speech'>Mallory says</preset>, "#{text}"),
      %(<pushStream id="whispers"/><preset id="whisper">Mallory whispers,</preset> "#{text}"<popStream/>)
    ]
  end

  # Feed a server line through the registered Flags matchers, the way
  # Lich's DRParser.check_events does for every downstream line.
  def deliver(line)
    Flags.matchers.each do |key, regexes|
      regexes.each do |regex|
        if (match = line.match(regex))
          Flags[key] = match
          break
        end
      end
    end
  end

  # lich-5 DRC.bput matching: Strings compile to /x/i, incoming lines are read
  # in order, the first line matching any pattern wins and bput returns the
  # matched text ('' when nothing matches before the timeout).
  def model_bput(lines, patterns)
    regexes = patterns.flatten.map { |p| p.is_a?(Regexp) ? p : /#{p}/i }
    lines.each do |line|
      regexes.each { |re| (m = line.match(re)) && (return m.to_a.first) }
    end
    ''
  end

  # Stub DRC.bput with model_bput. `replies` maps a command regex to the
  # incoming lines for each time that command is sent. Returns the commands sent.
  def stub_bput_replies(replies)
    sent = []
    allow(DRC).to receive(:bput) do |command, *patterns|
      sent << command
      key = replies.keys.find { |k| k.match?(command) }
      model_bput(Array(key && replies[key].shift), patterns)
    end
    sent
  end

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  describe 'constants' do
    it 'defines ANALYZE_READY_PATTERNS as frozen array' do
      expect(Enchant::ANALYZE_READY_PATTERNS).to be_frozen
      expect(Enchant::ANALYZE_READY_PATTERNS).to be_an(Array)
    end

    it 'defines BRAZIER_CONTENTS_PATTERN with named capture' do
      pattern = Enchant::BRAZIER_CONTENTS_PATTERN
      match = pattern.match('On the brass brazier you see a fount and a totem.')
      expect(match).not_to be_nil
      expect(match[:items]).to eq('a fount and a totem')
    end

    it 'defines FLAG_NAMES as frozen array' do
      expect(Enchant::FLAG_NAMES).to be_frozen
      expect(Enchant::FLAG_NAMES).to include('enchant-complete')
    end
  end

  # ---------------------------------------------------------------------------
  # setup_flags / cleanup_flags
  # ---------------------------------------------------------------------------

  describe '#setup_flags' do
    it 'calls Flags.add for all required flags' do
      instance = build_instance

      expect(Flags).to receive(:add).with('enchant-focus', anything)
      expect(Flags).to receive(:add).with('enchant-meditate', anything)
      expect(Flags).to receive(:add).with('enchant-imbue', anything)
      expect(Flags).to receive(:add).with('enchant-push', anything)
      expect(Flags).to receive(:add).with('enchant-sigil', anything)
      expect(Flags).to receive(:add).with('enchant-complete', anything, anything, anything, anything)
      expect(Flags).to receive(:add).with('imbue-failed', anything)
      expect(Flags).to receive(:add).with('imbue-backlash', anything)

      instance.send(:setup_flags)
    end
  end

  describe 'flag matchers' do
    before { build_instance.send(:setup_flags) }

    ENCHANT_SPEC_FLAG_LINES.each do |key, lines|
      it "sets #{key} on the game's own line" do
        lines.each do |line|
          Flags.reset(key)
          deliver(line)
          expect(Flags[key]).to be_truthy, line
        end
      end

      it "ignores #{key} words in other players' ESP, speech and whispers" do
        lines.map { |line| line.sub(/\A.*?  (?=With the enchanting)/, '') }.each do |text|
          raw_player_lines(text).each do |line|
            deliver(line)
            expect(Flags[key]).to be_falsey, line
          end
        end
      end
    end

    it 'keeps the sigil type the scribing loop reads' do
      deliver(ENCHANT_SPEC_FLAG_LINES['enchant-sigil'].first)
      expect(Flags['enchant-sigil'][:type]).to eq('paradox ')
      expect(Flags['enchant-sigil'][:order]).to eq('secondary')
    end
  end

  describe '#cleanup_flags' do
    it 'calls Flags.delete for all flags' do
      instance = build_instance

      Enchant::FLAG_NAMES.each do |flag|
        expect(Flags).to receive(:delete).with(flag)
      end

      instance.send(:cleanup_flags)
    end
  end

  # ---------------------------------------------------------------------------
  # empty_brazier - named capture extraction
  # ---------------------------------------------------------------------------

  describe '#empty_brazier' do
    it 'extracts items using named capture from brazier contents' do
      instance = build_instance

      allow(DRC).to receive(:bput).and_return('On the brass brazier you see a fount and a totem.')
      expect(DRCI).to receive(:get_item?).with('fount', 'brazier').and_return(true)
      expect(DRCI).to receive(:get_item?).with('totem', 'brazier').and_return(true)
      expect(DRCC).to receive(:stow_crafting_item).twice

      instance.send(:empty_brazier)
    end

    it 'handles nothing on brazier' do
      instance = build_instance

      allow(DRC).to receive(:bput).and_return('There is nothing')
      expect(DRCI).not_to receive(:get_item?)

      instance.send(:empty_brazier)
    end

    it 'logs error when item cannot be retrieved' do
      instance = build_instance

      allow(DRC).to receive(:bput).and_return('On the brass brazier you see a fount.')
      expect(DRCI).to receive(:get_item?).with('fount', 'brazier').and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to get fount/)

      instance.send(:empty_brazier)
    end

    it "takes only what the game lists, not what another player says is there" do
      player_lines('On the brazier you see a burin and a rod.').each do |line|
        stub_bput_replies(/^look on/ => [[line, 'There is nothing on the brazier.']])
        expect(DRCI).not_to receive(:get_item?)

        build_instance.send(:empty_brazier)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # scribe - the main bug fix (waitrt? before recursive call)
  # ---------------------------------------------------------------------------

  describe '#scribe' do
    it 'checks enchant-complete flag before scribing again' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-focus').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-meditate').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-push').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-imbue').and_return(nil)
      allow(Flags).to receive(:[]).with('imbue-backlash').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-complete').and_return(true)

      expect(instance).to receive(:handle_complete_flag)
      expect(DRC).not_to receive(:bput)

      instance.send(:scribe)
    end

    it 'checks enchant-sigil flag and handles it' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return({ type: 'induction ', order: 'primary' })

      expect(instance).to receive(:handle_sigil_flag)

      instance.send(:scribe)
    end

    it 'checks imbue-backlash flag' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-focus').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-meditate').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-push').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-imbue').and_return(nil)
      allow(Flags).to receive(:[]).with('imbue-backlash').and_return(true)

      expect(instance).to receive(:handle_backlash_flag)

      instance.send(:scribe)
    end

    {
      'enchant-sigil'    => :handle_sigil_flag,
      'enchant-focus'    => :handle_focus_flag,
      'enchant-meditate' => :handle_meditate_flag,
      'enchant-push'     => :handle_push_flag,
      'enchant-imbue'    => :handle_imbue_flag,
      'imbue-backlash'   => :handle_backlash_flag,
      'enchant-complete' => :handle_complete_flag
    }.each do |key, handler|
      it "keeps scribing through other players' #{key} lines and acts on the game's own" do
        instance = build_instance
        instance.send(:setup_flags)
        texts = ENCHANT_SPEC_FLAG_LINES[key].map { |line| line.sub(/\A.*?  (?=With the enchanting)/, '') }
        heard = texts.flat_map { |text| raw_player_lines(text) } + [ENCHANT_SPEC_FLAG_LINES[key].first]
        scribes = 0
        allow(DRC).to receive(:bput) do |command, *_patterns|
          if command.start_with?('scribe ')
            scribes += 1
            deliver(heard.shift)
          end
          'Roundtime: 3 sec.'
        end
        allow(instance).to receive(:waitrt?)
        handled_after = nil
        allow(instance).to receive(handler) { handled_after = scribes }
        expect(DRC).not_to receive(:wait_for_script_to_complete)

        instance.send(:scribe)

        expect(handled_after).to eq(texts.size * 6 + 1)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # handle_sigil_flag
  # ---------------------------------------------------------------------------

  describe '#handle_sigil_flag' do
    it 'extracts sigil type from flag and traces it' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return({ type: 'induction ', order: 'primary' })
      allow(Flags).to receive(:reset).with('enchant-sigil')

      expect(DRCC).to receive(:stow_crafting_item).with('burin', 'backpack', 'toolbelt')
      expect(instance).to receive(:trace_sigil).with('induction')
      expect(DRCC).to receive(:get_crafting_item)
      expect(instance).to receive(:scribe)

      instance.send(:handle_sigil_flag)
    end

    it 'defaults to congruence sigil when type is empty' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return({ type: '', order: 'primary' })
      allow(Flags).to receive(:reset).with('enchant-sigil')

      expect(instance).to receive(:trace_sigil).with('congruence')
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCC).to receive(:get_crafting_item)
      allow(instance).to receive(:scribe)

      instance.send(:handle_sigil_flag)
    end
  end

  # ---------------------------------------------------------------------------
  # trace_sigil
  # ---------------------------------------------------------------------------

  describe '#trace_sigil' do
    it 'gets sigil, studies it, and traces on item' do
      instance = build_instance

      expect(DRCI).to receive(:get_item?).with('induction sigil').and_return(true)
      expect(DRC).to receive(:bput).with('study my induction sigil', Enchant::SIGIL_STUDY_SUCCESS)
      expect(DRC).to receive(:bput).with('trace totem on brazier', Enchant::SIGIL_TRACE_SUCCESS)

      instance.send(:trace_sigil, 'induction')
    end

    it 'logs error and returns early when sigil not found' do
      instance = build_instance

      expect(DRCI).to receive(:get_item?).with('induction sigil').and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to get induction sigil/)
      expect(DRC).not_to receive(:bput)

      instance.send(:trace_sigil, 'induction')
    end
  end

  # ---------------------------------------------------------------------------
  # handle_complete_flag
  # ---------------------------------------------------------------------------

  describe '#handle_complete_flag' do
    it 'outputs completion message and calls cleanup' do
      instance = build_instance

      expect(Lich::Messaging).to receive(:msg).with('plain', 'Enchant: Enchanting complete!')
      expect(instance).to receive(:cleanup)

      instance.send(:handle_complete_flag)
    end

    it 'stamps item when @stamp is true' do
      instance = build_instance(stamp: true)

      allow(Lich::Messaging).to receive(:msg)
      allow(instance).to receive(:cleanup)
      expect(instance).to receive(:stamp_item).with('totem')

      instance.send(:handle_complete_flag)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_backlash_flag
  # ---------------------------------------------------------------------------

  describe '#handle_backlash_flag' do
    it 'outputs error message, cleans up, and goes to safe room' do
      instance = build_instance

      expect(Lich::Messaging).to receive(:msg).with('bold', /Imbue backlash occurred/)
      expect(instance).to receive(:cleanup)
      expect(DRC).to receive(:wait_for_script_to_complete).with('safe-room', ['force'])

      instance.send(:handle_backlash_flag)
    end
  end

  # ---------------------------------------------------------------------------
  # imbue
  # ---------------------------------------------------------------------------

  describe '#imbue' do
    context 'with waggle spell config' do
      it 'casts spell using DRCA and retries on failure' do
        instance = build_instance(
          settings: OpenStruct.new(
            'waggle_sets' => { 'imbue' => { 'Imbue' => { 'mana' => 20 } } }
          )
        )

        # First call fails, second succeeds
        call_count = 0
        allow(DRCA).to receive(:cast_spell?) do
          call_count += 1
          call_count > 1
        end
        allow(Flags).to receive(:reset).with('enchant-imbue')

        expect(Lich::Messaging).to receive(:msg).with('bold', /Casting Imbue failed/).once

        instance.send(:imbue)
      end
    end

    context 'with imbue wand' do
      it 'waves wand at item on brazier' do
        instance = build_instance(
          settings: OpenStruct.new('waggle_sets' => { 'imbue' => {} })
        )
        $left_hand = nil

        expect(DRCC).to receive(:get_crafting_item).with('rod', 'backpack', ['burin'], 'toolbelt')
        expect(DRC).to receive(:bput).with(
          'wave rod at totem on brazier',
          Enchant::IMBUE_WAND_SUCCESS,
          Enchant::IMBUE_WAND_SIGIL_NEEDED,
          Enchant::IMBUE_WAND_FAILED
        ).and_return('Roundtime')
        allow(Flags).to receive(:reset).with('enchant-imbue')

        instance.send(:imbue)
      end

      it 'retries when wand fails' do
        instance = build_instance(
          settings: OpenStruct.new('waggle_sets' => { 'imbue' => {} })
        )
        $left_hand = 'rod'

        # First call fails, second succeeds
        call_count = 0
        allow(DRC).to receive(:bput) do
          call_count += 1
          call_count > 1 ? 'Roundtime' : 'The streams collide, rending the space before you and disrupting the enchantment'
        end
        allow(Flags).to receive(:reset).with('enchant-imbue')

        expect(Lich::Messaging).to receive(:msg).with('bold', /Imbue wand failed/).once

        instance.send(:imbue)
      end

      it "waves once when another player says the wand-failure words" do
        player_lines('The streams collide, rending the space before you and disrupting the enchantment.').each do |line|
          instance = build_instance(settings: OpenStruct.new('waggle_sets' => { 'imbue' => {} }))
          $left_hand = 'rod'
          sent = stub_bput_replies(/^wave rod/ => [[line, 'Roundtime: 5 sec.']])
          allow(Flags).to receive(:reset).with('enchant-imbue')
          expect(Lich::Messaging).not_to receive(:msg)

          instance.send(:imbue)

          expect(sent).to eq(['wave rod at totem on brazier']), line
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # clean_brazier
  # ---------------------------------------------------------------------------

  describe '#clean_brazier' do
    it 'cleans brazier when successful' do
      instance = build_instance

      expect(DRC).to receive(:bput).with(
        'clean brazier',
        Enchant::CLEAN_SUCCESS,
        Enchant::CLEAN_NOTHING,
        Enchant::CLEAN_NOT_LIT
      ).and_return('You prepare to clean off the brazier')
      expect(DRC).to receive(:bput).with('clean brazier', Enchant::CLEAN_SINGED)

      instance.send(:clean_brazier)
    end

    it 'stows left hand when brazier not lit' do
      instance = build_instance
      $left_hand = 'burin'

      allow(DRC).to receive(:bput).and_return('The brazier is not currently lit')
      expect(DRCC).to receive(:stow_crafting_item).with('burin', 'backpack', 'toolbelt')

      instance.send(:clean_brazier)
    end

    it "does not confirm the clean when another player says the prompt words" do
      player_lines('You prepare to clean off the brazier.').each do |line|
        sent = stub_bput_replies(/^clean/ => [[line, 'There is nothing on the brazier to clean.']])

        build_instance.send(:clean_brazier)

        expect(sent).to eq(['clean brazier']), line
      end
    end

    it "does not stow a hand when another player says the brazier is not lit" do
      player_lines('The brazier is not currently lit.').each do |line|
        $left_hand = 'burin'
        stub_bput_replies(/^clean/ => [[line, 'You prepare to clean off the brazier.'], []])
        expect(DRCC).not_to receive(:stow_crafting_item)

        build_instance.send(:clean_brazier)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # study_recipe / place_item_on_brazier - get and put replies
  # ---------------------------------------------------------------------------

  describe '#study_recipe' do
    it "does not clean the brazier when another player says it is too dangerous" do
      player_lines('That is far too dangerous!').each do |line|
        instance = build_instance
        stub_bput_replies(/^get my totem/ => [[line, 'You get a totem from inside your backpack.']])
        allow(instance).to receive(:place_item_on_brazier)
        expect(instance).not_to receive(:clean_brazier)
        expect(instance).not_to receive(:empty_brazier)

        instance.send(:study_recipe)
      end
    end

    it 'cleans the brazier when the game says it is too dangerous' do
      instance = build_instance
      stub_bput_replies(/^get my totem/ => [['That is far too dangerous to do while the brazier holds something.']])
      allow(instance).to receive(:place_item_on_brazier)
      expect(instance).to receive(:clean_brazier)
      expect(instance).to receive(:empty_brazier)

      instance.send(:study_recipe)
    end
  end

  describe '#place_item_on_brazier' do
    it "cleans the brazier when the game asks, despite another player's flick words" do
      player_lines('With a flick, you pop open the lid.').each do |line|
        instance = build_instance
        stub_bput_replies(/^put my totem/ => [[line, 'You must first clean the brazier.']])
        expect(instance).to receive(:clean_brazier)
        allow(instance).to receive(:empty_brazier)
        allow(instance).to receive(:place_item_inner)

        instance.send(:place_item_on_brazier)
      end
    end

    it "treats the game's own flick line as placed" do
      instance = build_instance
      stub_bput_replies(/^put my totem/ => [["With a flick, you pop open the brazier's lid.  A tall and strong flame leaps into being within the brazier.  Carefully you place your totem atop the brazier."]])
      expect(instance).not_to receive(:clean_brazier)
      expect(instance).to receive(:waitrt?)

      instance.send(:place_item_on_brazier)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_new_enchant - fount existence check
  # ---------------------------------------------------------------------------

  describe '#handle_new_enchant' do
    it 'exits early with message when fount not found' do
      instance = build_instance(item: 'totem')
      $mock_drci_exists = false

      allow(instance).to receive(:study_recipe)
      expect(Lich::Messaging).to receive(:msg).with('bold', /fount not found in inventory/)
      expect(instance).to receive(:cleanup)
      expect(instance).not_to receive(:imbue)

      instance.send(:handle_new_enchant)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_resume
  # ---------------------------------------------------------------------------

  describe '#handle_resume' do
    it 'logs error for unexpected analyze result' do
      instance = build_instance
      $mock_bput_result = 'Something unexpected'

      allow(DRCC).to receive(:get_crafting_item)
      expect(Lich::Messaging).to receive(:msg).with('bold', /Unexpected analyze result/)

      instance.send(:handle_resume)
    end

    it "follows the game's analysis, not another player's" do
      player_lines('The totem is ready for additional scribing.').each do |line|
        instance = build_instance
        stub_bput_replies(/^analyze/ => [[line, 'The totem awaits the application of an imbue spell to advance the enchanting process.']])
        allow(DRCC).to receive(:get_crafting_item)
        expect(instance).to receive(:handle_imbue_resume)
        expect(instance).not_to receive(:scribe)

        instance.send(:handle_resume)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # handle_imbue_resume - regression: single-item brazier must not time out
  # (issue #7553)
  # ---------------------------------------------------------------------------

  describe '#handle_imbue_resume' do
    it 'imbues directly when the fount is the only item on the brazier' do
      instance = build_instance
      allow(DRC).to receive(:bput).and_return('On the brass brazier you see a fount.')

      expect(instance).to receive(:imbue)
      expect(DRCC).not_to receive(:get_crafting_item)

      instance.send(:handle_imbue_resume)
    end

    it 'imbues directly when the fount is present alongside other items' do
      instance = build_instance
      allow(DRC).to receive(:bput).and_return('On the brass brazier you see a fount and a totem.')

      expect(instance).to receive(:imbue)
      expect(DRCC).not_to receive(:get_crafting_item)

      instance.send(:handle_imbue_resume)
    end

    it 'detects the fount on a public enchanter\'s brazier' do
      instance = build_instance
      allow(DRC).to receive(:bput).and_return("On the enchanter's brazier you see a fount.")

      expect(instance).to receive(:imbue)
      expect(DRCC).not_to receive(:get_crafting_item)

      instance.send(:handle_imbue_resume)
    end

    it 'fetches and waves a fount when none is on the brazier' do
      instance = build_instance
      allow(DRC).to receive(:bput).with(/^look on/, anything, anything)
                                  .and_return('On the brass brazier you see a totem.')
      allow(DRC).to receive(:bput).with(/^wave my fount/, anything, anything)
                                  .and_return('The fragile mana fount is not required')

      expect(DRCC).to receive(:get_crafting_item).with('fount', 'backpack', ['burin'], 'toolbelt')
      expect(DRCC).to receive(:stow_crafting_item).with('fount', 'backpack', 'toolbelt')
      expect(instance).to receive(:imbue)

      instance.send(:handle_imbue_resume)
    end

    it "keeps the fount when another player says it is not required" do
      wave = 'You slowly wave the fount over and around the totem.  Motes of light rise up from the brazier and encircle your hand.  Satisfied the bonding is complete, you place the fount atop the totem.'
      player_lines('The fragile mana fount is not required.').each do |line|
        instance = build_instance
        stub_bput_replies(/^look on/ => [['On the brass brazier you see a totem.']], /^wave my fount/ => [[line, wave]])
        allow(DRCC).to receive(:get_crafting_item)
        expect(DRCC).not_to receive(:stow_crafting_item)
        allow(instance).to receive(:imbue)

        instance.send(:handle_imbue_resume)
      end
    end

    it "reads the game's look reply, not another player's" do
      player_lines('There is nothing on it.').each do |line|
        result = model_bput([line, 'On the brass brazier you see a fount.'], [Enchant::BRAZIER_LOOK_PATTERN, Enchant::BRAZIER_EMPTY])
        expect(result).to start_with('On the brass brazier you see'), line
      end
    end
  end
end
