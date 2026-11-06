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
# Two items of one name (two stacks of one remedy) can each have an id of
# their own instead: an inventory entry [name, location, id], or {#hold}
# with id:. That id moves with the item and wins over `ids:` (the harness's
# $hand_item_ids).
# A helper given a "#<id>" reference (DRCI.get_item?("#41782305"), as
# lich-5's item_ref passes it through, 480bdee3 common-items.rb:50-58)
# finds the item, held or owned, that has that id, and nothing else; the
# game's own by-id commands do the same.
#
# == Shops
# By default DRCT.order_item puts the ordered item in hand and sends
# nothing. With `shop: :game` it sends lich-5's two ORDER commands through
# the game, and DRCT.buy_item sends its BUY, so a replay answers them from
# log lines (see {#order_item}, {#buy_item}).
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
  # @!attribute [r] id
  #   @return [String, nil] its own game id, for an item whose name another
  #     item shares; nil to use the `ids:` table
  Item = Struct.new(:name, :location, :id)

  # How {#order_item} and {#buy_item} answer: :model puts the item in hand
  # and sends nothing; :game sends lich-5's commands through the game.
  SHOPS = %i[model game].freeze

  # The replies lich-5's DRCT.order_item waits for (6f126888
  # common-travel.rb:126-128): the price quote, no coins, and the sale.
  ORDER_QUOTE = 'Just order it again'
  ORDER_NO_COINS = "you don't have enough coins"
  ORDER_SOLD = 'takes some coins from you'

  # The replies DRCT.buy_item waits for without a price (6f126888
  # common-travel.rb:62-65): the sale, and nothing of that name.
  BUY_SOLD = 'You decide to purchase'
  BUY_NONE = 'Buy what'

  # COUNT replies DRCI.count_item_parts reads a count from (6f126888
  # common-items.rb:947-955), the two the logs show: brine parts ("There
  # are ten parts left of the brewer's brine.", 6100:8800; "There is only
  # one part left ...", 6100:8665) and herb pieces ("You count out 25
  # pieces of material there.", 6100:4595).
  COUNT_PARTS = [/There (?:is|are) (?:only )?(?<count>.+) parts? left/, /You count out (?<count>.+) pieces? of material there/].freeze

  # COUNT's reply when no item of that ordinal is found
  # (common-items.rb:975), which ends DRCI.count_item_parts.
  COUNT_NONE = 'I could not find what you were referring to.'

  # The ordinals DRCI.count_item_parts counts with, in order (lich-5
  # $ORDINALS).
  ORDINALS = %w[first second third fourth fifth sixth seventh eighth ninth tenth].freeze

  # Number words the game spells counts with, for DRC.text2num's part of
  # count_item_parts (the harness's text2num returns the text unchanged).
  NUMBER_WORDS = %w[zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen
                    sixteen seventeen eighteen nineteen twenty].freeze

  # The lich-5 releases the model can answer as.
  LICH5_RELEASES = %i[v5_21 v5_22 current].freeze

  # Where an item lowered to the ground is (DRCI.lower_item?).
  GROUND = 'ground'

  # Where DRCI.put_away_item? with no container puts an item.
  STOWED = 'stowed'

  # The place a {#moves} entry gives for the character's hands.
  HAND = 'hand'

  # A "#<id>" item reference (lich-5 DRCI::ITEM_ID_REF_PATTERN, 480bdee3
  # common-items.rb:58). Captures the id.
  ID_REF = /\A#(\d+)\z/

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
  #   name of the item it puts in hand; a [room, number] key wins over the
  #   number alone, for two shops that sell different things under one
  #   number (Crossing's alchemy supplies sell alcohol as 2, its forging
  #   supplies a coal nugget, 6100:4250)
  # @param ids [Hash{String => String}] full item name => the game id
  #   GameObj shows for it in a hand (none by default)
  # @param shop [Symbol] one of {SHOPS}
  # @param buys [Hash{String => String}] DRCT.buy_item item => the full name
  #   of the item it puts in hand
  # @param container_gets [Boolean] model a get from a container as the
  #   game does it (see {#get_item?})
  # @raise [ArgumentError] for an unknown release or shop
  # @note inventory may also be an Array of [name, location] or [name,
  #   location, id], for two items of one name.
  def initialize(game: nil, lich5: :current, inventory: {}, orders: {}, ids: {}, shop: :model, buys: {}, container_gets: false)
    raise ArgumentError, "lich5: must be one of #{LICH5_RELEASES.inspect}, not #{lich5.inspect}" unless LICH5_RELEASES.include?(lich5)
    raise ArgumentError, "shop: must be one of #{SHOPS.inspect}, not #{shop.inspect}" unless SHOPS.include?(shop)

    @game = game
    @lich5 = lich5
    @inventory = inventory.map { |name, location, id| Item.new(name, location, id) }
    @orders = orders
    @shop = shop
    @buys = buys
    @container_gets = container_gets
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
    $hand_item_ids = {}
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
      allow(DRCI).to receive(:count_item_parts) { |*args| commons.count_item_parts(*args) }
      allow(DRCT).to receive(:order_item) { |*args| commons.order_item(*args) }
      allow(DRCT).to receive(:buy_item) { |*args| commons.buy_item(*args) }
      allow(DRCT).to receive(:walk_to) { |*args| commons.walk_to(*args) }
      allow(DRCM).to receive(:ensure_copper_on_hand) { |*args| commons.ensure_copper_on_hand(*args) }
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
  # @param id [String, nil] its own game id (for an item whose name another
  #   item shares); nil to use the `ids:` table
  # @param hand [Symbol, nil] :right or :left to put it in that hand (it
  #   must be empty); nil for the right hand when empty, else the left
  # @return [Symbol, nil] the hand (:right or :left), or nil when no hand
  #   was free
  def hold(name, id: nil, hand: nil)
    hand = hand ? (held_name(hand).nil? ? hand : nil) : free_hand
    return nil unless hand

    put_in_hand(hand, name, id)
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

    full_name, = take_from_hand(hand)
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
    put_in_hand(hand, item.name, item.id)
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
  # are already holding" is a success pattern, 480bdee3 common-items.rb:135)
  # and nothing moves; else the item, from +container+ when given, goes to a
  # free hand.
  #
  # With `container_gets: true` a get from a container is the game's
  # instead: it names the container ("get my glop from my satchel"), so one
  # in the container goes to a free hand even with another already held (the
  # game did so with a second remedy stack, 6100:9365-9368); with none
  # there, the answer is still true when one is held, since lich-5 judges
  # the get by in_hands? (6f126888 common-items.rb:1249-1265). Off by
  # default: remedy's specs pin the older answer.
  #
  # @param item [String] the item asked for, or a "#<id>" reference
  # @param container [String, nil] where to get it from
  # @return [Boolean] true when the item ends in hand
  def get_item?(item, container = nil)
    record('DRCI.get_item?', item, container)
    return true if (container.nil? || !@container_gets) && hand_holding(item)

    found = find_item(item, container)
    hand = free_hand
    return !hand_holding(item).nil? unless found && hand

    take_from_inventory(found)
    put_in_hand(hand, found.name, found.id)
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
  # @note Not modelled: lich-5's answer for the "#<id>" form. The model
  #   answers it as its other helpers find an item by id ({#named?}).
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
  # With `shop: :game` it is lich-5's DRCT.order_item (6f126888
  # common-travel.rb:123-129) instead: a walk to the room, then
  # `order <number>` through the game, which returns nil on "you don't have
  # enough coins", else `order <number>` again, whose matched text it
  # returns ('' when the sale line did not come). The item goes to a hand
  # only on the sale line ("The attendant takes some coins from you and
  # hands you (25 pieces) dried georin.", 6100:8890).
  #
  # @param room [Object] the shop room
  # @param number [Object] the order number
  # @return [String, nil] nil by default; with `shop: :game` what lich-5
  #   returns
  def order_item(room, number)
    record('DRCT.order_item', room, number)
    return order_through_game(room, number) if @shop == :game

    item = ordered(room, number)
    hand_over(item, SHOP) if item
    nil
  end

  # Model of DRCT.buy_item (6f126888 common-travel.rb:97-107): recorded, a
  # walk to the room, then with `shop: :game` `buy <item>` through the game
  # (no price is ever offered: the brine's reply, "You decide to purchase
  # the brine, and pay the sales clerk 50 Kronars.", 6100:8718, names
  # none). On that sale line the item {#initialize}'s buys names goes to a
  # free hand. By default nothing is sent and the item goes to a hand.
  #
  # @param room [Object] the shop room
  # @param item [String] what to buy
  # @return [nil]
  def buy_item(room, item)
    record('DRCT.buy_item', room, item)
    walk_to(room)
    sold = @shop == :model || @game.bput("buy #{item}", BUY_SOLD, BUY_NONE) == BUY_SOLD
    hand_over(@buys[item], SHOP) if sold && @buys.key?(item)
    nil
  end

  # Model of DRCI.count_item_parts (6f126888 common-items.rb:968-999):
  # `count my <ordinal> <item>` through the game, first, second and so on,
  # until "I could not find what you were referring to."; each
  # {COUNT_PARTS} reply adds its count, read as a number or a number word.
  # A reply that is neither (bput's '' on a timeout) adds nothing and the
  # next ordinal is counted, as in lich-5. A "#<id>" reference is counted
  # once.
  #
  # @param item [String] e.g. 'brine', 'georin'
  # @return [Integer] the parts or pieces counted; 0 without a game
  def count_item_parts(item)
    record('DRCI.count_item_parts', item)
    return 0 unless @game

    refs = item.start_with?('#') ? [item] : ORDINALS.map { |ordinal| "my #{ordinal} #{item}" }
    total = 0
    refs.each do |ref|
      reply = @game.bput("count #{ref}", COUNT_NONE, *COUNT_PARTS)
      break if reply == COUNT_NONE

      count = COUNT_PARTS.lazy.filter_map { |pattern| reply.match(pattern)&.[](:count) }.first
      total += count.match?(/\A\d+\z/) ? count.to_i : NUMBER_WORDS.index(count).to_i if count
    end
    total
  end

  # Model of DRCT.walk_to: recorded; always arrives.
  #
  # @param room [Object]
  # @return [Boolean] true
  def walk_to(room)
    record('DRCT.walk_to', room)
    true
  end

  # Model of DRCM.ensure_copper_on_hand: recorded with the amount and the
  # town (the settings are left out of the record); always succeeds.
  #
  # @param amount [Integer] the coppers wanted on hand
  # @param _settings [Object] the script's settings, unused
  # @param town [String, nil] the town whose bank and currency are used
  # @return [Boolean] true
  def ensure_copper_on_hand(amount, _settings = nil, town = nil)
    record('DRCM.ensure_copper_on_hand', amount, town)
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
  # @param name [String] a name, or a "#<id>" reference ({#named?})
  # @param container [String, nil]
  # @return [Item, nil]
  def find_item(name, container = nil)
    @inventory.find do |item|
      named?(item.name, name, item.id) && (container.nil? || self.class.matches?(item.location, container))
    end
  end

  # Whether a requested name finds an item: a "#<id>" reference ({ID_REF})
  # finds only the item with that id, its own id when it has one, else its
  # full name's id in the `ids:` table; any other name finds it as
  # {.matches?} does.
  #
  # @param full_name [String, nil] the item's full name
  # @param requested [String, nil] the name a helper was given
  # @param own_id [String, nil] the item's own id
  # @return [Boolean]
  def named?(full_name, requested, own_id = nil)
    id = requested.to_s[ID_REF, 1]
    return self.class.matches?(full_name, requested) unless id
    return false if full_name.nil?

    (own_id || @ids[full_name]) == id
  end

  # The hand holding an item: an exact name first, then a name that finds it
  # ({#named?}, so a "#<id>" reference too), right hand before left.
  #
  # @note An ordinal name ("first nemoih") finds no hand (see the class
  #   comment).
  # @param name [String, nil]
  # @return [Symbol, nil] :right, :left or nil
  def hand_holding(name)
    return nil if name.nil?
    return :right if $right_hand == name
    return :left if $left_hand == name
    return :right if named?($right_hand, name, held_id(:right))
    return :left if named?($left_hand, name, held_id(:left))

    nil
  end

  # @param hand [Symbol] :right or :left
  # @return [String, nil] the name of what the hand holds
  def held_name(hand)
    hand == :right ? $right_hand : $left_hand
  end

  # The own id of what a hand holds ($hand_item_ids), while it still holds
  # the item that id was given for.
  #
  # @param hand [Symbol] :right or :left
  # @return [String, nil]
  def held_id(hand)
    name, id = ($hand_item_ids || {})[hand]
    id if name && name == held_name(hand)
  end

  # Puts a shop's item in a free hand, recording where it came from.
  #
  # @param name [String, nil] the full item name; nil does nothing
  # @param from [String] e.g. {SHOP}
  # @return [void]
  def hand_over(name, from)
    hand = free_hand
    return unless name && hand

    put_in_hand(hand, name)
    move(name, from, HAND)
  end

  # lich-5's DRCT.order_item, through the game ({#order_item}).
  #
  # @param room [Object]
  # @param number [Object]
  # @return [String, nil]
  def order_through_game(room, number)
    walk_to(room)
    return nil if @game.bput("order #{number}", ORDER_QUOTE, ORDER_NO_COINS) == ORDER_NO_COINS

    reply = @game.bput("order #{number}", ORDER_SOLD)
    item = ordered(room, number)
    hand_over(item, SHOP) if reply == ORDER_SOLD && item
    reply
  end

  # The item an order hands over: {#initialize}'s orders for [room, number],
  # else for the number alone.
  #
  # @param room [Object] the shop room
  # @param number [Object] the order number
  # @return [String, nil] its full name; nil when orders names none
  def ordered(room, number)
    @orders.fetch([room, number]) { @orders[number] }
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
    name, id = take_from_hand(hand)
    @inventory << Item.new(name, location, id)
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
  # @param name [String, nil]
  # @param id [String, nil] the item's own id, if it has one
  # @return [void]
  def put_in_hand(hand, name, id = nil)
    hand == :right ? $right_hand = name : $left_hand = name
    $hand_item_ids ||= {}
    id ? $hand_item_ids[hand] = [name, id] : $hand_item_ids.delete(hand)
  end

  # @param hand [Symbol] :right or :left
  # @return [Array(String, String)] the name the hand held and its own id
  #   (nil when it had none)
  def take_from_hand(hand)
    taken = [held_name(hand), held_id(hand)]
    put_in_hand(hand, nil)
    taken
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
