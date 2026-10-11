# frozen_string_literal: true

module BotOps
  Stat = Struct.new(:label, :value, :note, :note_color)

  # The single source of truth for everything the dashboard draws.
  #
  # The UI never mutates the data directly. Comms channels produce event
  # hashes which are fed to Store#apply; the important one is
  #
  #   { type: "snapshot", snapshot: <Probe#snapshot>, local: true/false }
  #
  # which replaces everything known about one machine account. Sources are
  # keyed "user@host", so two accounts on one Mac (each running the probe or
  # bin/bot-ops-agent as itself) show up side by side instead of colliding. Machines that stop
  # reporting are marked offline after OFFLINE_AFTER_S and their sessions
  # drop out of the live views (their history stays in the usage numbers).
  class Store
    OFFLINE_AFTER_S = 15
    TOOL_GROUPS = {
      edits: %w[Edit Write MultiEdit NotebookEdit],
      shell: %w[Bash BashOutput KillShell Monitor]
    }.freeze

    attr_accessor :page, :activity_tab, :tool_filter, :selected_session_id, :overlay, :session_only
    attr_reader :collector_status, :probe_error, :version

    # history: a History to record usage into (charts beyond 24h); prefs: a
    # Prefs (or any Hash-like) for chart range, hidden series, notifications.
    def initialize(history: nil, prefs: nil)
      @history = history
      @prefs = prefs || Prefs::DEFAULTS.dup
      @machines = {}
      @page = :overview
      @activity_tab = :all
      @tool_filter = :all
      @collector_status = "Starting…"
      @probe_error = nil
      @version = 0
      @cache = {}
    end

    # ---- event ingestion -------------------------------------------------

    def apply(event)
      type = (event[:type] || event["type"]).to_s
      ev = event.each_with_object({}) { |(k, v), o| o[k.to_sym] = v }
      case type
      when "snapshot"
        snap = ev[:snapshot]
        return self unless snap.is_a?(Hash) && snap["host"].is_a?(String)
        key = snap["user"].is_a?(String) && !snap["user"].empty? ? "#{snap['user']}@#{snap['host']}" : snap["host"]
        @machines[key] = { "snapshot" => snap, "received_at" => ev[:at] || Time.now, "local" => ev[:local] ? true : false }
        @history&.record(key, Store.usage_rows(snap))
        @probe_error = nil if ev[:local]
      when "collector" then @collector_status = ev[:status].to_s
      when "probe.error" then @probe_error = ev[:message].to_s
      else return self
      end
      @version += 1
      @cache = {}
      self
    end

    def apply_all(events)
      Array(events).each { |e| apply(e) }
    end

    # ---- machines ----------------------------------------------------------

    def machines(now = Time.now)
      cached(:machines) do
        @machines.map do |host, m|
          snap = m["snapshot"]
          {
            "host" => host,
            "local" => m["local"],
            "online" => now - m["received_at"] < OFFLINE_AFTER_S,
            "seen_at" => m["received_at"],
            "health" => snap["machine"] || {},
            "sessions" => Array(snap["sessions"]).size
          }
        end.sort_by { |m| [m["local"] ? 0 : 1, m["host"]] }
      end
    end

    def online_machines(now = Time.now)
      machines(now).select { |m| m["online"] }
    end

    def local_machine
      machines.find { |m| m["local"] }
    end

    # ---- sessions ----------------------------------------------------------

    # Live sessions on every online machine, most recent activity first.
    def sessions(now = Time.now)
      cached(:sessions) do
        online = online_machines(now).map { |m| m["host"] }
        list = online.flat_map do |host|
          Array(@machines[host]["snapshot"]["sessions"]).map { |s| s.merge("host" => host) }
        end
        Store.by_recency(list)
      end
    end

    # Sessions from the last 12h whose process has exited (earlier VS Code
    # conversations, finished CLI runs), from every online machine.
    def recent_sessions(now = Time.now)
      cached(:recent) do
        online_machines(now).flat_map do |m|
          Array(@machines[m["host"]]["snapshot"]["recent"]).map { |s| s.merge("host" => m["host"]) }
        end.sort_by { |s| -s["last_at"].to_f }
      end
    end

    # Live and earlier sessions in one list, ordered like Recent Prompts: the
    # session you last prompted is on top (a busy session's own tool calls
    # don't keep it there), except that a session waiting on you comes first.
    def all_sessions
      cached(:all_sessions) { Store.by_recency(sessions + recent_sessions) }
    end

    def self.by_recency(list)
      list.sort_by { |s| [s["attention"] ? 0 : 1, -worked_at(s).to_f] }
    end

    # When you last worked with a session: its last prompt, else its last activity.
    def self.worked_at(s)
      s["prompt_at"] || s["last_at"] || s["status_at"]
    end

    # What a session is working on (its AI title), else its process nickname.
    def self.display_name(s)
      t = s["title"].to_s.strip
      t.empty? ? s["name"].to_s : t
    end

    def session(id)
      all_sessions.find { |s| s["id"] == id }
    end

    def selected_session
      session(@selected_session_id) || all_sessions.first
    end

    def visible_sessions
      case @activity_tab
      when :busy then sessions.select { |s| s["status"] == "busy" }
      when :idle then sessions.reject { |s| s["status"] == "busy" }
      else sessions
      end
    end

    def busy_count
      sessions.count { |s| s["status"] == "busy" }
    end

    # Sessions blocked on a permission prompt (needs bin/bot-ops-hook).
    def attention_count
      sessions.count { |s| s["attention"] }
    end

    def hooks_installed?
      @machines.values.any? { |m| m["snapshot"]["hooks"] }
    end

    # ---- events ------------------------------------------------------------

    # Prompts, tool calls and tool errors from every machine, newest first.
    def events
      cached(:events) do
        names = {}
        all_sessions.each { |s| names[s["id"]] = Store.display_name(s) }
        @machines.flat_map do |host, m|
          Array(m["snapshot"]["events"]).map do |e|
            e.merge("host" => host, "session" => names[e["sid"]] || e["project"] || e["sid"].to_s[0, 8])
          end
        end.sort_by { |e| -e["at"].to_f }
      end
    end

    def prompts
      events.select { |e| e["kind"] == "prompt" }
    end

    def tool_events
      events.select { |e| e["kind"] == "tool" || e["kind"] == "error" }
    end

    # Events every term of `query` appears in (case-insensitive), newest first.
    def search(query, limit = 200)
      terms = query.to_s.downcase.split
      return [] if terms.empty?
      events.select do |e|
        haystack = [e["title"], e["detail"], e["full"], e["session"], e["project"], e["kind"]].join(" ").downcase
        terms.all? { |t| haystack.include?(t) }
      end.first(limit)
    end

    # Events for the Event Log: everything, or only the selected session's.
    def visible_events
      @session_only && selected_session ? events.select { |e| e["sid"] == selected_session["id"] } : events
    end

    def visible_tools
      return visible_tools_unscoped unless @session_only && selected_session
      visible_tools_unscoped.select { |e| e["sid"] == selected_session["id"] }
    end

    def visible_tools_unscoped
      case @tool_filter
      when :errors then tool_events.select { |e| e["kind"] == "error" }
      when :edits, :shell then tool_events.select { |e| TOOL_GROUPS[@tool_filter].include?(e["title"]) }
      else tool_events
      end
    end

    def tool_counts
      cached(:tool_counts) do
        t = tool_events
        { all: t.size, edits: t.count { |e| TOOL_GROUPS[:edits].include?(e["title"]) },
          shell: t.count { |e| TOOL_GROUPS[:shell].include?(e["title"]) }, errors: t.count { |e| e["kind"] == "error" } }
      end
    end

    # ---- usage -------------------------------------------------------------

    # A snapshot's usage rows: [hour, project, model, client, out, in,
    # cache_read, cache_write, tools, prompts, errors]. Agents from before the
    # client column are padded; snapshots without usage are read from their
    # 24h "hourly" table.
    def self.usage_rows(snap)
      if snap["usage"].is_a?(Array)
        return snap["usage"].map { |r| r.size == 10 ? r.dup.insert(3, "") : r }
      end
      Array(snap["hourly"]).map { |hour, out, tools, prompts, errors| [hour, "", "", "", out.to_i, 0, 0, 0, tools.to_i, prompts.to_i, errors.to_i] }
    end

    # Positions in a usage row as Store#usage returns it (source first).
    U = %i[source hour project model client out in cache_read cache_write tools prompts errors]
        .each_with_index.to_h.freeze

    def self.current_hour(now = Time.now)
      (now.to_i / 3600) * 3600
    end

    # [[source, hour, project, model, client, out, in, cache_read,
    # cache_write, tools, prompts, errors], ...] for the last `hours` hours,
    # every source.
    def usage(hours = 24)
      cached([:usage, hours]) do
        since = Store.current_hour - (hours - 1) * 3600
        if @history
          @history.rows(since)
        else
          @machines.flat_map do |key, m|
            Store.usage_rows(m["snapshot"]).select { |r| r[0].to_i >= since }.map { |r| [key, *r] }
          end
        end
      end
    end

    # Last +hours+ hourly buckets summed over all sources:
    # [[hour_epoch, out_tokens, tool_calls, prompts, errors], ...] oldest first.
    def hourly(hours = 24)
      cached([:hourly, hours]) do
        sums = Hash.new { |h, k| h[k] = [0, 0, 0, 0] }
        usage(hours).each do |_, hour, _, _, _, out, _, _, _, tools, prompts, errors|
          row = sums[hour]
          row[0] += out
          row[1] += tools
          row[2] += prompts
          row[3] += errors
        end
        last = Store.current_hour
        (0...hours).map { |i| h = last - (hours - 1 - i) * 3600; [h, *sums[h]] }
      end
    end

    def totals
      cached(:totals) do
        rows = hourly(24)
        { out_tokens: rows.sum { |r| r[1] }, tool_calls: rows.sum { |r| r[2] },
          prompts: rows.sum { |r| r[3] }, errors: rows.sum { |r| r[4] } }
      end
    end

    # ---- drill-downs -------------------------------------------------------

    TOKEN_KINDS = %w[out in cache_read cache_write].freeze

    CLIENT_NAMES = { "cli" => "CLI", "claude-vscode" => "VS Code", "cloud" => "claude.ai", "claude-desktop" => "Desktop",
                     "sdk-cli" => "SDK", "sdk-ts" => "SDK", "sdk-py" => "SDK" }.freeze

    def self.client_name(entrypoint)
      CLIENT_NAMES[entrypoint] || (entrypoint.to_s.empty? ? "(unknown)" : entrypoint)
    end

    # Tokens over the last `hours`: totals per kind, and every kind grouped
    # by client, project, model and hour (by day past two days); sessions by
    # their own totals.
    def token_breakdown(hours = 24)
      cached([:tokens, hours]) do
        totals = Hash.new(0)
        by = Hash.new { |h, dim| h[dim] = Hash.new { |g, k| g[k] = Hash.new(0) } }
        step = hours > 48 ? 86_400 : 3600
        usage(hours).each do |_, hour, project, model, client, *counts|
          TOKEN_KINDS.each_with_index do |kind, i|
            n = counts[i].to_i
            next if n.zero?
            totals[kind] += n
            by[:client][Store.client_name(client)][kind] += n
            by[:project][project.empty? ? "(unknown)" : project][kind] += n
            by[:model][model.empty? ? "(unknown)" : model][kind] += n
            by[:period][Time.at(hour).then { |t| step == 3600 ? hour : Time.local(t.year, t.month, t.day).to_i }][kind] += n
          end
        end
        reads = totals["cache_read"]
        prompt_side = totals["in"] + totals["cache_read"] + totals["cache_write"]
        sessions = all_sessions.filter_map do |s|
          t = s["tokens"] || {}
          [Store.display_name(s), t] if t.values.any? { |v| v.to_i.positive? }
        end.sort_by { |_, t| -t["out"].to_i }
        { totals: totals, by_client: by[:client], by_project: by[:project], by_model: by[:model], by_period: by[:period],
          period: step, by_session: sessions,
          cache_hit: prompt_side.positive? ? reads.to_f / prompt_side : nil }
      end
    end

    # Tools that wait for the person rather than run, so their "duration" is
    # thinking time, not slowness.
    WAITS_ON_YOU = %w[AskUserQuestion ExitPlanMode].freeze

    # Per tool over the event window: calls, failures, median and slowest
    # duration (from each call to its result, where known).
    def tool_stats
      cached(:tool_stats) do
        calls = events.select { |e| e["kind"] == "tool" }
        failed = events.select { |e| e["kind"] == "error" && e["tool"] }.map { |e| e["tool"] }.tally
        calls.group_by { |e| e["title"].to_s }.map do |tool, list|
          durations = list.filter_map { |e| e["duration"] }.sort
          { tool: tool, calls: list.size, errors: [failed[tool].to_i, list.count { |e| e["failed"] }].max,
            median: durations.empty? ? nil : durations[durations.size / 2], max: durations.last,
            waits: WAITS_ON_YOU.include?(tool) }
        end.sort_by { |t| -t[:calls] }
      end
    end

    # The slowest tool calls that actually ran (not ones waiting on you).
    def slowest_tools(n = 10)
      events.select { |e| e["kind"] == "tool" && e["duration"] && !WAITS_ON_YOU.include?(e["title"]) }
            .max_by(n) { |e| e["duration"] }
    end

    def prompts_by_project
      cached(:prompts_by_project) { prompts.group_by { |e| e["project"].to_s }.sort_by { |_, l| -l.size } }
    end

    # ---- preferences ---------------------------------------------------------

    CHART_RANGES = { "12h" => 12, "24h" => 24, "7d" => 168, "30d" => 720 }.freeze

    def chart_range
      CHART_RANGES.key?(@prefs["chart_range"]) ? @prefs["chart_range"] : "12h"
    end

    def chart_range=(range)
      return unless CHART_RANGES.key?(range)
      @prefs["chart_range"] = range
      @cache = {}
    end

    def hidden_series
      Array(@prefs["hidden_series"])
    end

    def toggle_series(name)
      @prefs["hidden_series"] = hidden_series.include?(name) ? hidden_series - [name] : hidden_series + [name]
    end

    def notifications?
      @prefs["notifications"] ? true : false
    end

    def notifications=(on)
      @prefs["notifications"] = on ? true : false
    end

    # Projects with activity in the last 24h on any machine, most recent first.
    def projects
      cached(:projects) do
        @machines.flat_map do |host, m|
          Array(m["snapshot"]["projects"]).map { |p| p.merge("host" => host) }
        end.sort_by { |p| -p["last_at"].to_f }
      end
    end

    def stats
      t = totals
      [
        Stat.new("LIVE SESSIONS",   sessions.size.to_s, "+#{recent_sessions.size} earlier", recent_sessions.empty? ? Theme::MUTED : Theme::GREEN),
        if attention_count.positive?
          Stat.new("BUSY NOW", busy_count.to_s, "#{attention_count} need you", Theme::YELLOW)
        else
          Stat.new("BUSY NOW", busy_count.to_s, "#{sessions.size - busy_count} idle", Theme::MUTED)
        end,
        Stat.new("PROMPTS (24H)",   Store.count(t[:prompts]), "#{projects.size} project#{'s' unless projects.size == 1}", Theme::CYAN),
        Stat.new("TOOL CALLS (24H)", Store.count(t[:tool_calls]), "#{t[:errors]} error#{'s' unless t[:errors] == 1}", t[:errors].positive? ? Theme::RED : Theme::MUTED),
        Stat.new("OUTPUT TOKENS",   Store.count(t[:out_tokens]), "24h", Theme::CYAN)
      ]
    end

    # ---- formatting helpers ---------------------------------------------

    def self.ago(time, now = Time.now)
      return "—" unless time
      secs = (now.to_f - time.to_f).to_i
      return "just now" if secs < 60
      mins = secs / 60
      return "#{mins}m ago" if mins < 60
      return "#{mins / 60}h #{mins % 60}m ago" if mins < 24 * 60
      "#{mins / 1440}d ago"
    end

    def self.duration(secs)
      return "—" unless secs
      m = (secs / 60).to_i
      return "#{m}m" if m < 60
      return format("%dh %02dm", m / 60, m % 60) if m < 24 * 60
      format("%dd %dh", m / 1440, (m % 1440) / 60)
    end

    # The context window a session is working against: Claude Haiku 4.5 has
    # 200k, the current models 1M. A context already past the guess means the
    # guess was wrong, so the next size up is used.
    def self.context_window(model, context = 0)
      window = model.to_s.include?("haiku-4") ? 200_000 : 1_000_000
      window = 1_000_000 if context.to_i > window
      window
    end

    # 950, 12.4k, 3.1M
    def self.count(n)
      n = n.to_i
      return n.to_s if n < 1000
      return format("%.1fk", n / 1000.0).sub(".0k", "k") if n < 1_000_000
      return format("%.1fM", n / 1_000_000.0).sub(".0M", "M") if n < 999_950_000
      format("%.1fB", n / 1_000_000_000.0).sub(".0B", "B")
    end

    # "claude-opus-5-5" -> "Opus 5.5"
    def self.model_name(id)
      m = id.to_s.match(/claude-(\w+)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?\z/)
      return id.to_s if m.nil?
      [m[1].capitalize, [m[2], m[3]].compact.join(".")].join(" ")
    end

    private

    def cached(key)
      @cache.fetch(key) { @cache[key] = yield }
    end
  end
end
