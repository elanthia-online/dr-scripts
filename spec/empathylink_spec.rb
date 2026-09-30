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

  it 'no longer defines the p_script/u_script helpers that paused combat-trainer directly' do
    # include_all: true so a re-added private/protected helper is still caught
    expect(link.respond_to?(:p_script, true)).to be(false)
    expect(link.respond_to?(:u_script, true)).to be(false)
  end
end

# `link <target> hodierna` on a patient who already has the Hodierna connection
# answers "You sense that you already have such a connection with <target>."
# That response was not in the bput match list, so every re-link attempt hung for
# the full 15s bput timeout (with other scripts paused) before failing.
describe 'Empathylink#hodierna_heal_patient' do
  before(:all) { load_lic_class('empathylink.lic', 'Empathylink') }

  let(:link) { Empathylink.allocate }

  before do
    UserVars.empathylink = {}
    allow(DRC).to receive(:message)
    allow(DRC).to receive(:bput)
      .with('link Tenuk persistent', any_args)
      .and_return('You already have a persistent empathic link')
  end

  it 'offers the already-connected response to bput so it matches instead of timing out' do
    allow(DRC).to receive(:bput).with('link Tenuk hodierna', any_args).and_return('begins to seep through the connection')

    link.hodierna_heal_patient('Tenuk')

    expect(DRC).to have_received(:bput)
      .with('link Tenuk hodierna', any_args, 'You sense that you already have such a connection')
  end

  it 'treats an existing Hodierna connection as linked and holds the target for 30 minutes' do
    allow(DRC).to receive(:bput)
      .with('link Tenuk hodierna', any_args)
      .and_return('You sense that you already have such a connection')

    now = Time.now.to_i
    link.hodierna_heal_patient('Tenuk')

    expect(DRC).to have_received(:message).with('Established link of Hodierna with Tenuk')
    expect(UserVars.empathylink['Tenuk']).to be_between(now + 1800, now + 1801)
  end

  it 'still backs off 5 minutes when the diagnostic link is too fragile' do
    allow(DRC).to receive(:bput)
      .with('link Tenuk hodierna', any_args)
      .and_return('the diagnostic link is too fragile')

    now = Time.now.to_i
    link.hodierna_heal_patient('Tenuk')

    expect(DRC).to have_received(:message).with('Failed to establish link Hodierna with Tenuk')
    expect(UserVars.empathylink['Tenuk']).to be_between(now + 300, now + 301)
  end
end
