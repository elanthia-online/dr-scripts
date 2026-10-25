# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('sigilrecorder.lic', 'SigilRecorder')

# sigilrecorder.lic watches for signs of combat with the 'sigil-danger-room'
# flag. When it is set after WEAVE, the room goes onto the nogo list in
# data/base-sigils.yaml, which every later run skips. lich-5 tests the flag's
# patterns against every incoming line, including other players' speech,
# whispers and ESP, so the patterns must only match the game's own lines.
RSpec.describe SigilRecorder do
  describe "'sigil-danger-room' flag" do
    let(:room_id) { 4242 }
    let(:image) { 'zoluren-crossing.png' }
    let(:cities) { %w[Crossing Riverhaven Shard] }
    let(:sigils) do
      %w[abolition congruence induction permutation rarefaction antipode ascension clarification
         decay evolution integration metamorphosis nurture paradox unity]
    end
    let(:seasons) { %w[summer fall winter spring] }
    let(:sigil_data) do
      info = { 'banpatterns' => [], 'nogo' => [] }
      cities.each { |city| info[city] = sigils.to_h { |sigil| [sigil, seasons.to_h { |season| [season, []] }] } }
      OpenStruct.new(SigilInfo: info)
    end
    let(:data_file) { '/nonexistent-sigilrecorder-spec/data/base-sigils.yaml' }
    let(:writes) { [] }

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

    # Runs the script over a one-room walk list. `heard` arrives while WEAVE
    # runs, followed by the game's own WEAVE reply. The data file write is
    # captured, never made.
    def run_script(heard:, weave_reply: 'There is nothing else to face!')
      stub_const('SCRIPT_DIR', '/nonexistent-sigilrecorder-spec')
      room = OpenStruct.new(id: room_id, image: image)
      allow(Room).to receive(:current).and_return(room)
      allow(Map).to receive(:list).and_return([room])
      allow(Map).to receive(:[]).with(room_id).and_return(OpenStruct.new(title: '[Town Green]'))
      $test_data = OpenStruct.new(sigils: sigil_data, hunting: OpenStruct.new(hunting_zones: { 'rats' => [1, 1] }))
      allow(DRCA).to receive(:do_buffs)
      allow(DRCT).to receive(:walk_to).and_return(true)
      allow(DRC).to receive(:message)
      allow(File).to receive(:open).with(data_file, 'w') { |*_args, &block| block.call(StringIO.new.tap { |io| writes << io }) }
      # A danger room hands record_sigil nil. Lich's nil patch makes nil.each a
      # no-op there; rspec has no such patch, so skip the call for nil.
      allow_any_instance_of(SigilRecorder).to receive(:record_sigil).and_wrap_original do |original, found, data|
        original.call(found, data) if found
      end
      perceived = %w[unity decay]
      allow(DRC).to receive(:bput) do |command, *_patterns|
        case command
        when 'time' then 'It is currently summer and it is mid-morning.'
        when 'weave'
          Array(heard).each { |line| deliver(line) }
          deliver(weave_reply)
          weave_reply
        when 'perceive sigil' then perceived.shift
        end
      end
      SigilRecorder.new
    ensure
      Flags.delete('sigil-danger-room')
    end

    def nogo
      sigil_data.SigilInfo['nogo']
    end

    def recorded_rooms
      sigil_data.SigilInfo['Crossing'].values_at('unity', 'decay').map { |by_season| by_season['summer'] }
    end

    it 'records the sigils of a quiet room and never touches nogo' do
      run_script(heard: nil)

      expect(nogo).to be_empty
      expect(recorded_rooms).to eq([[room_id], [room_id]])
      expect(writes.last.string).to include('unity')
    end

    context 'with the game reporting combat' do
      [
        ['the WEAVE reply facing an enemy', nil,
         %(<pushStream id="combat" />You weave back and forth in a dance-like motion, drawing your opponent's attention away from the fight.)],
        ['the WEAVE reply with the enemy out of reach', nil, 'You must be closer to use tactical abilities on your opponent.'],
        ['a creature advancing', 'The jeol moradu begins to advance on you!', 'There is nothing else to face!'],
        ['a creature with an apostrophe advancing', "The matron's tress begins to advance on you!", 'There is nothing else to face!']
      ].each do |label, heard, reply|
        it "puts the room on the nogo list for #{label}" do
          run_script(heard: heard, weave_reply: reply)

          expect(nogo).to eq([room_id])
          expect(recorded_rooms).to eq([[], []])
          expect(writes.last.string).to include("- #{room_id}")
        end
      end
    end

    context 'with another player repeating the danger lines' do
      phrases = [
        'You weave back and forth in a dance-like motion',
        'You must be closer to use tactical abilities on your opponent',
        'The jeol moradu begins to advance on you!'
      ]
      shapes = {
        'ESP'           => ->(text) { %([General][Mallory] "#{text}") },
        'ESP (raw XML)' => ->(text) { %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>) },
        'say'           => ->(text) { %(Mallory says, "#{text}") },
        'say (raw XML)' => ->(text) { %(<preset id='speech'>Mallory says</preset>, "#{text}") },
        'whisper'       => ->(text) { %(Mallory whispers, "#{text}") }
      }
      shapes.to_a.product(phrases).each do |(shape, build), text|
        it "keeps the room off the nogo list for #{shape} of '#{text}'" do
          run_script(heard: build.call(text))

          expect(nogo).to be_empty
          expect(recorded_rooms).to eq([[room_id], [room_id]])
        end
      end
    end
  end
end
