# frozen_string_literal: true

require_relative 'spec_helper'

# Register#initialize needs the full Lich runtime (parse_args, get_settings, item
# handling), so the class is extracted with load_lic_class and its page-selection
# seams are driven on bare instances.
#
# "read my register" prints one of two layouts, depending on the crafting display
# toggle (both documented in inventory-manager.lic#parse_deed_row):
#   toggle on:  "|   7 | Metal | an agonite ingot | 3V 98Q - pure --Sekmeht |"
#   toggle off: "   7 -- [Metal]  a deed for an agonite ingot (3V 98Q - pure --Sekmeht)"
# The table layout also has a header row whose page column reads "Page".
#
# Covered: which pages `label all` (unlabeled only) and `label force` (every page)
# turn to and label, in both layouts, and that header and totals lines never
# become a page.
load_lic_class('register.lic', 'Register')

describe Register do
  let(:register) { Register.allocate }

  let(:table_layout) do
    [
      '| Page | Type  | Deed                  | Notes                     |',
      '|    3 | Metal | a bronze ingot        |                           |',
      '|    7 | Metal | an agonite ingot      | 3V 98Q - pure --Sekmeht   |',
      '|   12 | Wood  | some mistwood lumber  |                           |',
      '|  104 | Stone | a deed for a boulder  | 5V 40Q                    |',
      'Currently Stored: 4',
      'Maximum:  250'
    ]
  end

  let(:listing_layout) do
    [
      '   3 -- [Metal]  a deed for a bronze ingot',
      '   7 -- [Metal]  a deed for an agonite ingot (3V 98Q - pure --Sekmeht)',
      '  12 -- [Wood]  a deed for some mistwood lumber',
      ' 104 -- [Stone]  a deed for a boulder (5V 40Q)',
      'Currently stored: 4',
      'Maximum:  250'
    ]
  end

  # Feeds the register listing to #search and records each page #find_unlabeled
  # turns to and labels.
  def run_find_unlabeled(lines, *args)
    turned = []
    allow(DRC).to receive(:bput).with('read my register', any_args).and_return('Stored Deeds:')
    allow(register).to receive(:get).and_return(*lines)
    allow(register).to receive(:turn_register?) { |page| turned << page }
    allow(register).to receive(:label_page)
    register.find_unlabeled(*args)
    turned
  end

  describe '#find_unlabeled with force' do
    it 'labels every page of the table layout, notes or not' do
      expect(run_find_unlabeled(table_layout, true)).to eq([3, 7, 12, 104])
      expect(register).to have_received(:label_page).exactly(4).times
    end

    it 'labels every page of the listing layout, notes or not' do
      expect(run_find_unlabeled(listing_layout, true)).to eq([3, 7, 12, 104])
      expect(register).to have_received(:label_page).exactly(4).times
    end

    it 'never treats the table header row as a page' do
      expect(run_find_unlabeled(table_layout.first(1) + table_layout.last(1), true)).to be_empty
    end

    it 'never treats the totals lines as pages' do
      expect(run_find_unlabeled(['Currently Stored: 4', 'Currently stored: 4', 'Maximum:  250'], true)).to be_empty
    end
  end

  describe '#find_unlabeled without force (label all)' do
    it 'labels only the unlabeled pages of the table layout' do
      expect(run_find_unlabeled(table_layout, false)).to eq([3, 12])
    end

    it 'labels only the unlabeled pages of the listing layout' do
      expect(run_find_unlabeled(listing_layout, false)).to eq([3, 12])
    end

    it 'defaults to unlabeled-only when called without an argument' do
      expect(run_find_unlabeled(listing_layout)).to eq([3, 12])
    end
  end

  describe '#search' do
    it 'stops reading at the Maximum line' do
      allow(DRC).to receive(:bput).with('read my register', any_args).and_return('Stored Deeds:')
      allow(register).to receive(:get).and_return('   3 -- [Metal]  a deed for a bronze ingot', 'Maximum:  250', '   9 -- [Metal]  a deed for a tin ingot')

      expect(register.search('^\|?\s+\d+')).to eq(['   3 -- [Metal]  a deed for a bronze ingot'])
    end
  end
end
