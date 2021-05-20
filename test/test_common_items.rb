require_relative 'test_helper'

load 'test/test_harness.rb'

include Harness

class TestDRCI < Minitest::Test

  def setup
    reset_data
    $history.clear
    $server_buffer.clear
    sent_messages.clear
    displayed_messages.clear
  end

  def teardown
    @test.join if @test
  end

  #########################################
  # RUN DRCI COMMAND
  #########################################

  def assert_result
    proc { |result| assert(result) }
  end

  def refute_result
    proc { |result| refute(result) }
  end

  def run_drci_command(messages, command, args, assertions = [])
    @test = run_script_with_proc(['common', 'common-items'], proc do
      # Setup
      $server_buffer = messages.dup
      $history = $server_buffer.dup

      # Test
      result = DRCI.send(command, *args)

      # Assert
      assertions = [assertions] unless assertions.is_a?(Array)
      assertions.each { |assertion| assertion.call(result) }
    end)
  end

  #########################################
  # GET ITEM
  #########################################

  def test_get_item__should_get_crystal_from_backpack
    run_drci_command(
      ["You get a sanowret crystal from inside your hitman's backpack."],
      'get_item?',
      ["sanowret crystal"],
      [assert_result]
    ).join
  end

  def test_get_item__should_pick_up_arrow
    run_drci_command(
      ["You pick up a drake-fang arrow."],
      'get_item?',
      ["drake-fang arrow"],
      [assert_result]
    ).join
  end

  def test_get_item__should_pluck_rat_from_sack
    run_drci_command(
      ["You pluck an emaciated pet rat from a coarse burlap sack, the creature yawning as you wake it up."],
      'get_item?',
      ["rat"],
      [assert_result]
    ).join
  end

  def test_get_item__should_remove_barb_from_sash
    run_drci_command(
      ["You deftly remove the spiky barb from your sash."],
      'get_item?',
      ["spiky barb"],
      [assert_result]
    ).join
  end

  def test_get_item__should_fade_in_to_pick_up_cowbell
    run_drci_command(
      ["You fade in for a moment as you pick up a dainty cowbell fit with a polished flamewood handle."],
      'get_item?',
      ["dainty cowbell"],
      [assert_result]
    ).join
  end

  def test_get_item__should_fade_in_to_get_gem_from_pouch
    run_drci_command(
      ["You fade in for a moment as you get a small rust-colored andalusite from a black gem pouch."],
      'get_item?',
      ["andalusite"],
      [assert_result]
    ).join
  end

  def test_get_item__should_stop_as_you_realize_not_yours
    run_drci_command(
      ["You stop as you realize the boar-tusk arrow is not yours."],
      'get_item?',
      ["boar-tusk arrow"],
      [refute_result]
    ).join
  end

  def test_get_item__should_not_exceed_inventory_limit
    run_drci_command(
      ["Picking up a rugged red backpack would push you over the item limit of 100.  Please reduce your inventory count before you try again."],
      'get_item?',
      ["red backpack"],
      [refute_result]
    ).join
  end

  def test_get_item__should_need_a_free_hand_to_pick
    run_drci_command(
      ["You need a free hand to pick that up."],
      'get_item?',
      ["anything"],
      [refute_result]
    ).join
  end

  def test_get_item__should_need_a_free_hand_to_do
    run_drci_command(
      ["You need a free hand to do that."],
      'get_item?',
      ["anything"],
      [refute_result]
    ).join
  end

  def test_get_item__should_already_be_in_your_inventory
    run_drci_command(
      ["But that is already in your inventory."],
      'get_item?',
      ["anything"],
      [refute_result]
    ).join
  end

  def test_get_item__should_ask_get_what
    run_drci_command(
      ["Get what?"],
      'get_item?',
      ["nothing"],
      [refute_result]
    ).join
  end

  def test_get_item__should_not_find_what_you_were_referring
    run_drci_command(
      ["I could not find what you were referring to."],
      'get_item?',
      ["nothing"],
      [refute_result]
    ).join
  end

  def test_get_item__should_ask_what_were_you_referring
    run_drci_command(
      ["What were you referring to?"],
      'get_item?',
      ["nothing"],
      [refute_result]
    ).join
  end

  def test_get_item__should_not_find_container
    run_drci_command(
      ["I could not find that container."],
      'get_item?',
      ["nothing"],
      [refute_result]
    ).join
  end

  def test_get_item__should_not_get_if_rapidly_decays
    run_drci_command(
      ["The large limb rapidly decays away."],
      'get_item?',
      ["large limb"],
      [refute_result]
    ).join
  end

  def test_get_item__should_not_get_if_rots_away
    run_drci_command(
      ["A sharp pine sapling cracks and rots away along with the troll."],
      'get_item?',
      ["large limb"],
      [refute_result]
    ).join
  end

  #########################################
  # DISPOSE TRASH
  #########################################

  def test_dispose_trash_in_bin
    # TODO get test coverage for various trash bins
  end

  def test_dispose_trash__should_drop_ocarina_on_ground
    run_drci_command(
      [
        "Whoah!  Dropping a silverwillow ocarina would damage it!  If you wish to set the ocarina down, LOWER it.",
        "You drop your ocarina on the ground, causing it to hit the surface with a dull *creak*."
      ],
      'dispose_trash',
      ["ocarina"],
      [assert_result]
    ).join
  end

  def test_dispose_trash__should_smash_ocarina_to_bits
    run_drci_command(
      ["In sudden anger, you fling the ocarina to the ground, smashing it to bits!"],
      'dispose_trash',
      ["ocarina"],
      [assert_result]
    ).join
  end

  def test_dispose_trash__should_drop_pack_on_ground
    run_drci_command(
      ["You drop a storm grey pack."],
      'dispose_trash',
      ["pack"],
      [assert_result]
    ).join
  end

  def test_dispose_trash__should_drop_pants_in_barrel
    run_drci_command(
      ["You drop some faded pants in a large wooden barrel."],
      'dispose_trash',
      ["faded pants"],
      [assert_result]
    ).join
  end

  def test_dispose_trash__should_drop_lily_in_bucket
    run_drci_command(
      ["You drop a queen-of-the-night lily in a bucket of viscous gloop."],
      'dispose_trash',
      ["lily"],
      [assert_result]
    ).join
  end

  def test_dispose_trash__should_spread_blanket_on_ground
    run_drci_command(
      ["You spread a thick sea-blue wool blanket embroidered with twining vines on the ground."],
      'dispose_trash',
      ["wool blanket"],
      [assert_result]
    ).join
  end

  def test_dispose_trash__should_release_moonblade
    run_drci_command(
      ["As you open your hand to release the moonblade, it crumbles into a fine ash."],
      'dispose_trash',
      ["moonblade"],
      [assert_result]
    ).join
  end

  #########################################
  # GIVE ITEM
  #########################################

  def assert_give_item_success
    proc { |accepted| assert_equal(true, accepted) }
  end

  def assert_give_item_failure
    proc { |accepted| assert_equal(false, accepted) }
  end

  def run_give_item(messages, assertions = [])
    @test = run_script_with_proc(['common', 'common-items'], proc do
      # Setup
      $server_buffer = messages.dup
      $history = $server_buffer.dup

      # Test
      accepted = DRCI.give_item?('Frodo', 'ring')

      # Assert
      assertions = [assertions] unless assertions.is_a?(Array)
      assertions.each { |assertion| assertion.call(accepted) }
    end)
  end

  def test_give_item_accepts_offer
    messages = [
      'You offer your magic ring to Frodo, who has 30 seconds to accept the offer.  Type CANCEL to prematurely cancel the offer.',
      'Frodo has accepted your offer and is now holding a magical ring to rule them all.'
    ]
    run_give_item(messages, [
      assert_give_item_success
    ])
  end

  def test_give_item_offer_declined
    messages = [
      'You offer your magic ring to Frodo, who has 30 seconds to accept the offer.  Type CANCEL to prematurely cancel the offer.',
      'Frodo has declined the offer.'
    ]
    run_give_item(messages, [
      assert_give_item_failure
    ])
  end

  def test_give_item_offer_expires
    messages = [
      'You offer your magic ring to Frodo, who has 30 seconds to accept the offer.  Type CANCEL to prematurely cancel the offer.',
      'Your offer to Frodo has expired.'
    ]
    run_give_item(messages, [
      assert_give_item_failure
    ])
  end

  def test_give_item_multiple_outstanding_offers
    messages = [
      'You may only have one outstanding offer at a time.'
    ]
    run_give_item(messages, [
      assert_give_item_failure
    ])
  end

  def test_give_item_nothing_to_give
    messages = [
      "What is it you're trying to give"
    ]
    run_give_item(messages, [
      assert_give_item_failure
    ])
  end

  #########################################
  # ACCEPT ITEM
  #########################################

  def assert_accept_item_success
    proc { |giver| assert_equal('Frodo', giver) }
  end

  def assert_accept_item_failure
    proc { |giver| assert_equal(false, giver) }
  end

  def run_accept_item(messages, assertions = [])
    @test = run_script_with_proc(['common', 'common-items'], proc do
      # Setup
      $server_buffer = messages.dup
      $history = $server_buffer.dup

      # Test
      giver = DRCI.accept_item?

      # Assert
      assertions = [assertions] unless assertions.is_a?(Array)
      assertions.each { |assertion| assertion.call(giver) }
    end)
  end

  def test_accept_item_accepted
    messages = [
      "Frodo offers you a magical ring.  Enter ACCEPT to accept the offer or DECLINE to decline it.  The offer will expire in 30 seconds.",
      "You accept Frodo's offer and are now holding a magical ring."
    ]
    run_accept_item(messages, [
      assert_accept_item_success
    ])
  end

  def test_accept_item_no_offers
    messages = [
      "You have no offers to accept."
    ]
    run_accept_item(messages, [
      assert_accept_item_failure
    ])
  end

  def test_accept_item_hands_full
    messages = [
      "Frodo offers you a magical ring.  Enter ACCEPT to accept the offer or DECLINE to decline it.  The offer will expire in 30 seconds.",
      "Both of your hands are full."
    ]
    run_accept_item(messages, [
      assert_accept_item_failure
    ])
  end

  def test_accept_item_inventory_limit
    messages = [
      "Frodo offers you a magical ring.  Enter ACCEPT to accept the offer or DECLINE to decline it.  The offer will expire in 30 seconds.",
      "Accepting a magical ring would push you over your item limit of 100 items.  Please reduce your inventory count before you try again."
    ]
    run_accept_item(messages, [
      assert_accept_item_failure
    ])
  end

end
