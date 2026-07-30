# frozen_string_literal: true

require 'ostruct'

# Test suite for automap.lic (duplicate-aware mapper).
#
# Scope: the AutoMap module, which holds all of automap's decision logic. The
# module is self-contained (no top-level side effects), so we eval only its
# source slice out of the .lic and drive its methods directly.
#
# Isolation: this suite loads into the same process as every other spec, so it
# defines NO shared top-level constants or global methods. The live seams the
# module talks to are supplied per example instead:
#   - Room / Map / XMLData via stub_const (fresh anonymous classes, auto-removed)
#   - respond / clear / get stubbed on AutoMap itself; bare calls inside the
#     module resolve to its singleton, so no global respond/get is touched.
#
# Coverage aims beyond the happy path: the UID-boundary matrix that decides a
# duplicate, adversarial reply parsing (garbage, partial words, nil, casing),
# idempotent linking, and the resolve_room orchestration across create/skip/stop.

# Eval only the `module AutoMap ... end` slice so the top-level hook, config read,
# and mapping loop at the bottom of the .lic never run.
#
# @param filename [String] path to the .lic relative to this spec's parent dir
# @param module_name [String] the module to extract
# @return [void]
def load_lic_module(filename, module_name)
  return if Object.const_defined?(module_name)

  path = File.join(File.dirname(__FILE__), '..', filename)
  lines = File.readlines(path)

  start_idx = lines.index { |l| l =~ /^module\s+#{module_name}\b/ }
  raise "Could not find 'module #{module_name}' in #{filename}" unless start_idx

  end_offset = lines[start_idx + 1..].index { |l| l =~ /^end\s*$/ }
  raise "Could not find matching end for 'module #{module_name}'" unless end_offset

  source = lines[start_idx..start_idx + 1 + end_offset].join
  eval(source, TOPLEVEL_BINDING, path, start_idx + 1)
end

load_lic_module('automap.lic', 'AutoMap')

# Build a room stand-in with only the accessors AutoMap touches.
#
# @return [OpenStruct] a room-like object
def build_room(id: 1, title: ['[A Room]'], description: ['A plain room.'],
               uid: [], paths: ['Obvious exits: north'], wayto: {}, timeto: {})
  OpenStruct.new(id: id, title: title, description: description,
                 uid: uid, paths: paths, wayto: wayto, timeto: timeto)
end

RSpec.describe 'AutoMap' do
  before do
    stub_const('Room', Class.new)
    stub_const('Map', Class.new)
    stub_const('XMLData', Class.new)
    allow(AutoMap).to receive(:respond)
    allow(AutoMap).to receive(:clear)
    AutoMap.actions = []
    AutoMap.confirm = true
  end

  describe '.parse_reply' do
    it 'reads yes and y (any case) as create' do
      expect(AutoMap.parse_reply('yes')).to eq(:create)
      expect(AutoMap.parse_reply('y')).to eq(:create)
      expect(AutoMap.parse_reply('YES')).to eq(:create)
      expect(AutoMap.parse_reply('Y')).to eq(:create)
    end

    it 'reads no, n, and skip (any case) as skip' do
      expect(AutoMap.parse_reply('no')).to eq(:skip)
      expect(AutoMap.parse_reply('n')).to eq(:skip)
      expect(AutoMap.parse_reply('skip')).to eq(:skip)
      expect(AutoMap.parse_reply('SKIP')).to eq(:skip)
    end

    it 'reads stop (any case) as stop' do
      expect(AutoMap.parse_reply('stop')).to eq(:stop)
      expect(AutoMap.parse_reply('Stop')).to eq(:stop)
    end

    it 'strips surrounding whitespace before matching' do
      expect(AutoMap.parse_reply('  yes  ')).to eq(:create)
      expect(AutoMap.parse_reply("stop\n")).to eq(:stop)
    end

    it 'rejects partial or padded words rather than matching loosely' do
      expect(AutoMap.parse_reply('yep')).to be_nil
      expect(AutoMap.parse_reply('yesss')).to be_nil
      expect(AutoMap.parse_reply('nope')).to be_nil
      expect(AutoMap.parse_reply('yes please')).to be_nil
      expect(AutoMap.parse_reply('stop it')).to be_nil
    end

    it 'treats empty, whitespace-only, and nil input as unrecognized' do
      expect(AutoMap.parse_reply('')).to be_nil
      expect(AutoMap.parse_reply('   ')).to be_nil
      expect(AutoMap.parse_reply(nil)).to be_nil
    end

    it 'treats arbitrary game output during a prompt as unrecognized' do
      expect(AutoMap.parse_reply('A goblin arrives.')).to be_nil
      expect(AutoMap.parse_reply('You see nothing unusual.')).to be_nil
    end
  end

  describe '.suspicious_twin?' do
    shared_examples 'a flagged twin' do
      it 'is reported as suspicious' do
        expect(AutoMap.suspicious_twin?(twin, game_uid)).to be(true)
      end
    end

    shared_examples 'a safe twin' do
      it 'is not reported as suspicious' do
        expect(AutoMap.suspicious_twin?(twin, game_uid)).to be(false)
      end
    end

    context 'when the game reports a UID' do
      let(:game_uid) { 230008 }

      context 'and the twin has no UID at all' do
        let(:twin) { build_room(uid: []) }

        include_examples 'a flagged twin'
      end

      context 'and the twin owns a different UID (a genuinely different room)' do
        let(:twin) { build_room(uid: [999999]) }

        include_examples 'a safe twin'
      end

      context 'and the twin already includes the game UID' do
        let(:twin) { build_room(uid: [230008]) }

        include_examples 'a safe twin'
      end

      context 'and the game UID is off by one from the twin (boundary)' do
        let(:twin) { build_room(uid: [230007]) }

        include_examples 'a safe twin'
      end
    end

    context 'when the game reports no UID' do
      context 'given a zero UID and a UID-bearing twin' do
        let(:game_uid) { 0 }
        let(:twin) { build_room(uid: [230008]) }

        include_examples 'a safe twin'
      end

      context 'given a zero UID and a UID-less twin (legit maze)' do
        let(:game_uid) { 0 }
        let(:twin) { build_room(uid: []) }

        include_examples 'a safe twin'
      end

      context 'given a nil UID (never navigated yet) it behaves like zero' do
        let(:game_uid) { nil }
        let(:twin) { build_room(uid: []) }

        include_examples 'a safe twin'
      end
    end
  end

  describe '.twins_for' do
    let(:match)      { build_room(id: 1, title: ['[Square]'], description: ['A plaza.']) }
    let(:title_only) { build_room(id: 2, title: ['[Square]'], description: ['A different place.']) }
    let(:desc_only)  { build_room(id: 3, title: ['[Alley]'],  description: ['A plaza.']) }

    it 'selects rooms sharing both title and description' do
      allow(Map).to receive(:list).and_return([match, title_only, desc_only])
      expect(AutoMap.twins_for('[Square]', 'A plaza.')).to eq([match])
    end

    it 'excludes a room that matches title but not description' do
      allow(Map).to receive(:list).and_return([title_only])
      expect(AutoMap.twins_for('[Square]', 'A plaza.')).to be_empty
    end

    it 'excludes a room that matches description but not title' do
      allow(Map).to receive(:list).and_return([desc_only])
      expect(AutoMap.twins_for('[Square]', 'A plaza.')).to be_empty
    end

    it 'skips nil holes in the map list without raising' do
      allow(Map).to receive(:list).and_return([nil, match, nil])
      expect { AutoMap.twins_for('[Square]', 'A plaza.') }.not_to raise_error
      expect(AutoMap.twins_for('[Square]', 'A plaza.')).to eq([match])
    end

    it 'returns empty when the list is empty' do
      allow(Map).to receive(:list).and_return([])
      expect(AutoMap.twins_for('[Square]', 'A plaza.')).to eq([])
    end
  end

  describe '.normalize' do
    it 'strips the <c> client marker' do
      expect(AutoMap.normalize('<c>go door')).to eq('go door')
    end

    it 'strips embedded newlines' do
      expect(AutoMap.normalize("north\n")).to eq('north')
    end

    it 'leaves a plain command untouched' do
      expect(AutoMap.normalize('go narrow trail')).to eq('go narrow trail')
    end
  end

  describe '.link' do
    let(:from) { build_room(id: 10, wayto: {}, timeto: {}) }

    before { allow(Room).to receive(:[]).with(10).and_return(from) }

    it 'records the wayto command and a default timeto keyed by destination id' do
      AutoMap.link(10, 20, 'north')
      expect(from.wayto).to eq('20' => 'north')
      expect(from.timeto).to eq('20' => AutoMap::DEFAULT_TIMETO)
    end

    it 'initializes wayto and timeto when they start nil' do
      from.wayto = nil
      from.timeto = nil
      expect { AutoMap.link(10, 20, 'north') }.not_to raise_error
      expect(from.wayto).to eq('20' => 'north')
    end

    it 'replaces a stale edge with the same command instead of duplicating it' do
      from.wayto = { '20' => 'north' }
      AutoMap.link(10, 25, 'north')
      expect(from.wayto).to eq('25' => 'north')
    end

    it 'preserves unrelated existing edges' do
      from.wayto = { '5' => 'south' }
      from.timeto = { '5' => 0.2 }
      AutoMap.link(10, 20, 'north')
      expect(from.wayto).to eq('5' => 'south', '20' => 'north')
    end
  end

  describe '.confirm_new_room' do
    let(:twin) { build_room(id: 1, uid: [230008]) }

    before { allow(AutoMap).to receive(:announce_duplicate) }

    it 'flushes buffered input before reading a reply' do
      allow(AutoMap).to receive(:get).and_return('yes')
      expect(AutoMap).to receive(:clear)
      AutoMap.confirm_new_room('[Square]', [twin])
    end

    it 'ignores noise lines until a recognized reply arrives' do
      allow(AutoMap).to receive(:get).and_return('A goblin arrives.', '', 'blah', 'yes')
      expect(AutoMap.confirm_new_room('[Square]', [twin])).to eq(:create)
    end

    it 'returns the decision for a skip reply' do
      allow(AutoMap).to receive(:get).and_return('no')
      expect(AutoMap.confirm_new_room('[Square]', [twin])).to eq(:skip)
    end

    it 'returns the decision for a stop reply' do
      allow(AutoMap).to receive(:get).and_return('stop')
      expect(AutoMap.confirm_new_room('[Square]', [twin])).to eq(:stop)
    end
  end

  describe '.announce_duplicate' do
    it 'shows the current game UID when the game reports one' do
      allow(XMLData).to receive(:room_id).and_return(230008)
      messages = capture_responses { AutoMap.announce_duplicate('[Square]', [build_room]) }
      expect(messages.join("\n")).to include('game UID now: 230008')
    end

    it 'shows (none) when the game reports no UID' do
      allow(XMLData).to receive(:room_id).and_return(0)
      messages = capture_responses { AutoMap.announce_duplicate('[Square]', [build_room]) }
      expect(messages.join("\n")).to include('game UID now: (none)')
    end

    it 'truncates the twin list to MAX_TWINS_SHOWN entries' do
      allow(XMLData).to receive(:room_id).and_return(0)
      twins = Array.new(20) { |i| build_room(id: i) }
      messages = capture_responses { AutoMap.announce_duplicate('[Square]', twins) }
      listed = messages.count { |m| m =~ /^\*\*\*   #/ }
      expect(listed).to eq(AutoMap::MAX_TWINS_SHOWN)
    end

    # Collect the lines the module would print, without touching a global respond.
    def capture_responses
      captured = []
      allow(AutoMap).to receive(:respond) { |msg = ''| captured << msg }
      yield
      captured
    end
  end

  describe '.resolve_room' do
    let(:matched)      { build_room(id: 7) }
    let(:created)      { build_room(id: 99) }
    let(:suspect_twin) { build_room(id: 1, uid: [], title: ['[Square]'], description: ['A plaza.']) }

    context 'on a normal revisit (Room.current matches)' do
      before { allow(Room).to receive(:current).and_return(matched) }

      it 'returns current_or_new without scanning for twins' do
        allow(Room).to receive(:current_or_new).and_return(matched)
        expect(Map).not_to receive(:list)
        expect(AutoMap.resolve_room).to eq(matched)
      end
    end

    context 'when Room.current is nil' do
      before do
        allow(Room).to receive(:current).and_return(nil)
        allow(Room).to receive(:current_or_new).and_return(created)
        allow(XMLData).to receive(:room_title).and_return('[Square]')
        allow(XMLData).to receive(:room_description).and_return('A plaza.')
        allow(XMLData).to receive(:room_id).and_return(230008)
      end

      it 'creates silently when no twin is suspicious' do
        allow(Map).to receive(:list).and_return([])
        expect(AutoMap).not_to receive(:confirm_new_room)
        expect(AutoMap.resolve_room).to eq(created)
      end

      it 'creates silently when prompting is disabled, even with a suspicious twin' do
        AutoMap.confirm = false
        allow(Map).to receive(:list).and_return([suspect_twin])
        expect(AutoMap).not_to receive(:confirm_new_room)
        expect(AutoMap.resolve_room).to eq(created)
      end

      context 'with a suspicious twin and prompting on' do
        before { allow(Map).to receive(:list).and_return([suspect_twin]) }

        it 'creates the room when the user confirms' do
          allow(AutoMap).to receive(:confirm_new_room).and_return(:create)
          expect(AutoMap.resolve_room).to eq(created)
        end

        it 'returns nil (leave unmapped) when the user skips' do
          allow(AutoMap).to receive(:confirm_new_room).and_return(:skip)
          expect(AutoMap.resolve_room).to be_nil
        end

        it 'throws :automap_stop when the user stops' do
          allow(AutoMap).to receive(:confirm_new_room).and_return(:stop)
          expect { AutoMap.resolve_room }.to throw_symbol(:automap_stop)
        end
      end
    end
  end
end
