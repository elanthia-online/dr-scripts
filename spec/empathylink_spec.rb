require 'spec_helper'

# Regression coverage for the pause-handling in empathylink's touch(). The
# script froze a character when its old p_script/u_script helpers paused
# combat-trainer directly (outside $safe_pause_lock): combat-trainer's own
# safe_pause_list paused empathylink between the pause and the unpause, so the
# two scripts paused each other and neither could recover. touch() now uses the
# shared safe_pause_list/safe_unpause_list protocol and an ensure block so the
# unpause (and lock release) always happens.
describe 'Empathylink#touch' do
  before(:all) { load_lic_class('empathylink.lic', 'Empathylink') }

  let(:link) do
    instance = Empathylink.allocate
    instance.instance_variable_set(:@use_hodierna, false)
    instance.instance_variable_set(:@buddies, ['Buddy'])
    instance
  end

  before do
    UserVars.empathylink = {}
    allow(DRC).to receive(:safe_pause_list).and_return(['combat-trainer', 'hunting-buddy'])
    allow(DRC).to receive(:safe_unpause_list)
  end

  it 'pauses other scripts through the shared safe-pause lock' do
    allow(DRC).to receive(:bput).and_return('I could not find')

    link.touch('Buddy')

    expect(DRC).to have_received(:safe_pause_list)
  end

  it 'unpauses exactly the scripts it paused' do
    allow(DRC).to receive(:bput).and_return('I could not find')

    link.touch('Buddy')

    expect(DRC).to have_received(:safe_unpause_list).with(['combat-trainer', 'hunting-buddy'])
  end

  it 'still unpauses when the link cannot be established' do
    allow(DRC).to receive(:bput).and_return('Touch what')

    link.touch('Buddy')

    expect(DRC).to have_received(:safe_unpause_list).with(['combat-trainer', 'hunting-buddy'])
  end

  it 'releases the pause lock even when a heal command raises mid-touch' do
    allow(DRC).to receive(:bput).and_raise(StandardError, 'boom')

    expect { link.touch('Buddy') }.to raise_error(StandardError, 'boom')
    expect(DRC).to have_received(:safe_unpause_list).with(['combat-trainer', 'hunting-buddy'])
  end

  it 'retries until it acquires the safe-pause lock before healing' do
    allow(DRC).to receive(:safe_pause_list).and_return(false, false, ['combat-trainer'])
    allow(link).to receive(:pause)
    allow(link).to receive(:echo)
    allow(DRC).to receive(:bput).and_return('I could not find')

    link.touch('Buddy')

    expect(DRC).to have_received(:safe_pause_list).exactly(3).times
    expect(DRC).to have_received(:safe_unpause_list).with(['combat-trainer'])
  end

  it 'no longer pauses combat-trainer directly via the removed p_script/u_script helpers' do
    expect(link).not_to respond_to(:p_script)
    expect(link).not_to respond_to(:u_script)
  end
end
