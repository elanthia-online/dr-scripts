# frozen_string_literal: true

require_relative 'spec_helper'

# smartlisten.lic is class-less: the whole script is top-level code that reads
# game lines with script.gets in an endless loop. These specs run the real file
# in a fresh object whose script.gets hands out the given lines in order and
# ends the run when they are used up.
#
# script.gets sees the stripped game stream, which also carries other players'
# ESP, speech and whispers. The lecture offer must match only the game's own
# line, which starts with the teacher's name.
RSpec.describe 'smartlisten.lic' do
  # Ends the script's endless loop.
  let(:run_over) { Class.new(StandardError) }

  # Real lines from the text-log corpus.
  let(:bows_line) { 'Barrask begins to lecture you on the proper usage of the Bows skill.' }
  let(:heavy_thrown_line) { 'Damoone begins to lecture you on the proper usage of the Heavy Thrown skill.' }

  let(:listened) { [] }
  let(:pauses) { [] }

  before do
    reset_data
    DRStats.guild = 'Warrior Mage'
    $test_settings = OpenStruct.new(listen_skills: ['Bows', 'Heavy Thrown'], listen_observe: false)
    allow(DRC).to receive(:safe_pause_list) do
      pauses << :pause
      []
    end
    allow(DRC).to receive(:safe_unpause_list)
    allow(DRC).to receive(:listen?) do |teacher, observe|
      listened << [teacher, observe]
      true
    end
  end

  def run_script(lines)
    queue = lines.dup
    over = run_over
    reader = Object.new
    reader.define_singleton_method(:gets) { queue.empty? ? raise(over) : queue.shift }
    runner = Object.new
    runner.define_singleton_method(:script) { reader }
    path = lic_path('smartlisten.lic')
    runner.instance_eval(File.read(path), path, 1)
  rescue run_over
    nil
  end

  def player_lines(text)
    [%([General][Mallory] "#{text}"), %(Mallory says, "#{text}"), %(Mallory whispers, "#{text}")]
  end

  describe 'lecture offers' do
    it 'listens to the teacher named on the real lecture line' do
      run_script([bows_line])
      expect(listened).to eq([['Barrask', false]])
      expect(pauses).to eq([:pause])
    end

    it 'reads multi-word skill names from the real lecture line' do
      run_script([heavy_thrown_line])
      expect(listened).to eq([['Damoone', false]])
    end

    it 'does not listen to a class on a skill it does not want' do
      $test_settings.listen_skills = ['Bows']
      run_script([heavy_thrown_line])
      expect(listened).to be_empty
      expect(pauses).to be_empty
    end

    it 'ignores the lecture line in ESP, speech and whispers' do
      run_script(player_lines(bows_line) + player_lines(heavy_thrown_line))
      expect(listened).to be_empty
      expect(pauses).to be_empty
    end

    it 'still hears the real line after player lines' do
      run_script(player_lines(bows_line) + [bows_line])
      expect(listened).to eq([['Barrask', false]])
      expect(pauses).to eq([:pause])
    end
  end
end
