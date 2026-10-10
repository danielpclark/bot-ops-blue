# frozen_string_literal: true

require "test_helper"

class SceneTest < Minitest::Test
  def setup
    @store = Fixtures.store
    @host = BotOps::PreviewHost.new
    @scene = BotOps::Scene.new(@store, @host)
  end

  def canvas
    @scene.build
  end

  # Clicks the first clickable +text+; tab: true only matches pill tabs (20pt high).
  def click_text(canvas, text, tab: false)
    cmd = canvas.cmds.find do |c|
      next false unless c.op == :text && c.a[0] == text
      h = canvas.hit_at(c.a[1] + 2, c.a[2] + 2)
      h && (!tab || h.h == 20)
    end
    refute_nil cmd, "no clickable text #{text.inspect}"
    assert @scene.click(cmd.a[1] + 2, cmd.a[2] + 2)
  end

  def test_overview_draws_every_panel_from_real_data
    c = canvas
    ["CLAUDE SESSIONS", "LIVE ACTIVITY", "PROJECTS · 24H", "TOOL CALLS", "USAGE", "SYSTEM HEALTH · laptop",
     "RECENT PROMPTS", "SESSION DETAILS", "EVENT LOG", "MACHINES", "BOT OPS BLUE"].each do |title|
      assert_includes c.texts, title
    end
    assert_includes c.texts, "Fix flaky login test", "sessions are named by what they are working on"
    assert_includes c.texts, "api · CLI · api-fix"
    assert_includes c.texts, "Opus 5.5"
    assert_includes c.texts, "1 MACHINE ONLINE"
    assert_equal 4, c.count(:wedge), "four health gauges"
  end

  def test_empty_store_shows_empty_states_not_filler
    c = BotOps::Scene.new(BotOps::Store.new, @host).build
    assert_includes c.texts, "Reading Claude Code sessions…"
    assert_includes c.texts, "WAITING FOR DATA"
  end

  def test_tabs_filters_and_session_selection
    click_text(canvas, "Idle", tab: true)
    assert_equal :idle, @store.activity_tab
    assert_equal ["s-idle"], @store.visible_sessions.map { |s| s["id"] }

    click_text(canvas, "Errors (1)", tab: true)
    assert_equal :errors, @store.tool_filter
    assert_equal ["error"], @store.visible_tools.map { |e| e["kind"] }

    click_text(canvas, "docs")
    assert_equal "s-idle", @store.selected_session_id
    assert_includes canvas.texts, "Sonnet 5.5"
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
end

class FrameTest < Minitest::Test
  def test_frame_json_round_trips_commands_and_hits
    canvas = BotOps::Scene.new(Fixtures.store, BotOps::PreviewHost.new).build
    frame = JSON.parse(canvas.to_json(drag: [0, 0, 1536, 86]))
    assert_equal [0, 0, 1536, 86], frame["drag"]
    assert_equal canvas.count, frame["cmds"].size
    assert_equal canvas.hits.size, frame["hits"].size
    t = frame["cmds"].find { |c| c[0] == "t" && c[1] == "BOT OPS BLUE" }
    assert_equal ["bold", "sans", nil, "left", 3], t[6..10]
  end

  def test_native_host_polls_resizes_and_dispatches_hits
    channel = BotOps::Comms::Channel.new
    channel.push(type: "snapshot", snapshot: Fixtures.snapshot, local: true)
    host = BotOps::NativeHost.new(channel: channel)
    frame = JSON.parse(host.poll)
    assert_equal "", host.poll, "nothing changed, so no new frame"
    quit_hit = frame["hits"].find { |h| h[1] < 30 && h[0] > 1495 } # top-right "x" glyph
    assert_equal "quit", host.hit(quit_hit[4])
    page_hit = frame["hits"].find { |h| h[0] < 90 && h[1] > 150 && h[1] < 220 } # sidebar "Sessions"
    assert_equal "", host.hit(page_hit[4])
    assert_equal :sessions, host.store.page
    refute_equal "", host.poll, "page change produces a new frame"
    host.resize(1820, 1024)
    assert_equal 1820, JSON.parse(host.poll)["drag"][2], "resize lays out at the new width"
    host.toggle_fullscreen
    assert_equal "fullscreen:toggle", host.hit(-1)
  end

  def test_native_host_applies_new_data_on_the_next_frame
    channel = BotOps::Comms::Channel.new
    host = BotOps::NativeHost.new(channel: channel)
    host.poll
    assert_equal "", host.poll
    channel.push(type: "snapshot", snapshot: Fixtures.snapshot, local: true)
    refute_equal "", host.poll, "a snapshot is drawn right away, not on the next 2s tick"
    assert_equal 2, host.store.sessions.size
  end
end
