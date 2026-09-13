# frozen_string_literal: true

require 'ostruct'
require_relative 'spec_helper'

load_lic_class('corn-maze.lic', 'CornMaze')

RSpec.describe CornMaze do
  let(:corn_maze) { CornMaze.allocate }

  describe '#stow_thing' do
    let(:settings) { OpenStruct.new(cornmaze_containers: []) }

    before do
      corn_maze.instance_variable_set(:@settings, settings)
      corn_maze.instance_variable_set(:@worn_trashcan, nil)
      corn_maze.instance_variable_set(:@worn_trashcan_verb, nil)
    end

    context 'when a custom cornmaze_container accepts the item' do
      let(:settings) { OpenStruct.new(cornmaze_containers: ['backpack', 'pouch']) }

      it 'returns early when put away in the first container' do
        expect(DRCI).to receive(:put_away_item?).with('gem', 'backpack').and_return(true)
        expect(DRCI).not_to receive(:put_away_item?).with('gem', 'pouch')
        expect(DRCI).not_to receive(:stow_item?)

        corn_maze.send(:stow_thing, 'gem')
      end

      it 'tries subsequent containers when the first fails' do
        expect(DRCI).to receive(:put_away_item?).with('gem', 'backpack').and_return(false)
        expect(DRCI).to receive(:put_away_item?).with('gem', 'pouch').and_return(true)
        expect(DRCI).not_to receive(:stow_item?)

        corn_maze.send(:stow_thing, 'gem')
      end
    end

    context 'when no custom containers are configured' do
      it 'falls back to general stow_item?' do
        expect(DRCI).to receive(:stow_item?).with('gem').and_return(true)

        corn_maze.send(:stow_thing, 'gem')
      end
    end

    context 'when all containers and general stow fail' do
      let(:settings) { OpenStruct.new(cornmaze_containers: ['backpack']) }

      it 'warns and disposes trash' do
        expect(DRCI).to receive(:put_away_item?).with('junk', 'backpack').and_return(false)
        expect(DRCI).to receive(:stow_item?).with('junk').and_return(false)
        expect(DRC).to receive(:message).with("YOU'VE RUN OUT OF ROOM!  GET SOME MORE SPACE, YOU LAZY SLOB!")
        expect(DRCI).to receive(:dispose_trash).with('junk', nil, nil)

        corn_maze.send(:stow_thing, 'junk')
      end
    end
  end
end
