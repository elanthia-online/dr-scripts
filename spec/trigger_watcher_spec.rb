# frozen_string_literal: true

# Test suite for trigger-watcher.lic
#
# trigger-watcher.lic is class-less: its trigger commands are top-level defs,
# followed by a main loop that needs the full Lich runtime. The defs under test
# are extracted with load_lic_methods (spec_helper.rb), which wraps them in a
# module without running the main loop.

TriggerWatcherMethods = load_lic_methods(
  'trigger-watcher.lic',
  'parse_enclosing_curly_braces',
  'execute_pause'
)

RSpec.describe 'trigger-watcher.lic' do
  describe '=pause' do
    # Mirrors the main loop's handling of a `=pause` response line.
    def run_pause_response(response)
      exec_pause = response.gsub('=pause', '').strip
      exec_pause = TriggerWatcherMethods.parse_enclosing_curly_braces(exec_pause)
      TriggerWatcherMethods.execute_pause(exec_pause)
    end

    before do
      $debug_mode_tw = false
      allow(TriggerWatcherMethods).to receive(:pause)
      allow(DRC).to receive(:message)
    end

    after do
      $debug_mode_tw = nil
    end

    context 'with a whole number of seconds' do
      it 'pauses for every digit of a two-digit number, not just the first' do
        run_pause_response('=pause {10}')

        expect(TriggerWatcherMethods).to have_received(:pause).with(10)
      end

      it 'pauses for 30 seconds when asked for 30' do
        run_pause_response('=pause {30}')

        expect(TriggerWatcherMethods).to have_received(:pause).with(30)
      end

      it 'still pauses for a single-digit number' do
        run_pause_response('=pause {5}')

        expect(TriggerWatcherMethods).to have_received(:pause).with(5)
      end

      it 'ignores spaces inside the braces' do
        run_pause_response('=pause { 10 }')

        expect(TriggerWatcherMethods).to have_received(:pause).with(10)
      end

      it 'tells the player the same number of seconds it pauses for' do
        run_pause_response('=pause {10}')

        expect(DRC).to have_received(:message).with('  Pausing 10 seconds.')
        expect(TriggerWatcherMethods).to have_received(:pause).with(10)
      end

      it 'echoes the full number in debug mode' do
        $debug_mode_tw = true

        run_pause_response('=pause {10}')

        expect(displayed_messages).to include('Pausing 10 seconds')
      end
    end

    context 'with a decimal number of seconds' do
      it 'pauses for the fractional amount' do
        run_pause_response('=pause {2.5}')

        expect(TriggerWatcherMethods).to have_received(:pause).with(2.5)
        expect(DRC).to have_received(:message).with('  Pausing 2.5 seconds.')
      end
    end

    context 'with a value that is not a number of seconds' do
      shared_examples 'a rejected pause' do |response, shown_value|
        it "does not pause for #{response}" do
          run_pause_response(response)

          expect(TriggerWatcherMethods).not_to have_received(:pause)
        end

        it "says why it did not pause for #{response}" do
          run_pause_response(response)

          expect(DRC).to have_received(:message)
            .with("  =pause needs a number of seconds, like =pause {10}. Got '#{shown_value}', so not pausing.")
          expect(DRC).not_to have_received(:message).with(/Pausing/)
        end
      end

      it_behaves_like 'a rejected pause', '=pause {soon}', 'soon'
      it_behaves_like 'a rejected pause', '=pause {}', ''
      it_behaves_like 'a rejected pause', '=pause {-5}', '-5'
      it_behaves_like 'a rejected pause', '=pause {5 seconds}', '5 seconds'
      # A UserVar that isn't set is left in the response as written.
      it_behaves_like 'a rejected pause', '=pause {$PauseTime}', '$PauseTime'
    end
  end
end
