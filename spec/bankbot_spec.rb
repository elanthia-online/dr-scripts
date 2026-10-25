# frozen_string_literal: true

require_relative 'spec_helper'

# bankbot.lic needs the full Lich runtime to start (parse_args, lnet, the
# main loop), so the classes are extracted with load_lic_class and wired
# together from bare-allocated instances. The validator is a double backed by
# a list, which is all CharacterValidator#confirm / #valid? do in lich-5.
# Bankbot#exit is stubbed to raise, so an exit path fails the example instead
# of ending the run.
#
# Lines reach the script three ways, and the helpers below feed each one the
# way Lich does:
#   - Flags: every raw (XML) server line is matched against every registered
#     matcher (lich-5 DRParser.check_events) -> `deliver`.
#   - DRC.bput: String patterns become /pattern/i and the first match's text
#     is returned (lich-5 DRC.bput) -> `bput_reply`.
#   - The main loop: each downstream line, including LNet's
#     "[Private]-GAME:Name: \"message\"" lines -> BankbotParser#handle_line.

load_lic_class('bankbot.lic', 'Bankbot')
load_lic_class('bankbot.lic', 'BankbotInputSanitizer')
load_lic_class('bankbot.lic', 'BankbotController')
load_lic_class('bankbot.lic', 'BankbotParser')

