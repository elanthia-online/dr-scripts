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
end
