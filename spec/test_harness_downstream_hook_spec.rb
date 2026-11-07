# frozen_string_literal: true

# Pins the harness DownstreamHook to lich-5's registry contract (adebeef0
# lib/common/hook_registry.rb and lib/common/downstreamhook.rb): add takes
# persist: and priority:, run calls hooks by descending priority and then
# registration order, and a bad priority is refused the way lich-5 refuses it.
# Scripts that register with a priority (textsubs at -100) rely on this order
# in their specs.
#
# Every hook proc here uses `next`, never `return`: a `return` in a proc made
# in an example body would unwind the example instead of handing on the line.
RSpec.describe 'test harness DownstreamHook' do
  hook_names = %w[harness-a harness-b harness-c harness-d]

  after { hook_names.each { |name| DownstreamHook.remove(name) } }

  # @param name [String] hook name, also appended to the line and to calls
  # @param calls [Array<String>] receives +name+ each time the hook runs
  # @return [Proc] a hook that records its call and tags the line
  def tagging_hook(name, calls)
    proc do |line|
      calls << name
      "#{line}|#{name}"
    end
  end

  describe 'run order' do
    it 'runs a priority -100 hook after a priority 0 hook registered later' do
      calls = []
      DownstreamHook.add('harness-a', tagging_hook('harness-a', calls), persist: false, priority: -100)
      DownstreamHook.add('harness-b', tagging_hook('harness-b', calls))

      expect(DownstreamHook.run('line')).to eq('line|harness-b|harness-a')
      expect(calls).to eq(%w[harness-b harness-a])
    end

    it 'keeps registration order between hooks of equal priority, explicit or default' do
      calls = []
      DownstreamHook.add('harness-c', tagging_hook('harness-c', calls))
      DownstreamHook.add('harness-a', tagging_hook('harness-a', calls), priority: 0)
      DownstreamHook.add('harness-b', tagging_hook('harness-b', calls))

      expect(DownstreamHook.run('line')).to eq('line|harness-c|harness-a|harness-b')
    end

    it 'keeps registration order inside each priority band, highest band first' do
      calls = []
      DownstreamHook.add('harness-a', tagging_hook('harness-a', calls), priority: -100)
      DownstreamHook.add('harness-b', tagging_hook('harness-b', calls), priority: 5)
      DownstreamHook.add('harness-c', tagging_hook('harness-c', calls), priority: -100)
      DownstreamHook.add('harness-d', tagging_hook('harness-d', calls), priority: 5)

      DownstreamHook.run('line')
      expect(calls).to eq(%w[harness-b harness-d harness-a harness-c])
    end

    it 'orders a fractional priority between its integer neighbours' do
      calls = []
      DownstreamHook.add('harness-a', tagging_hook('harness-a', calls), priority: -1)
      DownstreamHook.add('harness-b', tagging_hook('harness-b', calls), priority: -0.5)
      DownstreamHook.add('harness-c', tagging_hook('harness-c', calls))

      DownstreamHook.run('line')
      expect(calls).to eq(%w[harness-c harness-b harness-a])
    end

    it 'keeps the first position when a name is re-added at the same priority' do
      calls = []
      DownstreamHook.add('harness-a', tagging_hook('harness-a', calls))
      DownstreamHook.add('harness-b', tagging_hook('harness-b', calls))
      DownstreamHook.add('harness-a', proc { |line| calls << 'harness-a again'; "#{line}|again" })

      expect(DownstreamHook.run('line')).to eq('line|again|harness-b')
      expect(calls).to eq(['harness-a again', 'harness-b'])
    end

    it 'moves a re-added name to its new priority band' do
      calls = []
      DownstreamHook.add('harness-a', tagging_hook('harness-a', calls))
      DownstreamHook.add('harness-b', tagging_hook('harness-b', calls))
      DownstreamHook.add('harness-a', tagging_hook('harness-a', calls), priority: -100)

      DownstreamHook.run('line')
      expect(calls).to eq(%w[harness-b harness-a])
    end

    it 'lists names in registration order, not run order' do
      DownstreamHook.add('harness-a', proc { |line| line }, priority: -100)
      DownstreamHook.add('harness-b', proc { |line| line })

      names = DownstreamHook.list
      expect(names.index('harness-a')).to be < names.index('harness-b')
      expect(DownstreamHook.ordered_hook_names.index('harness-a'))
        .to be > DownstreamHook.ordered_hook_names.index('harness-b')
    end
  end

  describe 'registration' do
    it 'defaults a two-argument add to persist nil and priority 0' do
      action = proc { |line| line }
      expect(DownstreamHook.add('harness-a', action)).to be(action)
      expect(DownstreamHook._hook_persist).to include('harness-a' => nil)
      expect(DownstreamHook._hook_priorities).to include('harness-a' => 0)
    end

    it 'records persist: and priority: as given' do
      DownstreamHook.add('harness-a', proc { |line| line }, persist: false, priority: -100)
      DownstreamHook.add('harness-b', proc { |line| line }, persist: true, priority: 3)

      expect(DownstreamHook._hook_persist).to include('harness-a' => false, 'harness-b' => true)
      expect(DownstreamHook._hook_priorities).to include('harness-a' => -100, 'harness-b' => 3)
    end

    it 'forgets persist and priority on remove, so a re-add starts from the defaults' do
      DownstreamHook.add('harness-a', proc { |line| line }, persist: false, priority: -100)
      DownstreamHook.remove('harness-a')

      expect(DownstreamHook._hook_persist).not_to have_key('harness-a')
      expect(DownstreamHook._hook_priorities).not_to have_key('harness-a')
    end

    [nil, '1', Float::INFINITY, -Float::INFINITY, Float::NAN, Complex(1, 1)].each do |bad|
      it "refuses priority #{bad.inspect} with an echo and registers nothing" do
        expect(DownstreamHook.add('harness-a', proc { |line| line }, priority: bad)).to be(false)
        expect(DownstreamHook.list).not_to include('harness-a')
        expect(DownstreamHook._hook_priorities).not_to have_key('harness-a')
        expect(displayed_messages).to include(/DownstreamHook: priority must be a finite real Numeric/)
      end
    end

    it 'accepts a Rational priority' do
      expect(DownstreamHook.add('harness-a', proc { |line| line }, priority: Rational(-1, 2))).to be_a(Proc)
    end

    it 'refuses an action that is not a Proc' do
      expect(DownstreamHook.add('harness-a', 'not a proc', priority: 1)).to be(false)
      expect(DownstreamHook.list).not_to include('harness-a')
      expect(displayed_messages).to include('DownstreamHook: not a Proc (not a proc)')
    end
  end

  describe 'run' do
    it 'stops at a hook that drops the line, so lower-priority hooks never see it' do
      calls = []
      DownstreamHook.add('harness-a', tagging_hook('harness-a', calls), priority: -100)
      DownstreamHook.add('harness-b', proc { |_line| calls << 'harness-b' and nil })

      expect(DownstreamHook.run('line')).to be_nil
      expect(calls).to eq(['harness-b'])
    end

    it 'removes a hook that raises and passes the line on to the next one unchanged' do
      calls = []
      DownstreamHook.add('harness-a', tagging_hook('harness-a', calls), priority: -100)
      DownstreamHook.add('harness-b', proc { |_line| raise 'boom' })

      expect(DownstreamHook.run('line')).to eq('line|harness-a')
      expect(DownstreamHook.list).not_to include('harness-b')
      expect(displayed_messages).to include('--- Lich: DownstreamHook: boom')
    end

    it 'skips a hook that an earlier hook removed in the same pass' do
      calls = []
      DownstreamHook.add('harness-a', tagging_hook('harness-a', calls), priority: -100)
      DownstreamHook.add('harness-b', proc { |line| DownstreamHook.remove('harness-a') && "#{line}|harness-b" })

      expect(DownstreamHook.run('line')).to eq('line|harness-b')
      expect(calls).to be_empty
    end

    it 'hands each hook a copy, so a hook mutating its argument cannot change the caller line' do
      DownstreamHook.add('harness-a', proc { |line| line << '|mutated' })
      original = +'line'

      expect(DownstreamHook.run(original)).to eq('line|mutated')
      expect(original).to eq('line')
    end
  end
end
