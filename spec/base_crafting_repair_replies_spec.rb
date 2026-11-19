# frozen_string_literal: true

require 'yaml'
require_relative 'spec_helper'

# data/base-crafting.yaml repair_replies: what a repairer answers when handed a
# tool, read by workorders and taskmaster. Each entry is a pattern as DRC.bput
# takes one (a string becomes /entry/i), so these specs match them that way,
# against lines the game sent.
RSpec.describe 'base-crafting.yaml repair_replies' do
  # Loaded the safe way, as a spec or tool reading the data file would: no
  # Ruby-specific tags in it.
  let(:replies) { YAML.load_file(File.expand_path('../data/base-crafting.yaml', __dir__), aliases: true)['repair_replies'] }

  def bput_match?(pattern, line)
    line.match?(pattern.is_a?(Regexp) ? pattern : /#{pattern}/i)
  end

  # Rangu (Hollow Eve 2026, log 6100:9659, 9661) and Catrox (Byd, 2026-11-19
  # 08:21:52 and 2026-11-18 23:03:03).
  let(:rangu_quote) { "Rangu looks over the mortar and says, \"That will cost 240 Kronars to repair.  Just give it to me again if you want, and I'll have it ready in 1 roisaen.\"" }
  let(:catrox_quote) { "Catrox looks over the needles and says, \"That will cost 4036 Kronars to repair.  Just give it to me again if you want, and I'll have it ready in 3 roisaen.\"" }
  let(:rangu_ticket) { "You hand Rangu 240 Kronars and he gives you back a repair ticket.  Rangu says, \"I should be having that done for you in about 1 roisaen.  Don't lose this ticket!  You must have it to reclaim your mortar.\"" }
  let(:no_scratch) { "Catrox shrugs and says, \"There isn't a scratch on that, and I'm not one to rob you.\"" }
  # LOOK AT a ticket (Mithandres, 2026-01-03 00:55:40).
  let(:ticket_ready) { 'Looking at the Granzer ticket you see it is for a small demonscale shield pyrographed with a map of the Blasted Plains.  You recall that your shield should be ready by now.' }

  it 'matches both repairers\' quotes, cost included, with the quote pattern' do
    expect(bput_match?(replies['quote'], rangu_quote)).to be(true)
    expect(bput_match?(replies['quote'], catrox_quote)).to be(true)
    expect(rangu_quote[/#{replies['quote']}/i]).to start_with('cost 240 Kronars')
  end

  it 'lists the quote among the answers to the first give, so a quote ends the wait' do
    expect(replies['offered']).to include(replies['quote'])
    expect(replies['offered'].any? { |pattern| bput_match?(pattern, rangu_quote) }).to be(true)
  end

  it 'answers the first give for a tool with no wear, and declines it' do
    expect(replies['offered'].any? { |pattern| bput_match?(pattern, no_scratch) }).to be(true)
    expect(replies['declined'].any? { |pattern| bput_match?(pattern, no_scratch) }).to be(true)
  end

  it 'does not decline a quote' do
    expect(replies['declined'].none? { |pattern| bput_match?(pattern, rangu_quote) || bput_match?(pattern, catrox_quote) }).to be(true)
  end

  it 'finds the ticket in the answer to the second give' do
    expect(bput_match?(replies['ticket'], rangu_ticket)).to be(true)
    expect(bput_match?(replies['ticket'], rangu_quote)).to be(false)
  end

  it 'tells a ready ticket apart: the ready pattern matches it, and both match a ticket look' do
    expect(bput_match?(replies['ready'], ticket_ready)).to be(true)
    expect(bput_match?(replies['not_ready'], ticket_ready)).to be(true)
  end

  it 'holds only strings, so every pattern loads without Ruby tags' do
    patterns = [replies['quote'], replies['ticket'], replies['need_coin'], replies['ready'], replies['not_ready'], *replies['offered'], *replies['declined']]
    expect(patterns).to all(be_a(String))
    expect { patterns.each { |pattern| Regexp.new(pattern) } }.not_to raise_error
  end
end
