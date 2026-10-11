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

  # Code keeps its line breaks and indentation: never wrapped, so it pans
  # sideways instead, and stays clipped to the frame.
  CODE = "if true\n  echo #{'x' * 300} \\\n       --continued\nend"

  def test_code_is_never_wrapped_or_split
    lines = BotOps::Overlay.new("t").field("When", "now").block("Input", CODE).lines
    mono = lines.select { |l| l[0] == :mono }.map(&:last)
    assert_equal CODE.split("\n"), mono, "every line exactly as written, indentation included"
    assert_equal [:field, "When", "now", 6], lines.first
  end

  def test_only_notes_wrap_and_only_between_words
    lines = BotOps::Overlay.new("t").note("alpha beta gamma delta epsilon zeta eta theta iota kappa").lines(22).map(&:last)
    assert_equal ["alpha beta gamma delta", "epsilon zeta eta theta", "iota kappa"], lines
  end

  def test_long_lines_pan_sideways_within_the_frame
    @scene.open_overlay(BotOps::Overlay.new("t").block("Input", CODE))
    c = @scene.build
    assert(c.texts.any? { |t| t.include?("drag or swipe sideways") }, "says it can pan")
    line = ->(canvas) { canvas.cmds.find { |x| x.op == :text && x.a[0].start_with?("  echo xxx") } }
    x0 = line.(c).a[1]
    assert @scene.pan(120, 0)
    assert_in_delta x0 - 120, line.(@scene.build).a[1], 0.01, "the text moved left"
    @scene.pan(100_000, 0)
    @scene.build
    max = @store.overlay.x_offset
    assert_operator max, :<, 100_000, "stops at the right end"
    @scene.pan(-100_000, 0)
    @scene.build
    assert_equal 0, @store.overlay.x_offset
    ops = @scene.build.cmds.map(&:op)
    assert_equal ops.count(:clip), ops.count(:unclip)
    assert_operator ops.count(:clip), :>=, 2, "title and body are clipped"
  end

  def test_short_content_has_nothing_to_pan
    @scene.open_overlay(BotOps::Overlay.new("t").block("Input", "ls -la"))
    refute(@scene.build.texts.any? { |t| t.include?("sideways") })
    @scene.pan(50, 0)
    @scene.build
    assert_equal 0, @store.overlay.x_offset
  end

  def test_drags_in_the_body_reach_ruby_as_pans
    host = BotOps::NativeHost.new(channel: BotOps::Comms::Channel.new)
    assert_nil JSON.parse(host.poll)["pan"], "no overlay, nothing to pan"
    host.scene.open_overlay(BotOps::Overlay.new("t").block("Input", CODE))
    region = JSON.parse(host.poll)["pan"]
    refute_nil region
    host.pan(40, 32)
    assert_equal 40, host.store.overlay.x_offset
    assert_equal 2, host.store.overlay.offset, "32pt down = 2 lines"
  end
end
