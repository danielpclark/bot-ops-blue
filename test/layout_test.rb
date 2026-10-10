# frozen_string_literal: true

require "minitest/autorun"
require "bot_ops"

class LayoutTest < Minitest::Test
  L = BotOps::Layout

  def test_fit_is_identity_at_design_size
    assert_equal L::FLEET, L.fit(L::FLEET, L::WIDTH, L::HEIGHT)
    assert_equal L::REPORTS, L.fit(L::REPORTS, L::WIDTH, L::HEIGHT)
  end

  def test_fit_stretches_columns_to_fill_a_wider_window
    w = 1820
    fleet, activity, workflows = [L::FLEET, L::ACTIVITY, L::WORKFLOWS].map { |r| L.fit(r, w, L::HEIGHT) }
    assert_equal L::CONTENT_X, fleet[0], "left edge stays put"
    assert_equal L::CONTENT_X + L.content_w(w), workflows[0] + workflows[2], "right edge reaches the window"
    assert_operator activity[0] - (fleet[0] + fleet[2]), :>=, L::GAP, "gap between panels kept"
    assert_equal L::ROW1_H, fleet[3], "rows keep their height when only width grows"
  end

  def test_scene_lays_out_for_the_window_size_but_never_below_design
    scene = BotOps::Scene.new(BotOps::Store.new, BotOps::PreviewHost.new)
    scene.resize(1820, 1024)
    assert_equal 1820, scene.build.width
    scene.resize(800, 600)
    assert_equal [L::WIDTH, L::HEIGHT], [scene.width, scene.height]
  end
end
