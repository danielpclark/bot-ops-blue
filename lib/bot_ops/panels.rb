# frozen_string_literal: true

module BotOps
  # Bodies of each dashboard panel. Every method receives the body width and
  # height so the same drawing can be reused on the full-size sub pages.
  # Coordinates are relative to the panel body (see Widgets#panel).
  #
  # Everything shown comes from the Store, which is filled from real Claude
  # Code sessions (see Probe). Panels show an empty state instead of filler.
  module Panels
    include Theme

    PALETTE = [CYAN, TEAL, YELLOW, BLUE, PURPLE, PINK, GREEN, ORANGE].freeze
    ENTRY_GLYPHS = { "cli" => "›", "claude-vscode" => "◇", "claude-desktop" => "▣", "sdk-cli" => "⚙", "sdk-ts" => "⚙", "sdk-py" => "⚙" }.freeze

    # Stable colour per project, so a repo keeps its colour across panels.
    def project_color(name)
      PALETTE[name.to_s.sum % PALETTE.size]
    end

    def project_of(s)
      File.basename(s["cwd"].to_s)
    end

    ENTRY_NAMES = { "cli" => "CLI", "claude-vscode" => "VS Code", "claude-desktop" => "Desktop",
                    "sdk-cli" => "SDK", "sdk-ts" => "SDK", "sdk-py" => "SDK" }.freeze

    def entry_name(s)
      ENTRY_NAMES[s["entrypoint"]] || s["entrypoint"] || s["kind"]
    end

    def entry_glyph(s)
      ENTRY_GLYPHS[s["entrypoint"]] || (s["kind"] == "background" ? "◌" : "✦")
    end

    def status_label(s)
      s["attention"] ? "Needs you" : s["status"].to_s.capitalize
    end

    def empty_state(text, y = 12)
      txt(text, 16, y, size: 10, color: MUTED)
    end

    # ---- Sessions ------------------------------------------------------

    def draw_sessions_body(w, h)
      list = @store.all_sessions
      if list.empty?
        return empty_state(@store.machines.empty? ? "Reading Claude Code sessions…" : "No Claude Code sessions in the last 12 hours.")
      end
      row_h = 44
      sel = @store.selected_session
      list.first((h - 4) / row_h).each_with_index { |s, i| session_row(s, 2 + i * row_h, w, row_h, sel) }
    end

    def session_row(s, y, w, row_h, sel)
      ended = s["status"] == "ended"
      mid = (w * 0.52).round
      if sel && s["id"] == sel["id"]
        @c.rect(6, y + 1, w - 12, row_h - 3, curve: 6, fill: col(CYAN, 0.05), stroke: col(EDGE))
      else
        hline(12, w - 12, y + row_h - 1, col(CYAN, 0.07))
      end
      color = ended ? DIM : project_color(project_of(s))
      avatar(14, y + 7, color, entry_glyph(s), 30)
      txt(clip(Store.display_name(s), (mid - 70) / 6), 56, y + 5, size: 10, color: ended ? MUTED : TEXT, weight: :bold)
      sub = [project_of(s), entry_name(s), (s["name"] unless ended || s["name"] == Store.display_name(s))]
      txt(clip(sub.compact.join(" · "), (mid - 70) / 5.5),
          56, y + 21, size: 9, color: ended ? DIM : MUTED)
      status_pill(mid, y + 6, status_label(s))
      txt(Store.model_name(s["model"]), mid, y + 22, size: 9, color: ended ? DIM : MUTED)
      txt("#{s['tool_calls'].to_i} tools", w - 100, y + 5, size: 9, color: ended ? MUTED : TEXT, width: 88, align: :right)
      # When you last prompted it, which is what the list is sorted by.
      txt(Store.ago(Store.worked_at(s)), w - 100, y + 21, size: 9, color: MUTED, width: 88, align: :right)
      @c.hit(4, y, w - 8, row_h) { select_session(s["id"]) }
    end

    # ---- Live activity -------------------------------------------------

    ACTIVITY_TABS = [[:all, "All"], [:busy, "Busy"], [:idle, "Idle"]].freeze

    def draw_live_body(w, h)
      tx = 14
      ACTIVITY_TABS.each do |key, text|
        tw = tab(tx, 4, text, @store.activity_tab == key) { set_activity_tab(key) }
        tx += tw + 6
      end

      row_h = 44
      top = 32
      items = @store.visible_sessions
      return empty_state("Nothing here right now.", top + 12) if items.empty?
      rows = [(h - top) / row_h, items.size].min
      tool_x = (w * 0.47).round
      items.first(rows).each_with_index do |s, i|
        y = top + i * row_h
        color = project_color(project_of(s))
        box(10, y, w - 20, row_h - 6, fill: col(PANEL2), stroke: s["status"] == "busy" ? col(color, 0.7) : col(EDGE_SOFT, 0.8), curve: 6)
        avatar(18, y + 4, color, entry_glyph(s), 30)
        txt(clip(Store.display_name(s), (tool_x - 70) / 6.5), 58, y + 3, size: 10, color: TEXT, weight: :bold)
        sub = [project_of(s), entry_name(s), (s["name"] unless s["name"] == Store.display_name(s))]
        txt(clip(s["attention"] || sub.compact.join(" · "), (tool_x - 70) / 5.5), 58, y + 19, size: 9,
            color: s["attention"] ? YELLOW : MUTED)
        if (t = s["last_tool"])
          txt(t["name"].to_s, tool_x, y + 3, size: 9, color: color, weight: :bold)
          txt(clip(t["detail"], (w - 180 - tool_x) / 5.5), tool_x, y + 19, size: 9, color: MUTED, mono: true)
        end
        txt(Store.ago(s["last_at"] || s["status_at"]), w - 170, y + 11, size: 9, color: MUTED, width: 70, align: :right)
        status_pill(w - 86, y + 12, status_label(s))
        @c.hit(10, y, w - 20, row_h - 6) { select_session(s["id"]) }
      end
    end

    # ---- Projects ------------------------------------------------------

    def draw_projects_body(w, h)
      list = @store.projects
      return empty_state("No Claude Code activity in the last 24 hours.") if list.empty?
      card_h = 52
      rows = [(h - 6) / (card_h + 6), list.size].min
      max_tok = [list.map { |p| p["out_tokens"].to_i }.max, 1].max
      list.first(rows).each_with_index do |p, i|
        y = 4 + i * (card_h + 6)
        name = File.basename(p["cwd"].to_s)
        color = project_color(name)
        box(10, y, w - 20, card_h, fill: col(PANEL2), stroke: col(color, 0.25), curve: 7)
        square_icon(18, y + 11, color, name[0].to_s.upcase, 30)
        txt(clip(name, (w - 200) / 6.5), 58, y + 9, size: 10, color: TEXT, weight: :bold)
        txt(clip([p["branch"], p["host"]].compact.join(" · "), (w - 200) / 5.5), 58, y + 27, size: 9, color: MUTED)
        txt("#{Store.count(p['out_tokens'])} tok", w - 130, y + 9, size: 9, color: TEXT, width: 108, align: :right)
        txt("#{p['prompts'].to_i} prompts · #{Store.ago(p['last_at'])}", w - 190, y + 25, size: 8, color: MUTED, width: 168, align: :right)
        hbar(w - 108, y + 40, 86, 3, p["out_tokens"].to_i * 100.0 / max_tok, color, no_glow: true)
      end
    end

    # ---- Tool calls ----------------------------------------------------

    TOOL_TABS = [[:all, "All"], [:edits, "Edits"], [:shell, "Shell"], [:errors, "Errors"]].freeze

    def draw_tools_body(w, h)
      tx = 14
      counts = @store.tool_counts
      TOOL_TABS.each do |key, text|
        color = { all: TEAL, edits: YELLOW, shell: CYAN, errors: RED }[key]
        tw = tab(tx, 4, "#{text} (#{Store.count(counts[key])})", @store.tool_filter == key, color: color) { set_tool_filter(key) }
        tx += tw + 6
      end
      k = [w / 466.0, 1].max
      cx = [14, 54, 150, 222].map { |x| (x * k).round }
      %w[TIME SESSION TOOL DETAIL].each_with_index { |name, i| label(name, cx[i], 34, size: 8, color: DIM, weight: :bold) }
      hline(10, w - 10, 48, col(CYAN, 0.12))

      row_h = 22
      top = 52
      items = @store.visible_tools
      return empty_state("No tool calls in the last 24 hours.", top + 8) if items.empty?
      rows = [(h - top) / row_h, items.size].min
      items.first(rows).each_with_index do |e, i|
        y = top + i * row_h
        hline(10, w - 10, y + row_h - 1, col(CYAN, 0.05))
        err = e["kind"] == "error"
        txt(Time.at(e["at"]).strftime("%H:%M"), cx[0], y + 3, size: 9, color: MUTED, mono: true)
        txt(clip(e["session"], (cx[2] - cx[1]) / 6), cx[1], y + 3, size: 9, color: TEXT)
        dot(cx[2], y + 8, col(err ? RED : project_color(e["project"])), 5)
        txt(err ? "error" : e["title"], cx[2] + 9, y + 3, size: 9, color: err ? RED : TEXT)
        txt(clip(e["detail"], (w - cx[3] - 12) / 5.6), cx[3], y + 3, size: 9, color: err ? RED : MUTED, mono: true)
      end
    end

    # ---- Usage ---------------------------------------------------------

    def draw_usage_body(w, h)
      t = @store.totals
      tiles = [["Prompts", t[:prompts], "›"], ["Tool calls", t[:tool_calls], "⚙"],
               ["Output tokens", t[:out_tokens], "✦"], ["Tool errors", t[:errors], "!"]]
      bw = [(w - 32 - 3 * 24) / 4, 100].max
      gap = (w - 32 - tiles.size * bw) / (tiles.size - 1)
      tiles.each_with_index do |(name, value, glyph), i|
        x = 16 + i * (bw + gap)
        c = name == "Tool errors" && value.positive? ? RED : CYAN
        @c.rect(x, 6, bw, 56, curve: 8, fill: col(PANEL2), stroke: col(c, 0.55))
        square_icon(x + 8, 16, c, glyph, 26)
        txt(name, x + 42, 13, size: 9, color: c, weight: :bold)
        txt(Store.count(value), x + 42, 30, size: 13, color: TEXT, weight: :bold)
      end

      rows = @store.hourly(12)
      labels = rows.map { |r| Time.at(r[0]).strftime("%H:00") }
      series = [
        { name: "Tool calls / h",  color: TEAL,   values: rows.map { |r| r[2] } },
        { name: "Output k-tok / h", color: BLUE,  values: rows.map { |r| (r[1] / 1000.0).round(1) } },
        { name: "Prompts / h",     color: PURPLE, values: rows.map { |r| r[3] } },
        { name: "Errors / h",      color: RED,    values: rows.map { |r| r[4] } }
      ]
      peak = series.flat_map { |s| s[:values] }.max.to_f
      max = nice_ceiling(peak)
      chart_w = w - 130
      shown = labels.each_with_index.map { |l, i| i.even? || i == labels.size - 1 ? l : "" }
      line_chart(12, 76, chart_w, h - 84, shown, series, max: max)
      txt("Last 12 hours, all machines", chart_w + 22, 76, size: 8, color: DIM, width: 110)
      legend(chart_w + 22, 100, series)
    end

    def nice_ceiling(v)
      return 6 if v <= 6
      mag = 10**Math.log10(v).floor
      [1, 1.5, 2, 3, 5, 6, 10].map { |m| m * mag }.find { |c| c >= v }.ceil
    end

    # ---- System health -------------------------------------------------

    def health_machine
      host = @store.selected_session&.dig("host")
      @store.machines.find { |m| m["host"] == host } || @store.local_machine
    end

    def draw_health_body(w, h)
      m = health_machine
      return empty_state("Waiting for the first probe…") unless m
      hl = m["health"]
      load_pct = hl["load"] && hl["cpus"].to_i.positive? ? hl["load"] * 100.0 / hl["cpus"] : 0
      host_sessions = @store.sessions.select { |s| s["host"] == m["host"] }
      busy_pct = host_sessions.empty? ? 0 : host_sessions.count { |s| s["status"] == "busy" } * 100.0 / host_sessions.size
      gauges = [[load_pct, "Load", CYAN], [hl["mem_pct"], "Memory", TEAL], [hl["disk_pct"], "Disk", CYAN], [busy_pct, "Busy", TEAL]]
      slot_w = w / gauges.size
      gauges.each_with_index do |(pct, name, color), i|
        donut(slot_w * i + slot_w / 2, 46, 34, pct.to_f, pct.to_f > 90 ? RED : color, label: name)
      end
      metrics = [
        ["▤", "Uptime",      hl["uptime_s"] ? uptime_text(hl["uptime_s"]) : "—"],
        ["☀", "Load avg",    hl["load"] ? format("%.2f / %d", hl["load"], hl["cpus"].to_i) : "—"],
        ["◷", "Last report", Store.ago(m["seen_at"])]
      ]
      mw = (w - 32) / metrics.size
      metrics.each_with_index do |(glyph, name, value), i|
        x = 14 + i * mw
        box(x, 118, mw - 6, [h - 126, 60].min, fill: col(PANEL2), curve: 7)
        txt(glyph, x + 12, 128, size: 11, color: TEAL)
        txt(name, x + 30, 128, size: 9, color: MUTED)
        txt(value, x + 12, 148, size: 13, color: TEXT, weight: :bold)
      end
    end

    def uptime_text(secs)
      d = secs / 86_400
      hh = (secs % 86_400) / 3600
      "#{d}d #{hh}h"
    end

    # ---- Recent prompts ------------------------------------------------

    def draw_prompts_body(w, h)
      list = @store.prompts
      return empty_state("No prompts in the last 24 hours.") if list.empty?
      row_h = 27
      rows = [(h - 4) / row_h, list.size].min
      name_w = [(w * 0.3).round, 150].min
      list.first(rows).each_with_index do |e, i|
        y = 2 + i * row_h
        color = project_color(e["project"])
        avatar(14, y + 3, color, "›", 20)
        txt(clip(e["session"], name_w / 6.5), 42, y + 5, size: 9, color: TEXT, weight: :bold)
        txt(clip(e["detail"], (w - name_w - 130) / 5.5), 48 + name_w, y + 5, size: 9, color: TEXT)
        txt(Store.ago(e["at"]), w - 76, y + 5, size: 9, color: MUTED, width: 64, align: :right)
      end
    end

    # ---- Session details -----------------------------------------------

    def draw_detail_body(w, h)
      s = @store.selected_session
      return empty_state("Select a session to see its details.") unless s
      color = project_color(project_of(s))
      avatar(16, 6, color, entry_glyph(s), 44)
      txt(clip(Store.display_name(s), (w - 100) / 7), 72, 6, size: 11, color: TEXT, weight: :bold)
      status_pill(72, 25, status_label(s))
      txt(clip([s["host"], entry_name(s), s["version"] && "v#{s['version']}"].compact.join(" · "), (w - 100) / 5.5),
          72, 38, size: 9, color: MUTED)

      col_w = ((w - 32) * 0.55).to_i
      box(12, 60, col_w, [h - 68, 100].min, fill: col(PANEL2), curve: 7)
      label("Last prompt", 22, 68, size: 9, color: MUTED)
      txt(clip(s["last_prompt"] || "—", (col_w - 20) / 5.5), 22, 82, size: 9, color: TEXT)
      t = s["last_tool"]
      txt(clip(t ? "#{t['name']}: #{t['detail']}" : "No tool calls yet", (col_w - 20) / 5.5), 22, 98, size: 9, color: color, mono: true)
      if s["status"] == "ended"
        label("Last active", 22, 118, size: 9, color: MUTED)
        txt(Store.ago(s["last_at"]), 80, 118, size: 9, color: TEXT)
      else
        label("Started", 22, 118, size: 9, color: MUTED)
        txt(Store.ago(s["started_at"]), 80, 118, size: 9, color: TEXT)
      end
      label("Model", 22, 136, size: 9, color: MUTED)
      txt(Store.model_name(s["model"]), 80, 136, size: 9, color: TEXT)

      cx = 22 + col_w
      tok = s["tokens"] || {}
      rows = [
        ["Branch",      clip(s["branch"] || "—", (w - cx - 70) / 5.5)],
        ["Context",     s["context"] ? "#{Store.count(s['context'])} tok" : "—"],
        ["Output",      "#{Store.count(tok['out'])} tok"],
        ["Cache read",  "#{Store.count(tok['cache_read'])} tok"],
        ["Tools",       "#{s['tool_calls'].to_i} (#{s['errors'].to_i} err)"],
        ["Prompts",     s["prompts"].to_i.to_s]
      ]
      rows.each_with_index do |(k, v), i|
        label(k, cx, 68 + i * 17, size: 9, color: MUTED)
        txt(v, cx + 64, 68 + i * 17, size: 9, color: k == "Tools" && s["errors"].to_i.positive? ? YELLOW : TEXT)
      end
    end

    # ---- Event log -----------------------------------------------------

    KIND_COLORS = { "prompt" => CYAN, "tool" => TEAL, "error" => RED, "attention" => YELLOW, "lifecycle" => MUTED }.freeze

    def draw_log_body(w, h)
      list = @store.events
      return empty_state("No events in the last 24 hours.") if list.empty?
      row_h = 19
      rows = [(h - 6) / row_h, list.size].min
      list.first(rows).each_with_index do |e, i|
        y = 4 + i * row_h
        txt(Time.at(e["at"]).strftime("%H:%M"), 14, y, size: 9, color: MUTED, mono: true)
        kind = %w[tool lifecycle].include?(e["kind"]) ? e["title"].to_s : e["kind"].to_s
        txt(clip(kind, 14), 54, y, size: 9, color: KIND_COLORS[e["kind"]] || MUTED, mono: true)
        txt(clip("#{e['session']}: #{e['detail']}", (w - 160) / 5.6), 148, y, size: 9, color: TEXT)
      end
    end

    # ---- Machines ------------------------------------------------------

    def draw_machines_body(w, h)
      list = @store.machines
      return empty_state("Waiting for the first probe…") if list.empty?
      row_h = 33
      rows = [(h - 4) / row_h, list.size].min
      list.first(rows).each_with_index do |m, i|
        y = 2 + i * row_h
        c = m["online"] ? GREEN : RED
        square_icon(14, y + 3, c, m["local"] ? "⌂" : "◈", 24)
        txt(clip(m["host"], (w - 120) / 6.5), 48, y + 2, size: 9, color: TEXT, weight: :bold)
        os = m["health"]["os"]
        txt([("#{m['sessions']} sessions" if m["online"]), os, (m["online"] ? nil : "last seen #{Store.ago(m['seen_at'])}")].compact.join(" · "),
            48, y + 17, size: 8, color: MUTED)
        txt(m["online"] ? "online" : "offline", w - 70, y + 2, size: 8, color: c, width: 58, align: :right)
      end
    end

    # ---- Settings ------------------------------------------------------

    def draw_settings_body(w, _h)
      rows = [
        ["Window",        "Borderless, laid out at #{@width}x#{@height}"],
        ["Toolkit",       @host.toolkit_name],
        ["Data source",   @host.channel_name],
        ["Machines",      @store.collector_status],
        ["Probe",         @store.probe_error || "OK"],
        ["Hooks",         @store.hooks_installed? ? "Installed (permission prompts, start/end, finished turns)" : "Not installed (optional, see README: Hooks)"],
        ["Refresh",       "every #{Scene::REFRESH_SECONDS}s"],
        ["Ruby",          "#{RUBY_VERSION} (#{RUBY_PLATFORM})"]
      ]
      rows.each_with_index do |(k, v), i|
        y = 10 + i * 24
        label(k, 16, y, size: 9, color: MUTED)
        txt(clip(v, (w - 170) / 5.5), 150, y, size: 9, color: k == "Probe" && @store.probe_error ? RED : TEXT)
      end
      y = 10 + rows.size * 24 + 10
      txt("Window", 16, y, size: 9, color: MUTED)
      link("[ Toggle title bar ]", 150, y) { @host.toggle_decorations }
      link("[ Toggle fullscreen ]", 300, y) { @host.toggle_fullscreen }
      link("[ Quit ]", 460, y, color: RED) { @host.quit }
      txt("Drag the header bar to move the window. Esc leaves fullscreen; F11 or Ctrl+Cmd+F toggles it.",
          16, y + 28, size: 9, color: DIM, width: w - 32)
      y += 64
      txt("Add another machine", 16, y, size: 9, color: MUTED)
      txt("1. Here: start the dashboard with BOT_OPS_LISTEN=0.0.0.0:47800 and a BOT_OPS_TOKEN of 16+ characters.",
          150, y, size: 9, color: TEXT, width: w - 170)
      txt("2. There: BOT_OPS_COLLECTOR=http://<this machine>:47800 BOT_OPS_TOKEN=<same> bin/bot-ops-agent",
          150, y + 18, size: 9, color: TEXT, width: w - 170, mono: true)
    end
  end
end
