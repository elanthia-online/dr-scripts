# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

# Minimal stub modules for game interaction
class EquipmentManager
  def empty_hands; end
end

load_lic_class('enchant.lic', 'Enchant')

RSpec.describe Enchant do
  before(:each) do
    reset_data
    $mock_bput_result = nil
    $mock_drci_exists = nil
    $mock_drci_get_item = nil
    $mock_drca_cast_spell = nil
    $left_hand = nil
    $right_hand = nil
  end

  # Helper: create a bare Enchant instance without running initialize
  def build_instance(**overrides)
    instance = Enchant.allocate
    # Set default ivars
    instance.instance_variable_set(:@settings, OpenStruct.new(
                                                 crafting_container: 'backpack',
                                                 crafting_items_in_container: ['burin'],
                                                 enchanting_belt: 'toolbelt',
                                                 mark_crafted_goods: false,
                                                 worn_trashcan: 'bucket',
                                                 worn_trashcan_verb: 'put',
                                                 enchanting_tools: ['brazier', 'fount', 'aug loop', 'rod', 'burin'],
                                                 master_crafting_book: nil,
                                                 cube_armor_piece: nil
                                               ))
    instance.instance_variable_set(:@bag, 'backpack')
    instance.instance_variable_set(:@bag_items, ['burin'])
    instance.instance_variable_set(:@belt, 'toolbelt')
    instance.instance_variable_set(:@brazier, 'brazier')
    # @brazier_ref is derived in initialize (which these specs bypass); the
    # command-building methods interpolate it directly.
    instance.instance_variable_set(:@brazier_ref, 'brazier')
    instance.instance_variable_set(:@fount, 'fount')
    instance.instance_variable_set(:@loop, 'aug loop')
    instance.instance_variable_set(:@imbue_wand, 'rod')
    instance.instance_variable_set(:@burin, 'burin')
    instance.instance_variable_set(:@item, 'totem')
    instance.instance_variable_set(:@baseitem, 'totem')
    instance.instance_variable_set(:@use_own_brazier, true)
    instance.instance_variable_set(:@worn_trashcan, 'bucket')
    instance.instance_variable_set(:@worn_trashcan_verb, 'put')
    instance.instance_variable_set(:@stamp, false)
    instance.instance_variable_set(:@equipment_manager, EquipmentManager.new)
    overrides.each { |k, v| instance.instance_variable_set(:"@#{k}", v) }
    instance
  end

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  describe 'constants' do
    it 'defines ANALYZE_READY_PATTERNS as frozen array' do
      expect(Enchant::ANALYZE_READY_PATTERNS).to be_frozen
      expect(Enchant::ANALYZE_READY_PATTERNS).to be_an(Array)
    end

    it 'defines BRAZIER_CONTENTS_PATTERN with named capture' do
      pattern = Enchant::BRAZIER_CONTENTS_PATTERN
      match = pattern.match('On the brass brazier you see a fount and a totem.')
      expect(match).not_to be_nil
      expect(match[:items]).to eq('a fount and a totem')
    end

    it 'defines FLAG_NAMES as frozen array' do
      expect(Enchant::FLAG_NAMES).to be_frozen
      expect(Enchant::FLAG_NAMES).to include('enchant-complete')
    end
  end

  # ---------------------------------------------------------------------------
  # setup_flags / cleanup_flags
  # ---------------------------------------------------------------------------

  describe '#setup_flags' do
    it 'calls Flags.add for all required flags' do
      instance = build_instance

      expect(Flags).to receive(:add).with('enchant-focus', anything)
      expect(Flags).to receive(:add).with('enchant-meditate', anything)
      expect(Flags).to receive(:add).with('enchant-imbue', anything)
      expect(Flags).to receive(:add).with('enchant-push', anything)
      expect(Flags).to receive(:add).with('enchant-sigil', anything)
      expect(Flags).to receive(:add).with('enchant-complete', anything, anything, anything, anything)
      expect(Flags).to receive(:add).with('imbue-failed', anything)
      expect(Flags).to receive(:add).with('imbue-backlash', anything)

      instance.send(:setup_flags)
    end
  end

  describe '#cleanup_flags' do
    it 'calls Flags.delete for all flags' do
      instance = build_instance

      Enchant::FLAG_NAMES.each do |flag|
        expect(Flags).to receive(:delete).with(flag)
      end

      instance.send(:cleanup_flags)
    end
  end

  # ---------------------------------------------------------------------------
  # empty_brazier - named capture extraction
  # ---------------------------------------------------------------------------

  describe '#empty_brazier' do
    it 'extracts items using named capture from brazier contents' do
      instance = build_instance

      allow(DRC).to receive(:bput).and_return('On the brass brazier you see a fount and a totem.')
      expect(DRCI).to receive(:get_item?).with('fount', 'brazier').and_return(true)
      expect(DRCI).to receive(:get_item?).with('totem', 'brazier').and_return(true)
      expect(DRCC).to receive(:stow_crafting_item).twice

      instance.send(:empty_brazier)
    end

    it 'handles nothing on brazier' do
      instance = build_instance

      allow(DRC).to receive(:bput).and_return('There is nothing')
      expect(DRCI).not_to receive(:get_item?)

      instance.send(:empty_brazier)
    end

    it 'logs error when item cannot be retrieved' do
      instance = build_instance

      allow(DRC).to receive(:bput).and_return('On the brass brazier you see a fount.')
      expect(DRCI).to receive(:get_item?).with('fount', 'brazier').and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to get fount/)

      instance.send(:empty_brazier)
    end
  end

  # ---------------------------------------------------------------------------
  # scribe - the main bug fix (waitrt? before recursive call)
  # ---------------------------------------------------------------------------

  describe '#scribe' do
    it 'checks enchant-complete flag before scribing again' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-focus').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-meditate').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-push').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-imbue').and_return(nil)
      allow(Flags).to receive(:[]).with('imbue-backlash').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-complete').and_return(true)

      expect(instance).to receive(:handle_complete_flag)
      expect(DRC).not_to receive(:bput)

      instance.send(:scribe)
    end

    it 'checks enchant-sigil flag and handles it' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return({ type: 'induction ', order: 'primary' })

      expect(instance).to receive(:handle_sigil_flag)

      instance.send(:scribe)
    end

    it 'checks imbue-backlash flag' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-focus').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-meditate').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-push').and_return(nil)
      allow(Flags).to receive(:[]).with('enchant-imbue').and_return(nil)
      allow(Flags).to receive(:[]).with('imbue-backlash').and_return(true)

      expect(instance).to receive(:handle_backlash_flag)

      instance.send(:scribe)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_sigil_flag
  # ---------------------------------------------------------------------------

  describe '#handle_sigil_flag' do
    it 'extracts sigil type from flag and traces it' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return({ type: 'induction ', order: 'primary' })
      allow(Flags).to receive(:reset).with('enchant-sigil')

      expect(DRCC).to receive(:stow_crafting_item).with('burin', 'backpack', 'toolbelt')
      expect(instance).to receive(:trace_sigil).with('induction')
      expect(DRCC).to receive(:get_crafting_item)
      expect(instance).to receive(:scribe)

      instance.send(:handle_sigil_flag)
    end

    it 'defaults to congruence sigil when type is empty' do
      instance = build_instance

      allow(Flags).to receive(:[]).with('enchant-sigil').and_return({ type: '', order: 'primary' })
      allow(Flags).to receive(:reset).with('enchant-sigil')

      expect(instance).to receive(:trace_sigil).with('congruence')
      allow(DRCC).to receive(:stow_crafting_item)
      allow(DRCC).to receive(:get_crafting_item)
      allow(instance).to receive(:scribe)

      instance.send(:handle_sigil_flag)
    end
  end

  # ---------------------------------------------------------------------------
  # trace_sigil
  # ---------------------------------------------------------------------------

  describe '#trace_sigil' do
    it 'gets sigil, studies it, and traces on item' do
      instance = build_instance

      expect(DRCI).to receive(:get_item?).with('induction sigil').and_return(true)
      expect(DRC).to receive(:bput).with('study my induction sigil', Enchant::SIGIL_STUDY_SUCCESS)
      expect(DRC).to receive(:bput).with('trace totem on brazier', Enchant::SIGIL_TRACE_SUCCESS)

      instance.send(:trace_sigil, 'induction')
    end

    it 'logs error and returns early when sigil not found' do
      instance = build_instance

      expect(DRCI).to receive(:get_item?).with('induction sigil').and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to get induction sigil/)
      expect(DRC).not_to receive(:bput)

      instance.send(:trace_sigil, 'induction')
    end

    it 'does not trace when the sigil was never memorized' do
      instance = build_instance

      allow(instance).to receive(:study_sigil).with('induction').and_return(false)
      expect(DRC).not_to receive(:bput)

      instance.send(:trace_sigil, 'induction')
    end

    it 'traces without touching a loose scroll when the book supplied the sigil' do
      instance = build_instance(sigil_book: 'small sigil book')

      allow(instance).to receive(:study_sigil_from_book).with('induction').and_return(true)
      expect(DRCI).not_to receive(:get_item?)
      expect(DRC).to receive(:bput).with('trace totem on brazier', Enchant::SIGIL_TRACE_SUCCESS)

      instance.send(:trace_sigil, 'induction')
    end
  end

  # ---------------------------------------------------------------------------
  # Sigil book
  #
  # Fixtures are verbatim game output. Note that page numbers are global to the
  # book and are NOT renumbered per section (congruence 1-2, nurture 3-5), but
  # they DO renumber when a study blanks a page.
  # ---------------------------------------------------------------------------

  let(:contents_read) do
    [
      'You page through the book to see what scrolls it contains.',
      '   Page -- Sigil Type, Clarity, Precision',
      '      1 -- congruence, distinct (54), broad (13)',
      '      2 -- congruence, distinct (54), broad (13)',
      '      3 -- nurture, rough (26), broad (21)',
      '      4 -- nurture, rough (26), broad (21)',
      '      5 -- nurture, rough (19), broad (15)',
      '[You can turn the book TO PAGE # or TO SIGIL {Sigil Type}.]'
    ]
  end

  let(:nurture_section_read) do
    [
      'You page through the nurture section to see what scrolls it contains.',
      '   Page -- Sigil Type, Clarity, Precision',
      '      3 -- nurture, rough (26), broad (21)',
      '      4 -- nurture, rough (26), broad (21)',
      '      5 -- nurture, rough (19), broad (15)',
      '[You can turn the book TO PAGE # or TO CONTENTS.]'
    ]
  end

  let(:empty_section_read) do
    [
      'You page through the rarefaction section to see what scrolls it contains.',
      '   Page -- Sigil Type, Clarity, Precision',
      '[You can turn the book TO PAGE # or TO CONTENTS.]'
    ]
  end

  let(:nurture_page_read) do
    [
      'On this page you see a rough nurture sigil comprised of broad strokes.  You can STUDY the book to bring it into your mind, or PULL the book to remove it.',
      '   --=== Nurture sigil ===--',
      '',
      '   Cardinality: Primary',
      '       Clarity: 26 (rough)',
      '     Precision: 21 (comprised of broad strokes)',
      '[You can now STUDY the book to memorize the sigil.]'
    ]
  end

  let(:study_success) { "You commit the sigil's design to memory rendering the page blank, and turn the book back to the contents." }
  let(:study_appraise) { 'You study the book and determine it is well-suited for holding sigil-scrolls.  These scrolls can be PUT into the book.' }

  # Two books with DIFFERENT nouns, so a spec can tell which one a command
  # addressed. In game they are usually both "book", which is exactly why the
  # implementation stows one before picking up the next.
  let(:first_book) { 'small sigil book' }
  let(:second_book) { 'battered sigil tome' }

  # Stubs the two READs the book flow issues against one book, keyed by their
  # start pattern.
  def stub_book_reads(noun: 'book', section_lines:, page_lines: [])
    allow(Lich::Util).to receive(:issue_command)
      .with("read my #{noun}", Enchant::SIGIL_BOOK_READ_HEADER, Enchant::SIGIL_BOOK_READ_FOOTER, silent: true, quiet: true, timeout: 3)
      .and_return(section_lines)
    allow(Lich::Util).to receive(:issue_command)
      .with("read my #{noun}", Enchant::SIGIL_BOOK_PAGE_HEADER, Enchant::SIGIL_BOOK_PAGE_FOOTER, silent: true, quiet: true, timeout: 3)
      .and_return(page_lines)
  end

  describe 'sigil book constants' do
    it 'parses a page row into page number and sigil type' do
      match = Enchant::SIGIL_BOOK_PAGE_ROW.match('      3 -- nurture, rough (26), broad (21)')

      expect(match[:page]).to eq('3')
      expect(match[:type]).to eq('nurture')
    end

    it 'does not treat the table header as a page row' do
      expect(Enchant::SIGIL_BOOK_PAGE_ROW).not_to match('   Page -- Sigil Type, Clarity, Precision')
    end

    it 'parses the sigil type off a page banner' do
      match = Enchant::SIGIL_BOOK_PAGE_TYPE.match('   --=== Congruence sigil ===--')

      expect(match[:type]).to eq('Congruence')
    end

    it 'matches the read footer in both the contents and section views' do
      expect(Enchant::SIGIL_BOOK_READ_FOOTER).to match('[You can turn the book TO PAGE # or TO SIGIL {Sigil Type}.]')
      expect(Enchant::SIGIL_BOOK_READ_FOOTER).to match('[You can turn the book TO PAGE # or TO CONTENTS.]')
    end

    it 'matches the section and page turn confirmations' do
      section = Enchant::SIGIL_BOOK_TURN_SECTION.match('You turn the book to the congruence section.')
      page = Enchant::SIGIL_BOOK_TURN_PAGE.match('You turn the book to page 1.')

      expect(section[:section]).to eq('congruence')
      expect(page[:page]).to eq('1')
    end

    it 'distinguishes a memorizing study from the book appraisal' do
      expect(Enchant::SIGIL_BOOK_STUDY_SUCCESS).to match(study_success)
      expect(Enchant::SIGIL_BOOK_STUDY_SUCCESS).not_to match(study_appraise)
      expect(Enchant::SIGIL_BOOK_STUDY_APPRAISE).to match(study_appraise)
    end
  end

  describe '#sigil_books' do
    it 'is empty when nothing is configured' do
      expect(build_instance.send(:sigil_books)).to eq([])
    end

    it 'keeps a configured list in order' do
      instance = build_instance(sigil_books: [first_book, second_book])

      expect(instance.send(:sigil_books)).to eq([first_book, second_book])
    end

    it 'accepts a bare string as a single book' do
      instance = build_instance(sigil_books: first_book)

      expect(instance.send(:sigil_books)).to eq([first_book])
    end
  end

  describe '#sigil_book_noun' do
    it 'reduces a book name to its bare noun' do
      instance = build_instance

      expect(instance.send(:sigil_book_noun, first_book)).to eq('book')
      expect(instance.send(:sigil_book_noun, second_book)).to eq('tome')
    end
  end

  describe '#study_sigil' do
    it 'prefers the books and skips the loose scroll entirely' do
      instance = build_instance(sigil_books: [first_book])

      expect(instance).to receive(:study_sigil_from_book).with('nurture').and_return(true)
      expect(DRCI).not_to receive(:get_item?)

      expect(instance.send(:study_sigil, 'nurture')).to be true
    end

    it 'falls back to a loose scroll when no book can supply the sigil' do
      instance = build_instance(sigil_books: [first_book])

      allow(instance).to receive(:study_sigil_from_book).with('nurture').and_return(false)
      expect(DRCI).to receive(:get_item?).with('nurture sigil').and_return(true)
      expect(DRC).to receive(:bput).with('study my nurture sigil', Enchant::SIGIL_STUDY_SUCCESS)

      expect(instance.send(:study_sigil, 'nurture')).to be true
    end

    it 'returns false when neither the books nor a loose scroll has the sigil' do
      instance = build_instance(sigil_books: [first_book])

      allow(instance).to receive(:study_sigil_from_book).and_return(false)
      allow(DRCI).to receive(:get_item?).and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to get nurture sigil/)

      expect(instance.send(:study_sigil, 'nurture')).to be false
    end
  end

  describe '#study_sigil_from_book' do
    it 'returns false without touching the game when no books are configured' do
      instance = build_instance

      expect(DRCC).not_to receive(:get_crafting_item)
      expect(DRC).not_to receive(:bput)

      expect(instance.send(:study_sigil_from_book, 'nurture')).to be false
    end

    it 'takes the sigil from the first book that has it' do
      instance = build_instance(sigil_books: [first_book, second_book])

      expect(instance).to receive(:study_sigil_from_this_book).with(first_book, 'nurture').and_return(true)
      expect(instance).not_to receive(:study_sigil_from_this_book).with(second_book, anything)

      expect(instance.send(:study_sigil_from_book, 'nurture')).to be true
    end

    it 'moves on to the next book when the first one is out of that sigil' do
      instance = build_instance(sigil_books: [first_book, second_book])

      expect(instance).to receive(:study_sigil_from_this_book).with(first_book, 'nurture').and_return(false)
      expect(instance).to receive(:study_sigil_from_this_book).with(second_book, 'nurture').and_return(true)

      expect(instance.send(:study_sigil_from_book, 'nurture')).to be true
    end

    it 'reports once when no configured book holds the sigil' do
      instance = build_instance(sigil_books: [first_book, second_book])

      allow(instance).to receive(:study_sigil_from_this_book).and_return(false)

      expect(Lich::Messaging).to receive(:msg).with('bold', /No nurture sigil in your sigil books/).once

      expect(instance.send(:study_sigil_from_book, 'nurture')).to be false
    end

    it 'searches every configured book against real book output before giving up' do
      instance = build_instance(sigil_books: [first_book, second_book])

      allow(DRCI).to receive(:in_hands?).and_return(true)
      allow(DRC).to receive(:bput).and_return(study_success)
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRCC).to receive(:stow_crafting_item)
      # The first book is out of nurture; the second still has pages.
      stub_book_reads(noun: 'book', section_lines: empty_section_read)
      stub_book_reads(noun: 'tome', section_lines: nurture_section_read, page_lines: nurture_page_read)

      expect(instance.send(:study_sigil_from_book, 'nurture')).to be true
      expect(DRCC).to have_received(:get_crafting_item).with(first_book, 'backpack', ['burin'], 'toolbelt', true)
      expect(DRCC).to have_received(:get_crafting_item).with(second_book, 'backpack', ['burin'], 'toolbelt', true)
    end

    it 'stows each book it picks up, including ones that had nothing' do
      instance = build_instance(sigil_books: [first_book, second_book])

      allow(DRCI).to receive(:in_hands?).and_return(true)
      allow(DRC).to receive(:bput).and_return(study_success)
      allow(DRCC).to receive(:get_crafting_item)
      allow(Lich::Messaging).to receive(:msg)
      stub_book_reads(noun: 'book', section_lines: empty_section_read)
      stub_book_reads(noun: 'tome', section_lines: nurture_section_read, page_lines: nurture_page_read)

      expect(DRCC).to receive(:stow_crafting_item).with(first_book, 'backpack', 'toolbelt')
      expect(DRCC).to receive(:stow_crafting_item).with(second_book, 'backpack', 'toolbelt')

      instance.send(:study_sigil_from_book, 'nurture')
    end
  end

  describe '#study_sigil_from_this_book' do
    it 'turns to the section, reads it, turns to a page, confirms it, then studies' do
      instance = build_instance(sigil_books: [first_book])

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      allow(DRCC).to receive(:get_crafting_item)
      stub_book_reads(section_lines: nurture_section_read, page_lines: nurture_page_read)

      expect(DRC).to receive(:bput)
        .with('turn my book to sigil nurture', { 'timeout' => 3, 'suppress_no_match' => true }, Enchant::SIGIL_BOOK_TURN_SECTION)
      expect(DRC).to receive(:bput)
        .with('turn my book to page 3', { 'timeout' => 3, 'suppress_no_match' => true }, Enchant::SIGIL_BOOK_TURN_PAGE)
      expect(DRC).to receive(:bput)
        .with('study my book', Enchant::SIGIL_BOOK_STUDY_SUCCESS, Enchant::SIGIL_BOOK_STUDY_APPRAISE, Enchant::SIGIL_BOOK_NOT_HELD)
        .and_return(study_success)
      expect(DRCC).to receive(:stow_crafting_item).with(first_book, 'backpack', 'toolbelt')

      expect(instance.send(:study_sigil_from_this_book, first_book, 'nurture')).to be true
    end

    it 'returns false without studying when this book has no page of that type' do
      instance = build_instance(sigil_books: [first_book])

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRC).to receive(:bput)
      stub_book_reads(section_lines: empty_section_read)

      expect(DRC).not_to receive(:bput).with('study my book', any_args)

      expect(instance.send(:study_sigil_from_this_book, first_book, 'rarefaction')).to be false
    end

    it 'treats the book appraisal as a failed study rather than a memorized sigil' do
      instance = build_instance(sigil_books: [first_book])

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      allow(DRCC).to receive(:get_crafting_item)
      stub_book_reads(section_lines: nurture_section_read, page_lines: nurture_page_read)
      allow(DRC).to receive(:bput).and_return(study_appraise)

      expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to study nurture sigil from small sigil book/)

      expect(instance.send(:study_sigil_from_this_book, first_book, 'nurture')).to be false
    end

    it 'stows the book even when the study fails' do
      instance = build_instance(sigil_books: [first_book])

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRC).to receive(:bput)
      stub_book_reads(section_lines: empty_section_read)
      allow(Lich::Messaging).to receive(:msg)

      expect(DRCC).to receive(:stow_crafting_item).with(first_book, 'backpack', 'toolbelt')

      instance.send(:study_sigil_from_this_book, first_book, 'nurture')
    end

    it 'does not stow anything when the book could not be picked up' do
      instance = build_instance(sigil_books: [first_book])

      allow(DRCI).to receive(:in_hands?).with('book').and_return(false)
      allow(DRCC).to receive(:get_crafting_item)
      allow(Lich::Messaging).to receive(:msg)

      expect(DRCC).not_to receive(:stow_crafting_item)

      expect(instance.send(:study_sigil_from_this_book, first_book, 'nurture')).to be false
    end

    it 're-reads the book for every sigil, because studying renumbers the pages' do
      instance = build_instance(sigil_books: [first_book])

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRC).to receive(:bput).and_return(study_success)
      allow(DRCC).to receive(:stow_crafting_item)
      stub_book_reads(section_lines: nurture_section_read, page_lines: nurture_page_read)

      instance.send(:study_sigil_from_this_book, first_book, 'nurture')
      instance.send(:study_sigil_from_this_book, first_book, 'nurture')

      expect(Lich::Util).to have_received(:issue_command)
        .with('read my book', Enchant::SIGIL_BOOK_READ_HEADER, Enchant::SIGIL_BOOK_READ_FOOTER, silent: true, quiet: true, timeout: 3)
        .twice
    end
  end

  describe '#get_sigil_book' do
    it 'fetches from the crafting container or belt and confirms it landed in hand' do
      instance = build_instance

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      expect(DRCC).to receive(:get_crafting_item).with(first_book, 'backpack', ['burin'], 'toolbelt', true)

      expect(instance.send(:get_sigil_book, first_book)).to be true
    end

    it 'always fetches, because a held book may be a different book of the same noun' do
      instance = build_instance

      allow(DRCI).to receive(:in_hands?).with('tome').and_return(true)
      expect(DRCC).to receive(:get_crafting_item).with(second_book, 'backpack', ['burin'], 'toolbelt', true)

      instance.send(:get_sigil_book, second_book)
    end

    it 'reports failure when the book never reaches a hand' do
      instance = build_instance

      allow(DRCI).to receive(:in_hands?).with('book').and_return(false)
      allow(DRCC).to receive(:get_crafting_item)
      expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to get small sigil book/)

      expect(instance.send(:get_sigil_book, first_book)).to be false
    end
  end

  describe '#find_sigil_page' do
    it 'returns the first page of the requested type' do
      instance = build_instance

      allow(DRC).to receive(:bput)
      stub_book_reads(section_lines: nurture_section_read)

      expect(instance.send(:find_sigil_page, first_book, 'nurture')).to eq(3)
    end

    it 'ignores pages of other types when reading the contents view' do
      instance = build_instance

      allow(DRC).to receive(:bput)
      stub_book_reads(section_lines: contents_read)

      expect(instance.send(:find_sigil_page, first_book, 'nurture')).to eq(3)
    end

    it 'matches the sigil type case-insensitively' do
      instance = build_instance

      allow(DRC).to receive(:bput)
      stub_book_reads(section_lines: nurture_section_read)

      expect(instance.send(:find_sigil_page, first_book, 'Nurture')).to eq(3)
    end

    it 'addresses the book by its own noun' do
      instance = build_instance

      stub_book_reads(noun: 'tome', section_lines: nurture_section_read)
      expect(DRC).to receive(:bput)
        .with('turn my tome to sigil nurture', { 'timeout' => 3, 'suppress_no_match' => true }, Enchant::SIGIL_BOOK_TURN_SECTION)

      expect(instance.send(:find_sigil_page, second_book, 'nurture')).to eq(3)
    end

    it 'returns nil for a section that reads empty' do
      instance = build_instance

      allow(DRC).to receive(:bput)
      stub_book_reads(section_lines: empty_section_read)

      expect(instance.send(:find_sigil_page, first_book, 'rarefaction')).to be_nil
    end

    it 'returns nil when the read times out and captures nothing' do
      instance = build_instance

      allow(DRC).to receive(:bput)
      stub_book_reads(section_lines: [])

      expect(instance.send(:find_sigil_page, first_book, 'nurture')).to be_nil
    end
  end

  describe '#turn_to_sigil_page' do
    it 'confirms the page holds the expected sigil type' do
      instance = build_instance

      stub_book_reads(section_lines: [], page_lines: nurture_page_read)
      expect(DRC).to receive(:bput)
        .with('turn my book to page 3', { 'timeout' => 3, 'suppress_no_match' => true }, Enchant::SIGIL_BOOK_TURN_PAGE)

      expect(instance.send(:turn_to_sigil_page, first_book, 3, 'nurture')).to be true
    end

    it 'rejects a page holding a different sigil type' do
      instance = build_instance

      allow(DRC).to receive(:bput)
      stub_book_reads(section_lines: [], page_lines: nurture_page_read)

      expect(Lich::Messaging).to receive(:msg).with('bold', /Page 3 of small sigil book does not hold a congruence sigil/)

      expect(instance.send(:turn_to_sigil_page, first_book, 3, 'congruence')).to be false
    end

    it 'rejects a read that never reached a page view' do
      instance = build_instance

      allow(DRC).to receive(:bput)
      stub_book_reads(section_lines: [], page_lines: nurture_section_read)
      allow(Lich::Messaging).to receive(:msg)

      expect(instance.send(:turn_to_sigil_page, first_book, 3, 'nurture')).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # handle_complete_flag
  # ---------------------------------------------------------------------------

  describe '#handle_complete_flag' do
    it 'outputs completion message and calls cleanup' do
      instance = build_instance

      expect(Lich::Messaging).to receive(:msg).with('plain', 'Enchant: Enchanting complete!')
      expect(instance).to receive(:cleanup)

      instance.send(:handle_complete_flag)
    end

    it 'stamps item when @stamp is true' do
      instance = build_instance(stamp: true)

      allow(Lich::Messaging).to receive(:msg)
      allow(instance).to receive(:cleanup)
      expect(instance).to receive(:stamp_item).with('totem')

      instance.send(:handle_complete_flag)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_backlash_flag
  # ---------------------------------------------------------------------------

  describe '#handle_backlash_flag' do
    it 'outputs error message, cleans up, and goes to safe room' do
      instance = build_instance

      expect(Lich::Messaging).to receive(:msg).with('bold', /Imbue backlash occurred/)
      expect(instance).to receive(:cleanup)
      expect(DRC).to receive(:wait_for_script_to_complete).with('safe-room', ['force'])

      instance.send(:handle_backlash_flag)
    end
  end

  # ---------------------------------------------------------------------------
  # imbue
  # ---------------------------------------------------------------------------

  describe '#imbue' do
    context 'with waggle spell config' do
      it 'casts spell using DRCA and retries on failure' do
        instance = build_instance(
          settings: OpenStruct.new(
            'waggle_sets' => { 'imbue' => { 'Imbue' => { 'mana' => 20 } } }
          )
        )

        # First call fails, second succeeds
        call_count = 0
        allow(DRCA).to receive(:cast_spell?) do
          call_count += 1
          call_count > 1
        end
        allow(Flags).to receive(:reset).with('enchant-imbue')

        expect(Lich::Messaging).to receive(:msg).with('bold', /Casting Imbue failed/).once

        instance.send(:imbue)
      end
    end

    context 'with imbue wand' do
      it 'waves wand at item on brazier' do
        instance = build_instance(
          settings: OpenStruct.new('waggle_sets' => { 'imbue' => {} })
        )
        $left_hand = nil

        expect(DRCC).to receive(:get_crafting_item).with('rod', 'backpack', ['burin'], 'toolbelt')
        expect(DRC).to receive(:bput).with(
          'wave rod at totem on brazier',
          Enchant::IMBUE_WAND_SUCCESS,
          Enchant::IMBUE_WAND_SIGIL_NEEDED,
          Enchant::IMBUE_WAND_FAILED
        ).and_return('Roundtime')
        allow(Flags).to receive(:reset).with('enchant-imbue')

        instance.send(:imbue)
      end

      it 'retries when wand fails' do
        instance = build_instance(
          settings: OpenStruct.new('waggle_sets' => { 'imbue' => {} })
        )
        $left_hand = 'rod'

        # First call fails, second succeeds
        call_count = 0
        allow(DRC).to receive(:bput) do
          call_count += 1
          call_count > 1 ? 'Roundtime' : Enchant::IMBUE_WAND_FAILED
        end
        allow(Flags).to receive(:reset).with('enchant-imbue')

        expect(Lich::Messaging).to receive(:msg).with('bold', /Imbue wand failed/).once

        instance.send(:imbue)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # clean_brazier
  # ---------------------------------------------------------------------------

  describe '#clean_brazier' do
    it 'cleans brazier when successful' do
      instance = build_instance

      expect(DRC).to receive(:bput).with(
        'clean brazier',
        Enchant::CLEAN_SUCCESS,
        Enchant::CLEAN_NOTHING,
        Enchant::CLEAN_NOT_LIT
      ).and_return(Enchant::CLEAN_SUCCESS)
      expect(DRC).to receive(:bput).with('clean brazier', Enchant::CLEAN_SINGED)

      instance.send(:clean_brazier)
    end

    it 'stows left hand when brazier not lit' do
      instance = build_instance
      $left_hand = 'burin'

      allow(DRC).to receive(:bput).and_return(Enchant::CLEAN_NOT_LIT)
      expect(DRCC).to receive(:stow_crafting_item).with('burin', 'backpack', 'toolbelt')

      instance.send(:clean_brazier)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_new_enchant - fount existence check
  # ---------------------------------------------------------------------------

  describe '#handle_new_enchant' do
    it 'exits early with message when fount not found' do
      instance = build_instance(item: 'totem')
      $mock_drci_exists = false

      allow(instance).to receive(:study_recipe)
      expect(Lich::Messaging).to receive(:msg).with('bold', /fount not found in inventory/)
      expect(instance).to receive(:cleanup)
      expect(instance).not_to receive(:imbue)

      instance.send(:handle_new_enchant)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_resume
  # ---------------------------------------------------------------------------

  describe '#handle_resume' do
    it 'logs error for unexpected analyze result' do
      instance = build_instance
      $mock_bput_result = 'Something unexpected'

      allow(DRCC).to receive(:get_crafting_item)
      expect(Lich::Messaging).to receive(:msg).with('bold', /Unexpected analyze result/)

      instance.send(:handle_resume)
    end

    it 'picks the burin back up and scribes when the item is ready for scribing' do
      instance = build_instance
      allow(DRC).to receive(:bput).and_return('The fount is ready for additional scribing.')
      allow(DRCC).to receive(:get_crafting_item)

      expect(instance).to receive(:scribe_with_burin)

      instance.send(:handle_resume)
    end

    it 'hands off to the imbue resume when an imbue is still required' do
      instance = build_instance
      allow(DRC).to receive(:bput)
        .and_return('The fount requires an application of an imbue spell to advance the enchanting process.')
      allow(DRCC).to receive(:get_crafting_item)

      expect(instance).to receive(:handle_imbue_resume)

      instance.send(:handle_resume)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_imbue_resume
  #
  # Regression: an imbue is never the last step, so resuming into one must fall
  # through to the scribe loop. It used to imbue and exit, which dropped the
  # sigil prompt that only arrives after the imbue roundtime.
  # ---------------------------------------------------------------------------

  describe '#handle_imbue_resume' do
    it 'scribes after imbuing when the fount is already on the brazier' do
      instance = build_instance
      allow(DRC).to receive(:bput).and_return('On the brass brazier you see a fount and a totem.')
      allow(instance).to receive(:imbue)

      expect(DRCC).not_to receive(:get_crafting_item).with('fount', any_args)
      expect(instance).to receive(:scribe_with_burin)

      instance.send(:handle_imbue_resume)
    end

    it 'waves the fount first, then imbues, then scribes' do
      instance = build_instance
      allow(DRC).to receive(:bput).and_return('There is nothing')
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRCC).to receive(:stow_crafting_item)

      expect(DRCC).to receive(:get_crafting_item).with('fount', 'backpack', ['burin'], 'toolbelt')
      expect(instance).to receive(:imbue).ordered
      expect(instance).to receive(:scribe_with_burin).ordered

      instance.send(:handle_imbue_resume)
    end

    it 'still scribes when the look on the brazier matches nothing at all' do
      instance = build_instance
      # bput returns nil when no pattern matched within the timeout.
      allow(DRC).to receive(:bput).and_return(nil)
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRCC).to receive(:stow_crafting_item)
      allow(instance).to receive(:imbue)

      expect(instance).to receive(:scribe_with_burin)

      instance.send(:handle_imbue_resume)
    end
  end

  describe '#scribe_with_burin' do
    it 'gets the burin before entering the scribe loop' do
      instance = build_instance

      expect(DRCC).to receive(:get_crafting_item).with('burin', 'backpack', ['burin'], 'toolbelt').ordered
      expect(instance).to receive(:scribe).ordered

      instance.send(:scribe_with_burin)
    end
  end
end
