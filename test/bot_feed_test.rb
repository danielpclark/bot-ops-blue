# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "socket"

class BotFeedTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @log = File.join(@dir, "bot-events.jsonl")
    @feed = BotOps::BotFeed.new(log: @log)
    @now = Time.now.to_f
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def ev(name, extra = {})
    { "bot" => "Bot Ops", "bot_event" => name, "run_id" => "r_8f2c1a", "at" => @now }.merge(extra)
  end

  def test_routine_run_becomes_a_bots_source
    @feed.ingest(ev("run_start", "routine" => "nightly-digest", "title" => "Compile nightly ops digest", "at" => @now - 220))
    @feed.ingest(ev("heartbeat", "at" => @now - 160))
    snap = @feed.snapshot
    assert_equal "bots", snap["host"]
    s = snap["sessions"].first
    assert_equal ["Compile nightly ops digest", "busy", "bot-routine", "nightly-digest", "Bot Ops", "Bot Ops"],
                 s.values_at("name", "status", "entrypoint", "routine", "bot", "cwd")
    assert_equal @now - 220, s["started_at"]
    assert_equal @now - 160, s["last_at"]

    @feed.ingest(ev("run_end", "result" => "Digest written: 4 incidents, 0 open", "at" => @now - 1))
    snap = @feed.snapshot
    assert_empty snap["sessions"]
    r = snap["recent"].first
    assert_equal ["ended", "Digest written: 4 incidents, 0 open", @now - 1], r.values_at("status", "result", "ended_at")
    assert_equal({ "lifecycle" => 2 }, snap["events"].map { |e| e["kind"] }.tally)
    assert_equal ["run finished", "run started"], snap["events"].map { |e| e["title"] }
    assert_equal({ "cwd" => "Bot Ops", "sessions" => 1 }, snap["projects"].first.slice("cwd", "sessions"))
    assert_equal "idle", snap["bots"].first["status"]
    assert_equal "r_8f2c1a", snap["bots"].first["last_run"]["id"]
  end

  def test_heartbeats_keep_a_run_live_without_event_rows
    @feed.ingest(ev("run_start", "routine" => "digest", "at" => @now - 200))
    3.times { |i| @feed.ingest(ev("heartbeat", "at" => @now - 140 + i * 60)) }
    snap = @feed.snapshot
    assert_equal "busy", snap["sessions"].first["status"]
    assert_equal @now - 20, snap["sessions"].first["last_at"]
    assert_equal 1, snap["events"].size, "heartbeats leave no event rows"
    assert_equal "working", snap["bots"].first["status"]
    assert_equal "r_8f2c1a", snap["bots"].first["current_run"]
  end

  def test_run_error_ends_the_run_and_marks_the_bot_error
    @feed.ingest(ev("run_start", "bot" => "Legal - Contracts", "team" => "legal", "run_id" => "r_77aa", "routine" => "nda-review", "at" => @now - 100))
    @feed.ingest(ev("run_error", "bot" => "Legal - Contracts", "run_id" => "r_77aa", "error" => "Drive download 403 on Acme_NDA_v3.docx"))
    snap = @feed.snapshot
    r = snap["recent"].first
    assert_equal ["ended", 1, "Drive download 403 on Acme_NDA_v3.docx"], r.values_at("status", "errors", "last_error")
    err = snap["events"].find { |e| e["kind"] == "error" }
    assert_equal ["run failed", "Drive download 403 on Acme_NDA_v3.docx", "Legal - Contracts"], err.values_at("title", "detail", "project")
    b = snap["bots"].first
    assert_equal ["Legal - Contracts", "legal", "error", 1, 1], b.values_at("name", "team", "status", "runs_24h", "errors_24h")
    assert_equal "Drive download 403 on Acme_NDA_v3.docx", b["last_run"]["error"]
    hour = (@now.to_i / 3600) * 3600
    assert_includes snap["usage"], [hour, "Legal - Contracts", "", "bot-routine", 0, 0, 0, 0, 0, 0, 1]
  end

  def test_run_goes_stale_after_five_minutes_of_silence
    @feed.ingest(ev("run_start", "routine" => "digest"))
    assert_equal "busy", @feed.snapshot(Time.at(@now + 299))["sessions"].first["status"]
    snap = @feed.snapshot(Time.at(@now + 301))
    assert_empty snap["sessions"]
    r = snap["recent"].first
    assert_equal ["ended", true, @now, 1], r.values_at("status", "stale", "ended_at", "errors")
    silent = ->(sn) { sn["events"].select { |e| e["title"] == "run went silent" } }
    assert_equal 1, silent.(snap).size
    assert_equal "no heartbeat for 5 min", silent.(snap).first["detail"]
    again = @feed.snapshot(Time.at(@now + 302))
    assert_equal 1, silent.(again).size, "swept once"
    assert_equal 1, again["recent"].first["errors"]
    assert_equal "stale", again["bots"].first["status"]
    assert_equal "stale", again["bots"].first["runs"].last[2]
  end

  def test_heartbeat_for_an_unknown_run_creates_it
    @feed.ingest(ev("heartbeat", "run_id" => "r_mid", "at" => @now - 30))
    s = @feed.snapshot["sessions"].first
    assert_equal ["r_mid", "busy", "run r_mid", "Bot Ops", nil], s.values_at("id", "status", "name", "cwd", "routine")
    assert_equal @now - 30, s["started_at"]
    @feed.ingest(ev("task", "run_id" => "r_mid", "task" => "fetch", "detail" => "calendar", "at" => @now - 20))
    @feed.ingest(ev("run_end", "run_id" => "r_mid", "result" => "ok", "at" => @now - 10))
    snap = @feed.snapshot
    assert_equal 1, snap["recent"].first["tool_calls"]
    assert_equal({ "name" => "fetch", "detail" => "calendar", "at" => @now - 20 }, snap["recent"].first["last_tool"])
    assert_equal %w[lifecycle tool], snap["events"].map { |e| e["kind"] }
  end

  def test_history_survives_a_restart_and_old_events_are_dropped
    @feed.ingest(ev("run_start", "routine" => "digest", "at" => @now - 100))
    @feed.ingest(ev("run_end", "result" => "fine", "at" => @now - 50))
    File.open(@log, "a") { |f| f.puts JSON.generate(ev("run_start", "run_id" => "r_old", "at" => @now - 30 * 3600)) }
    first = @feed.snapshot
    again = BotOps::BotFeed.new(log: @log)
    second = again.snapshot
    assert_equal first.except("at"), second.except("at")
    assert_equal 2, File.readlines(@log).size, "replay rewrites the log without stale events"
  end

  def test_rejects_things_that_are_not_bot_events
    refute @feed.ingest({ "session_id" => "s1", "hook_event_name" => "Stop" }), "a hook event"
    refute @feed.ingest(ev("run_start", "run_id" => "bad id!"))
    refute @feed.ingest(ev("run_start", "run_id" => "x" * 129))
    refute @feed.ingest(ev("run_start", "bot" => ""))
    refute @feed.ingest(ev("run_start").except("bot"))
    refute @feed.ingest(ev("run_pause"))
    refute @feed.ingest("not a hash")
    refute @feed.any?
    refute File.exist?(@log)
  end

  def test_long_fields_are_truncated_and_tokens_ignored
    @feed.ingest(ev("run_start", "bot" => "B" * 100, "routine" => "r" * 100, "title" => "t" * 200, "team" => "T" * 100,
                                 "tokens" => { "out" => 999 }, "usage" => [[0, "m", 1, 2, 3, 4]], "at" => @now - 10))
    @feed.ingest(ev("task", "bot" => "B" * 100, "task" => "k" * 100, "detail" => "d" * 200, "error" => "e" * 400))
    snap = @feed.snapshot
    s = snap["sessions"].first
    assert_equal [64, 80, 120, 64], s.values_at("bot", "routine", "title", "team").map(&:length)
    assert_equal [64, 160], s["last_tool"].values_at("name", "detail").map(&:length)
    assert_equal({}, s["tokens"])
    assert_equal 0, snap["usage"].sum { |r| r[4] }, "no token columns"
    assert_equal 1, s["errors"], "a task with an error is a task error too"
    assert_equal 1, snap["events"].count { |e| e["kind"] == "error" }
  end

  def test_bots_roster_has_runs_for_the_dot_strip
    runs = [["r1", @now - 4000, "run_end"], ["r2", @now - 3000, "run_error"], ["r3", @now - 2000, "run_end"]]
    runs.each do |id, at, finish|
      @feed.ingest(ev("run_start", "run_id" => id, "routine" => "digest", "at" => at))
      @feed.ingest(ev(finish, "run_id" => id, "at" => at + 60, "error" => "boom", "result" => "ok"))
    end
    @feed.ingest(ev("run_start", "run_id" => "r4", "routine" => "digest", "at" => @now - 1000))
    @feed.ingest(ev("run_start", "run_id" => "r5", "routine" => "digest", "at" => @now - 10))
    b = @feed.snapshot["bots"].first
    assert_equal %w[ended error ended stale working], b["runs"].map(&:last)
    assert_equal [@now - 4000, @now - 3940], b["runs"].first[0, 2]
    assert_nil b["runs"].last[1]
    assert_equal ["working", "r5", 5, 2], b.values_at("status", "current_run", "runs_24h", "errors_24h")
    assert_equal "r4", b["last_run"]["id"], "the most recently finished run"
  end
