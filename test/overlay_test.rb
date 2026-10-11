# frozen_string_literal: true

require "test_helper"

class OverlayTest < Minitest::Test
  LONG = (1..80).map { |i| "echo line #{i}" }.join("\n")

  def setup
    snap = Fixtures.snapshot
    snap["events"][0]["full"] = "command:\n#{LONG.lines.map { |l| "  #{l.chomp}" }.join("\n")}"
    @store = BotOps::Store.new.apply(type: "snapshot", snapshot: snap, local: true)
    @host = BotOps::PreviewHost.new
    @scene = BotOps::Scene.new(@store, @host)
  end

  def click_text(text)
    c = @scene.build
    cmd = c.cmds.find { |x| x.op == :text && x.a[0] == text && c.hit_at(x.a[1] + 2, x.a[2] + 4) }
    refute_nil cmd, "no clickable #{text.inspect}"
    @scene.click(cmd.a[1] + 2, cmd.a[2] + 4)
  end

  def overlay_box
    w, h = @scene.width, @scene.height
    bw = [[w - 260, 1040].min, 560].max
    bh = [[h - 200, 780].min, 320].max
    [(w - bw) / 2, (h - bh) / 2, bw, bh]
  end

  def test_clicking_a_tool_call_opens_its_full_detail
    click_text("bundle exec rake test") # the Tool Calls row's detail
    o = @store.overlay
    refute_nil o
    assert_equal "Bash tool call", o.title
    texts = @scene.build.texts
    assert_includes texts, "  echo line 1", "the full input, not the excerpt"
    assert(texts.any? { |t| t.include?("Esc, X or a click outside closes") })
  end

  def test_x_and_a_click_outside_close_it_but_a_click_inside_does_not
    click_text("bundle exec rake test")
    bx, by, bw, bh = overlay_box
    @scene.build
    @scene.click(bx + bw / 2, by + bh / 2)
    refute_nil @store.overlay, "inside the box"
    @scene.click(bx + bw - 28, by + 22)
    assert_nil @store.overlay, "the X"

    click_text("bundle exec rake test")
    @scene.build
    @scene.click(5, 5)
    assert_nil @store.overlay, "the backdrop"
  end

  def test_it_scrolls_and_stops_at_the_ends
    click_text("bundle exec rake test")
    @scene.build
    assert @scene.scroll(5)
    @scene.build
    assert_equal 5, @store.overlay.offset
    @scene.scroll(10_000)
    @scene.build
    max = @store.overlay.offset
    assert_operator max, :>, 5
    assert_includes @scene.build.texts, "  echo line 80", "the last line is reachable"
    @scene.scroll(-10_000)
    @scene.build
    assert_equal 0, @store.overlay.offset
    refute BotOps::Scene.new(BotOps::Store.new, @host).scroll(3), "nothing to scroll without an overlay"
  end

  def test_escape_closes_it_first
    host = BotOps::NativeHost.new(channel: BotOps::Comms::Channel.new)
    assert_equal "", host.key(27), "no overlay: Esc is left for fullscreen"
    host.scene.open_overlay(BotOps::Overlay.new("x"))
    assert_equal "handled", host.key(27)
    assert_nil host.store.overlay
  end

  def test_other_panels_open_overlays_too
    click_text("fix the flaky login test") # Recent Prompts
    assert_equal "Prompt", @store.overlay.title
    @scene.close_overlay
    click_text("laptop") # Machines
    assert_equal "laptop", @store.overlay.title
    assert(@store.overlay.sections.any? { |s| s.label == "Live sessions" })
  end

  def test_excerpt_only_events_say_so
    o = BotOps::Overlay.new("t")
    @scene.open_overlay(@scene.event_overlay(@store.events.find { |e| e["kind"] == "prompt" }))
    assert(@store.overlay.sections.any? { |s| s.kind == :note }, "no full text: explain why")
    assert_equal [[:field, "a", "b", 3]], o.field("a", "b").lines(40)
  end

  # Text wraps from the character width the native side measures, and the
  # body is clipped to the frame either way.
  def test_wrapping_follows_the_measured_font_width_and_text_is_clipped_to_the_box
    @scene.open_overlay(BotOps::Overlay.new("t").block("Input", "y" * 400))
    widest = ->(c) { c.cmds.select { |x| x.op == :text && x.a[0].start_with?("y") }.map { |x| x.a[0].length }.max }
    nominal = widest.(@scene.build)
    @scene.mono_char = 6.6 # pixel rounding made characters wider at this zoom
    wider = widest.(@scene.build)
    assert_operator wider, :<, nominal, "fewer columns when characters are wider"
    bx, _, bw, = overlay_box
    assert_operator 24 + wider * 6.6, :<=, bw - 38, "the widest line fits inside the clip"
    ops = @scene.build.cmds.map(&:op)
    assert_equal ops.count(:clip), ops.count(:unclip)
    assert_operator ops.count(:clip), :>=, 2, "title and body are clipped"
  end

  def test_long_lines_wrap_to_the_box
    lines = BotOps::Overlay.new("t").block("Input", "x" * 95).lines(40)
    assert_equal [[:heading, "Input"], [:mono, "x" * 40], [:mono, "x" * 40], [:mono, "x" * 15]], lines
  end
end
