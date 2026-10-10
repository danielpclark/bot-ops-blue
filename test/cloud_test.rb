# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

class CloudFeedTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @log = File.join(@dir, "cloud-events.jsonl")
    @feed = BotOps::CloudFeed.new(log: @log)
    @now = Time.now.to_f
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def ev(name, extra = {})
    { "session_id" => "cloud-1", "hook_event_name" => name, "cwd" => "/home/user/tern", "at" => @now }.merge(extra)
  end

  def test_hook_events_become_a_claude_ai_source
    @feed.ingest(ev("SessionStart", "branch" => "fix/sheet", "at" => @now - 30))
    @feed.ingest(ev("UserPromptSubmit", "prompt" => "Fix the itinerary sheet\nmore detail", "at" => @now - 20))
    @feed.ingest(ev("PostToolUse", "tool_name" => "Bash", "detail" => "npm test", "at" => @now - 10))
    @feed.ingest(ev("PostToolUse", "tool_name" => "Bash", "detail" => "npm run lint", "error" => true, "at" => @now - 5))
    snap = @feed.snapshot
    assert_equal "claude.ai", snap["host"]
    s = snap["sessions"].first
    assert_equal ["Fix the itinerary sheet", "busy", "cloud", "fix/sheet"], s.values_at("name", "status", "entrypoint", "branch")
    assert_equal [2, 1, 1], s.values_at("tool_calls", "errors", "prompts")
    assert_equal({ "error" => 1, "tool" => 2, "prompt" => 1, "lifecycle" => 1 }, snap["events"].map { |e| e["kind"] }.tally)

    @feed.ingest(ev("Stop"))
    assert_equal "idle", @feed.snapshot["sessions"].first["status"]
    @feed.ingest(ev("SessionEnd", "reason" => "exit"))
    assert_empty @feed.snapshot["sessions"]
    assert_equal "ended", @feed.snapshot["recent"].first["status"]
  end

  def test_history_survives_a_restart_and_old_events_are_dropped
    @feed.ingest(ev("UserPromptSubmit", "prompt" => "hello"))
    File.open(@log, "a") { |f| f.puts JSON.generate(ev("UserPromptSubmit", "prompt" => "old", "at" => @now - 30 * 3600)) }
    again = BotOps::CloudFeed.new(log: @log)
    assert_equal 1, again.snapshot["sessions"].first["prompts"]
    assert_equal 1, File.readlines(@log).size, "replay rewrites the log without stale events"
  end

  def test_rejects_things_that_are_not_hook_events
    refute @feed.ingest({ "hello" => "world" })
    refute @feed.any?
  end

  def test_cloud_sessions_show_on_the_dashboard_next_to_local_ones
    @feed.ingest(ev("UserPromptSubmit", "prompt" => "Cloud task"))
    store = Fixtures.store
    store.apply(type: "snapshot", snapshot: @feed.snapshot, local: false)
    assert_equal "Cloud task", BotOps::Store.display_name(store.all_sessions.first)
    assert_includes store.machines.map { |m| m["host"] }, "claude.ai"
    c = BotOps::Scene.new(store, BotOps::PreviewHost.new).build
    assert_includes c.texts, "tern · Cloud"
    assert_includes c.texts, "SYSTEM HEALTH · laptop", "health stays on a real machine"
  end
end

class CloudReporterTest < Minitest::Test
  TOKEN = "cloud-reporter-token-123456"
  SCRIPT = File.expand_path("../cloud/bot-ops-report.py", __dir__)

  def run_hook(payload, env)
    Open3.capture2(env, "python3", SCRIPT, stdin_data: JSON.generate(payload))
  end

  def test_reporter_posts_a_trimmed_event_and_stays_silent
    skip "python3 not installed" unless system("python3", "-c", "1", out: File::NULL, err: File::NULL)
    got = Queue.new
    c = BotOps::Collector.new("127.0.0.1:0", TOKEN, on_event: ->(e) { got << e; true }) { |_| }.start
    url = "http://#{c.address}"
    payload = { "session_id" => "s1", "hook_event_name" => "PostToolUse", "cwd" => "/repo", "tool_name" => "Write",
                "tool_input" => { "file_path" => "/repo/secret.rb", "content" => "API_KEY=xyz" },
                "tool_response" => { "content" => "big output" }, "transcript_path" => "/tmp/t.jsonl" }
    out, status = run_hook(payload, "BOT_OPS_URL" => url, "BOT_OPS_TOKEN" => TOKEN)
    assert status.success?
    assert_equal "", out, "stdout must stay empty"
    e = got.pop(timeout: 5)
    assert_equal %w[at cwd detail hook_event_name session_id tool_name], e.keys.sort
    assert_equal "/repo/secret.rb", e["detail"]
    refute_includes JSON.generate(e), "API_KEY", "file contents never leave the session"
  ensure
    c&.stop
  end

  def test_reporter_does_nothing_without_configuration
    skip "python3 not installed" unless system("python3", "-c", "1", out: File::NULL, err: File::NULL)
    out, status = run_hook({ "session_id" => "s1", "hook_event_name" => "Stop" }, "BOT_OPS_URL" => "", "BOT_OPS_TOKEN" => "")
    assert status.success?
    assert_equal "", out
  end
end
