# frozen_string_literal: true

require 'ostruct'
require 'yaml'
require_relative 'spec_helper'

load_lic_class('mooniefill.lic', 'MoonieFill')

RSpec.describe MoonieFill do
  let(:settings) do
    OpenStruct.new(telescope_name: 'telescope', telescope_storage: { 'container' => 'rucksack' })
  end

  # The fields mooniefill reads, copied from data/base-constellations.yaml.
  let(:constellations) do
    [
      { 'name' => 'Elanthian Sun', 'telescope' => false, 'circle' => 1,  'constellation' => false, 'pools' => { 'Survival' => 1 } },
      { 'name' => 'Heart',         'telescope' => false, 'circle' => 1,  'constellation' => true,  'pools' => { 'Survival' => 1 } },
      { 'name' => 'Yavash',        'telescope' => false, 'circle' => 1,  'constellation' => false, 'pools' => { 'Magic' => 1 } },
      { 'name' => 'Wolf',          'telescope' => false, 'circle' => 2,  'constellation' => true,  'pools' => { 'Magic' => 1 } },
      { 'name' => 'Cobra',         'telescope' => false, 'circle' => 8,  'constellation' => true,  'pools' => { 'Magic' => 1, 'Lore' => 1 } },
      { 'name' => 'Scorpion',      'telescope' => true,  'circle' => 10, 'constellation' => true,  'pools' => { 'Offense' => 2, 'Defense' => 1 } },
      { 'name' => 'Ram',           'telescope' => false, 'circle' => 13, 'constellation' => true,  'pools' => { 'Survival' => 2 } },
      { 'name' => 'King Snake',    'telescope' => true,  'circle' => 20, 'constellation' => true,  'pools' => { 'Defense' => 1, 'Lore' => 2 } },
      { 'name' => 'Toad',          'telescope' => false, 'circle' => 44, 'constellation' => true,  'pools' => { 'Magic' => 2 } },
      { 'name' => 'Merewalda',     'telescope' => true,  'circle' => 65, 'constellation' => false, 'pools' => { 'Offense' => 1, 'Defense' => 3 } }
    ]
  end

  let(:constellations_data) do
    OpenStruct.new(
      constellations: constellations,
      observe_success_messages: ['You learned something useful from your observation', "While the sighting wasn't quite", 'you still learned more'],
      observe_injured_messages: ['The pain is too much', 'Your vision is too fuzzy']
    )
  end

  # --- A small model of the game, answering the commands mooniefill sends ---

  # OBSERVE HEAVENS listing (a night sky by default). Toad is above circle 20.
  let(:sky) do
    [
      'Yavash is rising in the east.',
      'The Heart is high overhead.',
      'Wolf is in the western sky.',
      'Ram is low in the north.',
      'Cobra is directly overhead.',
      'Toad is in the southern sky.',
      'Katamba is below the horizon.'
    ]
  end
  # PREDICT STATE words per pool, in the order the game reports them. The last one repeats.
  let(:pool_states) { {} }
  # CENTER replies per body. Anything not listed centers fine.
  let(:center_replies) { {} }
  # PEER outputs in order. The last one repeats, and a successful observation is the default.
  let(:peer_results) { [] }
  let(:learned) { ['You learned something useful from your observation.', 'Roundtime: 5 sec.'] }
  # Every command, plus :pause for each second spent waiting on the observation timer.
  let(:sent) { [] }
  let(:messages) { [] }

  def predict_reply(pool)
    words = pool_states.fetch(pool, ['complete'])
    word = words.size > 1 ? words.shift : words.first
    "You have a #{word} understanding of the celestial influences over #{pool}."
  end

  def game_reply(command)
    case command
    when /^predict state (\w+)$/
      predict_reply(Regexp.last_match(1))
    when /^center my telescope on (.+)$/
      body = Regexp.last_match(1)
      center_replies.fetch(body, "You put your eye to your telescope and find #{body}.")
    when 'open my telescope'
      'You extend your telescope to its full length.'
    when 'info'
      'Circle: 20'
    else
      ''
    end
  end

  # Like DRC.bput: the text matched by the first pattern that fits, or '' on a timeout.
  def bput_result(line, patterns)
    patterns.each do |pattern|
      match = line.match(pattern.is_a?(Regexp) ? pattern : /#{pattern}/i)
      return match[0] if match
    end
    ''
  end

  def centers
    sent.grep(/^center/)
  end

  def build_mooniefill
    described_class.allocate.tap do |mf|
      mf.instance_variable_set(:@settings, settings)
      mf.instance_variable_set(:@telescope_name, 'telescope')
      mf.instance_variable_set(:@telescope_storage, { 'container' => 'rucksack' })
      mf.instance_variable_set(:@constellations, constellations_data.constellations)
      mf.instance_variable_set(:@success_messages, constellations_data.observe_success_messages)
      mf.instance_variable_set(:@injured_messages, constellations_data.observe_injured_messages)
      mf.instance_variable_set(:@telescope_out, false)
      mf.instance_variable_set(:@awaiting_ponder, false)
      # The pondered message arrives after one second of waiting.
      allow(mf).to receive(:pause) do
        sent << :pause
        Flags[MoonieFill::PONDERED_FLAG] = true
      end
    end
  end

  let(:mooniefill) { build_mooniefill }

  before(:each) do
    DRStats.guild = 'Moon Mage'
    DRStats.circle = 20
    $test_settings = settings
    $test_data = { constellations: constellations_data }

    allow(Lich::Messaging).to receive(:msg) { |_type, text| messages << text }
    allow(DRC).to receive(:can_see_sky?).and_return(true)
    allow(DRC).to receive(:wait_for_script_to_complete)
    allow(DRC).to receive(:bput) do |command, *patterns|
      sent << command
      bput_result(game_reply(command), patterns)
    end
    allow(DRCMM).to receive(:get_telescope?).and_return(true)
    allow(DRCMM).to receive(:store_telescope?).and_return(true)
    allow(DRCMM).to receive(:observe).with('heavens') do
      sent << 'observe heavens'
      $history = sky + ['Roundtime: 3 sec.']
      'The following heavenly bodies are visible:'
    end
    allow(DRCMM).to receive(:peer_telescope) do
      sent << 'peer my telescope'
      peer_results.size > 1 ? peer_results.shift : (peer_results.first || learned)
    end
  end

  describe '#initialize' do
    it 'exits for a character who is not a Moon Mage' do
      DRStats.guild = 'Ranger'

      expect { described_class.new }.to raise_error(SystemExit)
      expect(messages).to include('MoonieFill: This script is only for Moon Mages. Exiting.')
    end

    it 'loads the bodies and observation messages from the constellations data' do
      mf = described_class.new

      expect($data_called_with).to include('constellations')
      expect(mf.instance_variable_get(:@constellations)).to eq(constellations)
      expect(mf.instance_variable_get(:@success_messages)).to eq(constellations_data.observe_success_messages)
    end

    it 'refreshes a circle that still reads 0, so circle filtering works' do
      DRStats.circle = 0

      described_class.new

      expect(sent).to include('info')
    end

    it 'does not send INFO when the circle is known' do
      described_class.new

      expect(sent).not_to include('info')
    end
  end

  describe '#run' do
    it 'stops before buffing or observing when the sky cannot be seen' do
      allow(DRC).to receive(:can_see_sky?).and_return(false)

      mooniefill.run

      expect(messages).to include('MoonieFill: You need to be somewhere you can see the sky. Exiting.')
      expect(DRC).not_to have_received(:wait_for_script_to_complete)
      expect(sent).to be_empty
      expect(DRCMM).not_to have_received(:get_telescope?)
    end

    it 'checks every pool and never takes the telescope out when all are full' do
      mooniefill.run

      expect(sent).to eq(MoonieFill::POOLS.map { |pool| "predict state #{pool.downcase}" })
      expect(messages).to include('MoonieFill: Survival is full!', 'MoonieFill: Offense is full!')
      expect(DRCMM).not_to have_received(:get_telescope?)
      expect(DRCMM).not_to have_received(:store_telescope?)
    end

    it 'calls fill_pool once per pool, never recursively' do
      pool_states['survival'] = %w[weak modest complete]
      allow(mooniefill).to receive(:fill_pool).and_call_original

      mooniefill.run

      expect(mooniefill).to have_received(:fill_pool).exactly(MoonieFill::POOLS.size).times
    end

    it 'takes the telescope out once and stores it once across every pool it observes for' do
      pool_states['survival'] = %w[weak complete]
      pool_states['magic'] = %w[fledgling complete]

      mooniefill.run

      expect(DRCMM).to have_received(:get_telescope?).once
      expect(DRCMM).to have_received(:store_telescope?).once.with('telescope', { 'container' => 'rucksack' })
      expect(centers).to eq(['center my telescope on Ram', 'center my telescope on Cobra'])
    end

    it 'still stores the telescope once when a pool stops the run' do
      pool_states['survival'] = %w[weak]
      center_replies['Ram'] = 'The pain is too much for you to focus.'

      mooniefill.run

      expect(DRCMM).to have_received(:store_telescope?).once
      expect(sent).not_to include('predict state magic')
    end

    it 'runs ;buff astrology at the start and after each successful observation' do
      pool_states['survival'] = %w[weak modest complete]

      mooniefill.run

      expect(DRC).to have_received(:wait_for_script_to_complete).with('buff', ['astrology']).exactly(3).times
    end

    it 'adds the pondered flag for the run and removes it at the end' do
      pool_states['survival'] = %w[weak complete]
      allow(Flags).to receive(:add).and_call_original
      allow(Flags).to receive(:delete).and_call_original

      mooniefill.run

      expect(Flags).to have_received(:add).with(MoonieFill::PONDERED_FLAG, MoonieFill::PONDERED_MESSAGE)
      expect(Flags).to have_received(:delete).with(MoonieFill::PONDERED_FLAG)
    end
  end

  describe '#fill_pool' do
    context 'when the pool is already full' do
      it 'returns without observing the sky or taking out the telescope' do
        expect(mooniefill.fill_pool('Survival')).to eq(:full)

        expect(sent).to eq(['predict state survival'])
        expect(DRCMM).not_to have_received(:get_telescope?)
      end
    end

    context 'when an observation fills the pool' do
      it 'stops observing as soon as PREDICT STATE reports complete understanding' do
        pool_states['survival'] = %w[weak complete]

        expect(mooniefill.fill_pool('Survival')).to eq(:full)

        expect(centers).to eq(['center my telescope on Ram'])
        expect(DRCMM).to have_received(:peer_telescope).once
        expect(messages).to include('MoonieFill: Survival is full!')
      end
    end

    context 'when an observation leaves the pool not full' do
      before { pool_states['survival'] = %w[weak modest decent complete] }

      it 'keeps observing the best body in a loop instead of restarting itself' do
        allow(mooniefill).to receive(:fill_pool).and_call_original

        expect(mooniefill.fill_pool('Survival')).to eq(:full)

        expect(mooniefill).to have_received(:fill_pool).once
        expect(centers).to eq(['center my telescope on Ram'] * 3)
        expect(sent.count('observe heavens')).to eq(1)
        expect(DRCMM).to have_received(:get_telescope?).once
      end

      it 'waits for the observation timer before the next observation' do
        mooniefill.fill_pool('Survival')

        expect(sent).to eq([
                             'predict state survival', 'observe heavens',
                             'center my telescope on Ram', 'peer my telescope', 'predict state survival',
                             :pause,
                             'center my telescope on Ram', 'peer my telescope', 'predict state survival',
                             :pause,
                             'center my telescope on Ram', 'peer my telescope', 'predict state survival'
                           ])
      end

      it 'reports the pool level after each observation' do
        mooniefill.fill_pool('Survival')

        expect(messages).to include('MoonieFill: Survival: modest understanding (4/10).',
                                    'MoonieFill: Survival: decent understanding (5/10).')
      end
    end

    context 'when the pool never reports full' do
      it 'gives up after MAX_OBSERVATIONS_PER_POOL observations' do
        pool_states['survival'] = %w[weak]

        expect(mooniefill.fill_pool('Survival')).to eq(:not_full)

        expect(DRCMM).to have_received(:peer_telescope).exactly(MoonieFill::MAX_OBSERVATIONS_PER_POOL).times
        expect(messages).to include("MoonieFill: Survival still isn't full after #{MoonieFill::MAX_OBSERVATIONS_PER_POOL} observations. Moving on.")
      end

      it 'treats an unreadable PREDICT STATE as not full and still ends' do
        pool_states['survival'] = ['garbled']

        expect(mooniefill.fill_pool('Survival')).to eq(:not_full)

        expect(messages).to include("MoonieFill: Survival: couldn't read PREDICT STATE.")
      end
    end

    context 'when a body is not in the sky' do
      it 'moves to the next body without peering when the search turns up fruitless' do
        pool_states['survival'] = %w[weak complete]
        center_replies['Ram'] = 'Your search for Ram turns up fruitless.'

        mooniefill.fill_pool('Survival')

        expect(centers).to eq(['center my telescope on Ram', 'center my telescope on Heart'])
        expect(DRCMM).to have_received(:peer_telescope).once
      end

      it 'moves to the next body when the search is foiled by the daylight' do
        pool_states['survival'] = %w[weak complete]
        center_replies['Ram'] = 'Your search for Ram is foiled by the daylight.'

        mooniefill.fill_pool('Survival')

        expect(centers).to eq(['center my telescope on Ram', 'center my telescope on Heart'])
      end

      it 'moves to the next body on a CENTER reply it does not recognise' do
        pool_states['survival'] = %w[weak complete]
        center_replies['Ram'] = 'Something new and unexpected.'

        mooniefill.fill_pool('Survival')

        expect(centers).to eq(['center my telescope on Ram', 'center my telescope on Heart'])
      end

      it 'reports when it runs out of bodies before the pool fills' do
        pool_states['survival'] = %w[weak]
        center_replies['Ram'] = 'Your search for Ram turns up fruitless.'
        center_replies['Heart'] = 'Your search for the Heart turns up fruitless.'

        expect(mooniefill.fill_pool('Survival')).to eq(:not_full)

        expect(DRCMM).not_to have_received(:peer_telescope)
        expect(messages).to include('MoonieFill: Ran out of bodies to observe before Survival filled. Try again later or at another time of day.')
      end
    end

    context 'when the game says the body has nothing more to add' do
      it 'moves to the next body if the pool still is not full' do
        pool_states['survival'] = %w[weak weak complete]
        peer_results.push(["You believe you've learned all that you can about survival.", 'Roundtime: 3 sec.'], learned)

        mooniefill.fill_pool('Survival')

        expect(centers).to eq(['center my telescope on Ram', 'center my telescope on Heart'])
      end

      it 'stops once PREDICT STATE agrees the pool is full' do
        pool_states['survival'] = %w[weak complete]
        peer_results.push(["You believe you've learned all that you can about survival.", 'Roundtime: 3 sec.'])

        expect(mooniefill.fill_pool('Survival')).to eq(:full)

        expect(centers).to eq(['center my telescope on Ram'])
      end

      it 'counts a two-pool body that reports one pool full but still teaches as a success' do
        pool_states['survival'] = %w[weak complete]
        peer_results.push(["You believe you've learned all that you can about magic.", 'You learned something useful from your observation.'])

        mooniefill.fill_pool('Survival')

        expect(DRC).to have_received(:wait_for_script_to_complete).with('buff', ['astrology'])
      end
    end

    context 'when too many futures cloud your mind' do
      let(:clouded) { ['Too many futures cloud your mind - you learn nothing.', 'Roundtime: 3 sec.'] }

      it 'gives up on the pool instead of trying every other body' do
        pool_states['survival'] = %w[weak]
        peer_results.push(clouded)

        expect(mooniefill.fill_pool('Survival')).to eq(:not_full)

        expect(centers).to eq(['center my telescope on Ram'])
        expect(messages).to include("MoonieFill: Too many futures cloud your mind, so Survival can't take more right now. Moving on.")
      end

      it 'does not restart the other pools' do
        pool_states['survival'] = %w[weak]
        peer_results.push(clouded)

        mooniefill.fill_pool('Survival')

        expect(sent.grep(/^predict state/).uniq).to eq(['predict state survival'])
      end

      it 'reports the pool full if PREDICT STATE says so' do
        pool_states['survival'] = %w[weak complete]
        peer_results.push(clouded)

        expect(mooniefill.fill_pool('Survival')).to eq(:full)
      end
    end

    context 'when the observation timer has not run out' do
      it 'waits for the pondered message, then observes the same body again' do
        pool_states['survival'] = %w[weak complete]
        peer_results.push(['You have not pondered your last observation sufficiently.', 'Roundtime: 1 sec.'], learned)

        expect(mooniefill.fill_pool('Survival')).to eq(:full)

        expect(sent).to eq([
                             'predict state survival', 'observe heavens',
                             'center my telescope on Ram', 'peer my telescope',
                             :pause,
                             'center my telescope on Ram', 'peer my telescope', 'predict state survival'
                           ])
      end

      it 'does not wait at all if the pondered message already arrived' do
        pool_states['survival'] = %w[weak modest complete]
        allow(DRC).to receive(:wait_for_script_to_complete) { Flags[MoonieFill::PONDERED_FLAG] = true }

        mooniefill.fill_pool('Survival')

        expect(sent).not_to include(:pause)
      end

      it 'stops waiting after PONDER_WAIT_SECONDS if the message never comes' do
        pool_states['survival'] = %w[weak modest complete]
        allow(mooniefill).to receive(:pause) { sent << :pause }

        mooniefill.fill_pool('Survival')

        expect(sent.count(:pause)).to eq(MoonieFill::PONDER_WAIT_SECONDS)
      end
    end

    context 'when the telescope needs attention' do
      it 'opens a closed telescope and centers again' do
        pool_states['survival'] = %w[weak complete]
        allow(DRC).to receive(:bput).with('center my telescope on Ram', any_args)
                                    .and_return('open it to make any use of it', 'You put your eye')

        mooniefill.fill_pool('Survival')

        expect(sent).to include('open my telescope')
        expect(DRCMM).to have_received(:peer_telescope).once
      end

      it 'opens the telescope when PEER says it is closed' do
        pool_states['survival'] = %w[weak complete]
        peer_results.push(["You'll need to open it to make any use of it."], learned)

        expect(mooniefill.fill_pool('Survival')).to eq(:full)

        expect(sent).to include('open my telescope')
        expect(centers).to eq(['center my telescope on Ram'] * 2)
      end

      it 'stops if the telescope will not open' do
        pool_states['survival'] = %w[weak]
        center_replies['Ram'] = "You'll need to open it to make any use of it."
        allow(DRC).to receive(:bput).with('open my telescope', any_args).and_return('')

        expect(mooniefill.fill_pool('Survival')).to eq(:stop)

        expect(messages).to include('MoonieFill: Could not open your telescope. Stopping.')
      end

      it 'fetches the telescope again when it is no longer in hand' do
        pool_states['survival'] = %w[weak complete]
        allow(DRC).to receive(:bput).with('center my telescope on Ram', any_args)
                                    .and_return('Center what', 'You put your eye')

        expect(mooniefill.fill_pool('Survival')).to eq(:full)

        expect(DRCMM).to have_received(:get_telescope?).twice
      end

      it 'gives up on a body after MAX_RETRIES_PER_BODY retries' do
        pool_states['survival'] = %w[weak complete]
        center_replies['Ram'] = "You'll need to open it to make any use of it."

        mooniefill.fill_pool('Survival')

        expect(centers.count('center my telescope on Ram')).to eq(MoonieFill::MAX_RETRIES_PER_BODY + 1)
        expect(centers.last).to eq('center my telescope on Heart')
      end

      it 'stops when the telescope cannot be fetched' do
        pool_states['survival'] = %w[weak]
        allow(DRCMM).to receive(:get_telescope?).and_return(false)

        expect(mooniefill.fill_pool('Survival')).to eq(:stop)

        expect(centers).to be_empty
        expect(messages).to include('MoonieFill: Could not get telescope. Exiting.')
      end
    end

    context 'when observing cannot go on' do
      before { pool_states['survival'] = %w[weak] }

      it 'stops at once when the sky cannot be seen' do
        center_replies['Ram'] = "That's a bit tough to do when you can't see the sky."

        expect(mooniefill.fill_pool('Survival')).to eq(:stop)

        expect(centers).to eq(['center my telescope on Ram'])
        expect(messages).to include("MoonieFill: You can't see the sky from here. Stopping.")
      end

      it 'stops at once when a periscope would be needed' do
        center_replies['Ram'] = 'You would probably need a periscope to do that.'

        expect(mooniefill.fill_pool('Survival')).to eq(:stop)
      end

      it 'stops when CENTER says your eyes are injured' do
        center_replies['Ram'] = 'Your vision is too fuzzy to make out anything.'

        expect(mooniefill.fill_pool('Survival')).to eq(:stop)

        expect(messages).to include('MoonieFill: Your eyes are too hurt to observe. Get healed, then run it again.')
      end

      it 'stops when PEER says your eyes are injured' do
        peer_results.push(['The pain is too much for you to bear.'])

        expect(mooniefill.fill_pool('Survival')).to eq(:stop)

        expect(centers).to eq(['center my telescope on Ram'])
      end

      it 'stops when the game wants both hands free' do
        center_replies['Ram'] = 'You must have both hands free to do that.'

        expect(mooniefill.fill_pool('Survival')).to eq(:stop)

        expect(messages).to include('MoonieFill: The game wants both hands free to center the telescope. Stopping.')
      end

      it 'stops when OBSERVE HEAVENS says you are inside' do
        allow(DRCMM).to receive(:observe).with('heavens').and_return("That's a bit hard to do while inside")

        expect(mooniefill.fill_pool('Survival')).to eq(:stop)

        expect(DRCMM).not_to have_received(:get_telescope?)
      end
    end

    context 'when nothing in the sky feeds the pool' do
      it 'moves on without taking out the telescope' do
        pool_states['offense'] = %w[weak]
        DRStats.circle = 5

        expect(mooniefill.fill_pool('Offense')).to eq(:not_full)

        expect(DRCMM).not_to have_received(:get_telescope?)
        expect(messages).to include('MoonieFill: Nothing in the sky within your circle feeds Offense right now. Try again later.')
      end
    end
  end

  describe '#candidate_bodies' do
    def names(pool)
      mooniefill.candidate_bodies(pool).map { |body| body['name'] }
    end

    it 'keeps visible bodies that feed the pool, the biggest contribution first' do
      expect(names('Survival')).to eq(%w[Ram Heart])
    end

    it 'breaks ties by circle, highest first' do
      expect(names('Magic')).to eq(%w[Cobra Wolf Yavash])
    end

    it 'leaves out bodies above your circle' do
      expect(names('Magic')).not_to include('Toad')
    end

    it 'leaves out bodies below the horizon' do
      sky.push('Elanthian Sun is below the horizon.')

      expect(names('Survival')).not_to include('Elanthian Sun')
    end

    it 'adds telescope-only constellations at night' do
      expect(names('Lore')).to eq(['King Snake', 'Cobra'])
      expect(names('Offense')).to eq(['Scorpion'])
    end

    it 'leaves out telescope-only constellations by day' do
      sky.replace(['The Elanthian Sun is high in the sky.', 'Yavash is rising in the east.'])

      expect(names('Offense')).to be_empty
      expect(names('Survival')).to eq(['Elanthian Sun'])
    end

    it 'adds telescope-only planets within your circle by day or night' do
      DRStats.circle = 70
      sky.replace(['The Elanthian Sun is high in the sky.'])

      expect(names('Defense')).to eq(['Merewalda'])
    end

    it 'returns nil indoors' do
      allow(DRCMM).to receive(:observe).with('heavens').and_return("That's a bit hard to do while inside")

      expect(mooniefill.candidate_bodies('Survival')).to be_nil
      expect(messages).to include('MoonieFill: You need to be outdoors to observe the sky. Exiting.')
    end

    context 'with the real data/base-constellations.yaml' do
      let(:constellations_data) do
        OpenStruct.new(YAML.load_file(File.expand_path('../data/base-constellations.yaml', __dir__)))
      end

      it 'matches the pool names the data file uses' do
        DRStats.circle = 150

        MoonieFill::POOLS.each do |pool|
          bodies = mooniefill.candidate_bodies(pool)
          expect(bodies).not_to be_empty, "no #{pool} bodies"
          expect(bodies.map { |body| body['pools'][pool] }).to all(be_a(Integer))
        end
      end

      it 'recognises the success and injured messages listed there' do
        expect(mooniefill.peer_outcome('You learned something useful from your observation of Wolf.')).to eq(:success)
        expect(mooniefill.peer_outcome('Although you were nearly overwhelmed, you still learned more of the future.')).to eq(:success)
        expect(mooniefill.peer_outcome('The pain is too much for you to bear.')).to eq(:injured)
      end
    end
  end

  describe '#peer_outcome' do
    {
      'You learned something useful from your observation.'          => :success,
      "While the sighting wasn't quite what you hoped, you learned." => :success,
      'You have not pondered your last observation sufficiently.'    => :cooldown,
      'You are unable to make use of this latest observation.'       => :cooldown,
      'Too many futures cloud your mind - you learn nothing.'        => :saturated,
      "You believe you've learned all that you can about lore."      => :pool_full,
      "You'll need to open it to make any use of it."                => :closed,
      'Your vision is too fuzzy.'                                    => :injured,
      'You peer aimlessly through your telescope.'                   => :skip,
      'Clouds obscure the sky where Ram should appear.'              => :skip,
      ''                                                             => :skip
    }.each do |text, outcome|
      it "reads #{text.empty? ? 'no output' : text.inspect} as #{outcome}" do
        expect(mooniefill.peer_outcome(text)).to eq(outcome)
      end
    end
  end

  describe 'before_dying teardown' do
    it 'stows the telescope and removes the pondered flag' do
      captured_block = nil
      main_obj = TOPLEVEL_BINDING.eval('self')
      allow(main_obj).to receive(:before_dying) { |&block| captured_block = block }
      allow(MoonieFill).to receive(:new).and_return(instance_double(MoonieFill, run: nil))

      # Evaluate only the teardown and entry point, not the class body again.
      path = lic_path('mooniefill.lic')
      lines = File.readlines(path)
      start = lines.index { |line| line.start_with?('before_dying do') }
      eval(lines[start..].join, TOPLEVEL_BINDING, path, start + 1)

      Flags.add(MoonieFill::PONDERED_FLAG, MoonieFill::PONDERED_MESSAGE)
      captured_block.call

      expect(DRCMM).to have_received(:store_telescope?).with('telescope', { 'container' => 'rucksack' })
      expect(Flags.flags).not_to have_key(MoonieFill::PONDERED_FLAG)
    end
  end
end
