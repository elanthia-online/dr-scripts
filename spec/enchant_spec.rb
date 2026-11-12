# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('enchant.lic', 'Enchant')

# The game's own lines (from real logs where we have them) set each flag;
# the same words in another player's ESP, speech or whisper do not.
ENCHANT_SPEC_FLAG_LINES = {
  'enchant-focus'          => ["The totem's material struggles to accept the sigil scribing."],
  'enchant-meditate'       => ['The traced sigil pattern blurs before your eyes, making it difficult to follow.'],
  'enchant-imbue'          => ['Once finished you sense an imbue spell will be required to continue enchanting.'],
  'enchant-push'           => ["You notice many of the scribed sigils are slowly merging back into the totem's surface."],
  'enchant-sigil'          => ['You need another paradox secondary sigil to continue the enchanting process.  You believe you can STUDY the sigil and then TRACE it on the unfinished item to prepare it for continued scribing.'],
  'enchant-complete'       => ["The spell's energies settle upon the totem and seal off the streams of mana.  With the enchanting process completed, you believe it is safe to collect your things once more.",
                               'With the enchantment complete, you collect your things.',
                               'With enchanting complete, you collect your things.'],
  'imbue-failed'           => ['The streams collide, rending the space before you and disrupting the enchantment.'],
  'imbue-backlash'         => ['Suddenly the streams slip through your grasp and cascade violently against each other!'],
  'enchant-fount-returned' => ['You collect the fount and place it at your feet.']
}.freeze

# Game lines copied from two Dorhum task runs (2026-11, spongestone and virga
# wand). Keys name the moment in the run; values are the lines in order,
# blank lines kept, as the game sent them after the command.
ENCHANT_LOG = {
  study_instructions_again: ['The delicate nature of the instructions will cause them to wear out with use.',
                             '',
                             '[These instructions have only 9 uses remaining.  Study them again to proceed.]'],
  study_spongestone_instructions: ['You scan the spongestone instructions with a glance and completely understand all facets of the design.',
                                   'You now feel ready to begin the crafting process.',
                                   'Roundtime: 7 sec.'],
  study_wand_instructions: ['You scan the wand instructions with a glance and completely understand all facets of the design.',
                            'You now feel ready to begin the crafting process.',
                            'Roundtime: 6 sec.'],
  get_rock: ['You get a rock from inside your duffel bag.'],
  get_wand: ['You get a redwood wand from inside your duffel bag.'],
  put_glance: ['You glance down at the smoking brazier and reconsider if you wish to begin enchanting.',
               '',
               "[Putting an item on the brazier begins the enchanting process.  This process can enhance the item, or cause serious damage to it and the enchanter.  Put your item onto the brazier again in the next 30 seconds, to proceed.  You've been warned!]"],
  put_rock: ["With a flick, you pop open the brazier's lid.  Tiny motes briefly encircle the almond-shaped flame now burning within the brazier.  Carefully you place your rock atop the brazier.",
             '',
             'Once finished you sense an imbue spell will be required to continue enchanting.',
             'Roundtime: 13 sec.',
             '',
             "You need another mana fount to continue crafting a rock.  WAVE a functional mana fount at the a rock to align the item with the fount's focusing properties.  Then continue the process with the casting of an imbue spell."],
  put_wand: ["With a flick, you pop open the brazier's lid.  A tall and strong flame leaps into being within the brazier.  Carefully you place your wand atop the brazier.",
             '',
             'Once finished you sense an imbue spell will be required to continue enchanting.',
             'Roundtime: 13 sec.',
             '',
             "You need another mana fount to continue crafting a redwood wand.  WAVE a functional mana fount at the a redwood wand to align the item with the fount's focusing properties.  Then continue the process with the casting of an imbue spell."],
  wave_fount_rock: ['You slowly wave the fount over and around the rock.  Motes of light rise up from the brazier and encircle your hand.  Satisfied the bonding is complete, you place the fount atop the rock.'],
  wave_fount_wand: ['You slowly wave the fount over and around the wand.  Motes of light rise up from the brazier and encircle your hand.  Satisfied the bonding is complete, you place the fount atop the wand.'],
  imbue_wants_congruence: ['The spell is channeled through the fount hanging above, and down into the rock.  Not a single stream avoids your cautious analysis as you conduct them into arrangements.',
                           'Roundtime: 15 sec.',
                           '',
                           'You need another congruence primary sigil to continue the enchanting process.  You believe you can STUDY the sigil and then TRACE it on the unfinished item to prepare it for continued scribing.',
                           '',
                           '[Sigils can be added to the artifact to continue crafting.]'],
  imbue_wants_induction: ['The spell is channeled through the fount hanging above, and down into the wand.  After focusing the streams into ordered groups you then direct them into exacting positions.',
                          'Roundtime: 7 sec.',
                          '',
                          'You need another induction primary sigil to continue the enchanting process.  You believe you can STUDY the sigil and then TRACE it on the unfinished item to prepare it for continued scribing.',
                          '',
                          '[Sigils can be added to the artifact to continue crafting.]'],
  study_sigil: ['You study the sigil-scroll and commit the design to memory.', 'Roundtime: 13 sec.'],
  trace_rock: ['Recalling the intricacies of the sigil, you trace its form over the rock with your finger and prepare to begin scribing it more permanently with a burin.', 'Roundtime: 1 sec.'],
  trace_wand: ['Recalling the intricacies of the sigil, you trace its form over the wand with your finger and prepare to begin scribing it more permanently with a burin.', 'Roundtime: 1 sec.'],
  scribe_rock: ['You lean in towards your rock and begin scribing marks along it with a fey-bone burin wrapped within a lattice of steelsilk knotwork.  In and out you weave a decisive tapestry of patterns across the rock with your burin.',
                'Roundtime: 17 sec.'],
  scribe_wand: ['You lean in towards your wand and begin scribing marks along it with a fey-bone burin wrapped within a lattice of steelsilk knotwork.  Through effortless control of the burin you capture the pattern in razor-sharp detail.',
                'Roundtime: 17 sec.'],
  scribe_rock_merging: ["You lean in towards your rock and begin scribing marks along it with a fey-bone burin wrapped within a lattice of steelsilk knotwork.  With skilled flourishes of the burin you capture the sigil pattern's precision and complexity.",
                        '',
                        "You notice many of the scribed sigils are slowly merging back into the rock's surface.",
                        'Roundtime: 10 sec.'],
  scribe_rock_wants_decay: ['You lean in towards your rock and begin scribing marks along it with a fey-bone burin wrapped within a lattice of steelsilk knotwork.  Through effortless control of the burin you capture the pattern in razor-sharp detail.',
                            'Roundtime: 19 sec.',
                            '',
                            'You need another decay secondary sigil to continue the enchanting process.  You believe you can STUDY the sigil and then TRACE it on the unfinished item to prepare it for continued scribing.',
                            '',
                            '[Sigils can be added to the artifact to continue crafting.]'],
  scribe_rock_blurs: ['You lean in towards your rock and begin scribing marks along it with a fey-bone burin wrapped within a lattice of steelsilk knotwork.  In and out you weave a decisive tapestry of patterns across the rock with your burin.',
                      '',
                      'The traced sigil pattern blurs before your eyes, making it difficult to follow.',
                      'Roundtime: 14 sec.'],
  scribe_wand_struggles: ["You lean in towards your wand and begin scribing marks along it with a fey-bone burin wrapped within a lattice of steelsilk knotwork.  With skilled flourishes of the burin you capture the sigil pattern's precision and complexity.",
                          "The wand's material struggles to accept the sigil scribing.",
                          'Roundtime: 17 sec.'],
  scribe_wand_wants_imbue: ['You lean in towards your wand and begin scribing marks along it with a fey-bone burin wrapped within a lattice of steelsilk knotwork.  With skilled flourishes of the burin you capture the sigil pattern\'s precision and complexity.',
                            'Once finished you sense an imbue spell will be required to continue enchanting.',
                            'Roundtime: 13 sec.'],
  push_rock: ['You wave the loop near the rock to visualize and adjust the disrupted mana streams.  A tall and strong flame leaps into being within the loop.', 'Roundtime: 19 sec.'],
  focus_wand: ["You adjust the brazier's intensity and peer closely at the wand.  With precise movements you adjust the brightness and trace out your next steps.", 'Roundtime: 19 sec.'],
  meditate_wants_imbue: ['You lean in close to the fount, close your eyes and calmly meditate.  The fount rings with mellifluous tones that clarify each design in your thoughts.',
                         '',
                         'Once finished you sense an imbue spell will be required to continue enchanting.',
                         'Roundtime: 12 sec.'],
  imbue_completes_rock: ['The spell is channeled through the fount hanging above, and down into the rock.  Not a single stream avoids your cautious analysis as you conduct them into arrangements.',
                         'Roundtime: 17 sec.',
                         "The spell's energies settle upon the rock and seal off the pattern.  With the enchanting process completed, you believe it is safe to collect your things once more.",
                         'You collect the fount and place it at your feet.',
                         'You collect the rock and place it at your feet.'],
  # The fount's last use: only the rock comes back (log 1, the eighth and last item).
  imbue_completes_rock_fount_used_up: ['The spell is channeled through the fount hanging above, and down into the rock.  With expert precision you rapidly direct each stream into place around the rock.',
                                       'Roundtime: 16 sec.',
                                       "The spell's energies settle upon the rock and seal off the pattern.  With the enchanting process completed, you believe it is safe to collect your things once more.",
                                       'You collect the rock and place it at your feet.'],
  imbue_completes_wand: ['The spell is channeled through the fount hanging above, and down into the wand.  Not a single stream avoids your cautious analysis as you conduct them into arrangements.',
                         'Roundtime: 10 sec.',
                         "The spell's energies settle upon the wand and seal off the pattern.  With the enchanting process completed, you believe it is safe to collect your things once more.",
                         'You collect the fount and place it at your feet.',
                         'You collect the wand and place it at your feet.']
}.freeze

