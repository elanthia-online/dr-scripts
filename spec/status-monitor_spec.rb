# frozen_string_literal: true

require_relative 'spec_helper'

load_lic_class('status-monitor.lic', 'GameFilter')

RSpec.describe GameFilter do
  let(:legacy_players_line) do
    "<component id='room players'>Also here: Monster Aldric, Brenna who is sitting, " \
      'Corwin (invisible) and Druid Delphine.</component>'
  end

  let(:saga_players_line) do
    "<component id='room players'>Also here: Monster <a exist=\"-10514490\" noun=\"Aldric\">Aldric</a>, " \
      '<a exist="-10514491" noun="Brenna">Brenna</a> who is sitting, ' \
      '<a exist="-10514492" noun="Corwin">Corwin</a> (invisible) and ' \
      'Druid <a exist="-10614301" noun="Delphine">Delphine</a>.</component>'
  end

  let(:filter) { described_class.new }

  before do
    $test_data[:filters] = { 'filter_strings' => [] }
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(/seen_messages_/).and_return(false)
    UserVars.npcs = []
  end

  describe '#update_players' do
    it 'parses names from the legacy players line' do
      filter.update_players(legacy_players_line)
      expect(filter.instance_variable_get(:@room_players)).to eq(%w[Aldric Brenna Corwin Delphine])
    end

    it 'parses names from the Saga players line, where each name is a link' do
      filter.update_players(saga_players_line)
      expect(filter.instance_variable_get(:@room_players)).to eq(%w[Aldric Brenna Corwin Delphine])
    end

    it 'skips an entry that does not end in a name instead of storing nil' do
      filter.update_players("<component id='room players'>Also here: Aldric and <b>?</b>.</component>")
      expect(filter.instance_variable_get(:@room_players)).to eq(%w[Aldric])
    end
  end

  describe '#clean' do
    it 'drops a line that mentions a player in the room' do
      filter.clean(saga_players_line.dup)
      expect(filter.clean('Delphine waves.'.dup)).to be_nil
    end

    it 'keeps processing lines after a players line with an unparseable entry' do
      filter.clean("<component id='room players'>Also here: <b>?</b>.</component>".dup)
      expect(filter.clean('A cold wind blows.'.dup)).to eq('A cold wind blows.')
    end

    it 'treats the Saga room block as non-useful' do
      line = '<resource picture="0"/><room><name>[Bosque Deriel, Burial Ground] (230007)</name>' \
             '<description>A quiet place.</description></room>'
      expect(filter.clean(line.dup)).to be_nil
    end
  end
end
