# frozen_string_literal: true

require "minitest/autorun"
require "bot_ops"

class SceneTest < Minitest::Test
  def setup
    @store = BotOps::Store.new
    @host = BotOps::PreviewHost.new
    @channel = BotOps::Comms::SimulatedChannel.new
    @scene = BotOps::Scene.new(@store, @host)
  end

  def canvas
    @scene.build
  end

  def click_text(canvas, text)
    cmd = canvas.cmds.find { |c| c.op == :text && c.a[0] == text && canvas.hit_at(c.a[1] + 2, c.a[2] + 2) }
    refute_nil cmd, "no clickable text #{text.inspect}"
    assert @scene.click(cmd.a[1] + 2, cmd.a[2] + 2)
  end

  def test_overview_draws_every_panel
    c = canvas
    %w[BOT\ FLEET LIVE\ BOT\ ACTIVITY WORKFLOWS TASK\ QUEUE CURRENT\ PIPELINE SYSTEM\ HEALTH
       RECENT\ ACTIVITY AGENT\ DETAILS RECENT\ LOGS RECENT\ REPORTS BOT\ OPS\ BLUE].each do |title|
      assert_includes c.texts, title
    end
    assert_operator c.count(:text), :>, 300
    assert_operator c.count(:rect), :>, 100
    assert_equal 4, c.count(:wedge), "four health gauges"
  end

  def test_refresh_loop_applies_simulated_events
    40.times { @store.apply_all(@channel.poll(@store)) }
    c = canvas
    assert_operator @store.logs.size, :>, 8
    assert_includes c.texts, "BOT OPS BLUE"
  end

  def test_tabs_filters_and_bot_selection
    c = canvas
    click_text(c, "Completed")
    assert_equal :completed, @store.activity_tab
    c = canvas
    assert_includes c.texts, "✓ Completed"

    click_text(c, "Pending (12)")
    assert_equal :pending, @store.queue_filter
    assert @store.visible_tasks.all? { |t| t.status == "Pending" }

    click_text(c, "Research Agent")
    assert_equal :research, @store.selected_bot_id
    assert_includes canvas.texts, "Analyzing market trends"
  end

  def test_every_page_builds_and_navigates
    BotOps::Layout::NAV.each do |key, name, _glyph|
      click_text(canvas, name)
      assert_equal key, @store.page
      c = canvas
      assert_operator c.count, :>, 50, "page #{key} is empty"
      refute_empty c.to_svg
    end
  end

  def test_header_window_controls
    c = canvas
    click_text(c, "▣")
    click_text(c, "⤢")
    click_text(c, "✕")
    assert_equal [:toggle_decorations, :toggle_fullscreen, :quit], @host.actions
  end

  def test_header_drag_region_excludes_controls
    canvas
    assert @scene.drag_region?(300, 30)
    refute @scene.drag_region?(1505, 12), "quit glyph is a button, not a drag handle"
    refute @scene.drag_region?(300, 300)
  end

  def test_store_applies_external_events
    @store.apply(type: "log", level: "ERROR", message: "boom")
    @store.apply("type" => "health", "cpu" => 91)
    @store.apply(type: "progress", bot_id: :content, progress: 100)
    assert_equal "boom", @store.logs.first.message
    assert_equal 91, @store.health[:cpu]
    assert_equal "Completed", @store.activity.find { |a| a.bot_id == :content }.status
  end
end

class FrameTest < Minitest::Test
  def test_frame_json_round_trips_commands_and_hits
    store = BotOps::Store.new
    host = BotOps::PreviewHost.new
    canvas = BotOps::Scene.new(store, host).build
    frame = JSON.parse(canvas.to_json(drag: [0, 0, 1536, 86]))
    assert_equal [0, 0, 1536, 86], frame["drag"]
    assert_equal canvas.count, frame["cmds"].size
    assert_equal canvas.hits.size, frame["hits"].size
    ops = frame["cmds"].map(&:first).uniq.sort
    assert_equal %w[a c l r t w], ops
    t = frame["cmds"].find { |c| c[0] == "t" && c[1] == "BOT OPS BLUE" }
    assert_equal ["bold", "sans", nil, "left", 3], t[6..10]
  end

  def test_native_host_polls_and_dispatches_hits
    host = BotOps::NativeHost.new(channel: BotOps::Comms::SimulatedChannel.new)
    frame = JSON.parse(host.poll)
    assert_equal "", host.poll, "nothing changed, so no new frame"
    quit_hit = frame["hits"].find { |h| h[1] < 30 && h[0] > 1495 } # top-right "x" glyph
    assert_equal "quit", host.hit(quit_hit[4])
    page_hit = frame["hits"].find { |h| h[0] < 90 && h[1] > 150 && h[1] < 220 } # sidebar "Bots"
    assert_equal "", host.hit(page_hit[4])
    assert_equal :bots, host.store.page
    refute_equal "", host.poll, "page change produces a new frame"
    host.toggle_fullscreen
    assert_equal "fullscreen:on", host.hit(-1)
  end
end
