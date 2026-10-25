# frozen_string_literal: true

require_relative 'spec_helper'

# afk.lic is class-less: the whole script is top-level code that reads game
# lines with script.gets? in an endless loop. These specs run the real file in
# a fresh object whose script.gets? hands out the given lines in order and ends
# the run when they are used up (or when the script sends EXIT).
#
# script.gets? sees the stripped game stream, which also carries other
# players' ESP, speech and whispers. Every message the loop acts on must match
# only the game's own line, not another player's line quoting the same words.
RSpec.describe 'afk.lic' do
  # Ends the script's endless loop.
  let(:run_over) { Class.new(StandardError) }

  # The corpus holds no copy of the justice, junk yard or sneak messages,
  # so those lines use the matchers' own words. The idle and feet lines are real.
  let(:justice_line) { 'Now the authorities will try to bring you in for endangering the public.' }
  let(:burn_line) { '"Burn her!  Burn her!" the townsfolk cry, giving you a wide berth.' }
  let(:idle_line) { 'YOU HAVE BEEN IDLE TOO LONG. PLEASE RESPOND.' }
  let(:junk_yard_line) { 'For a current status of how many items you have, use LOOK PORTAL.' }
  let(:sneak_line) { 'You find yourself unable to sneak with items at your feet.' }
  let(:feet_line) { "You notice a steel hhr'ata with a tempered head at your feet, and do not wish to leave it behind." }

  let(:bput_commands) { [] }

  around do |example|
    saved = [$_IDLETIMESTAMP_, $_SCRIPTIDLETIMESTAMP_]
    example.run
  ensure
    $_IDLETIMESTAMP_, $_SCRIPTIDLETIMESTAMP_ = saved
  end

  before do
    reset_data
    @now = Time.at(1_800_000_000)
    allow(Time).to receive(:now) { @now }
    $_IDLETIMESTAMP_ = @now
    $_SCRIPTIDLETIMESTAMP_ = @now
    $test_settings = OpenStruct.new(health_threshold: 50, depart_on_death: false, depart_type: 'item',
                                    afk_justice_threshold: 4, slack_username: nil)
    $test_data.spells = {
      'spell_data' => {
        'Shadows'      => { 'abbrev' => 'shadows', 'triggers_justice' => true },
        'Clear Vision' => { 'abbrev' => 'cv', 'triggers_justice' => false }
      }
    }
    DRSpells._set_active_spells({ 'Shadows' => 300, 'Clear Vision' => 200 })
    DRStats.health = 100
    DRStats.spirit = 100
    $running_scripts = ['go2']
    allow(DRC).to receive(:bput) do |command, *_patterns|
      bput_commands << command
      bput_commands.size == 1 ? "You pick up a steel hhr'ata." : 'Stow what?'
    end
  end

  def run_script(lines)
    queue = lines.dup
    over = run_over
    clock = self
    reader = Object.new
    reader.define_singleton_method(:gets?) { queue.empty? ? raise(over) : queue.shift }
    runner = Object.new
    runner.define_singleton_method(:script) { reader }
    runner.define_singleton_method(:pause) { |seconds = 1| clock.advance(seconds) }
    runner.define_singleton_method(:fput) do |message|
      sent_messages << message
      raise over if message == 'exit'
    end
    path = lic_path('afk.lic')
    runner.instance_eval(File.read(path), path, 1)
  rescue run_over
    nil
  end

  def advance(seconds)
    @now += seconds
  end

  def sent
    messages = []
    messages << sent_messages.pop until sent_messages.empty?
    messages
  end

  def player_lines(text)
    [%([General][Mallory] "#{text}"), %(Mallory says, "#{text}"), %(Mallory whispers, "#{text}")]
  end

  describe 'justice messages' do
    it 'releases justice-triggering spells for each real justice line' do
      run_script([justice_line, burn_line])
      expect(sent).to eq(['release shadows spell', 'release shadows spell'])
    end

    it 'logs out after more real justice lines than the threshold' do
      run_script([justice_line] * 5)
      expect(sent).to eq(['release shadows spell'] * 5 + ['exit'])
    end

    it 'ignores the justice message in ESP, speech and whispers' do
      run_script(player_lines(justice_line) + player_lines(justice_line.sub('Now the ', '')))
      expect(sent).to be_empty
    end

    it 'does not log out on more player justice lines than the threshold' do
      run_script(player_lines(justice_line) * 2)
      expect(sent).not_to include('exit')
    end

    it 'ignores the Burn message in ESP, speech and whispers' do
      run_script(player_lines(burn_line))
      expect(sent).to be_empty
    end
  end

  describe 'items at your feet' do
    it 'stows the items and stops go2 on the real sneak line' do
      run_script([sneak_line])
      expect(bput_commands).to eq(['stow feet', 'stow feet'])
      expect($stopped_scripts).to eq(['go2'])
    end

    it 'stows the items and stops go2 on the real feet line' do
      run_script([feet_line])
      expect(bput_commands).to eq(['stow feet', 'stow feet'])
      expect($stopped_scripts).to eq(['go2'])
    end

    it 'ignores the sneak and feet messages in ESP, speech and whispers' do
      run_script(player_lines(sneak_line) + player_lines(feet_line))
      expect(bput_commands).to be_empty
      expect($stopped_scripts).to be_empty
    end
  end

  describe 'idle warning' do
    it 'sends a harmless command on the real idle line' do
      run_script([idle_line])
      expect(sent).to contain_exactly(a_string_matching(/\A(?:tdp|time|age)\z/))
    end

    it 'ignores the idle message in ESP, speech and whispers' do
      run_script(player_lines(idle_line))
      expect(sent).to be_empty
    end
  end

  describe 'junk yard' do
    before { XMLData.room_title = '[[A Junk Yard]]' }

    it 'logs out after 60 seconds in the junk yard on the real line' do
      run_script([junk_yard_line])
      expect(sent).to eq(['exit'])
      expect(displayed_messages).to include(a_string_starting_with("Looks like you're in the junk yard."))
    end

    it 'ignores the junk yard message in ESP, speech and whispers' do
      run_script(player_lines(junk_yard_line))
      expect(sent).to be_empty
      expect(displayed_messages).not_to include(a_string_starting_with("Looks like you're in the junk yard."))
    end
  end
end