end

class BotDashboardTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @feed = BotOps::BotFeed.new(log: File.join(@dir, "bot-events.jsonl"))
    @now = Time.now.to_f
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_bot_runs_show_on_the_dashboard_next_to_claude_sessions
    @feed.ingest({ "bot" => "Bot Ops", "bot_event" => "run_start", "run_id" => "r_1", "routine" => "nightly-digest",
                   "title" => "Compile nightly ops digest", "at" => @now - 30 })
    @feed.ingest({ "bot" => "Bot Ops", "bot_event" => "task", "run_id" => "r_1", "task" => "drive.search", "detail" => "incidents", "at" => @now - 10 })
    @feed.ingest({ "bot" => "George", "team" => "legal", "bot_event" => "run_error", "run_id" => "r_2", "error" => "403", "at" => @now - 5 })
    store = Fixtures.store
    store.apply(type: "snapshot", snapshot: @feed.snapshot, local: false)
    assert_includes store.all_sessions.map { |s| BotOps::Store.display_name(s) }, "Compile nightly ops digest"
    assert_includes store.machines.map { |m| m["host"] }, "bots"
    assert_equal "Compile nightly ops digest", store.events.find { |e| e["title"] == "drive.search" }["session"]
    assert_equal %w[Bot\ Ops George], store.bots.map { |b| b["name"] }
    assert_equal ["working", "error"], store.bots.map { |b| b["status"] }
    assert_equal ["bots", true], store.bots.first.values_at("source", "online")
    assert_equal "Bots", BotOps::Store.client_name("bot-routine")
    assert_equal 6, store.stats.size, "a BOTS stat joins the header once a bot reports"
  end