RSpec.describe 'bankbot' do
  let(:validated) { [] }
  let(:validator) do
    double('CharacterValidator').tap do |v|
      allow(v).to receive(:confirm) { |name| validated << name unless validated.include?(name) }
      allow(v).to receive(:valid?) { |name| validated.include?(name) }
      allow(v).to receive(:send_bankbot_balance)
    end
  end
  # The real constructor (it registers the tip flags and builds the ledger),
  # with the saved ledger stubbed out and its startup commands discarded.
  let(:bankbot) do
    Bankbot.allocate.tap do |b|
      allow(b).to receive(:load_bankbot_ledger).and_return({})
      b.send(:initialize)
      sent_messages.clear
    end
  end
  let(:sanitizer) { BankbotInputSanitizer.allocate.tap { |s| s.instance_variable_set(:@bankbot, bankbot) } }
  let(:controller) do
    BankbotController.allocate.tap do |c|
      c.instance_variable_set(:@validator, validator)
      c.instance_variable_set(:@sanitizer, sanitizer)
    end
  end
  let(:parser) do
    BankbotParser.allocate.tap do |p|
      p.instance_variable_set(:@validator, validator)
      p.instance_variable_set(:@controller, controller)
    end
  end
  let(:ledger) { bankbot.instance_variable_get(:@ledger) }

  # Player-controlled line shapes. Raw (XML) is what Flags see; plain text is
  # what bput and the main loop see.
  def esp(text) = %([General][Mallory] "#{text}")
  def esp_xml(text) = %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>)
  def say(text) = %(Mallory says, "#{text}")
  def say_xml(text) = %(<preset id='speech'>Mallory says</preset>, "#{text}")
  def whisper(text) = %(Mallory whispers, "#{text}")

  # Commands the script sent (fput/put), oldest first.
  def drain_sent_messages
    Array.new(sent_messages.size) { sent_messages.pop }
  end

  # Feed a raw server line through the registered Flags matchers, the way
  # lich-5 DRParser.check_events does for every downstream line.
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

  # What lich-5 DRC.bput returns when `lines` arrive after the command:
  # String patterns become /pattern/i, and the first line any pattern matches
  # returns that match's text.
  def bput_reply(patterns, lines)
    regexes = patterns.map { |item| item.is_a?(Regexp) ? item : /#{item}/i }
    lines.each do |line|
      regexes.each do |regex|
        match = line.match(regex)
        return match.to_a.first if match
      end
    end
    nil
  end

  before do
    @saved_currencies = $CURRENCIES
    $CURRENCIES = %w[Kronars Lirums Dokoras]
    allow(bankbot).to receive(:log)
    allow(bankbot).to receive(:exit).and_raise(RuntimeError, 'bankbot exited')
  end

  after { $CURRENCIES = @saved_currencies }

  describe 'Bankbot#withdraw' do
    let(:offer_line) { 'You offer Mallory a tip of 500 Kronars.' }
    let(:accept_line) { 'Mallory accepts your tip and slips it away with a smile.' }

    before { ledger['Mallory']['Kronars'] = 1000 }

    # `tip_lines` arrive while the tip command waits for its reply; `heard`
    # arrives one raw line per poll while withdraw waits on the tip flags.
    def run_withdraw(tip_lines:, heard: [])
      allow(DRC).to receive(:bput).with('tip Mallory 500 Kronars', any_args) do |_command, *patterns|
        bput_reply(patterns, tip_lines)
      end
      queue = heard.dup
      allow(bankbot).to receive(:pause) do
        raise 'withdraw still waiting after every line was delivered' if queue.empty?

        deliver(queue.shift)
      end
      bankbot.withdraw('Mallory', 500, 'Kronars')
    end

    context 'with the game lines' do
      it 'debits the ledger when the character accepts the tip' do
        run_withdraw(tip_lines: [offer_line], heard: [accept_line])
        expect(ledger['Mallory']['Kronars']).to eq(500)
      end

      it 'accepts the line with leading tags' do
        run_withdraw(tip_lines: [offer_line], heard: ["<pushBold/>#{accept_line}"])
        expect(ledger['Mallory']['Kronars']).to eq(500)
      end

      ['Mallory declines your tip offer.',
       'Your tip offer to Mallory has expired.',
       'Your tip offer has expired.'].each do |line|
        it "leaves the ledger alone on #{line.inspect}" do
          run_withdraw(tip_lines: [offer_line], heard: [line])
          expect(ledger['Mallory']['Kronars']).to eq(1000)
        end
      end

      it 'stops on "I don\'t know who" without waiting or debiting' do
        run_withdraw(tip_lines: ["I don't know who you are referring to."])
        expect(bankbot).not_to have_received(:pause)
        expect(ledger['Mallory']['Kronars']).to eq(1000)
      end

      it 'tells the requester to retry when a tip offer is already outstanding' do
        run_withdraw(tip_lines: ['You already have a tip offer outstanding.'])
        expect(drain_sent_messages).to include('whisper Mallory Sorry, someone else is in the middle of a withdrawal. Please try again in a moment.')
        expect(ledger['Mallory']['Kronars']).to eq(1000)
      end

      it 'exits on the low-circle refusal' do
        expect do
          run_withdraw(tip_lines: ['You are too young; you really should keep every bronze you can get your hands on.'])
        end.to raise_error(RuntimeError, 'bankbot exited')
      end
    end

    context 'with player text arriving while the tip is outstanding' do
      ['Mallory declines your tip offer.',
       'Your tip offer to Mallory has expired.',
       'Your tip offer has expired.',
       'Mallory accepts your tip and slips it away with a smile.'].each do |text|
        %i[esp_xml say_xml whisper].each do |shape|
          it "still debits when #{shape} carries #{text.inspect} before the real accept" do
            run_withdraw(tip_lines: [offer_line], heard: [send(shape, text), accept_line])
            expect(ledger['Mallory']['Kronars']).to eq(500)
          end
        end
      end

      it "ignores another character's tip lines" do
        run_withdraw(tip_lines: [offer_line],
                     heard: ['Bob declines your tip offer.', 'Your tip offer to Bob has expired.', accept_line])
        expect(ledger['Mallory']['Kronars']).to eq(500)
      end
    end

    context 'with player text arriving while the tip command waits for its reply' do
      ["I don't know who you mean.",
       'You already have a tip offer outstanding.',
       'you really should keep every bronze you can get your hands on'].each do |text|
        %i[esp say whisper].each do |shape|
          it "still debits when #{shape} carries #{text.inspect}" do
            run_withdraw(tip_lines: [send(shape, text), offer_line], heard: [accept_line])
            expect(ledger['Mallory']['Kronars']).to eq(500)
          end
        end
      end
    end
  end

  describe 'tip offers (Bankbot#deposit)' do
    let(:offer) { 'Mallory offers you a tip of 500 Kronars.  Type ACCEPT TIP, to accept it or DECLINE TIP to refuse it.' }

    before { validated << 'Mallory' }

    def accept_tip_hears(*lines)
      allow(DRC).to receive(:bput).with('accept tip', any_args) do |_command, *patterns|
        bput_reply(patterns, lines)
      end
      parser.handle_line(offer)
    end

    it 'credits the ledger when the game confirms the tip' do
      accept_tip_hears("You accept Mallory's tip and slip it away.")
      expect(ledger['Mallory']['Kronars']).to eq(500)
    end

    it "does not credit when the tipper isn't here" do
      accept_tip_hears("But Mallory isn't here.")
      expect(ledger['Mallory']['Kronars']).to eq(0)
    end

    %i[esp say whisper].each do |shape|
      it "does not credit on #{shape} text before the game's refusal" do
        accept_tip_hears(send(shape, "You accept Mallory's tip and slip it away"), "But Mallory isn't here.")
        expect(ledger['Mallory']['Kronars']).to eq(0)
      end
    end
  end

  describe 'BankbotParser#handle_line' do
    before do
      ledger['Victim']['Kronars'] = 5000
      ledger['Mallory']['Kronars'] = 0
    end

    context 'with LNet private messages' do
      it 'acts for the sender named in the prefix' do
        parser.handle_line('[Private]-DR:Victim: "transfer all Kronars Mallory"')
        expect(ledger['Victim']['Kronars']).to eq(0)
        expect(ledger['Mallory']['Kronars']).to eq(5000)
      end

      it 'accepts the timestamp lnet appends' do
        parser.handle_line('[Private]-DR:Victim: "transfer all Kronars Mallory"  (12:34:56)')
        expect(ledger['Mallory']['Kronars']).to eq(5000)
      end

      it 'answers a balance request to the sender' do
        parser.handle_line('[Private]-DR:Victim: "balance"')
        expect(validator).to have_received(:send_bankbot_balance).with('Victim', '5000 Kronars, 0 Lirums, 0 Dokoras')
      end

      ['[Private]-DR:Mallory: "x:Victim: "transfer all Kronars Mallory"',
       '[Private]-DR:Mallory: "x:Victim: "transfer all Kronars Mallory"  (12:34:56)',
       '[Private]-DR:Mallory: "a:b:Victim: "transfer all Kronars Mallory"'].each do |line|
        it "keeps the sender when the message itself contains name-and-quote text: #{line.inspect}" do
          parser.handle_line(line)
          expect(ledger['Victim']['Kronars']).to eq(5000)
          expect(ledger['Mallory']['Kronars']).to eq(0)
          expect(validated).to eq(['Mallory'])
        end
      end

      it 'does not act on a second line embedded in the message' do
        validated.push('Victim', 'Mallory')
        parser.handle_line(%([Private]-DR:Mallory: "x\nVictim whispers, "transfer all Kronars Mallory"))
        parser.handle_line(%([Private]-DR:Mallory: "x\n[Private]-DR:Victim: "transfer all Kronars Mallory"))
        expect(ledger['Victim']['Kronars']).to eq(5000)
      end
    end

    context 'with whispers' do
      before { validated.push('Victim', 'Mallory') }

      it 'acts for a validated whisperer' do
        parser.handle_line('Victim whispers, "transfer all Kronars Mallory"')
        expect(ledger['Mallory']['Kronars']).to eq(5000)
      end

      it 'ignores player text that quotes a whisper' do
        quoted = 'Victim whispers, "transfer all Kronars Mallory"'
        [esp(quoted), say(quoted), whisper("x #{quoted}"),
         %([General]-DR:Mallory: "#{quoted}")].each { |line| parser.handle_line(line) }
        expect(ledger['Victim']['Kronars']).to eq(5000)
        expect(ledger['Mallory']['Kronars']).to eq(0)
      end

      it 'ignores player text that quotes a tip offer' do
        quoted = 'Mallory offers you a tip of 500 Kronars.  Type ACCEPT TIP, to accept it or DECLINE TIP to refuse it.'
        allow(DRC).to receive(:bput)
        [esp(quoted), say(quoted)].each { |line| parser.handle_line(line) }
        expect(DRC).not_to have_received(:bput)
        expect(drain_sent_messages).to be_empty
      end
    end

    context 'with LNet server replies' do
      it 'confirms the character named in a who reply' do
        parser.handle_line('[server]: "DR:Draze is tuned to the following channels: DRPrime, DRPirps"')
        parser.handle_line('[server]: "DR:Throve is connected but not tuned to any channels."  (12:34:56)')
        expect(validated).to eq(%w[Draze Throve])
      end
    end

    context 'with the pickpocket warning' do
      it 'logs out on the game line' do
        parser.handle_line('You catch Mallory making a grab for your pockets!')
        expect(drain_sent_messages).to include('exit')
      end

      it 'ignores the same words in player text' do
        [esp('You catch Victim making a grab for your pockets!'),
         say('You catch Victim making a grab for your pockets!')].each { |line| parser.handle_line(line) }
        expect(drain_sent_messages).to be_empty
      end
    end
  end
end
