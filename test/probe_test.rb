# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "net/http"

class ProbeTest < Minitest::Test
  SID = "11111111-2222-3333-4444-555555555555"

  def setup
    @dir = Dir.mktmpdir
    @now = Time.now
    FileUtils.mkdir_p(File.join(@dir, "sessions"))
    @project = File.join(@dir, "projects", "-src-api")
    FileUtils.mkdir_p(File.join(@project, SID, "subagents"))
    File.write(File.join(@dir, "sessions", "#{Process.pid}.json"), JSON.generate(
      "pid" => Process.pid, "sessionId" => SID, "cwd" => "/src/api", "name" => "api-e1", "kind" => "interactive",
      "entrypoint" => "cli", "status" => "busy", "startedAt" => ((@now.to_f - 600) * 1000).to_i, "version" => "2.1.0"
    ))
    File.write(File.join(@dir, "sessions", "999999.json"), JSON.generate("pid" => 999_999, "sessionId" => "dead"))
    @transcript = File.join(@project, "#{SID}.jsonl")
    write(@transcript, [
      line("ai-title", "aiTitle" => "Fix login"),
      line("user", "message" => { "content" => "fix the login test" }),
      line("user", "message" => { "content" => "<command-name>/clear</command-name>" }),
      assistant("m1", 100, [{ "type" => "tool_use", "name" => "Bash", "input" => { "command" => "rake test\nmore" } }]),
      assistant("m1", 100, [{ "type" => "text", "text" => "same message, second block" }]),
      line("user", "message" => { "content" => [{ "type" => "tool_result", "is_error" => true, "content" => "exit 1" }] }),
      line("queue-operation", "operation" => "enqueue", "content" => "also check CI")
    ])
    write(File.join(@project, SID, "subagents", "agent-a.jsonl"), [
      line("user", "isSidechain" => true, "message" => { "content" => "subagent brief" }),
      assistant("m2", 50, [{ "type" => "tool_use", "name" => "Grep", "input" => { "pattern" => "login" } }], model: "claude-haiku-4-5")
    ])
    @probe = BotOps::Probe.new(claude_dir: @dir, host: "box")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def line(type, extra = {})
    { "type" => type, "timestamp" => (@now - 60).utc.iso8601(3), "cwd" => "/src/api", "gitBranch" => "main", "sessionId" => SID }.merge(extra)
  end

  def assistant(id, out, content, model: "claude-opus-5-5")
    line("assistant", "message" => { "id" => id, "model" => model, "content" => content,
                                     "usage" => { "input_tokens" => 5, "output_tokens" => out, "cache_read_input_tokens" => 1000 } })
  end

  def write(path, records, mode = "w")
    File.open(path, mode) { |f| records.each { |r| f.puts(JSON.generate(r)) } }
  end

  def test_snapshot_reads_live_sessions_and_transcripts
    snap = @probe.snapshot(@now)
    assert_equal "box", snap["host"]
    assert_equal [SID], snap["sessions"].map { |s| s["id"] }, "dead pid is dropped"
    s = snap["sessions"].first
    assert_equal "busy", s["status"]
    assert_equal "Fix login", s["title"]
    assert_equal "claude-opus-5-5", s["model"], "subagent model does not replace the session's"
    assert_equal "main", s["branch"]
    assert_equal 150, s["tokens"]["out"], "usage counted once per message id, subagents included"
    assert_equal 1005, s["context"]
    assert_equal 2, s["tool_calls"]
    assert_equal 1, s["errors"]
    assert_equal 2, s["prompts"], "typed + queued prompts; wrappers and subagent briefs skipped"
    assert_equal "rake test", snap["events"].find { |e| e["title"] == "Bash" }["detail"]
    assert_equal [150, 2, 2, 1], snap["hourly"].map { |r| r[1..] }.transpose.map(&:sum)
    assert_equal "/src/api", snap["projects"].first["cwd"]
  end

  def test_refresh_reads_only_appended_lines
    @probe.snapshot(@now)
    write(@transcript, [assistant("m3", 7, [{ "type" => "tool_use", "name" => "Edit", "input" => { "file_path" => "/x.rb" } }])], "a")
    s = @probe.snapshot(@now)["sessions"].first
    assert_equal 157, s["tokens"]["out"]
    assert_equal "Edit", s["last_tool"]["name"]
  end

  def test_machine_health_has_real_numbers
    m = @probe.snapshot(@now)["machine"]
    assert_operator m["cpus"], :>, 0
    skip "health probes are macOS/Linux only" unless RUBY_PLATFORM =~ /darwin|linux/
    assert_kind_of Integer, m["mem_pct"]
    assert_kind_of Integer, m["disk_pct"]
  end
