# frozen_string_literal: true

require "minitest/autorun"
require "bot_ops"

class DisplayTest < Minitest::Test
  # Laptop (main) with a taller QHD monitor to its right, bottoms offset.
  COCOA = "Built-in|0|0|1512|982\nDELL|1512|-458|2560|1440\n"

  def screens
    BotOps::Display.parse_cocoa(COCOA)
  end

  def position(env)
    BotOps::Display.position(1536, 1024, env: env, screens: screens)
  end

  def test_parse_cocoa_flips_to_top_left_origin
    main, ext = screens
    assert_equal [0, 0, 1512, 982], [main.left, main.top, main.width, main.height]
    assert_equal [1512, 0, 2560, 1440], [ext.left, ext.top, ext.width, ext.height]
  end

  def test_defaults_to_centering_on_the_external_monitor
    assert_equal "2024,208", position({})
    assert_equal "2024,208", position("BOT_OPS_DISPLAY" => "external")
  end

  def test_main_or_missing_monitor_leaves_placement_to_the_os
    assert_equal "", position("BOT_OPS_DISPLAY" => "main")
    assert_equal "", position("BOT_OPS_DISPLAY" => "3")
  end

  def test_external_only_refuses_when_just_the_main_monitor_is_connected
    laptop_only = screens.take(1)
    assert_nil BotOps::Display.position(1536, 1024, env: {}, screens: laptop_only)
    assert_equal "", BotOps::Display.position(1536, 1024, env: { "BOT_OPS_DISPLAY" => "main" }, screens: laptop_only)
  end

  def test_numbered_monitor_pins_oversized_window_to_its_corner
    assert_equal "0,0", position("BOT_OPS_DISPLAY" => "1")
    assert_equal "2024,208", position("BOT_OPS_DISPLAY" => "2")
  end

  def test_explicit_position_wins
    assert_equal "-100,40", position("BOT_OPS_POSITION" => "-100, 40", "BOT_OPS_DISPLAY" => "main")
    assert_equal "2024,208", position("BOT_OPS_POSITION" => "nonsense")
  end
end
