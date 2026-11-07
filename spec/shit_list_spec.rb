# frozen_string_literal: true

require 'tmpdir'

load_lic_class('shit-list.lic', 'ShitListRecorder')

# shit-list.lic keeps <checkname>_shit.list, which textsubs reads once when it
# starts to tag each listed player 'Name (SL)'. These specs run the script the
# way a player types it (;shit-list add|rem|clear ...) in a scratch directory
# and check when it restarts textsubs so the tags follow the list.
RSpec.describe ShitListRecorder do
  let(:list_file) { 'Testchar_shit.list' }

  around do |example|
    Dir.mktmpdir('shit-list-spec') { |dir| Dir.chdir(dir) { example.run } }
  end

  before do
    $parse_args_model = true
    $test_settings.integrate_shit_list_with_textsubs = true
    $running_scripts << 'textsubs'
  end

  # Runs the script with the arguments as typed.
  def shit_list(*argv)
    $script_vars = [argv.join(' '), *argv]
    run_lic_entry('shit-list.lic', 'ShitListRecorder')
  end

  describe ';shit-list rem' do
    before { File.write(list_file, "bob, stole my kill\nquimble, rude\n") }

    it 'restarts textsubs after removing a listed name, so its (SL) tag goes' do
      shit_list('rem', 'bob')

      expect(File.read(list_file)).to eq("quimble, rude\n")
      expect($stopped_scripts).to eq(['textsubs'])
      expect($started_scripts).to eq([['textsubs']])
    end

    it 'stops textsubs before starting it again, with a pause between' do
      calls = []
      allow_any_instance_of(described_class).to receive(:stop_script) { |_recorder, name| calls << [:stop, name] }
      allow_any_instance_of(described_class).to receive(:pause) { |_recorder, seconds| calls << [:pause, seconds] }
      allow_any_instance_of(described_class).to receive(:start_script) { |_recorder, name| calls << [:start, name] }

      shit_list('rem', 'bob')

      expect(calls).to eq([[:stop, 'textsubs'], [:pause, 2], [:start, 'textsubs']])
    end

    it 'starts textsubs only once the name is gone from the file, so the new textsubs cannot reread it' do
      list_at_start = nil
      allow_any_instance_of(described_class).to receive(:start_script) { list_at_start = File.read(list_file) }

      shit_list('rem', 'bob')

      expect(list_at_start).to eq("quimble, rude\n")
    end

    it 'leaves textsubs alone when the name is not on the list' do
      shit_list('rem', 'zed')

      expect(displayed_messages).to include('Could not find in your shit list!')
      expect($stopped_scripts).to be_empty
      expect($started_scripts).to be_empty
    end

    it 'leaves textsubs alone for a name that is only part of a listed one' do
      shit_list('rem', 'bo')

      expect(File.read(list_file)).to eq("bob, stole my kill\nquimble, rude\n")
      expect($stopped_scripts).to be_empty
      expect($started_scripts).to be_empty
    end

    it 'does not say the name was missing when it removed it' do
      shit_list('rem', 'bob')

      expect(displayed_messages).to include('Removed bob from your Shit List!')
      expect(displayed_messages).not_to include('Could not find in your shit list!')
    end
  end

  describe ';shit-list clear confirm' do
    before { File.write(list_file, "bob, stole my kill\n") }

    it 'restarts textsubs after emptying the list, so every (SL) tag goes' do
      list_at_start = nil
      allow_any_instance_of(described_class).to receive(:start_script) do |_recorder, name|
        list_at_start = File.read(list_file)
        $started_scripts << [name]
      end

      shit_list('clear', 'confirm')

      expect(list_at_start).to eq('')
      expect($stopped_scripts).to eq(['textsubs'])
      expect($started_scripts).to eq([['textsubs']])
    end
  end

  describe ';shit-list add' do
    it 'still restarts textsubs after adding a name' do
      shit_list('add', 'bob', 'stole my kill')

      expect(File.read(list_file)).to start_with('bob, ')
      expect($stopped_scripts).to eq(['textsubs'])
      expect($started_scripts).to eq([['textsubs']])
    end

    it 'leaves textsubs alone when the name is already listed' do
      File.write(list_file, "bob, stole my kill\n")

      expect { shit_list('add', 'bob', 'again') }.to raise_error(SystemExit)
      expect($stopped_scripts).to be_empty
      expect($started_scripts).to be_empty
    end
  end

  context 'when integrate_shit_list_with_textsubs is off' do
    before do
      $test_settings.integrate_shit_list_with_textsubs = false
      File.write(list_file, "bob, stole my kill\nquimble, rude\n")
    end

    [%w[add zed spammer], %w[rem bob], %w[clear confirm]].each do |argv|
      it "does not restart textsubs on ;shit-list #{argv.join(' ')}" do
        shit_list(*argv)

        expect($stopped_scripts).to be_empty
        expect($started_scripts).to be_empty
      end
    end
  end

  context 'when textsubs is not running' do
    before do
      $running_scripts.delete('textsubs')
      File.write(list_file, "bob, stole my kill\nquimble, rude\n")
    end

    [%w[add zed spammer], %w[rem bob], %w[clear confirm]].each do |argv|
      it "does not start textsubs on ;shit-list #{argv.join(' ')}" do
        shit_list(*argv)

        expect($stopped_scripts).to be_empty
        expect($started_scripts).to be_empty
      end
    end
  end
end
