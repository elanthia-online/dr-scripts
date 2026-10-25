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
  'execute_pause',
  'execute_script',
  'execute_uservar',
  'execute_logf',
  'execute_logw',
  'execute_if',
  'execute_eval',
  'execute_script_wait',
  'substitute_captures',
  'warn_capture_not_substituted',
  'apply_captures',
  'exec_arguments'
)

# The script's main loop: top-level code from `until script.gets.nil?` to the end of the file,
# which load_lic_methods can't extract. fire_trigger below runs it as written.
TRIGGER_WATCHER_LINES = File.readlines(lic_path('trigger-watcher.lic'))
TRIGGER_WATCHER_MAIN_LOOP_START = TRIGGER_WATCHER_LINES.index { |l| l.start_with?('until script.gets.nil?') }
TRIGGER_WATCHER_MAIN_LOOP = TRIGGER_WATCHER_LINES[TRIGGER_WATCHER_MAIN_LOOP_START..].join

RSpec.describe 'trigger-watcher.lic' do
  describe '=pause' do
    # A copy of the three statements in the main loop's `elsif string =~ /^=pause\b/i`
    # branch. The main loop is top-level code that load_lic_methods can't extract,
    # so the 'still matches the main loop' example below fails if the two drift apart.
    def run_pause_response(response)
      exec_pause = response.gsub('=pause', '').strip
      exec_pause = TriggerWatcherMethods.parse_enclosing_curly_braces(exec_pause)
      TriggerWatcherMethods.execute_pause(exec_pause)
    end

    it 'still matches the main loop =pause branch that run_pause_response copies' do
      main_loop_branch = Regexp.new(
        [
          "exec_pause = string.gsub('=pause', '').strip",
          'exec_pause = parse_enclosing_curly_braces(exec_pause)',
          'execute_pause(exec_pause)'
        ].map { |statement| Regexp.escape(statement) }.join('\s+')
      )

      expect(File.read(lic_path('trigger-watcher.lic'))).to match(main_loop_branch)
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

        expect(TriggerWatcherMethods).to have_received(:pause).with(10.0)
      end

      it 'pauses for 30 seconds when asked for 30' do
        run_pause_response('=pause {30}')

        expect(TriggerWatcherMethods).to have_received(:pause).with(30.0)
      end

      it 'still pauses for a single-digit number' do
        run_pause_response('=pause {5}')

        expect(TriggerWatcherMethods).to have_received(:pause).with(5.0)
      end

      it 'ignores spaces inside the braces' do
        run_pause_response('=pause { 10 }')

        expect(TriggerWatcherMethods).to have_received(:pause).with(10.0)
      end

      it 'tells the player the same number of seconds it pauses for' do
        run_pause_response('=pause {10}')

        expect(DRC).to have_received(:message).with('  Pausing 10 seconds.')
        expect(TriggerWatcherMethods).to have_received(:pause).with(10.0)
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

  describe 'regex capture groups in trigger responses' do
    # A capture holding braces and quotes, the characters that matter if the text were read as code
    let(:captured_text) { %q(Mallory's "big" {grin}) }
    let(:match) { /^(.*) waves to you\.$/.match("#{captured_text} waves to you.") }
    let(:log_file) { StringIO.new }
    let(:shown_messages) { [] }

    # Fires one trigger whose regex matched `match`, and runs the main loop for one game line:
    # script.gets then returns nil and the loop ends.
    def fire_trigger(responses, name: 'greet')
      TriggerWatcherMethods.instance_variable_set(
        :@trigger_data,
        name => {
          'triggers'         => ['^(.*) waves to you\\.$'],
          'responses'        => responses.map(&:dup),
          'use_with_scripts' => [],
          'no_use_scripts'   => []
        }
      )
      Flags[name] = match
      game_lines = double('script')
      allow(game_lines).to receive(:gets).and_return('a game line', nil)
      allow(TriggerWatcherMethods).to receive(:script).and_return(game_lines)
      TriggerWatcherMethods.module_eval(TRIGGER_WATCHER_MAIN_LOOP, lic_path('trigger-watcher.lic'), TRIGGER_WATCHER_MAIN_LOOP_START + 1)
    end

    def capture_warnings
      shown_messages.grep(/aren't substituted/)
    end

    before do
      $debug_mode_tw = false
      TriggerWatcherMethods.instance_variable_set(:@capture_warned_triggers, nil)
      allow(DRC).to receive(:message) { |msg| shown_messages << msg }
      allow(TriggerWatcherMethods).to receive(:fput)
      allow(DRC).to receive(:log_window)
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with('mylog.txt', 'a').and_yield(log_file)
    end

    after do
      $debug_mode_tw = nil
    end

    context 'in a plain command' do
      it 'sends the command with the capture text in place of $1' do
        fire_trigger(['say I saw $1'])

        expect(TriggerWatcherMethods).to have_received(:fput).with(%q(say I saw Mallory's "big" {grin}))
      end

      it 'puts $0 in as the whole matched line' do
        fire_trigger(['say $0'])

        expect(TriggerWatcherMethods).to have_received(:fput).with(%q(say Mallory's "big" {grin} waves to you.))
      end

      context 'when the capture holds a backslash sequence' do
        let(:captured_text) { %q(Mallory \\0 and \\1) }

        it 'sends the backslashes as written' do
          fire_trigger(['say I saw $1'])

          expect(TriggerWatcherMethods).to have_received(:fput).with(%q(say I saw Mallory \\0 and \\1))
        end
      end

      it 'warns and leaves $2 as written when the trigger has no second group' do
        fire_trigger(['say $2'])

        expect(TriggerWatcherMethods).to have_received(:fput).with('say $2')
        expect(DRC).to have_received(:message).with("  Warning, you're referencing capture group $2, which does not exist.")
      end
    end

    context 'when the capture text looks like a trigger command' do
      before do
        allow(TriggerWatcherMethods).to receive(:execute_eval)
        allow(TriggerWatcherMethods).to receive(:execute_logf)
      end

      context 'with an =eval command' do
        let(:captured_text) { '=eval {DRC.message("hi")}' }

        it 'sends a plain $1 response as the text, without evaluating it' do
          fire_trigger(['$1'])

          expect(TriggerWatcherMethods).not_to have_received(:execute_eval)
          expect(TriggerWatcherMethods).to have_received(:fput).with('=eval {DRC.message("hi")}')
        end
      end

      context 'with an =logf command' do
        let(:captured_text) { '=logf {mylog hi}' }

        it 'sends a plain response as the text, without logging' do
          fire_trigger(['$1 now'])

          expect(TriggerWatcherMethods).not_to have_received(:execute_logf)
          expect(TriggerWatcherMethods).to have_received(:fput).with('=logf {mylog hi} now')
        end
      end
    end

    context 'in =exec and =execw' do
      let(:captured_text) { 'Mallory Smith' }

      before do
        allow(DRC).to receive(:verify_script).and_return(true)
        allow(DRC).to receive(:wait_for_script_to_complete)
      end

      it 'starts the named script with the capture text as one argument' do
        fire_trigger(['=exec {somescript $1 now}'])

        expect($started_scripts).to eq([['somescript', ['"Mallory Smith"', 'now'], {}]])
      end

      it 'runs the named =execw script with the capture text as one argument' do
        fire_trigger(['=execw {somescript $1}'])

        expect(DRC).to have_received(:wait_for_script_to_complete).with('somescript', ['Mallory Smith'])
      end

      context 'when the script name is a capture' do
        let(:captured_text) { 'somescript' }

        it 'does not start a script named by the capture' do
          fire_trigger(['=exec {$1}'])

          expect($started_scripts.map(&:first)).not_to include('somescript')
        end

        it 'explains once that captures are not substituted into script names' do
          fire_trigger(['=exec {$1}'])
          fire_trigger(['=execw {$1}'])

          expect(capture_warnings).to eq(
            ["  Warning, trigger greet uses a capture group ($0-$9) in an =exec or =execw script name. Capture groups aren't substituted into script names, so it is left as written."]
          )
        end
      end
    end

    context 'in =logf text' do
      it 'logs the capture text exactly as captured, braces and quotes included' do
        fire_trigger(['=logf {mylog Saw $1}'])

        expect(log_file.string).to include([%q(Saw Mallory's "big" {grin})].inspect)
      end

      it 'still runs the inner-brace Ruby written in the response itself' do
        fire_trigger(['=logf {mylog {1 + 2} waves from $1}'])

        expect(log_file.string).to include([%q(3 waves from Mallory's "big" {grin})].inspect)
      end
    end

    context 'in =logw text' do
      it 'writes the capture text exactly as captured' do
        fire_trigger(['=logw {mywindow {1 + 2} waves from $1}'])

        expect(DRC).to have_received(:log_window)
          .with(%q(3 waves from Mallory's "big" {grin}), 'mywindow', true, true, false)
      end
    end

    context 'in responses that run Ruby' do
      it 'hands an =eval response to evaluation with $1 left as written' do
        allow(TriggerWatcherMethods).to receive(:execute_eval)

        fire_trigger(['=eval {DRC.message("$1 waved")}'])

        expect(TriggerWatcherMethods).to have_received(:execute_eval).with('DRC.message("$1 waved")')
      end

      it 'runs the =eval code as the user wrote it' do
        fire_trigger(['=eval {DRC.message("$1 waved")}'])

        expect(DRC).to have_received(:message).with('$1 waved')
      end

      it 'hands an =if response to evaluation with $1 left as written' do
        allow(TriggerWatcherMethods).to receive(:execute_if)
        response = '=if {"$1".empty?} {DRC.message("nobody")} =else {DRC.message("saw $1")}'

        fire_trigger([response])

        expect(TriggerWatcherMethods).to have_received(:execute_if).with(response)
      end

      it 'sets an =uvar to the text as written, without the capture' do
        allow(UserVars).to receive(:send)

        fire_trigger(['=uvar {set LastWaver $1}'])

        expect(UserVars).to have_received(:send).with('LastWaver=', '$1')
      end

      it 'explains once per trigger that captures are not substituted into these responses' do
        allow(TriggerWatcherMethods).to receive(:execute_eval)

        fire_trigger(['=eval {DRC.message("$1 waved")}'])
        fire_trigger(['=eval {DRC.message("$1 waved")}'])

        expect(capture_warnings).to eq(
          ["  Warning, trigger greet uses a capture group ($0-$9) in an =eval, =if or =uvar response. Capture groups aren't substituted into responses that run Ruby, so it is left as written."]
        )
      end

      it 'warns separately for each trigger' do
        allow(TriggerWatcherMethods).to receive(:execute_eval)

        fire_trigger(['=eval {DRC.message("$1 waved")}'], name: 'greet')
        fire_trigger(['=eval {DRC.message("$1 waved")}'], name: 'farewell')

        expect(capture_warnings.size).to eq(2)
      end

      it 'still substitutes a plain command in the same trigger' do
        allow(TriggerWatcherMethods).to receive(:execute_eval)

        fire_trigger(['=eval {DRC.message("$1 waved")}', 'say hi $1'])

        expect(TriggerWatcherMethods).to have_received(:execute_eval).with('DRC.message("$1 waved")')
        expect(TriggerWatcherMethods).to have_received(:fput).with(%q(say hi Mallory's "big" {grin}))
      end
    end
  end
end
