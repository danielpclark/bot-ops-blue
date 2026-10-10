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

    attr_accessor :page, :activity_tab, :tool_filter, :selected_session_id
    attr_reader :collector_status, :probe_error, :version

    def initialize
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

    # Live sessions on every online machine: busy first, then most recent.
    def sessions(now = Time.now)
      cached(:sessions) do
        online = online_machines(now).map { |m| m["host"] }
        list = online.flat_map do |host|
          Array(@machines[host]["snapshot"]["sessions"]).map { |s| s.merge("host" => host) }
        end
        list.sort_by { |s| [s["attention"] ? 0 : (s["status"] == "busy" ? 1 : 2), -(s["last_at"] || s["status_at"]).to_f] }
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

    # Live sessions first, then recent ones.
    def all_sessions
      sessions + recent_sessions
    end

    def session(id)
      all_sessions.find { |s| s["id"] == id }
    end

    def selected_session
      session(@selected_session_id) || sessions.first
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
        all_sessions.each { |s| names[s["id"]] = s["name"] }
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

    def visible_tools
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

    # Last +hours+ hourly buckets summed over all machines:
    # [[hour_epoch, out_tokens, tool_calls, prompts, errors], ...] oldest first.
    def hourly(hours = 24)
      cached([:hourly, hours]) do
        sums = Hash.new { |h, k| h[k] = [0, 0, 0, 0] }
        @machines.each_value do |m|
          Array(m["snapshot"]["hourly"]).each do |hour, *vals|
            vals.each_with_index { |v, i| sums[hour][i] += v.to_i }
          end
        end
        last = sums.keys.max || (Time.now.to_i / 3600) * 3600
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
        Stat.new("LIVE SESSIONS",   sessions.size.to_s, "+#{recent_sessions.size} earlier", Theme::MUTED),
        if attention_count.positive?
          Stat.new("BUSY NOW", busy_count.to_s, "#{attention_count} need you", Theme::YELLOW)
        else
          Stat.new("BUSY NOW", busy_count.to_s, "#{sessions.size - busy_count} idle", Theme::MUTED)
        end,
        Stat.new("PROMPTS (24H)",   Store.count(t[:prompts]), "#{projects.size} projects", Theme::MUTED),
        Stat.new("TOOL CALLS (24H)", Store.count(t[:tool_calls]), "#{t[:errors]} errors", t[:errors].positive? ? Theme::RED : Theme::MUTED),
        Stat.new("OUTPUT TOKENS",   Store.count(t[:out_tokens]), "24h", Theme::MUTED)
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

    # 950, 12.4k, 3.1M
    def self.count(n)
      n = n.to_i
      return n.to_s if n < 1000
      return format("%.1fk", n / 1000.0).sub(".0k", "k") if n < 1_000_000
      format("%.1fM", n / 1_000_000.0).sub(".0M", "M")
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
