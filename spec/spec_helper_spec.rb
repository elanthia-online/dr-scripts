# frozen_string_literal: true

require 'open3'
require 'tmpdir'

# Self-test of spec_helper's exit guard. RSpec does not rescue SystemExit, so
# without the guard an example whose code calls exit ends the whole run there,
# reporting "N examples, 0 failures" with status 0 and skipping the rest.
#
# The guard can only be seen from outside the run it protects, so this runs a
# probe spec in a child `bundle exec rspec` from the repo root: the same .rspec
# and spec_helper as the real suite, no copy of either.
RSpec.describe 'spec_helper exit guard' do
  probe = <<~RUBY
    RSpec.describe 'exit guard probe' do
      it 'exits bare' do
        exit 3
      end

      it 'asserts its exit' do
        expect { exit }.to raise_error(SystemExit)
      end

      it 'runs after the exit' do
        expect(1).to eq(1)
      end
    end
  RUBY

  before(:all) do
    Dir.mktmpdir('exit-guard') do |dir|
      path = File.join(dir, 'exit_guard_probe_spec.rb')
      File.write(path, probe)
      env = { 'COVERAGE' => nil }
      root = File.expand_path('..', __dir__)
      @output, status = Open3.capture2e(env, 'bundle', 'exec', 'rspec', '--no-color', path, chdir: root)
      @exitstatus = status.exitstatus
    end
  end

  it 'runs every example after one that calls exit' do
    expect(@output).to include('3 examples, 1 failure')
  end

  it 'fails the run instead of exiting 0' do
    expect(@exitstatus).to eq(1)
  end

  it 'fails only the example that called exit' do
    failed = @output.lines.grep(/^rspec /)
    expect(failed.map { |l| l.split(' # ').last.strip }).to eq(['exit guard probe exits bare'])
  end

  it 'says the code under test called exit, with its status, and how to assert it' do
    expect(@output).to include('called exit (status 3)')
    expect(@output).to include('raise_error(SystemExit)')
  end
end