# A scripted game for whole-run specs. The transcript is every command the
# script sends (with the game's reply lines) and every commons call it makes,
# in order. Anything sent out of order fails the example, so a passing run
# pins the exact sequence. Hands follow the transcript's gives:/takes:, and
# every reply line goes through the registered Flags matchers the way Lich's
# parser feeds each downstream line.
class EnchantSpecGame
  Step = Struct.new(:kind, :name, :args, :lines, :returns, :gives, :takes, keyword_init: true)

  attr_reader :messages, :feet

  def initialize
    @steps = []
    @messages = []
    @feet = []
    $right_hand = nil
    $left_hand = nil
  end

  # A game command and the lines it gets back.
  def command(text, lines = [], gives: nil, takes: nil)
    @steps << Step.new(kind: :command, name: text, lines: lines, gives: gives, takes: takes)
  end

  # A commons call, with what it returns and what it does to the hands.
  # `gives: { from_feet: item }` picks the item up off the floor, and
  # `gives: { left: item }` puts it in the left hand. A give with both hands
  # full fails, as the game's "You need a free hand" would.
  def call(name, *args, returns: true, gives: nil, takes: nil, lines: [])
    @steps << Step.new(kind: :call, name: name, args: args, returns: returns, gives: gives, takes: takes, lines: lines)
  end

  def bput(text, patterns)
    step = next_step(:command, text, nil)
    apply_hands(step)
    deliver(step.lines)
    regexes = patterns.flatten.map { |p| p.is_a?(Regexp) ? p : /#{p}/i }
    step.lines.each do |line|
      regexes.each { |re| (m = line.match(re)) && (return m.to_a.first) }
    end
    ''
  end

  def commons(name, *args)
    step = next_step(:call, name, args)
    apply_hands(step)
    deliver(step.lines)
    step.returns
  end

  def remaining
    @steps.map { |s| s.kind == :command ? s.name : "#{s.name}(#{s.args.map(&:inspect).join(', ')})" }
  end

  def hands
    [$right_hand, $left_hand]
  end

  private

  def next_step(kind, name, args)
    step = @steps.shift
    sent = kind == :command ? name : "#{name}(#{args.map(&:inspect).join(', ')})"
    wanted = step && (step.kind == :command ? step.name : "#{step.name}(#{step.args.map(&:inspect).join(', ')})")
    raise "unexpected #{sent.inspect}; the transcript wanted #{wanted.inspect}" unless step && step.kind == kind && step.name == name && (args.nil? || step.args == args)

    step
  end

  def apply_hands(step)
    Array(step.takes).each { |item| take(item) }
    @feet.concat(feet_from(step.lines))
    give = step.gives
    return unless give

    if give.is_a?(Hash) && give[:left]
      $left_hand = give[:left]
      return
    end
    if give.is_a?(Hash) && give[:from_feet]
      @feet.delete_at(@feet.index(give[:from_feet]) || @feet.size)
      give = give[:from_feet]
    end
    raise "no free hand for #{give.inspect}: the hands hold #{hands.inspect}" if $right_hand && $left_hand

    $right_hand.nil? ? ($right_hand = give) : ($left_hand = give)
  end

  def take(item)
    if $right_hand&.include?(item) || item.include?($right_hand.to_s) && $right_hand
      $right_hand = nil
    elsif $left_hand&.include?(item) || item.include?($left_hand.to_s) && $left_hand
      $left_hand = nil
    else
      raise "takes #{item.inspect}, but the hands hold #{hands.inspect}"
    end
  end

  def feet_from(lines)
    lines.filter_map { |line| line[/^You collect the (\w+) and place it at your feet/, 1] }
  end

  def deliver(lines)
    lines.each do |line|
      Flags.matchers.each do |key, regexes|
        regexes.each do |regex|
          if (match = line.match(regex))
            Flags[key] = match
            break
          end
        end
      end
    end
  end
end

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
      expect(pattern.match("On the enchanter's brazier you see a thin mana fount.")[:items]).to eq('a thin mana fount')
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
    it 'registers a matcher for every flag in FLAG_NAMES, and no other' do
      build_instance.send(:setup_flags)

      expect(Flags.matchers.keys).to match_array(Enchant::FLAG_NAMES)
    end

    it 'gives enchant-complete its four completion lines' do
      build_instance.send(:setup_flags)

      expect(Flags.matchers['enchant-complete'].size).to eq(4)
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

    it 'takes every item when the game lists three or more' do
      instance = build_instance
      allow(DRC).to receive(:bput).and_return('On the brass brazier you see a rock, a fount and a totem.')
      allow(DRCC).to receive(:stow_crafting_item)

      %w[rock fount totem].each do |noun|
        expect(DRCI).to receive(:get_item?).with(noun, 'brazier').and_return(true)
      end

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

    it "empties the public enchanter's brazier" do
      instance = build_instance(brazier: "enchanter's brazier", brazier_ref: "enchanter's brazier", use_own_brazier: false)
      stub_bput_replies(/^look on/ => [["On the enchanter's brazier you see a fount and a totem."]])

      expect(DRCI).to receive(:get_item?).with('fount', "enchanter's brazier").and_return(true)
      expect(DRCI).to receive(:get_item?).with('totem', "enchanter's brazier").and_return(true)
      expect(DRCC).to receive(:stow_crafting_item).twice

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

  describe '#next_scribe_step' do
    let(:instance) { build_instance }

    before(:each) { instance.send(:setup_flags) }

    it 'is nil when the game asked for nothing, so the next step is a scribe' do
      expect(instance.send(:next_scribe_step)).to be_nil
    end

    {
      'enchant-sigil'    => :handle_sigil_flag,
      'enchant-focus'    => :handle_focus_flag,
      'enchant-meditate' => :handle_meditate_flag,
      'enchant-push'     => :handle_push_flag,
      'enchant-imbue'    => :handle_imbue_flag,
      'imbue-backlash'   => :handle_backlash_flag,
      'enchant-complete' => :handle_complete_flag
    }.each do |key, step|
      it "answers #{key} with #{step}" do
        Flags[key] = true

        expect(instance.send(:next_scribe_step)).to eq(step)
      end
    end

    it 'answers a wanted sigil before a finished enchant' do
      Flags['enchant-complete'] = true
      Flags['enchant-sigil'] = true

      expect(instance.send(:next_scribe_step)).to eq(:handle_sigil_flag)
    end

    it 'answers a backlash before a finished enchant' do
      Flags['enchant-complete'] = true
      Flags['imbue-backlash'] = true

      expect(instance.send(:next_scribe_step)).to eq(:handle_backlash_flag)
    end
  end

  describe '#scribe' do
    let(:instance) { build_instance }

    before(:each) { instance.send(:setup_flags) }

    it 'finishes without scribing when the enchant is already complete' do
      Flags['enchant-complete'] = true
      expect(instance).to receive(:handle_complete_flag)
      expect(DRC).not_to receive(:bput)

      instance.send(:scribe)
    end

    it 'stops after a backlash without scribing again' do
      Flags['imbue-backlash'] = true
      expect(instance).to receive(:handle_backlash_flag)
      expect(DRC).not_to receive(:bput)

      instance.send(:scribe)
    end

    it "stops after #{Enchant::MAX_SCRIBE_STEPS} steps when the game never finishes the item" do
      allow(DRC).to receive(:bput).and_return('Roundtime: 3 sec.')
      allow(Lich::Messaging).to receive(:msg)

      expect { instance.send(:scribe) }.to raise_error(SystemExit)

      expect(DRC).to have_received(:bput).exactly(Enchant::MAX_SCRIBE_STEPS).times
      expect(Lich::Messaging).to have_received(:msg)
        .with('bold', "Enchant: Still not finished after #{Enchant::MAX_SCRIBE_STEPS} scribing steps; the totem is still on the brazier.")
    end

    it 'finishes on the last step it allows' do
      scribes = 0
      allow(DRC).to receive(:bput) do
        scribes += 1
        Flags['enchant-complete'] = true if scribes == Enchant::MAX_SCRIBE_STEPS - 1
        'Roundtime: 3 sec.'
      end
      expect(instance).to receive(:handle_complete_flag)

      instance.send(:scribe)
    end

    it 'answers what the game asked for, then scribes on until the enchant completes' do
      Flags['enchant-sigil'] = true
      allow(instance).to receive(:handle_sigil_flag) { Flags.reset('enchant-sigil') }
      scribes = 0
      allow(DRC).to receive(:bput) do |command, *_patterns|
        scribes += 1 if command == 'scribe totem on brazier with my burin'
        Flags['enchant-complete'] = true if scribes == 3
        'Roundtime: 3 sec.'
      end
      expect(instance).to receive(:handle_complete_flag)

      instance.send(:scribe)

      expect(instance).to have_received(:handle_sigil_flag).once
      expect(scribes).to eq(3)
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
        allow(instance).to receive(handler) do
          handled_after = scribes
          throw :handled
        end
        expect(DRC).not_to receive(:wait_for_script_to_complete)

        catch(:handled) { instance.send(:scribe) }

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

      allow(DRCI).to receive(:in_hands?).with('burin').and_return(true)
      expect(DRCC).to receive(:stow_crafting_item).with('burin', 'backpack', 'toolbelt')
      expect(instance).to receive(:trace_sigil).with('induction')
      expect(DRCC).to receive(:get_crafting_item)
      expect(instance).not_to receive(:scribe)

      instance.send(:handle_sigil_flag)
    end

    it 'puts away no burin that is not in hand' do
      instance = build_instance
      allow(Flags).to receive(:[]).with('enchant-sigil').and_return({ type: 'induction ', order: 'primary' })
      allow(Flags).to receive(:reset).with('enchant-sigil')
      allow(DRCI).to receive(:in_hands?).with('burin').and_return(false)
      allow(instance).to receive(:trace_sigil)
      allow(DRCC).to receive(:get_crafting_item)

      expect(DRCC).not_to receive(:stow_crafting_item)

      instance.send(:handle_sigil_flag)
    end

    it 'defaults to congruence sigil when type is empty' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return({ type: '', order: 'primary' })
      allow(Flags).to receive(:reset).with('enchant-sigil')

      expect(instance).to receive(:trace_sigil).with('congruence')
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCC).to receive(:get_crafting_item)

      instance.send(:handle_sigil_flag)
    end
  end

  # ---------------------------------------------------------------------------
  # trace_sigil
  # ---------------------------------------------------------------------------

  describe 'putting the burin away' do
    # The hand names a "fine precise burin" by its last adjective only.
    def hold_precise_burin
      allow(DRCI).to receive(:in_hands?) { |name| ['precise burin', 'burin'].include?(name) }
    end

    it 'stows a burin set up as "fine burin" before the imbue, though the hand says "precise burin"' do
      instance = build_instance(burin: 'fine burin')
      hold_precise_burin
      allow(instance).to receive(:imbue)
      allow(instance).to receive(:get_tool)
      expect(instance).to receive(:stow_tool).with('fine burin')

      instance.send(:handle_imbue_flag)
    end

    it 'finds an imbue rod set up as "slender rod" by its noun, before and after the wave' do
      instance = build_instance(imbue_wand: 'slender rod')
      allow(DRCI).to receive(:in_hands?) { |name| ['imbuement rod', 'rod'].include?(name) }
      allow(DRC).to receive(:bput).and_return('The spell is channeled through the fount hanging above')
      expect(instance).not_to receive(:get_tool)
      expect(instance).to receive(:stow_tool).with('slender rod')

      instance.send(:wave_imbue_wand)
    end

    it 'stows it before tracing a sigil too' do
      instance = build_instance(burin: 'fine burin')
      hold_precise_burin
      Flags['enchant-sigil'] = { type: 'decay' }
      allow(instance).to receive(:trace_sigil)
      allow(instance).to receive(:get_tool)
      expect(instance).to receive(:stow_tool).with('fine burin')

      instance.send(:handle_sigil_flag)
    end

    it 'stows it before the loop push too' do
      instance = build_instance(burin: 'fine burin')
      hold_precise_burin
      allow(instance).to receive(:get_tool)
      allow(instance).to receive(:brazier_step)
      expect(instance).to receive(:stow_tool).with('fine burin').ordered
      expect(instance).to receive(:stow_tool).with('aug loop').ordered

      instance.send(:handle_push_flag)
    end
  end

  describe '#trace_sigil' do
    it 'gets sigil, studies it, and traces on item' do
      instance = build_instance

      expect(DRCI).to receive(:get_item?).with('induction sigil').and_return(true)
      expect(DRC).to receive(:bput).with('study my induction sigil', Enchant::SIGIL_STUDY_SUCCESS)
      expect(DRC).to receive(:bput).with('trace totem on brazier', Enchant::SIGIL_TRACE_SUCCESS)

      instance.send(:trace_sigil, 'induction')
    end

    it 'stops without studying or tracing when the sigil-scroll is not there' do
      instance = build_instance

      expect(DRCI).to receive(:get_item?).with('induction sigil').and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', 'Enchant: No induction sigil-scroll to study; the totem is still on the brazier.')
      expect(DRC).not_to receive(:bput)

      expect { instance.send(:trace_sigil, 'induction') }.to raise_error(SystemExit)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_complete_flag
  # ---------------------------------------------------------------------------

  describe '#get_burin_unless_done' do
    let(:instance) { build_instance }

    before(:each) { instance.send(:setup_flags) }

    it 'fetches the burin for the scribing the imbue leads to' do
      expect(DRCC).to receive(:get_crafting_item).with('burin', 'backpack', ['burin'], 'toolbelt')

      instance.send(:get_burin_unless_done)
    end

    it 'leaves the burin alone when the imbue finished the item' do
      Flags['enchant-complete'] = true
      expect(DRCC).not_to receive(:get_crafting_item)

      instance.send(:get_burin_unless_done)
    end

    it 'leaves the burin alone when the imbue asked for a sigil first' do
      Flags['enchant-sigil'] = { type: 'induction ', order: 'primary' }
      expect(DRCC).not_to receive(:get_crafting_item)

      instance.send(:get_burin_unless_done)
    end

    it 'leaves the burin alone after a backlash' do
      Flags['imbue-backlash'] = true
      expect(DRCC).not_to receive(:get_crafting_item)

      instance.send(:get_burin_unless_done)
    end
  end

  describe '#study_instructions' do
    let(:instance) { build_instance }
    let(:name) { 'spongestone instructions' }

    before(:each) do
      allow(DRCC).to receive(:get_crafting_item).and_return(true)
      allow(DRCC).to receive(:stow_crafting_item)
    end

    it "uses lich-5's DRCC.study_instructions when the installed Lich has it" do
      result = Struct.new(:studied?).new(true)
      allow(DRCC).to receive(:study_instructions).with(name, 'backpack', ['burin'], 'toolbelt', true).and_return(result)
      expect(DRC).not_to receive(:bput)

      expect(instance.send(:study_instructions, name)).to be(true)
    end

    # Reads queued reply lines the way DRC.bput does: lines that match none
    # of the matchers given are skipped, the matched text of the first that
    # does is returned, and '' (a timeout) when none is left. When the game
    # lags, a late Roundtime from an earlier command can come before the
    # study's own line, so a stub that only hands back canned values would
    # hide which line counted.
    def queue_study_replies(*replies)
      matched = []
      queue = replies.map(&:dup)
      allow(DRC).to receive(:bput) do |_command, *matchers|
        regexes = matchers.flatten.map { |m| m.is_a?(Regexp) ? m : /#{m}/i }
        lines = queue.shift || []
        found = nil
        while found.nil? && (line = lines.shift)
          regexes.each do |re|
            next unless (m = line.match(re))

            matched << line
            found = m.to_a.first
            break
          end
        end
        found || ''
      end
      matched
    end

    it 'counts a study done on each of the three endings of its own line' do
      ['completely understand all facets of the design.',
       'comprehend all but several minor details in the text.',
       "confidently discern most of the design's minutiae."].each do |ending|
        study_line = "You scan the spongestone instructions with a glance and #{ending}"
        matched = queue_study_replies([study_line, 'You now feel ready to begin the crafting process.', 'Roundtime: 7 sec.'])

        expect(instance.send(:study_instructions, name)).to be(true)
        expect(matched).to eq([study_line])
      end
    end

    it 'skips a late Roundtime from an earlier command and counts the study line after it' do
      matched = queue_study_replies(['Roundtime: 8 sec.'] + ENCHANT_LOG[:study_spongestone_instructions])

      expect(instance.send(:study_instructions, name)).to be(true)

      expect(matched).to eq([ENCHANT_LOG[:study_spongestone_instructions].first])
    end

    it 'does not count a late Roundtime followed by the instructions not being in hand' do
      queue_study_replies(['Roundtime: 8 sec.', 'You must be holding the instructions to study them.'])

      expect(instance.send(:study_instructions, name)).to be(false)
    end

    it 'does not count a late Roundtime that is the only reply' do
      queue_study_replies(['Roundtime: 8 sec.'])

      expect(instance.send(:study_instructions, name)).to be(false)
    end

    it "does not take a player's speech as the study line" do
      expect(ENCHANT_LOG[:study_wand_instructions].first).to match(Enchant::STUDY_INSTRUCTIONS_DONE)
      player_lines('You scan the wand instructions with a glance and completely understand all facets of the design.').each do |line|
        expect(line).not_to match(Enchant::STUDY_INSTRUCTIONS_DONE)
      end
    end

    it 'studies twice when the first study asks for another, then puts them back' do
      queue_study_replies(ENCHANT_LOG[:study_instructions_again], ENCHANT_LOG[:study_spongestone_instructions])

      expect(instance.send(:study_instructions, name)).to be(true)

      expect(DRC).to have_received(:bput).with("study my #{name}", any_args).twice
      expect(DRCC).to have_received(:stow_crafting_item).with(name, 'backpack', 'toolbelt')
    end

    it 'does not put back instructions the game threw away' do
      allow(DRC).to receive(:bput) do
        Flags[Enchant::STUDY_INSTRUCTIONS_TOSSED_FLAG] = true
        'You scan the spongestone instructions with a glance and '
      end

      expect(instance.send(:study_instructions, name)).to be(true)

      expect(DRCC).not_to have_received(:stow_crafting_item)
    end

    it 'counts a completed study after "1 uses" as the last, and keeps nothing' do
      queue_study_replies(['[These instructions have only 1 uses remaining.  Study them again to proceed.]'],
                          ENCHANT_LOG[:study_spongestone_instructions])

      expect(instance.send(:study_instructions, name)).to be(true)

      expect(DRCC).not_to have_received(:stow_crafting_item)
    end

    it 'fails when the instructions are not in hand (log 1)' do
      allow(DRC).to receive(:bput).and_return('You must be holding the instructions')

      expect(instance.send(:study_instructions, name)).to be(false)
    end

    it 'fails without studying when the instructions cannot be fetched' do
      allow(DRCC).to receive(:get_crafting_item).with(name, 'backpack', ['burin'], 'toolbelt', true).and_return(false)
      expect(DRC).not_to receive(:bput)

      expect(instance.send(:study_instructions, name)).to be(false)
    end

    it "asks for another study only on the game's line, not a player's" do
      expect('[These instructions have only 9 uses remaining.  Study them again to proceed.]').to match(Enchant::STUDY_INSTRUCTIONS_AGAIN)
      player_lines('These instructions have only 1 uses remaining.  Study them again to proceed.').each do |line|
        expect(line).not_to match(Enchant::STUDY_INSTRUCTIONS_AGAIN)
      end
    end

    it 'fails after three studies that only ever ask for another' do
      allow(DRC).to receive(:bput).and_return('Study them again')

      expect(instance.send(:study_instructions, name)).to be(false)

      expect(DRC).to have_received(:bput).exactly(3).times
    end

    it 'removes its flag however it ends' do
      allow(DRC).to receive(:bput).and_raise(StandardError, 'connection lost')

      expect { instance.send(:study_instructions, name) }.to raise_error(StandardError)

      expect(Flags.matchers).not_to have_key(Enchant::STUDY_INSTRUCTIONS_TOSSED_FLAG)
    end
  end

  describe '#take_product' do
    it 'lifts the product off the floor and sends nothing else' do
      instance = build_instance(item: 'rock')
      expect(DRCI).to receive(:lift?).with('rock').and_return(true)
      expect(DRCI).not_to receive(:get_item?)
      expect(DRCC).not_to receive(:stow_crafting_item)

      instance.send(:take_product)
    end

    it 'gets the product when there is nothing to lift' do
      instance = build_instance(item: 'rock')
      allow(DRCI).to receive(:lift?).with('rock').and_return(false)
      expect(DRCI).to receive(:get_item?).with('rock').and_return(true)
      expect(DRCC).not_to receive(:stow_crafting_item)

      expect(instance.send(:take_product)).to be(true)
    end
  end

  describe '#handle_complete_flag' do
    it 'outputs completion message and calls cleanup' do
      instance = build_instance
      Flags['enchant-fount-returned'] = true

      expect(Lich::Messaging).to receive(:msg).with('plain', 'Enchant: Enchanting complete!')
      expect(instance).to receive(:cleanup).with(fount: true)

      instance.send(:handle_complete_flag)
    end

    it 'leaves the fount out of the cleanup when the game did not hand it back' do
      instance = build_instance(fount_on_item: true)
      allow(Lich::Messaging).to receive(:msg)

      expect(instance).to receive(:cleanup).with(fount: false)

      instance.send(:handle_complete_flag)

      expect(Lich::Messaging).to have_received(:msg).with('plain', 'Enchant: The fount was used up and is gone.')
    end

    it 'says nothing of a used-up fount when the item needed none and it went back in the bag' do
      instance = build_instance(fount_on_item: false)
      allow(Lich::Messaging).to receive(:msg)

      expect(instance).to receive(:cleanup).with(fount: false)

      instance.send(:handle_complete_flag)

      expect(Lich::Messaging).not_to have_received(:msg).with('plain', /used up/)
    end

    it 'expects no fount back from a fount it just made' do
      instance = build_instance(item: 'fount')
      allow(Lich::Messaging).to receive(:msg)

      expect(Lich::Messaging).not_to receive(:msg).with('plain', /used up/)
      expect(instance).to receive(:cleanup).with(fount: true)

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

    context 'when every try fails' do
      it "stops after #{Enchant::MAX_IMBUE_TRIES} failed casts" do
        instance = build_instance(settings: OpenStruct.new('waggle_sets' => { 'imbue' => { 'Imbue' => { 'mana' => 20 } } }))
        allow(DRCA).to receive(:cast_spell?).and_return(false)
        allow(Lich::Messaging).to receive(:msg)

        expect { instance.send(:imbue) }.to raise_error(SystemExit)

        expect(DRCA).to have_received(:cast_spell?).exactly(Enchant::MAX_IMBUE_TRIES).times
        expect(Lich::Messaging).to have_received(:msg).with('bold', "Enchant: Imbue failed #{Enchant::MAX_IMBUE_TRIES} times; the totem is still on the brazier.")
      end

      it "stops after #{Enchant::MAX_IMBUE_TRIES} colliding wand waves" do
        instance = build_instance(settings: OpenStruct.new('waggle_sets' => { 'imbue' => {} }))
        allow(DRC).to receive(:bput).and_return('The streams collide, rending the space before you and disrupting the enchantment')
        allow(Lich::Messaging).to receive(:msg)

        expect { instance.send(:imbue) }.to raise_error(SystemExit)

        expect(DRC).to have_received(:bput).exactly(Enchant::MAX_IMBUE_TRIES).times
        expect(Lich::Messaging).to have_received(:msg).with('bold', "Enchant: The rod failed #{Enchant::MAX_IMBUE_TRIES} times; the totem is still on the brazier.")
      end

      it 'carries on when the last allowed cast works' do
        instance = build_instance(settings: OpenStruct.new('waggle_sets' => { 'imbue' => { 'Imbue' => { 'mana' => 20 } } }))
        failures = Array.new(Enchant::MAX_IMBUE_TRIES - 1, false)
        allow(DRCA).to receive(:cast_spell?).and_return(*failures, true)
        allow(Lich::Messaging).to receive(:msg)

        instance.send(:imbue)

        expect(Lich::Messaging).to have_received(:msg).with('bold', 'Enchant: Casting Imbue failed. Retrying.').exactly(failures.size).times
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

  describe '#study_recipe with an enchanting belt' do
    it 'unties the artificing book from the enchanting belt and ties it back' do
      belt = { 'name' => 'toolbelt', 'items' => ['artificing book', 'burin'] }
      instance = build_instance(belt: belt, chapter: '1', recipe: 'spongestone')
      allow(DRC).to receive(:bput).and_return('You get a rock from inside your backpack.', 'With a flick, you pop open the lid.')

      expect(DRCC).to receive(:get_crafting_item).with('artificing book', 'backpack', ['burin'], belt).ordered
      expect(DRCC).to receive(:find_recipe2).with('1', 'spongestone').ordered
      expect(DRCC).to receive(:stow_crafting_item).with('book', 'backpack', belt).ordered
      allow(DRCC).to receive(:get_crafting_item).with('brazier', anything, anything, anything)

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
    it 'stops before reading the recipe or touching the brazier when there is no fount' do
      instance = build_instance(item: 'totem')
      allow(DRCI).to receive(:exists?).with('fount').and_return(false)

      expect(Lich::Messaging).to receive(:msg).with('bold', 'Enchant: fount not found in inventory. Cannot proceed.')
      expect(instance).not_to receive(:study_recipe)
      expect(instance).not_to receive(:cleanup)
      expect(DRC).not_to receive(:bput)

      expect { instance.send(:handle_new_enchant) }.to raise_error(SystemExit)
    end

    it 'needs no fount to make a fount from a small sphere' do
      instance = build_instance(item: 'small sphere', baseitem: 'small sphere')
      expect(DRCI).not_to receive(:exists?)
      expect(instance).to receive(:study_recipe)
      expect(instance).not_to receive(:wave_fount)
      allow(instance).to receive(:imbue)
      allow(instance).to receive(:scribe)

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
    # These are about the fount; the scribing that follows the imbue is
    # covered by the whole runs.
    before(:each) do
      allow_any_instance_of(Enchant).to receive(:scribe)
      allow(DRCC).to receive(:get_crafting_item).with('burin', any_args)
    end

    # bput returns only the matched text, so these feed the game's look line
    # through model_bput rather than stubbing bput with the whole line.
    [
      'On the brass brazier you see a fount.',
      'On the brass brazier you see a fount and a totem.',
      'On the brass brazier you see a totem and a fragile mana fount.',
      "On the enchanter's brazier you see a fount.",
      "On the enchanter's brazier you see a thin mana fount.",
      'On the brazier you see a fount.'
    ].each do |look|
      it "imbues without fetching a fount when the game shows one: #{look}" do
        instance = build_instance
        sent = stub_bput_replies(/^look on/ => [[look]])

        expect(instance).to receive(:imbue)
        expect(DRCC).not_to receive(:get_crafting_item).with('fount', any_args)

        instance.send(:handle_imbue_resume)
        expect(sent).to eq(['look on brazier'])
      end
    end

    it 'fetches and waves a fount when the brazier is empty' do
      instance = build_instance
      sent = stub_bput_replies(/^look on/       => [['There is nothing on the brass brazier.']],
                               /^wave my fount/ => [['The fragile mana fount is not required to continue crafting.']])

      expect(DRCC).to receive(:get_crafting_item).with('fount', 'backpack', ['burin'], 'toolbelt')
      expect(DRCC).to receive(:stow_crafting_item).with('fount', 'backpack', 'toolbelt')
      expect(instance).to receive(:imbue)

      instance.send(:handle_imbue_resume)
      expect(sent).to eq(['look on brazier', 'wave my fount at totem on brazier'])
    end

    it 'does not take a word that only contains fount for the fount' do
      instance = build_instance
      stub_bput_replies(/^look on/       => [['On the brass brazier you see a fountain-carved totem.']],
                        /^wave my fount/ => [['You slowly wave the fount over and around the totem.']])

      expect(DRCC).to receive(:get_crafting_item).with('fount', 'backpack', ['burin'], 'toolbelt')
      expect(instance).to receive(:imbue)

      instance.send(:handle_imbue_resume)
    end

    it "ignores another player's claim that a fount is on the brazier" do
      player_lines('On the brass brazier you see a fount.').each do |line|
        instance = build_instance
        stub_bput_replies(/^look on/       => [[line, 'On the brass brazier you see a totem.']],
                          /^wave my fount/ => [['You slowly wave the fount over and around the totem.']])

        expect(DRCC).to receive(:get_crafting_item).with('fount', 'backpack', ['burin'], 'toolbelt')
        expect(instance).to receive(:imbue)

        instance.send(:handle_imbue_resume)
      end
    end

    it 'fetches and waves a fount when none is on the brazier' do
      instance = build_instance
      allow(DRC).to receive(:bput).with(/^look on/, anything, anything)
                                  .and_return('On the brass brazier you see a totem.')
      allow(DRC).to receive(:bput).with(/^wave my fount/, anything, anything, anything)
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
        result = model_bput([line, 'On the brass brazier you see a fount.'], [Enchant::BRAZIER_CONTENTS_PATTERN, Enchant::BRAZIER_EMPTY])
        expect(result).to start_with('On the brass brazier you see'), line
      end
    end
  end
end

# Whole runs, from the command line to the product in hand. These pin what
# enchant does today for its callers (craft.lic and workorders.lic send
# `chapter recipe noun`, then bundle the product held in hand) and for players
# (`enchant chapter recipe noun [base_noun]`, `enchant resume noun`). Every
# command and commons call is in the transcript, in order, with the game's own
# lines from real runs.
RSpec.describe Enchant, 'whole runs' do
  let(:game) { EnchantSpecGame.new }
  let(:bag) { 'duffel bag' }

  before(:each) do
    $test_settings = OpenStruct.new(
      crafting_container: bag,
      crafting_items_in_container: [],
      enchanting_belt: nil,
      enchanting_tools: ['augmenting loop', 'brazier', 'burin', 'imbuement rod', 'fount'],
      mark_crafted_goods: false,
      cube_armor_piece: nil,
      worn_trashcan: 'bucket',
      worn_trashcan_verb: 'drop',
      master_crafting_book: nil,
      waggle_sets: { 'imbue' => {} }
    )
    DRRoom.room_objs = []
    allow(DRC).to receive(:bput) { |text, *patterns| game.bput(text, patterns) }
    allow(DRC).to receive(:wait_for_script_to_complete) { |*args| game.commons('DRC.wait_for_script_to_complete', *args) }
    allow_any_instance_of(EquipmentManager).to receive(:empty_hands) { game.commons('EquipmentManager#empty_hands') }
    %i[get_crafting_item stow_crafting_item find_recipe2].each do |name|
      allow(DRCC).to receive(name) { |*args| game.commons("DRCC.#{name}", *args) }
    end
    %i[get_item? lift? dispose_trash].each do |name|
      allow(DRCI).to receive(name) { |*args| game.commons("DRCI.#{name}", *args) }
    end
    allow(DRCA).to receive(:cast_spell?) { |*args| game.commons('DRCA.cast_spell?', *args) }
    allow(DRCI).to receive(:exists?) { |item| [*game.hands, 'fount'].compact.any? { |held| held.include?(item) } }
    allow(DRCI).to receive(:in_hands?) { |item| game.hands.compact.any? { |held| held.include?(item) } }
    allow(Lich::Messaging).to receive(:msg) { |_style, text| game.messages << text }
  end

  # The script's entry point, as Lich runs it.
  def run_script(**args)
    $parsed_args = OpenStruct.new(args)
    Enchant.new.run
  end

  def expect_transcript_done
    expect(game.remaining).to eq([])
  end

  # The start every book run shares: empty hands, buffs, the recipe from the
  # artificing book, then the brazier.
  def book_start(chapter:, recipe:)
    game.call('EquipmentManager#empty_hands')
    game.call('DRC.wait_for_script_to_complete', 'buff', ['enchant'])
    game.call('DRCC.get_crafting_item', 'artificing book', bag, [], nil, gives: 'artificing book')
    game.call('DRCC.find_recipe2', chapter, recipe)
    game.call('DRCC.stow_crafting_item', 'book', bag, nil, takes: 'book')
    game.call('DRCC.get_crafting_item', 'brazier', bag, [], nil, gives: 'brazier')
  end

  # The end every run that finishes shares: the brazier and whatever else is
  # held go back to the bag, the fount comes off the floor into the bag, and
  # the product comes off the floor into hand for the caller.
  def tidy_up(item, held: %w[brazier], fount: true)
    held.each { |tool| game.call('DRCC.stow_crafting_item', tool, bag, nil, takes: tool) }
    if fount
      game.call('DRCI.lift?', 'fount', gives: { from_feet: 'fount' })
      game.call('DRCC.stow_crafting_item', 'fount', bag, nil, takes: 'fount')
    end
    game.call('DRCI.lift?', item, gives: { from_feet: item })
  end

  # The rod imbue that finishes the item.
  def final_rod_imbue(item, lines, holding_burin: true)
    game.call('DRCC.stow_crafting_item', 'burin', bag, nil, takes: 'burin') if holding_burin
    game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
    game.command("wave imbuement rod at #{item} on my brazier", lines)
    game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
  end

  context 'a spongestone from the artificing book (log 1, the first item)' do
    before(:each) do
      book_start(chapter: '1', recipe: 'spongestone')
      game.command("get my rock from my #{bag}", ENCHANT_LOG[:get_rock], gives: 'rock')
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_rock], takes: 'rock')
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.command('wave my fount at rock on my brazier', ENCHANT_LOG[:wave_fount_rock], takes: 'fount')
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at rock on my brazier', ENCHANT_LOG[:imbue_wants_congruence])
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      # The congruence sigil the imbue asked for: no burin until it is traced.
      game.call('DRCI.get_item?', 'congruence sigil', gives: 'congruence sigil')
      game.command('study my congruence sigil', ENCHANT_LOG[:study_sigil], takes: 'congruence sigil')
      game.command('trace rock on my brazier', ENCHANT_LOG[:trace_rock])
      game.call('DRCC.get_crafting_item', 'burin', bag, [], nil, gives: 'burin')
      game.command('scribe rock on my brazier with my burin', ENCHANT_LOG[:scribe_rock_merging])
      # The merging sigils want the loop.
      game.call('DRCC.stow_crafting_item', 'burin', bag, nil, takes: 'burin')
      game.call('DRCC.get_crafting_item', 'augmenting loop', bag, [], nil, gives: 'augmenting loop')
      game.command('push rock on my brazier with my augmenting loop', ENCHANT_LOG[:push_rock])
      game.call('DRCC.stow_crafting_item', 'augmenting loop', bag, nil, takes: 'augmenting loop')
      game.call('DRCC.get_crafting_item', 'burin', bag, [], nil, gives: 'burin')
      game.command('scribe rock on my brazier with my burin', ENCHANT_LOG[:scribe_rock_wants_decay])
      # The decay sigil.
      game.call('DRCC.stow_crafting_item', 'burin', bag, nil, takes: 'burin')
      game.call('DRCI.get_item?', 'decay sigil', gives: 'decay sigil')
      game.command('study my decay sigil', ENCHANT_LOG[:study_sigil], takes: 'decay sigil')
      game.command('trace rock on my brazier', ENCHANT_LOG[:trace_rock])
      game.call('DRCC.get_crafting_item', 'burin', bag, [], nil, gives: 'burin')
      4.times { game.command('scribe rock on my brazier with my burin', ENCHANT_LOG[:scribe_rock]) }
      game.command('scribe rock on my brazier with my burin', ENCHANT_LOG[:scribe_rock_blurs])
      game.command('meditate fount on my brazier', ENCHANT_LOG[:meditate_wants_imbue])
      # The imbue the meditation asked for finishes the rock.
      game.call('DRCC.stow_crafting_item', 'burin', bag, nil, takes: 'burin')
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at rock on my brazier', ENCHANT_LOG[:imbue_completes_rock])
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      # Done: put the brazier away, take the fount off the floor, and end
      # holding the rock.
      game.call('DRCC.stow_crafting_item', 'brazier', bag, nil, takes: 'brazier')
      game.call('DRCI.lift?', 'fount', gives: { from_feet: 'fount' })
      game.call('DRCC.stow_crafting_item', 'fount', bag, nil, takes: 'fount')
      game.call('DRCI.lift?', 'rock', gives: { from_feet: 'rock' })
    end

    it 'sends every command in order and ends holding the rock' do
      run_script(chapter: '1', recipe: 'spongestone', noun: 'rock')

      expect_transcript_done
      expect(game.hands).to eq(['rock', nil])
      expect(game.feet).to eq([])
    end

    it 'says the enchanting is complete' do
      run_script(chapter: '1', recipe: 'spongestone', noun: 'rock')

      expect(game.messages).to include('Enchant: Enchanting complete!')
    end

    it 'never puts the finished rock in the bag, where the unworked rocks are' do
      stowed = []
      allow(DRCC).to receive(:stow_crafting_item) do |*args|
        stowed << args.first
        game.commons('DRCC.stow_crafting_item', *args)
      end

      run_script(chapter: '1', recipe: 'spongestone', noun: 'rock')

      expect(stowed).not_to include('rock')
    end

    it 'removes every flag it added' do
      run_script(chapter: '1', recipe: 'spongestone', noun: 'rock')

      expect(Flags.matchers.keys & Enchant::FLAG_NAMES).to eq([])
    end
  end

  context 'a virga wand from the artificing book (log 2, the third item)' do
    before(:each) do
      book_start(chapter: '2', recipe: 'virga wand')
      game.command("get my wand from my #{bag}", ENCHANT_LOG[:get_wand], gives: 'redwood wand')
      game.command('put my wand on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my wand on my brazier', ENCHANT_LOG[:put_wand], takes: 'wand')
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.command('wave my fount at wand on my brazier', ENCHANT_LOG[:wave_fount_wand], takes: 'fount')
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at wand on my brazier', ENCHANT_LOG[:imbue_wants_induction])
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      game.call('DRCI.get_item?', 'induction sigil', gives: 'induction sigil')
      game.command('study my induction sigil', ENCHANT_LOG[:study_sigil], takes: 'induction sigil')
      game.command('trace wand on my brazier', ENCHANT_LOG[:trace_wand])
      game.call('DRCC.get_crafting_item', 'burin', bag, [], nil, gives: 'burin')
      game.command('scribe wand on my brazier with my burin', ENCHANT_LOG[:scribe_wand_struggles])
      # The struggling material wants a focus; the burin stays in hand.
      game.command('focus wand on my brazier', ENCHANT_LOG[:focus_wand])
      game.command('scribe wand on my brazier with my burin', ENCHANT_LOG[:scribe_wand])
      game.command('scribe wand on my brazier with my burin', ENCHANT_LOG[:scribe_wand_wants_imbue])
      final_rod_imbue('wand', ENCHANT_LOG[:imbue_completes_wand])
      tidy_up('wand')
    end

    it 'sends every command in order and ends holding the wand' do
      run_script(chapter: '2', recipe: 'virga wand', noun: 'wand')

      expect_transcript_done
      expect(game.hands).to eq(['wand', nil])
    end
  end

  context "at a public enchanter's brazier" do
    before(:each) do
      DRRoom.room_objs = ["an enchanter's brazier"]
      game.call('EquipmentManager#empty_hands')
      game.call('DRC.wait_for_script_to_complete', 'buff', ['enchant'])
      game.call('DRCC.get_crafting_item', 'artificing book', bag, [], nil, gives: 'artificing book')
      game.call('DRCC.find_recipe2', '1', 'spongestone')
      game.call('DRCC.stow_crafting_item', 'book', bag, nil, takes: 'book')
      # No brazier of our own to fetch: the room's is used by name, without "my".
      game.command("get my rock from my #{bag}", ENCHANT_LOG[:get_rock], gives: 'rock')
      game.command("put my rock on enchanter's brazier", ENCHANT_LOG[:put_glance])
      game.command("put my rock on enchanter's brazier", ENCHANT_LOG[:put_rock], takes: 'rock')
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.command("wave my fount at rock on enchanter's brazier", ENCHANT_LOG[:wave_fount_rock], takes: 'fount')
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      # A short enchant that finishes on its first imbue (log lines, shorter run).
      game.command("wave imbuement rod at rock on enchanter's brazier", ENCHANT_LOG[:imbue_completes_rock])
      # With no brazier held the rod is in the right hand; it is put away all the same.
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      tidy_up('rock', held: [])
    end

    it 'works on the public brazier and ends holding the rock' do
      run_script(chapter: '1', recipe: 'spongestone', noun: 'rock')

      expect_transcript_done
      expect(game.hands).to eq(['rock', nil])
    end
  end

  context 'with an Imbue spell in waggle_sets and an armor cube' do
    let(:imbue_spell) { { 'abbrev' => 'imbue', 'mana' => 5 } }

    before(:each) do
      $test_settings.waggle_sets = { 'imbue' => { 'Imbue' => imbue_spell } }
      $test_settings.cube_armor_piece = 'armguard'
      book_start(chapter: '1', recipe: 'spongestone')
      game.command("get my rock from my #{bag}", ENCHANT_LOG[:get_rock], gives: 'rock')
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_rock], takes: 'rock')
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.command('wave my fount at rock on my brazier', ENCHANT_LOG[:wave_fount_rock], takes: 'fount')
      # Code-derived reply: no cube touch in the logs.
      game.command('touch my armguard', ['Warm vapor swirls around your head in a misty halo of thoughts.'])
      game.call('DRCA.cast_spell?', imbue_spell.merge('cast' => 'cast rock on my brazier'), $test_settings,
                lines: ENCHANT_LOG[:imbue_completes_rock])
      tidy_up('rock')
    end

    it 'touches the cube, casts Imbue at the item and ends holding the rock' do
      run_script(chapter: '1', recipe: 'spongestone', noun: 'rock')

      expect_transcript_done
      expect(game.hands).to eq(['rock', nil])
    end
  end

  context 'from a master crafting book, with a base item that becomes the product' do
    before(:each) do
      $test_settings.master_crafting_book = 'tome'
      game.call('EquipmentManager#empty_hands')
      game.call('DRC.wait_for_script_to_complete', 'buff', ['enchant'])
      game.call('DRCC.find_recipe2', '4', 'radiant loop', 'tome', 'artificing')
      game.call('DRCC.get_crafting_item', 'brazier', bag, [], nil, gives: 'brazier')
      # The base item is fetched and placed by its own noun ...
      game.command("get my pole from my #{bag}", ['You get a short pole from inside your duffel bag.'], gives: 'pole')
      game.command('put my pole on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my pole on my brazier', ENCHANT_LOG[:put_rock], takes: 'pole')
      # ... and worked by the product's noun from then on.
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.command('wave my fount at loop on my brazier', ENCHANT_LOG[:wave_fount_rock], takes: 'fount')
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at loop on my brazier',
                   ENCHANT_LOG[:imbue_completes_rock].map { |line| line.sub('collect the rock', 'collect the loop') })
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      tidy_up('loop')
    end

    it 'reads the master book and ends holding the product' do
      run_script(chapter: '4', recipe: 'radiant loop', noun: 'loop', base_noun: 'pole')

      expect_transcript_done
      expect(game.hands).to eq(['loop', nil])
    end
  end

  context 'a fount from a small sphere, as workorders asks for it' do
    before(:each) do
      book_start(chapter: '1', recipe: 'fragile mana fount')
      game.command("get my small sphere from my #{bag}", ['You get a pine small sphere from inside your duffel bag.'], gives: 'small sphere')
      game.command('put my small sphere on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my small sphere on my brazier', ENCHANT_LOG[:put_rock], takes: 'small sphere')
      # The product is a fount, so no fount is waved at it.
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at fount on my brazier',
                   ENCHANT_LOG[:imbue_completes_rock].reject { |line| line.include?('collect the fount') }
                                                     .map { |line| line.sub('collect the rock', 'collect the fount') })
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      tidy_up('fount', fount: false)
    end

    it 'skips the fount steps and ends holding the new fount' do
      run_script(chapter: '1', recipe: 'fragile mana fount', noun: 'small sphere')

      expect_transcript_done
      expect(game.hands).to eq(['fount', nil])
    end
  end

  context 'resuming an item that is ready for more scribing' do
    before(:each) do
      game.call('EquipmentManager#empty_hands')
      game.call('DRC.wait_for_script_to_complete', 'buff', ['enchant'])
      game.call('DRCC.get_crafting_item', 'brazier', bag, [], nil, gives: 'brazier')
      # Code-derived reply: no analyze in the logs.
      game.command('analyze rock on my brazier', ['You do not see anything that would prevent scribing additional sigils.'])
      game.call('DRCC.get_crafting_item', 'burin', bag, [], nil, gives: 'burin')
      game.command('scribe rock on my brazier with my burin', ENCHANT_LOG[:scribe_rock_blurs])
      game.command('meditate fount on my brazier', ENCHANT_LOG[:meditate_wants_imbue])
      final_rod_imbue('rock', ENCHANT_LOG[:imbue_completes_rock])
      tidy_up('rock')
    end

    it 'goes on scribing to the end and ends holding the rock' do
      run_script(resume: 'resume', noun: 'rock')

      expect_transcript_done
      expect(game.hands).to eq(['rock', nil])
    end
  end

  context 'with mark_crafted_goods set' do
    before(:each) do
      $test_settings.mark_crafted_goods = true
      book_start(chapter: '1', recipe: 'spongestone')
      game.command("get my rock from my #{bag}", ENCHANT_LOG[:get_rock], gives: 'rock')
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_rock], takes: 'rock')
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.command('wave my fount at rock on my brazier', ENCHANT_LOG[:wave_fount_rock], takes: 'fount')
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at rock on my brazier', ENCHANT_LOG[:imbue_completes_rock])
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      tidy_up('rock')
      game.call('DRCC.get_crafting_item', 'stamp', bag, [], nil, gives: 'stamp')
      # Code-derived reply: no stamping in the logs.
      game.command('mark my rock with my stamp', ['You carefully hammer the stamp into the rock.'])
      game.call('DRCC.stow_crafting_item', 'stamp', bag, nil, takes: 'stamp')
    end

    it 'stamps the product and ends holding it' do
      run_script(chapter: '1', recipe: 'spongestone', noun: 'rock')

      expect_transcript_done
      expect(game.hands).to eq(['rock', nil])
    end
  end

  context 'when the base totem is already enchanted' do
    before(:each) do
      book_start(chapter: '3', recipe: 'flash trinket')
      game.command("get my totem from my #{bag}", ['You get a bone totem from inside your duffel bag.'], gives: 'totem')
      # Code-derived reply. The totem is thrown away and the recipe started over.
      game.command('put my totem on my brazier', ['The totem is already enchanted.'])
      game.call('DRCI.dispose_trash', 'totem', 'bucket', 'drop', takes: 'totem')
      game.call('DRCC.get_crafting_item', 'artificing book', bag, [], nil, gives: 'artificing book')
      game.call('DRCC.find_recipe2', '3', 'flash trinket')
      game.call('DRCC.stow_crafting_item', 'book', bag, nil, takes: 'book')
      game.call('DRCC.get_crafting_item', 'brazier', bag, [], nil)
      game.command("get my totem from my #{bag}", ['You get a bone totem from inside your duffel bag.'], gives: 'totem')
      game.command('put my totem on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my totem on my brazier', ENCHANT_LOG[:put_rock], takes: 'totem')
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.command('wave my fount at totem on my brazier', ENCHANT_LOG[:wave_fount_rock], takes: 'fount')
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at totem on my brazier',
                   ENCHANT_LOG[:imbue_completes_rock].map { |line| line.sub('collect the rock', 'collect the totem') })
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      tidy_up('totem')
    end

    it 'throws it away, starts again with the next totem and ends holding the product' do
      run_script(chapter: '3', recipe: 'flash trinket', noun: 'totem')

      expect_transcript_done
      expect(game.hands).to eq(['totem', nil])
    end
  end

  context 'when the brazier is too dangerous to work at' do
    before(:each) do
      book_start(chapter: '1', recipe: 'spongestone')
      # Code-derived replies: no brazier cleaning in the logs.
      game.command("get my rock from my #{bag}", ['That is far too dangerous to do with the brazier in this state.'])
      game.command('clean my brazier', ['You prepare to clean off the brazier.'])
      game.command('clean my brazier', ['You clean the brazier, and a massive ball of flame jets forward and singes everything nearby!'])
      game.command('look on my brazier', ['There is nothing on there.'])
      game.call('DRCI.get_item?', 'rock', bag, gives: 'rock')
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_rock], takes: 'rock')
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.command('wave my fount at rock on my brazier', ENCHANT_LOG[:wave_fount_rock], takes: 'fount')
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at rock on my brazier', ENCHANT_LOG[:imbue_completes_rock])
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      tidy_up('rock')
    end

    it 'cleans the brazier, gets the rock again and goes on' do
      run_script(chapter: '1', recipe: 'spongestone', noun: 'rock')

      expect_transcript_done
      expect(game.hands).to eq(['rock', nil])
    end
  end

  context 'when the imbue backlashes' do
    before(:each) do
      book_start(chapter: '1', recipe: 'spongestone')
      game.command("get my rock from my #{bag}", ENCHANT_LOG[:get_rock], gives: 'rock')
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_rock], takes: 'rock')
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.command('wave my fount at rock on my brazier', ENCHANT_LOG[:wave_fount_rock], takes: 'fount')
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      # Code-derived reply: no backlash in the logs.
      game.command('wave imbuement rod at rock on my brazier',
                   ['Suddenly the streams slip through your grasp and cascade violently against each other!', 'Roundtime: 10 sec.'])
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      game.call('DRCC.stow_crafting_item', 'brazier', bag, nil, takes: 'brazier')
      # After a backlash nothing was put at our feet: the lifts find nothing
      # and fall back to GETs.
      game.call('DRCI.lift?', 'fount', returns: false)
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.call('DRCC.stow_crafting_item', 'fount', bag, nil, takes: 'fount')
      game.call('DRCI.lift?', 'rock', returns: false)
      game.call('DRCI.get_item?', 'rock', returns: false)
      game.call('DRC.wait_for_script_to_complete', 'safe-room', ['force'])
    end

    it 'puts the tools away and goes to safe-room' do
      run_script(chapter: '1', recipe: 'spongestone', noun: 'rock')

      expect_transcript_done
      expect(game.messages).to include('Enchant: Imbue backlash occurred! Cleaning up and heading to safe room.')
    end
  end

  context "when the fount's last use goes into the rock (log 1, the fifth item)" do
    before(:each) do
      book_start(chapter: '1', recipe: 'spongestone')
      game.command("get my rock from my #{bag}", ENCHANT_LOG[:get_rock], gives: 'rock')
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_rock], takes: 'rock')
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.command('wave my fount at rock on my brazier', ENCHANT_LOG[:wave_fount_rock], takes: 'fount')
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at rock on my brazier', ENCHANT_LOG[:imbue_completes_rock_fount_used_up])
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      # No fount came back, so none is fetched: a GET of a fount that is gone
      # would stop the script before the rock is picked up.
      tidy_up('rock', fount: false)
    end

    it 'leaves the fount alone and still ends holding the rock' do
      run_script(chapter: '1', recipe: 'spongestone', noun: 'rock')

      expect_transcript_done
      expect(game.hands).to eq(['rock', nil])
      expect(game.feet).to eq([])
    end

    it 'says the fount is used up' do
      run_script(chapter: '1', recipe: 'spongestone', noun: 'rock')

      expect(game.messages).to include('Enchant: The fount was used up and is gone.')
    end
  end

  context 'when the sigil-scroll the game asks for is not there' do
    before(:each) do
      book_start(chapter: '1', recipe: 'spongestone')
      game.command("get my rock from my #{bag}", ENCHANT_LOG[:get_rock], gives: 'rock')
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_rock], takes: 'rock')
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.command('wave my fount at rock on my brazier', ENCHANT_LOG[:wave_fount_rock], takes: 'fount')
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at rock on my brazier', ENCHANT_LOG[:imbue_wants_congruence])
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      game.call('DRCI.get_item?', 'congruence sigil', returns: false)
      # Nothing more: scribing on would only get the same request back
      # (log 1: a scribe while a sigil is wanted repeats "You need another").
    end

    it 'stops instead of scribing on' do
      expect { run_script(chapter: '1', recipe: 'spongestone', noun: 'rock') }.to raise_error(SystemExit)

      expect_transcript_done
    end

    it 'says which scroll is missing and that the rock is still on the brazier' do
      expect { run_script(chapter: '1', recipe: 'spongestone', noun: 'rock') }.to raise_error(SystemExit)

      expect(game.messages).to include('Enchant: No congruence sigil-scroll to study; the rock is still on the brazier.')
    end

    it 'removes its flags on the way out' do
      expect { run_script(chapter: '1', recipe: 'spongestone', noun: 'rock') }.to raise_error(SystemExit)

      expect(Flags.matchers.keys & Enchant::FLAG_NAMES).to eq([])
    end
  end

  context 'when the rock cannot be fetched or put on the brazier' do
    before(:each) do
      book_start(chapter: '1', recipe: 'spongestone')
    end

    it 'stops when there is no hand free for the rock (log 1)' do
      game.command("get my rock from my #{bag}", ['You need a free hand to pick that up.'])

      expect { run_script(chapter: '1', recipe: 'spongestone', noun: 'rock') }.to raise_error(SystemExit)

      expect_transcript_done
      expect(game.messages).to include('Enchant: Could not get a rock from your duffel bag: You need a free hand to pick that up.')
    end

    it 'stops when there are no rocks left' do
      game.command("get my rock from my #{bag}", ['What were you referring to?'])

      expect { run_script(chapter: '1', recipe: 'spongestone', noun: 'rock') }.to raise_error(SystemExit)

      expect_transcript_done
    end

    it 'goes on to the PUT when a GET reply is missed but the rock is in hand' do
      game.command("get my rock from my #{bag}", [], gives: 'rock')
      game.command('put my rock on my brazier', ['What were you referring to?'])

      expect { run_script(chapter: '1', recipe: 'spongestone', noun: 'rock') }.to raise_error(SystemExit)

      expect_transcript_done
      expect(game.messages).to eq(['Enchant: Could not put the rock on the brazier: What were you referring to?'])
    end

    it 'stops when the rock is not in hand for the PUT (log 1)' do
      game.command("get my rock from my #{bag}", ENCHANT_LOG[:get_rock], gives: 'rock')
      game.command('put my rock on my brazier', ['You must be holding the rocks before doing that.'])

      expect { run_script(chapter: '1', recipe: 'spongestone', noun: 'rock') }.to raise_error(SystemExit)

      expect_transcript_done
      expect(game.messages).to include('Enchant: Could not put the rock on the brazier: You must be holding the rocks before doing that.')
    end

    it 'stops when no brazier is in reach (log 2)' do
      game.command("get my rock from my #{bag}", ENCHANT_LOG[:get_rock], gives: 'rock')
      game.command('put my rock on my brazier', ['What were you referring to?'])

      expect { run_script(chapter: '1', recipe: 'spongestone', noun: 'rock') }.to raise_error(SystemExit)

      expect_transcript_done
    end

    it 'stops when the brazier only ever asks to confirm' do
      game.command("get my rock from my #{bag}", ENCHANT_LOG[:get_rock], gives: 'rock')
      2.times { game.command('put my rock on my brazier', ENCHANT_LOG[:put_glance]) }

      expect { run_script(chapter: '1', recipe: 'spongestone', noun: 'rock') }.to raise_error(SystemExit)

      expect_transcript_done
    end

    it 'stops when no rock is left after cleaning a dangerous brazier' do
      game.command("get my rock from my #{bag}", ['That is far too dangerous to do with the brazier in this state.'])
      game.command('clean my brazier', ['You prepare to clean off the brazier.'])
      game.command('clean my brazier', ['You clean the brazier, and a massive ball of flame jets forward and singes everything nearby!'])
      game.command('look on my brazier', ['There is nothing on there.'])
      game.call('DRCI.get_item?', 'rock', bag, returns: false)

      expect { run_script(chapter: '1', recipe: 'spongestone', noun: 'rock') }.to raise_error(SystemExit)

      expect_transcript_done
    end
  end

  context 'when there is no fount' do
    it 'stops before reading the recipe, so nothing is left on the brazier' do
      allow(DRCI).to receive(:exists?).with('fount').and_return(false)
      game.call('EquipmentManager#empty_hands')
      game.call('DRC.wait_for_script_to_complete', 'buff', ['enchant'])

      expect { run_script(chapter: '1', recipe: 'spongestone', noun: 'rock') }.to raise_error(SystemExit)

      expect_transcript_done
      expect(game.messages).to eq(['Enchant: fount not found in inventory. Cannot proceed.'])
    end
  end

  context 'when the fount wave does not take' do
    before(:each) do
      book_start(chapter: '1', recipe: 'spongestone')
      game.command("get my rock from my #{bag}", ENCHANT_LOG[:get_rock], gives: 'rock')
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_rock], takes: 'rock')
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      # Log 1: the parser's reply to a wave with no fount in hand.
      game.command('wave my fount at rock on my brazier', ['I do not understand what you mean.'])
    end

    it 'stops instead of imbuing without a fount' do
      expect { run_script(chapter: '1', recipe: 'spongestone', noun: 'rock') }.to raise_error(SystemExit)

      expect_transcript_done
      expect(game.messages).to eq(['Enchant: Could not wave the fount at the rock: I do not understand what you mean.'])
    end
  end

  context 'when a scribing step cannot work' do
    before(:each) do
      book_start(chapter: '2', recipe: 'virga wand')
      game.command("get my wand from my #{bag}", ENCHANT_LOG[:get_wand], gives: 'redwood wand')
      game.command('put my wand on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my wand on my brazier', ENCHANT_LOG[:put_wand], takes: 'wand')
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.command('wave my fount at wand on my brazier', ENCHANT_LOG[:wave_fount_wand], takes: 'fount')
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at wand on my brazier', ENCHANT_LOG[:imbue_wants_induction])
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      game.call('DRCI.get_item?', 'induction sigil', gives: 'induction sigil')
      game.command('study my induction sigil', ENCHANT_LOG[:study_sigil], takes: 'induction sigil')
      game.command('trace wand on my brazier', ENCHANT_LOG[:trace_wand])
      game.call('DRCC.get_crafting_item', 'burin', bag, [], nil, gives: 'burin')
    end

    it 'stops when the brazier is not to hand (log 2, "You jot down some notes.")' do
      game.command('scribe wand on my brazier with my burin', ['You jot down some notes.'])

      expect { run_script(chapter: '2', recipe: 'virga wand', noun: 'wand') }.to raise_error(SystemExit)

      expect_transcript_done
      expect(game.messages).to eq(['Enchant: You jot down some notes. The wand is still on the brazier.'])
    end

    it 'stops when the burin is not in hand (log 1)' do
      game.command('scribe wand on my brazier with my burin', ['You must be holding the burin to do that.'])

      expect { run_script(chapter: '2', recipe: 'virga wand', noun: 'wand') }.to raise_error(SystemExit)

      expect_transcript_done
    end

    it 'stops after three scribes in a row get no reply it knows' do
      3.times { game.command('scribe wand on my brazier with my burin', []) }

      expect { run_script(chapter: '2', recipe: 'virga wand', noun: 'wand') }.to raise_error(SystemExit)

      expect_transcript_done
      expect(game.messages).to eq(['Enchant: No reply to scribe wand on my brazier with my burin 3 times in a row; the wand is still on the brazier.'])
    end

    it 'keeps going when a known reply comes between the silent ones' do
      2.times { game.command('scribe wand on my brazier with my burin', []) }
      game.command('scribe wand on my brazier with my burin', ENCHANT_LOG[:scribe_wand])
      2.times { game.command('scribe wand on my brazier with my burin', []) }
      game.command('scribe wand on my brazier with my burin', ENCHANT_LOG[:scribe_wand_wants_imbue])
      final_rod_imbue('wand', ENCHANT_LOG[:imbue_completes_wand])
      tidy_up('wand')

      run_script(chapter: '2', recipe: 'virga wand', noun: 'wand')

      expect_transcript_done
      expect(game.hands).to eq(['wand', nil])
    end
  end

  context 'with the brazier held in the left hand' do
    before(:each) do
      game.call('EquipmentManager#empty_hands')
      game.call('DRC.wait_for_script_to_complete', 'buff', ['enchant'])
      game.call('DRCC.get_crafting_item', 'artificing book', bag, [], nil, gives: 'artificing book')
      game.call('DRCC.find_recipe2', '1', 'spongestone')
      game.call('DRCC.stow_crafting_item', 'book', bag, nil, takes: 'book')
      game.call('DRCC.get_crafting_item', 'brazier', bag, [], nil, gives: { left: 'brazier' })
      game.command("get my rock from my #{bag}", ENCHANT_LOG[:get_rock], gives: 'rock')
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_rock], takes: 'rock')
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.command('wave my fount at rock on my brazier', ENCHANT_LOG[:wave_fount_rock], takes: 'fount')
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at rock on my brazier', ENCHANT_LOG[:imbue_wants_congruence])
      # The rod is in the right hand. Left in hand, it would leave no hand
      # free for the burin.
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      game.call('DRCI.get_item?', 'congruence sigil', gives: 'congruence sigil')
      game.command('study my congruence sigil', ENCHANT_LOG[:study_sigil], takes: 'congruence sigil')
      game.command('trace rock on my brazier', ENCHANT_LOG[:trace_rock])
      game.call('DRCC.get_crafting_item', 'burin', bag, [], nil, gives: 'burin')
      game.command('scribe rock on my brazier with my burin', ENCHANT_LOG[:scribe_rock_merging])
      # The burin is in the right hand too; it goes back before the loop.
      game.call('DRCC.stow_crafting_item', 'burin', bag, nil, takes: 'burin')
      game.call('DRCC.get_crafting_item', 'augmenting loop', bag, [], nil, gives: 'augmenting loop')
      game.command('push rock on my brazier with my augmenting loop', ENCHANT_LOG[:push_rock])
      game.call('DRCC.stow_crafting_item', 'augmenting loop', bag, nil, takes: 'augmenting loop')
      game.call('DRCC.get_crafting_item', 'burin', bag, [], nil, gives: 'burin')
      game.command('scribe rock on my brazier with my burin', ENCHANT_LOG[:scribe_rock_blurs])
      game.command('meditate fount on my brazier', ENCHANT_LOG[:meditate_wants_imbue])
      final_rod_imbue('rock', ENCHANT_LOG[:imbue_completes_rock])
      tidy_up('rock', held: %w[brazier])
    end

    it 'puts the rod and burin away from the right hand and ends holding the rock' do
      run_script(chapter: '1', recipe: 'spongestone', noun: 'rock')

      expect_transcript_done
      expect(game.hands).to eq(['rock', nil])
    end
  end

  context 'resuming an item that wants an imbue' do
    before(:each) do
      game.call('EquipmentManager#empty_hands')
      game.call('DRC.wait_for_script_to_complete', 'buff', ['enchant'])
      game.call('DRCC.get_crafting_item', 'brazier', bag, [], nil, gives: 'brazier')
      # Code-derived replies: no analyze or look on a brazier in the logs.
      game.command('analyze rock on my brazier', ['You believe it requires the application of an imbue spell to advance the enchanting process.'])
      game.command('look on my brazier', ['On the brazier you see a rock and a fount.'])
    end

    it 'finishes the item when the imbue completes it, and ends holding the rock' do
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at rock on my brazier', ENCHANT_LOG[:imbue_completes_rock])
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      tidy_up('rock')

      run_script(resume: 'resume', noun: 'rock')

      expect_transcript_done
      expect(game.hands).to eq(['rock', nil])
      expect(game.feet).to eq([])
    end

    it 'scribes on when the imbue asks for more' do
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at rock on my brazier', ENCHANT_LOG[:imbue_wants_congruence])
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      game.call('DRCI.get_item?', 'congruence sigil', gives: 'congruence sigil')
      game.command('study my congruence sigil', ENCHANT_LOG[:study_sigil], takes: 'congruence sigil')
      game.command('trace rock on my brazier', ENCHANT_LOG[:trace_rock])
      game.call('DRCC.get_crafting_item', 'burin', bag, [], nil, gives: 'burin')
      game.command('scribe rock on my brazier with my burin', ENCHANT_LOG[:scribe_rock_blurs])
      game.command('meditate fount on my brazier', ENCHANT_LOG[:meditate_wants_imbue])
      final_rod_imbue('rock', ENCHANT_LOG[:imbue_completes_rock])
      tidy_up('rock')

      run_script(resume: 'resume', noun: 'rock')

      expect_transcript_done
      expect(game.hands).to eq(['rock', nil])
    end
  end

  context 'a spongestone from Dorhum\'s instructions (log 1, the second item)' do
    before(:each) do
      game.call('EquipmentManager#empty_hands')
      game.call('DRC.wait_for_script_to_complete', 'buff', ['enchant'])
      game.call('DRCC.get_crafting_item', 'spongestone instructions', bag, [], nil, true, gives: 'spongestone instructions')
      game.command('study my spongestone instructions', ENCHANT_LOG[:study_instructions_again])
      game.command('study my spongestone instructions', ENCHANT_LOG[:study_spongestone_instructions])
      game.call('DRCC.stow_crafting_item', 'spongestone instructions', bag, nil, takes: 'spongestone instructions')
      game.call('DRCC.get_crafting_item', 'brazier', bag, [], nil, gives: 'brazier')
      game.command("get my rock from my #{bag}", ENCHANT_LOG[:get_rock], gives: 'rock')
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my rock on my brazier', ENCHANT_LOG[:put_rock], takes: 'rock')
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.command('wave my fount at rock on my brazier', ENCHANT_LOG[:wave_fount_rock], takes: 'fount')
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at rock on my brazier', ENCHANT_LOG[:imbue_wants_congruence])
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      game.call('DRCI.get_item?', 'congruence sigil', gives: 'congruence sigil')
      game.command('study my congruence sigil', ENCHANT_LOG[:study_sigil], takes: 'congruence sigil')
      game.command('trace rock on my brazier', ENCHANT_LOG[:trace_rock])
      game.call('DRCC.get_crafting_item', 'burin', bag, [], nil, gives: 'burin')
      game.command('scribe rock on my brazier with my burin', ENCHANT_LOG[:scribe_rock_wants_decay])
      game.call('DRCC.stow_crafting_item', 'burin', bag, nil, takes: 'burin')
      game.call('DRCI.get_item?', 'decay sigil', gives: 'decay sigil')
      game.command('study my decay sigil', ENCHANT_LOG[:study_sigil], takes: 'decay sigil')
      game.command('trace rock on my brazier', ENCHANT_LOG[:trace_rock])
      game.call('DRCC.get_crafting_item', 'burin', bag, [], nil, gives: 'burin')
      game.command('scribe rock on my brazier with my burin', ENCHANT_LOG[:scribe_rock_blurs])
      game.command('meditate fount on my brazier', ENCHANT_LOG[:meditate_wants_imbue])
      final_rod_imbue('rock', ENCHANT_LOG[:imbue_completes_rock])
      tidy_up('rock')
    end

    it 'studies the instructions instead of the book and ends holding the rock' do
      run_script(instructions: 'instructions', recipe: 'spongestone', noun: 'rock')

      expect_transcript_done
      expect(game.hands).to eq(['rock', nil])
    end
  end

  context 'a virga wand from Dorhum\'s instructions (log 2), the base item named apart' do
    before(:each) do
      game.call('EquipmentManager#empty_hands')
      game.call('DRC.wait_for_script_to_complete', 'buff', ['enchant'])
      game.call('DRCC.get_crafting_item', 'virga wand instructions', bag, [], nil, true, gives: 'virga wand instructions')
      game.command('study my virga wand instructions', ENCHANT_LOG[:study_instructions_again])
      game.command('study my virga wand instructions', ENCHANT_LOG[:study_wand_instructions])
      game.call('DRCC.stow_crafting_item', 'virga wand instructions', bag, nil, takes: 'virga wand instructions')
      game.call('DRCC.get_crafting_item', 'brazier', bag, [], nil, gives: 'brazier')
      game.command("get my wand from my #{bag}", ENCHANT_LOG[:get_wand], gives: 'redwood wand')
      game.command('put my wand on my brazier', ENCHANT_LOG[:put_glance])
      game.command('put my wand on my brazier', ENCHANT_LOG[:put_wand], takes: 'wand')
      game.call('DRCC.get_crafting_item', 'fount', bag, [], nil, gives: 'fount')
      game.command('wave my fount at wand on my brazier', ENCHANT_LOG[:wave_fount_wand], takes: 'fount')
      game.call('DRCC.get_crafting_item', 'imbuement rod', bag, [], nil, gives: 'imbuement rod')
      game.command('wave imbuement rod at wand on my brazier', ENCHANT_LOG[:imbue_wants_induction])
      game.call('DRCC.stow_crafting_item', 'imbuement rod', bag, nil, takes: 'imbuement rod')
      game.call('DRCI.get_item?', 'induction sigil', gives: 'induction sigil')
      game.command('study my induction sigil', ENCHANT_LOG[:study_sigil], takes: 'induction sigil')
      game.command('trace wand on my brazier', ENCHANT_LOG[:trace_wand])
      game.call('DRCC.get_crafting_item', 'burin', bag, [], nil, gives: 'burin')
      game.command('scribe wand on my brazier with my burin', ENCHANT_LOG[:scribe_wand_wants_imbue])
      final_rod_imbue('wand', ENCHANT_LOG[:imbue_completes_wand])
      tidy_up('wand')
    end

    it 'studies the virga wand instructions and ends holding the wand' do
      run_script(instructions: 'instructions', recipe: 'virga wand', noun: 'wand', base_noun: 'wand')

      expect_transcript_done
      expect(game.hands).to eq(['wand', nil])
    end
  end

  context 'when the instructions cannot be studied' do
    it 'stops before touching the brazier' do
      game.call('EquipmentManager#empty_hands')
      game.call('DRC.wait_for_script_to_complete', 'buff', ['enchant'])
      game.call('DRCC.get_crafting_item', 'spongestone instructions', bag, [], nil, true, returns: false)

      expect { run_script(instructions: 'instructions', recipe: 'spongestone', noun: 'rock') }.to raise_error(SystemExit)

      expect_transcript_done
      expect(game.messages).to eq(['Enchant: Could not study the spongestone instructions.'])
    end
  end
end
