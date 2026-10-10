# frozen_string_literal: true

require "json"
require "fileutils"

module BotOps
  # Turns hook events from cloud sessions (cloud/bot-ops-report.py, POSTed to
  # the Collector's /v1/event) into a "claude.ai" source shaped like a
  # Probe#snapshot, so cloud sessions sit next to local ones on every panel.
  #
  # Events are appended to ~/.config/bot-ops-blue/cloud-events.jsonl and
  # replayed on start, so cloud history survives a dashboard restart. Only
  # the last 24 hours are kept.
  class CloudFeed
    HOST = "claude.ai"
    WINDOW_S = 24 * 3600
    LIVE_S = 2 * 3600       # quiet longer than this and a session counts as earlier
    RECENT_S = 12 * 3600
    EVENT_LIMIT = 1000
    LOG = File.join(Dir.home, ".config", "bot-ops-blue", "cloud-events.jsonl")

    def initialize(log: LOG)
      @log = log
      @mutex = Mutex.new
      @sessions = {}
      @events = []
      @buckets = Hash.new { |h, k| h[k] = [0, 0, 0, 0] } # hour => [out_tokens, tools, prompts, errors]
      replay
    end

    def any?
      @mutex.synchronize { !@sessions.empty? }
    end

    # One trimmed hook event (string keys). Returns false if it was ignored.
    def ingest(e, persist: true)
      return false unless e.is_a?(Hash) && e["session_id"].is_a?(String) && e["hook_event_name"].is_a?(String)
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
        sessions = @sessions.values.select { |s| s["last_at"] >= t - RECENT_S }
        live, recent = sessions.partition { |s| s["status"] != "ended" && s["last_at"] >= t - LIVE_S }
        {
          "host" => HOST,
          "at" => t,
          "machine" => { "os" => "cloud" },
          "sessions" => live.map(&:dup),
          "recent" => recent.map { |s| s.merge("status" => "ended") },
          "events" => @events.select { |ev| ev["at"] >= t - WINDOW_S }.sort_by { |ev| -ev["at"] }.first(EVENT_LIMIT),
          "hourly" => hourly(t),
          "projects" => projects(sessions)
        }
      end
    end

    private

    def apply(e, at)
      sid = e["session_id"]
      s = (@sessions[sid] ||= { "id" => sid, "name" => "cloud #{sid[0, 6]}", "kind" => "cloud", "entrypoint" => "cloud",
                                "status" => "idle", "started_at" => at, "last_at" => at, "tool_calls" => 0,
                                "errors" => 0, "prompts" => 0, "tokens" => {} })
      s["cwd"] ||= e["cwd"]
      s["branch"] = e["branch"] if e["branch"].is_a?(String) && !e["branch"].empty?
      s["model"] = e["model"] if e["model"].is_a?(String)
      s["last_at"] = [s["last_at"], at].max
      hour = (at.to_i / 3600) * 3600
      case e["hook_event_name"]
      when "UserPromptSubmit"
        text = e["prompt"].to_s.strip
        s["status"] = "busy"
        s["prompts"] += 1
        s["prompt_at"] = [s["prompt_at"].to_f, at].max
        s["last_prompt"] = text.lines.first.to_s.strip[0, 160]
        s["title"] ||= s["last_prompt"][0, 80] unless text.empty?
        @buckets[hour][2] += 1
        event(s, at, "prompt", "prompt", s["last_prompt"])
      when "PostToolUse", "PostToolUseFailure"
        failed = e["error"] || e["hook_event_name"] == "PostToolUseFailure"
        s["status"] = "busy"
        s["tool_calls"] += 1
        s["last_tool"] = { "name" => e["tool_name"].to_s, "detail" => e["detail"].to_s, "at" => at }
        s.delete("attention")
        @buckets[hour][1] += 1
        event(s, at, "tool", e["tool_name"].to_s, e["detail"].to_s)
        if failed
          s["errors"] += 1
          @buckets[hour][3] += 1
          event(s, at, "error", "tool error", "#{e['tool_name']}: #{e['detail']}")
        end
      when "Notification"
        if e["notification_type"] == "permission_prompt" || e["message"].to_s =~ /permission/i
          s["attention"] = e["message"].to_s.empty? ? "Waiting for permission" : e["message"]
          event(s, at, "attention", "needs you", e["message"].to_s)
        end
      when "Stop"
        s["status"] = "idle"
        s.delete("attention")
        event(s, at, "lifecycle", "turn finished", "")
      when "SessionStart"
        event(s, at, "lifecycle", "session started", e["source"].to_s)
      when "SessionEnd"
        s["status"] = "ended"
        s.delete("attention")
        event(s, at, "lifecycle", "session ended", e["reason"].to_s)
      end
      s["name"] = s["title"] if s["title"]
    end

    def event(s, at, kind, title, detail)
      @events << { "at" => at, "sid" => s["id"], "project" => File.basename(s["cwd"].to_s), "kind" => kind,
                   "title" => title, "detail" => detail.to_s[0, 160] }
      @events.shift(@events.size - EVENT_LIMIT) if @events.size > EVENT_LIMIT * 2
    end

    def hourly(t)
      first = (t.to_i / 3600) * 3600 - 23 * 3600
      (0..23).map { |i| h = first + i * 3600; [h, *@buckets[h]] }
    end

    def projects(sessions)
      sessions.group_by { |s| s["cwd"].to_s }.map do |cwd, list|
        { "cwd" => cwd, "sessions" => list.size, "out_tokens" => 0, "tool_calls" => list.sum { |s| s["tool_calls"] },
          "prompts" => list.sum { |s| s["prompts"] }, "last_at" => list.map { |s| s["last_at"] }.max,
          "branch" => list.map { |s| s["branch"] }.compact.first }
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
