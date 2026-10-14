# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Phase 1 and 2: drill-downs, the usage chart, history, search, keys, alerts.
class DrilldownTest < Minitest::Test
  SID = "aaaaaaaa-2222-3333-4444-555555555555"

  def setup
    @tmp = Dir.mktmpdir
    @store = Fixtures.store
    @host = BotOps::PreviewHost.new
    @scene = BotOps::Scene.new(@store, @host)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def click_text(text, canvas = @scene.build)
    cmd = canvas.cmds.find { |x| x.op == :text && x.a[0] == text && canvas.hit_at(x.a[1] + 2, x.a[2] + 4) }
    refute_nil cmd, "no clickable #{text.inspect}"
    @scene.click(cmd.a[1] + 2, cmd.a[2] + 4)
  end

  # ---- probe ---------------------------------------------------------------

  def transcript(records)
    project = File.join(@tmp, "projects", "-src-api")
    FileUtils.mkdir_p(project)
    FileUtils.mkdir_p(File.join(@tmp, "sessions"))
    File.open(File.join(project, "#{SID}.jsonl"), "w") { |f| records.each { |r| f.puts(JSON.generate(r)) } }
  end

  def rec(type, at, extra = {})
    { "type" => type, "timestamp" => Time.at(at).utc.iso8601(3), "cwd" => "/src/api", "sessionId" => SID }.merge(extra)
  end

  def reply(id, at, content, model: "claude-opus-5-5", out: 100)
    rec("assistant", at, "message" => { "id" => id, "model" => model, "content" => content,
                                        "usage" => { "input_tokens" => 5, "output_tokens" => out,
                                                     "cache_read_input_tokens" => 1000, "cache_creation_input_tokens" => 20 } })
  end

  def test_probe_times_tools_links_errors_and_keeps_a_week_of_usage
    now = Time.now.to_f
    transcript([
      reply("old", now - 3 * 86_400, [{ "type" => "text", "text" => "three days ago" }], out: 700),
      rec("user", now - 120, "message" => { "content" => "run the tests" }),
      reply("m1", now - 100, [{ "type" => "tool_use", "id" => "t1", "name" => "Bash", "input" => { "command" => "rake" } }]),
      rec("user", now - 88, "message" => { "content" => [{ "type" => "tool_result", "tool_use_id" => "t1", "is_error" => true, "content" => "boom" }] }),
      reply("m2", now - 80, [{ "type" => "tool_use", "id" => "t2", "name" => "Read", "input" => { "file_path" => "/a" } }], model: "claude-haiku-4-5-20251001", out: 30),
      rec("user", now - 79.5, "message" => { "content" => [{ "type" => "tool_result", "tool_use_id" => "t2", "content" => "ok" }] })
    ])
    snap = BotOps::Probe.new(claude_dir: @tmp, host: "box", full_detail: true).snapshot
    bash = snap["events"].find { |e| e["title"] == "Bash" }
    assert_in_delta 12.0, bash["duration"], 0.01, "call to result"
    assert bash["failed"]
    assert_in_delta 0.5, snap["events"].find { |e| e["title"] == "Read" }["duration"], 0.01
    assert_equal "Bash", snap["events"].find { |e| e["kind"] == "error" }["tool"]

    usage = snap["usage"]
    assert_equal %w[claude-haiku-4-5-20251001 claude-opus-5-5], usage.map { |r| r[2] }.reject(&:empty?).uniq.sort
    assert_equal 830, usage.sum { |r| r[4] }, "output over the week, old reply included"
    assert_equal 3 * 1000, usage.sum { |r| r[6] }, "cache reads"
    assert_equal 130, snap["hourly"].sum { |r| r[1] }

    agent = BotOps::Probe.new(claude_dir: @tmp, host: "box").snapshot
    assert_equal 130, agent["usage"].sum { |r| r[4] }, "agents report one day"
  end

  # ---- history -------------------------------------------------------------

  def test_history_keeps_the_larger_running_total_and_survives_a_restart
    path = File.join(@tmp, "history.json")
    hour = BotOps::Store.current_hour
    h = BotOps::History.new(path: path, save_every: 0)
    h.record("me@box", [[hour, "api", "m", "cli", 10, 1, 2, 3, 4, 5, 6]])
    h.record("me@box", [[hour, "api", "m", "cli", 7, 1, 2, 3, 9, 5, 6]]) # a restarted probe that has re-read less
    h.record("me@box", [[hour - 40 * 86_400, "api", "m", "cli", 1, 0, 0, 0, 0, 0, 0]])
    h.save
    rows = BotOps::History.new(path: path).rows(hour - 60 * 86_400)
    assert_equal [["me@box", hour, "api", "m", "cli", 10, 1, 2, 3, 9, 5, 6]], rows, "max per count; 30-day cut"

    File.write(path, JSON.generate([["me@box", hour, "api", "m", 1, 2, 3, 4, 5, 6, 7]]))
    assert_equal [["me@box", hour, "api", "m", "", 1, 2, 3, 4, 5, 6, 7]], BotOps::History.new(path: path).rows(0),
                 "files from before the client column still load"
  end

  def test_a_history_backed_store_charts_sources_that_went_quiet
    history = BotOps::History.new(path: File.join(@tmp, "h.json"))
    store = BotOps::Store.new(history: history, prefs: {})
    store.apply(type: "snapshot", snapshot: Fixtures.snapshot(host: "laptop"), local: true)
    store.apply(type: "snapshot", snapshot: Fixtures.snapshot(host: "other"), local: false)
    assert_equal 2 * 4200, store.totals[:out_tokens]
  end

  # ---- drill-downs -----------------------------------------------------------

  def test_header_stats_open_their_breakdowns
    { "OUTPUT TOKENS" => "Tokens", "TOOL CALLS (24H)" => "Tool calls", "PROMPTS (24H)" => "Prompts",
      "LIVE SESSIONS" => "Claude sessions" }.each do |label, title|
      click_text(label)
      assert_equal title, @store.overlay&.title, label
      @scene.close_overlay
    end
  end

  def test_token_and_tool_breakdowns
    o = @scene.tokens_overlay
    assert(o.sections.any? { |s| s.label == "By model" && s.text.include?("Opus 5.5") })
    assert(o.sections.any? { |s| s.label == "Cache hit" })
    tools = @store.tool_stats
    bash = tools.find { |t| t[:tool] == "Bash" }
    assert_equal 1, bash[:calls]
    t = @scene.tools_overlay.sections.find { |s| s.label == "By tool" }.text
    assert_match(/error rate/, t)
  end

  def test_timeline_project_and_period_views
    @store.selected_session_id = "s-busy"
    click_text("Timeline ›")
    tl = @store.overlay.sections.find { |s| s.label.start_with?("Timeline") }.text.lines
    assert_match(/›  fix the flaky login test/, tl.first, "oldest first")
    assert_match(/Bash.*bundle exec rake test/, tl.last)
    @scene.close_overlay

    o = @scene.project_overlay(@store.projects.first)
    assert_equal "api", o.title
    assert(o.sections.any? { |s| s.label.start_with?("Files edited") && s.text.include?("login.rb") })

    o = @scene.period_overlay(BotOps::Store.current_hour, 1)
    assert_equal "2", o.sections.find { |s| s.label == "Prompts" }.text
  end

  def test_context_meter_warns_near_the_window
    s = { "context" => 52_000, "model" => "claude-opus-5-5" }
    assert_equal "52k / 1M · 5%", @scene.context_text(s)
    assert_equal BotOps::Theme::TEXT, @scene.context_color(s)
    assert_equal BotOps::Theme::RED, @scene.context_color("context" => 195_000, "model" => "claude-haiku-4-5-20251001")
    assert_equal BotOps::Theme::YELLOW, @scene.context_color("context" => 850_000, "model" => "claude-opus-5-5")
  end

  def test_chart_ranges_and_legend_toggles
    click_text("7d")
    assert_equal "7d", @store.chart_range
    assert(@scene.build.texts.any? { |t| t.start_with?("Last 7 days") })
    click_text("Errors / 6h")
    assert_includes @store.hidden_series, "Errors"
    click_text("Errors / 6h")
    refute_includes @store.hidden_series, "Errors"
  end

  # ---- search, filters, keys ----------------------------------------------

  def test_slash_searches_and_enter_opens_the_result
    assert @scene.text("/")
    assert @store.overlay.search?
    @scene.text("rake TEST")
    assert(@scene.build.texts.any? { |t| t.include?("bundle exec rake test") })
    assert_equal 1, @store.search("rake TEST").size, "every word, any case"
    @scene.key(8)
    assert_equal "rake TES", @store.overlay.query
    @scene.key(13)
    assert_equal "Bash tool call", @store.overlay.title
    @scene.key(27)
    assert_nil @store.overlay
  end

  def test_arrows_move_through_sessions_and_enter_opens_the_timeline
    first, second = @store.all_sessions.map { |s| s["id"] }
    @store.selected_session_id = first
    assert @scene.key(40)
    assert_equal second, @store.selected_session_id
    @scene.key(40)
    assert_equal second, @store.selected_session_id, "stops at the end"
    @scene.key(38)
    assert_equal first, @store.selected_session_id
    @scene.key(13)
    assert_match(/Timeline/, @store.overlay.sections.map(&:label).join)
  end

  def test_this_session_only_narrows_tools_and_the_log
    @store.selected_session_id = "s-idle"
    assert_operator @store.visible_events.size, :>, 0
    @scene.toggle_session_only
    assert_empty @store.visible_events
    assert_empty @store.visible_tools
  end

  def test_the_frame_carries_the_waiting_count_for_the_dock
    snap = Fixtures.snapshot
    snap["sessions"][0]["attention"] = "permission"
    host = BotOps::NativeHost.new(channel: BotOps::Comms::Channel.new,
                                  store: BotOps::Store.new.apply(type: "snapshot", snapshot: snap, local: true))
    assert_equal 1, JSON.parse(host.poll)["badge"]
  end
end
