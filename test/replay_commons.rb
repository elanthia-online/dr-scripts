# frozen_string_literal: true

# An API-level model of the lich-5 commons helpers a crafting script calls
# (DRCC, DRCI, DRCT, DRCM, DRCA and DRC.wait_for_script_to_complete), for
# replays driven by a ReplayGame. No lich-5 code is copied.
#
# "API-level" means the model does not send the commands the real helpers
# send. It answers each call from a model of the character's things:
# - the hands are the harness's $left_hand / $right_hand (what DRC.left_hand
#   and DRC.right_hand read), each holding a full item name or nil;
# - the inventory is a list of items, each a full name and where it is (a
#   container, the crafting belt, or 'ground').
# Every call is recorded in {#calls} and, with a game, in its timeline. Every
# item a helper moves is recorded in {#moves}, "<full name>: <from> -> <to>",
# which pins where things went whatever name or hand a script asked by.
#
# A helper finds an item the way lich-5 matches a held item: the requested
# name becomes DRC::Item.from_text(name).short_regex, /\b<first word>.*\b<last
# word>/i (lich-5 480bdee3 common.rb:629-631, :644-656), so 'mixing stick'
# finds "luminescent starshine mixing stick".
#
# Hand and inventory changes are model assumptions, not game facts (Genie client logs
# carry no hand data): an item picked up goes to the right hand when it is
# empty, else to the left.
#
# Items have no game id unless {#initialize} is given `ids:`: once
# installed, GameObj.left_hand.id and GameObj.right_hand.id (the harness's
# $hand_ids) answer the id of the item a hand holds, by its full name. The
# ids are made up for a spec (code-derived): Genie client logs carry no ids.
#
# == Not modelled: ordinals
# An item named by its place, such as "second nemoih" (remedy.lic:239 and
# :241 at 03f11b54 put away "second #{@herb1}" / "first #{@herb1}"), is
# left to the game by lich-5: put_away_item? sends `stow my second nemoih`
# and the reply decides (480bdee3 common-items.rb:1837-1890). The model has
# no places, so the ordinal is just the first word of the short_regex
# (/\bsecond.*\bnemoih/i) and finds no item: a helper given one moves
# nothing and answers as for an item it cannot find (put_away_item? false,
# in_hands? false, stow_crafting_item true, get_crafting_item a missing-item
# failure). Which item the game would take is not in the logs. A spec that
# reaches such a call pins the model's answer, not the game's; the game's
# side shows only through the commands the script sends next.
#
# == lich-5 releases
# `lich5:` picks how DRCC.get_crafting_item answers, because remedy runs on
# all three (read from each tag):
# - :v5_21 (v5.20.0 to v5.21.0, common-crafting.rb:324-363): nil on success,
#   nil on a missing item, never exits;
# - :v5_22 (v5.22.0, :324-363): nil on success; a missing item exits, or
#   returns nil with skip_exit;
# - :current (v5.23.0 and later; 480bdee3 :444-498, :516-527): true on
#   success; a final failure exits, or returns false with skip_exit.
#
# @example
#   commons = ReplayCommons.new(game: game, lich5: :v5_21,
#                               inventory: { 'heavy cauldron' => 'grass toolstrap' }).install(self)
#   DRCC.get_crafting_item('cauldron', "botanist's toolbag", [], belt) # => nil
#   $right_hand # => "heavy cauldron"
class ReplayCommons
  # An item the character owns but is not holding.
  #
  # @!attribute [r] name
  #   @return [String] the full item name, as it shows in a hand
  # @!attribute [r] location
  #   @return [String] where it is: a container, the belt's name, or 'ground'
  Item = Struct.new(:name, :location)

  # The lich-5 releases the model can answer as.
  LICH5_RELEASES = %i[v5_21 v5_22 current].freeze

  # Where an item lowered to the ground is (DRCI.lower_item?).
  GROUND = 'ground'

  # Where DRCI.put_away_item? with no container puts an item.
  STOWED = 'stowed'

  # The place a {#moves} entry gives for the character's hands.
  HAND = 'hand'

  # Where DRCT.order_item takes an ordered item from, in {#moves}.
  SHOP = 'shop'

  # Where {#hold} takes an item from and {#release} sends it, in {#moves}:
  # the game handed it over or took it (a product taken out of a vessel, an
  # herb put into one).
  GAME = 'game'

  # get_crafting_item's line for a missing item (480bdee3 common-crafting.rb:465).
  MISSING_MESSAGE = 'DRCC: You seem to be missing: %s'

  # get_crafting_item's line when no hand is free (480bdee3 common-crafting.rb:471).
  NO_FREE_HAND_MESSAGE = 'DRCC: No free hand to get: %s'

  # The line before get_crafting_item stops the script (480bdee3
  # common-crafting.rb:521).
  STOP_MESSAGE = 'DRCC: Cannot continue crafting without required item. Stopping script.'

  # @return [Array<Item>] what the character owns but is not holding
  attr_reader :inventory

  # @return [Array<Array>] each call made, as [name, *arguments]
  attr_reader :calls

  # @return [Array<String>] the bold lines the modelled helpers printed
  attr_reader :messages

  # @return [Array<String>] each item a modelled helper moved, in order, as
  #   "<full name>: <from> -> <to>" ({HAND}, {GROUND}, {SHOP}, {STOWED}, a
  #   container or the belt's name)
  attr_reader :moves

  # @return [Symbol] the modelled lich-5 release
  attr_reader :lich5

  class << self
    # Model of DRC::Item.from_text(text).short_regex (480bdee3 common.rb:629-631,
    # :644-656): a name of several words matches its first word, anything,
    # then its last word; one word matches as a word prefix.
    #
    # @param text [String] a requested item name
    # @return [Regexp, nil] nil for a blank name
    def item_regex(text)
      return nil if text.nil? || text.to_s.strip.empty?

      parts = text.to_s.sub('.', ' ').squeeze(' ').strip.split
      parts.size > 1 ? /\b#{parts.first}.*\b#{parts.last}/i : /\b#{parts.first}/i
    end

    # @param full_name [String, nil] a held or owned item's full name
    # @param requested [String, nil] the name a helper was given
    # @return [Boolean] true when the requested name finds the item
    def matches?(full_name, requested)
      regex = item_regex(requested)
      !full_name.nil? && !regex.nil? && regex.match?(full_name)
    end

    # Model of DRCI.in_hands? (480bdee3 common-items.rb:935-937, :978-998) on
    # the harness hands ($left_hand, $right_hand), for a spec that stubs only
    # this helper: allow(DRCI).to receive(:in_hands?) { |item| ReplayCommons.held?(item) }.
    #
    # @param item [String, nil] the name the caller asks for
    # @return [Boolean] true when either hand's name matches its short_regex
    def held?(item)
      matches?($left_hand, item) || matches?($right_hand, item)
    end

    # The id {#id_of} answers, from a `{ full name => id }` table without a
    # ReplayCommons: a spec can work out a command before its commons is
    # built (building it reads the inventory, which the example may still
    # change).
    #
    # @param ids [Hash{String => String}] full item name => game id
    # @param requested [String] the name a script asks for the item by
    # @return [String, nil] the id of the first item the name finds
    #   ({.matches?}), or nil
    def id_in(ids, requested)
      ids.find { |full_name, _id| matches?(full_name, requested) }&.last
    end
  end

  # @param game [ReplayGame, nil] the replay whose timeline records each call
  # @param lich5 [Symbol] one of {LICH5_RELEASES}
  # @param inventory [Hash{String => String}] full item name => location
  # @param orders [Hash{Object => String}] DRCT.order_item number => the full
  #   name of the item it puts in hand
  # @param ids [Hash{String => String}] full item name => the game id
  #   GameObj shows for it in a hand (none by default)
  # @raise [ArgumentError] for an unknown release
  def initialize(game: nil, lich5: :current, inventory: {}, orders: {}, ids: {})
    raise ArgumentError, "lich5: must be one of #{LICH5_RELEASES.inspect}, not #{lich5.inspect}" unless LICH5_RELEASES.include?(lich5)

    @game = game
    @lich5 = lich5
    @inventory = inventory.map { |name, location| Item.new(name, location) }
    @orders = orders
    @ids = ids
    @calls = []
    @messages = []
    @moves = []
  end

  # Routes the modelled helpers through `allow`, for the running example,
  # and gives the hands' items their ids ($hand_ids, read by GameObj).
  #
  # @param example [RSpec::Core::ExampleGroup] the running example (`self`)
  # @return [ReplayCommons] self
  def install(example)
    commons = self
    $hand_ids = @ids
    example.instance_exec do
      allow(DRCC).to receive(:get_crafting_item) { |*args| commons.get_crafting_item(*args) }
      allow(DRCC).to receive(:stow_crafting_item) { |*args| commons.stow_crafting_item(*args) }
      allow(DRCC).to receive(:find_recipe2) { |*args| commons.find_recipe2(*args) }
      allow(DRCC).to receive(:repair_own_tools) { |*args| commons.repair_own_tools(*args) }
      allow(DRCI).to receive(:get_item?) { |*args| commons.get_item?(*args) }
      allow(DRCI).to receive(:put_away_item?) { |*args| commons.put_away_item?(*args) }
      allow(DRCI).to receive(:lower_item?) { |*args| commons.lower_item?(*args) }
      allow(DRCI).to receive(:exists?) { |*args| commons.exists?(*args) }
      allow(DRCI).to receive(:in_hands?) { |*args| commons.in_hands?(*args) }
      allow(DRCI).to receive(:in_left_hand?) { |*args| commons.in_left_hand?(*args) }
      allow(DRCI).to receive(:in_right_hand?) { |*args| commons.in_right_hand?(*args) }
      allow(DRCT).to receive(:order_item) { |*args| commons.order_item(*args) }
      allow(DRCT).to receive(:walk_to) { |*args| commons.walk_to(*args) }
      allow(DRCM).to receive(:get_money_from_bank) { |*args| commons.get_money_from_bank(*args) }
      allow(DRCA).to receive(:crafting_magic_routine) { |*args| commons.crafting_magic_routine(*args) }
      allow(DRC).to receive(:wait_for_script_to_complete) { |*args| commons.wait_for_script_to_complete(*args) }
    end
    self
  end

  # The game id of the first item with an id that a requested name finds
  # ({.matches?}), as GameObj would show it once the item is in a hand.
  #
  # @param requested [String] the name a script asks for the item by
  # @return [String, nil] the id, or nil when no item with an id matches
  def id_of(requested)
    self.class.id_in(@ids, requested)
  end

  # Puts an item in a free hand, as a scenario's starting state or a game
  # reply's `after:` hook. Recorded in {#moves} as coming from {GAME}.
  #
  # @param name [String] the full item name
  # @return [Symbol, nil] the hand (:right or :left), or nil when both are full
  def hold(name)
    hand = free_hand
    return nil unless hand

    put_in_hand(hand, name)
    move(name, GAME, HAND)
    hand
  end

  # Empties the hand holding an item, without putting it anywhere (the game
  # took it). Recorded in {#moves} as going to {GAME}.
  #
  # @param name [String] a name that finds the held item
  # @return [String, nil] the full name released, or nil when not held
  def release(name)
    hand = hand_holding(name)
    return nil unless hand

    full_name = take_from_hand(hand)
    move(full_name, HAND, GAME)
    full_name
  end

  # @param name [String] a name that finds an owned item
  # @return [String, nil] where the item is, :right / :left as a String when
  #   held, or nil when the character does not have it
  def location_of(name)
    hand = hand_holding(name)
    return hand.to_s if hand

    find_item(name)&.location
  end

  # Model of DRCC.get_crafting_item: puts the item in hand.
  #
  # When +belt+ lists the name ({#belt_holds?}) the real helper first unties
  # it from the belt (480bdee3 common-crafting.rb:446-455): an item tied
  # there goes to a free hand; when none is, it goes on to the get.
  # When +bag_items+ lists the name the real helper sends `get my <name>
  # from my <bag>` (480bdee3 common-crafting.rb:455-456): a matching item in
  # +bag+ goes to a free hand, even with another already held (a second
  # stack of an herb). Otherwise an item already held is a success, and an
  # item found anywhere goes to a free hand. Missing, or no hand free: a
  # failure, answered as {#lich5} dictates (see the class comment).
  #
  # @note Unverified: a plain `get my <name>` with one already in hand changes
  #   nothing here. In game it may pick up a second one (remedy.lic:214
  #   mentions "You are already holding that." instead); a scenario that
  #   needs the second one adds it with {#hold}.
  # @note With :v5_21 and :v5_22 a full pair of hands returns nil and prints
  #   nothing: those releases have no free-hand pattern (v5.22.0
  #   common-crafting.rb:339), so the real reply would also cost a bput
  #   timeout. The model does not add that timeout.
  # @param name [String] the item asked for
  # @param bag [String] the crafting container
  # @param bag_items [Array<String>, nil] items kept in +bag+
  # @param belt [Hash, nil] the crafting belt ('name', 'items')
  # @param skip_exit [Boolean] return instead of exiting on a final failure
  # @return [Boolean, nil] true / false on :current; nil on older releases
  # @raise [SystemExit] on a final failure without skip_exit (:current, :v5_22)
  def get_crafting_item(name, bag, bag_items, belt, skip_exit = false)
    record('DRCC.get_crafting_item', name, bag, bag_items, belt, skip_exit)
    from_bag = bag if bag_items&.include?(name)
    tied = find_item(name, belt['name']) if belt_holds?(belt, name)
    item = tied || find_item(name, from_bag)
    return got if hand_holding(name) && (from_bag.nil? || item.nil?)
    return crafting_failure(format(MISSING_MESSAGE, name), skip_exit) unless item

    hand = free_hand
    unless hand
      return crafting_failure(format(NO_FREE_HAND_MESSAGE, name), skip_exit) if @lich5 == :current

      return nil
    end

    take_from_inventory(item)
    put_in_hand(hand, item.name)
    move(item.name, item.location, HAND)
    got
  end

  # Model of DRCC.stow_crafting_item: puts a held item away. It is tied to
  # the belt when the belt lists it, by the same rule as lich-5 (480bdee3
  # common-crafting.rb:532), else put in +bag+.
  #
  # @note The real helper also answers true when nothing was held (the game's
  #   "What were you referring to?" counts as done); so does the model.
  # @param name [String, nil] the item; nil does nothing (common-crafting.rb:529)
  # @param bag [String] the crafting container
  # @param belt [Hash, nil] the crafting belt ('name', 'items')
  # @return [Boolean, nil] true, or nil for a nil name
  def stow_crafting_item(name, bag, belt)
    record('DRCC.stow_crafting_item', name, bag, belt)
    return nil unless name

    hand = hand_holding(name)
    stow_from_hand(hand, belt_holds?(belt, name) ? belt['name'] : bag) if hand
    true
  end

  # Model of DRCC.find_recipe2: recorded only.
  #
  # @param args [Array] chapter, recipe name, book, discipline
  # @return [nil]
  def find_recipe2(*args)
    record('DRCC.find_recipe2', *args)
    nil
  end

  # Model of DRCC.repair_own_tools: recorded only.
  #
  # @param args [Array] info, tools, bag, bag_items, belt
  # @return [nil]
  def repair_own_tools(*args)
    record('DRCC.repair_own_tools', *args)
    nil
  end

  # Model of DRCI.get_item?: already held counts as success (the game's "You
  # are already holding" is a success pattern, 480bdee3 common-items.rb:135);
  # else the item, from +container+ when given, goes to a free hand.
  #
  # @param item [String] the item asked for
  # @param container [String, nil] where to get it from
  # @return [Boolean] true when the item ends in hand
  def get_item?(item, container = nil)
    record('DRCI.get_item?', item, container)
    return true if hand_holding(item)

    found = find_item(item, container)
    hand = free_hand
    return false unless found && hand

    take_from_inventory(found)
    put_in_hand(hand, found.name)
    move(found.name, found.location, HAND)
    true
  end

  # Model of DRCI.put_away_item?: a held item goes into +container+, or is
  # stowed when none is given.
  #
  # @note Not modelled: an ordinal name such as "second nemoih" finds no held
  #   item, so nothing moves and the answer is false; lich-5 sends `stow my
  #   second nemoih` and the game's reply decides (see the class comment).
  # @param item [String] the item
  # @param container [String, nil] where to put it
  # @return [Boolean] false when the item is not held
  def put_away_item?(item, container = nil)
    record('DRCI.put_away_item?', item, container)
    hand = hand_holding(item)
    return false unless hand

    stow_from_hand(hand, container || STOWED)
    true
  end

  # Model of DRCI.lower_item?: a held item goes to the ground (480bdee3
  # common-items.rb:1617-1626 checks in_hands? first).
  #
  # @param item [String] the item
  # @return [Boolean] false when the item is not held
  def lower_item?(item)
    record('DRCI.lower_item?', item)
    hand = hand_holding(item)
    return false unless hand

    stow_from_hand(hand, GROUND)
    true
  end

  # Model of DRCI.exists?: the character has the item, in +container+ when
  # given.
  #
  # @param item [String] the item
  # @param container [String, nil] where to look
  # @return [Boolean]
  def exists?(item, container = nil)
    record('DRCI.exists?', item, container)
    return true if container.nil? && hand_holding(item)

    !find_item(item, container).nil?
  end

  # Model of DRCI.in_hands? (480bdee3 common-items.rb:935-937, :978-998):
  # either hand's name matches the item's short_regex.
  #
  # @note Not modelled: the "#<id>" form.
  # @param item [String] the item
  # @return [Boolean]
  def in_hands?(item)
    record('DRCI.in_hands?', item)
    !hand_holding(item).nil?
  end

  # Model of DRCI.in_left_hand? (480bdee3 common-items.rb:945-947, :985-988):
  # the left hand's name matches the item's short_regex.
  #
  # @note Not modelled: the "#<id>" form.
  # @param item [String] the item
  # @return [Boolean]
  def in_left_hand?(item)
    record('DRCI.in_left_hand?', item)
    self.class.matches?($left_hand, item)
  end

  # Model of DRCI.in_right_hand? (480bdee3 common-items.rb:955-957, :985-986, :989-990):
  # the right hand's name matches the item's short_regex.
  #
  # @note Not modelled: the "#<id>" form.
  # @param item [String] the item
  # @return [Boolean]
  def in_right_hand?(item)
    record('DRCI.in_right_hand?', item)
    self.class.matches?($right_hand, item)
  end

  # Model of DRCT.order_item: the ordered item, when {#initialize}'s orders
  # names one for +number+, goes to a free hand.
  #
  # @param room [Object] the shop room
  # @param number [Object] the order number
  # @return [nil]
  def order_item(room, number)
    record('DRCT.order_item', room, number)
    if @orders.key?(number) && (hand = free_hand)
      put_in_hand(hand, @orders[number])
      move(@orders[number], SHOP, HAND)
    end
    nil
  end

  # Model of DRCT.walk_to: recorded; always arrives.
  #
  # @param room [Object]
  # @return [Boolean] true
  def walk_to(room)
    record('DRCT.walk_to', room)
    true
  end

  # Model of DRCM.get_money_from_bank: recorded; always succeeds.
  #
  # @param args [Array] amount, settings
  # @return [Boolean] true
  def get_money_from_bank(*args)
    record('DRCM.get_money_from_bank', args.first)
    true
  end

  # Model of DRCA.crafting_magic_routine: recorded only (the settings are
  # left out of the record).
  #
  # @param _settings [Object]
  # @return [nil]
  def crafting_magic_routine(_settings)
    record('DRCA.crafting_magic_routine')
    nil
  end

  # Model of DRC.wait_for_script_to_complete: recorded; the script is not run.
  #
  # @param name [String] the script
  # @param args [Array<String>] its arguments
  # @return [nil]
  def wait_for_script_to_complete(name, args = [])
    record('DRC.wait_for_script_to_complete', name, args)
    nil
  end

  private

  # What a successful get_crafting_item returns on {#lich5}.
  #
  # @return [Boolean, nil]
  def got
    @lich5 == :current ? true : nil
  end

  # A final get_crafting_item failure, answered as {#lich5} dictates. Every
  # release beeps before the bold line (DRC.beep: v5.21.0 and v5.22.0
  # common-crafting.rb:344, 480bdee3 crafting_item_failed :517), so a spec
  # counting beeps counts this one too.
  #
  # @param message [String] the bold line
  # @param skip_exit [Boolean]
  # @return [Boolean, nil] false on :current, nil on older releases
  # @raise [SystemExit] without skip_exit on :current and :v5_22
  def crafting_failure(message, skip_exit)
    DRC.beep
    @messages << message
    if skip_exit
      return @lich5 == :current ? false : nil
    end

    @messages << STOP_MESSAGE
    exit unless @lich5 == :v5_21
    nil
  end

  # @param belt [Hash, nil]
  # @param name [String]
  # @return [Boolean] true when the belt lists the item (480bdee3
  #   common-crafting.rb:532)
  def belt_holds?(belt, name)
    return false unless belt

    !belt['items'].find { |item| /\b#{name}/i =~ item || /\b#{item}/i =~ name }.nil?
  end

  # An owned item the name finds, in +container+ when given.
  #
  # @param name [String]
  # @param container [String, nil]
  # @return [Item, nil]
  def find_item(name, container = nil)
    @inventory.find do |item|
      self.class.matches?(item.name, name) && (container.nil? || self.class.matches?(item.location, container))
    end
  end

  # The hand holding an item: an exact name first, then a name that finds it,
  # right hand before left.
  #
  # @note An ordinal name ("first nemoih") finds no hand (see the class
  #   comment).
  # @param name [String, nil]
  # @return [Symbol, nil] :right, :left or nil
  def hand_holding(name)
    return nil if name.nil?
    return :right if $right_hand == name
    return :left if $left_hand == name
    return :right if self.class.matches?($right_hand, name)
    return :left if self.class.matches?($left_hand, name)

    nil
  end

  # @return [Symbol, nil] the right hand when empty, else the left, else nil
  def free_hand
    return :right if $right_hand.nil?
    return :left if $left_hand.nil?

    nil
  end

  # Removes one owned item from the inventory. By identity: two stacks of
  # one herb in one bag are equal Items, and only the one taken may go.
  #
  # @param item [Item]
  # @return [void]
  def take_from_inventory(item)
    @inventory.delete_at(@inventory.index { |owned| owned.equal?(item) })
  end

  # Takes the item out of a hand and puts it somewhere, recording the move.
  #
  # @param hand [Symbol] :right or :left
  # @param location [String] where it goes
  # @return [void]
  def stow_from_hand(hand, location)
    name = take_from_hand(hand)
    @inventory << Item.new(name, location)
    move(name, HAND, location)
  end

  # Records an item moved by a modelled helper.
  #
  # @param name [String] the item's full name
  # @param from [String] where it was
  # @param to [String] where it went
  # @return [void]
  def move(name, from, to)
    @moves << "#{name}: #{from} -> #{to}"
  end

  # @param hand [Symbol] :right or :left
  # @param name [String]
  # @return [void]
  def put_in_hand(hand, name)
    hand == :right ? $right_hand = name : $left_hand = name
  end

  # @param hand [Symbol] :right or :left
  # @return [String] the name the hand held
  def take_from_hand(hand)
    name = hand == :right ? $right_hand : $left_hand
    put_in_hand(hand, nil)
    name
  end

  # Records a call, and adds it to the game's timeline.
  #
  # @param name [String] e.g. 'DRCC.get_crafting_item'
  # @param args [Array]
  # @return [void]
  def record(name, *args)
    @calls << [name, *args]
    @game&.record_call("#{name}(#{args.map(&:inspect).join(', ')})")
  end
end
