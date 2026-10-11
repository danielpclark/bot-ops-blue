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

    PALETTE = [CYAN, TEAL, YELLOW, BLUE, PURPLE, GREEN, ORANGE].freeze
    ENTRY_GLYPHS = { "cloud" => :cloud, "cli" => "›", "claude-vscode" => "◇", "claude-desktop" => "▣", "sdk-cli" => "⚙", "sdk-ts" => "⚙", "sdk-py" => "⚙" }.freeze

    # Stable colour per project, so a repo keeps its colour across panels.
    def project_color(name)
      PALETTE[name.to_s.sum % PALETTE.size]
    end

    def project_of(s)
      File.basename(s["cwd"].to_s)
    end

    ENTRY_NAMES = { "cloud" => "Cloud", "cli" => "CLI", "claude-vscode" => "VS Code", "claude-desktop" => "Desktop",
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
      # Cloud sessions link to their page at claude.ai (drawn after the row's
      # own click area so it takes the click).
      if s["url"]
        link("↗", w - 118, y + 4, size: 11, color: CYAN) { open_session_url(s["url"]) }
      end
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
        @c.hit(tool_x, y, w - 180 - tool_x, row_h - 6) { open_overlay(last_tool_overlay(s)) } if s["last_tool"]
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
        @c.hit(10, y, w - 20, card_h) { open_overlay(project_overlay(p)) }
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
      session_only_toggle(w)
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
        @c.hit(10, y, w - 20, row_h) { open_overlay(event_overlay(e)) }
      end
    end

    # ---- Usage ---------------------------------------------------------

    RANGE_STEP = { "12h" => 1, "24h" => 1, "7d" => 6, "30d" => 24 }.freeze
    RANGE_LABEL = { "12h" => "Last 12 hours", "24h" => "Last 24 hours", "7d" => "Last 7 days", "30d" => "Last 30 days" }.freeze
    # [legend key, colour, index in an hourly row]
    SERIES = [["Tool calls", TEAL, 2], ["Output k-tok", BLUE, 1], ["Prompts", PURPLE, 3], ["Errors", RED, 4]].freeze

    def draw_usage_body(w, h)
      t = @store.totals
      tiles = [["Prompts", t[:prompts], "›", :prompts], ["Tool calls", t[:tool_calls], "⚙", :tools],
               ["Output tokens", t[:out_tokens], "✦", :tokens], ["Tool errors", t[:errors], "!", :tools]]
      bw = [(w - 32 - 3 * 24) / 4, 100].max
      gap = (w - 32 - tiles.size * bw) / (tiles.size - 1)
      tiles.each_with_index do |(name, value, glyph, view), i|
        x = 16 + i * (bw + gap)
        c = name == "Tool errors" && value.positive? ? RED : CYAN
        @c.rect(x, 6, bw, 56, curve: 8, fill: col(PANEL2), stroke: col(c, 0.55))
        square_icon(x + 8, 16, c, glyph, 26)
        txt(name, x + 42, 13, size: 9, color: c, weight: :bold)
        txt(Store.count(value), x + 42, 30, size: 13, color: TEXT, weight: :bold)
        @c.hit(x, 6, bw, 56) { open_overlay(view_overlay(view)) }
      end

      range = @store.chart_range
      step = RANGE_STEP[range]
      buckets = @store.hourly(Store::CHART_RANGES[range]).each_slice(step).map do |slice|
        [slice.first[0], *(1..4).map { |i| slice.sum { |r| r[i] } }]
      end
      unit = { 1 => "h", 6 => "6h", 24 => "day" }[step]
      format = { 1 => "%H:00", 6 => "%a %H:00", 24 => "%b %-d" }[step]
      series = SERIES.map do |key, color, idx|
        values = buckets.map { |b| idx == 1 ? (b[1] / 1000.0).round(1) : b[idx] }
        { key: key, name: "#{key} / #{unit}", color: color, values: values }
      end
      visible = series.reject { |sr| @store.hidden_series.include?(sr[:key]) }
      max = nice_ceiling(visible.flat_map { |sr| sr[:values] }.max.to_f)
      chart_w = w - 130
      every = [(buckets.size / 7.0).ceil, 1].max
      labels = buckets.each_with_index.map { |b, i| i % every == 0 || i == buckets.size - 1 ? Time.at(b[0]).strftime(format) : "" }
      line_chart(12, 76, chart_w, h - 84, labels, visible, max: max)

      # A click on a column opens that period's breakdown.
      gx = 38
      gw = chart_w - 26
      colw = gw / [buckets.size - 1, 1].max.to_f
      buckets.each_with_index do |b, i|
        @c.hit(gx + colw * i - colw / 2, 76, colw, h - 84 - 18) { open_overlay(period_overlay(b[0], step)) }
      end

      rx = chart_w + 22
      txt("#{RANGE_LABEL[range]}, all machines", rx, 72, size: 8, color: DIM, width: 110)
      Store::CHART_RANGES.keys.each_with_index do |key, i|
        tab(rx + (i % 2) * 52, 88 + (i / 2) * 24, key, key == range, width: 46) { set_chart_range(key) }
      end
      series.each_with_index do |sr, i|
        y = 146 + i * 22
        hidden = @store.hidden_series.include?(sr[:key])
        dot(rx, y + 3, col(sr[:color], hidden ? 0.25 : 1.0), 7)
        txt(sr[:name], rx + 14, y - 2, size: 9, color: hidden ? DIM : TEXT)
        @c.hit(rx - 4, y - 4, 112, 20) { toggle_series(sr[:key]) }
      end
    end

    def nice_ceiling(v)
      return 6 if v <= 6
      mag = 10**Math.log10(v).floor
      [1, 1.5, 2, 3, 5, 6, 10].map { |m| m * mag }.find { |c| c >= v }.ceil
    end

    # ---- System health -------------------------------------------------

    def health_machine
      host = @store.selected_session&.dig("host")
      m = @store.machines.find { |x| x["host"] == host }
      m && m["health"]["load"] ? m : @store.local_machine # claude.ai reports no machine health
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
        @c.hit(4, y, w - 8, row_h) { open_overlay(event_overlay(e)) }
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
      link("Open in claude.ai ↗", 150, 24, size: 9, color: CYAN) { open_session_url(s["url"]) } if s["url"]
      link("Timeline ›", w - 76, 8, size: 9, color: CYAN) { open_overlay(timeline_overlay(s)) }
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
        ["Context",     context_text(s)],
        ["Output",      "#{Store.count(tok['out'])} tok"],
        ["Cache read",  "#{Store.count(tok['cache_read'])} tok"],
        ["Tools",       "#{s['tool_calls'].to_i} (#{s['errors'].to_i} err)"],
        ["Prompts",     s["prompts"].to_i.to_s]
      ]
      rows.each_with_index do |(k, v), i|
        label(k, cx, 68 + i * 17, size: 9, color: MUTED)
        color = if k == "Context" then context_color(s)
                elsif k == "Tools" && s["errors"].to_i.positive? then YELLOW
                else TEXT
                end
        txt(v, cx + 64, 68 + i * 17, size: 9, color: color)
      end
    end

    # ---- Event log -----------------------------------------------------

    KIND_COLORS = { "prompt" => CYAN, "tool" => TEAL, "error" => RED, "attention" => YELLOW, "lifecycle" => MUTED }.freeze

    def draw_log_body(w, h)
      session_only_toggle(w)
      list = @store.visible_events
      return empty_state("No events in the last 24 hours.") if list.empty?
      row_h = 19
      rows = [(h - 6) / row_h, list.size].min
      list.first(rows).each_with_index do |e, i|
        y = 4 + i * row_h
        txt(Time.at(e["at"]).strftime("%H:%M"), 14, y, size: 9, color: MUTED, mono: true)
        kind = %w[tool lifecycle].include?(e["kind"]) ? e["title"].to_s : e["kind"].to_s
        txt(clip(kind, 14), 54, y, size: 9, color: KIND_COLORS[e["kind"]] || MUTED, mono: true)
        txt(clip("#{e['session']}: #{e['detail']}", (w - 160) / 5.6), 148, y, size: 9, color: TEXT)
        @c.hit(10, y - 2, w - 20, row_h) { open_overlay(event_overlay(e)) }
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
        square_icon(14, y + 3, c, m["local"] ? "⌂" : (m["host"] == CloudFeed::HOST ? :cloud : "◈"), 24)
        txt(clip(m["host"], (w - 120) / 6.5), 48, y + 2, size: 9, color: TEXT, weight: :bold)
        os = m["health"]["os"]
        txt([("#{m['sessions']} sessions" if m["online"]), os, (m["online"] ? nil : "last seen #{Store.ago(m['seen_at'])}")].compact.join(" · "),
            48, y + 17, size: 8, color: MUTED)
        txt(m["online"] ? "online" : "offline", w - 70, y + 2, size: 8, color: c, width: 58, align: :right)
        @c.hit(4, y, w - 8, row_h) { open_overlay(machine_overlay(m)) }
      end
    end

    # "This session only", in the panel's title bar: narrows Tool Calls and
    # the Event Log to the session selected in Claude Sessions.
    def session_only_toggle(w)
      on = @store.session_only
      label = on ? "● this session only" : "○ this session only"
      link(label, w - 128, -Layout::PANEL_TITLE_H + 12, size: 9, color: on ? CYAN : MUTED, width: 112) { toggle_session_only }
    end

    # ---- context meter -------------------------------------------------

    # "52k / 1M · 5%": the session's context against its model's window.
    def context_text(s)
      return "—" unless s["context"]
      window = Store.context_window(s["model"], s["context"])
      "#{Store.count(s['context'])} / #{Store.count(window)} · #{(s['context'] * 100.0 / window).round}%"
    end

    def context_color(s)
      return TEXT unless s["context"]
      pct = s["context"].to_f / Store.context_window(s["model"], s["context"])
      pct >= 0.95 ? RED : (pct >= 0.8 ? YELLOW : TEXT)
    end

    # ---- drill-down overlays --------------------------------------------

    # Monospaced table: first column left-aligned, the rest right-aligned
    # unless `left` names more left-aligned columns.
    def table(headers, rows, left: [0])
      cols = headers.size
      widths = (0...cols).map { |i| ([headers[i]] + rows.map { |r| r[i] }).map { |c| c.to_s.length }.max }
      fmt = ->(r) { (0...cols).map { |i| left.include?(i) ? r[i].to_s.ljust(widths[i]) : r[i].to_s.rjust(widths[i]) }.join("   ").rstrip }
      ([fmt.(headers), widths.map { |wd| "─" * wd }.join("   ")] + rows.map(&fmt)).join("\n")
    end

    def view_overlay(view)
      case view
      when :tokens then tokens_overlay
      when :tools then tools_overlay
      when :prompts then prompts_overlay
      else sessions_overlay
      end
    end

    def pct(part, whole)
      whole.to_f.positive? ? "#{(part * 100.0 / whole).round(1)}%" : "—"
    end

    def tokens_overlay(hours = 24)
      tb = @store.token_breakdown(hours)
      t = tb[:totals]
      o = Overlay.new("Output tokens", subtitle: "Last #{hours} hours, every machine")
      o.field("Output", Store.count(t["out"]))
      o.field("Input", Store.count(t["in"]))
      o.field("Cache read", Store.count(t["cache_read"]))
      o.field("Cache write", Store.count(t["cache_write"]))
      o.field("Cache hit", tb[:cache_hit] && "#{(tb[:cache_hit] * 100).round(1)}% of prompt tokens were read from cache")
      kinds = ->(x) { [Store.count(x["out"]), Store.count(x["in"]), Store.count(x["cache_read"]), Store.count(x["cache_write"])] }
      head = %w[output input cache\ read cache\ write]
      o.block("By model", table(["model", *head], tb[:by_model].sort_by { |_, x| -x["out"] }.map { |m, x| [Store.model_name(m), *kinds.(x)] }))
      o.block("By project", table(["project", *head], tb[:by_project].sort_by { |_, x| -x["out"] }.map { |pr, x| [pr, *kinds.(x)] }))
      o.block("By hour", table(["hour", *head], tb[:by_hour].sort_by(&:first).reverse.map { |hr, x| [Time.at(hr).strftime("%a %H:00"), *kinds.(x)] }))
      o.block("By session (whole session so far)", table(["session", *head], tb[:by_session].first(30).map { |n, x| [n.to_s[0, 60], *kinds.(x)] }))
      o.note("Cloud sessions report no token counts (Claude Code's hooks don't receive usage), so they're not included here.")
      o
    end

    def tools_overlay
      stats = @store.tool_stats
      secs = ->(v) { v ? (v < 10 ? format("%.2fs", v) : Store.duration(v).sub(/\A0m\z/, "#{v.round}s")) : "—" }
      o = Overlay.new("Tool calls", subtitle: "Every tool call in the last 24 hours (newest #{Probe::EVENT_LIMIT} per machine)")
      o.field("Calls", stats.sum { |x| x[:calls] })
      o.field("Errors", stats.sum { |x| x[:errors] })
      rows = stats.map do |x|
        [x[:tool], x[:calls], x[:errors], pct(x[:errors], x[:calls]), secs.(x[:median]), secs.(x[:max]) + (x[:waits] ? "  (waits on you)" : "")]
      end
      o.block("By tool", table(%w[tool calls errors error\ rate median slowest], rows, left: [0, 5]))
      slow = @store.slowest_tools(15).map { |e| [Time.at(e["at"]).strftime("%H:%M:%S"), e["title"], secs.(e["duration"]), e["session"].to_s[0, 40], e["detail"].to_s] }
      o.block("Slowest calls", table(%w[time tool took session detail], slow, left: [0, 1, 3, 4])) unless slow.empty?
      o.note("Durations run from the call to its result. Tools that wait for you (AskUserQuestion, ExitPlanMode) are left out of the slowest list. Cloud sessions report calls without durations.")
      o
    end

    def prompts_overlay
      by = @store.prompts_by_project
      o = Overlay.new("Prompts", subtitle: "Last 24 hours, every machine")
      o.field("Prompts", @store.prompts.size)
      o.block("By project", table(%w[project prompts], by.map { |pr, list| [pr.empty? ? "(unknown)" : pr, list.size] }))
      recent = @store.prompts.first(40).map { |e| "#{Time.at(e['at']).strftime('%a %H:%M')}  #{e['session'].to_s[0, 30].ljust(30)}  #{e['detail']}" }
      o.block("Most recent", recent.join("\n"))
      o.note("Click a prompt in Recent Prompts for its full text.")
      o
    end

    def sessions_overlay
      list = @store.all_sessions
      o = Overlay.new("Claude sessions", subtitle: "#{@store.sessions.size} live, #{@store.busy_count} busy, #{@store.recent_sessions.size} earlier")
      rows = list.map do |s|
        [status_label(s), Store.display_name(s).to_s[0, 50], project_of(s), entry_name(s), Store.model_name(s["model"]),
         s["tool_calls"].to_i, Store.ago(Store.worked_at(s))]
      end
      o.block("Sessions (most recently worked on first)", table(%w[status session project client model tools last\ worked], rows, left: [0, 1, 2, 3, 4]))
      o
    end

    # Everything one session did, in order, with the context after each prompt.
    def timeline_overlay(s)
      evs = @store.events.select { |e| e["sid"] == s["id"] }.sort_by { |e| e["at"].to_f }
      o = Overlay.new(Store.display_name(s), subtitle: [project_of(s), entry_name(s), s["host"]].compact.join("  ·  "))
      o.field("Status", status_label(s))
      o.field("Model", Store.model_name(s["model"]))
      o.field("Started", s["started_at"] && Time.at(s["started_at"]).strftime("%a %b %-d, %H:%M"))
      o.field("Context", context_text(s))
      o.field("Tools", "#{s['tool_calls'].to_i} (#{s['errors'].to_i} errors)")
      lines = evs.map do |e|
        time = Time.at(e["at"].to_f).strftime("%H:%M:%S")
        case e["kind"]
        when "prompt" then "#{time}  ›  #{e['detail']}#{e['context'] ? "   [context #{Store.count(e['context'])}]" : ''}"
        when "tool" then "#{time}      #{e['title']}#{e['duration'] ? " #{format('%.1fs', e['duration'])}" : ''}#{e['failed'] ? ' FAILED' : ''}  #{e['detail']}"
        when "error" then "#{time}      ! #{e['tool'] || 'tool'} error: #{e['detail']}"
        else "#{time}  ·  #{e['title']} #{e['detail']}".rstrip
        end
      end
      o.block("Timeline (oldest first)", lines.empty? ? "No events in the last 24 hours." : lines.join("\n"))
      o.note("Events are kept for 24 hours, the newest #{Probe::EVENT_LIMIT} per machine, so a long session's start may be missing.") if lines.size > 50
      o
    end

    EDIT_TOOLS = %w[Edit Write MultiEdit NotebookEdit].freeze

    def project_overlay(p)
      name = File.basename(p["cwd"].to_s)
      sessions = @store.all_sessions.select { |s| File.basename(s["cwd"].to_s) == name }
      o = Overlay.new(name, subtitle: [p["cwd"], p["host"]].compact.join("  ·  "))
      o.field("Prompts (24h)", p["prompts"].to_i)
      o.field("Tool calls (24h)", p["tool_calls"].to_i)
      o.field("Output (24h)", "#{Store.count(p['out_tokens'])} tokens")
      o.field("Branches", sessions.map { |s| s["branch"] }.compact.uniq.join(", "))
      by_model = Hash.new(0)
      @store.usage(24).each { |_, _, pr, model, out| by_model[model] += out if pr == name }
      o.block("Output by model (24h)", table(%w[model output], by_model.reject { |_, v| v.zero? }.sort_by { |_, v| -v }.map { |m, v| [Store.model_name(m), Store.count(v)] }))
      o.block("Sessions", table(%w[status session client tools last\ worked], sessions.map { |s| [status_label(s), Store.display_name(s).to_s[0, 50], entry_name(s), s["tool_calls"].to_i, Store.ago(Store.worked_at(s))] }, left: [0, 1, 2]))
      files = @store.tool_events.select { |e| e["project"] == name && EDIT_TOOLS.include?(e["title"]) }.map { |e| e["detail"].to_s }.reject(&:empty?).tally
      o.block("Files edited most (24h)", table(%w[file edits], files.sort_by { |_, n| -n }.first(20).map { |f, n| [f, n] })) unless files.empty?
      o
    end

    # One chart column: `step` hours from `start`.
    def period_overlay(start, step)
      stop = start + step * 3600
      rows = @store.usage([((Store.current_hour - start) / 3600) + 1, 1].max).select { |r| r[1] >= start && r[1] < stop }
      sum = ->(i) { rows.sum { |r| r[i].to_i } }
      fmt = step == 24 ? "%a %b %-d" : "%a %b %-d, %H:00"
      o = Overlay.new("Usage #{Time.at(start).strftime(fmt)}#{step > 1 ? " – #{Time.at(stop).strftime(step == 24 ? '%a %b %-d' : '%H:00')}" : ''}",
                      subtitle: "Every machine")
      o.field("Prompts", sum.(9))
      o.field("Tool calls", sum.(8))
      o.field("Errors", sum.(10))
      o.field("Output tokens", Store.count(sum.(4)))
      by_project = rows.group_by { |r| r[2].empty? ? "(cloud)" : r[2] }.map { |pr, rs| [pr, rs.sum { |r| r[9] }, rs.sum { |r| r[8] }, Store.count(rs.sum { |r| r[4] })] }
      o.block("By project", table(%w[project prompts tools output], by_project.sort_by { |r| -r[2] }))
      evs = @store.events.select { |e| e["at"].to_f >= start && e["at"].to_f < stop }.sort_by { |e| e["at"].to_f }
      if evs.empty?
        o.note("Individual events are kept for 24 hours; this period's totals come from the usage history.") if stop < Time.now.to_i - 24 * 3600
      else
        o.block("Events", evs.map { |e| "#{Time.at(e['at'].to_f).strftime('%H:%M:%S')}  #{e['kind'].ljust(9)} #{e['session'].to_s[0, 30].ljust(30)}  #{e['kind'] == 'tool' ? "#{e['title']}: " : ''}#{e['detail']}" }.join("\n"))
      end
      o
    end

    # ---- detail overlays ----------------------------------------------

    EVENT_HEADINGS = { "tool" => "Input", "prompt" => "Prompt", "error" => "Error", "attention" => "Message" }.freeze

    # Everything known about one event: tool call, prompt, error or notice.
    def event_overlay(e)
      session = @store.session(e["sid"])
      title = case e["kind"]
              when "tool" then "#{e['title']} tool call"
              when "error" then "Tool error"
              when "prompt" then "Prompt"
              else e["title"].to_s.capitalize
              end
      o = Overlay.new(title, subtitle: [e["session"], e["project"], e["host"]].compact.uniq.join("  ·  "))
      o.field("When", Time.at(e["at"].to_f).strftime("%a %b %-d %Y, %H:%M:%S"))
      o.field("Session", e["session"])
      o.field("Project", e["project"])
      o.field("Machine", e["host"])
      o.field("Client", session && entry_name(session))
      o.field("Model", session && Store.model_name(session["model"]))
      o.field("Session id", e["sid"])
      o.block(EVENT_HEADINGS.fetch(e["kind"], "Detail"), e["full"] || e["detail"])
      unless e["full"]
        o.note("Only this excerpt is available: sessions on other machines and in the cloud send a short " \
               "excerpt of each event, never the full text.")
      end
      o
    end

    # The tool a live session ran last, with the full event when it is known.
    def last_tool_overlay(s)
      t = s["last_tool"]
      e = @store.events.find { |x| x["sid"] == s["id"] && x["kind"] == "tool" && x["at"].to_f == t["at"].to_f }
      e ||= { "at" => t["at"], "sid" => s["id"], "kind" => "tool", "title" => t["name"], "detail" => t["detail"],
              "session" => Store.display_name(s), "project" => project_of(s), "host" => s["host"] }
      event_overlay(e)
    end

    def machine_overlay(m)
      hl = m["health"]
      sessions = @store.sessions.select { |s| s["host"] == m["host"] }
      source = if m["local"] then "this machine (read directly)"
               elsif m["host"] == CloudFeed::HOST then "cloud sessions (hook reports)"
               else "bin/bot-ops-agent"
               end
      o = Overlay.new(m["host"], subtitle: m["online"] ? "online" : "offline, last seen #{Store.ago(m['seen_at'])}")
      o.field("Source", source)
      o.field("OS", hl["os"])
      o.field("CPUs", hl["cpus"])
      o.field("Load", hl["load"] && format("%.2f", hl["load"]))
      o.field("Memory", hl["mem_pct"] && "#{hl['mem_pct']}% used")
      o.field("Disk", hl["disk_pct"] && "#{hl['disk_pct']}% used")
      o.field("Uptime", hl["uptime_s"] && uptime_text(hl["uptime_s"]))
      o.field("Last report", Store.ago(m["seen_at"]))
      unless sessions.empty?
        list = sessions.map { |s| "#{status_label(s).ljust(9)} #{Store.display_name(s)}  (#{project_of(s)}, #{entry_name(s)})" }
        o.block("Live sessions", list.join("\n"))
      end
      o
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
      ny = y + 54
      txt("Alerts", 16, ny, size: 9, color: MUTED)
      txt("Dock badge and bounce when a session waits on you: always on.", 150, ny, size: 9, color: TEXT)
      on = @store.notifications?
      link(on ? "[ macOS notifications: on ]" : "[ macOS notifications: off ]", 150, ny + 18, color: on ? CYAN : MUTED) do
        @store.notifications = !on
        @host.invalidate
      end
      txt("(a script-posted notification opens Script Editor when clicked)", 330, ny + 18, size: 8, color: DIM)
      y += 64 + 50
      txt("Add another machine", 16, y, size: 9, color: MUTED)
      txt("1. Here: start the dashboard with BOT_OPS_LISTEN=0.0.0.0:47800 and a BOT_OPS_TOKEN of 16+ characters.",
          150, y, size: 9, color: TEXT, width: w - 170)
      txt("2. There: BOT_OPS_COLLECTOR=http://<this machine>:47800 BOT_OPS_TOKEN=<same> bin/bot-ops-agent",
          150, y + 18, size: 9, color: TEXT, width: w - 170, mono: true)
    end
  end
end
