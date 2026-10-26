# frozen_string_literal: true

require "json"
require "fileutils"

module BotOps
  # Turns routine-run events from assistant bots (cloud/bot-ops-bot-report.py,
  # POSTed to the Collector's /v1/bot-event) into a "bots" source shaped like
  # a Probe#snapshot, so each scheduled run sits next to Claude sessions on
  # every panel. Runs are sessions; the bot's name stands in for the project.
  #
  # A run starts with run_start, stays live on a heartbeat every minute, and
  # finishes with run_end or run_error. A busy run that goes quiet for
  # STALE_S is marked stale: shown as ended, with one synthetic error.
  #
  # Events are appended to ~/.config/bot-ops-blue/bot-events.jsonl and
  # replayed on start, so bot history survives a dashboard restart. Only the
  # last 24 hours are kept.
  class BotFeed
    HOST = "bots"
    WINDOW_S = 24 * 3600
    STALE_S = 300
    RECENT_S = 12 * 3600
    EVENT_LIMIT = 1000
    RUNS_PER_BOT = 96        # dots in a bot's activity strip
    LOG = File.join(Dir.home, ".config", "bot-ops-blue", "bot-events.jsonl")
    EVENTS = %w[run_start heartbeat task task_error run_end run_error].freeze
    RUN_ID = /\A[A-Za-z0-9_-]{1,128}\z/
    # Lengths each field is cut to. Token and usage fields are ignored.
    LIMITS = { "bot" => 64, "bot_id" => 64, "team" => 64, "routine" => 80, "title" => 120, "task" => 64,
               "detail" => 160, "result" => 300, "error" => 300, "model" => 64 }.freeze
    # The only links the dashboard will open from a run: https:// pages on
    # the hosts named in BOT_OPS_BOT_URL_HOSTS (comma-separated). None by
    # default, so a link in a report is dropped unless a host is allowed.
    RUN_URL = begin
      hosts = ENV["BOT_OPS_BOT_URL_HOSTS"].to_s.split(",").map(&:strip).reject(&:empty?)
      hosts.empty? ? /(?!)/ : %r{\Ahttps://(?:#{hosts.map { |h| Regexp.escape(h) }.join('|')})(?:/\S*)?\z}
    end

    def initialize(log: LOG)
      @log = log
      @mutex = Mutex.new
      @sessions = {}
      @events = []
      @buckets = Hash.new { |h, k| h[k] = [0, 0, 0] } # [bot, hour] => [tools, prompts, errors]
      replay
    end

    def any?
      @mutex.synchronize { !@sessions.empty? }
    end

    # One bot event (string keys). Returns false if it was ignored.
    def ingest(e, persist: true)
      return false unless e.is_a?(Hash) && EVENTS.include?(e["bot_event"])
      return false unless e["bot"].is_a?(String) && !e["bot"].strip.empty?
      return false unless e["run_id"].is_a?(String) && e["run_id"].match?(RUN_ID)
      now = Time.now.to_f
      at = e["at"].is_a?(Numeric) && e["at"] <= now + 60 ? e["at"].to_f : now
      return false if at < now - WINDOW_S
      @mutex.synchronize { apply(e, at) }
      append(e.merge("at" => at)) if persist
      true
    end

    def snapshot(now = Time.now)
      @mutex.synchronize do
        t = now.to_f
        sweep_stale(t)
        @sessions.delete_if { |_, s| s["last_at"] < t - WINDOW_S }
        runs = @sessions.values
        live, ended = runs.partition { |s| s["status"] == "busy" }
        {
          "host" => HOST,
          "at" => t,
          "machine" => { "os" => "bots" },
          "sessions" => live.map(&:dup),
          "recent" => ended.select { |s| s["last_at"] >= t - RECENT_S }.map(&:dup),
          "events" => @events.select { |ev| ev["at"] >= t - WINDOW_S }.sort_by { |ev| -ev["at"] }.first(EVENT_LIMIT),
          "hourly" => hourly(t),
          "usage" => usage,
          "projects" => projects(runs),
          "bots" => bots(t)
        }
      end
    end

    private

    # The event's +key+, cut to its limit, or nil when absent or blank.
    def str(e, key)
      v = e[key]
      return nil unless v.is_a?(String)
      v = v.strip
      v.empty? ? nil : v[0, LIMITS.fetch(key)]
    end

    def apply(e, at)
      rid = e["run_id"]
      bot = str(e, "bot")
      routine = str(e, "routine")
      # A heartbeat or task for a run the dashboard never saw start (it
      # started before the dashboard did) creates the run the same way.
      s = (@sessions[rid] ||= { "id" => rid, "name" => routine || "run #{rid[0, 8]}", "kind" => "bot",
                                "entrypoint" => "bot-routine", "routine" => routine, "bot" => bot, "team" => nil,
                                "cwd" => bot, "status" => "busy", "started_at" => at, "last_at" => at,
                                "tool_calls" => 0, "errors" => 0, "prompts" => 0, "tokens" => {} })
      s["routine"] ||= routine
      s["team"] = str(e, "team") if str(e, "team")
      s["bot_id"] = str(e, "bot_id") if str(e, "bot_id")
      s["model"] = str(e, "model") if str(e, "model")
      s["url"] = e["url"] if e["url"].is_a?(String) && e["url"].match?(RUN_URL)
      s["title"] = str(e, "title") if str(e, "title")
      s["last_at"] = [s["last_at"], at].max
      s["started_at"] = [s["started_at"], at].min
      hour = (at.to_i / 3600) * 3600
      case e["bot_event"]
      when "run_start"
        # A start that arrives after the end (it was spooled) doesn't revive the run.
        s["status"] = "busy" unless s["ended_at"]
        event(s, at, "lifecycle", "run started", s["routine"])
      when "heartbeat"
        nil # last_at is the whole message
      when "task"
        task = str(e, "task").to_s
        s["tool_calls"] += 1
        s["last_tool"] = { "name" => task, "detail" => str(e, "detail").to_s, "at" => at }
        @buckets[[bot, hour]][0] += 1
        event(s, at, "tool", task, str(e, "detail"))
        task_error(s, at, bot, hour, "#{task}: #{str(e, 'error')}") if str(e, "error")
      when "task_error"
        task_error(s, at, bot, hour, [str(e, "task"), str(e, "error")].compact.join(": "))
      when "run_end"
        s["status"] = "ended"
        s["result"] = str(e, "result") if str(e, "result")
        s["ended_at"] = at
        event(s, at, "lifecycle", "run finished", s["result"])
      when "run_error"
        s["status"] = "ended"
        s["errors"] += 1
        s["last_error"] = str(e, "error").to_s
        s["ended_at"] = at
        @buckets[[bot, hour]][2] += 1
        event(s, at, "error", "run failed", s["last_error"])
      end
      s["name"] = s["title"] if s["title"]
    end

    def task_error(s, at, bot, hour, detail)
      s["errors"] += 1
      @buckets[[bot, hour]][2] += 1
      event(s, at, "error", "task error", detail)
    end

    def event(s, at, kind, title, detail)
      @events << { "at" => at, "sid" => s["id"], "project" => s["bot"].to_s, "kind" => kind,
                   "title" => title, "detail" => detail.to_s[0, 160] }
      @events.shift(@events.size - EVENT_LIMIT) if @events.size > EVENT_LIMIT * 2
    end

    # A busy run with no heartbeat for STALE_S has died without saying so:
    # it ends, stale, with one error. Once, since it is no longer busy. Not
    # written to the log; a replay reaches the same state from the events.
    def sweep_stale(t)
      @sessions.each_value do |s|
        next unless s["status"] == "busy" && s["last_at"] < t - STALE_S
        s["status"] = "ended"
        s["stale"] = true
        s["ended_at"] = s["last_at"]
        s["errors"] += 1
        hour = (s["last_at"].to_i / 3600) * 3600
        @buckets[[s["bot"], hour]][2] += 1
        event(s, s["last_at"], "error", "run went silent", "no heartbeat for 5 min")
      end
    end

    # Rows shaped like Probe#snapshot's "usage", client "bot-routine". Bots
    # report no tokens, so those columns stay 0.
    def usage
      @buckets.map { |(bot, hour), (tools, prompts, errors)| [hour, bot.to_s, "", "bot-routine", 0, 0, 0, 0, tools, prompts, errors] }
    end

    def hourly(t)
      first = (t.to_i / 3600) * 3600 - 23 * 3600
      sums = Hash.new { |h, k| h[k] = [0, 0, 0, 0] }
      usage.each do |hour, _, _, _, _, _, _, _, tools, prompts, errors|
        sums[hour] = sums[hour].zip([0, tools, prompts, errors]).map(&:sum)
      end
      (0..23).map { |i| h = first + i * 3600; [h, *sums[h]] }
    end

    # One "project" per bot, so the Projects page groups runs by bot.
    def projects(runs)
      runs.group_by { |s| s["cwd"].to_s }.map do |cwd, list|
        { "cwd" => cwd, "sessions" => list.size, "out_tokens" => 0, "tool_calls" => list.sum { |s| s["tool_calls"] },
          "prompts" => 0, "last_at" => list.map { |s| s["last_at"] }.max, "branch" => nil }
      end
    end

    # How a run turned out, for the activity strip's dots.
    def outcome(s)
      return "working" if s["status"] == "busy"
      return "stale" if s["stale"]
      s["errors"].to_i.positive? ? "error" : "ended"
    end

    # The roster: one entry per bot with its state, its current and last
    # run, and its runs over the last 24 hours (oldest first) for the strip.
    def bots(t)
      @sessions.values.group_by { |s| s["bot"].to_s }.map do |name, runs|
        runs = runs.sort_by { |s| [s["started_at"], s["id"]] }
        current = runs.select { |s| s["status"] == "busy" }.max_by { |s| s["last_at"] }
        last = runs.reject { |s| s["status"] == "busy" }.max_by { |s| [s["ended_at"] || s["last_at"], s["started_at"]] }
        status = if current then "working"
                 elsif last.nil? then "idle"
                 elsif last["stale"] then "stale"
                 elsif last["errors"].to_i.positive? then "error"
                 else "idle"
                 end
        {
          "name" => name,
          "team" => runs.filter_map { |s| s["team"] }.last,
          "status" => status,
          "last_seen" => runs.map { |s| s["last_at"] }.max,
          "current_run" => current && current["id"],
          "last_run" => last && { "id" => last["id"], "routine" => last["routine"], "status" => last["status"],
                                  "stale" => last["stale"] ? true : false, "result" => last["result"],
                                  "error" => last["last_error"], "ended_at" => last["ended_at"] },
          "runs_24h" => runs.size,
          "errors_24h" => runs.sum { |s| s["errors"].to_i },
          "runs" => runs.last(RUNS_PER_BOT).map { |s| [s["started_at"], s["ended_at"], outcome(s)] }
        }
      end
    end

    def append(e)
      FileUtils.mkdir_p(File.dirname(@log))
      File.open(@log, "a", 0o600) { |f| f.puts(JSON.generate(e)) }
    rescue SystemCallError
      nil
    end

    # Rebuild state from the log, and rewrite it without events older than 24h.
    def replay
      return unless File.exist?(@log)
      cutoff = Time.now.to_f - WINDOW_S
      kept = File.readlines(@log).filter_map do |line|
        e = JSON.parse(line) rescue next
        next unless e.is_a?(Hash) && e["at"].to_f >= cutoff
        ingest(e, persist: false) && line
      end
      File.write(@log, kept.join, perm: 0o600)
    rescue SystemCallError
      nil
    end
  end
end