end

class BotReporterTest < Minitest::Test
  TOKEN = "bot-reporter-token-123456789"
  SCRIPT = File.expand_path("../cloud/bot-ops-bot-report.py", __dir__)

  def setup
    skip "python3 not installed" unless system("python3", "-c", "1", out: File::NULL, err: File::NULL)
    @home = Dir.mktmpdir
    @got = Queue.new
    @collector = BotOps::Collector.new("127.0.0.1:0", TOKEN, on_bot_event: ->(e) { @got << e; true }) { |_| }.start
    @env = { "HOME" => @home, "BOT_OPS_URL" => "http://#{@collector.address}", "BOT_OPS_TOKEN" => TOKEN, "BOT_OPS_HEARTBEAT_S" => "0.2" }
  end

  def teardown
    @collector&.stop
    FileUtils.remove_entry(@home) if @home
  end

  def run_script(*args, env: {})
    Open3.capture3(@env.merge(env), "python3", SCRIPT, *args)
  end

  # Every event posted so far, up to and including the one that ends the run.
  def events(n)
    out = []
    while out.size < n && (e = @got.pop(timeout: 5))
      out << e
      break if %w[run_end run_error].include?(e["bot_event"])
    end
    out
  end

  def test_event_posts_basic_auth_and_trimmed_json
    server = TCPServer.new("127.0.0.1", 0)
    seen = Queue.new
    t = Thread.new do
      c = server.accept
      head = []
      while (l = c.gets) && l != "\r\n"
        head << l.strip
      end
      body = c.read(head.find { |h| h =~ /^content-length:/i }.split(":")[1].to_i)
      c.write("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      c.close
      seen << [head, body]
    end
    out, err, status = run_script("run_start", "--bot", "Bot Ops", "--run", "r_1", "--routine", "digest", "--title", "Nightly",
                                  env: { "BOT_OPS_URL" => "http://127.0.0.1:#{server.addr[1]}" })
    assert status.success?
    assert_equal ["", ""], [out, err]
    head, body = seen.pop(timeout: 5)
    assert_equal "POST /v1/bot-event HTTP/1.1", head.first
    assert_includes head, "Authorization: Basic #{['botops:' + TOKEN].pack('m0')}"
    assert head.any? { |h| h.downcase.start_with?("ngrok-skip-browser-warning:") }
    ev = JSON.parse(body)
    assert_equal %w[at bot bot_event routine run_id title], ev.keys.sort
    assert_equal ["Bot Ops", "run_start", "r_1", "digest", "Nightly"], ev.values_at("bot", "bot_event", "run_id", "routine", "title")
    assert_in_delta Time.now.to_f, ev["at"], 10
  ensure
    t&.kill
    server&.close
  end

  def test_token_can_come_from_a_file
    File.write(File.join(@home, "tok"), TOKEN + "\n")
    _, _, status = run_script("heartbeat", "--bot", "B", "--run", "r_2", env: { "BOT_OPS_TOKEN" => "", "BOT_OPS_TOKEN_FILE" => File.join(@home, "tok") })
    assert status.success?
    assert_equal "heartbeat", @got.pop(timeout: 5)["bot_event"]
    FileUtils.mkdir_p(File.join(@home, ".config", "bot-ops-blue"))
    File.write(File.join(@home, ".config", "bot-ops-blue", "bot-token"), TOKEN)
    run_script("task", "--bot", "B", "--run", "r_2", "--task", "fetch", "--detail", "x", env: { "BOT_OPS_TOKEN" => "" })
    assert_equal ["task", "fetch", "x"], @got.pop(timeout: 5).values_at("bot_event", "task", "detail")
  end

  def test_silent_and_exit_zero_without_configuration
    out, err, status = run_script("run_end", "--bot", "B", "--run", "r_3", env: { "BOT_OPS_URL" => "" })
    assert status.success?
    assert_equal ["", ""], [out, err]
    out, _, status = run_script("run_end", "--bot", "B", "--run", "r_3", env: { "BOT_OPS_TOKEN" => "" })
    assert status.success?
    assert_equal "", out
    assert_nil @got.pop(timeout: 0.5), "nothing sent"
    out, err, status = run_script("bogus", "--bot", "B")
    assert status.success?, "a usage error still exits 0"
    assert_equal "", out
    refute_equal "", err, "but says so on stderr"
    # Without configuration, wrap still runs the command.
    out, _, status = run_script("wrap", "--bot", "B", "--routine", "r", "--", "sh", "-c", "echo ran; exit 4", env: { "BOT_OPS_URL" => "" })
    assert_equal [4, "ran\n"], [status.exitstatus, out]
  end

  def test_wrap_sends_start_heartbeat_and_end_and_keeps_exit_code
    out, err, status = run_script("wrap", "--bot", "Bot Ops", "--routine", "digest", "--team", "ops", "--", "sh", "-c", "echo working; sleep 0.5; echo done")
    assert status.success?
    assert_equal ["working\ndone\n", ""], [out, err]
    evs = events(10).sort_by { |e| e["at"] }
    assert_equal "run_start", evs.first["bot_event"]
    assert_equal ["Bot Ops", "digest", "ops"], evs.first.values_at("bot", "routine", "team")
    assert_match(/\Ar_\h{12}\z/, evs.first["run_id"])
    assert_equal 1, evs.map { |e| e["run_id"] }.uniq.size
    assert_operator evs.count { |e| e["bot_event"] == "heartbeat" }, :>=, 1
    assert_equal ["run_end", "done"], evs.last.values_at("bot_event", "result")
  end

  def test_wrap_reports_run_error_on_failure
    out, err, status = run_script("wrap", "--bot", "B", "--routine", "r", "--", "sh", "-c", "echo boom >&2; exit 3")
    assert_equal 3, status.exitstatus
    assert_equal ["", "boom\n"], [out, err]
    evs = events(2).sort_by { |e| e["at"] }
    assert_equal %w[run_start run_error], evs.map { |e| e["bot_event"] }
    assert_equal "boom", evs.last["error"]

    run_script("wrap", "--bot", "B", "--routine", "r", "--", "sh", "-c", "exit 5")
    assert_equal "exit 5", events(2).find { |e| e["bot_event"] == "run_error" }["error"]
  end

  def test_failed_posts_are_spooled_and_flushed_later
    dead = TCPServer.new("127.0.0.1", 0)
    port = dead.addr[1]
    dead.close
    _, _, status = run_script("run_start", "--bot", "B", "--run", "r_9", "--routine", "digest", env: { "BOT_OPS_URL" => "http://127.0.0.1:#{port}" })
    assert status.success?
    spool = File.join(@home, ".cache", "bot-ops-blue", "bot-spool.jsonl")
    assert File.exist?(spool)
    assert_equal "600", File.stat(spool).mode.to_s(8)[-3..]
    File.open(spool, "a") { |f| f.puts JSON.generate("bot" => "B", "bot_event" => "heartbeat", "run_id" => "r_9", "at" => Time.now.to_f - 25 * 3600) }
    assert_equal 2, File.readlines(spool).size

    run_script("run_end", "--bot", "B", "--run", "r_9", "--result", "ok")
    evs = 2.times.map { @got.pop(timeout: 5) }
    assert_equal %w[run_end run_start], evs.map { |e| e["bot_event"] }.sort, "the live event, then the spooled one as a batch"
    assert_nil @got.pop(timeout: 0.5), "the day-old spool entry is dropped"
    assert_equal "", File.read(spool), "flushed"
  end
end
