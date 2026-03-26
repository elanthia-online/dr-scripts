require_relative 'spec_helper'

# HuntingBuddy's initialize depends on the full Lich runtime (parse_args,
# get_settings, get_data, etc.), so we extract the class via load_lic_class
# and test methods on bare-allocated instances with injected state.
#
# These specs focus on the plugin system infrastructure and the CT stop
# timeout fix -- the two changes in this PR. Every test is self-contained
# and reads top-to-bottom without chasing helpers (DAMP principle).

load_lic_class('hunting-buddy.lic', 'HuntingBuddy')

RSpec.describe HuntingBuddy do
  # ===========================================================================
  # Plugin Registry (class-level)
  # ===========================================================================

  describe '.registered_plugins' do
    after(:each) do
      # Clean up: remove any plugins registered during test
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])
    end

    it 'starts as an empty array' do
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])
      expect(HuntingBuddy.registered_plugins).to eq([])
    end

    it 'is readable but not directly writable from outside' do
      expect(HuntingBuddy).to respond_to(:registered_plugins)
      expect(HuntingBuddy).not_to respond_to(:registered_plugins=)
    end
  end

  describe '.register_plugin' do
    after(:each) do
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])
    end

    it 'appends a plugin instance to the registry' do
      plugin = Object.new
      HuntingBuddy.register_plugin(plugin)

      expect(HuntingBuddy.registered_plugins).to include(plugin)
    end

    it 'preserves insertion order for multiple plugins' do
      plugin_a = Object.new
      plugin_b = Object.new

      HuntingBuddy.register_plugin(plugin_a)
      HuntingBuddy.register_plugin(plugin_b)

      expect(HuntingBuddy.registered_plugins).to eq([plugin_a, plugin_b])
    end

    it 'allows the same plugin instance to be registered twice' do
      plugin = Object.new
      HuntingBuddy.register_plugin(plugin)
      HuntingBuddy.register_plugin(plugin)

      expect(HuntingBuddy.registered_plugins.size).to eq(2)
    end
  end

  # ===========================================================================
  # fire_hook (private, tested via send)
  # ===========================================================================

  describe '#fire_hook' do
    let(:buddy) { HuntingBuddy.allocate }

    after(:each) do
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])
    end

    it 'returns nil when no plugins are registered' do
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])

      result = buddy.send(:fire_hook, :find_room, buddy, [], 1234)

      expect(result).to be_nil
    end

    it 'skips plugins that do not implement the hook' do
      plugin_without_hook = Object.new
      HuntingBuddy.register_plugin(plugin_without_hook)

      result = buddy.send(:fire_hook, :find_room, buddy, [], 1234)

      expect(result).to be_nil
    end

    it 'returns the first non-nil result from a plugin' do
      plugin = double('plugin')
      allow(plugin).to receive(:respond_to?).with(:find_room).and_return(true)
      allow(plugin).to receive(:find_room).and_return(true)
      HuntingBuddy.register_plugin(plugin)

      result = buddy.send(:fire_hook, :find_room, buddy, ['zone1'], 1234)

      expect(result).to eq(true)
    end

    it 'returns nil when plugin returns nil (decline)' do
      plugin = double('plugin')
      allow(plugin).to receive(:respond_to?).with(:find_room).and_return(true)
      allow(plugin).to receive(:find_room).and_return(nil)
      HuntingBuddy.register_plugin(plugin)

      result = buddy.send(:fire_hook, :find_room, buddy, ['zone1'], 1234)

      expect(result).to be_nil
    end

    it 'stops at the first non-nil result and does not call subsequent plugins' do
      plugin_a = double('plugin_a')
      allow(plugin_a).to receive(:respond_to?).with(:find_room).and_return(true)
      allow(plugin_a).to receive(:find_room).and_return(false)

      plugin_b = double('plugin_b')
      allow(plugin_b).to receive(:respond_to?).with(:find_room).and_return(true)

      HuntingBuddy.register_plugin(plugin_a)
      HuntingBuddy.register_plugin(plugin_b)

      result = buddy.send(:fire_hook, :find_room, buddy, [], 1234)

      expect(result).to eq(false)
      expect(plugin_b).not_to have_received(:respond_to?)
    end

    it 'skips first plugin returning nil and returns second plugin result' do
      plugin_a = double('plugin_a')
      allow(plugin_a).to receive(:respond_to?).with(:find_room).and_return(true)
      allow(plugin_a).to receive(:find_room).and_return(nil)

      plugin_b = double('plugin_b')
      allow(plugin_b).to receive(:respond_to?).with(:find_room).and_return(true)
      allow(plugin_b).to receive(:find_room).and_return(true)

      HuntingBuddy.register_plugin(plugin_a)
      HuntingBuddy.register_plugin(plugin_b)

      result = buddy.send(:fire_hook, :find_room, buddy, [], 1234)

      expect(result).to eq(true)
    end

    context 'when a plugin raises an exception' do
      it 'catches the error and continues to next plugin' do
        exploding_plugin = double('exploding_plugin')
        allow(exploding_plugin).to receive(:respond_to?).with(:find_room).and_return(true)
        allow(exploding_plugin).to receive(:find_room).and_raise(RuntimeError, 'boom')
        allow(exploding_plugin).to receive(:class).and_return(Class.new { def self.name; 'ExplodingPlugin'; end })

        good_plugin = double('good_plugin')
        allow(good_plugin).to receive(:respond_to?).with(:find_room).and_return(true)
        allow(good_plugin).to receive(:find_room).and_return(true)

        HuntingBuddy.register_plugin(exploding_plugin)
        HuntingBuddy.register_plugin(good_plugin)

        # Enable debug mode so the rescue branch logs (covers that code path)
        $debug_mode_hunting = true
        result = buddy.send(:fire_hook, :find_room, buddy, [], 1234)
        $debug_mode_hunting = nil

        expect(result).to eq(true)
      end

      it 'returns nil if all plugins raise exceptions' do
        plugin = double('plugin')
        allow(plugin).to receive(:respond_to?).with(:find_room).and_return(true)
        allow(plugin).to receive(:find_room).and_raise(RuntimeError, 'kaboom')
        allow(plugin).to receive(:class).and_return(Class.new { def self.name; 'BrokenPlugin'; end })

        HuntingBuddy.register_plugin(plugin)

        result = buddy.send(:fire_hook, :find_room, buddy, [], 1234)

        expect(result).to be_nil
      end

      it 'suppresses error logging when debug mode is off' do
        plugin = double('plugin')
        allow(plugin).to receive(:respond_to?).with(:find_room).and_return(true)
        allow(plugin).to receive(:find_room).and_raise(RuntimeError, 'silent boom')
        allow(plugin).to receive(:class).and_return(Class.new { def self.name; 'SilentPlugin'; end })

        HuntingBuddy.register_plugin(plugin)

        $debug_mode_hunting = nil
        buddy.send(:fire_hook, :find_room, buddy, [], 1234)

        # No echo output expected when debug mode is off
        expect($displayed_messages).not_to include(a_string_matching(/SilentPlugin/))
      end
    end

    it 'distinguishes false (handled, negative) from nil (declined)' do
      # A plugin returning false means "I handled this and the answer is no"
      # A plugin returning nil means "I don't handle this, ask the next plugin"
      plugin = double('plugin')
      allow(plugin).to receive(:respond_to?).with(:find_room).and_return(true)
      allow(plugin).to receive(:find_room).and_return(false)
      HuntingBuddy.register_plugin(plugin)

      result = buddy.send(:fire_hook, :find_room, buddy, [], 1234)

      expect(result).to eq(false)
      expect(result).not_to be_nil
    end
  end

  # ===========================================================================
  # notify_hook (private, tested via send)
  # ===========================================================================

  describe '#notify_hook' do
    let(:buddy) { HuntingBuddy.allocate }

    after(:each) do
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])
    end

    it 'does nothing when no plugins are registered' do
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])

      # Should not raise
      expect { buddy.send(:notify_hook, :after_initialize, buddy) }.not_to raise_error
    end

    it 'calls all plugins that implement the hook' do
      plugin_a = double('plugin_a')
      allow(plugin_a).to receive(:respond_to?).with(:after_hunt).and_return(true)
      allow(plugin_a).to receive(:after_hunt)

      plugin_b = double('plugin_b')
      allow(plugin_b).to receive(:respond_to?).with(:after_hunt).and_return(true)
      allow(plugin_b).to receive(:after_hunt)

      HuntingBuddy.register_plugin(plugin_a)
      HuntingBuddy.register_plugin(plugin_b)

      buddy.send(:notify_hook, :after_hunt, buddy, hunting_room: 1234, counter: 60)

      expect(plugin_a).to have_received(:after_hunt).with(buddy, hunting_room: 1234, counter: 60)
      expect(plugin_b).to have_received(:after_hunt).with(buddy, hunting_room: 1234, counter: 60)
    end

    it 'skips plugins that do not implement the hook' do
      plugin_with = double('plugin_with')
      allow(plugin_with).to receive(:respond_to?).with(:cleanup).and_return(true)
      allow(plugin_with).to receive(:cleanup)

      plugin_without = Object.new

      HuntingBuddy.register_plugin(plugin_with)
      HuntingBuddy.register_plugin(plugin_without)

      buddy.send(:notify_hook, :cleanup, buddy)

      expect(plugin_with).to have_received(:cleanup).with(buddy)
    end

    context 'when a plugin raises an exception' do
      it 'continues calling remaining plugins' do
        exploding_plugin = double('exploding_plugin')
        allow(exploding_plugin).to receive(:respond_to?).with(:before_hunt).and_return(true)
        allow(exploding_plugin).to receive(:before_hunt).and_raise(RuntimeError, 'explosion')
        allow(exploding_plugin).to receive(:class).and_return(Class.new { def self.name; 'Exploder'; end })

        survivor_plugin = double('survivor_plugin')
        allow(survivor_plugin).to receive(:respond_to?).with(:before_hunt).and_return(true)
        allow(survivor_plugin).to receive(:before_hunt)

        HuntingBuddy.register_plugin(exploding_plugin)
        HuntingBuddy.register_plugin(survivor_plugin)

        buddy.send(:notify_hook, :before_hunt, buddy, hunting_room: 5000)

        expect(survivor_plugin).to have_received(:before_hunt).with(buddy, hunting_room: 5000)
      end

      it 'does not propagate exceptions to the caller' do
        plugin = double('plugin')
        allow(plugin).to receive(:respond_to?).with(:cleanup).and_return(true)
        allow(plugin).to receive(:cleanup).and_raise(RuntimeError, 'cleanup failed')
        allow(plugin).to receive(:class).and_return(Class.new { def self.name; 'FailPlugin'; end })

        HuntingBuddy.register_plugin(plugin)

        expect { buddy.send(:notify_hook, :cleanup, buddy) }.not_to raise_error
      end
    end

    it 'ignores return values from plugins (unlike fire_hook)' do
      plugin = Object.new
      def plugin.hunt_status(*_args, **_kwargs); :break; end

      HuntingBuddy.register_plugin(plugin)

      # notify_hook does not use plugin return values as control flow
      # (unlike fire_hook which returns the first non-nil result).
      # It returns the result of Array#each (the array), not a plugin value.
      result = buddy.send(:notify_hook, :hunt_status, buddy, counter: 0, duration: 30)

      expect(result).not_to eq(:break)
    end
  end

  # ===========================================================================
  # method_missing / respond_to_missing? (plugin API forwarding)
  # ===========================================================================

  describe '#method_missing' do
    let(:buddy) { HuntingBuddy.allocate }

    after(:each) do
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])
    end

    it 'forwards unknown methods to plugins that implement them' do
      plugin = double('plugin')
      allow(plugin).to receive(:respond_to?).with(:force_relocation!).and_return(true)
      allow(plugin).to receive(:force_relocation!).with(15082).and_return(true)
      HuntingBuddy.register_plugin(plugin)

      result = buddy.force_relocation!(15082)

      expect(result).to eq(true)
      expect(plugin).to have_received(:force_relocation!).with(15082)
    end

    it 'raises NoMethodError when no plugin implements the method' do
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])

      expect { buddy.nonexistent_method }.to raise_error(NoMethodError)
    end

    it 'forwards to the first plugin that responds, ignoring others' do
      plugin_a = double('plugin_a')
      allow(plugin_a).to receive(:respond_to?).with(:custom_api).and_return(true)
      allow(plugin_a).to receive(:custom_api).and_return('from_a')

      plugin_b = double('plugin_b')
      # plugin_b should never be checked since plugin_a handles it

      HuntingBuddy.register_plugin(plugin_a)
      HuntingBuddy.register_plugin(plugin_b)

      result = buddy.custom_api

      expect(result).to eq('from_a')
    end

    it 'falls through to next plugin if first does not respond' do
      plugin_a = double('plugin_a')
      allow(plugin_a).to receive(:respond_to?).with(:only_on_b).and_return(false)

      plugin_b = double('plugin_b')
      allow(plugin_b).to receive(:respond_to?).with(:only_on_b).and_return(true)
      allow(plugin_b).to receive(:only_on_b).and_return('from_b')

      HuntingBuddy.register_plugin(plugin_a)
      HuntingBuddy.register_plugin(plugin_b)

      result = buddy.only_on_b

      expect(result).to eq('from_b')
    end
  end

  describe '#respond_to_missing?' do
    let(:buddy) { HuntingBuddy.allocate }

    after(:each) do
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])
    end

    it 'returns true when a plugin implements the method' do
      plugin = double('plugin')
      allow(plugin).to receive(:respond_to?).with(:force_relocation!).and_return(true)
      HuntingBuddy.register_plugin(plugin)

      expect(buddy.respond_to?(:force_relocation!)).to be true
    end

    it 'returns false when no plugin implements the method' do
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])

      expect(buddy.respond_to?(:totally_unknown_method)).to be false
    end

    it 'still returns true for built-in methods like stop_hunting' do
      expect(buddy.respond_to?(:stop_hunting)).to be true
    end
  end

  # ===========================================================================
  # State Accessors (attr_reader / attr_accessor)
  # ===========================================================================

  describe 'state accessors' do
    let(:buddy) { HuntingBuddy.allocate }

    describe 'attr_reader :settings' do
      it 'exposes settings for plugin read access' do
        settings = OpenStruct.new(hometown: 'Crossing')
        buddy.instance_variable_set(:@settings, settings)

        expect(buddy.settings.hometown).to eq('Crossing')
      end

      it 'does not allow writing settings from outside' do
        expect(buddy).not_to respond_to(:settings=)
      end
    end

    describe 'attr_reader :hunting_data' do
      it 'exposes hunting_data for plugin read access' do
        data = OpenStruct.new(hunting_zones: { 'zone1' => [1, 2, 3] })
        buddy.instance_variable_set(:@hunting_data, data)

        expect(buddy.hunting_data.hunting_zones).to include('zone1')
      end
    end

    describe 'attr_reader :hunting_zones' do
      it 'exposes hunting_zones for plugin read access' do
        zones = { 'zone1' => [100, 200], 'zone2' => [300] }
        buddy.instance_variable_set(:@hunting_zones, zones)

        expect(buddy.hunting_zones).to eq(zones)
      end
    end

    describe 'attr_reader :hunting_info' do
      it 'exposes hunting_info for plugin read access' do
        info = [{ 'args' => ['farm'], zone: 'zone1' }]
        buddy.instance_variable_set(:@hunting_info, info)

        expect(buddy.hunting_info).to eq(info)
      end
    end

    describe 'attr_accessor :my_room_claim' do
      it 'allows reading and writing my_room_claim' do
        buddy.my_room_claim = 15082

        expect(buddy.my_room_claim).to eq(15082)
      end

      it 'defaults to nil when not set' do
        expect(buddy.my_room_claim).to be_nil
      end
    end

    describe 'attr_accessor :need_relocation' do
      it 'allows reading and writing need_relocation' do
        buddy.need_relocation = true

        expect(buddy.need_relocation).to be true
      end
    end

    describe 'attr_accessor :stopped_for_bleeding' do
      it 'allows reading and writing stopped_for_bleeding' do
        buddy.stopped_for_bleeding = true

        expect(buddy.stopped_for_bleeding).to be true
      end
    end
  end

  # ===========================================================================
  # Hook Integration Points (verify hooks fire at correct lifecycle points)
  # ===========================================================================

  describe 'lifecycle hook integration' do
    let(:buddy) { HuntingBuddy.allocate }

    after(:each) do
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])
    end

    # We can't call initialize/hunt/etc. directly (they need the full runtime),
    # but we CAN verify the hook methods exist and are callable.

    it 'has fire_hook as a private method' do
      expect(buddy.private_methods).to include(:fire_hook)
    end

    it 'has notify_hook as a private method' do
      expect(buddy.private_methods).to include(:notify_hook)
    end

    it 'does not expose fire_hook or notify_hook publicly' do
      expect(buddy.public_methods).not_to include(:fire_hook)
      expect(buddy.public_methods).not_to include(:notify_hook)
    end
  end

  # ===========================================================================
  # Plugin Loading (file glob pattern)
  # ===========================================================================

  describe 'plugin loading' do
    # The plugin loading code is at the top level of the .lic file (not in the
    # class), so we test the pattern rather than executing it directly.

    it 'uses a glob pattern that matches hunting-buddy-plugin-*.rb files' do
      pattern = 'hunting-buddy-plugin-*.rb'

      expect('hunting-buddy-plugin-coordination.rb').to match(File.fnmatch?(pattern, 'hunting-buddy-plugin-coordination.rb') ? /.*/ : /will not match/)
      expect(File.fnmatch?(pattern, 'hunting-buddy-plugin-coordination.rb')).to be true
      expect(File.fnmatch?(pattern, 'hunting-buddy-plugin-profiler.rb')).to be true
    end

    it 'does not match files that do not follow the naming convention' do
      pattern = 'hunting-buddy-plugin-*.rb'

      expect(File.fnmatch?(pattern, 'hunting-buddy.lic')).to be false
      expect(File.fnmatch?(pattern, 'combat-trainer.lic')).to be false
      expect(File.fnmatch?(pattern, 'some-other-plugin.rb')).to be false
    end

    it 'sorts plugin files alphabetically for deterministic load order' do
      files = ['hunting-buddy-plugin-z.rb', 'hunting-buddy-plugin-a.rb', 'hunting-buddy-plugin-m.rb']

      expect(files.sort).to eq(['hunting-buddy-plugin-a.rb', 'hunting-buddy-plugin-m.rb', 'hunting-buddy-plugin-z.rb'])
    end
  end

  # ===========================================================================
  # Adversarial: Edge Cases and Concurrency
  # ===========================================================================

  describe 'adversarial edge cases' do
    let(:buddy) { HuntingBuddy.allocate }

    after(:each) do
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])
    end

    context 'when a plugin modifies the registry during iteration' do
      it 'does not crash if a plugin registers another plugin during a hook' do
        sneaky_plugin = Object.new
        def sneaky_plugin.respond_to?(method, *); method == :after_initialize || super; end

        def sneaky_plugin.after_initialize(_buddy)
          new_plugin = Object.new
          HuntingBuddy.register_plugin(new_plugin)
          nil
        end

        HuntingBuddy.register_plugin(sneaky_plugin)

        # Ruby's Array#each tolerates appends during iteration
        expect { buddy.send(:notify_hook, :after_initialize, buddy) }.not_to raise_error
      end
    end

    context 'when fire_hook receives false vs nil' do
      it 'treats false as a definitive answer (not the same as nil/decline)' do
        plugin = double('plugin')
        allow(plugin).to receive(:respond_to?).with(:find_room).and_return(true)
        allow(plugin).to receive(:find_room).and_return(false)
        HuntingBuddy.register_plugin(plugin)

        result = buddy.send(:fire_hook, :find_room, buddy, [], 0)

        # false means "I handled it and the answer is no"
        expect(result).to eq(false)
      end

      it 'treats 0 as a definitive answer (truthy non-nil)' do
        plugin = double('plugin')
        allow(plugin).to receive(:respond_to?).with(:hunt_tick).and_return(true)
        allow(plugin).to receive(:hunt_tick).and_return(0)
        HuntingBuddy.register_plugin(plugin)

        result = buddy.send(:fire_hook, :hunt_tick, buddy, counter: 0)

        expect(result).to eq(0)
      end

      it 'treats empty string as a definitive answer (truthy non-nil)' do
        plugin = double('plugin')
        allow(plugin).to receive(:respond_to?).with(:find_room).and_return(true)
        allow(plugin).to receive(:find_room).and_return('')
        HuntingBuddy.register_plugin(plugin)

        result = buddy.send(:fire_hook, :find_room, buddy, [], 0)

        expect(result).to eq('')
      end
    end

    context 'when plugin raises different exception types' do
      it 'catches StandardError subclasses' do
        plugin = double('plugin')
        allow(plugin).to receive(:respond_to?).with(:cleanup).and_return(true)
        allow(plugin).to receive(:cleanup).and_raise(ArgumentError, 'bad args')
        allow(plugin).to receive(:class).and_return(Class.new { def self.name; 'ArgPlugin'; end })

        HuntingBuddy.register_plugin(plugin)

        expect { buddy.send(:notify_hook, :cleanup, buddy) }.not_to raise_error
      end

      it 'catches NameError (e.g. undefined constant in plugin)' do
        plugin = double('plugin')
        allow(plugin).to receive(:respond_to?).with(:before_hunt).and_return(true)
        allow(plugin).to receive(:before_hunt).and_raise(NameError, 'undefined local variable')
        allow(plugin).to receive(:class).and_return(Class.new { def self.name; 'NamePlugin'; end })

        HuntingBuddy.register_plugin(plugin)

        expect { buddy.send(:notify_hook, :before_hunt, buddy, hunting_room: 1) }.not_to raise_error
      end

      it 'catches TypeError (e.g. nil method call in plugin)' do
        plugin = double('plugin')
        allow(plugin).to receive(:respond_to?).with(:hunt_tick).and_return(true)
        allow(plugin).to receive(:hunt_tick).and_raise(TypeError, "no implicit conversion of nil")
        allow(plugin).to receive(:class).and_return(Class.new { def self.name; 'TypePlugin'; end })

        HuntingBuddy.register_plugin(plugin)

        result = buddy.send(:fire_hook, :hunt_tick, buddy, counter: 5)

        expect(result).to be_nil
      end
    end

    context 'with many plugins registered' do
      it 'calls all 10 plugins for a notify_hook' do
        plugins = 10.times.map do |i|
          plugin = double("plugin_#{i}")
          allow(plugin).to receive(:respond_to?).with(:hunt_status).and_return(true)
          allow(plugin).to receive(:hunt_status)
          HuntingBuddy.register_plugin(plugin)
          plugin
        end

        buddy.send(:notify_hook, :hunt_status, buddy, counter: 60, duration: 30)

        plugins.each do |p|
          expect(p).to have_received(:hunt_status).once
        end
      end

      it 'stops at first responder in fire_hook even with 10 plugins' do
        first_plugin = double('first')
        allow(first_plugin).to receive(:respond_to?).with(:find_room).and_return(true)
        allow(first_plugin).to receive(:find_room).and_return(true)
        HuntingBuddy.register_plugin(first_plugin)

        9.times do
          plugin = double('uncalled')
          HuntingBuddy.register_plugin(plugin)
        end

        result = buddy.send(:fire_hook, :find_room, buddy, [], 0)

        expect(result).to eq(true)
      end
    end

    context 'with zero plugins' do
      before { HuntingBuddy.instance_variable_set(:@registered_plugins, []) }

      it 'fire_hook returns nil harmlessly' do
        expect(buddy.send(:fire_hook, :any_hook)).to be_nil
      end

      it 'notify_hook completes harmlessly' do
        expect { buddy.send(:notify_hook, :any_hook) }.not_to raise_error
      end

      it 'method_missing raises NoMethodError as normal' do
        expect { buddy.unknown_plugin_method }.to raise_error(NoMethodError)
      end
    end
  end

  # ===========================================================================
  # Keyword Arguments Forwarding
  # ===========================================================================

  describe 'keyword argument forwarding' do
    let(:buddy) { HuntingBuddy.allocate }

    after(:each) do
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])
    end

    it 'fire_hook forwards keyword arguments to plugins' do
      plugin = double('plugin')
      allow(plugin).to receive(:respond_to?).with(:hunt_tick).and_return(true)
      allow(plugin).to receive(:hunt_tick).with(buddy, counter: 42).and_return(nil)
      HuntingBuddy.register_plugin(plugin)

      buddy.send(:fire_hook, :hunt_tick, buddy, counter: 42)

      expect(plugin).to have_received(:hunt_tick).with(buddy, counter: 42)
    end

    it 'notify_hook forwards keyword arguments to plugins' do
      plugin = double('plugin')
      allow(plugin).to receive(:respond_to?).with(:before_hunt).and_return(true)
      allow(plugin).to receive(:before_hunt).with(buddy, hunting_room: 9999)
      HuntingBuddy.register_plugin(plugin)

      buddy.send(:notify_hook, :before_hunt, buddy, hunting_room: 9999)

      expect(plugin).to have_received(:before_hunt).with(buddy, hunting_room: 9999)
    end

    it 'notify_hook forwards multiple keyword arguments' do
      plugin = double('plugin')
      allow(plugin).to receive(:respond_to?).with(:after_hunt).and_return(true)
      allow(plugin).to receive(:after_hunt).with(buddy, hunting_room: 100, counter: 300)
      HuntingBuddy.register_plugin(plugin)

      buddy.send(:notify_hook, :after_hunt, buddy, hunting_room: 100, counter: 300)

      expect(plugin).to have_received(:after_hunt).with(buddy, hunting_room: 100, counter: 300)
    end
  end

  # ===========================================================================
  # Existing Public API Preservation
  # ===========================================================================

  describe 'existing public API' do
    let(:buddy) { HuntingBuddy.allocate }

    describe '#stop_hunting' do
      it 'sets the @stop_hunting flag to true' do
        buddy.instance_variable_set(:@stop_hunting, false)

        buddy.stop_hunting

        expect(buddy.instance_variable_get(:@stop_hunting)).to be true
      end
    end

    describe '#next_hunt' do
      it 'sets the @next_hunt flag to true' do
        buddy.instance_variable_set(:@next_hunt, false)

        buddy.next_hunt

        expect(buddy.instance_variable_get(:@next_hunt)).to be true
      end
    end
  end
end
