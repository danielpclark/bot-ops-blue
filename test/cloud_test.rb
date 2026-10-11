# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "socket"

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

  def test_the_sessions_own_title_beats_one_made_from_its_prompt
    @feed.ingest(ev("UserPromptSubmit", "prompt" => "fix the parser", "at" => @now - 20))
    assert_equal "fix the parser", @feed.snapshot["sessions"].first["name"]
    @feed.ingest(ev("PostToolUse", "tool_name" => "Read", "title" => "Library edge cases", "at" => @now - 10))
    @feed.ingest(ev("UserPromptSubmit", "prompt" => "and the tests", "at" => @now - 5))
    assert_equal "Library edge cases", @feed.snapshot["sessions"].first["name"]
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
    out, status = run_hook(payload, "BOT_OPS_URL" => url, "BOT_OPS_TOKEN" => TOKEN, "CLAUDE_CODE_REMOTE" => "true")
    assert status.success?
    assert_equal "", out, "stdout must stay empty"
    e = got.pop(timeout: 5)
    assert_equal %w[at cwd detail hook_event_name session_id tool_name], e.keys.sort
    assert_equal "/repo/secret.rb", e["detail"]
    refute_includes JSON.generate(e), "API_KEY", "file contents never leave the session"
  ensure
    c&.stop
  end

  # In a cloud session the token is a network secret: the agent proxy adds the
  # Authorization header, so the reporter must post without one.
  def test_reporter_leaves_authorization_to_the_network_secret
    skip "python3 not installed" unless system("python3", "-c", "1", out: File::NULL, err: File::NULL)
    server = TCPServer.new("127.0.0.1", 0)
    seen = Queue.new
    t = Thread.new do
      c = server.accept
      head = []
      while (l = c.gets) && l != "\r\n"
        head << l.strip
      end
      c.write("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      c.close
      seen << head
    end
    _, status = run_hook({ "session_id" => "s1", "hook_event_name" => "Stop" },
                         "BOT_OPS_URL" => "http://127.0.0.1:#{server.addr[1]}", "BOT_OPS_TOKEN" => "", "CLAUDE_CODE_REMOTE" => "true")
    assert status.success?
    head = seen.pop(timeout: 5)
    assert_equal "POST /v1/event HTTP/1.1", head.first
    refute head.any? { |h| h.downcase.start_with?("authorization:") }, "no token in the session"
    assert head.any? { |h| h.downcase.start_with?("ngrok-skip-browser-warning:") }
  ensure
    t&.kill
    server&.close
  end

  # Local sessions (Mac, VS Code) are read from disk already; the reporter
  # must stay silent there even if BOT_OPS_URL happens to be set.
  def test_reporter_is_silent_outside_cloud_sessions
    skip "python3 not installed" unless system("python3", "-c", "1", out: File::NULL, err: File::NULL)
    server = TCPServer.new("127.0.0.1", 0)
    _, status = run_hook({ "session_id" => "s1", "hook_event_name" => "Stop" },
                         "BOT_OPS_URL" => "http://127.0.0.1:#{server.addr[1]}", "CLAUDE_CODE_REMOTE" => "")
    assert status.success?
    assert_nil IO.select([server], nil, nil, 1.5), "no request without CLAUDE_CODE_REMOTE=true"
  ensure
    server&.close
  end

  # The claude.ai sidebar shows the session's title: the hand-given one if it
  # was renamed, else the generated one. Both live in the transcript.
  def test_reporter_sends_the_sessions_title_from_its_transcript
    skip "python3 not installed" unless system("python3", "-c", "1", out: File::NULL, err: File::NULL)
    Dir.mktmpdir do |home|
      transcript = File.join(home, "t.jsonl")
      File.write(transcript, [{ "type" => "ai-title", "aiTitle" => "Library edge cases" }].map { |r| JSON.generate(r) + "\n" }.join)
      got = Queue.new
      c = BotOps::Collector.new("127.0.0.1:0", TOKEN, on_event: ->(e) { got << e; true }) { |_| }.start
      env = { "HOME" => home, "BOT_OPS_URL" => "http://#{c.address}", "BOT_OPS_TOKEN" => TOKEN, "CLAUDE_CODE_REMOTE" => "true" }
      fire = -> { run_hook({ "session_id" => "s1", "hook_event_name" => "Stop", "transcript_path" => transcript }, env); got.pop(timeout: 5) }
      assert_equal "Library edge cases", fire.call["title"]

      File.open(transcript, "a") { |f| f.puts JSON.generate("type" => "custom-title", "customTitle" => "Renamed by hand") }
      assert_equal "Renamed by hand", fire.call["title"]
      File.open(transcript, "a") { |f| f.puts JSON.generate("type" => "ai-title", "aiTitle" => "Newer generated title") }
      assert_equal "Renamed by hand", fire.call["title"], "a hand-given title wins over later generated ones"
      refute fire.call.key?("transcript_path"), "the transcript path itself is not sent"
    ensure
      c&.stop
    end
  end

  def test_reporter_does_nothing_without_configuration
    skip "python3 not installed" unless system("python3", "-c", "1", out: File::NULL, err: File::NULL)
    out, status = run_hook({ "session_id" => "s1", "hook_event_name" => "Stop" }, "BOT_OPS_URL" => "", "BOT_OPS_TOKEN" => "")
    assert status.success?
    assert_equal "", out
  end
end

class CloudSetupScriptTest < Minitest::Test
  def test_committed_setup_script_matches_the_reporter
    require "bot_ops/cloud_setup"
    assert_equal BotOps::CloudSetup.script, File.read(BotOps::CloudSetup::PATH),
                 "cloud/setup.sh is stale: run `bundle exec rake cloud:setup_script`"
  end

  def test_setup_script_installs_a_cloud_only_user_hook_for_every_repo
    skip "python3 not installed" unless system("python3", "-c", "1", out: File::NULL, err: File::NULL)
    require "bot_ops/cloud_setup"
    Dir.mktmpdir do |home|
      FileUtils.mkdir_p(File.join(home, ".claude"))
      File.write(File.join(home, ".claude", "settings.json"), JSON.generate("model" => "x", "hooks" => { "Stop" => [{ "hooks" => [{ "type" => "command", "command" => "keep-me" }] }] }))
      2.times { assert system({ "HOME" => home }, "bash", BotOps::CloudSetup::PATH, out: File::NULL, err: File::NULL) }

      installed = File.read(File.join(home, ".claude", "hooks", "bot-ops-report.py"))
      assert_equal File.read(File.join(BotOps::CloudSetup::DIR, "bot-ops-report.py")), installed
      settings = JSON.parse(File.read(File.join(home, ".claude", "settings.json")))
      assert_equal "x", settings["model"]
      assert_equal %w[keep-me] + [BotOps::CloudSetup::COMMAND], settings["hooks"]["Stop"].map { |g| g["hooks"][0]["command"] },
                   "existing hooks kept, ours added once"
      assert_equal BotOps::CloudSetup::EVENTS.sort, (settings["hooks"].keys).sort

      # Fire the installed hook command the way Claude Code would in the cloud.
      server = TCPServer.new("127.0.0.1", 0)
      env = { "HOME" => home, "CLAUDE_CODE_REMOTE" => "true", "BOT_OPS_URL" => "http://127.0.0.1:#{server.addr[1]}" }
      _, status = Open3.capture2(env, "bash", "-c", BotOps::CloudSetup::COMMAND,
                                 stdin_data: JSON.generate("session_id" => "c1", "hook_event_name" => "Stop"))
      assert status.success?
      refute_nil IO.select([server], nil, nil, 5), "the installed hook reported"
      c = server.accept
      assert_equal "POST /v1/event HTTP/1.1", c.gets.strip
      c.close
      server.close
    end
  end
end

class CloudIconTest < Minitest::Test
  def test_cloud_sessions_get_a_drawn_hollow_cloud
    feed = BotOps::CloudFeed.new(log: File.join(Dir.mktmpdir, "c.jsonl"))
    feed.ingest({ "session_id" => "c1", "hook_event_name" => "UserPromptSubmit", "cwd" => "/home/user/kis_http", "prompt" => "hi" })
    store = Fixtures.store
    store.apply(type: "snapshot", snapshot: feed.snapshot, local: false)
    c = BotOps::Scene.new(store, BotOps::PreviewHost.new).build
    refute_includes c.texts, "☁"
    clouds = c.cmds.select { |cmd| cmd.op == :polyline && cmd.a[3] }
    refute_empty clouds, "a closed outline, not a filled glyph"
    assert_includes JSON.parse(c.to_json)["cmds"].map(&:first), "p"
  end
end

class CloudSessionLinkTest < Minitest::Test
  TOKEN = "cloud-link-token-123456789"
  SCRIPT = File.expand_path("../cloud/bot-ops-report.py", __dir__)

  def report(env)
    got = Queue.new
    c = BotOps::Collector.new("127.0.0.1:0", TOKEN, on_event: ->(e) { got << e; true }) { |_| }.start
    Open3.capture2({ "BOT_OPS_URL" => "http://#{c.address}", "BOT_OPS_TOKEN" => TOKEN, "CLAUDE_CODE_REMOTE" => "true" }.merge(env),
                   "python3", SCRIPT, stdin_data: JSON.generate("session_id" => "s1", "hook_event_name" => "Stop"))
    got.pop(timeout: 5)
  ensure
    c&.stop
  end

  def test_reporter_sends_the_session_page_from_the_remote_session_id
    skip "python3 not installed" unless system("python3", "-c", "1", out: File::NULL, err: File::NULL)
    assert_equal "https://claude.ai/code/session_01AbC", report("CLAUDE_CODE_REMOTE_SESSION_ID" => "cse_01AbC")["url"]
    refute report("CLAUDE_CODE_REMOTE_SESSION_ID" => "cse_x/../evil")&.key?("url"), "odd ids send no link"
  end

  def test_only_claude_ai_session_pages_become_links
    feed = BotOps::CloudFeed.new(log: File.join(Dir.mktmpdir, "c.jsonl"))
    base = { "session_id" => "c1", "hook_event_name" => "Stop", "cwd" => "/home/user/rutie" }
    feed.ingest(base.merge("url" => "https://evil.example/x"))
    assert_nil feed.snapshot["sessions"].first["url"]
    feed.ingest(base.merge("url" => "https://claude.ai/code/session_01AbC"))
    assert_equal "https://claude.ai/code/session_01AbC", feed.snapshot["sessions"].first["url"]
  end

  def test_session_row_and_details_link_open_the_page
    feed = BotOps::CloudFeed.new(log: File.join(Dir.mktmpdir, "c.jsonl"))
    feed.ingest({ "session_id" => "c1", "hook_event_name" => "UserPromptSubmit", "prompt" => "Backport PR 232",
                  "cwd" => "/home/user/rutie", "url" => "https://claude.ai/code/session_01AbC" })
    store = BotOps::Store.new.apply(type: "snapshot", snapshot: feed.snapshot, local: false)
    host = BotOps::PreviewHost.new
    scene = BotOps::Scene.new(store, host)
    c = scene.build
    %w[↗ Open\ in\ claude.ai\ ↗].each do |label|
      cmd = c.cmds.find { |x| x.op == :text && x.a[0] == label }
      refute_nil cmd, "#{label} drawn"
      assert scene.click(cmd.a[1] + 2, cmd.a[2] + 4)
    end
    assert_equal [[:open_url, "https://claude.ai/code/session_01AbC"]] * 2, host.actions
    assert_equal "open:https://claude.ai/code/session_01AbC",
                 BotOps::NativeHost.new(channel: BotOps::Comms::Channel.new).tap { |h| h.open_url("https://claude.ai/code/session_01AbC") }.hit(-1)
  end
end
