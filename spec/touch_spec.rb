require 'spec_helper'

# touch.lic is an empath healing window. The GTK window and the game loop need
# the live runtime, so these specs cover the three pure pieces they are built
# on: the TOUCH / PERCEIVE HEALTH parser, the per-patient wound model, and the
# command builder that turns a click into TAKE / LINK / spell actions.
describe 'touch.lic' do
  before(:all) do
    load_lic_class('touch.lic', 'TouchParser')
    load_lic_class('touch.lic', 'TouchPatient')
    load_lic_class('touch.lic', 'TouchCommands')
  end

  let(:link_line) { 'You sense a successful empathic link has been forged between you and Navesi.' }

  describe 'TouchParser' do
    subject(:parser) { TouchParser.new }

    def wounds_from(*lines)
      ([link_line] + lines).flat_map { |line| parser.feed(line) }.select { |event| event.first == :wound }
    end

    it 'opens a fresh tab for the patient named in the empathic link' do
      expect(parser.feed(link_line)).to eq([[:patient, 'Navesi'], [:reset, 'Navesi']])
      expect(parser.patient).to eq('Navesi')
    end

    it 'ignores wound lines that are not part of TOUCH output' do
      expect(parser.feed('Wounds to the HEAD:')).to eq([])
      expect(parser.feed('Fresh External:  light scratches -- negligible')).to eq([])
    end

    it 'reads each wound with its body part, type and severity' do
      events = wounds_from(
        'Wounds to the RIGHT LEG:',
        'Fresh External:  cuts and bruises about the right leg -- more than minor',
        'Scars Internal:  an occasional twitch in the right leg -- insignificant'
      )

      expect(events).to eq([
                             [:wound, 'Navesi', :fresh_external, :right_leg, 4],
                             [:wound, 'Navesi', :scar_internal, :right_leg, 1]
                           ])
    end

    it 'does not read "very harmful" as "harmful"' do
      events = wounds_from('Wounds to the CHEST:', 'Fresh External:  deep slashes across the chest -- very harmful')

      expect(events.first.last).to eq(6)
    end

    it 'prefers the (n/13) level when the game shows one' do
      events = wounds_from('Wounds to the NECK:', 'Fresh Internal:  a swollen neck -- devastating (12/13)')

      expect(events.first.last).to eq(12)
    end

    it 'reads "insignificant to negligible" as level 1' do
      events = wounds_from('Wounds to the BACK:', 'Scars External:  faint scars -- insignificant to negligible')

      expect(events.first.last).to eq(1)
    end

    it 'skips wounds listed under a body part it does not know' do
      expect(wounds_from('Wounds to the WINGS:', 'Fresh External:  torn feathers -- minor')).to eq([])
    end

    it 'reads the remaining-vitality line' do
      parser.feed(link_line)

      expect(parser.feed('(Navesi has 55% vitality remaining.)')).to eq([[:vitality, 'Navesi', 55]])
    end

    it 'turns a vitality-loss line into the vitality left' do
      parser.feed(link_line)

      expect(parser.feed('Navesi is suffering from a moderate loss of vitality (38%).')).to eq([[:vitality, 'Navesi', 62]])
    end

    it 'counts each poison line' do
      parser.feed(link_line)
      parser.feed('Navesi has a mild case of Hydra poison.')

      expect(parser.feed('Navesi is having trouble breathing from Cyanide poison!')).to eq([[:poison, 'Navesi', 2]])
    end

    it 'flags disease' do
      parser.feed(link_line)

      expect(parser.feed('Navesi has a dormant infection.')).to eq([[:disease, 'Navesi']])
    end

    it 'flags a dead patient' do
      parser.feed(link_line)

      expect(parser.feed('He is dead.')).to eq([[:dead, 'Navesi']])
    end

    it 'starts a Self tab from PERCEIVE HEALTH SELF' do
      expect(parser.feed('Your injuries include...')).to eq([[:patient, 'Self'], [:reset, 'Self']])
      expect(parser).to be_parsing
    end

    it 'clears the Self tab when there is nothing to perceive' do
      line = 'You close your eyes, centering your thoughts on your own life essence, but feel only an aching emptiness.'

      expect(parser.feed(line)).to eq([[:patient, 'Self'], [:reset, 'Self']])
      expect(parser).not_to be_parsing
    end

    it 'stops reading at the prompt' do
      parser.feed(link_line)
      parser.finish

      expect(parser.feed('Navesi has a dormant infection.')).to eq([])
    end

    it 'stops reading at Roundtime' do
      parser.feed(link_line)
      parser.feed('Roundtime: 1 sec.')

      expect(parser.feed('(Navesi has 55% vitality remaining.)')).to eq([])
    end

    it 'restarts poison counting for each new TOUCH' do
      parser.feed(link_line)
      parser.feed('Navesi has a mild case of Hydra poison.')
      parser.finish
      parser.feed(link_line)

      expect(parser.feed('Navesi has a mild case of Hydra poison.')).to eq([[:poison, 'Navesi', 1]])
    end

    it 'accepts extra link messages from touch_link_patterns' do
      custom = TouchParser.new(['Your hand tingles as you link with {name}.'])

      expect(custom.feed('Your hand tingles as you link with Tenuk.')).to eq([[:patient, 'Tenuk'], [:reset, 'Tenuk']])
      expect(custom.feed(link_line).first).to eq([:patient, 'Navesi'])
    end

    it 'ignores a link pattern without {name}' do
      expect(TouchParser.pattern_to_regex('You feel a link.')).to be_nil
    end

    it 'still knows the standard link message when touch_link_patterns is missing or malformed' do
      [nil, 'not a list', [nil, 42, { 'x' => 1 }]].each do |setting|
        expect(TouchParser.new(setting).feed(link_line).first).to eq([:patient, 'Navesi'])
      end
    end
  end

  describe 'TouchPatient' do
    subject(:patient) { TouchPatient.new('Navesi') }

    it 'starts unhurt' do
      expect(patient.vitality).to eq(100)
      expect(patient.wound_list).to eq([])
    end

    it 'lists wounds worst first, keeping perceive order for ties' do
      patient.apply([:wound, 'Navesi', :fresh_external, :head, 3])
      patient.apply([:wound, 'Navesi', :fresh_external, :chest, 9])
      patient.apply([:wound, 'Navesi', :scar_external, :neck, 3])

      expect(patient.wound_list).to eq([
                                         [:fresh_external, :chest, 9],
                                         [:fresh_external, :head, 3],
                                         [:scar_external, :neck, 3]
                                       ])
    end

    it 'forgets everything on reset' do
      patient.apply([:wound, 'Navesi', :fresh_external, :head, 3])
      patient.apply([:poison, 'Navesi', 2])
      patient.apply([:disease, 'Navesi'])
      patient.apply([:reset, 'Navesi'])

      expect([patient.wound_list, patient.poison, patient.disease]).to eq([[], 0, false])
    end

    it 'hands out a snapshot later wounds do not change' do
      snapshot = patient.snapshot
      patient.apply([:wound, 'Navesi', :fresh_external, :head, 3])

      expect(snapshot[:wounds][:fresh_external]).to eq({})
    end
  end

  # touch_self_spells is optional fine-tuning; the script carries its own
  # defaults so an older base.yaml (no setting at all) still casts.
  describe 'Touch.spell_settings' do
    before(:all) { load_lic_class('touch.lic', 'Touch') }

    it 'has nothing to override when the setting is missing' do
      expect(Touch.spell_settings(nil)).to eq({})
    end

    it 'ignores a setting that is not a hash' do
      expect(Touch.spell_settings(%w[hw hs])).to eq({})
    end

    it 'keeps only the values given, for the defaults to fill in the rest' do
      spells = Touch.spell_settings('hw' => { 'mana' => 10 })

      expect(Touch::DEFAULT_SPELL.merge(spells['hw'])).to eq('mana' => 10, 'prep_time' => 5)
    end

    it 'drops values that are not usable numbers' do
      spells = Touch.spell_settings('hw' => { 'mana' => 'ten', 'prep_time' => -1 }, 'hs' => 'lots', 'vh' => { 'mana' => 0 })

      expect(spells).to eq('hw' => {}, 'vh' => {})
    end

    it 'accepts symbol and upper-case keys' do
      expect(Touch.spell_settings(HW: { mana: 12, prep_time: 2.5 })).to eq('hw' => { 'mana' => 12, 'prep_time' => 2.5 })
    end
  end

  # The script reads raw game XML from a DownstreamHook so its own fput calls
  # cannot swallow TOUCH output; this is the XML-to-parser step.
  describe 'Touch#drain_lines' do
    before(:all) { load_lic_class('touch.lic', 'Touch') }

    let(:touch) do
      instance = Touch.allocate
      instance.instance_variable_set(:@lines, Thread::Queue.new)
      instance.instance_variable_set(:@parser, TouchParser.new)
      instance.instance_variable_set(:@patients, {})
      allow(instance).to receive(:publish)
      # Lich's strip_xml for a balanced line: drop the tags, keep all text.
      allow(instance).to receive(:strip_xml) do |line, **|
        text = line.gsub(/<[^>]+>/, '').gsub('&gt;', '>').gsub('&lt;', '<')
        text.strip.empty? ? nil : text
      end
      instance
    end

    def drain(*raw_lines)
      raw_lines.each { |raw| touch.instance_variable_get(:@lines) << raw }
      touch.send(:drain_lines)
      touch.instance_variable_get(:@patients)
    end

    it 'reads a link that arrives on the same line as the previous prompt' do
      patients = drain(
        %(<prompt time="1">&gt;</prompt>You sense a successful empathic link has been forged between you and <a exist="1" noun="Navesi">Navesi</a>.\r\n),
        "Wounds to the HEAD:\r\n",
        "Fresh External:  light scratches -- negligible\r\n"
      )

      expect(patients['Navesi'].wound_list).to eq([[:fresh_external, :head, 2]])
    end

    it 'stops at the prompt so later lines are not credited to the patient' do
      patients = drain(
        "#{link_line}\r\n",
        %(<prompt time="1">&gt;</prompt>\r\n),
        "Navesi has a dormant infection.\r\n"
      )

      expect(patients['Navesi'].disease).to be false
    end

    # Regression: the first in-game test opened the tab but drew no wounds,
    # because a home-grown stream filter dropped the wound block. This is the
    # live output, indented as the game sends it.
    it 'reads the wound block of a real TOUCH' do
      patients = drain(
        "You touch Pazzlen.\r\n",
        "You sense a successful empathic link has been forged between you and Pazzlen.\r\n",
        "Pazzlen's injuries include...\r\n",
        "Wounds to the HEAD:\r\n",
        "  Fresh External:  cuts and bruises about the head -- more than minor\r\n",
        "  Fresh Internal:  a deeply bruised head -- very harmful\r\n",
        "Wounds to the LEFT ARM:\r\n",
        "  Fresh External:  light scratches -- insignificant\r\n",
        "(Pazzlen has 100% vitality remaining.)\r\n"
      )

      expect(patients['Pazzlen'].wound_list).to eq([
                                                     [:fresh_internal, :head, 6],
                                                     [:fresh_external, :head, 4],
                                                     [:fresh_external, :left_arm, 1]
                                                   ])
    end

    it 'keeps wound lines the game wraps in a stream' do
      patients = drain(
        "#{link_line}\r\n",
        %(<pushStream id="percWindow"/>Wounds to the CHEST:\r\n),
        "  Fresh External:  deep slashes across the chest -- very harmful<popStream/>\r\n"
      )

      expect(patients['Navesi'].wound_list).to eq([[:fresh_external, :chest, 6]])
    end

    it 'reads every line when Lich hands back a joined multi-line stream' do
      joined = "Wounds to the NECK:\r\n  Scars External:  a tiny scar -- negligible\r\n"
      allow(touch).to receive(:strip_xml) { |line, **| line.include?('<buffered/>') ? joined : line }

      patients = drain("#{link_line}\r\n", "<buffered/>\r\n")

      expect(patients['Navesi'].wound_list).to eq([[:scar_external, :neck, 2]])
    end

    it 'tells the window which patient to bring forward' do
      drain("#{link_line}\r\n")

      expect(touch).to have_received(:publish).with({ 'Navesi' => true })
    end
  end

  describe 'TouchCommands' do
    let(:defaults) do
      { include_internal: true, include_scars: true, quick: false, half_on_major: false, leave_bleeders: false, click_amount: 'all' }
    end

    def commands(actions)
      actions.map(&:last)
    end

    describe '.touch' do
      it 'touches a patient' do
        expect(TouchCommands.touch('Navesi')).to eq([[:command, 'touch Navesi']])
      end

      it 'perceives your own health for Self' do
        expect(TouchCommands.touch('Self')).to eq([[:command, 'perceive health self']])
      end
    end

    describe '.take_wound' do
      it 'names internal scars' do
        expect(TouchCommands.take_wound('Navesi', :scar_internal, :left_arm, 'half', quick: true))
          .to eq([[:command, 'take Navesi left arm internal scar half quick']])
      end

      it 'takes all of it for "all"' do
        expect(TouchCommands.take_wound('Navesi', :fresh_external, :head, 'all'))
          .to eq([[:command, 'take Navesi head']])
      end

      it 'casts Heal Wounds or Heal Scars at the area on Self, naming the layer' do
        expect(TouchCommands.take_wound('Self', :fresh_external, :right_hand)).to eq([[:spell, 'hw', 'right hand external']])
        expect(TouchCommands.take_wound('Self', :scar_external, :right_hand)).to eq([[:spell, 'hs', 'right hand external']])
        expect(TouchCommands.take_wound('Self', :fresh_internal, :chest)).to eq([[:spell, 'hw', 'chest internal']])
        expect(TouchCommands.take_wound('Self', :scar_internal, :chest)).to eq([[:spell, 'hs', 'chest internal']])
      end
    end

    describe '.click_wound' do
      it 'takes half of a wound past very damaging with Half On Major' do
        actions = TouchCommands.click_wound('Navesi', :fresh_external, :chest, 9, defaults.merge(half_on_major: true))

        expect(commands(actions)).to eq(['take Navesi chest half'])
      end

      it 'takes all of a lesser wound with Half On Major' do
        actions = TouchCommands.click_wound('Navesi', :fresh_external, :chest, 7, defaults.merge(half_on_major: true))

        expect(commands(actions)).to eq(['take Navesi chest'])
      end

      it 'takes the amount picked under Left-Click Takes' do
        %w[part half most].each do |amount|
          actions = TouchCommands.click_wound('Navesi', :scar_internal, :neck, 3, defaults.merge(click_amount: amount, quick: true))

          expect(commands(actions)).to eq(["take Navesi neck internal scar #{amount} quick"])
        end
      end

      it 'lets a picked amount win over Half On Major' do
        options = defaults.merge(click_amount: 'most', half_on_major: true)

        expect(commands(TouchCommands.click_wound('Navesi', :fresh_external, :chest, 9, options))).to eq(['take Navesi chest most'])
      end

      it 'takes all of it when the amount is missing or unknown' do
        [nil, 'everything'].each do |amount|
          actions = TouchCommands.click_wound('Navesi', :fresh_external, :chest, 4, defaults.merge(click_amount: amount))

          expect(commands(actions)).to eq(['take Navesi chest'])
        end
      end

      it 'still casts on Self whatever the amount' do
        actions = TouchCommands.click_wound('Self', :fresh_external, :chest, 4, defaults.merge(click_amount: 'part'))

        expect(actions).to eq([[:spell, 'hw', 'chest external']])
      end

      # Mahtra's review: a plain CAST <area> heals externals first, so a click
      # on an internal wound has to say internal to reach it.
      it 'casts at the internal layer when an internal wound is clicked on Self' do
        expect(TouchCommands.click_wound('Self', :fresh_internal, :chest, 6, defaults)).to eq([[:spell, 'hw', 'chest internal']])
      end

      it 'halves a very damaging wound (8/13) with Half On Major, as Genie Crutch did' do
        actions = TouchCommands.click_wound('Navesi', :fresh_external, :chest, 8, defaults.merge(half_on_major: true))

        expect(commands(actions)).to eq(['take Navesi chest half'])
      end
    end

    describe '.take_condition' do
      it 'takes vitality, poison and disease from a patient' do
        quick = defaults.merge(quick: true)

        expect(commands(TouchCommands.take_condition('Navesi', 'vitality', quick))).to eq(['take Navesi vitality quick'])
        expect(commands(TouchCommands.take_condition('Navesi', 'poison', quick))).to eq(['take Navesi quick poison'])
        expect(commands(TouchCommands.take_condition('Navesi', 'disease', defaults))).to eq(['take Navesi disease'])
      end

      it 'casts the matching spell on Self' do
        expect(TouchCommands.take_condition('Self', 'poison', defaults)).to eq([[:spell, 'fp', nil]])
      end
    end

    describe '.take_all' do
      let(:wounds) do
        [[:fresh_external, :chest, 9], [:fresh_internal, :head, 4], [:scar_external, :neck, 2]]
      end

      # Mahtra's review: the tab must redraw after the TAKE, not only before it.
      it "uses the game's TAKE ALL between a touch for the link and one to redraw" do
        expect(commands(TouchCommands.take_all('Navesi', wounds, defaults)))
          .to eq(['touch Navesi', 'take Navesi all', 'touch Navesi'])
      end

      it 'leaves bleeders past harmful, then takes the scars of what it took' do
        actions = TouchCommands.take_all('Navesi', wounds, defaults.merge(leave_bleeders: true))

        expect(commands(actions)).to eq([
                                          'take Navesi head internal',
                                          'take Navesi neck scar',
                                          'take Navesi head internal scar',
                                          'touch Navesi'
                                        ])
      end

      it 'skips internal wounds and scars when those options are off' do
        options = defaults.merge(include_internal: false, include_scars: false)

        expect(commands(TouchCommands.take_all('Navesi', wounds, options))).to eq(['take Navesi chest', 'touch Navesi'])
      end

      it 'never sends the same TAKE twice' do
        repeated = [[:fresh_external, :chest, 3], [:scar_external, :chest, 3]]
        actions = TouchCommands.take_all('Navesi', repeated, defaults.merge(quick: true, half_on_major: true))

        expect(commands(actions)).to eq(['take Navesi chest quick', 'take Navesi chest scar quick', 'touch Navesi'])
      end

      it 'takes whole wounds whatever Left-Click Takes is set to' do
        options = defaults.merge(leave_bleeders: true, include_scars: false, click_amount: 'part')

        expect(commands(TouchCommands.take_all('Navesi', wounds, options))).to eq(['take Navesi head internal', 'touch Navesi'])
      end

      it 'heals internal and external wounds on Self, each at its own layer' do
        expect(TouchCommands.take_all('Self', wounds, defaults))
          .to eq([[:spell, 'hw', 'chest external'], [:spell, 'hw', 'head internal'], [:spell, 'hs', 'neck external']])
      end

      # Mahtra's review: with only internal wounds, All on Self did nothing.
      it 'still casts on Self when the only wounds are internal' do
        expect(TouchCommands.take_all('Self', [[:fresh_internal, :chest, 6]], defaults)).to eq([[:spell, 'hw', 'chest internal']])
      end
    end

    describe '.take_minor' do
      it 'takes only wounds below harmful, touching before and after' do
        wounds = [[:fresh_external, :chest, 9], [:fresh_external, :head, 4]]

        expect(commands(TouchCommands.take_minor('Navesi', wounds, defaults))).to eq(['touch Navesi', 'take Navesi head', 'touch Navesi'])
      end

      it 'on Self, casts once per part and layer' do
        wounds = [[:fresh_external, :head, 3], [:fresh_internal, :head, 3], [:fresh_external, :head, 2]]

        expect(TouchCommands.take_minor('Self', wounds, defaults))
          .to eq([[:spell, 'hw', 'head external'], [:spell, 'hw', 'head internal']])
      end
    end

    describe '.link' do
      it 'links Hodierna on top of a persistent link' do
        expect(commands(TouchCommands.link('Navesi', 'hodierna')))
          .to eq(['touch Navesi', 'link Navesi persistent', 'link Navesi hodierna'])
      end
    end

    describe '.link_take' do
      it 'takes part of everything, touching before and after' do
        expect(commands(TouchCommands.link_take('Navesi', 'part', defaults.merge(quick: true))))
          .to eq(['touch Navesi', 'take Navesi part quick all', 'touch Navesi'])
      end
    end

    describe '.break_link' do
      it 'breaks a link to a patient but never to yourself' do
        expect(TouchCommands.break_link('Navesi')).to eq([[:command, 'break Navesi']])
        expect(TouchCommands.break_link('Self')).to eq([])
        expect(TouchCommands.break_link(nil)).to eq([])
      end
    end

    # Tooltips and the status line print these, so they must name the layer.
    describe '.describe' do
      it 'names the spell and where it is cast' do
        expect(TouchCommands.describe([:spell, 'hw', 'left leg external'])).to eq('cast Heal Wounds at left leg external')
        expect(TouchCommands.describe([:spell, 'vh', nil])).to eq('cast Vitality Healing')
      end

      it 'shows a command as sent' do
        expect(TouchCommands.describe([:command, 'take Navesi chest half'])).to eq('take Navesi chest half')
      end
    end

    # The status strip: who and what, short enough for the default width.
    describe '.task_label' do
      it 'names the patient and the task' do
        expect(TouchCommands.task_label(:take_all, 'Pazzlen')).to eq('Pazzlen: Take all')
        expect(TouchCommands.task_label(:touch, 'Pazzlen')).to eq('Pazzlen: Touch')
        expect(TouchCommands.task_label(:break, 'Pazzlen')).to eq('Pazzlen: Break link')
        expect(TouchCommands.task_label(:take_condition, 'Pazzlen', ['vitality'])).to eq('Pazzlen: Take vitality')
      end

      it 'says heal on the Self tab, with the wound layer' do
        expect(TouchCommands.task_label(:take_all, 'Self')).to eq('Self: Heal all')
        expect(TouchCommands.task_label(:take_wound, 'Self', [:fresh_internal, :left_leg])).to eq('Self: Heal left leg (fresh int)')
        expect(TouchCommands.task_label(:take_condition, 'Self', ['poison'])).to eq('Self: Flush poison')
      end

      it 'labels requests that are not about one patient' do
        expect(TouchCommands.task_label(:break_all, nil)).to eq('Cancel all links')
        expect(TouchCommands.task_label(:cast, nil, ['regen'])).to eq('Self: Cast Regenerate')
      end
    end

    describe '.status_text' do
      let(:step) { { action: [:spell, 'hw', 'chest external'], label: 'Self: Heal all', step: 2, steps: 9 } }

      it 'shows progress while running, "done" once sent, and where it stopped' do
        expect(TouchCommands.status_text(step, :running)).to eq('Self: Heal all 2/9')
        expect(TouchCommands.status_text(step.merge(step: 9), :done)).to eq('Self: Heal all - done')
        expect(TouchCommands.status_text(step.merge(step: 3), :stopped)).to eq('Self: Heal all - stopped at 3/9')
      end

      it 'leaves the counter off a one-step task' do
        one = { action: [:command, 'touch Pazzlen'], label: 'Pazzlen: Touch', step: 1, steps: 1 }

        expect(TouchCommands.status_text(one, :running)).to eq('Pazzlen: Touch')
        expect(TouchCommands.status_text(one, :stopped)).to eq('Pazzlen: Touch - stopped')
      end
    end
  end

  # Regression: All on the Self tab queued one cast per wound, and Break could
  # not stop it, because it only cleared the queue between actions while each
  # cast sat in a fixed preparation wait.
  describe 'Touch stopping a cast' do
    before(:all) { load_lic_class('touch.lic', 'Touch') }

    let(:touch) do
      instance = Touch.allocate
      instance.instance_variable_set(:@intents, Thread::Queue.new)
      instance.instance_variable_set(:@pending, [])
      instance.instance_variable_set(:@spells, {})
      instance.instance_variable_set(:@patients, {})
      %i[show_status drain_lines pause waitrt? fput].each { |name| allow(instance).to receive(name) }
      allow(DRCA).to receive(:prepare?).and_return(true)
      allow(DRCA).to receive(:cast?).and_return(true)
      instance
    end

    it 'releases the spell, skips the cast and drops the queue when Break comes during preparation' do
      touch.instance_variable_get(:@pending) << [:spell, 'hw', 'left arm internal']
      touch.instance_variable_get(:@intents) << [:break, 'Self']

      touch.send(:cast_on_self, 'hw', 'chest external')

      expect(touch).to have_received(:fput).with('release spell')
      expect(DRCA).not_to have_received(:cast?)
      expect(touch.instance_variable_get(:@pending)).to eq([])
    end

    it 'stops when the window is closed during preparation' do
      touch.instance_variable_get(:@intents) << [:quit]

      touch.send(:cast_on_self, 'hw', 'chest external')

      expect(DRCA).not_to have_received(:cast?)
      expect(touch.instance_variable_get(:@quitting)).to be true
    end

    it 'casts at the named layer once preparation finishes' do
      touch.instance_variable_set(:@spells, { 'hw' => { 'prep_time' => 0 } })

      touch.send(:cast_on_self, 'hw', 'chest external')

      expect(DRCA).to have_received(:cast?).with('cast chest external')
    end
  end
end