end

class StoreTest < Minitest::Test
  def test_machines_go_offline_and_their_sessions_leave_the_live_views
    store = BotOps::Store.new
    store.apply(type: "snapshot", snapshot: Fixtures.snapshot(host: "laptop"), local: true)
    store.apply(type: "snapshot", snapshot: Fixtures.snapshot(host: "tower"), local: false, at: Time.now - 60)
    assert_equal [true, false], store.machines.map { |m| m["online"] }
    assert_equal ["laptop"], store.sessions.map { |s| s["host"] }.uniq
    assert_equal 2 * 3000, store.hourly(1).last[1], "usage history still counts the offline machine"
    assert_equal "2", store.stats.first.value
  end

  def test_formatting
    assert_equal "12.4k", BotOps::Store.count(12_400)
    assert_equal "3.1M", BotOps::Store.count(3_100_000)
    assert_equal "Opus 5.5", BotOps::Store.model_name("claude-opus-5-5")
    assert_equal "Haiku 4.5", BotOps::Store.model_name("claude-haiku-4-5-20251001")
  end
end

class CollectorTest < Minitest::Test
  TOKEN = "collector-test-token-123"

  def post(port, body, token)
    Net::HTTP.post(URI("http://127.0.0.1:#{port}/v1/snapshot"), body, "Authorization" => "Bearer #{token}")
  end

  def test_accepts_authorized_snapshots_only
    got = Queue.new
    c = BotOps::Collector.new("127.0.0.1:0", TOKEN) { |s| got << s }.start
    port = c.address.split(":").last
    assert_equal "401", post(port, "{}", "nope").code
    assert_equal "400", post(port, "not json", TOKEN).code
    assert_equal "204", post(port, JSON.generate(Fixtures.snapshot(host: "tower")), TOKEN).code
    assert_equal "tower", got.pop(timeout: 2)["host"]
  ensure
    c&.stop
  end

  def test_refuses_to_start_without_a_strong_token
    assert_raises(ArgumentError) { BotOps::Collector.new("0.0.0.0:47800", "short") }
  end
end

class HookLogTest < Minitest::Test
  def test_permission_prompt_needs_you_until_the_session_moves_on
    Dir.mktmpdir do |dir|
      path = File.join(dir, "hooks.jsonl")
      log = BotOps::Probe::HookLog.new(path)
      now = Time.now.to_f
      File.write(path, [
        { "session_id" => "a", "hook_event_name" => "SessionStart", "source" => "startup", "at" => now - 30 },
        { "session_id" => "a", "hook_event_name" => "Notification", "message" => "Claude needs your permission to use Bash", "at" => now - 10 },
        { "session_id" => "b", "hook_event_name" => "Notification", "message" => "Claude is waiting for your input", "at" => now - 5 }
      ].map { |h| JSON.generate(h) + "\n" }.join)
      log.refresh(Time.now)
      assert_match(/permission/, log.pending_attention("a")["message"])
      assert_nil log.pending_attention("b"), "idle notifications are not attention"
      assert_equal %w[lifecycle attention], log.events(Time.now).map { |e| e["kind"] }

      File.open(path, "a") { |f| f.puts JSON.generate("session_id" => "a", "hook_event_name" => "Stop", "at" => now) }
      log.refresh(Time.now)
      assert_nil log.pending_attention("a"), "a finished turn clears it"
    end
  end

  def test_hook_script_logs_quietly_and_never_fails
    Dir.mktmpdir do |home|
      script = File.expand_path("../bin/bot-ops-hook", __dir__)
      payload = JSON.generate("session_id" => "s1", "hook_event_name" => "Stop", "cwd" => "/src/api", "transcript_path" => "/secret")
      out, status = Open3.capture2({ "HOME" => home }, RbConfig.ruby, script, stdin_data: payload)
      assert status.success?
      assert_equal "", out, "stdout must stay empty (it can be fed back to Claude)"
      line = JSON.parse(File.read(File.join(home, ".claude", "bot-ops", "hooks.jsonl")))
      assert_equal %w[at cwd hook_event_name session_id], line.keys.sort
      _, status = Open3.capture2({ "HOME" => home }, RbConfig.ruby, script, stdin_data: "not json")
      assert status.success?
    end
  end
end
