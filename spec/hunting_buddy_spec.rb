require_relative 'spec_helper'
require 'tmpdir'
require 'fileutils'

# HuntingBuddy's initialize depends on the full Lich runtime (parse_args,
# get_settings, get_data, etc.), so we extract the class via load_lic_class
# and test methods on bare-allocated instances with injected state.
#
# Top-level code (before_dying, the plugin load call, HuntingBuddy.new.main)
# is not loaded by these specs; keep it to calls into methods tested here.
# Every test is self-contained and reads top-to-bottom without chasing
# helpers (DAMP principle).

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
  # Plugin Loading
  # ===========================================================================

  describe '.load_plugins' do
    let(:dir) { Dir.mktmpdir('hunting-buddy-plugins') }

    # Each plugin file appends its own name to $hb_loaded when it is loaded.
    def write_plugin(name, body = nil)
      File.write(File.join(dir, name), body || "$hb_loaded << #{name.inspect}\n")
    end

    before { $hb_loaded = [] }

    after do
      FileUtils.remove_entry(dir)
      $hb_loaded = nil
    end

    it 'loads hunting-buddy-plugin-*.rb files in name order' do
      write_plugin('hunting-buddy-plugin-zeta.rb')
      write_plugin('hunting-buddy-plugin-alpha.rb')

      HuntingBuddy.load_plugins(dir)

      expect($hb_loaded).to eq(['hunting-buddy-plugin-alpha.rb', 'hunting-buddy-plugin-zeta.rb'])
    end

    it 'ignores files that do not follow the naming convention' do
      write_plugin('some-other-plugin.rb')
      write_plugin('hunting-buddy-plugin-notes.txt')

      HuntingBuddy.load_plugins(dir)

      expect($hb_loaded).to be_empty
    end

    it 'reports a plugin that raises and still loads the others' do
      write_plugin('hunting-buddy-plugin-a-broken.rb', "raise 'boom'\n")
      write_plugin('hunting-buddy-plugin-b-fine.rb')

      HuntingBuddy.load_plugins(dir)

      expect($hb_loaded).to eq(['hunting-buddy-plugin-b-fine.rb'])
      expect(displayed_messages).to include('Failed to load hunting-buddy plugin hunting-buddy-plugin-a-broken.rb: boom')
    end

    it 'reports a plugin with a syntax error and still loads the others' do
      write_plugin('hunting-buddy-plugin-a-typo.rb', "def broken(\n")
      write_plugin('hunting-buddy-plugin-b-fine.rb')

      expect { HuntingBuddy.load_plugins(dir) }.not_to raise_error

      expect($hb_loaded).to eq(['hunting-buddy-plugin-b-fine.rb'])
      expect(displayed_messages.grep(/Failed to load hunting-buddy plugin hunting-buddy-plugin-a-typo\.rb/)).not_to be_empty
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

    context 'when a plugin raises a ScriptError' do
      it 'isolates a NotImplementedError in a decision hook and asks the next plugin' do
        abstract = Class.new { def find_room(*) = raise(NotImplementedError, 'todo') }.new
        answer = Class.new { def find_room(*) = :mine }.new
        HuntingBuddy.register_plugin(abstract)
        HuntingBuddy.register_plugin(answer)

        expect(buddy.send(:fire_hook, :find_room, buddy, [], 1)).to eq(:mine)
      end

      it 'isolates a NotImplementedError in a notification hook and still calls the rest' do
        seen = []
        abstract = Class.new { def cleanup(*) = raise(NotImplementedError, 'todo') }.new
        listener = Object.new
        listener.define_singleton_method(:cleanup) { |*| seen << :cleanup }
        HuntingBuddy.register_plugin(abstract)
        HuntingBuddy.register_plugin(listener)

        expect { buddy.send(:notify_hook, :cleanup, buddy) }.not_to raise_error
        expect(seen).to eq([:cleanup])
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

  # ===========================================================================
  # Room check: is the candidate hunting room empty?
  # ===========================================================================

  describe '#find_hunting_room? empty-room check' do
    let(:buddy) { HuntingBuddy.allocate }
    let(:settings) do
      OpenStruct.new(
        custom_hunting_zones: {},
        hunting_buddies: [],
        hunting_nemesis: [],
        empty_hunting_room_messages: ['Is anyone hunting here?'],
        hunting_room_min_mana: 0,
        hunting_room_strict_mana: false,
        hunting_room_max_searches: 30
      )
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

    # Runs the room predicate hunting-buddy hands to find_empty_room, with
    # `say_echo` as the line the game sends back for our own empty-room say
    # and `heard` as anything else that arrives while we wait.
    def room_judged_empty?(say_echo:, heard: nil, avoid_buddies: false, pcs: [], group: [], search_finds: nil, heard_in_search: nil)
      buddy.instance_variable_set(:@settings, settings)
      buddy.instance_variable_set(:@hunting_zones, { 'rats' => [1] })
      buddy.instance_variable_set(:@escort_zones, {})
      buddy.instance_variable_set(:@hunting_buddies_max, 2)
      DRRoom.pcs = pcs
      DRRoom.group_members = group
      allow(DRC).to receive(:bput).with('search', any_args) do
        deliver(heard_in_search) if heard_in_search
        'Roundtime: 3 sec.'
      end
      allow(buddy).to receive(:reget).and_return(search_finds ? [search_finds, 'You search around for a moment.'].reverse : [])
      allow(buddy).to receive(:waitrt?)
      allow(buddy).to receive(:pause)
      allow(buddy).to receive(:fput) do |command|
        next unless command.start_with?('say ')

        deliver(say_echo)
        deliver(heard) if heard
      end
      allow(DRCT).to receive(:find_empty_room) { |_rooms, _idle, predicate, *_rest| predicate.call(1) }

      buddy.find_hunting_room?(['rats'], 851, false, avoid_buddies)
    end

    context 'with a hunting buddy (Bob)' do
      let(:settings) do
        OpenStruct.new(custom_hunting_zones: {}, hunting_buddies: ['Bob'], hunting_nemesis: [],
                       empty_hunting_room_messages: ['Is anyone hunting here?'],
                       hunting_room_min_mana: 0, hunting_room_strict_mana: false, hunting_room_max_searches: 30)
      end
      let(:echo) { 'You say, "Is anyone hunting here?"' }

      it 'takes a room where a hidden buddy speaks up, by default' do
        expect(room_judged_empty?(say_echo: echo, search_finds: 'You notice Bob, who is hiding.', heard_in_search: 'Bob says, "Here!"')).to be_truthy
      end

      it 'leaves a room where a hidden buddy is found, with avoid_buddies' do
        expect(room_judged_empty?(say_echo: echo, avoid_buddies: true, search_finds: 'You notice Bob, who is hiding.', heard_in_search: 'Bob says, "Here!"')).to be false
      end

      it 'takes a room where a buddy answers, by default' do
        expect(room_judged_empty?(say_echo: echo, heard: 'Bob says, "Come on in."')).to be true
      end

      it 'leaves a room where a buddy answers, with avoid_buddies' do
        expect(room_judged_empty?(say_echo: echo, heard: 'Bob says, "Come on in."', avoid_buddies: true)).to be false
      end

      it 'still takes a room whose only other person is a buddy in your group, with avoid_buddies' do
        expect(room_judged_empty?(say_echo: echo, avoid_buddies: true, pcs: ['Bob'], group: ['Bob'])).to be true
      end
    end

    # Own echoes of the empty-room say: these must not mark the room occupied.
    # The preset lines are verbatim from a Saga-dialect capture (lich-5
    # spec/fixtures/streams/dr_saga_containers_speech.xml).
    [
      'You say, "Is anyone hunting here?"',
      'You politely say, "Is anyone hunting here?"',
      'You ask, "Is anyone hunting here?"',
      %(<pushStream id="talk"/><preset id='speech'>You politely say</preset>, "Hello."),
      %(<popStream/><preset id='speech'>You politely say</preset>, "Hello."),
      %(<preset id='speech'>You say, "Is anyone hunting here?"</preset>)
    ].each do |echo|
      it "does not treat its own echo as someone else speaking: #{echo}" do
        expect(room_judged_empty?(say_echo: echo)).to be true
      end
    end

    # Someone else talking: the room is taken.
    [
      'Bob says, "I am."',
      'Bob politely says, "I am."',
      'Bob asks, "Who is there?"',
      'Bob exclaims, "Mine!"',
      'Bob says to you, "Go away."',
      'Someone says, "boo"',
      %(<pushStream id="talk"/><preset id='speech'><a exist="-10700003" noun="Delphine">Delphine</a> politely says</preset>, "Hello."),
      %(<popStream/><preset id='speech'><a exist="-10700003" noun="Delphine">Delphine</a> politely says</preset>, "Hello.")
    ].each do |answer|
      it "leaves the room when someone else speaks: #{answer}" do
        expect(room_judged_empty?(say_echo: 'You say, "Is anyone hunting here?"', heard: answer)).to be false
      end
    end
  end

  # ===========================================================================
  # 'during' scripts are stopped when hunting-buddy dies mid-hunt
  # ===========================================================================

  describe '.on_death' do
    let(:buddy) { HuntingBuddy.allocate }
    let(:stopped) { [] }

    before do
      allow(DRC).to receive(:message)
      allow(buddy).to receive(:start_script)
      allow(buddy).to receive(:stop_script) { |name| stopped << name }
      allow(HuntingBuddy).to receive(:stop_script) { |name| stopped << name }
      allow(HuntingBuddy).to receive(:fput)
      allow(HuntingBuddy).to receive(:get_settings).and_return(OpenStruct.new(cyclic_no_release: []))
      allow(DRCA).to receive(:release_cyclics)
      # Report every script as running, so only hunting-buddy's own record of
      # what it started decides what gets stopped.
      allow(Script).to receive(:running?).and_return(true)
    end

    it 'stops the during scripts of a hunt that is still running' do
      buddy.execute_nonblocking_actions(['tendme', 'performance fast'])

      HuntingBuddy.on_death(buddy)

      expect(stopped).to include('tendme', 'performance')
    end

    it 'does not stop during scripts again after the hunt already stopped them' do
      buddy.execute_nonblocking_actions(['performance fast'])
      buddy.stop_actions(['performance fast'])
      stopped.clear

      HuntingBuddy.on_death(buddy)

      expect(stopped).to eq(['combat-trainer'])
    end

    it 'stops combat-trainer and cleans up when hunting-buddy died while starting up' do
      Flags.add('hunting-buddy-room-check', /x/)

      expect { HuntingBuddy.on_death(nil) }.not_to raise_error

      expect(stopped).to eq(['combat-trainer'])
      expect(Flags.flags.keys).not_to include('hunting-buddy-room-check')
    end

    it 'gives plugins their cleanup hook' do
      plugin = Object.new
      seen = []
      plugin.define_singleton_method(:cleanup) { |b| seen << b }
      HuntingBuddy.register_plugin(plugin)

      HuntingBuddy.on_death(buddy)

      expect(seen).to eq([buddy])
    ensure
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])
    end
  end

  # ===========================================================================
  # hunt: plugin lifecycle hooks and the stop reason
  # ===========================================================================

  describe '#hunt lifecycle' do
    let(:buddy) { HuntingBuddy.allocate }
    let(:calls) { [] }

    # Stand-in for combat-trainer's $COMBAT_TRAINER: running until stopped.
    let(:combat_trainer) do
      Class.new do
        def running = !@stopped
        def stop = (@stopped = true)
      end.new
    end

    before do
      buddy.instance_variable_set(:@settings, OpenStruct.new(health_threshold: 0, stop_hunting_if_bleeding: false))
      buddy.instance_variable_set(:@stop_on_familiar_drag, false)
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: 100))
      allow(DRC).to receive(:message)
      allow(DRC).to receive(:verify_script).and_return(true)
      allow(DRC).to receive(:retreat)
      allow(DRStats).to receive(:health).and_return(100)
      allow(Script).to receive(:running?).and_return(false)
      allow(buddy).to receive(:start_script) { $COMBAT_TRAINER = combat_trainer }
      allow(buddy).to receive(:pause)
      allow(buddy).to receive(:clear)
      allow(buddy).to receive(:fput)
      allow(buddy).to receive(:encumbered?).and_return(false)
    end

    after do
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])
      $COMBAT_TRAINER = nil
    end

    def register(plugin_class)
      HuntingBuddy.register_plugin(plugin_class.new(calls))
    end

    it 'turns room descriptions off for the hunt and back on after, from the plan' do
      sent = []
      allow(buddy).to receive(:fput) { |command| sent << command }
      register(Class.new do
        def initialize(calls) = (@calls = calls)
        def hunt_tick(*) = :break
      end)

      buddy.hunt(HuntingBuddy::HuntPlan.new(args: [], duration: 30, disable_room_descriptions: true))

      expect(sent).to include('flag description off', 'flag description on')
      expect(buddy.instance_variable_get(:@disable_room_descriptions)).to be true
    end

    it 'fires after_hunt with counter 0 when a before_hunt plugin calls the hunt off' do
      register(Class.new do
        def initialize(calls) = (@calls = calls)
        def before_hunt(buddy, hunting_room:) = (@calls << [:before_hunt, hunting_room]) && buddy.stop_hunting
        def after_hunt(_buddy, hunting_room:, counter:) = @calls << [:after_hunt, hunting_room, counter]
      end)

      buddy.hunt(HuntingBuddy::HuntPlan.new(args: [], duration: 30))

      expect(calls).to eq([[:before_hunt, 100], [:after_hunt, 100, 0]])
      expect(buddy).not_to have_received(:start_script)
    end

    it 'reports :manual_stop, not the previous hunt\'s reason, when the hunt is called off early' do
      buddy.hunt_stop_reason = :duration
      buddy.stop_hunting

      buddy.hunt(HuntingBuddy::HuntPlan.new(args: [], duration: 30))

      expect(buddy.hunt_stop_reason).to eq(:manual_stop)
    end

    it 'reports :too_injured when the room search found you too injured to search' do
      reasons = []
      register(Class.new do
        def initialize(calls) = (@calls = calls)
        def after_hunt(buddy, counter:, **) = @calls << [:after_hunt, counter, buddy.hunt_stop_reason]
      end)
      buddy.instance_variable_set(:@settings, OpenStruct.new(custom_hunting_zones: {}, hunting_buddies: [], hunting_nemesis: [],
                                                             health_threshold: 0, stop_hunting_if_bleeding: false,
                                                             hunting_room_min_mana: 0, hunting_room_strict_mana: false, hunting_room_max_searches: 30))
      buddy.instance_variable_set(:@hunting_zones, { 'rats' => [1] })
      buddy.instance_variable_set(:@escort_zones, {})
      buddy.instance_variable_set(:@hunting_buddies_max, 2)
      DRRoom.pcs = []
      DRRoom.group_members = []
      allow(buddy).to receive(:bleeding?).and_return(false)
      allow(DRC).to receive(:bput).with('search', any_args).and_return("You're not in any condition to be searching around")
      allow(DRCT).to receive(:find_empty_room) { |_rooms, _idle, predicate, *_rest| predicate.call(1) }

      buddy.find_hunting_room?(['rats'], 851)
      buddy.hunt(HuntingBuddy::HuntPlan.new(args: [], duration: 30))
      reasons << buddy.hunt_stop_reason

      expect(calls).to eq([[:after_hunt, 0, :too_injured]])
      expect(reasons).to eq([:too_injured])
    end

    it 'clears the previous hunt\'s reason when a plugin ends the hunt with :break' do
      register(Class.new do
        def initialize(calls) = (@calls = calls)
        def hunt_tick(*) = :break
      end)
      buddy.hunt_stop_reason = :duration

      buddy.hunt(HuntingBuddy::HuntPlan.new(args: [], duration: 30))

      expect(buddy.hunt_stop_reason).to be_nil
    end
  end

  # ===========================================================================
  # find_hunting_room?: the :zone: list is a priority order
  # ===========================================================================

  describe '#find_hunting_room? zone order' do
    let(:buddy) { HuntingBuddy.allocate }
    let(:echoes) { [] }
    let(:searched) { [] }
    let(:escorted) { [] }

    def search_result(result)
      allow(DRCT).to receive(:find_empty_room) do |rooms, *_rest|
        searched << rooms
        result
      end
    end

    before do
      buddy.instance_variable_set(:@settings, OpenStruct.new(
                                                custom_hunting_zones: { 'my_rats' => [7, 8] },
                                                hunting_buddies: [], hunting_nemesis: [],
                                                hunting_room_min_mana: 0, hunting_room_strict_mana: false, hunting_room_max_searches: 30
                                              ))
      buddy.instance_variable_set(:@hunting_zones, { 'rats' => [1, 2], 'goblins' => [3, 4] })
      buddy.instance_variable_set(:@escort_zones, { 'ship' => { 'base' => 9, 'area' => 'ship_area', 'enter' => 'board' } })
      allow(buddy).to receive(:echo) { |message| echoes << message }
      allow(DRC).to receive(:message)
      allow(DRCT).to receive(:walk_to)
      allow(DRC).to receive(:wait_for_script_to_complete) { |name, args| escorted << [name, args] }
    end

    it 'pools the ordinary zones into one search, in list order' do
      search_result(true)

      expect(buddy.find_hunting_room?(%w[rats goblins], 851)).to be true
      expect(searched).to eq([[1, 2, 3, 4]])
      expect(escorted).to be_empty
    end

    it 'falls back to an escort zone only when the ordinary zones had no room' do
      search_result(false)

      expect(buddy.find_hunting_room?(%w[rats goblins ship], 851)).to be true
      expect(searched).to eq([[1, 2, 3, 4]])
      expect(escorted).to eq([['bescort', %w[ship_area board]]])
      expect(buddy.instance_variable_get(:@exit)).to eq(%w[ship_area exit])
      expect(echoes).not_to include('Unable to find hunting zone: ship')
    end

    it 'still searches ordinary zones listed after the escort zone' do
      search_result(true)

      expect(buddy.find_hunting_room?(%w[rats ship goblins], 851)).to be true
      expect(searched).to eq([[1, 2, 3, 4]])
      expect(escorted).to be_empty
      expect(buddy.instance_variable_get(:@exit)).to be_nil
    end

    it 'enters a leading escort zone without searching the zones after it' do
      search_result(true)

      expect(buddy.find_hunting_room?(%w[ship rats], 851)).to be true
      expect(searched).to be_empty
      expect(escorted).to eq([['bescort', %w[ship_area board]]])
    end

    it 'goes straight to the escort zone when the ordinary zones are unknown' do
      search_result(true)

      expect(buddy.find_hunting_room?(%w[nowhere ship], 851)).to be true
      expect(searched).to be_empty
      expect(echoes).to include('Unable to find hunting zone: nowhere')
    end

    it 'uses a custom_hunting_zones entry in place of the base zone' do
      search_result(true)

      buddy.find_hunting_room?(%w[my_rats goblins], 851)

      expect(searched).to eq([[7, 8, 3, 4]])
    end

    it 'treats a custom zone named like an escort zone as the custom zone' do
      buddy.instance_variable_get(:@settings).custom_hunting_zones['ship'] = [5, 6]
      search_result(true)

      expect(buddy.find_hunting_room?(%w[ship], 851)).to be true
      expect(searched).to eq([[5, 6]])
      expect(escorted).to be_empty
    end

    it 'exits when no zone in the list has any rooms' do
      search_result(true)

      expect { buddy.find_hunting_room?(%w[nowhere], 851) }.to raise_error(SystemExit)
      expect(searched).to be_empty
    end

    it 'skips the hunt, without exiting, when the :zone: list is empty' do
      search_result(true)

      expect(buddy.find_hunting_room?([], 851)).to be false
      expect(searched).to be_empty
    end

    it 'reports a failed search when there is no escort zone to fall back on' do
      search_result(false)

      expect(buddy.find_hunting_room?(%w[rats], 851)).to be false
    end

    it 'forgets the previous hunt\'s escort zone when a plugin finds the room' do
      plugin = Object.new
      plugin.define_singleton_method(:find_room) { |*_| true }
      buddy.instance_variable_set(:@exit, %w[ship_area exit])
      HuntingBuddy.register_plugin(plugin)

      expect(buddy.find_hunting_room?(%w[rats], 851)).to be true
      expect(buddy.instance_variable_get(:@exit)).to be_nil
    ensure
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])
    end
  end

  # ===========================================================================
  # current_hunting_zone
  # ===========================================================================

  describe '#current_hunting_zone' do
    let(:buddy) { HuntingBuddy.allocate }

    before do
      buddy.instance_variable_set(:@hunting_zones, { 'rats' => [1, 2], 'goblins' => [3, 4] })
      buddy.instance_variable_set(:@settings, OpenStruct.new(custom_hunting_zones: { 'my_spot' => [500, 501], 'goblins' => [600] }))
    end

    it 'names the base-hunting.yaml zone the room belongs to' do
      expect(buddy.current_hunting_zone(2)).to eq('rats')
    end

    it 'names the custom_hunting_zones zone the room belongs to' do
      expect(buddy.current_hunting_zone(501)).to eq('my_spot')
    end

    it 'uses the custom rooms, not the base rooms, for a zone the custom list overrides' do
      expect(buddy.current_hunting_zone(600)).to eq('goblins')
      expect(buddy.current_hunting_zone(3)).to be_nil
    end

    it 'returns nil for a room in no zone' do
      expect(buddy.current_hunting_zone(9999)).to be_nil
    end

    it 'works when custom_hunting_zones is not set' do
      buddy.instance_variable_set(:@settings, OpenStruct.new(custom_hunting_zones: nil))

      expect(buddy.current_hunting_zone(3)).to eq('goblins')
    end
  end

  # ===========================================================================
  # main: staying in the room between hunts in the same zone
  # ===========================================================================

  describe '#main room search between hunts' do
    let(:buddy) { HuntingBuddy.allocate }

    # Runs two identical hunts while standing in `room` and returns how many
    # times hunting-buddy searched for a room (1 means it stayed for hunt 2).
    def searches_for(zones, room, custom, base_zones = { 'rats' => [1, 2], 'brewery' => [3, 4], 'brewery_alias' => [3, 4] })
      buddy.instance_variable_set(:@hunting_zones, base_zones)
      buddy.instance_variable_set(:@escort_zones, {})
      buddy.instance_variable_set(:@settings, OpenStruct.new(custom_hunting_zones: custom, sell_loot_skip_bank: true, safe_room: 1, cyclic_no_release: []))
      info = { :zone => zones, 'args' => [], 'before' => [], 'after' => [], 'during' => [] }
      buddy.instance_variable_set(:@hunting_info, [info.dup, info.dup])
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: room))
      %i[check_bundling_rope check_prehunt_buffs hunt execute_actions execute_nonblocking_actions stop_actions].each { |m| allow(buddy).to receive(m) }
      allow(buddy).to receive_messages(encumbered?: false, should_stop_for_high_skills?: false, should_stop_for_low_skills?: false)
      allow(DRC).to receive(:bput).and_return('Stow what?')
      allow(DRC).to receive(:message)
      allow(DRC).to receive_messages(right_hand: nil, left_hand: nil)
      allow(DRCA).to receive(:release_cyclics)
      allow(DRCT).to receive(:walk_to)
      allow(EquipmentManager).to receive(:new).and_return(double(wear_equipment_set?: true))
      count = 0
      allow(buddy).to receive(:find_hunting_room?) { count += 1 }
      buddy.main
      count
    end

    it 'stays in a custom zone room' do
      expect(searches_for(['my_spot'], 500, { 'my_spot' => [500] })).to eq(1)
    end

    it 'stays in a base zone room that a differently named custom zone also lists' do
      expect(searches_for(['brewery'], 3, { 'my_brewery' => [3] })).to eq(1)
    end

    it 'stays in a room that belongs to two base zones, whichever the hunt names' do
      expect(searches_for(['brewery_alias'], 3, {})).to eq(1)
      expect(searches_for(['brewery'], 3, {})).to eq(1)
    end

    it 'uses the base rooms for a custom entry with no rooms' do
      expect(searches_for(['brewery'], 3, { 'brewery' => nil })).to eq(1)
    end

    it 'stays when two custom zones overlap and the hunt names the second' do
      expect(searches_for(['spot_b'], 500, { 'spot_a' => [500, 501], 'spot_b' => [500] })).to eq(1)
    end

    it 'searches again when the next hunt is in a zone you are not in' do
      expect(searches_for(['rats'], 3, {})).to eq(2)
    end
  end

  # ===========================================================================
  # Learning-rate thresholds behind stop_on / stop_on_low
  # ===========================================================================

  describe 'low learning-rate threshold' do
    let(:buddy) { HuntingBuddy.allocate }
    let(:skills) { %w[Locksmithing Forging Outfitting] }

    before do
      buddy.instance_variable_set(:@stop_on_low_threshold, 2)
      allow(DRSkill).to receive(:getskillset).and_return('Lore')
      allow(DRSkill).to receive(:getxp) { |skill| { 'Locksmithing' => 1, 'Forging' => 12, 'Outfitting' => 2 }.fetch(skill) }
    end

    it 'stops when any listed skill is at or below the threshold' do
      expect(buddy.should_stop_for_low_skills?(skills)).to be true
    end

    it 'names only the skills that dropped when the hunt loop stops for them' do
      messages = []
      buddy.instance_variable_set(:@settings, OpenStruct.new(health_threshold: 0, stop_hunting_if_bleeding: false))
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: 100))
      allow(DRC).to receive(:message) { |message| messages << message }
      allow(DRC).to receive(:verify_script).and_return(true)
      allow(DRC).to receive(:retreat)
      allow(DRStats).to receive(:health).and_return(100)
      allow(Script).to receive(:running?).and_return(false)
      allow(buddy).to receive(:start_script) { $COMBAT_TRAINER = Class.new { def running = !@stopped; def stop = (@stopped = true) }.new }
      allow(buddy).to receive_messages(pause: nil, clear: nil, fput: nil, yiamura_all_done?: true)

      buddy.hunt(HuntingBuddy::HuntPlan.new(args: [], stop_on_low_skills: [skills]))

      expect(messages).to include('***STATUS*** Stopping because skills dropped below learning threshold: Locksmithing, Outfitting')
    ensure
      $COMBAT_TRAINER = nil
    end
  end

  describe '#main skipping a hunt for its skills' do
    let(:buddy) { HuntingBuddy.allocate }
    let(:messages) { [] }

    def run_main(info)
      buddy.instance_variable_set(:@settings, OpenStruct.new(sell_loot_skip_bank: true, safe_room: 1, cyclic_no_release: []))
      buddy.instance_variable_set(:@hunting_info, [{ :zone => 'rats', 'args' => [], 'before' => [], 'after' => [], 'during' => [] }.merge(info)])
      buddy.instance_variable_set(:@stop_on_low_threshold, 2)
      buddy.instance_variable_set(:@stop_on_high_threshold, 32)
      %i[check_bundling_rope check_prehunt_buffs hunt find_hunting_room? execute_actions stop_actions].each { |m| allow(buddy).to receive(m) }
      allow(buddy).to receive(:encumbered?).and_return(false)
      allow(DRC).to receive(:message) { |message| messages << message }
      allow(DRCT).to receive(:walk_to)
      allow(EquipmentManager).to receive(:new).and_return(double(wear_equipment_set?: true))
      allow(DRSkill).to receive(:getskillset).and_return('Lore')
      allow(DRSkill).to receive(:getxp) { |skill| { 'Locksmithing' => 1, 'Forging' => 12, 'Evasion' => 34, 'Parry Ability' => 33 }.fetch(skill) }
      buddy.main
    end

    it 'names only the stop_on_low skills that dropped' do
      run_main('stop_on_low' => %w[Locksmithing Forging])

      expect(messages).to include('***STATUS*** Skipping hunt because skills dropped below learning threshold: Locksmithing')
      expect(buddy).not_to have_received(:hunt)
    end

    it 'lists the stop_on skills as plain text' do
      run_main('stop_on' => ['Evasion', 'Parry Ability'])

      expect(messages).to include('***STATUS*** Skipping hunt because skills reached learning threshold: Evasion, Parry Ability')
    end
  end

  describe 'high learning-rate threshold' do
    let(:buddy) { HuntingBuddy.allocate }
    let(:skills) { ['Small Edged', 'Parry Ability'] }

    before do
      buddy.instance_variable_set(:@stop_on_high_threshold, 32)
      allow(DRSkill).to receive(:getskillset).and_return('Weapon')
    end

    def learning(rates)
      allow(DRSkill).to receive(:getxp) { |skill| rates.fetch(skill) }
    end

    it 'counts a skill sitting exactly at the threshold as done for the stop check' do
      learning('Small Edged' => 32, 'Parry Ability' => 32)

      expect(buddy.should_stop_for_high_skills?(skills)).to be true
    end

    it 'keeps hunting while any listed skill is below the threshold' do
      learning('Small Edged' => 32, 'Parry Ability' => 10)

      expect(buddy.should_stop_for_high_skills?(skills)).to be false
    end

    it 'lists only the skills still below the threshold as being waited on' do
      learning('Small Edged' => 32, 'Parry Ability' => 10)

      expect(buddy.get_skills_below_high_threshold(skills)).to eq(['Parry Ability'])
    end

    it 'leaves "waiting on" out of the status line when no skill is still short' do
      learning('Small Edged' => 34, 'Parry Ability' => 32)
      messages = []
      buddy.instance_variable_set(:@settings, OpenStruct.new(health_threshold: 0, stop_hunting_if_bleeding: false))
      allow(Room).to receive(:current).and_return(OpenStruct.new(id: 100))
      allow(DRC).to receive(:message) { |message| messages << message }
      allow(DRC).to receive(:verify_script).and_return(true)
      allow(DRC).to receive(:retreat)
      allow(DRStats).to receive(:health).and_return(100)
      allow(Script).to receive(:running?).and_return(false)
      allow(buddy).to receive(:start_script) { $COMBAT_TRAINER = Class.new { def running = !@stopped; def stop = (@stopped = true) }.new }
      # Skills are done but a raised yiamura keeps the hunt going.
      allow(buddy).to receive_messages(pause: nil, clear: nil, fput: nil, encumbered?: false, yiamura_all_done?: false)
      stopper = Object.new
      stopper.define_singleton_method(:hunt_tick) { |_buddy, counter:| :break if counter.positive? }
      HuntingBuddy.register_plugin(stopper)

      buddy.hunt(HuntingBuddy::HuntPlan.new(args: [], duration: 30, stop_on_high_skills: skills))
      buddy.hunt(HuntingBuddy::HuntPlan.new(args: [], stop_on_high_skills: skills))

      expect(messages).to include('***STATUS*** 30 minutes of hunting remaining', '***STATUS*** 0 minutes of hunting')
      expect(messages.grep(/waiting on/)).to be_empty
    ensure
      HuntingBuddy.instance_variable_set(:@registered_plugins, [])
      $COMBAT_TRAINER = nil
    end

    it 'waits on nothing once the stop check is satisfied' do
      learning('Small Edged' => 34, 'Parry Ability' => 32)

      expect(buddy.get_skills_below_high_threshold(skills)).to be_empty
    end
  end

  # ===========================================================================
  # main: the per-hunt sequence (characterization)
  # ===========================================================================

  describe '#main' do
    let(:buddy) { HuntingBuddy.allocate }
    let(:events) { [] }
    let(:running) { [] }

    def hunt_info(overrides = {})
      { :zone => 'rats', :duration => 30, 'args' => ['a'], 'before' => ['prep'], 'after' => ['wrapup x'], 'during' => ['tendme'] }.merge(overrides)
    end

    def run_main(*infos)
      buddy.instance_variable_set(:@hunting_info, infos)
      buddy.main
    end

    before do
      buddy.instance_variable_set(:@settings, OpenStruct.new(sell_loot_skip_bank: true, safe_room: 851, cyclic_no_release: []))
      allow(buddy).to receive(:check_bundling_rope)
      allow(buddy).to receive(:check_prehunt_buffs)
      allow(buddy).to receive_messages(need_boxes?: true, encumbered?: false, in_hunting_zone?: true)
      allow(buddy).to receive(:find_hunting_room?) { |zones, *_| events << [:find_room, zones] && true }
      allow(buddy).to receive(:hunt) { |plan| events << [:hunt, plan.args] }
      allow(buddy).to receive(:start_script) { |name, _args| events << [:start, name] && running << name }
      allow(buddy).to receive(:stop_script) { |name| events << [:stop, name] && running.delete(name) }
      allow(Script).to receive(:running?) { |name| running.include?(name) }
      allow(DRC).to receive(:wait_for_script_to_complete) { |name, args = []| events << [:run, name, args] }
      allow(DRC).to receive(:message) { |message| events << [:message, message] }
      allow(DRC).to receive(:retreat) { events << [:retreat] }
      allow(DRC).to receive(:bput).with('stow feet', any_args).and_return('Stow what?')
      allow(DRC).to receive_messages(right_hand: nil, left_hand: nil)
      allow(DRCA).to receive(:release_cyclics)
      allow(DRCMM).to receive(:moons_visible?).and_return(true)
      allow(DRCT).to receive(:walk_to)
      allow(EquipmentManager).to receive(:new).and_return(double(wear_equipment_set?: true))
    end

    def without_messages = events.reject { |event| event.first == :message }

    it 'runs before, finds a room, runs during around the hunt, then after' do
      run_main(hunt_info)

      expect(without_messages).to eq([
                                       [:run, 'prep', []], [:find_room, ['rats']], [:start, 'tendme'],
                                       [:hunt, ['a']], [:stop, 'tendme'], [:run, 'wrapup', ['x']]
                                     ])
    end

    it 'skips the room search for a later hunt that starts in the zone you are already in' do
      run_main(hunt_info, hunt_info('args' => ['b']))

      expect(events.count { |event| event.first == :find_room }).to eq(1)
      expect(events).to include([:hunt, ['b']])
    end

    it 'skips a boxes hunt without running any actions when you have enough boxes' do
      allow(buddy).to receive(:need_boxes?).and_return(false)

      run_main(hunt_info('boxes' => true))

      expect(without_messages).to be_empty
      expect(events).to include([:message, '***STATUS*** Skipping hunt because have enough boxes'])
    end

    it 'runs before and after, but not the hunt, when there are no moons' do
      allow(DRCMM).to receive(:moons_visible?).and_return(false)

      run_main(hunt_info('moons' => true))

      expect(without_messages).to eq([[:run, 'prep', []], [:run, 'wrapup', ['x']]])
    end

    it 'runs before and after, but not the hunt, when too encumbered' do
      allow(buddy).to receive(:encumbered?).and_return(true)

      run_main(hunt_info('stop_on_encumbrance' => 3))

      expect(without_messages).to eq([[:run, 'prep', []], [:run, 'wrapup', ['x']]])
    end

    it 'runs before but not after when no hunting room is found' do
      allow(buddy).to receive(:find_hunting_room?).and_return(false)

      run_main(hunt_info)

      expect(without_messages).to eq([[:run, 'prep', []]])
    end

    it 'stops all hunting, running after, when stop_hunting was called during an earlier hunt' do
      allow(buddy).to receive(:hunt) { |plan| events << [:hunt, plan.args] && buddy.stop_hunting }

      run_main(hunt_info, hunt_info('args' => ['b'], 'after' => ['second-after']))

      expect(events).not_to include([:hunt, ['b']])
      expect(events).to include([:message, '***STATUS*** Stopping all hunting because manual intervention'])
      expect(events.last(4)).to include([:run, 'second-after', []])
    end

    it 'retreats, stops tendme and runs the next hunt\'s after scripts when a hunt ended bleeding' do
      allow(buddy).to receive(:hunt) { |plan| events << [:hunt, plan.args] && buddy.stopped_for_bleeding = true }
      running << 'tendme'

      run_main(hunt_info('during' => ['perf']), hunt_info('args' => ['b'], 'during' => ['second-during'], 'after' => ['second-after']))

      after_first = events.drop_while { |event| event != [:message, '***STATUS*** Stopping all hunting because bleeding'] }
      expect(after_first.reject { |e| e.first == :message }).to eq([[:retreat], [:stop, 'tendme'], [:run, 'second-after', []]])
      expect(events).not_to include([:hunt, ['b']])
      expect(events.count([:run, 'prep', []])).to eq(1)
    end

    it 'runs before and after, but not the hunt, when the stop_on skills are already done' do
      allow(buddy).to receive(:should_stop_for_high_skills?).and_return(true)

      run_main(hunt_info('stop_on' => ['Evasion']))

      expect(without_messages).to eq([[:run, 'prep', []], [:run, 'wrapup', ['x']]])
    end

    it 'runs before and after, but not the hunt, when a stop_on_low skill has dropped' do
      allow(buddy).to receive(:should_stop_for_low_skills?).and_return(true)
      allow(buddy).to receive(:get_skills_below_low_threshold).and_return(['Forging'])

      run_main(hunt_info('stop_on_low' => ['Forging']))

      expect(without_messages).to eq([[:run, 'prep', []], [:run, 'wrapup', ['x']]])
    end

    it 'restocks first unless sell_loot_skip_bank is set' do
      buddy.instance_variable_set(:@settings, OpenStruct.new(sell_loot_skip_bank: false, safe_room: 851, cyclic_no_release: []))

      run_main(hunt_info)

      expect(without_messages.first).to eq([:run, 'restock', []])
    end

    it 'casts prehunt buffs before looking for a room and releases cyclics after the hunt' do
      allow(buddy).to receive(:check_prehunt_buffs) { events << [:buffs] }
      allow(DRCA).to receive(:release_cyclics) { events << [:release] }

      run_main(hunt_info)

      expect(without_messages).to eq([
                                       [:run, 'prep', []], [:buffs], [:find_room, ['rats']], [:start, 'tendme'],
                                       [:hunt, ['a']], [:stop, 'tendme'], [:release], [:run, 'wrapup', ['x']]
                                     ])
    end

    it 'does not run a scalar action string, as before' do
      expect { run_main(hunt_info('before' => 'prep now')) }.to raise_error(NoMethodError)
    end

    it 'treats a hunt with no before, during or after keys as having none' do
      run_main({ :zone => 'rats', :duration => 30, 'args' => [] })

      expect(without_messages).to eq([[:find_room, ['rats']], [:hunt, []]])
    end

    it 'retreats and stops all hunting when the room search finds you bleeding' do
      allow(buddy).to receive(:find_hunting_room?) { buddy.stopped_for_bleeding = true }
      running << 'tendme'

      run_main(hunt_info('during' => ['perf']))

      expect(events).not_to include([:hunt, ['a']])
      expect(events.drop_while { |event| event != [:message, '***STATUS*** Stopping all hunting because bleeding'] }.reject { |e| e.first == :message })
        .to eq([[:retreat], [:stop, 'tendme'], [:run, 'wrapup', ['x']]])
      expect(without_messages).to eq([[:run, 'prep', []], [:retreat], [:stop, 'tendme'], [:run, 'wrapup', ['x']]])
    end

    it 'picks up everything at your feet after the hunt' do
      replies = ['You pick up a rock.', 'You pick up a stick.', 'Stow what?']
      allow(DRC).to receive(:bput).with('stow feet', any_args) { replies.shift }

      run_main(hunt_info)

      expect(DRC).to have_received(:bput).with('stow feet', any_args).exactly(3).times
    end

    it 'leaves an escort zone after the hunt' do
      allow(buddy).to receive(:find_hunting_room?) { buddy.instance_variable_set(:@exit, %w[ship_area exit]) }

      run_main(hunt_info)

      expect(events).to include([:run, 'bescort', %w[ship_area exit]])
    end

    it 'returns to the safe room and re-wears the combat gear set at the end' do
      gear = double(wear_equipment_set?: true)
      allow(EquipmentManager).to receive(:new).and_return(gear)

      run_main(hunt_info)

      expect(DRCT).to have_received(:walk_to).with(851)
      expect(gear).to have_received(:wear_equipment_set?).with('standard')
    end
  end

  # ===========================================================================
  # Smaller helpers
  # ===========================================================================

  describe '#encumbered?' do
    let(:buddy) { HuntingBuddy.allocate }

    it 'is false without a threshold, without checking encumbrance' do
      allow(DRC).to receive(:check_encumbrance)

      expect(buddy.encumbered?(nil)).to be false
      expect(DRC).not_to have_received(:check_encumbrance)
    end

    it 'is true at the threshold and false below it' do
      allow(DRC).to receive(:check_encumbrance).and_return(3)

      expect(buddy.encumbered?(3)).to be true
      expect(buddy.encumbered?(4)).to be false
    end

    it 'caps the threshold at 11' do
      allow(DRC).to receive(:check_encumbrance).and_return(11)

      expect(buddy.encumbered?(99)).to be true
    end
  end

  describe '#need_boxes?' do
    let(:buddy) { HuntingBuddy.allocate }

    it 'is true while the box count is at or below box_hunt_minimum' do
      buddy.instance_variable_set(:@settings, OpenStruct.new(box_hunt_minimum: 2))
      allow(DRCI).to receive(:count_all_boxes).and_return(2)

      expect(buddy.need_boxes?).to be true
    end

    it 'is false once the box count is above box_hunt_minimum' do
      buddy.instance_variable_set(:@settings, OpenStruct.new(box_hunt_minimum: 2))
      allow(DRCI).to receive(:count_all_boxes).and_return(3)

      expect(buddy.need_boxes?).to be false
    end

    it 'is false when box_hunt_minimum is blank' do
      buddy.instance_variable_set(:@settings, OpenStruct.new(box_hunt_minimum: nil))

      expect(buddy.need_boxes?).to be false
    end
  end

  describe '#yiamura_all_done?' do
    let(:buddy) { HuntingBuddy.allocate }

    before { allow(Map).to receive(:current).and_return(OpenStruct.new(id: 100)) }

    it 'is true when the yiamura was never raised' do
      UserVars.yiamura = nil

      expect(buddy.yiamura_all_done?).to be true
    end

    it 'is true when it was raised in another room' do
      UserVars.yiamura = { 'last_raised_room_id' => 5, 'last_raised' => Time.now }

      expect(buddy.yiamura_all_done?).to be true
    end

    it 'is false within ten minutes of raising it in this room' do
      UserVars.yiamura = { 'last_raised_room_id' => 100, 'last_raised' => Time.now - 60 }

      expect(buddy.yiamura_all_done?).to be false
    end

    it 'is true more than ten minutes after raising it in this room' do
      UserVars.yiamura = { 'last_raised_room_id' => 100, 'last_raised' => Time.now - 601 }

      expect(buddy.yiamura_all_done?).to be true
    end
  end

  describe '#execute_actions' do
    let(:buddy) { HuntingBuddy.allocate }

    it 'runs each action as a script name followed by its arguments' do
      allow(DRC).to receive(:message)
      allow(DRC).to receive(:wait_for_script_to_complete)

      buddy.execute_actions(['sell-loot', 'buff prehunt now'])

      expect(DRC).to have_received(:wait_for_script_to_complete).with('sell-loot', []).ordered
      expect(DRC).to have_received(:wait_for_script_to_complete).with('buff', %w[prehunt now]).ordered
    end
  end

  describe '#check_prehunt_buffs' do
    let(:buddy) { HuntingBuddy.allocate }

    before do
      buddy.instance_variable_set(:@prehunt_buff_waggle, 'prehunt_buffs')
      buddy.instance_variable_set(:@prehunt_buffing_room, 1234)
      allow(DRCT).to receive(:walk_to)
      allow(DRC).to receive(:wait_for_script_to_complete)
    end

    it 'walks to the buffing room and runs buff with the waggle set when it exists' do
      buddy.instance_variable_set(:@settings, OpenStruct.new(waggle_sets: { 'prehunt_buffs' => {} }))

      buddy.check_prehunt_buffs

      expect(DRCT).to have_received(:walk_to).with(1234)
      expect(DRC).to have_received(:wait_for_script_to_complete).with('buff', ['prehunt_buffs'])
    end

    it 'does nothing when the waggle set is missing' do
      buddy.instance_variable_set(:@settings, OpenStruct.new(waggle_sets: {}))

      buddy.check_prehunt_buffs

      expect(DRCT).not_to have_received(:walk_to)
    end
  end

  describe HuntingBuddy::HuntPlan do
    let(:settings) { OpenStruct.new(safe_room: 851, hunting_disable_room_descriptions: true) }

    it 'reads the boxes and moons aliases as well as the long names' do
      expect(described_class.from_info({ 'boxes' => true, 'moons' => true }, settings))
        .to have_attributes(stop_on_boxes: true, stop_on_no_moons: true)
      expect(described_class.from_info({ 'stop_on_boxes' => true, 'stop_on_moons' => true }, settings))
        .to have_attributes(stop_on_boxes: true, stop_on_no_moons: true)
    end

    it 'turns a single zone into a list and drops a missing one' do
      expect(described_class.from_info({ zone: 'rats' }, settings).hunting_zones).to eq(['rats'])
      expect(described_class.from_info({ zone: %w[rats goblins] }, settings).hunting_zones).to eq(%w[rats goblins])
      expect(described_class.from_info({}, settings).hunting_zones).to eq([])
    end

    it 'waits in safe_room unless full_waiting_room is given' do
      expect(described_class.from_info({}, settings).waiting_room).to eq(851)
      expect(described_class.from_info({ 'full_waiting_room' => 42 }, settings).waiting_room).to eq(42)
    end

    it 'lets a hunt override hunting_disable_room_descriptions, including with false' do
      expect(described_class.from_info({}, settings).disable_room_descriptions).to be true
      expect(described_class.from_info({ 'disable_room_descriptions' => false }, settings).disable_room_descriptions).to be false
    end

    it 'maps the remaining keys to their fields' do
      info = { :duration => 30, 'args' => ['x'], 'before' => ['b'], 'after' => ['a'], 'during' => ['d'],
               'stop_on' => ['Evasion'], 'stop_on_low' => ['Forging'], 'stop_on_encumbrance' => 3,
               'stop_on_burgle_cooldown' => true, 'prefer_buddies' => true, 'avoid_buddies' => false }

      expect(described_class.from_info(info, settings)).to have_attributes(
        duration: 30, args: ['x'], before_actions: ['b'], after_actions: ['a'], during_actions: ['d'],
        stop_on_high_skills: ['Evasion'], stop_on_low_skills: ['Forging'], stop_on_encumbrance: 3,
        stop_on_burgle_cooldown: true, prefer_buddies: true, avoid_buddies: false
      )
    end
  end
end
