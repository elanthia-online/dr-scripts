# See spec/spec_helper.rb for the shared harness conventions relied on here:
# the game/commons doubles (DRC, get_noun, list_to_array, fput) and the
# load_lic_class extractor are provided centrally, so this spec neither
# reopens a module nor redefines a top-level method (doing so would clobber
# the shared doubles for the whole run and break other specs).

load_lic_class('trade.lic', 'Trade')

RSpec.describe Trade do
  # find_contracts takes only a container noun; no instance state is needed,
  # so a bare allocated instance keeps the parse/filter logic isolated.
  let(:trade) { Trade.allocate }

  # Issue #4201: the container is rummaged and each entry kept only if it is
  # actually a contract. The bug was a substring match (item.include?('contract'))
  # that also matched a "contract case", so the fix matches on the item noun.
  # DRC.list_to_array preserves the leading space on non-first items (real game
  # behaviour), so results are compared after stripping that incidental space.
  describe '#find_contracts' do
    def stub_look(*items)
      sentence = items.join(', ')
      allow(DRC).to receive(:bput).and_return("you see #{sentence}.")
    end

    def contracts_in(container)
      trade.find_contracts(container).map(&:strip)
    end

    it 'keeps a real contract and rejects a contract case in the same container' do
      stub_look('a Trading contract', 'a contract case', 'some silver coins')
      expect(contracts_in('backpack')).to eq(['a Trading contract'])
    end

    it 'rejects a contract case even when it is the only item (the exact #4201 bug)' do
      stub_look('a contract case')
      expect(contracts_in('backpack')).to eq([])
    end

    it 'returns every contract when several are present' do
      stub_look('a Trading contract', 'a Trading contract', 'a contract case')
      expect(contracts_in('backpack')).to eq(['a Trading contract', 'a Trading contract'])
    end

    it 'returns an empty array when no contracts are present' do
      stub_look('a contract case', 'a leather duffel bag', 'some grass')
      expect(contracts_in('backpack')).to eq([])
    end

    it 'does not match a plural "contracts" noun (only a single contract counts)' do
      stub_look('a bundle of contracts', 'a Trading contract')
      expect(contracts_in('backpack')).to eq(['a Trading contract'])
    end

    it 'reopens a closed container and retries before parsing' do
      responses = ['That is closed', 'you see a Trading contract.']
      allow(DRC).to receive(:bput) { responses.shift }
      expect(contracts_in('contract case')).to eq(['a Trading contract'])

      sent = []
      sent << $sent_messages.pop until $sent_messages.empty?
      expect(sent).to include('open my contract case')
    end
  end
end
