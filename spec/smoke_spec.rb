require_relative 'spec_helper'

# Smoker#initialize depends on the full Lich runtime (parse_args, get_settings,
# EquipmentManager, live smoking I/O), so we extract the class with
# load_lic_class and exercise the pure, side-effect-free seams on bare-allocated
# instances (Smoker.allocate). Every example is self-contained (DAMP).
#
# The emphasis is adversarial: the tier-priority planner (prioritize) is the
# brain of the script, so its selection, filtering, mastered/unknown handling,
# and tier ordering are stress-tested; plus the smoke-list parser, the tier
# predicates, settings validation (which aborts), and the queue reshuffle.
load_lic_class('smoke.lic', 'Smoker')

# UserVars is per-script config -- provide the constant (only if no other spec
# defined it) so build_priority_queue's reads/writes can be stubbed per example.
class UserVars
  class << self
    def smoke_images_known; @smoke_images_known; end
    def smoke_images_known=(value); @smoke_images_known = value; end
    def smoke_images_mastered; @smoke_images_mastered; end
    def smoke_images_mastered=(value); @smoke_images_mastered = value; end
  end
end unless defined?(UserVars)

RSpec.describe Smoker do
  subject(:smoker) { described_class.allocate }

  # ===========================================================================
  # blank? -- the nil/whitespace predicate the settings logic leans on
  # ===========================================================================
  describe '#blank?' do
    it 'treats nil and empty/whitespace strings as blank' do
      expect(smoker.blank?(nil)).to be(true)
      expect(smoker.blank?('')).to be(true)
      expect(smoker.blank?('   ')).to be(true)
    end

    it 'treats a real string and a non-string as present' do
      expect(smoker.blank?('glitvire pipe')).to be(false)
      expect(smoker.blank?(42)).to be(false)
    end
  end

  # ===========================================================================
  # Tier predicates -- tier_rank / known_tier? / mastered?
  # ===========================================================================
  describe '#tier_rank' do
    it 'ranks known tiers by skill, lowest first' do
      expect(smoker.tier_rank('learning')).to eq(0)
      expect(smoker.tier_rank('master')).to eq(5)
      expect(smoker.tier_rank('master*')).to eq(6)
    end

    it 'ranks Olvi intermediate tier names the same as the common names' do
      expect(smoker.tier_rank('wheezer')).to eq(smoker.tier_rank('beginner'))
      expect(smoker.tier_rank('streamer')).to eq(smoker.tier_rank('competent'))
    end

    it 'is case-insensitive' do
      expect(smoker.tier_rank('MASTER*')).to eq(6)
    end

    it 'ranks an unknown tier (and nil) last' do
      expect(smoker.tier_rank('bogus')).to eq(Smoker::UNKNOWN_RANK)
      expect(smoker.tier_rank(nil)).to eq(Smoker::UNKNOWN_RANK)
    end
  end

  describe '#known_tier?' do
    it 'recognizes configured tiers and rejects unknown/nil' do
      expect(smoker.known_tier?('adequate')).to be(true)
      expect(smoker.known_tier?('bogus')).to be(false)
      expect(smoker.known_tier?(nil)).to be(false)
    end
  end

  describe '#mastered?' do
    it 'is true only for master* (not master), case-insensitively' do
      expect(smoker.mastered?('master*')).to be(true)
      expect(smoker.mastered?('MASTER*')).to be(true)
      expect(smoker.mastered?('master')).to be(false)
      expect(smoker.mastered?(nil)).to be(false)
    end
  end

  # ===========================================================================
  # parse_smoke_list -- pure parsing of "smoke list" output lines
  # ===========================================================================
  describe '#parse_smoke_list' do
    it 'parses multiple image/tier pairs from a single line' do
      line = 'deer      - learning        tart      - master*'
      expect(smoker.parse_smoke_list([line])).to eq([%w[deer learning], %w[tart master*]])
    end

    it 'captures the master* asterisk in the tier' do
      expect(smoker.parse_smoke_list(['wolf      - master*'])).to eq([%w[wolf master*]])
    end

    it 'skips the IMAGE - SKILL header line' do
      expect(smoker.parse_smoke_list(['IMAGE - SKILL', 'deer - learning'])).to eq([%w[deer learning]])
    end

    it 'flattens pairs across multiple lines' do
      lines = ['deer - learning', 'tart - master']
      expect(smoker.parse_smoke_list(lines)).to eq([%w[deer learning], %w[tart master]])
    end

    it 'is safe against nil and unmatched lines' do
      expect(smoker.parse_smoke_list([nil, 'no pairs here'])).to eq([])
    end
  end

  # ===========================================================================
  # prioritize -- the pure training planner (the brain). No I/O, no shuffle.
  # ===========================================================================
  describe '#prioritize' do
    it 'selects only the lowest surviving tier and reports the breakdown' do
      entries = [%w[deer learning], %w[wolf streamer], %w[tart master*]]
      plan = smoker.prioritize(entries, %w[deer wolf tart], clean_mastered: true)

      expect(plan[:lowest_tier]).to eq('learning')
      expect(plan[:lowest_images]).to eq(['deer'])
      expect(plan[:mastered]).to eq(['tart'])
      expect(plan[:pool]).to eq(%w[deer wolf])
      expect(plan[:summary]).to eq('learning(1) > streamer(1)')
    end

    it 'keeps mastered images when clean_mastered is false (explicit image runs)' do
      entries = [%w[tart master*], %w[deer learning]]
      plan = smoker.prioritize(entries, %w[tart deer], clean_mastered: false)

      expect(plan[:mastered]).to eq([])
      expect(plan[:pool]).to eq(%w[tart deer])
      expect(plan[:lowest_images]).to eq(['deer'])
    end

    it 'trains a master (not master*) image -- mastery is exact' do
      entries = [%w[deer master], %w[tart master*]]
      plan = smoker.prioritize(entries, %w[deer tart], clean_mastered: true)

      expect(plan[:mastered]).to eq(['tart'])
      expect(plan[:pool]).to eq(['deer'])
      expect(plan[:lowest_images]).to eq(['deer'])
      expect(plan[:lowest_tier]).to eq('master')
    end

    it 'reports pool images absent from the smoke list as unknown and drops them' do
      entries = [%w[deer learning]]
      plan = smoker.prioritize(entries, %w[deer xyzzy], clean_mastered: true)

      expect(plan[:unknown]).to eq(['xyzzy'])
      expect(plan[:pool]).to eq(['deer'])
      expect(plan[:known]).to eq(['deer'])
    end

    it 'flags unrecognized tiers and still ranks them last' do
      entries = [%w[deer wobble], %w[wolf learning]]
      plan = smoker.prioritize(entries, %w[deer wolf], clean_mastered: true)

      expect(plan[:unknown_tiers]).to eq(['wobble'])
      expect(plan[:lowest_tier]).to eq('learning') # rank 0 beats the unknown rank 99
      expect(plan[:lowest_images]).to eq(['wolf'])
    end

    it 'groups every image sharing the lowest tier, in list order (deterministic)' do
      entries = [%w[deer learning], %w[rabbit learning], %w[wolf master]]
      plan = smoker.prioritize(entries, %w[deer rabbit wolf], clean_mastered: true)

      expect(plan[:lowest_images]).to eq(%w[deer rabbit])
    end

    it 'returns an empty plan when the whole pool is mastered' do
      entries = [%w[deer master*], %w[tart master*]]
      plan = smoker.prioritize(entries, %w[deer tart], clean_mastered: true)

      expect(plan[:pool]).to eq([])
      expect(plan[:lowest_images]).to eq([])
      expect(plan[:lowest_tier]).to be_nil
      expect(plan[:summary]).to eq('')
    end

    it 'handles an empty pool and empty entries without error' do
      expect(smoker.prioritize([], [], clean_mastered: true)[:lowest_images]).to eq([])
      plan = smoker.prioritize([%w[deer learning]], [], clean_mastered: false)
      expect(plan[:pool]).to eq([])
      expect(plan[:known]).to eq(['deer'])
    end

    it 'ranks by tier regardless of list order (streamer trains before master)' do
      entries = [%w[tart master], %w[deer streamer]]
      plan = smoker.prioritize(entries, %w[tart deer], clean_mastered: true)

      expect(plan[:lowest_tier]).to eq('streamer')
      expect(plan[:lowest_images]).to eq(['deer'])
    end
  end

  # ===========================================================================
  # find_blade -- EquipmentManager resolution (with Regexp.escape safety)
  # ===========================================================================
  describe '#find_blade' do
    let(:blade) { double('blade', short_regex: /paraz/, name: 'serrated parazonium') }

    before { smoker.instance_variable_set(:@equipmanager, double('eq', items: [blade])) }

    it 'returns nil for a blank setting without touching equipment' do
      expect(smoker.find_blade(nil)).to be_nil
      expect(smoker.find_blade('  ')).to be_nil
    end

    it 'matches an item by short_regex' do
      expect(smoker.find_blade('serrated parazonium')).to eq(blade)
    end

    it 'matches an item by name when the short_regex does not match' do
      dagger = double('dagger', short_regex: /nomatch/, name: 'fine steel dagger')
      smoker.instance_variable_set(:@equipmanager, double('eq', items: [dagger]))
      expect(smoker.find_blade('dagger')).to eq(dagger)
    end

    it 'does not match a name substring across a word boundary' do
      dagger = double('dagger', short_regex: /nomatch/, name: 'fine steel dagger')
      smoker.instance_variable_set(:@equipmanager, double('eq', items: [dagger]))
      expect(smoker.find_blade('dagg')).to be_nil
    end

    it 'returns nil when nothing matches' do
      expect(smoker.find_blade('nonexistent halberd')).to be_nil
    end

    it 'does not raise when the setting contains regex-special characters' do
      expect { smoker.find_blade('blade (fancy) [+2]') }.not_to raise_error
    end
  end

  # ===========================================================================
  # validate_settings -- aborts (exit) on missing/invalid config
  # ===========================================================================
  describe '#validate_settings' do
    def args(**opts)
      OpenStruct.new(opts)
    end

    before do
      smoker.instance_variable_set(:@bag, 'smoking jacket')
      smoker.instance_variable_set(:@pipe, 'glitvire pipe')
      smoker.instance_variable_set(:@lighter, 'lava drake')
      smoker.instance_variable_set(:@blade, nil)
      smoker.instance_variable_set(:@smoke_settings, {})
      allow(DRStats).to receive(:warrior_mage?).and_return(false)
    end

    it 'returns early for reset_known even when nothing is configured' do
      smoker.instance_variable_set(:@bag, nil)
      expect { smoker.validate_settings(args(reset_known: true)) }.not_to raise_error
    end

    it 'aborts when the container is not set' do
      smoker.instance_variable_set(:@bag, nil)
      expect { smoker.validate_settings(args) }.to raise_error(SystemExit)
    end

    it 'aborts a pipe run when the pipe is not set' do
      smoker.instance_variable_set(:@pipe, nil)
      expect { smoker.validate_settings(args) }.to raise_error(SystemExit)
    end

    it 'does not require a pipe for an explicit cigar run' do
      smoker.instance_variable_set(:@pipe, nil)
      expect { smoker.validate_settings(args(cigar: 'fine cigar')) }.not_to raise_error
    end

    it 'does not require a pipe when the cigar is given via the smoke arg' do
      smoker.instance_variable_set(:@pipe, nil)
      expect { smoker.validate_settings(args(smoke: 'fine cigar')) }.not_to raise_error
    end

    it 'passes for a warrior mage with no lighter or blade' do
      smoker.instance_variable_set(:@lighter, nil)
      allow(DRStats).to receive(:warrior_mage?).and_return(true)
      expect { smoker.validate_settings(args) }.not_to raise_error
    end

    it 'passes with a configured lighter' do
      expect { smoker.validate_settings(args) }.not_to raise_error
    end

    it 'warns but passes when falling back to a found blade' do
      smoker.instance_variable_set(:@lighter, nil)
      smoker.instance_variable_set(:@smoke_settings, { 'blade' => 'serrated parazonium' })
      smoker.instance_variable_set(:@blade, double('blade'))
      expect { smoker.validate_settings(args) }.not_to raise_error
    end

    it 'aborts when a blade is configured but not found in EquipmentManager' do
      smoker.instance_variable_set(:@lighter, nil)
      smoker.instance_variable_set(:@smoke_settings, { 'blade' => 'ghost blade' })
      smoker.instance_variable_set(:@blade, nil)
      expect { smoker.validate_settings(args) }.to raise_error(SystemExit)
    end

    it 'aborts when there is no lighter and no blade (non-warrior-mage)' do
      smoker.instance_variable_set(:@lighter, nil)
      smoker.instance_variable_set(:@smoke_settings, {})
      expect { smoker.validate_settings(args) }.to raise_error(SystemExit)
    end
  end

  # ===========================================================================
  # next_image -- queue consumption with lowest-tier reshuffle
  # ===========================================================================
  describe '#next_image' do
    it 'shifts the next image off a non-empty queue' do
      smoker.instance_variable_set(:@image_queue, %w[deer tart])
      smoker.instance_variable_set(:@lowest_tier_pool, %w[deer tart])
      expect(smoker.next_image).to eq('deer')
      expect(smoker.instance_variable_get(:@image_queue)).to eq(['tart'])
    end

    it 'reshuffles the lowest tier when the queue is empty' do
      smoker.instance_variable_set(:@image_queue, [])
      smoker.instance_variable_set(:@lowest_tier_pool, %w[x y])
      expect(%w[x y]).to include(smoker.next_image)
      expect(smoker.instance_variable_get(:@image_queue).size).to eq(1)
    end

    it 'reshuffles when the queue is nil' do
      smoker.instance_variable_set(:@image_queue, nil)
      smoker.instance_variable_set(:@lowest_tier_pool, ['z'])
      expect(smoker.next_image).to eq('z')
    end

    it 'returns nil when there is nothing left to reshuffle' do
      smoker.instance_variable_set(:@image_queue, [])
      smoker.instance_variable_set(:@lowest_tier_pool, nil)
      expect(smoker.next_image).to be_nil
    end
  end

  # ===========================================================================
  # exhale_smoke -- outcome branches, including the observe-teacher abort
  # ===========================================================================
  describe '#exhale_smoke' do
    it 'exhales a ring when untrained in the image' do
      allow(DRC).to receive(:bput).and_return('You are untrained in the ways of making that image.')
      expect(smoker).to receive(:fput).with('exhale ring')
      smoker.exhale_smoke('deer')
    end

    it 'reports when the image is just learned' do
      allow(DRC).to receive(:bput).and_return('You now know the basics of making')
      expect(DRC).to receive(:message).with(/Image learned/)
      smoker.exhale_smoke('deer')
    end

    it 'registers the observe-teacher line as a bput match (so the branch is reachable)' do
      captured = nil
      allow(DRC).to receive(:bput) { |_cmd, *patterns| captured = patterns; 'Roundtime' }
      smoker.exhale_smoke('deer')
      expect(captured.any? { |p| p.is_a?(Regexp) && p =~ 'You need to observe your teacher performing to do that' }).to be(true)
    end

    it 'aborts when told to observe the teacher first' do
      allow(DRC).to receive(:bput).and_return('You need to observe your teacher performing')
      expect { smoker.exhale_smoke('deer') }.to raise_error(SystemExit)
    end

    it 'does nothing extra on a normal roundtime exhale' do
      allow(DRC).to receive(:bput).and_return('Roundtime: 3 sec.')
      expect(smoker).not_to receive(:fput)
      expect { smoker.exhale_smoke('deer') }.not_to raise_error
    end
  end

  # ===========================================================================
  # offer_lesson -- teaching handshake branches, including the unresponsive exit
  # ===========================================================================
  describe '#offer_lesson' do
    it 'is true when the student starts paying attention' do
      allow(DRC).to receive(:bput).and_return('Bob starts paying attention to your advice on how to make')
      expect(smoker.offer_lesson('deer', 'Bob')).to be(true)
    end

    it 'is true when the student nods' do
      allow(DRC).to receive(:bput).and_return('Bob nods to you')
      expect(smoker.offer_lesson('deer', 'Bob')).to be(true)
    end

    it 'is false when the student already knows the image' do
      allow(DRC).to receive(:bput).and_return('already knows how to make that smoke image')
      expect(smoker.offer_lesson('deer', 'Bob')).to be(false)
    end

    it 'aborts when the student is unresponsive (no match)' do
      allow(DRC).to receive(:bput).and_return('')
      expect { smoker.offer_lesson('deer', 'Bob') }.to raise_error(SystemExit)
    end
  end

  # ===========================================================================
  # quick_light_safe -- the true/false returns that drive the until_out break
  # ===========================================================================
  describe '#quick_light_safe' do
    before do
      smoker.instance_variable_set(:@pipe, 'glitvire pipe')
      smoker.instance_variable_set(:@bag, 'smoking jacket')
      allow(smoker).to receive(:light_tobacco) # isolate: don't run real lighting I/O
    end

    it 'returns false when the pipe cannot be retrieved' do
      allow(DRCI).to receive(:get_item_if_not_held?).and_return(false)
      expect(smoker.quick_light_safe('pipe')).to be(false)
    end

    it 'returns true when the pipe is already burning' do
      allow(DRCI).to receive(:get_item_if_not_held?).and_return(true)
      allow(DRC).to receive(:bput).and_return('In the pipe you see a burning wad of tobacco')
      expect(smoker.quick_light_safe('pipe')).to be(true)
    end

    it 'loads tobacco and returns true when the pipe is empty but tobacco remains' do
      allow(DRCI).to receive(:get_item_if_not_held?).and_return(true)
      allow(DRC).to receive(:bput).and_return('There is nothing in there')
      allow(DRCI).to receive(:get_item?).with('tobacco', 'smoking jacket').and_return(true)
      allow(DRCI).to receive(:put_away_item?).and_return(true)
      expect(smoker.quick_light_safe('pipe')).to be(true)
    end

    it 'returns false when the pipe is empty and no tobacco remains' do
      allow(DRCI).to receive(:get_item_if_not_held?).and_return(true)
      allow(DRC).to receive(:bput).and_return('There is nothing in there')
      allow(DRCI).to receive(:get_item?).with('tobacco', 'smoking jacket').and_return(false)
      expect(smoker.quick_light_safe('pipe')).to be(false)
    end

    it 'returns false when out of cigars' do
      allow(DRCI).to receive(:get_item_if_not_held?).and_return(false)
      expect(smoker.quick_light_safe('fine cigar')).to be(false)
    end

    it 'returns true when a cigar is retrieved' do
      allow(DRCI).to receive(:get_item_if_not_held?).and_return(true)
      expect(smoker.quick_light_safe('fine cigar')).to be(true)
    end
  end

  # ===========================================================================
  # build_priority_queue -- the I/O wrapper's UserVars writes + empty return
  # ===========================================================================
  describe '#build_priority_queue' do
    before do
      smoker.instance_variable_set(:@clean_mastered, true)
      allow(UserVars).to receive(:smoke_images_known=)
      allow(UserVars).to receive(:smoke_images_mastered).and_return([])
      allow(UserVars).to receive(:smoke_images_mastered=)
    end

    it 'returns the lowest trainable tier and records known images' do
      smoker.instance_variable_set(:@image_pool, %w[deer tart])
      allow(smoker).to receive(:read_smoke_list).and_return([%w[deer learning], %w[tart master*]])

      expect(UserVars).to receive(:smoke_images_known=).with(%w[deer tart])
      expect(smoker.build_priority_queue).to eq(['deer'])
      expect(smoker.instance_variable_get(:@lowest_tier_pool)).to eq(['deer'])
    end

    it 'returns an empty queue when everything is mastered' do
      smoker.instance_variable_set(:@image_pool, %w[deer tart])
      allow(smoker).to receive(:read_smoke_list).and_return([%w[deer master*], %w[tart master*]])

      expect(smoker.build_priority_queue).to eq([])
    end
  end

  # ===========================================================================
  # Smoke-list I/O helpers -- collect_smoke_list_lines / read_smoke_list
  # ===========================================================================
  describe '#collect_smoke_list_lines' do
    before { allow(smoker).to receive(:fput) }

    it 'collects lines up to the "Total images known" terminator' do
      allow(smoker).to receive(:get).and_return('deer - learning', 'tart - master*', 'Total images known: 2')
      expect(smoker.collect_smoke_list_lines).to eq(['deer - learning', 'tart - master*'])
    end

    it 'stops on a nil line (stream end) rather than looping forever' do
      allow(smoker).to receive(:get).and_return('deer - learning', nil)
      expect(smoker.collect_smoke_list_lines).to eq(['deer - learning'])
    end

    it 'stops immediately when no smoke images are known' do
      allow(smoker).to receive(:get).and_return("You don't know any smoke images")
      expect(smoker.collect_smoke_list_lines).to eq([])
    end
  end

  describe '#read_smoke_list' do
    it 'parses the collected lines into image/tier pairs' do
      allow(smoker).to receive(:collect_smoke_list_lines).and_return(['deer - learning', 'tart - master*'])
      expect(smoker.read_smoke_list).to eq([%w[deer learning], %w[tart master*]])
    end
  end

  # ===========================================================================
  # Lighting dispatch -- light_tobacco routes to the right method
  # ===========================================================================
  describe '#light_tobacco' do
    it 'uses the warrior mage cantrip when applicable' do
      allow(DRStats).to receive(:warrior_mage?).and_return(true)
      expect(smoker).to receive(:light_warrior_mage).with('tobacco in pipe')
      smoker.light_tobacco('tobacco in pipe')
    end

    it 'uses the configured lighter for non-warrior-mages' do
      allow(DRStats).to receive(:warrior_mage?).and_return(false)
      smoker.instance_variable_set(:@lighter, 'lava drake')
      expect(smoker).to receive(:light_with_lighter).with('fine cigar')
      smoker.light_tobacco('fine cigar')
    end

    it 'falls back to flint when there is no lighter and no cantrip' do
      allow(DRStats).to receive(:warrior_mage?).and_return(false)
      smoker.instance_variable_set(:@lighter, nil)
      expect(smoker).to receive(:light_with_flint).with('fine cigar')
      smoker.light_tobacco('fine cigar')
    end
  end

  describe '#light_warrior_mage' do
    it 'preps the cantrip then gestures at the target' do
      expect(DRC).to receive(:bput).with('prep c b t', anything).ordered
      expect(DRC).to receive(:bput).with('gesture tobacco in pipe', anything, anything).ordered
      smoker.light_warrior_mage('tobacco in pipe')
    end
  end

  # ===========================================================================
  # light_with_lighter -- success paths AND the flint fallbacks
  # ===========================================================================
  describe '#light_with_lighter' do
    before do
      smoker.instance_variable_set(:@lighter, 'lava drake')
      smoker.instance_variable_set(:@bag, 'smoking jacket')
      allow(DRStats).to receive(:warrior_mage?).and_return(false)
      allow(DRC).to receive(:bput) # the "point" command
    end

    it 'points an untied lighter and stows it on success' do
      smoker.instance_variable_set(:@smoke_settings, {})
      allow(DRCI).to receive(:get_item?).with('lava drake').and_return(true)
      expect(smoker).not_to receive(:light_with_flint)
      expect(DRCI).to receive(:put_away_item?).with('lava drake', 'smoking jacket')
      smoker.light_with_lighter('fine cigar')
    end

    it 'reties a tied lighter and does not stow it' do
      smoker.instance_variable_set(:@smoke_settings, { 'lighter_tied_to' => 'belt' })
      allow(DRCI).to receive(:untie_item?).and_return(true)
      allow(DRCI).to receive(:tie_item?).and_return(true)
      expect(DRCI).not_to receive(:put_away_item?)
      smoker.light_with_lighter('fine cigar')
    end

    it 'stows the lighter when re-tying fails' do
      smoker.instance_variable_set(:@smoke_settings, { 'lighter_tied_to' => 'belt' })
      allow(DRCI).to receive(:untie_item?).and_return(true)
      allow(DRCI).to receive(:tie_item?).and_return(false)
      expect(DRCI).to receive(:put_away_item?).with('lava drake', 'smoking jacket')
      smoker.light_with_lighter('fine cigar')
    end

    it 'falls back to flint (and disables the lighter) when it cannot be retrieved' do
      smoker.instance_variable_set(:@smoke_settings, {})
      allow(DRCI).to receive(:get_item?).with('lava drake').and_return(false)
      expect(smoker).to receive(:light_with_flint).with('fine cigar')
      smoker.light_with_lighter('fine cigar')
      expect(smoker.instance_variable_get(:@lighter)).to be(false)
    end

    it 'falls back to flint when a tied lighter cannot be untied' do
      smoker.instance_variable_set(:@smoke_settings, { 'lighter_tied_to' => 'belt' })
      allow(DRCI).to receive(:untie_item?).and_return(false)
      expect(smoker).to receive(:light_with_flint).with('fine cigar')
      smoker.light_with_lighter('fine cigar')
    end
  end

  describe '#light_with_flint' do
    before do
      smoker.instance_variable_set(:@bag, 'smoking jacket')
      smoker.instance_variable_set(:@blade, double('blade'))
      smoker.instance_variable_set(:@equipmanager, double('eq', get_item?: true, return_held_gear: nil))
      allow(DRC).to receive(:bput)
      allow(DRCI).to receive(:lower_item?)
      allow(DRCI).to receive(:stow_item?)
      allow(DRCI).to receive(:lift?)
    end

    it 'aborts when flint cannot be obtained' do
      allow(DRCI).to receive(:get_item?).with('flint').and_return(false)
      allow(DRC).to receive(:right_hand).and_return('right thing')
      allow(DRCI).to receive(:put_away_item?)
      expect { smoker.light_with_flint('fine cigar') }.to raise_error(SystemExit)
    end

    it 'strikes flint against the blade and cleans up on success' do
      allow(DRCI).to receive(:get_item?).with('flint').and_return(true)
      expect(DRCI).to receive(:stow_item?).with('flint')
      expect { smoker.light_with_flint('tobacco in pipe') }.not_to raise_error
    end
  end

  # ===========================================================================
  # load_pipe / quick_light -- retrieval, tobacco, and abort paths
  # ===========================================================================
  describe '#load_pipe' do
    before do
      smoker.instance_variable_set(:@pipe, 'glitvire pipe')
      smoker.instance_variable_set(:@bag, 'smoking jacket')
      allow(smoker).to receive(:light_tobacco)
      allow(DRCI).to receive(:put_away_item?)
    end

    it 'aborts when the pipe cannot be retrieved' do
      allow(DRCI).to receive(:get_item_if_not_held?).and_return(false)
      expect { smoker.load_pipe }.to raise_error(SystemExit)
    end

    it 'returns true when the pipe is already burning' do
      allow(DRCI).to receive(:get_item_if_not_held?).and_return(true)
      allow(DRC).to receive(:bput).and_return('In the pipe you see a burning wad of tobacco')
      expect(smoker.load_pipe).to be(true)
    end

    it 'aborts when empty and no tobacco remains' do
      allow(DRCI).to receive(:get_item_if_not_held?).and_return(true)
      allow(DRC).to receive(:bput).and_return('There is nothing in there')
      allow(DRCI).to receive(:get_item?).with('tobacco', 'smoking jacket').and_return(false)
      expect { smoker.load_pipe }.to raise_error(SystemExit)
    end

    it 'loads tobacco and lights when empty but tobacco remains' do
      allow(DRCI).to receive(:get_item_if_not_held?).and_return(true)
      allow(DRC).to receive(:bput).and_return('There is nothing in there')
      allow(DRCI).to receive(:get_item?).with('tobacco', 'smoking jacket').and_return(true)
      expect(smoker).to receive(:light_tobacco).with('tobacco in pipe')
      smoker.load_pipe
    end
  end

  describe '#quick_light' do
    before { smoker.instance_variable_set(:@bag, 'smoking jacket') }

    it 'loads the pipe for a pipe smoker' do
      smoker.instance_variable_set(:@pipe, 'glitvire pipe')
      expect(smoker).to receive(:load_pipe)
      smoker.quick_light('pipe')
    end

    it 'aborts when a cigar cannot be retrieved' do
      allow(DRCI).to receive(:get_item_if_not_held?).and_return(false)
      expect { smoker.quick_light('fine cigar') }.to raise_error(SystemExit)
    end

    it 'lights a retrieved cigar' do
      allow(DRCI).to receive(:get_item_if_not_held?).and_return(true)
      expect(smoker).to receive(:light_tobacco).with('fine cigar')
      smoker.quick_light('fine cigar')
    end
  end

  # ===========================================================================
  # inhale -- clears the lungs (recursing) then inhales cleanly
  # ===========================================================================
  describe '#inhale' do
    before { smoker.instance_variable_set(:@smoker, 'glitvire pipe') }

    it 'exhales and re-inhales when the lungs must be cleared first' do
      allow(DRC).to receive(:bput).and_return('out of your lungs first', 'You take')
      expect(smoker).to receive(:exhale_smoke).with('deer')
      smoker.inhale('deer')
    end

    it 'does nothing extra on a clean inhale' do
      allow(DRC).to receive(:bput).and_return('You take a long draw')
      expect(smoker).not_to receive(:exhale_smoke)
      smoker.inhale('deer')
    end
  end

  # ===========================================================================
  # smoke -- one practice cycle, pulling from the queue only when needed
  # ===========================================================================
  describe '#smoke' do
    before do
      smoker.instance_variable_set(:@time_between, 0)
      allow(smoker).to receive(:inhale)
      allow(smoker).to receive(:exhale_smoke)
    end

    it 'pulls the next image from the queue when none is given' do
      allow(smoker).to receive(:next_image).and_return('deer')
      expect(smoker).to receive(:inhale).with('deer')
      expect(smoker).to receive(:exhale_smoke).with('deer')
      smoker.smoke
    end

    it 'practices the given image without touching the queue' do
      expect(smoker).not_to receive(:next_image)
      expect(smoker).to receive(:exhale_smoke).with('tart')
      smoker.smoke('tart')
    end
  end

  # ===========================================================================
  # stow_pipe / announce_all_mastered -- small state/reporting helpers
  # ===========================================================================
  describe '#stow_pipe' do
    before { smoker.instance_variable_set(:@bag, 'smoking jacket') }

    it 'stows the pipe when it is in hand' do
      smoker.instance_variable_set(:@pipe, 'glitvire pipe')
      allow(DRCI).to receive(:in_hands?).and_return(true)
      expect(DRCI).to receive(:put_away_item?).with('glitvire pipe', 'smoking jacket')
      smoker.stow_pipe
    end

    it 'does nothing when the pipe is not in hand' do
      smoker.instance_variable_set(:@pipe, 'glitvire pipe')
      allow(DRCI).to receive(:in_hands?).and_return(false)
      expect(DRCI).not_to receive(:put_away_item?)
      smoker.stow_pipe
    end

    it 'does nothing on a cigar run (no pipe configured)' do
      smoker.instance_variable_set(:@pipe, nil)
      expect(DRCI).not_to receive(:put_away_item?)
      smoker.stow_pipe
    end
  end

  describe '#announce_all_mastered' do
    it 'reports the mastered set and includes the optional prefix' do
      allow(UserVars).to receive(:smoke_images_mastered).and_return(%w[deer tart])
      expect(DRC).to receive(:message).with(/All 2 images have reached master/)
      expect(DRC).to receive(:message).with(/Mastered: deer, tart/)
      expect(DRC).to receive(:message).with(/Finished 3 round\(s\)\. Nothing left/)
      smoker.announce_all_mastered('Finished 3 round(s). ')
    end
  end

  # ===========================================================================
  # abort_lesson -- clean teardown of a teach/learn session
  # ===========================================================================
  describe '#abort_lesson' do
    it 'stows the active smoker and exits' do
      smoker.instance_variable_set(:@smoker, 'glitvire pipe')
      smoker.instance_variable_set(:@bag, 'smoking jacket')
      allow(DRCI).to receive(:in_hands?).and_return(true)
      expect(DRCI).to receive(:put_away_item?).with('glitvire pipe', 'smoking jacket')
      expect { smoker.abort_lesson('teacher gone') }.to raise_error(SystemExit)
    end

    it 'exits even when nothing is held' do
      smoker.instance_variable_set(:@smoker, nil)
      expect(DRCI).not_to receive(:put_away_item?)
      expect { smoker.abort_lesson('teacher gone') }.to raise_error(SystemExit)
    end
  end

  # ===========================================================================
  # smoke_teach -- lights up and dispatches to the teach/learn loop
  # ===========================================================================
  describe '#smoke_teach' do
    before { smoker.instance_variable_set(:@pipe, 'glitvire pipe') }

    it 'dispatches to learn_loop for a learn request' do
      args = OpenStruct.new(smoke: 'pipe', teach: 'learn', player: 'bob')
      expect(smoker).to receive(:learn_loop).with(['deer'], 'Bob')
      smoker.smoke_teach(args, ['deer'])
    end

    it 'dispatches to teach_loop for a teach request' do
      args = OpenStruct.new(smoke: 'pipe', teach: 'teach', player: 'bob')
      expect(smoker).to receive(:teach_loop).with(['deer'], 'Bob')
      smoker.smoke_teach(args, ['deer'])
    end
  end

  # ===========================================================================
  # teach_loop -- image iteration + completion exit
  # ===========================================================================
  describe '#teach_loop' do
    it 'completes and exits when there is nothing to teach' do
      expect { smoker.teach_loop([], 'Bob') }.to raise_error(SystemExit)
    end

    it 'skips an image the student already knows, then completes' do
      allow(smoker).to receive(:offer_lesson).with('deer', 'Bob').and_return(false)
      expect(smoker).not_to receive(:smoke)
      expect { smoker.teach_loop(['deer'], 'Bob') }.to raise_error(SystemExit)
    end
  end

  # ===========================================================================
  # learn_loop -- the teacher-leaves-the-room guards (its whole reason to exist)
  # ===========================================================================
  describe '#learn_loop' do
    before do
      smoker.instance_variable_set(:@smoker, 'glitvire pipe')
      smoker.instance_variable_set(:@bag, 'smoking jacket')
      allow(DRCI).to receive(:in_hands?).and_return(true)
      allow(DRCI).to receive(:put_away_item?)
    end

    it 'aborts immediately when the teacher is not in the room' do
      allow(DRRoom).to receive(:pcs).and_return([])
      expect { smoker.learn_loop([], 'Bob') }.to raise_error(SystemExit)
    end

    it 'aborts when the teacher leaves while waiting to be taught' do
      allow(DRRoom).to receive(:pcs).and_return(['Bob'], [])
      allow(DRC).to receive(:bput).and_return("Bob isn't teaching a class")
      expect { smoker.learn_loop([], 'Bob') }.to raise_error(SystemExit)
    end

    it 'aborts when the teacher leaves mid-lesson' do
      allow(DRRoom).to receive(:pcs).and_return(['Bob'], [])
      allow(DRC).to receive(:bput).and_return("You start paying attention to Bob's advice on how to make a deer smoke image")
      expect { smoker.learn_loop([], 'Bob') }.to raise_error(SystemExit)
    end
  end

  # ===========================================================================
  # reset_known -- rebuild from the master list and report (then exit)
  # ===========================================================================
  describe '#reset_known' do
    before do
      smoker.instance_variable_set(:@full_image_list, %w[deer tart])
      allow(UserVars).to receive(:smoke_images_known=)
      allow(UserVars).to receive(:smoke_images_mastered=)
    end

    it 'reports the new training list and exits' do
      allow(smoker).to receive(:read_smoke_list).and_return([%w[deer learning], %w[tart master*]])
      expect(DRC).to receive(:message).with(/New Training List/)
      expect { smoker.reset_known }.to raise_error(SystemExit)
    end

    it 'reports when everything is already mastered and exits' do
      allow(smoker).to receive(:read_smoke_list).and_return([%w[deer master*], %w[tart master*]])
      expect(DRC).to receive(:message).with(/All known images are mastered/)
      expect { smoker.reset_known }.to raise_error(SystemExit)
    end
  end

  # ===========================================================================
  # smoke_loop -- the full round loop, driving the new-cig tobacco flag
  # ===========================================================================
  describe '#smoke_loop' do
    before do
      smoker.instance_variable_set(:@pipe, 'glitvire pipe')
      smoker.instance_variable_set(:@cigar, nil)
      smoker.instance_variable_set(:@bag, 'smoking jacket')
      smoker.instance_variable_set(:@smoke_settings, {})
      allow(smoker).to receive(:quick_light)
      allow(smoker).to receive(:stow_pipe)
      allow(DRC).to receive(:message)
      Flags['new-cig'] = true # a fresh, unlit smoker
    end

    it 'announces and exits when the first queue is already empty' do
      allow(smoker).to receive(:build_priority_queue).and_return([])
      expect(smoker).to receive(:announce_all_mastered)
      expect { smoker.smoke_loop(%w[deer], 1) }.to raise_error(SystemExit)
    end

    it 'runs exactly the requested number of rounds then completes' do
      allow(smoker).to receive(:build_priority_queue).and_return(['deer'])
      # Each smoke cycle ends by exhausting the tobacco (sets new-cig), ending the
      # inner `smoke until Flags['new-cig']` after one call per round.
      expect(smoker).to(receive(:smoke).exactly(2).times { Flags['new-cig'] = true })
      expect(smoker).to receive(:stow_pipe)
      expect(DRC).to receive(:message).with(/Smoker Complete! Finished 2 round/)
      expect { smoker.smoke_loop(['deer'], 2) }.not_to raise_error
    end

    it 'walks to the configured smoke room before training' do
      smoker.instance_variable_set(:@smoke_settings, { 'smoke_room' => 1234 })
      allow(smoker).to receive(:build_priority_queue).and_return(['deer'])
      allow(smoker).to receive(:smoke) { Flags['new-cig'] = true }
      expect(DRCT).to receive(:walk_to).with(1234)
      smoker.smoke_loop(['deer'], 1)
    end

    it 'stops in until_out mode when tobacco runs out' do
      allow(smoker).to receive(:build_priority_queue).and_return(['deer'])
      allow(smoker).to receive(:quick_light_safe).and_return(false)
      expect(smoker).not_to receive(:smoke)
      expect { smoker.smoke_loop(['deer'], :until_out) }.not_to raise_error
    end

    it 'exits in until_out mode once everything becomes mastered' do
      allow(smoker).to receive(:build_priority_queue).and_return(['deer'], [])
      allow(smoker).to receive(:quick_light_safe).and_return(true)
      allow(smoker).to receive(:smoke) { Flags['new-cig'] = true }
      expect(smoker).to receive(:announce_all_mastered).with(/Finished 1 round/)
      expect { smoker.smoke_loop(['deer'], :until_out) }.to raise_error(SystemExit)
    end
  end

  # ===========================================================================
  # initialize -- argument routing / dispatch (collaborators stubbed)
  # ===========================================================================
  describe '#initialize (dispatch)' do
    let(:yaml_smoke) { { 'container' => 'smoking jacket', 'pipe' => 'glitvire pipe', 'smoke_images' => %w[deer tart] } }

    # Build a bare instance with every collaborator stubbed, then run initialize.
    def boot(args_opts, smoke: yaml_smoke)
      instance = described_class.allocate
      allow(instance).to receive(:parse_args).and_return(OpenStruct.new(args_opts))
      allow(instance).to receive(:get_settings).and_return(double('settings', smoke: smoke))
      allow(EquipmentManager).to receive(:new).and_return(double('eq'))
      allow(instance).to receive(:find_blade).and_return(nil)
      allow(instance).to receive(:validate_settings)
      allow(instance).to receive(:quick_light)
      allow(instance).to receive(:reset_known)
      allow(instance).to receive(:smoke_teach)
      allow(instance).to receive(:smoke_loop)
      instance
    end

    it 'aborts when there is no smoke settings block' do
      instance = boot({}, smoke: nil)
      expect { instance.send(:initialize) }.to raise_error(SystemExit)
    end

    it 'light_only lights the requested utensil and exits' do
      instance = boot({ light_only: 'light_only', smoke: 'pipe' })
      expect(instance).to receive(:quick_light).with('pipe')
      expect { instance.send(:initialize) }.to raise_error(SystemExit)
    end

    it 'defaults to a single round' do
      instance = boot({})
      expect(instance).to receive(:smoke_loop).with(%w[deer tart], 1)
      instance.send(:initialize)
    end

    it 'passes :until_out through to the loop' do
      instance = boot({ until_out: 'until_out' })
      expect(instance).to receive(:smoke_loop).with(%w[deer tart], :until_out)
      instance.send(:initialize)
    end

    it 'passes an explicit repeat count through to the loop' do
      instance = boot({ repeat: '3' })
      expect(instance).to receive(:smoke_loop).with(%w[deer tart], 3)
      instance.send(:initialize)
    end

    it 'runs reset_known when requested' do
      instance = boot({ reset_known: 'reset_known' })
      expect(instance).to receive(:reset_known)
      instance.send(:initialize)
    end

    it 'dispatches to teaching when requested' do
      instance = boot({ teach: 'teach' })
      expect(instance).to receive(:smoke_teach)
      instance.send(:initialize)
    end

    it 'trains a single explicitly-requested image' do
      instance = boot({ image: 'deer' })
      expect(instance).to receive(:smoke_loop).with(['deer'], 1)
      instance.send(:initialize)
    end
  end
end
