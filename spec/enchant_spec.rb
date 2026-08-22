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
      expect(DRC).to receive(:bput)
        .with('trace totem on brazier', { 'timeout' => 5, 'suppress_no_match' => true }, Enchant::SIGIL_TRACE_SUCCESS)
        .and_return(trace_success)

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
      instance = build_instance(sigil_books: { 'induction' => first_book })

      allow(instance).to receive(:study_sigil_from_book).with('induction').and_return(true)
      expect(DRCI).not_to receive(:get_item?)
      expect(DRC).to receive(:bput)
        .with('trace totem on brazier', { 'timeout' => 5, 'suppress_no_match' => true }, Enchant::SIGIL_TRACE_SUCCESS)
        .and_return(trace_success)

      instance.send(:trace_sigil, 'induction')
    end

    it 'keeps the book in hand while tracing' do
      instance = build_instance(sigil_books: { 'induction' => first_book }, held_sigil_book: first_book)

      allow(instance).to receive(:study_sigil).and_return(true)
      allow(DRC).to receive(:bput).and_return(trace_success)

      expect(instance).not_to receive(:stow_sigil_book)

      instance.send(:trace_sigil, 'induction')
    end

    # The book occupies a hand for the whole scribe loop. Whether TRACE tolerates
    # that is not known from the game output we have, so the run finds out once
    # rather than paying a stow and a fetch per sigil on the chance it matters.
    it 'stows the book and retries once when the trace is not accepted' do
      instance = build_instance(sigil_books: { 'induction' => first_book }, held_sigil_book: first_book)

      allow(instance).to receive(:study_sigil).and_return(true)
      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      allow(DRC).to receive(:bput).and_return(nil, trace_success)

      expect(DRCC).to receive(:stow_crafting_item).with(first_book, 'backpack', 'toolbelt')

      instance.send(:trace_sigil, 'induction')

      expect(instance.instance_variable_get(:@trace_needs_free_hand)).to be true
    end

    it 'stows the book before tracing once it knows the trace needs the hand' do
      instance = build_instance(
        sigil_books: { 'induction' => first_book },
        held_sigil_book: first_book,
        trace_needs_free_hand: true
      )

      allow(instance).to receive(:study_sigil).and_return(true)
      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      allow(DRC).to receive(:bput).and_return(trace_success)

      expect(DRCC).to receive(:stow_crafting_item).with(first_book, 'backpack', 'toolbelt').once

      instance.send(:trace_sigil, 'induction')
    end

    it 'reports when even a retry with free hands will not trace' do
      instance = build_instance

      allow(instance).to receive(:study_sigil).and_return(true)
      allow(DRC).to receive(:bput).and_return(nil)

      expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to trace induction sigil/)

      instance.send(:trace_sigil, 'induction')
    end
  end

  # ---------------------------------------------------------------------------
  # Sigil book
  #
  # One book per sigil type. A dedicated book is never read: every page holds
  # the same type, and studying a page blanks it and renumbers the rest, so the
  # next scroll of that type is page 1 again.
  #
  # Fixtures are verbatim game output.
  # ---------------------------------------------------------------------------

  let(:turn_page) { 'You turn the book to page 1.' }
  let(:already_at_page) { 'You are already on page 1.' }
  let(:page_missing) { 'The book does not have that many sigils in it.' }
  let(:page_banner) { '   --=== Nurture sigil ===--' }
  let(:study_unread) { 'You must read the current page before you study the book.' }
  let(:study_success) { "You commit the sigil's design to memory rendering the page blank, and turn the book back to the contents." }
  let(:study_appraise) { 'You study the book and determine it is well-suited for holding sigil-scrolls.  These scrolls can be PUT into the book.' }
  let(:trace_success) { 'Recalling the intricacies of the sigil, you trace its form' }

  # Two books with DIFFERENT nouns, so a spec can tell which one a command
  # addressed. In game they are usually both "book", which is why only one is
  # ever held at a time.
  let(:first_book) { 'small sigil book' }
  let(:second_book) { 'battered sigil tome' }

  describe 'sigil book constants' do
    it 'parses the page turn confirmation' do
      expect(Enchant::SIGIL_BOOK_TURN_PAGE.match(turn_page)[:page]).to eq('1')
    end

    it 'parses the already-at-that-page response' do
      expect(Enchant::SIGIL_BOOK_ALREADY_AT_PAGE.match(already_at_page)[:page]).to eq('1')
      expect(Enchant::SIGIL_BOOK_ALREADY_AT_PAGE).not_to match('A small black book of sigils is already at the contents.')
      expect(Enchant::SIGIL_BOOK_ALREADY_AT_PAGE).not_to match(page_missing)
    end

    it 'recognizes an emptied book refusing the page turn' do
      expect(Enchant::SIGIL_BOOK_PAGE_MISSING).to match(page_missing)
      expect(Enchant::SIGIL_BOOK_PAGE_MISSING).not_to match(turn_page)
    end

    it 'parses the sigil type off a page banner' do
      expect(Enchant::SIGIL_BOOK_PAGE_TYPE.match(page_banner)[:type]).to eq('Nurture')
    end

    it 'recognizes a study refused for want of a read' do
      expect(Enchant::SIGIL_BOOK_STUDY_UNREAD).to match(study_unread)
      expect(Enchant::SIGIL_BOOK_STUDY_UNREAD).not_to match(study_success)
    end

    it 'distinguishes a memorizing study from the book appraisal' do
      expect(Enchant::SIGIL_BOOK_STUDY_SUCCESS).to match(study_success)
      expect(Enchant::SIGIL_BOOK_STUDY_SUCCESS).not_to match(study_appraise)
      expect(Enchant::SIGIL_BOOK_STUDY_APPRAISE).to match(study_appraise)
    end
  end

  describe '#parse_sigil_books' do
    it 'is empty when the setting is unset' do
      expect(build_instance.send(:parse_sigil_books, nil)).to eq({})
    end

    it 'maps each sigil type to its book' do
      instance = build_instance

      parsed = instance.send(:parse_sigil_books, 'nurture' => first_book, 'congruence' => second_book)

      expect(parsed).to eq('nurture' => first_book, 'congruence' => second_book)
    end

    it 'downcases the configured sigil types' do
      instance = build_instance

      expect(instance.send(:parse_sigil_books, 'Nurture' => first_book)).to eq('nurture' => first_book)
    end

    it 'rejects the pre-map list format, which cannot say what each book holds' do
      instance = build_instance

      expect(Lich::Messaging).to receive(:msg).with('bold', /must map each sigil type to its own book/)

      expect(instance.send(:parse_sigil_books, [first_book, second_book])).to eq({})
    end

    it 'says nothing about an empty list' do
      instance = build_instance

      expect(Lich::Messaging).not_to receive(:msg)

      expect(instance.send(:parse_sigil_books, [])).to eq({})
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
    it 'prefers the book and skips the loose scroll entirely' do
      instance = build_instance(sigil_books: { 'nurture' => first_book })

      expect(instance).to receive(:study_sigil_from_book).with('nurture').and_return(true)
      expect(DRCI).not_to receive(:get_item?)

      expect(instance.send(:study_sigil, 'nurture')).to be true
    end

    it 'falls back to a loose scroll when the book cannot supply the sigil' do
      instance = build_instance(sigil_books: { 'nurture' => first_book })

      allow(instance).to receive(:study_sigil_from_book).with('nurture').and_return(false)
      expect(DRCI).to receive(:get_item?).with('nurture sigil').and_return(true)
      expect(DRC).to receive(:bput).with('study my nurture sigil', Enchant::SIGIL_STUDY_SUCCESS)

      expect(instance.send(:study_sigil, 'nurture')).to be true
    end

    it 'returns false when neither the book nor a loose scroll has the sigil' do
      instance = build_instance(sigil_books: { 'nurture' => first_book })

      allow(instance).to receive(:study_sigil_from_book).and_return(false)
      allow(DRCI).to receive(:get_item?).and_return(false)
      expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to get nurture sigil/)

      expect(instance.send(:study_sigil, 'nurture')).to be false
    end
  end

  describe '#study_sigil_from_book' do
    it 'returns false without touching the game for a type with no book' do
      instance = build_instance(sigil_books: { 'nurture' => first_book })

      expect(DRCC).not_to receive(:get_crafting_item)
      expect(DRC).not_to receive(:bput)

      expect(instance.send(:study_sigil_from_book, 'rarefaction')).to be false
    end

    it 'turns to page 1, reads it, then studies - without reading the contents' do
      instance = build_instance(sigil_books: { 'nurture' => first_book })

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      allow(DRCC).to receive(:get_crafting_item)

      expect(DRC).to receive(:bput)
        .with('turn my book to page 1', { 'timeout' => 3, 'suppress_no_match' => true }, Enchant::SIGIL_BOOK_TURN_PAGE, Enchant::SIGIL_BOOK_ALREADY_AT_PAGE, Enchant::SIGIL_BOOK_PAGE_MISSING)
        .and_return(turn_page)
      expect(DRC).to receive(:bput)
        .with('read my book', { 'timeout' => 3, 'suppress_no_match' => true }, Enchant::SIGIL_BOOK_PAGE_TYPE)
        .and_return(page_banner)
      expect(DRC).to receive(:bput)
        .with('study my book', Enchant::SIGIL_BOOK_STUDY_SUCCESS, Enchant::SIGIL_BOOK_STUDY_APPRAISE, Enchant::SIGIL_BOOK_STUDY_UNREAD, Enchant::SIGIL_BOOK_NOT_HELD)
        .and_return(study_success)
      expect(Lich::Util).not_to receive(:issue_command)

      expect(instance.send(:study_sigil_from_book, 'nurture')).to be true
    end

    it 'refuses to study a page holding some other sigil type' do
      instance = build_instance(sigil_books: { 'nurture' => first_book })

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRC).to receive(:bput).and_return(turn_page, '   --=== Congruence sigil ===--')

      expect(Lich::Messaging).to receive(:msg).with('bold', /mapped to nurture but page 1 holds a congruence sigil/)
      expect(DRC).not_to receive(:bput).with('study my book', any_args)

      expect(instance.send(:study_sigil_from_book, 'nurture')).to be false
      expect(instance.send(:sigil_books)).not_to have_key('nurture')
    end

    it 'matches the configured type case-insensitively' do
      instance = build_instance(sigil_books: { 'nurture' => first_book })

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRC).to receive(:bput).and_return(turn_page, page_banner, study_success)

      expect(instance.send(:study_sigil_from_book, 'Nurture')).to be true
    end

    it 'keeps the book in hand across repeats of the same sigil type' do
      instance = build_instance(sigil_books: { 'nurture' => first_book })

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      allow(DRC).to receive(:bput).and_return(turn_page, page_banner, study_success, turn_page, page_banner, study_success)

      expect(DRCC).to receive(:get_crafting_item).once
      expect(DRCC).not_to receive(:stow_crafting_item)

      instance.send(:study_sigil_from_book, 'nurture')
      instance.send(:study_sigil_from_book, 'nurture')
    end

    it 'swaps books when the next sigil is a different type' do
      instance = build_instance(sigil_books: { 'nurture' => first_book, 'congruence' => second_book })

      allow(DRCI).to receive(:in_hands?).and_return(true)
      allow(DRC).to receive(:bput).and_return(turn_page, page_banner, study_success, turn_page, '   --=== Congruence sigil ===--', study_success)
      allow(DRCC).to receive(:get_crafting_item)

      instance.send(:study_sigil_from_book, 'nurture')

      expect(DRCC).to receive(:stow_crafting_item).with(first_book, 'backpack', 'toolbelt')

      instance.send(:study_sigil_from_book, 'congruence')

      expect(DRCC).to have_received(:get_crafting_item).with(first_book, 'backpack', ['burin'], 'toolbelt', true)
      expect(DRCC).to have_received(:get_crafting_item).with(second_book, 'backpack', ['burin'], 'toolbelt', true)
    end

    it 'drops a book that has run out and falls back to loose scrolls after' do
      instance = build_instance(sigil_books: { 'nurture' => first_book })

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      allow(DRCC).to receive(:get_crafting_item)
      # An emptied book refuses the page turn outright.
      allow(DRC).to receive(:bput).and_return(page_missing)

      expect(Lich::Messaging).to receive(:msg).with('bold', /small sigil book has no nurture sigils left/)
      expect(DRC).not_to receive(:bput).with('study my book', any_args)

      expect(instance.send(:study_sigil_from_book, 'nurture')).to be false
      expect(instance.send(:sigil_books)).not_to have_key('nurture')
    end

    it 'treats the book appraisal as a failed study rather than a memorized sigil' do
      instance = build_instance(sigil_books: { 'nurture' => first_book })

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRC).to receive(:bput).and_return(turn_page, page_banner, study_appraise)

      expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to study nurture sigil from small sigil book/)

      expect(instance.send(:study_sigil_from_book, 'nurture')).to be false
    end

    it 'forgets the held book when the game says it is not being held' do
      instance = build_instance(sigil_books: { 'nurture' => first_book })

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      allow(DRCC).to receive(:get_crafting_item)
      allow(DRC).to receive(:bput).and_return(turn_page, page_banner, Enchant::SIGIL_BOOK_NOT_HELD)
      allow(Lich::Messaging).to receive(:msg)

      instance.send(:study_sigil_from_book, 'nurture')

      expect(instance.instance_variable_get(:@held_sigil_book)).to be_nil
    end

    it 'returns false when the book cannot be picked up' do
      instance = build_instance(sigil_books: { 'nurture' => first_book })

      allow(DRCI).to receive(:in_hands?).with('book').and_return(false)
      allow(DRCC).to receive(:get_crafting_item)
      expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to get small sigil book/)
      expect(DRC).not_to receive(:bput)

      expect(instance.send(:study_sigil_from_book, 'nurture')).to be false
    end
  end

  describe '#hold_sigil_book' do
    it 'fetches from the crafting container or belt and confirms it landed in hand' do
      instance = build_instance

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      expect(DRCC).to receive(:get_crafting_item).with(first_book, 'backpack', ['burin'], 'toolbelt', true)

      expect(instance.send(:hold_sigil_book, first_book)).to be true
      expect(instance.instance_variable_get(:@held_sigil_book)).to eq(first_book)
    end

    it 'does not re-fetch a book it is already holding' do
      instance = build_instance(held_sigil_book: first_book)

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      expect(DRCC).not_to receive(:get_crafting_item)

      expect(instance.send(:hold_sigil_book, first_book)).to be true
    end

    it 're-fetches when the tracked book is no longer in hand' do
      instance = build_instance(held_sigil_book: first_book)

      allow(DRCI).to receive(:in_hands?).with('book').and_return(false)
      expect(DRCC).to receive(:get_crafting_item)
      allow(Lich::Messaging).to receive(:msg)

      instance.send(:hold_sigil_book, first_book)
    end

    it 'puts the current book away before picking up a different one' do
      instance = build_instance(held_sigil_book: first_book)

      allow(DRCI).to receive(:in_hands?).and_return(true)
      allow(DRCC).to receive(:get_crafting_item)

      expect(DRCC).to receive(:stow_crafting_item).with(first_book, 'backpack', 'toolbelt')

      instance.send(:hold_sigil_book, second_book)
    end

    it 'reports failure and tracks nothing when the book never reaches a hand' do
      instance = build_instance

      allow(DRCI).to receive(:in_hands?).with('book').and_return(false)
      allow(DRCC).to receive(:get_crafting_item)
      expect(Lich::Messaging).to receive(:msg).with('bold', /Failed to get small sigil book/)

      expect(instance.send(:hold_sigil_book, first_book)).to be false
      expect(instance.instance_variable_get(:@held_sigil_book)).to be_nil
    end
  end

  describe '#stow_sigil_book' do
    it 'puts the held book away and forgets it' do
      instance = build_instance(held_sigil_book: first_book)

      allow(DRCI).to receive(:in_hands?).with('book').and_return(true)
      expect(DRCC).to receive(:stow_crafting_item).with(first_book, 'backpack', 'toolbelt')

      instance.send(:stow_sigil_book)

      expect(instance.instance_variable_get(:@held_sigil_book)).to be_nil
    end

    it 'does nothing when no book is being tracked' do
      instance = build_instance

      expect(DRCC).not_to receive(:stow_crafting_item)

      instance.send(:stow_sigil_book)
    end

    it 'forgets a book another cleanup path already stowed' do
      instance = build_instance(held_sigil_book: first_book)

      allow(DRCI).to receive(:in_hands?).with('book').and_return(false)
      expect(DRCC).not_to receive(:stow_crafting_item)

      instance.send(:stow_sigil_book)

      expect(instance.instance_variable_get(:@held_sigil_book)).to be_nil
    end
  end

  describe '#read_sigil_book_page' do
    # STUDY refuses a page that has not been read, so this command is mandatory -
    # which makes the type check on its banner free.
    it 'reads the page and accepts a banner of the expected type' do
      instance = build_instance

      expect(DRC).to receive(:bput)
        .with('read my book', { 'timeout' => 3, 'suppress_no_match' => true }, Enchant::SIGIL_BOOK_PAGE_TYPE)
        .and_return(page_banner)

      expect(instance.send(:read_sigil_book_page, first_book, 'nurture')).to be true
    end

    it 'matches the banner case-insensitively' do
      instance = build_instance

      allow(DRC).to receive(:bput).and_return(page_banner)

      expect(instance.send(:read_sigil_book_page, first_book, 'Nurture')).to be true
    end

    it 'rejects a page holding a different sigil type' do
      instance = build_instance

      allow(DRC).to receive(:bput).and_return('   --=== Congruence sigil ===--')

      expect(Lich::Messaging).to receive(:msg).with('bold', /small sigil book is mapped to nurture but page 1 holds a congruence sigil/)

      expect(instance.send(:read_sigil_book_page, first_book, 'nurture')).to be false
    end

    it 'rejects a read that produced no page banner' do
      instance = build_instance

      allow(DRC).to receive(:bput).and_return(nil)

      expect(Lich::Messaging).to receive(:msg).with('bold', /Could not read the current page of small sigil book/)

      expect(instance.send(:read_sigil_book_page, first_book, 'nurture')).to be false
    end

    it 'addresses the book by its own noun' do
      instance = build_instance

      expect(DRC).to receive(:bput)
        .with('read my tome', { 'timeout' => 3, 'suppress_no_match' => true }, Enchant::SIGIL_BOOK_PAGE_TYPE)
        .and_return(page_banner)

      instance.send(:read_sigil_book_page, second_book, 'nurture')
    end
  end

  describe '#turn_sigil_book_to_first_page' do
    it 'always turns to page 1, because studying renumbers the pages' do
      instance = build_instance

      expect(DRC).to receive(:bput)
        .with('turn my book to page 1', { 'timeout' => 3, 'suppress_no_match' => true }, Enchant::SIGIL_BOOK_TURN_PAGE, Enchant::SIGIL_BOOK_ALREADY_AT_PAGE, Enchant::SIGIL_BOOK_PAGE_MISSING)
        .and_return(turn_page)

      expect(instance.send(:turn_sigil_book_to_first_page, first_book)).to be true
    end

    # An interrupted study leaves the book sitting on the page it selected, so
    # the next turn is a no-op the game reports differently. Treating that as a
    # failure would wrongly write the book off as empty.
    it 'accepts a book already sitting on page 1' do
      instance = build_instance

      allow(DRC).to receive(:bput).and_return(already_at_page)

      expect(instance.send(:turn_sigil_book_to_first_page, first_book)).to be true
    end

    it 'addresses the book by its own noun' do
      instance = build_instance

      expect(DRC).to receive(:bput)
        .with('turn my tome to page 1', { 'timeout' => 3, 'suppress_no_match' => true }, Enchant::SIGIL_BOOK_TURN_PAGE, Enchant::SIGIL_BOOK_ALREADY_AT_PAGE, Enchant::SIGIL_BOOK_PAGE_MISSING)
        .and_return('You turn the tome to page 1.')

      expect(instance.send(:turn_sigil_book_to_first_page, second_book)).to be true
    end

    it 'is false when the book has no scrolls left' do
      instance = build_instance

      allow(DRC).to receive(:bput).and_return(page_missing)

      expect(instance.send(:turn_sigil_book_to_first_page, first_book)).to be false
    end

    it 'is false when the turn draws no recognized response at all' do
      instance = build_instance

      allow(DRC).to receive(:bput).and_return(nil)

      expect(instance.send(:turn_sigil_book_to_first_page, first_book)).to be false
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
