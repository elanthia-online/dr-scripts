# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

load_lic_class('remedy.lic', 'Remedy')

RSpec.describe Remedy do
  def build_instance(alchemy_tools)
    instance = described_class.allocate
    instance.instance_variable_set(:@settings, OpenStruct.new(alchemy_tools: alchemy_tools))
    instance.instance_variable_set(:@recipe_name, 'some eye wash')
    instance
  end

  describe '#resolve_container' do
    # base-recipes.yaml asks for either "mortar" or "bowl".
    let(:mortar_only) { ['rustic mortar', 'rustic pestle', 'mesh sieve'] }
    let(:with_bowl) { ['rustic mortar', 'rustic pestle', 'mesh sieve', 'ceramic bowl'] }
    let(:with_cauldron) { ['rustic mortar', 'rustic pestle', 'iron cauldron'] }

    it 'matches a recipe container against the tool that holds that word' do
      expect(build_instance(mortar_only).send(:resolve_container, 'mortar')).to eq('rustic mortar')
    end

    it 'accepts a cauldron for a recipe that asks for a bowl' do
      expect(build_instance(with_cauldron).send(:resolve_container, 'bowl')).to eq('iron cauldron')
    end

    it 'prefers a bowl for a recipe that asks for a bowl' do
      expect(build_instance(with_bowl).send(:resolve_container, 'bowl')).to eq('ceramic bowl')
    end

    # Before this, an unlisted container returned nil and the script sent the
    # malformed command "get my " with no item name.
    it 'stops when no tool matches a bowl' do
      messages = []
      allow(DRC).to receive(:message) { |text| messages << text }
      expect { build_instance(mortar_only).send(:resolve_container, 'bowl') }.to raise_error(SystemExit)
      expect(messages.first).to include('some eye wash', 'bowl', 'alchemy_tools')
      expect(messages.last).to include('Add your bowl to alchemy_tools')
    end

    it 'stops when no tool matches a mortar' do
      allow(DRC).to receive(:message)
      expect { build_instance(['ceramic bowl']).send(:resolve_container, 'mortar') }.to raise_error(SystemExit)
    end

    it 'stops when alchemy_tools is empty or unset' do
      allow(DRC).to receive(:message)
      [[], nil].each do |tools|
        %w[mortar bowl].each do |requested|
          expect { build_instance(tools).send(:resolve_container, requested) }.to raise_error(SystemExit)
        end
      end
    end

    it 'never returns nil for any container a recipe can ask for' do
      allow(DRC).to receive(:message)
      [mortar_only, with_bowl, with_cauldron, []].each do |tools|
        %w[mortar bowl].each do |requested|
          instance = build_instance(tools)
          begin
            expect(instance.send(:resolve_container, requested)).not_to be_nil
          rescue SystemExit
            # Stopping is the other acceptable answer. A nil is not.
          end
        end
      end
    end
  end

  describe '#work' do
    let(:instance) { build_instance(['rustic mortar', 'rustic pestle', 'mesh sieve']) }

    before do
      allow(instance).to receive(:waitrt?)
      allow(DRCA).to receive(:crafting_magic_routine)
    end

    it 'finishes when not enough pieces of the plant to begin' do
      expect(DRC).to receive(:bput).with(
        'crush my some eye wash with my rustic pestle',
        'Applying the final touches',
        'Interesting thought really... but no.',
        'you just can\'t mix',
        'Try as you might',
        'That craftable requires more pieces of that plant to begin',
        'Roundtime:'
      ).and_return('That craftable requires more pieces of that plant to begin')
      expect(instance).to receive(:finish).and_raise(SystemExit)

      instance.instance_variable_set(:@container, 'rustic mortar')
      instance.instance_variable_set(:@noun, 'some eye wash')
      instance.instance_variable_set(:@pestle, 'rustic pestle')
      instance.instance_variable_set(:@verb, 'crush')
      expect { instance.send(:work, 'crush my some eye wash with my rustic pestle') }.to raise_error(SystemExit)
    end
  end
end
