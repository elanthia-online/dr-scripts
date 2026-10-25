# frozen_string_literal: true

require_relative 'spec_helper'

# lichbot.lic needs the full Lich runtime to start (parse_args, the validator,
# the main loop), so the Lichbot class is extracted with load_lic_class and
# built from a bare-allocated instance.
#
# Lines reach the script three ways, and the helpers below feed each one the
# way Lich does:
#   - Flags: every raw (XML) server line is matched against every registered
#     matcher (lich-5 DRParser.check_events) -> `deliver`.
#   - DRC.bput: String patterns become /pattern/i and the first match's text
#     is returned (lich-5 DRC.bput) -> `bput_reply`.
#   - The main loop: LNet's "[Private]-GAME:Name: \"message\"" lines ->
#     Lichbot.slack_token_requester.

load_lic_class('lichbot.lic', 'Lichbot')

RSpec.describe Lichbot do
  # The real constructor (it registers the listening flag and sets the avoids),
  # with its startup commands discarded.
  let(:lichbot) do
    Lichbot.allocate.tap do |bot|
      bot.send(:initialize, true)
      drain_sent_messages
    end
  end

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
    $test_settings.lichbot_buffs = []
    allow(lichbot).to receive(:refresh_inventory)
  end

  describe '.slack_token_requester' do
    it 'names the sender of an LNet RequestSlackToken message' do
      expect(Lichbot.slack_token_requester('[Private]-DR:Bob: "RequestSlackToken"')).to eq('Bob')
    end

    it 'accepts the timestamp lnet appends' do
      expect(Lichbot.slack_token_requester('[Private]-DR:Bob: "RequestSlackToken"  (12:34:56)')).to eq('Bob')
    end

    ['[Private]-DR:Mallory: "x:Victim: "RequestSlackToken"',
     '[Private]-DR:Mallory: "a:b:Victim: "RequestSlackToken"  (12:34:56)',
     %([Private]-DR:Mallory: "x\n[Private]-DR:Victim: "RequestSlackToken")].each do |line|
      it "never names anyone but the sender when the message holds name-and-quote text: #{line.inspect}" do
        expect(Lichbot.slack_token_requester(line)).to be_nil
      end
    end

    it 'ignores player text that quotes a private message' do
      quoted = '[Private]-DR:Victim: "RequestSlackToken"'
      [esp(quoted), say(quoted), whisper(quoted), %([General]-DR:Mallory: "#{quoted}")].each do |line|
        expect(Lichbot.slack_token_requester(line)).to be_nil
      end
    end

    it 'ignores other private messages and a missing line' do
      expect(Lichbot.slack_token_requester('[Private]-DR:Bob: "hello"')).to be_nil
      expect(Lichbot.slack_token_requester(nil)).to be_nil
    end
  end

  describe '#accept' do
    def run_accept(*lines)
      allow(DRC).to receive(:bput).with('accept', any_args) { |_command, *patterns| bput_reply(patterns, lines) }
      allow(DRCI).to receive(:stow_hands)
      lichbot.accept('Bob')
    end

    it 'stows the item when the game confirms the accept' do
      run_accept("You accept Bob's offer and are now holding a steel sword.")
      expect(DRCI).to have_received(:stow_hands)
      expect(drain_sent_messages).to be_empty
    end

    it 'declines at the item limit' do
      run_accept('Accepting that would push you over your item limit.')
      expect(drain_sent_messages).to eq(['whisper Bob ***ERROR*** I am at my inventory limit and cannot accept that.', 'decline'])
    end

    %i[esp say whisper].each do |shape|
      it "does not decline on #{shape} text before the game's accept" do
        run_accept(send(shape, 'that would push you over your item limit'),
                   "You accept Bob's offer and are now holding a steel sword.")
        expect(drain_sent_messages).not_to include('decline')
        expect(DRCI).to have_received(:stow_hands)
      end
    end
  end

  describe '#give' do
    let(:offer_line) { 'You offer your steel sword to Bob, who has 30 seconds to accept the offer.  Type CANCEL to prematurely cancel the offer.' }
    let(:accept_line) { 'Bob has accepted your offer and is now holding a steel sword.' }

    # `get_lines` and `give_lines` arrive while the get and give commands wait
    # for their reply; `heard` arrives one raw line per poll while give waits
    # on the give flags. Returns the lines still unheard when give returned.
    def run_give(get_lines: ['You get a steel sword from inside your pack.'], give_lines: [offer_line], heard: [])
      allow(DRC).to receive(:bput).with('get my sword', any_args) { |_command, *patterns| bput_reply(patterns, get_lines) }
      allow(DRC).to receive(:bput).with('give my sword to Bob', any_args) { |_command, *patterns| bput_reply(patterns, give_lines) }
      allow(DRCI).to receive(:stow_hands)
      queue = heard.dup
      allow(lichbot).to receive(:pause) do
        raise 'give still waiting after every line was delivered' if queue.empty?

        deliver(queue.shift)
      end
      lichbot.give('Bob', 'sword')
      queue
    end

    context 'with the game lines' do
      it 'refreshes the inventory when the recipient accepts' do
        run_give(heard: [accept_line])
        expect(lichbot).to have_received(:refresh_inventory)
      end

      it 'accepts the line with leading tags' do
        run_give(heard: ["<pushBold/>#{accept_line}"])
        expect(lichbot).to have_received(:refresh_inventory)
      end

      ['Bob has declined the offer.', 'Your offer to Bob has expired.'].each do |line|
        it "stows without a refresh on #{line.inspect}" do
          run_give(heard: [line])
          expect(DRCI).to have_received(:stow_hands)
          expect(lichbot).not_to have_received(:refresh_inventory)
        end
      end

      it 'whispers a failure when the recipient is not there' do
        run_give(give_lines: ["What is it you're trying to give?"])
        expect(drain_sent_messages).to eq(['whisper Bob Sorry, I failed to give you [sword]'])
      end

      it 'whispers a failure when the item is not found' do
        run_give(get_lines: ['What were you referring to?'])
        expect(drain_sent_messages).to eq(['whisper Bob Sorry, I failed to find [sword] in my inventory'])
      end
    end

    context 'with player text arriving while the offer is outstanding' do
      ['Bob has accepted your offer and is now holding a steel sword.',
       'Bob has declined the offer.',
       'Your offer to Bob has expired.'].each do |text|
        %i[esp_xml say_xml whisper].each do |shape|
          it "keeps waiting for the game's line when #{shape} carries #{text.inspect}" do
            unheard = run_give(heard: [send(shape, text), accept_line])
            expect(unheard).to be_empty
            expect(lichbot).to have_received(:refresh_inventory)
          end
        end
      end

      it "ignores the game's lines about another character's offer" do
        unheard = run_give(heard: ['Carl has declined the offer.', 'Your offer to Carl has expired.',
                                   'Carl has accepted your offer and is now holding a rock.', accept_line])
        expect(unheard).to be_empty
      end
    end

    context 'with player text arriving while the give command waits for its reply' do
      %i[esp say whisper].each do |shape|
        it "still offers when #{shape} carries 'What is it'" do
          run_give(give_lines: [send(shape, 'What is it you want?'), offer_line], heard: [accept_line])
          expect(drain_sent_messages).to be_empty
          expect(lichbot).to have_received(:refresh_inventory)
        end

        it "does not wait on an offer when #{shape} carries 'You offer' before the game's refusal" do
          run_give(give_lines: [send(shape, 'You offer too little'), "What is it you're trying to give?"])
          expect(drain_sent_messages).to eq(['whisper Bob Sorry, I failed to give you [sword]'])
        end

        it "does not retry with a bare give when #{shape} carries 'You don't need to specify the object'" do
          run_give(give_lines: [send(shape, "You don't need to specify the object"), offer_line], heard: [accept_line])
          expect(DRC).not_to have_received(:bput).with('give Bob', any_args)
        end
      end
    end

    context 'with player text arriving while the get command waits for its reply' do
      %i[esp say whisper].each do |shape|
        it "reports the item missing when #{shape} carries 'You get' before 'What were you referring to'" do
          run_give(get_lines: [send(shape, 'You get nothing from me'), 'What were you referring to?'])
          expect(drain_sent_messages).to eq(['whisper Bob Sorry, I failed to find [sword] in my inventory'])
        end
      end
    end
  end

  describe '#ping and the stopped-listening flag' do
    before do
      $test_settings.lichbot_train_when_idle = true
      $test_settings.dump_item_count = 10
      allow(DRC).to receive(:assess_teach).and_return({ 'Byd' => 'Scholarship' })
      allow(DRC).to receive(:listen?).and_return(true)
    end

    # Run one idle tick (the 3-minute idle guard rewound).
    def idle_ping
      lichbot.instance_variable_set(:@last_action, Time.now - 600)
      lichbot.ping
    end

    # The first idle tick picks Byd (no teacher yet); every example then
    # delivers lines and checks whether the second tick looks for a new class.
    it 'picks a new teacher after the current teacher stops teaching' do
      idle_ping
      deliver('Byd stops teaching.')
      idle_ping
      expect(DRC).to have_received(:assess_teach).twice
    end

    it 'picks a new teacher when the game says the teacher is gone' do
      idle_ping
      deliver('<pushBold/>Your teacher is not here, so you are no longer learning anything.')
      idle_ping
      expect(DRC).to have_received(:assess_teach).twice
    end

    it 'keeps the class when another teacher stops teaching' do
      idle_ping
      deliver('Gorkus stops teaching.')
      idle_ping
      expect(DRC).to have_received(:assess_teach).once
    end

    %i[esp_xml say_xml whisper].each do |shape|
      it "keeps the class when #{shape} carries the stop line" do
        idle_ping
        deliver(send(shape, 'Byd stops teaching.'))
        deliver(send(shape, 'Your teacher is not here, so you are no longer learning anything.'))
        idle_ping
        expect(DRC).to have_received(:assess_teach).once
      end
    end
  end
end
