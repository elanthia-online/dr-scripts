# frozen_string_literal: true

require_relative 'spec_helper'

load_lic_class('corn-maze.lic', 'CornMaze')

# corn-maze.lic follows the maze through Flags (task requests, task done,
# scarecrow built, maze over) and picks its route from the "look" reply
# through DRC.bput. lich-5 tests every one of those patterns against every
# incoming line, and other players' speech, whispers and ESP arrive on lines
# of their own, so each pattern must only match the game's own line.
#
# These specs run the real CornMaze methods with the world stubbed: lines are
# fed through the registered Flags matchers the way lich-5's
# DRParser.check_events does, and the look reply is matched the way lich-5's
# DRC.bput matches it.
RSpec.describe CornMaze do
  let(:maze) do
    CornMaze.allocate.tap { |m| m.setup }
  end

  # Raised by the pause and command guards so a script that would wait or loop
  # forever ends the example instead.
  let(:stuck) { Class.new(StandardError) }

  # Feed a server line through the registered Flags matchers, the way
  # lich-5's DRParser.check_events does for every downstream line.
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

  # lich-5 DRC.bput matching: Strings compile to /x/i, each line is tried
  # against every pattern in order, and the first match's text is returned.
  def model_bput(lines, patterns)
    regexes = patterns.flatten.map { |item| item.is_a?(Regexp) ? item : /#{item}/i }
    lines.each do |line|
      regexes.each do |regex|
        match = line.match(regex)
        return match.to_a.first if match
      end
    end
    ''
  end

  def esp_xml(text)
    %(<pushStream id="thoughts"/>[General][Mallory] "#{text}"<popStream/>)
  end

  def say_xml(text)
    %(<preset id='speech'>Mallory says</preset>, "#{text}")
  end

  def whisper(text)
    %(Mallory whispers, "#{text}")
  end

  def player_lines(text)
    { 'ESP' => esp_xml(text), 'say' => say_xml(text), 'whisper' => whisper(text) }
  end

  def sent
    messages = []
    messages << sent_messages.pop until sent_messages.empty?
    messages
  end

  describe 'short maze (run_short_maze)' do
    let(:search_request) { "Okay, I'd like you to SEARCH around this room." }
    let(:thanks) { "Thanks for all the hard work.  Here's a little something to show my appreciation." }

    def halfling_says(text)
      %(A harried Halfling says, "#{text}")
    end

    # Runs the short maze, delivering one line each time the wait loop pauses.
    def run_short_maze_hearing(*lines)
      queue = lines.dup
      allow(maze).to receive(:join_harried_halfling)
      allow(maze).to receive(:pause) do
        raise stuck, 'still waiting for the maze to end' if queue.empty?

        deliver(queue.shift)
      end
      maze.run_short_maze
    end

    it "does the Halfling's task and stops when the Halfling thanks you" do
      run_short_maze_hearing(halfling_says(search_request), halfling_says(thanks))
      expect(sent).to eq(['search'])
    end

    it 'hears the Halfling with a bold or speech-tagged name' do
      run_short_maze_hearing(%(<pushBold/>A harried Halfling<popBold/> says, "#{search_request}"),
                             %(<preset id='speech'>The Halfling states</preset>, "#{thanks}"))
      expect(sent).to eq(['search'])
    end

    ['ESP', 'say', 'whisper'].each do |shape|
      it "does not act on a task request in a player's #{shape}" do
        run_short_maze_hearing(player_lines(search_request)[shape], halfling_says(thanks))
        expect(sent).to be_empty
      end

      it "does not end the maze on a player's #{shape} of the thanks line" do
        expect { run_short_maze_hearing(player_lines(thanks)[shape]) }.to raise_error(stuck)
      end
    end

    it 'does not act on a player saying a Halfling line to the Halfling' do
      run_short_maze_hearing(%(Mallory says to a harried Halfling, "#{search_request}"), halfling_says(thanks))
      expect(sent).to be_empty
    end
  end

  describe 'long maze flags' do
    let(:moves) { [] }
    let(:maze_done_line) { 'A cheerful Halfling leads you through the twisting passages and brings you to the exit.' }
    let(:task_done_line) { 'You have chased away 10 of 10 mice.' }

    before do
      allow(maze).to receive(:find_start)
      allow(maze).to receive(:get_task)
      allow(maze).to receive(:pause)
      maze.run_long_maze
    end

    # The script's `exit`, raised as an error so a wrong exit fails one example
    # instead of ending the whole run.
    let(:script_exited) { Class.new(StandardError) }

    # Runs the mice task over three rooms, delivering `line` after the first move.
    def mice_task_hearing(line)
      allow(maze).to receive(:exit) { raise script_exited }
      maze.instance_variable_set(:@mice_path, ['east', 'east', 'east'])
      allow(maze).to receive(:finish_task)
      allow(maze).to receive(:custom_move) do |dir, fast = false|
        moves << [dir, fast]
        deliver(line) if moves.size == 1
      end
      maze.mice_task
    end

    describe 'maze over (maze_done)' do
      it 'stops the script when a Halfling leads you out' do
        expect { mice_task_hearing(maze_done_line) }.to raise_error(script_exited)
        expect(moves.size).to eq(1)
      end

      ['ESP', 'say', 'whisper'].each do |shape|
        it "keeps walking the maze on a player's #{shape} of the line" do
          mice_task_hearing(player_lines(maze_done_line)[shape])
          expect(moves.size).to eq(3)
          expect(maze).to have_received(:finish_task)
        end
      end
    end

    describe 'task done (task_done)' do
      it 'stops doing the task and walks fast once the count is complete' do
        mice_task_hearing(task_done_line)
        expect(moves).to eq([['east', false], ['east', true], ['east', true]])
      end

      it 'also hears the return-to-a-Halfling line' do
        mice_task_hearing('Your task is complete.  You should return to one of the Halflings and ASK HALFLING ABOUT TASK again.')
        expect(moves).to eq([['east', false], ['east', true], ['east', true]])
      end

      ['ESP', 'say', 'whisper'].each do |shape|
        it "keeps doing the task on a player's #{shape} of a complete count" do
          mice_task_hearing(player_lines('10 of 10')[shape])
          expect(moves).to eq([['east', false], ['east', false], ['east', false]])
        end
      end
    end

    describe 'scarecrow built (scarecrow_done)' do
      let(:builds) { [] }
      let(:built_line) { 'You put the finishing touches on the corn husk scarecrow.' }

      # Builds in one room; each build attempt delivers the next line.
      def build_hearing(*lines)
        maze.instance_variable_set(:@maze_path, ['north'])
        DRRoom.room_objs = []
        allow(maze).to receive(:finish_task)
        allow(maze).to receive(:custom_move)
        allow(maze).to receive(:fput) do |command|
          builds << command
          raise stuck, 'built 10 times' if builds.size > 10

          deliver(lines.shift) if lines.any?
        end
        maze.scarecrow_task
      end

      it 'stops building when the scarecrow is finished' do
        build_hearing(built_line)
        expect(builds).to eq(['build scarecrow'])
      end

      ['ESP', 'say', 'whisper'].each do |shape|
        it "keeps building after a player's #{shape} of the line" do
          build_hearing(player_lines('You put the finishing touches')[shape], built_line)
          expect(builds).to eq(['build scarecrow', 'build scarecrow'])
        end
      end
    end
  end

  describe 'asking for a task with searching off (get_task)' do
    let(:asks) { [] }
    let(:busy_reply) { "A cheerful Halfling looks at you and says, \"You're already on a task.\"" }
    let(:task_reply) { 'A cheerful Halfling smiles happily at you and gives you a task.' }

    # Each 'ask halfling for task' returns the lines that arrive for it.
    def get_task_hearing(*replies)
      maze.instance_variable_set(:@searching, false)
      DRRoom.npcs = ['Halfling']
      allow(maze).to receive(:pause)
      allow(maze).to receive(:find_start)
      allow(maze).to receive(:wait_for_command)
      allow(DRC).to receive(:bput).with('ask halfling about task', any_args).and_return('A cheerful Halfling smiles happily at you.')
      allow(DRC).to receive(:bput).with('ask halfling for task', any_args) do |command, *patterns|
        asks << command
        raise stuck, 'asked with nothing left to hear' if replies.empty?

        model_bput(replies.shift, patterns)
      end
      maze.get_task
    end

    it 'cancels and asks again when the Halfling says you are already on a task' do
      get_task_hearing([busy_reply], [task_reply])
      expect(sent).to eq(['ask halfling for task cancel', 'ask halfling for task cancel'])
      expect(asks.size).to eq(2)
    end

    ['ESP', 'say', 'whisper'].each do |shape|
      it "does not cancel the task on a player's #{shape} of the Halfling's reply" do
        get_task_hearing([player_lines(busy_reply.delete('"'))[shape].gsub(/<[^>]+>/, ''), task_reply])
        expect(sent).to be_empty
      end
    end
  end

  describe 'route from the look reply (find_start)' do
    let(:moves) { [] }
    let(:entrance_exits) { 'Obvious paths: west, southwest.' }

    # Each look returns the lines that arrive for it.
    def find_start_hearing(*looks)
      XMLData.room_title = '[Sleeping Dragon Corn Maze, Labyrinth]'
      allow(maze).to receive(:pause)
      allow(maze).to receive(:custom_move) { |dir| moves << dir }
      allow(DRC).to receive(:bput).with('look', any_args) do |_command, *patterns|
        raise stuck, 'looked with nothing left to hear' if looks.empty?

        model_bput(looks.shift, patterns)
      end
      maze.find_start
    end

    it 'follows the exits the game lists' do
      find_start_hearing([entrance_exits])
      expect(moves).to eq(['west'] * 4)
    end

    ['ESP', 'say', 'whisper'].each do |shape|
      it "ignores exits in a player's #{shape} and follows the game's" do
        find_start_hearing([player_lines('Obvious paths: north.')[shape].gsub(/<[^>]+>/, ''), entrance_exits])
        expect(moves).to eq(['west'] * 4)
      end
    end
  end
end
